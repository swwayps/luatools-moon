#!/usr/bin/env bash
# Unit test for uninstall.sh's Game Mode (gamescope session) hook removal.
#
# Why this exists
# ---------------
# The installer writes one sessions.d/<client> override per Steam-ish gamescope
# client, because the session only sources the config of the client it was
# instantiated with (Bazzite 44 boots "ogui-steam", not "steam"). Removal has to
# sweep the whole directory to match, while never touching a file that is not
# ours — a user's own session config must survive an uninstall untouched.
#
# Run: bash scripts/test-gamemode-uninstall.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL_SH="$SCRIPT_DIR/../uninstall.sh"

failures=0
check() { # $1 desc  $2 result(0/1)
	if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT
export SLSPLUGIN_LIB_ONLY=1

# shellcheck disable=SC1090
source "$UNINSTALL_SH" >/dev/null 2>&1

SENTINEL="# managed-by: slsteammoon (game-mode launcher hook)"
export XDG_CONFIG_HOME="$TESTDIR/config"
DIR="$XDG_CONFIG_HOME/gamescope-session-plus/sessions.d"
mkdir -p "$DIR"

# Ours, for both clients the image ships.
printf '%s\nexport STEAMCMD=x\n' "$SENTINEL" > "$DIR/steam"
printf '%s\nexport STEAMCMD=x\n' "$SENTINEL" > "$DIR/ogui-steam"
# A foreign file the user wrote themselves.
printf '# my own tweaks\nexport FOO=1\n' > "$DIR/kodi"
# A foreign file we displaced on install, stashed next to the hook.
printf '# the user had this before\n' > "$DIR/steam.bak.100"

remove_gamemode_hook >/dev/null 2>&1

[ ! -f "$DIR/ogui-steam" ]
check "removes the ogui-steam hook (the one Bazzite 44 actually sources)" $?

[ -f "$DIR/kodi" ] && grep -q 'my own tweaks' "$DIR/kodi"
check "leaves a foreign client config untouched" $?

[ -f "$DIR/steam" ] && grep -q 'the user had this before' "$DIR/steam"
check "restores the stashed foreign backup over the removed hook" $?

# Second run must be a clean no-op: the restored file is NOT ours, so it stays.
remove_gamemode_hook >/dev/null 2>&1
[ -f "$DIR/steam" ] && grep -q 'the user had this before' "$DIR/steam"
check "re-run does not eat the restored foreign config" $?

# No gamescope config at all -> silent no-op, no directories created.
export XDG_CONFIG_HOME="$TESTDIR/empty-config"
remove_gamemode_hook >/dev/null 2>&1
[ ! -d "$XDG_CONFIG_HOME/gamescope-session-plus" ]
check "no hook present -> no-op, creates nothing" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
