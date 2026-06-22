#!/usr/bin/env bash
# Unit test for install.sh's Game Mode (gamescope session) support.
#
# Why this exists
# ---------------
# On Deck/handheld images, "Game Mode" launches Steam through a gamescope
# session wrapper instead of the .desktop we patch, so we drop a sessions.d
# override that re-points the launcher at our wrapper. Two things MUST hold:
#   1. Detection is distro-agnostic (gamescope-session-plus OR gamescope-session,
#      under /usr/share or /etc) and is a clean NO-OP off gamescope, so a normal
#      desktop install never grows a Game Mode step.
#   2. The hook preserves the distro's own CLIENTCMD flags (-gamepadui ...) while
#      swapping the binary for our wrapper.
# This pins gamescope_session_base / has_gamescope_session / gamemode_hook_content
# against synthetic fixtures (so it runs on any dev host).
#
# Run: bash scripts/test-gamemode-hook.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() { # $1 desc  $2 result(0/1)
	if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT
export SLSPLUGIN_LIB_ONLY=1

# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

# Neutralise the SteamOS Game Mode detector so this (ChimeraOS/Bazzite) test is
# hermetic even when run on a real SteamOS host (which ships steam-launcher.
# service under the default unit dirs). The SteamOS path has its own test.
export STEAMOS_SESSION_UNIT_DIRS="$TESTDIR/no-steamos-units"

# --- gamescope_session_base / has_gamescope_session (synthetic fixtures) ----

# No gamescope dirs at all -> not a gamescope host.
export GAMESCOPE_SHARE_DIRS="$TESTDIR/usr-share $TESTDIR/etc"
[ -z "$(gamescope_session_base)" ]; check "base: none present -> empty" $?
if has_gamescope_session; then r=1; else r=0; fi
check "detect: none present -> no" "$r"

# Bazzite/ChimeraOS layout: gamescope-session-plus under /usr/share.
mkdir -p "$TESTDIR/usr-share/gamescope-session-plus/sessions.d"
: > "$TESTDIR/usr-share/gamescope-session-plus/sessions.d/steam"
[ "$(gamescope_session_base)" = "gamescope-session-plus" ]
check "base: -plus present -> gamescope-session-plus" $?
has_gamescope_session; check "detect: -plus present -> yes" $?

# Older layout: only gamescope-session (no -plus).
export GAMESCOPE_SHARE_DIRS="$TESTDIR/u2 $TESTDIR/e2"
mkdir -p "$TESTDIR/e2/gamescope-session/sessions.d"
: > "$TESTDIR/e2/gamescope-session/sessions.d/steam"
[ "$(gamescope_session_base)" = "gamescope-session" ]
check "base: only plain -> gamescope-session" $?

# Precedence: -plus wins when both exist.
export GAMESCOPE_SHARE_DIRS="$TESTDIR/u3"
mkdir -p "$TESTDIR/u3/gamescope-session-plus/sessions.d" \
         "$TESTDIR/u3/gamescope-session/sessions.d"
[ "$(gamescope_session_base)" = "gamescope-session-plus" ]
check "base: both -> -plus precedence" $?

# --- gamemode_hook_content: flag preservation -------------------------------
# Sourcing the generated hook with a representative CLIENTCMD must yield a
# STEAMCMD that points at our wrapper AND keeps every original flag.
HOOK="$TESTDIR/hook"
gamemode_hook_content > "$HOOK"

grep -qF "managed-by: slsteammoon" "$HOOK"; check "hook: carries sentinel" $?

(
	HOME="/home/tester"
	CLIENTCMD="steam -gamepadui -steamos3 -steampal -steamdeck"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "/home/tester/.local/share/SLSsteam/path/steam -gamepadui -steamos3 -steampal -steamdeck" ]
)
check "hook: preserves flags + points at wrapper" $?

# Edge case: CLIENTCMD is just "steam" (no flags) -> no trailing space/args.
(
	HOME="/home/tester"
	CLIENTCMD="steam"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "/home/tester/.local/share/SLSsteam/path/steam" ]
)
check "hook: bare 'steam' -> no trailing args" $?

# Edge case: empty CLIENTCMD -> still resolves to the wrapper alone.
(
	HOME="/home/tester"
	CLIENTCMD=""
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "/home/tester/.local/share/SLSsteam/path/steam" ]
)
check "hook: empty CLIENTCMD -> wrapper alone" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
