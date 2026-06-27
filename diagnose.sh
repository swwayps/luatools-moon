#!/usr/bin/env bash
# ============================================================================
#  luatools-moon — diagnostics collector
# ============================================================================
#  Gathers the stack's logs, strips person-identifying data, bundles them into
#  a .tar.gz and uploads the bundle to a public paste, printing ONLY the link.
#
#    curl -fsSL https://raw.githubusercontent.com/luatools-linux/luatools-moon/main/diagnose.sh | bash
#
#  The link points at a gzip tarball of the COMPLETE logs (one file each),
#  fetched + read with:
#
#    curl -fsSL <link> -o luatools-logs.tar.gz && tar xzf luatools-logs.tar.gz
#
#  Design notes
#  ------------
#  - No install-time footprint: run on demand, nothing persists on disk.
#  - Only curl + tar/gzip + sed are needed (all implied by a `curl ... | bash`
#    run). A bash /dev/tcp termbin fallback covers the upload if paste.rs is
#    unreachable.
#  - Privacy: every archived log is filtered by scrub() before it leaves the
#    machine. Person-identifying data is masked (home/username, Steam account
#    id, SteamID64, email, IPv4, Steam CM region); technically useful, non-PII
#    fields (appids, depot ids, manifest gids, build ids, hashes) are kept.
#  - Secrets are NEVER collected: OAuth tokens in ~/.config/CloudRedirect, the
#    Lumen per-boot RPC token (session.json), etc. Only explicit log files are
#    read.
#  - Logs are archived COMPLETE, except cef_log (Chromium noise) which is
#    tail-capped so a multi-MB file can't blow the paste size limit.
#  - The paste link is treated as inert: validated against a strict regex,
#    never eval'd, printed escaped.
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# scrub : stdin -> stdout, masking person-identifying data.
#
# The running identity is taken from SCRUB_USER / SCRUB_HOME (so it is unit-
# testable with a fixed fixture identity); in normal runs they default to the
# real user. Everything not person-identifying (appids, depot ids, manifest
# gids, build ids, hashes, timestamps, memory addresses) is preserved.
# ----------------------------------------------------------------------------

# Escape every non-alphanumeric char so an arbitrary string is safe to embed in
# a sed ERE (over-escaping is harmless for these characters).
_re_escape() { printf '%s' "$1" | sed -e 's/[^a-zA-Z0-9]/\\&/g'; }

scrub() {
	local u h
	u="${SCRUB_USER-$(id -un 2>/dev/null || true)}"
	h="${SCRUB_HOME-$HOME}"

	local -a args=(-E)

	if [ -n "$h" ]; then
		args+=(-e "s#$(_re_escape "$h")#/home/USER#g")
	fi
	args+=(-e 's#/home/[A-Za-z0-9._-]+#/home/USER#g')

	# Steam account id (Steam3 accountid) — maps to a public SteamID64 / profile
	# URL, so it deanonymizes. Appears as userdata/<id> and in CloudRedirect
	# storage/backups/<id> paths, or as a keyed value.
	args+=(-e 's#(userdata|storage|backups)/[0-9]+#\1/ACCOUNTID#g')
	# Separator restricted to non-alphanumerics so the rule can't span across a
	# following word (and can't re-consume the ACCOUNTID placeholder + eat the
	# next token's digits).
	args+=(-e 's/(account[_ ]?id)([^0-9A-Za-z]{1,6})[0-9]+/\1\2ACCOUNTID/gI')

	# Full SteamID64 (17 digits, 7656...). Bounded so longer manifest gids stay.
	args+=(-e 's/\b7656[0-9]{13}\b/STEAMID/g')

	# Emails (incl. a set FakeEmail value).
	args+=(-e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/EMAIL/g')

	# IPv4 addresses.
	args+=(-e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/IP/g')

	# Steam CM endpoint region (coarse geolocation, e.g. cmp1-atl3 = Atlanta).
	args+=(-e 's/-[a-z]{2,5}[0-9]+\.steamserver\.net/-REGION.steamserver.net/g')

	# Forced account / persona name given as a keyed value.
	args+=(-e 's/((force_)?account_?name|persona_?name)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\3NAME/gI')

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
# URL with an alphanumeric id is accepted. Whitespace, control/ANSI bytes, shell
# metacharacters, a foreign host or extra text are all rejected. The caller
# never eval's the value and prints it with printf %s.
# ----------------------------------------------------------------------------
validate_paste_url() {
	local u="${1-}"
	case "$u" in
		*[[:space:]]*) return 1 ;;
	esac
	[[ "$u" =~ ^https://(paste\.rs|termbin\.com)/[A-Za-z0-9]+$ ]]
}

# ----------------------------------------------------------------------------
# Log collection
# ----------------------------------------------------------------------------
DIAG_CEF_CAP="${DIAG_CEF_CAP:-262144}"   # tail cap for cef_log (Chromium noise)
DIAG_MAX_BYTES="${DIAG_MAX_BYTES:-900000}" # paste.rs ~1 MiB upload ceiling

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

# Scrub a source log into the staging dir. With cap>0 only the trailing cap
# bytes are kept (used to bound cef_log, and to shrink the whole bundle if it
# exceeds the paste size limit). No-op when the source is absent/unreadable.
_stage_file() { # $1 stage-dir  $2 dest-relpath  $3 src  $4 cap(bytes,0=full)
	local stage="$1" dest="$2" src="$3" cap="${4:-0}"
	[ -f "$src" ] && [ -r "$src" ] || return 0
	mkdir -p "$stage/$(dirname "$dest")"
	if [ "$cap" -gt 0 ]; then
		tail -c "$cap" "$src" 2>/dev/null | scrub > "$stage/$dest"
	else
		scrub < "$src" > "$stage/$dest"
	fi
}

DIAG_STAGE=""   # current staging dir (for cleanup on interrupt)

# Build the diagnostics tarball at $1. $2 = global tail cap in bytes (0 = full
# logs, cef_log still capped). Only explicit log files are read — never whole
# config dirs (CloudRedirect holds OAuth tokens; Lumen holds a session token).
collect() {
	local outtar="$1" cap="${2:-0}"
	local stage; stage="$(mktemp -d "${TMPDIR:-/tmp}/luatools-diag.XXXXXX")" || return 1
	DIAG_STAGE="$stage"

	local sr; sr="$(steam_root)"

	# Summary header (scrubbed).
	{
		printf 'luatools-moon diagnostics\n'
		printf 'date(utc): %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
		printf 'kernel: %s   arch: %s\n' "$(uname -r 2>/dev/null)" "$(uname -m 2>/dev/null)"
		if [ -r /etc/os-release ]; then
			# shellcheck disable=SC1091
			( . /etc/os-release >/dev/null 2>&1; printf 'distro: %s %s\n' "${ID:-?}" "${VERSION_ID:-}" )
		fi
		printf 'steam_root: %s\n' "${sr:-NOT FOUND}"
		printf 'components:'
		{ [ -d "$HOME/.local/share/Lumen" ] || [ -f "$HOME/.lumen.log" ]; } && printf ' lumen'
		{ [ -d "$HOME/.millennium" ] || [ -d "$HOME/.local/share/millennium" ]; } && printf ' millennium'
		[ -d "$HOME/.config/CloudRedirect" ] && printf ' cloudredirect'
		[ -f "$HOME/.SLSsteam.log" ] && printf ' slsteam'
		printf '\n'
		[ "$cap" -gt 0 ] && printf 'note: logs tail-capped to %d bytes to fit the upload limit\n' "$cap"
	} | scrub > "$stage/summary.txt"

	# Stack logs (complete unless a global cap is in force).
	_stage_file "$stage" "slsteam.log"        "$HOME/.SLSsteam.log"                  "$cap"
	_stage_file "$stage" "slsteam-config.yaml" "$HOME/.config/SLSsteam/config.yaml"  "$cap"
	_stage_file "$stage" "lumen.log"          "$HOME/.lumen.log"                     "$cap"
	_stage_file "$stage" "cloudredirect-cr_debug.log"     "$HOME/.config/CloudRedirect/cr_debug.log"     "$cap"
	_stage_file "$stage" "cloudredirect-cloud_redirect.log" "$HOME/.config/CloudRedirect/cloud_redirect.log" "$cap"

	# Steam's own logs directory — complete, except cef_log which is always
	# tail-capped (the global cap, if any, only tightens it further).
	if [ -n "$sr" ] && [ -d "$sr/logs" ]; then
		local f base fcap
		for f in "$sr"/logs/*; do
			[ -f "$f" ] || continue
			base="$(basename "$f")"
			fcap="$cap"
			case "$base" in
				cef_log*)
					if [ "$cap" -gt 0 ] && [ "$cap" -lt "$DIAG_CEF_CAP" ]; then fcap="$cap"
					else fcap="$DIAG_CEF_CAP"; fi ;;
			esac
			_stage_file "$stage" "steam-logs/$base" "$f" "$fcap"
		done
	fi

	# Millennium line (fallback branch) — best-effort glob of its log dirs.
	local g
	for g in "$HOME"/.millennium/*.log \
	         "$HOME"/.millennium/logs/*.log \
	         "$HOME"/.local/share/millennium/*.log \
	         "$HOME"/.local/share/millennium/logs/*.log; do
		[ -f "$g" ] || continue
		_stage_file "$stage" "millennium/$(basename "$g")" "$g" "$cap"
	done

	tar -czf "$outtar" -C "$stage" . 2>/dev/null
	local rc=$?
	rm -rf "$stage"; DIAG_STAGE=""
	return $rc
}

# ----------------------------------------------------------------------------
# Upload — paste.rs (curl) primary, termbin (bash /dev/tcp) fallback.
# Echoes a VALIDATED url on success; returns 1 if both sinks fail.
# ----------------------------------------------------------------------------

# paste.rs: only a 201 (whole paste stored) is accepted. 206 (partial / too
# big) is rejected so the caller can shrink and retry rather than serve a
# truncated tarball.
_paste_rs_upload() { # $1 file -> validated url (201 only)
	command -v curl >/dev/null 2>&1 || return 1
	local file="$1" body code
	body="$(mktemp "${TMPDIR:-/tmp}/luatools-diag.XXXXXX")" || return 1
	code="$(curl -sS --max-time 60 --data-binary @"$file" https://paste.rs/ \
		-o "$body" -w '%{http_code}' 2>/dev/null || echo 000)"
	local url; url="$(cat "$body" 2>/dev/null)"; rm -f "$body"
	[ "$code" = "201" ] && validate_paste_url "$url" && { printf '%s' "$url"; return 0; }
	return 1
}

_termbin_upload() { # $1 file -> validated url
	local file="$1" resp
	exec 3<>/dev/tcp/termbin.com/9999 || return 1
	cat "$file" >&3
	resp="$(cat <&3)"
	exec 3>&- 2>/dev/null || true
	resp="$(printf '%s' "$resp" | tr -d '\000\r\n')"
	validate_paste_url "$resp" && { printf '%s' "$resp"; return 0; }
	return 1
}

upload() { # $1 file -> validated url
	local file="$1" url
	if url="$(_paste_rs_upload "$file")"; then printf '%s\n' "$url"; return 0; fi
	if url="$(_termbin_upload "$file" 2>/dev/null)"; then printf '%s\n' "$url"; return 0; fi
	return 1
}

# ----------------------------------------------------------------------------
# main — collect, upload, print ONLY the link.
# ----------------------------------------------------------------------------
DIAG_TMP=""
_diag_cleanup() {
	rm -f "${DIAG_TMP:-}" 2>/dev/null || true
	[ -n "${DIAG_STAGE:-}" ] && rm -rf "${DIAG_STAGE}" 2>/dev/null || true
}

main() {
	local url cap
	trap _diag_cleanup EXIT
	DIAG_TMP="$(mktemp "${TMPDIR:-/tmp}/luatools-diag.XXXXXX")" \
		|| { echo "diag: cannot create a temporary file" >&2; exit 1; }

	# Build the complete bundle; shrink with progressively tighter caps only if
	# it exceeds the paste size limit (keeps logs complete in the common case).
	collect "$DIAG_TMP" 0
	for cap in 524288 131072; do
		[ "$(wc -c < "$DIAG_TMP" 2>/dev/null || echo 0)" -le "$DIAG_MAX_BYTES" ] && break
		collect "$DIAG_TMP" "$cap"
	done

	if [ ! -s "$DIAG_TMP" ]; then
		echo "diag: no logs found to collect" >&2
		exit 1
	fi

	if url="$(upload "$DIAG_TMP")"; then
		printf '%s\n' "$url"
	else
		echo "diag: upload failed (paste.rs and termbin both unreachable, or bundle too large)" >&2
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
