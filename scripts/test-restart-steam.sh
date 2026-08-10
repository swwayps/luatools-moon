#!/usr/bin/env bash
# Unit test for plugin/backend/scripts/restart_steam.sh strategy selection.
#
# Why this exists
# ---------------
# The "Restart Steam" button must pick the RIGHT restart strategy per session:
#   - SteamOS Game Mode: Steam is its own user unit (steam-launcher.service),
#     separate from the gamescope compositor (gamescope-session.service, which
#     is RefuseManualStart=yes -> cannot be restarted; restarting it did
#     nothing, the reported bug). Restart steam-launcher.service.
#   - Bazzite/ChimeraOS Game Mode: Steam is supervised by a gamescope-session*
#     service (e.g. gamescope-session-plus@steam.service). Restart that.
#   - Desktop: no active session unit -> kill + relaunch via the wrapper.
#
# The script exposes a dry-run seam (SLS_RESTART_DRYRUN=1) that prints the
# chosen action and exits BEFORE touching the running Steam, so we can pin the
# decision against a fake `systemctl` on PATH (runs on any host).
#
# Run: bash scripts/test-restart-steam.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTART_SH="$SCRIPT_DIR/../plugin/backend/scripts/restart_steam.sh"

failures=0
check() { # $1 desc  $2 actual  $3 expected
	if [ "$2" = "$3" ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s (got "%s", want "%s")\n' "$1" "$2" "$3"; failures=$((failures+1)); fi
}

TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# --- fake systemctl on PATH -------------------------------------------------
FAKEBIN="$TESTDIR/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
# Minimal systemctl stand-in driven by $FAKE_MODE.
mode="${FAKE_MODE:-none}"
is_active=0; list_units=0
for a in "$@"; do
	[ "$a" = "is-active" ] && is_active=1
	[ "$a" = "list-units" ] && list_units=1
done
if [ "$is_active" = 1 ]; then
	# `systemctl --user is-active --quiet steam-launcher.service`
	case "$mode" in
		steamos) for a in "$@"; do [ "$a" = "steam-launcher.service" ] && exit 0; done; exit 3 ;;
		*) exit 3 ;;
	esac
fi
if [ "$list_units" = 1 ]; then
	case "$mode" in
		bazzite) echo "gamescope-session-plus@steam.service loaded active running Gamescope" ;;
		*) : ;;  # none active
	esac
	exit 0
fi
exit 0
FAKE
chmod +x "$FAKEBIN/systemctl"

run_restart() { # $1 FAKE_MODE  -> echoes the script's dry-run decision
	FAKE_MODE="$1" SLS_RESTART_DRYRUN=1 HOME="$TESTDIR/home" \
		PATH="$FAKEBIN:$PATH" bash "$RESTART_SH" 2>/dev/null
}

# --- SteamOS: steam-launcher.service active -> restart THAT -----------------
out="$(run_restart steamos)"
check "SteamOS -> restarts steam-launcher.service" "$out" "unit:steam-launcher.service"

# --- Bazzite: gamescope-session-plus@steam active -> restart THAT -----------
out="$(run_restart bazzite)"
check "Bazzite -> restarts the gamescope-session unit" "$out" "unit:gamescope-session-plus@steam.service"

# --- Desktop: nothing active -> fall through to wrapper relaunch -------------
mkdir -p "$TESTDIR/home/.local/share/SLSsteam/path"
: > "$TESTDIR/home/.local/share/SLSsteam/path/steam"
chmod +x "$TESTDIR/home/.local/share/SLSsteam/path/steam"
out="$(run_restart none)"
check "Desktop -> relaunches via the slsteam-moon wrapper" \
	"$out" "desktop:$TESTDIR/home/.local/share/SLSsteam/path/steam"

# --- Desktop: refuse relaunch while the old steam.sh wrapper remains ---------
EVENTS="$TESTDIR/events"
STATE="$TESTDIR/steam-alive"
STEAM_SH_STATE="$TESTDIR/steamsh-alive"
LOGGER_STATE="$TESTDIR/logger-alive"
LAUNCH_MARKER="$TESTDIR/launched"
: > "$EVENTS"
printf '%s\n' alive > "$STEAM_SH_STATE"
cat > "$FAKEBIN/steam" <<'FAKE'
#!/usr/bin/env bash
printf 'steam %s\n' "$*" >> "$TEST_EVENTS"
exit 0
FAKE
chmod +x "$FAKEBIN/steam"
cat > "$FAKEBIN/pgrep" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = -x ] && [ "${2:-}" = steam ]; then
	[ -e "${TEST_STATE:-}" ] && exit 0 || exit 1
fi
if [ "${1:-}" = -f ]; then
	case "${2:-}" in
		*'/steam.sh'*) [ -e "${TEST_STEAM_SH_STATE:-}" ] && exit 0 || exit 1 ;;
		*srt-logger*console-linux.txt*) exit 1 ;;
		*srt-logger*) [ -e "${TEST_LOGGER_STATE:-}" ] && exit 0 || exit 1 ;;
		*steamwebhelper*) exit 1 ;;
	esac
fi
exit 1
FAKE
chmod +x "$FAKEBIN/pgrep"
cat > "$FAKEBIN/pkill" <<'FAKE'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >> "$TEST_EVENTS"
exit 0
FAKE
chmod +x "$FAKEBIN/pkill"
cat > "$FAKEBIN/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$FAKEBIN/sleep"
cat > "$TESTDIR/home/.local/share/SLSsteam/path/steam" <<'FAKE'
#!/usr/bin/env bash
touch "$TEST_LAUNCH_MARKER"
FAKE
chmod +x "$TESTDIR/home/.local/share/SLSsteam/path/steam"
if FAKE_MODE=none HOME="$TESTDIR/home" PATH="$FAKEBIN:$PATH" \
	TEST_EVENTS="$EVENTS" TEST_STATE="$STATE" \
	TEST_STEAM_SH_STATE="$STEAM_SH_STATE" TEST_LOGGER_STATE="$LOGGER_STATE" \
	TEST_LAUNCH_MARKER="$LAUNCH_MARKER" \
	bash "$RESTART_SH"; then
	printf 'FAIL: restart relaunched while steam.sh remained alive\n'
	failures=$((failures+1))
else
	printf 'ok:   restart refuses a residual steam.sh process\n'
fi
if [ -e "$LAUNCH_MARKER" ]; then
	printf 'FAIL: residual steam.sh path launched a new client\n'
	failures=$((failures+1))
else
	printf 'ok:   residual steam.sh path does not launch Steam\n'
fi

# The logger command line is not required to include console-linux.txt.
rm -f "$STEAM_SH_STATE" "$LAUNCH_MARKER"
printf '%s\n' alive > "$LOGGER_STATE"
if FAKE_MODE=none HOME="$TESTDIR/home" PATH="$FAKEBIN:$PATH" \
	TEST_EVENTS="$EVENTS" TEST_STATE="$STATE" \
	TEST_STEAM_SH_STATE="$STEAM_SH_STATE" TEST_LOGGER_STATE="$LOGGER_STATE" \
	TEST_LAUNCH_MARKER="$LAUNCH_MARKER" \
	bash "$RESTART_SH"; then
	printf 'FAIL: restart relaunched while srt-logger remained alive\n'
	failures=$((failures+1))
else
	printf 'ok:   restart refuses a residual srt-logger process\n'
fi
if [ -e "$LAUNCH_MARKER" ]; then
	printf 'FAIL: residual srt-logger path launched a new client\n'
	failures=$((failures+1))
else
	printf 'ok:   residual srt-logger path does not launch Steam\n'
fi

BUNDLE="$SCRIPT_DIR/../dist/luatools-linux.zip"
if [ ! -f "$BUNDLE" ] || ! unzip -p "$BUNDLE" backend/scripts/restart_steam.sh \
	| cmp -s - "$RESTART_SH"; then
	printf 'FAIL: packaged LuaTools restart helper differs from the source helper\n'
	failures=$((failures+1))
else
	printf 'ok:   packaged LuaTools restart helper matches the source\n'
fi

if [ "$failures" -eq 0 ]; then echo; echo "ALL PASS"; exit 0; fi
echo; echo "$failures CHECK(S) FAILED"; exit 1
