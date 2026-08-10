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
# It also pins the desktop shutdown policy, which is latency-sensitive: the
# button is on the user's critical path, so the script may only wait on
# processes that can actually block a new client, and it must not ask a
# non-running Steam to shut down (that boots a whole bootstrapper and loses the
# clean-exit record, forcing the expensive startup verification).
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

# --- Desktop shutdown policy fakes ------------------------------------------
EVENTS="$TESTDIR/events"
CLIENT_STATE="$TESTDIR/steam-alive"
STEAM_SH_STATE="$TESTDIR/steamsh-alive"
LOGGER_STATE="$TESTDIR/logger-alive"
LAUNCH_MARKER="$TESTDIR/launched"

cat > "$FAKEBIN/steam" <<'FAKE'
#!/usr/bin/env bash
printf 'steam %s\n' "$*" >> "$TEST_EVENTS"
exit 0
FAKE
chmod +x "$FAKEBIN/steam"
cat > "$FAKEBIN/pgrep" <<'FAKE'
#!/usr/bin/env bash
# The client and the webhelper are keyed off one state file so a test can make
# Steam "refuse to die"; steam.sh and srt-logger have their own states so their
# presence can be asserted NOT to block the restart.
if [ "${1:-}" = -x ] && [ "${2:-}" = steam ]; then
	[ -e "${TEST_CLIENT_STATE:-}" ] && exit 0 || exit 1
fi
if [ "${1:-}" = -x ] && [ "${2:-}" = steamwebhelper ]; then
	exit 1
fi
if [ "${1:-}" = -f ]; then
	case "${2:-}" in
		*'/steam.sh'*) [ -e "${TEST_STEAM_SH_STATE:-}" ] && exit 0 || exit 1 ;;
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

run_desktop() { # runs the real shutdown+relaunch path against the fakes
	FAKE_MODE=none HOME="$TESTDIR/home" PATH="$FAKEBIN:$PATH" \
		TEST_EVENTS="$EVENTS" TEST_CLIENT_STATE="$CLIENT_STATE" \
		TEST_STEAM_SH_STATE="$STEAM_SH_STATE" TEST_LOGGER_STATE="$LOGGER_STATE" \
		TEST_LAUNCH_MARKER="$LAUNCH_MARKER" \
		bash "$RESTART_SH"
}

await_launch() { # the relaunch is detached; the faked sleep returns instantly
	local i
	for i in $(seq 1 40); do
		[ -e "$LAUNCH_MARKER" ] && return 0
		command sleep 0.05
	done
	[ -e "$LAUNCH_MARKER" ]
}

# --- A client that refuses to die blocks the restart ------------------------
# Starting a second client over a live one would have two clients racing the
# same install and config state.
rm -f "$LAUNCH_MARKER" "$STEAM_SH_STATE" "$LOGGER_STATE"
: > "$EVENTS"
printf '%s\n' alive > "$CLIENT_STATE"
rm -f "$TESTDIR/home/.lumen.log"
if run_desktop; then
	printf 'FAIL: restart relaunched while the client was still alive\n'
	failures=$((failures+1))
else
	printf 'ok:   restart refuses to start a second client\n'
fi
if [ -e "$LAUNCH_MARKER" ]; then
	printf 'FAIL: a live client did not prevent the relaunch\n'
	failures=$((failures+1))
else
	printf 'ok:   a live client prevents the relaunch\n'
fi
if grep -q 'restart_steam. aborted' "$TESTDIR/home/.lumen.log" 2>/dev/null; then
	printf 'ok:   an aborted restart is recorded for diagnosis\n'
else
	printf 'FAIL: aborted restart left no diagnosable record\n'
	failures=$((failures+1))
fi
if grep -q 'SIGKILL' "$TESTDIR/home/.lumen.log" 2>/dev/null; then
	printf 'ok:   a client that ignores the clean quit is escalated before aborting\n'
else
	printf 'FAIL: escalation to SIGKILL was not attempted or not recorded\n'
	failures=$((failures+1))
fi

# --- steam.sh / srt-logger must NOT block the restart -----------------------
# steam.sh is the client's PARENT, so it always outlives it, and the srt-logger
# helpers are reparented to init. Neither can hold Steam's single-instance
# guard, so waiting on them only added latency to every restart.
rm -f "$LAUNCH_MARKER" "$CLIENT_STATE"
: > "$EVENTS"
printf '%s\n' alive > "$STEAM_SH_STATE"
printf '%s\n' alive > "$LOGGER_STATE"
if run_desktop; then
	printf 'ok:   a residual steam.sh or srt-logger does not cancel the restart\n'
else
	printf 'FAIL: residual session helpers cancelled the restart\n'
	failures=$((failures+1))
fi
if await_launch; then
	printf 'ok:   the restart relaunches Steam despite session helpers lingering\n'
else
	printf 'FAIL: restart did not relaunch Steam with session helpers lingering\n'
	failures=$((failures+1))
fi

# --- No client running -> never ask Steam to shut down ----------------------
# `steam -shutdown` with nothing to answer it boots an entire bootstrapper
# (~10s observed) and exits without writing the `Shutdown` line, so the NEXT
# start pays `Verifying all executable checksums`.
rm -f "$LAUNCH_MARKER" "$CLIENT_STATE" "$STEAM_SH_STATE" "$LOGGER_STATE"
: > "$EVENTS"
if run_desktop; then
	printf 'ok:   a restart with no running client succeeds\n'
else
	printf 'FAIL: restart failed when no client was running\n'
	failures=$((failures+1))
fi
if grep -q 'shutdown' "$EVENTS" 2>/dev/null; then
	printf 'FAIL: asked a non-running Steam to shut down\n'
	failures=$((failures+1))
else
	printf 'ok:   no shutdown request is sent when Steam is not running\n'
fi
if await_launch; then
	printf 'ok:   the relaunch still happens with no previous client\n'
else
	printf 'FAIL: no relaunch when there was no previous client\n'
	failures=$((failures+1))
fi

# --- A running client IS asked to quit cleanly first ------------------------
# The clean request is what writes `Shutdown` and keeps the next start on the
# cheap `Verifying file sizes only` path, so signals must not come first.
rm -f "$LAUNCH_MARKER" "$STEAM_SH_STATE" "$LOGGER_STATE"
: > "$EVENTS"
printf '%s\n' alive > "$CLIENT_STATE"
cat > "$FAKEBIN/pgrep" <<'FAKE'
#!/usr/bin/env bash
# Report the client as alive for the first two probes, then let the clean quit
# take effect, so no signal escalation should be needed.
if [ "${1:-}" = -x ] && [ "${2:-}" = steam ]; then
	printf 'x' >> "${TEST_PROBES:-/dev/null}"
	[ "$(wc -c < "${TEST_PROBES:-/dev/null}")" -le 2 ] && exit 0
	exit 1
fi
exit 1
FAKE
chmod +x "$FAKEBIN/pgrep"
PROBES="$TESTDIR/probes"
: > "$PROBES"
if FAKE_MODE=none HOME="$TESTDIR/home" PATH="$FAKEBIN:$PATH" \
	TEST_EVENTS="$EVENTS" TEST_CLIENT_STATE="$CLIENT_STATE" \
	TEST_PROBES="$PROBES" TEST_LAUNCH_MARKER="$LAUNCH_MARKER" \
	bash "$RESTART_SH"; then
	printf 'ok:   a running client is restarted without escalation\n'
else
	printf 'FAIL: restart failed for a client that quit cleanly\n'
	failures=$((failures+1))
fi
if grep -q 'steam -shutdown' "$EVENTS" 2>/dev/null; then
	printf 'ok:   the clean shutdown request is sent to a running client\n'
else
	printf 'FAIL: no clean shutdown request was sent\n'
	failures=$((failures+1))
fi
if grep -q 'pkill' "$EVENTS" 2>/dev/null; then
	printf 'FAIL: signalled Steam even though it quit cleanly\n'
	failures=$((failures+1))
else
	printf 'ok:   no signal is sent when the clean quit works\n'
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
