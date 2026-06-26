#!/usr/bin/env bash
# ============================================================================
#  luatools-moon — diagnostics collector
# ============================================================================
#  Gathers the stack's logs, strips person-identifying data, bundles them and
#  uploads the bundle to a public paste, printing ONLY the resulting link.
#
#    curl -fsSL https://raw.githubusercontent.com/luatools-linux/luatools-moon/main/diagnose.sh | bash
#
#  Design notes
#  ------------
#  - No install-time footprint: run on demand, nothing persists on disk.
#  - No hard dependencies beyond what a `curl ... | bash` run already implies
#    (bash, curl, tar/gzip, sed). A bash /dev/tcp fallback covers the upload
#    when the curl-based sink is unreachable.
#  - Privacy: collected logs are filtered by scrub() before they ever leave the
#    machine. We mask person-identifying data (home/username, Steam account id,
#    SteamID64, email, IPv4, Steam CM region) and KEEP the technically useful,
#    non-PII fields (appids, depot ids, manifest gids, build ids, hashes).
#  - Secrets are NEVER collected: OAuth tokens in ~/.config/CloudRedirect, the
#    Lumen per-boot RPC token (session.json), etc. Only explicit log files are
#    read.
#  - The paste link is treated as inert: validated against a strict regex,
#    never eval'd, printed escaped.
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# scrub : stdin -> stdout, masking person-identifying data.
#
# The running identity is taken from SCRUB_USER / SCRUB_HOME (so it is unit-
# testable with a fixed fixture identity); in normal runs main() seeds them
# from the real user. Everything not person-identifying (appids, depot ids,
# manifest gids, build ids, hashes, timestamps, memory addresses) is preserved
# on purpose so the logs stay diagnosable.
# ----------------------------------------------------------------------------

# Escape every non-alphanumeric char so an arbitrary string is safe to embed in
# a sed ERE (over-escaping is harmless for these characters).
_re_escape() { printf '%s' "$1" | sed -e 's/[^a-zA-Z0-9]/\\&/g'; }

scrub() {
	local u h
	u="${SCRUB_USER-$(id -un 2>/dev/null || true)}"
	h="${SCRUB_HOME-$HOME}"

	local -a args=(-E)

	# Literal home dir + running username (strongest: catches the name wherever
	# it appears, not just under /home/). Added only when non-empty.
	if [ -n "$h" ]; then
		args+=(-e "s#$(_re_escape "$h")#/home/USER#g")
	fi

	# Generic home paths (other users mentioned in shared logs, e.g. cef logs).
	args+=(-e 's#/home/[A-Za-z0-9._-]+#/home/USER#g')

	# Steam account id (Steam3 accountid) — directly maps to a public SteamID64
	# / profile URL, so it deanonymizes. Appears as userdata/<id> and in
	# CloudRedirect storage/backups/<id> paths.
	args+=(-e 's#(userdata|storage|backups)/[0-9]+#\1/ACCOUNTID#g')
	# accountId given as a keyed value (e.g. "m_accountId = 488150314").
	args+=(-e 's/(account[_ ]?id)([^0-9]{1,6})[0-9]+/\1\2ACCOUNTID/gI')

	# Full SteamID64 (17 digits, 7656...). Bounded so 18/19-digit manifest gids
	# are untouched.
	args+=(-e 's/\b7656[0-9]{13}\b/STEAMID/g')

	# Email addresses (incl. a set FakeEmail value).
	args+=(-e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/EMAIL/g')

	# IPv4 addresses.
	args+=(-e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/IP/g')

	# Steam CM endpoint region (coarse geolocation, e.g. cmp1-atl3 = Atlanta).
	args+=(-e 's/-[a-z]{2,5}[0-9]+\.steamserver\.net/-REGION.steamserver.net/g')

	# Forced account / persona name given as a keyed value.
	args+=(-e 's/((force_)?account_?name|persona_?name)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\3NAME/gI')

	# Bare username token anywhere else. Added last and only when non-empty.
	if [ -n "$u" ]; then
		args+=(-e "s/\b$(_re_escape "$u")\b/USER/g")
	fi

	sed "${args[@]}"
}

# ----------------------------------------------------------------------------
# validate_paste_url : 0 iff $1 is a clean, known-shape paste URL.
#
# The sink's response is attacker-controllable if the sink is hijacked, so the
# returned link is treated as inert: only an exact https paste.rs / termbin.com
# URL with an alphanumeric id is ever accepted. Anything with whitespace,
# control/ANSI bytes, shell metacharacters, a foreign host or extra text is
# rejected. The caller never eval's the value and prints it with printf %s.
# ----------------------------------------------------------------------------
validate_paste_url() {
	local u="${1-}"
	# Reject any whitespace/newline up front (so a multiline string can't slip
	# past the anchored regex on some regex engines).
	case "$u" in
		*[[:space:]]*) return 1 ;;
	esac
	# Strict shape. The trailing anchor + [A-Za-z0-9]-only id rejects control
	# bytes, ANSI escapes, path traversal and shell metacharacters implicitly.
	[[ "$u" =~ ^https://(paste\.rs|termbin\.com)/[A-Za-z0-9]+$ ]]
}

# ----------------------------------------------------------------------------
# Log collection
# ----------------------------------------------------------------------------
# Per-file tail cap and overall cap. Diagnostic value lives in the tail (recent
# events); the overall cap keeps the bundle under the paste host's size limit.
DIAG_PER_FILE_CAP="${DIAG_PER_FILE_CAP:-262144}"   # 256 KiB / file
DIAG_TOTAL_CAP="${DIAG_TOTAL_CAP:-716800}"         # ~700 KiB total

# Resolve the Steam root (layout-independent): prefer the bootstrapped
# ~/.steam/steam symlink, else known per-distro data dirs. Echoes "" if none.
steam_root() {
	local link="$HOME/.steam/steam" r c
	r="$(readlink -e -q "$link" 2>/dev/null || true)"
	if [ -n "$r" ] && [ -d "$r/logs" ]; then printf '%s' "$r"; return 0; fi
	for c in "$HOME/.local/share/Steam" "$HOME/.steam/debian-installation" "$HOME/.steam/steam"; do
		if [ -d "$c/logs" ]; then printf '%s' "$c"; return 0; fi
	done
	printf ''
}

# Append a scrubbed, tail-capped copy of a log file to $DIAG_OUT. The header
# (which embeds the path) is scrubbed too, so the home/username never leaks via
# the section title. No-op when the file is absent/unreadable.
_add_file() { # $1 label  $2 path
	local label="$1" path="$2"
	[ -f "$path" ] && [ -r "$path" ] || return 0
	{
		printf '\n===== %s (%s) =====\n' "$label" "$path"
		tail -c "$DIAG_PER_FILE_CAP" "$path" 2>/dev/null
	} | scrub >> "$DIAG_OUT"
}

# Build the diagnostics bundle at $1. Only explicit log files are read — never
# whole config dirs (CloudRedirect holds OAuth tokens; Lumen holds a session
# token). Auto-detects which line (Lumen/Millennium) and components are present.
collect() {
	DIAG_OUT="$1"
	local sr; sr="$(steam_root)"

	{
		printf '===== luatools-moon diagnostics =====\n'
		printf 'date(utc): %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
		printf 'kernel: %s   arch: %s\n' "$(uname -r 2>/dev/null)" "$(uname -m 2>/dev/null)"
		if [ -r /etc/os-release ]; then
			# shellcheck disable=SC1091
			( . /etc/os-release >/dev/null 2>&1; printf 'distro: %s %s\n' "${ID:-?}" "${VERSION_ID:-}" )
		fi
		printf 'steam_root: %s\n' "${sr:-NOT FOUND}"
		printf 'components:'
		[ -d "$HOME/.local/share/Lumen" ] || [ -f "$HOME/.lumen.log" ] && printf ' lumen'
		{ [ -d "$HOME/.millennium" ] || [ -d "$HOME/.local/share/millennium" ]; } && printf ' millennium'
		[ -d "$HOME/.config/CloudRedirect" ] && printf ' cloudredirect'
		[ -f "$HOME/.SLSsteam.log" ] && printf ' slsteam'
		printf '\n'
	} | scrub >> "$DIAG_OUT"

	# Stack logs.
	_add_file "slsteam"        "$HOME/.SLSsteam.log"
	_add_file "slsteam-config" "$HOME/.config/SLSsteam/config.yaml"
	_add_file "lumen"          "$HOME/.lumen.log"

	# Steam's own logs directory (content_log, cef_log, connection_log, ...).
	if [ -n "$sr" ]; then
		local f
		for f in "$sr"/logs/*; do _add_file "steam-log" "$f"; done
	fi

	# CloudRedirect — ONLY the two log files, never the config dir (tokens!).
	_add_file "cloudredirect" "$HOME/.config/CloudRedirect/cr_debug.log"
	_add_file "cloudredirect" "$HOME/.config/CloudRedirect/cloud_redirect.log"

	# Millennium line (fallback branch) — best-effort glob of its log dirs.
	local g
	for g in "$HOME"/.millennium/*.log \
	         "$HOME"/.millennium/logs/*.log \
	         "$HOME"/.local/share/millennium/*.log \
	         "$HOME"/.local/share/millennium/logs/*.log; do
		_add_file "millennium" "$g"
	done

	# Keep the bundle under the paste host's size limit (tail = recent events).
	if [ "$(wc -c < "$DIAG_OUT" 2>/dev/null || echo 0)" -gt "$DIAG_TOTAL_CAP" ]; then
		local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/luatools-diag.XXXXXX")" || return 0
		{ printf '[... older output trimmed to fit ...]\n'; tail -c "$DIAG_TOTAL_CAP" "$DIAG_OUT"; } > "$tmp"
		mv -f "$tmp" "$DIAG_OUT"
	fi
}

# ----------------------------------------------------------------------------
# Upload — paste.rs (curl) primary, termbin (bash /dev/tcp) fallback.
# Echoes a VALIDATED url on success; returns 1 if both sinks fail.
# ----------------------------------------------------------------------------
_termbin_upload() { # $1 file -> raw response
	local file="$1" resp
	exec 3<>/dev/tcp/termbin.com/9999 || return 1
	cat "$file" >&3
	resp="$(cat <&3)"
	exec 3>&- 2>/dev/null || true
	printf '%s' "$resp" | tr -d '\000\r\n'
}

upload() { # $1 file -> validated url
	local file="$1" url
	if command -v curl >/dev/null 2>&1; then
		url="$(curl -sS --max-time 30 --data-binary @"$file" https://paste.rs/ 2>/dev/null || true)"
		if validate_paste_url "$url"; then printf '%s\n' "$url"; return 0; fi
	fi
	url="$(_termbin_upload "$file" 2>/dev/null || true)"
	if validate_paste_url "$url"; then printf '%s\n' "$url"; return 0; fi
	return 1
}

# ----------------------------------------------------------------------------
# main — collect, upload, print ONLY the link.
# ----------------------------------------------------------------------------
# Holds the temp bundle path; global so the EXIT trap can clean it after main
# returns (a function-local would be out of scope by then, tripping set -u).
DIAG_TMP=""
_diag_cleanup() { rm -f "${DIAG_TMP:-}" 2>/dev/null || true; }

main() {
	local url
	trap _diag_cleanup EXIT
	DIAG_TMP="$(mktemp "${TMPDIR:-/tmp}/luatools-diag.XXXXXX")" \
		|| { echo "diag: cannot create a temporary file" >&2; exit 1; }

	collect "$DIAG_TMP"
	if [ ! -s "$DIAG_TMP" ]; then
		echo "diag: no logs found to collect" >&2
		exit 1
	fi

	if url="$(upload "$DIAG_TMP")"; then
		printf '%s\n' "$url"
	else
		echo "diag: upload failed (paste.rs and termbin both unreachable)" >&2
		exit 1
	fi
}

# ----------------------------------------------------------------------------
# Run unless sourced for unit tests (DIAGNOSE_LIB_ONLY=1). Plain
# `curl ... | bash` leaves it unset, so main still runs.
# ----------------------------------------------------------------------------
if [ -z "${DIAGNOSE_LIB_ONLY:-}" ]; then
	main "$@"
fi
