#!/usr/bin/env bash
# ============================================================================
#  luatools-moon — diagnostics collector
# ============================================================================
#  Gathers the stack's logs, strips person-identifying data, bundles them into
#  a .tar.gz and uploads the bundle to a public paste, printing ONLY the link.
#
#    curl -fsSL https://raw.githubusercontent.com/swwayps/luatools-moon/main/diagnose.sh | bash
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
#    run). The bundle is uploaded to a binary-capable file host (uguu.se, which
#    auto-expires in ~3h, with catbox.moe as fallback) so complete,
#    possibly-large logs survive intact.
#  - Privacy: every archived log is filtered by scrub() before it leaves the
#    machine. Person-identifying data is masked (home/username, Steam account
#    id, SteamID64, email, IPv4, Steam CM region); technically useful, non-PII
#    fields (appids, depot ids, manifest gids, build ids, hashes) are kept.
#    Exception: Steam crash minidumps (/tmp/dumps/*.dmp, staged under
#    steam-dumps/, newest few, size-capped) are binary memory snapshots —
#    byte-shifting sed substitutions would corrupt their internal offsets, so
#    they are archived AS-IS and may hold arbitrary Steam process memory. The
#    per-user *_stdout.txt companion IS scrubbed and renamed to stdout.txt
#    (its original filename embeds the Linux username).
#  - Secrets are NEVER collected: OAuth tokens in ~/.config/CloudRedirect, the
#    Lumen per-boot RPC token (session.json), etc. Only explicit log files are
#    read.
#  - Crash triage artifacts (added because a client that aborts BEFORE breakpad
#    installs leaves no minidump at all, so steam-dumps/ is empty and the crash
#    is otherwise only findable by hand in a multi-MB console log):
#      * slsteam-guard.txt / slsteam-guard.log — the wrapper's crash-loop
#        fail-safe state and log; tells whether safe mode latched and why not.
#      * steam-client-crashes.txt — the steam.sh job-status lines for abnormal
#        client exits, matched on the literal "$STEAMROOT/$STEAMEXEPATH" so the
#        signal survives localization (pt-BR says "Abortado", not "Aborted").
#      * steam-coredumps.txt — coredumpctl/coredump-dir INVENTORY for the Steam
#        client only. Core bodies are never collected: they are whole-process
#        memory snapshots and can be hundreds of MB.
#      * launch-coverage.txt now also reports which launcher the wrapper would
#        actually exec, for BOTH entry points (a .desktop calling the wrapper
#        directly vs. the system-launcher shim), plus whether they diverge.
#  - Logs are archived COMPLETE, except cef_log (Chromium noise) which is
#    tail-capped so a multi-MB file can't bloat the upload.
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
# validate_paste_url : 0 iff $1 is a clean, known-shape file-host URL.
#
# The sink's response is attacker-controllable if the sink is hijacked, so the
# returned link is treated as inert: only an exact catbox / uguu file URL is
# accepted. Whitespace, control/ANSI bytes, shell metacharacters, a foreign
# host or extra text are rejected. The caller never eval's it and prints it
# with printf %s.
# ----------------------------------------------------------------------------
validate_paste_url() {
	local u="${1-}"
	case "$u" in
		*[[:space:]]*) return 1 ;;
	esac
	[[ "$u" =~ ^https://(files\.catbox\.moe|[a-z]\.uguu\.se)/[A-Za-z0-9._-]+$ ]]
}

# ----------------------------------------------------------------------------
# Log collection
# ----------------------------------------------------------------------------
DIAG_CEF_CAP="${DIAG_CEF_CAP:-262144}"   # tail cap for cef_log (Chromium noise)
DIAG_MAX_BYTES="${DIAG_MAX_BYTES:-94371840}" # 90 MiB safety ceiling; catbox/uguu handle large files, so logs stay complete

# The desktop-coverage guardian appends on every launch and every re-assert, so
# its log grows without bound (~1 MB after a few weeks). Always tail-capped.
DIAG_GUARDIAN_CAP="${DIAG_GUARDIAN_CAP:-262144}"
# How many abnormal-client-exit lines to distil out of the Steam console logs.
DIAG_CRASH_LINES="${DIAG_CRASH_LINES:-60}"

# Crash-dump bounds: stage at most the newest DIAG_DUMP_MAX minidumps, each at
# most DIAG_DUMP_MAX_BYTES (12 MiB), so a bundle can't blow past the safety
# ceiling on dumps alone (worst case ~48 MiB + capped logs < 90 MiB).
DIAG_DUMP_MAX="${DIAG_DUMP_MAX:-4}"
DIAG_DUMP_MAX_BYTES="${DIAG_DUMP_MAX_BYTES:-12582912}"
# ':'-separated dump search dirs (Steam writes crash minidumps to /tmp/dumps;
# overridable so the staging logic is unit-testable with fixtures).
DIAG_DUMP_DIRS="${DIAG_DUMP_DIRS:-/tmp/dumps:/var/tmp/dumps}"

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
# exceeds the safety ceiling). No-op when the source is absent/unreadable.
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

# Collect EVERY *steam*.desktop launcher anywhere on the machine (patched AND
# unpatched — a stray launcher install.sh never touched is exactly what we want
# to see) into one scrubbed file, each entry wrapped in BEGIN/END separators
# that name its source path (the header is scrubbed too, so the home/username
# never leaks).
#
# The search walks the whole filesystem from '/', pruning pseudo/virtual mounts
# (/proc, /sys, /dev, /run) for speed and to avoid noise, and is wrapped in a
# timeout so a pathological disk can't hang the run. Search roots and the
# per-root find depth are overridable for tests via DIAG_DESKTOP_DIRS (a
# ':'-separated list) and DIAG_DESKTOP_MAXDEPTH.
# $1 stage-dir  $2 cap(bytes,0=full).
_collect_desktops() {
	local stage="$1" cap="${2:-0}"
	local dest="$stage/steam-desktops.txt"

	local -a roots=()
	if [ -n "${DIAG_DESKTOP_DIRS:-}" ]; then
		local IFS=':'; read -r -a roots <<< "$DIAG_DESKTOP_DIRS"
	else
		roots=("/")
	fi

	# find prelude: prune pseudo-filesystems (only meaningful for a '/' walk).
	local -a prune=( '(' -path /proc -o -path /sys -o -path /dev -o -path /run ')' -prune -o )
	local -a depth=()
	[ -n "${DIAG_DESKTOP_MAXDEPTH:-}" ] && depth=( -maxdepth "$DIAG_DESKTOP_MAXDEPTH" )
	# Bound the walk so a huge/slow disk can't stall the diagnostic.
	local -a to=()
	command -v timeout >/dev/null 2>&1 && to=( timeout "${DIAG_DESKTOP_TIMEOUT:-90}" )

	local raw; raw="$(mktemp "${TMPDIR:-/tmp}/luatools-diag-desk.XXXXXX")" || return 0
	local -A seen=()
	local found=0 r f rp
	for r in "${roots[@]}"; do
		[ -d "$r" ] || continue
		while IFS= read -r -d '' f; do
			rp="$(readlink -f -- "$f" 2>/dev/null || printf '%s' "$f")"
			[ -n "${seen[$rp]:-}" ] && continue
			seen[$rp]=1
			[ -r "$f" ] || continue
			found=1
			{
				printf '===== BEGIN %s =====\n' "$f"
				if [ "$cap" -gt 0 ]; then tail -c "$cap" -- "$f" 2>/dev/null
				else cat -- "$f" 2>/dev/null; fi
				printf '\n===== END %s =====\n\n' "$f"
			} >> "$raw"
		done < <("${to[@]}" find "$r" "${depth[@]}" "${prune[@]}" \
			-iname '*steam*.desktop' -type f -print0 2>/dev/null)
	done

	[ "$found" -eq 1 ] && scrub < "$raw" > "$dest"
	rm -f "$raw"
}

# Resolve the persisted launch-coverage policy without sourcing installer code.
# Relative XDG_STATE_HOME values intentionally fall back to the conventional
# per-user state directory, matching install.sh's reporting behavior.
_diag_state_home() {
	case "${XDG_STATE_HOME:-}" in
		/*) printf '%s\n' "$XDG_STATE_HOME" ;;
		*)  printf '%s/.local/state\n' "$HOME" ;;
	esac
}

_diag_effective_policy() {
	local policy="${SLSM_COVERAGE_POLICY-}" policy_file status_file
	# Match dc_read_policy/install_coverage_policy: an explicit non-empty
	# override is authoritative, including an invalid value falling back to
	# desktop rather than consulting stale persisted state.
	if [ -n "$policy" ]; then
		case "$policy" in
			launcher|desktop) printf '%s\n' "$policy" ;;
			*)                 printf 'desktop\n' ;;
		esac
		return 0
	fi

	# setup.sh writes this marker when policy persistence fails. Its presence
	# means the effective runtime fallback is desktop, even if an older state
	# file still says launcher.
	status_file="${DIAG_POLICY_STATUS_FILE:-$HOME/.local/share/SLSsteam/coverage-policy.effective}"
	if [ -e "$status_file" ] || [ -L "$status_file" ]; then
		printf 'desktop\n'
		return 0
	fi

	policy_file="${DIAG_POLICY_FILE:-$(_diag_state_home)/slsteam-moon/coverage.policy}"
	if cmp -s "$policy_file" <(printf 'launcher\n'); then
		printf 'launcher\n'
	elif cmp -s "$policy_file" <(printf 'desktop\n'); then
		printf 'desktop\n'
	else
		printf 'desktop\n'
	fi
}

_diag_launcher_dirs() {
	local value="${DIAG_LAUNCHER_DIRS:-/usr/bin:/usr/games:/usr/local/bin}" d
	while [ -n "$value" ]; do
		case "$value" in
			*:*) d="${value%%:*}"; value="${value#*:}" ;;
			*)   d="$value"; value= ;;
		esac
		[ -n "$d" ] && printf '%s\n' "$d"
	d=''
	done
}

# The wrapper walks its candidate launchers in a FIXED order and takes the first
# hit, so the order decides which launcher a launch actually gets. Mirror the
# wrapper's order here (it differs from the inventory order above, where order is
# irrelevant). Tests drive both through the same DIAG_LAUNCHER_DIRS knob.
_diag_wrapper_launcher_dirs() {
	if [ -n "${DIAG_LAUNCHER_DIRS:-}" ]; then
		_diag_launcher_dirs
		return 0
	fi
	printf '/usr/games\n/usr/bin\n/usr/local/bin\n'
}

# Read the first 3 lines only — enough for the shim tag, and it keeps launcher
# bodies (package scripts, possibly with tokens) out of the collector.
_diag_is_shim() {
	[ -f "$1" ] && head -3 "$1" 2>/dev/null | grep -qF '# slsteam-moon system launcher shim'
}

_diag_is_wrapper() {
	[ -f "$1" ] && head -3 "$1" 2>/dev/null | grep -qF '# slsteam-moon wrapper'
}

# Valve's launcher refuses to run as anything but `steam`, so a shim is only
# fully operational when a `steam`-named alias for the captured original exists.
# Derived from paths (never by reading a launcher body). Echoes "<alias>\t<status>";
# status is ready or missing.
_diag_shim_exec_alias() { # $1 backup-root  $2 launcher-path
	local backup_root="$1" launcher="$2" alias candidate target
	alias="${backup_root%/}/${launcher#/}"
	alias="${alias%/*}/steam"
	for candidate in "$alias" "${backup_root%/}/steam"; do
		[ -x "$candidate" ] || continue
		target="$(readlink -f "$candidate" 2>/dev/null || true)"
		case "$target" in
			"${backup_root%/}"/*.orig)
				printf '%s\tready' "$candidate"
				return 0
				;;
		esac
	done
	printf '%s\tmissing' "$alias"
}

# Steam's own bootstrap script, the wrapper's last-resort launcher.
_diag_steam_sh_fallback() {
	local c
	for c in "$HOME/.local/share/Steam/steam.sh" \
	         "$HOME/.steam/steam/steam.sh" \
	         "$HOME/.steam/debian-installation/steam.sh"; do
		[ -x "$c" ] && { printf '%s' "$c"; return 0; }
	done
	printf ''
}

# What the wrapper would exec when it is entered DIRECTLY (every patched
# .desktop does that). Read-only mirror of the wrapper's own resolution: it
# skips itself and skips our shim, so where the shim is the only system launcher
# the chain falls through to steam.sh — a different launcher than the shim path
# hands over. Echoes "<path>\t<via>"; via is system-launcher, path,
# path-wrapper-loop, steam-sh-fallback or none. Fields are tab-separated and
# never empty ('none' is the placeholder): a leading tab would be eaten by
# `read`, silently shifting via into path.
_diag_wrapper_direct_target() { # $1 wrapper-path
	local wrapper="$1" self d c p ifs_save
	self="$(readlink -f "$wrapper" 2>/dev/null || printf '%s' "$wrapper")"

	while IFS= read -r d; do
		[ -n "$d" ] || continue
		c="${d%/}/steam"
		[ -x "$c" ] || continue
		[ "$(readlink -f "$c" 2>/dev/null || printf '%s' "$c")" = "$self" ] && continue
		_diag_is_shim "$c" && continue
		printf '%s\tsystem-launcher' "$c"
		return 0
	done < <(_diag_wrapper_launcher_dirs)

	ifs_save="$IFS"
	IFS=:
	for p in ${PATH:-}; do
		IFS="$ifs_save"
		[ -n "$p" ] || continue
		c="$p/steam"
		[ -x "$c" ] || continue
		[ "$(readlink -f "$c" 2>/dev/null || printf '%s' "$c")" = "$self" ] && continue
		_diag_is_shim "$c" && continue
		# The wrapper only skips ITSELF, so a second wrapper on PATH (a stale or
		# duplicate install) is a launcher it would really exec — reported as a
		# distinct verdict rather than presented as a normal target.
		if _diag_is_wrapper "$c"; then
			printf '%s\tpath-wrapper-loop' "$c"
		else
			printf '%s\tpath' "$c"
		fi
		return 0
	done
	IFS="$ifs_save"

	c="$(_diag_steam_sh_fallback)"
	[ -n "$c" ] && { printf '%s\tsteam-sh-fallback' "$c"; return 0; }
	printf 'none\tnone'
}

# What the wrapper would exec when the system-launcher SHIM invoked it: the shim
# exports SLSM_STEAM_BIN pointing at its captured original's `steam`-named alias.
# Echoes "<path>\t<via>"; via is shim-backup or unavailable.
_diag_wrapper_shim_target() { # $1 backup-root
	local backup_root="$1" d c alias status
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		c="${d%/}/steam"
		_diag_is_shim "$c" || continue
		IFS=$'\t' read -r alias status <<<"$(_diag_shim_exec_alias "$backup_root" "$c")"
		[ "$status" = ready ] || continue
		printf '%s\tshim-backup' "$alias"
		return 0
	done < <(_diag_wrapper_launcher_dirs)
	printf 'none\tunavailable'
}

# Inventory system launchers and backup paths only. The collector never reads a
# launcher or backup body, so package scripts and any accidental tokens in those
# files cannot enter the diagnostic archive.
_collect_launch_coverage() {
	local stage="$1" dest="$stage/launch-coverage.txt" raw
	local dir launcher status found=0 backup_root backup found_backup=0
	local exec_alias exec_status
	local wrapper direct_path direct_via shim_path shim_via
	raw="$(mktemp "${TMPDIR:-/tmp}/luatools-diag-coverage.XXXXXX" 2>/dev/null || true)"
	[ -n "$raw" ] || return 0
	backup_root="${DIAG_LAUNCHER_BACKUP_ROOT:-$HOME/.local/share/SLSsteam/system-launcher-backup}"
	wrapper="${DIAG_WRAPPER:-$HOME/.local/share/SLSsteam/path/steam}"
	{
		printf 'effective policy: %s\n' "$(_diag_effective_policy)"
		while IFS= read -r dir; do
			[ -n "$dir" ] || continue
			launcher="${dir%/}/steam"
			[ -f "$launcher" ] || continue
			found=1
			if head -3 "$launcher" 2>/dev/null | grep -qF '# slsteam-moon system launcher shim'; then
				status=shim
			else
				status=vanilla
			fi
			printf 'system launcher: %s status=%s\n' "$launcher" "$status"
			[ "$status" = shim ] || continue
			# Reported because the alias's absence is invisible otherwise: the
			# launch then dies before Steam writes any log.
			IFS=$'\t' read -r exec_alias exec_status \
				<<<"$(_diag_shim_exec_alias "$backup_root" "$launcher")"
			printf 'shim exec: %s status=%s\n' "$exec_alias" "$exec_status"
		done < <(_diag_launcher_dirs)
		[ "$found" -eq 1 ] || printf 'system launcher: none detected\n'

		if [ -d "$backup_root" ]; then
			while IFS= read -r -d '' backup; do
				found_backup=1
				if [ "$(dirname -- "$backup")" = "${backup_root%/}" ]; then
					printf 'backup: legacy %s\n' "$backup"
				else
					printf 'backup: mirrored %s\n' "$backup"
				fi
			done < <(find "$backup_root" -type f -name '*.orig' -print0 2>/dev/null | sort -z)
		fi
		[ "$found_backup" -eq 1 ] || printf 'backup: none detected\n'

		# Which launcher a launch actually reaches. The two entry points do not
		# have to agree: a patched .desktop calls the wrapper directly, whereas
		# the shim hands the wrapper its captured original in SLSM_STEAM_BIN. A
		# divergence here means "works from the terminal, dies from the icon"
		# class bugs, so it is stated explicitly instead of being inferred.
		if [ -x "$wrapper" ]; then
			printf 'wrapper: %s status=present\n' "$wrapper"
		else
			printf 'wrapper: %s status=missing\n' "$wrapper"
		fi
		IFS=$'\t' read -r direct_path direct_via <<<"$(_diag_wrapper_direct_target "$wrapper")"
		IFS=$'\t' read -r shim_path shim_via <<<"$(_diag_wrapper_shim_target "$backup_root")"
		printf 'launch target (desktop entry -> wrapper): %s via=%s\n' \
			"$direct_path" "$direct_via"
		printf 'launch target (system launcher shim -> wrapper): %s via=%s\n' \
			"$shim_path" "$shim_via"
		case "$direct_via" in
			path|path-wrapper-loop)
				printf 'launch target note: PATH-resolved with this shell PATH; a desktop-session launch can differ\n' ;;
		esac
		# Only comparable when BOTH entry points resolve to a real launcher.
		if [ "$direct_path" = none ] || [ "$shim_path" = none ]; then
			printf 'launch target divergence: unknown\n'
		elif [ "$(readlink -f "$direct_path" 2>/dev/null || printf '%s' "$direct_path")" \
		    = "$(readlink -f "$shim_path" 2>/dev/null || printf '%s' "$shim_path")" ]; then
			printf 'launch target divergence: no\n'
		else
			printf 'launch target divergence: yes\n'
		fi
	} > "$raw"
	scrub < "$raw" > "$dest"
	rm -f "$raw"
}

# ----------------------------------------------------------------------------
# Crash-loop fail-safe state (the wrapper's guard) + the desktop-coverage
# guardian log. The guard decides whether injection is paused for the session;
# when a crash class is invisible to it (e.g. an abort before breakpad installs,
# so no minidump is ever written) the user loops forever with no notice, and this
# is the only artifact that shows it.
# ----------------------------------------------------------------------------
_diag_guard_dir() {
	if [ -n "${DIAG_GUARD_DIR:-}" ]; then
		printf '%s\n' "$DIAG_GUARD_DIR"
		return 0
	fi
	printf '%s/slsteam-moon\n' "$(_diag_state_home)"
}

_collect_guard_state() { # $1 stage-dir  $2 cap(bytes,0=full)
	local stage="$1" cap="${2:-0}" gd raw now then_ts
	gd="$(_diag_guard_dir)"
	[ -d "$gd" ] || return 0

	# Logs. guardian.log is append-only and unbounded, so it is always capped.
	_stage_file "$stage" "slsteam-guard.log" "$gd/guard.log" "$cap"
	local gcap="$DIAG_GUARDIAN_CAP"
	[ "$cap" -gt 0 ] && [ "$cap" -lt "$gcap" ] && gcap="$cap"
	_stage_file "$stage" "slsteam-desktop-guardian.log" "$gd/guardian.log" "$gcap"

	raw="$(mktemp "${TMPDIR:-/tmp}/luatools-diag-guard.XXXXXX" 2>/dev/null || true)"
	[ -n "$raw" ] || return 0
	{
		if [ -e "$gd/safe_mode" ]; then
			printf 'safe_mode: latched\n'
		else
			printf 'safe_mode: not latched\n'
		fi
		printf 'safe_mode_fingerprint: %s\n' \
			"$([ -e "$gd/safe_mode_fingerprint" ] && echo present || echo absent)"
		printf 'boot_fail_count: %s\n' "$(cat "$gd/boot_fail_count" 2>/dev/null || echo absent)"

		# The guard resets its state when the machine session changes. Report
		# only whether the recorded session is the current one — the boot id
		# itself is a per-boot machine identifier and is never archived.
		local recorded current='' sid_file
		recorded="$(cat "$gd/session_id" 2>/dev/null || true)"
		sid_file="${DIAG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
		current="$(cat "$sid_file" 2>/dev/null || true)"
		if [ -z "$recorded" ]; then printf 'guard_session: absent\n'
		elif [ -z "$current" ]; then printf 'guard_session: unknown\n'
		elif [ "$recorded" = "$current" ]; then printf 'guard_session: current\n'
		else printf 'guard_session: stale (state will reset on next launch)\n'; fi

		# steamclient.so identity (size:mtime) of the last boot vs. the last one
		# that started cleanly. A mismatch is how the guard decides a startup
		# crash is a client-update compatibility break. Not person-identifying.
		printf 'last_client: %s\n' "$(cat "$gd/last_client" 2>/dev/null || echo absent)"
		printf 'good_client: %s\n' "$(cat "$gd/good_client" 2>/dev/null || echo absent)"
		printf 'last_launch_display: %s\n' \
			"$(cat "$gd/last_launch_display" 2>/dev/null || echo absent)"
		if [ -e "$gd/last_launch" ]; then
			now="$(date +%s 2>/dev/null || echo 0)"
			then_ts="$(stat -c %Y "$gd/last_launch" 2>/dev/null || echo 0)"
			if [ "$now" -gt 0 ] && [ "$then_ts" -gt 0 ]; then
				printf 'last_launch: %s seconds ago\n' "$(( now - then_ts ))"
			else
				printf 'last_launch: present (age unknown)\n'
			fi
		else
			printf 'last_launch: absent\n'
		fi
	} > "$raw"
	scrub < "$raw" > "$stage/slsteam-guard.txt"
	rm -f "$raw"
}

# ----------------------------------------------------------------------------
# Abnormal Steam-client exits, distilled from Steam's own console logs.
#
# steam.sh reports the client's death as a shell job-status line. The signal
# word is LOCALIZED ("Abortado (imagem do núcleo gravada)" in pt-BR), so the
# match is anchored on the literal command text bash echoes back —
# "$STEAMROOT/$STEAMEXEPATH" — plus steam.sh, which is locale-independent and
# excludes steam.sh's own debugger-echo lines.
#
# This matters because a client that dies before installing breakpad writes NO
# minidump: steam-dumps/ is empty and the only evidence is one line buried in a
# multi-MB console log.
# ----------------------------------------------------------------------------
_collect_client_crashes() { # $1 stage-dir  $2 steam-root -> echoes match count
	local stage="$1" sr="$2" raw f total=0 n
	[ -n "$sr" ] && [ -d "$sr/logs" ] || { printf 0; return 0; }
	raw="$(mktemp "${TMPDIR:-/tmp}/luatools-diag-crash.XXXXXX" 2>/dev/null || true)"
	[ -n "$raw" ] || { printf 0; return 0; }

	for f in "$sr/logs/console-linux.txt" "$sr/logs/console_log.txt" \
	         "$sr/logs/bootstrap_log.txt"; do
		[ -f "$f" ] && [ -r "$f" ] || continue
		n="$(grep -c -F -e '"$STEAMROOT/$STEAMEXEPATH"' -- "$f" 2>/dev/null || true)"
		case "$n" in ''|*[!0-9]*) n=0 ;; esac
		[ "$n" -eq 0 ] && continue
		{
			printf '===== %s =====\n' "$f"
			grep -F -e '"$STEAMROOT/$STEAMEXEPATH"' -- "$f" 2>/dev/null \
				| grep -F 'steam.sh' 2>/dev/null \
				| tail -n "$DIAG_CRASH_LINES" || true
			printf '\n'
		} >> "$raw"
		total=$(( total + n ))
	done

	[ -s "$raw" ] && scrub < "$raw" > "$stage/steam-client-crashes.txt"
	rm -f "$raw"
	printf '%s' "$total"
}

# ----------------------------------------------------------------------------
# Core-dump INVENTORY for the Steam client (ubuntu12_32/steam and friends).
#
# Bodies are never collected: a core is a whole-process memory snapshot, easily
# hundreds of MB, and would carry arbitrary Steam process memory off the machine.
# The inventory is what the triage needs — it proves a real fault happened and
# gives the pid to hand to `coredumpctl info`, which the user runs locally.
# ----------------------------------------------------------------------------
_collect_client_coredumps() { # $1 stage-dir
	local stage="$1" raw cdctl dumpdir found=0
	raw="$(mktemp "${TMPDIR:-/tmp}/luatools-diag-core.XXXXXX" 2>/dev/null || true)"
	[ -n "$raw" ] || return 0

	cdctl="${DIAG_COREDUMPCTL:-$(command -v coredumpctl 2>/dev/null || true)}"
	if [ -n "$cdctl" ] && [ -x "$cdctl" ]; then
		# COLUMNS must be wide or systemd ellipsizes the EXE column and the
		# filter below stops matching. Pager/colour off for a parseable stream.
		if COLUMNS=1000 SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat \
			"$cdctl" list --no-pager 2>/dev/null \
			| grep -F 'ubuntu12_' >> "$raw"; then
			found=1
		fi
		[ "$found" -eq 1 ] || printf 'coredumpctl: no Steam client coredumps recorded\n' >> "$raw"
	else
		printf 'coredumpctl: not available\n' >> "$raw"
	fi

	# Filename-only fallback for images without systemd-coredump journalling.
	# Names encode exe, uid, pid and timestamp — no body is read.
	dumpdir="${DIAG_COREDUMP_DIR:-/var/lib/systemd/coredump}"
	if [ -d "$dumpdir" ] && [ -r "$dumpdir" ]; then
		find "$dumpdir" -maxdepth 1 -name 'core.steam*' -printf 'coredump file: %f (%s bytes)\n' \
			2>/dev/null | sort >> "$raw" || true
	fi

	[ -s "$raw" ] && scrub < "$raw" > "$stage/steam-coredumps.txt"
	rm -f "$raw"
}

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
		# Detect the PAYLOAD too, not just its config dir: the hook is installed
		# under ~/.local/share and only writes ~/.config/CloudRedirect once it has
		# been set up, so a config-only probe reports an installed hook as absent.
		{ [ -d "$HOME/.config/CloudRedirect" ] \
			|| [ -f "$HOME/.local/share/CloudRedirect/cloud_redirect.so" ]; } \
			&& printf ' cloudredirect'
		[ -f "$HOME/.SLSsteam.log" ] && printf ' slsteam'
		printf '\n'
		[ "$cap" -gt 0 ] && printf 'note: logs tail-capped to %d bytes to fit the upload limit\n' "$cap"
	} | scrub > "$stage/summary.txt"

	# Stack logs (complete unless a global cap is in force).
	_stage_file "$stage" "slsteam.log"        "$HOME/.SLSsteam.log"                  "$cap"
	_stage_file "$stage" "slsteam-config.yaml" "$HOME/.config/SLSsteam/config.yaml"  "$cap"
	_stage_file "$stage" "lumen.log"          "$HOME/.lumen.log"                     "$cap"

	# Steam .desktop launchers — every *steam*.desktop across the standard XDG
	# app/autostart dirs (shows the LD_AUDIT wrapper Exec line, key for launch
	# issues), bundled into one scrubbed file with per-file BEGIN/END separators.
	_collect_desktops "$stage" "$cap"
	_collect_launch_coverage "$stage"
	_collect_guard_state "$stage" "$cap"
	_collect_client_coredumps "$stage"
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

	# Steam crash minidumps (/tmp/dumps — breakpad naming: crash_*.dmp for hard
	# crashes, assert_*.dmp for assertion failures). Archived AS-IS (binary;
	# scrubbing would corrupt them), newest DIAG_DUMP_MAX only, each truncated
	# to DIAG_DUMP_MAX_BYTES. Any *.dmp.upload is an unsent crash report in a
	# breakpad uploader envelope; stripping its header yields a plain .dmp.
	local d u i f b
	local IFS_SAVE="$IFS" IFS=':'
	# shellcheck disable=SC2086
	local dumps_found=0
	for d in $DIAG_DUMP_DIRS; do
		IFS="$IFS_SAVE"
		[ -d "$d" ] || continue
		u="$stage/steam-dumps/$(basename "$d")"
		mkdir -p "$u" || continue
		i=0
		# Newest first by mtime (find -printf %T@, sorted descending).
		while IFS= read -r f; do
			[ -f "$f" ] || continue
			b="$(basename "$f")"
			case "$b" in
				*.dmp)
					# Oversized dumps: keep the tail — minidump data is end-weighted.
					if [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -gt "$DIAG_DUMP_MAX_BYTES" ]; then
						tail -c "$DIAG_DUMP_MAX_BYTES" "$f" 2>/dev/null > "$u/$b"
					else
						cp -- "$f" "$u/$b" 2>/dev/null
					fi
					;;
				*.dmp.upload)
					# Drop the 8-byte breakpad upload header ('0' + little-endian size), cap the rest.
					dd if="$f" of="$u/${b%.upload}" bs=1 skip=8 count="$DIAG_DUMP_MAX_BYTES" 2>/dev/null || true
					;;
				*_stdout.txt)
					# Basename embeds the Linux username — stage as a constant name, scrubbed.
					_stage_file "$u" "stdout.txt" "$f" "$cap"
					;;
			esac
			dumps_found=$((dumps_found+1))
			i=$((i+1))
			[ "$i" -ge "$DIAG_DUMP_MAX" ] && break
		done < <(find "$d" -maxdepth 1 -type f \( -name '*.dmp' -o -name '*.dmp.upload' -o -name '*_stdout.txt' \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
	done
	# Surface dump availability in the summary so it's visible without unpacking.
	printf 'crash_dumps: %d file(s) staged under steam-dumps/\n' "$dumps_found" >> "$stage/summary.txt"

	# Abnormal client exits are counted in the summary too: a non-zero count with
	# crash_dumps: 0 is precisely the case the minidump-based crash guard cannot
	# see, and reading it off the summary saves a console-log dig.
	local crashes
	crashes="$(_collect_client_crashes "$stage" "$sr")"
	printf 'client_abnormal_exits: %s (see steam-client-crashes.txt)\n' \
		"${crashes:-0}" >> "$stage/summary.txt"

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
# Upload — uguu.se (auto-expires ~3h) primary, catbox.moe (reliable, permanent)
# fallback. Both accept binary and large files (unlike text pastebins).
# Echoes a VALIDATED url on success; returns 1 if both sinks fail.
# ----------------------------------------------------------------------------
_catbox_upload() { # $1 file -> validated url
	command -v curl >/dev/null 2>&1 || return 1
	local url
	url="$(curl -sS --max-time 120 -F 'reqtype=fileupload' \
		-F "fileToUpload=@$1;filename=luatools-logs.tar.gz" \
		https://catbox.moe/user/api.php 2>/dev/null | tr -d '\r\n')"
	validate_paste_url "$url" && { printf '%s' "$url"; return 0; }
	return 1
}

_uguu_upload() { # $1 file -> validated url
	command -v curl >/dev/null 2>&1 || return 1
	local raw url
	raw="$(curl -sS --max-time 120 -F "files[]=@$1;filename=luatools-logs.tar.gz" https://uguu.se/upload.php 2>/dev/null)"
	# Pull the JSON "url" value and unescape the \/ sequences.
	url="$(printf '%s' "$raw" \
		| sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		| sed 's#\\/#/#g' | tr -d '\r\n')"
	validate_paste_url "$url" && { printf '%s' "$url"; return 0; }
	return 1
}

upload() { # $1 file -> validated url
	local file="$1" url
	if url="$(_uguu_upload "$file")"; then printf '%s\n' "$url"; return 0; fi
	if url="$(_catbox_upload "$file")"; then printf '%s\n' "$url"; return 0; fi
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
	# it exceeds the safety ceiling (keeps logs complete in the common case).
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
		echo "diag: upload failed (uguu.se and catbox.moe both unreachable)" >&2
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
