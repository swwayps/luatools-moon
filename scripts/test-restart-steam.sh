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

if [ "$failures" -eq 0 ]; then echo; echo "ALL PASS"; exit 0; fi
echo; echo "$failures CHECK(S) FAILED"; exit 1
