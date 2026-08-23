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

# --- gamescope_session_clients ----------------------------------------------
# The session sources ONLY sessions.d/<client> for the client it was started
# with, so the hook must be written for every Steam-ish client the image ships.
# Bazzite 44 autologins into "ogui-steam"; a hook written only for "steam" is
# never sourced and Game Mode comes up un-injected.
CLIENTS_ROOT="$TESTDIR/clients"
mkdir -p "$CLIENTS_ROOT/gamescope-session-plus/sessions.d"
export GAMESCOPE_SHARE_DIRS="$CLIENTS_ROOT"
cat > "$CLIENTS_ROOT/gamescope-session-plus/sessions.d/steam" <<'EOS'
export CLIENTCMD="steam -gamepadui -steamos3 -steampal -steamdeck"
EOS
cat > "$CLIENTS_ROOT/gamescope-session-plus/sessions.d/ogui-steam" <<'EOS'
. /usr/share/gamescope-session-plus/sessions.d/steam
CLIENTCMD="opengamepadui --overlay-mode -- $CLIENTCMD"
EOS
# A non-Steam client and package/backup leftovers must be ignored.
echo 'export CLIENTCMD="kodi"' > "$CLIENTS_ROOT/gamescope-session-plus/sessions.d/kodi"
echo 'export CLIENTCMD="steam"' > "$CLIENTS_ROOT/gamescope-session-plus/sessions.d/steam.rpmnew"
echo 'export CLIENTCMD="steam"' > "$CLIENTS_ROOT/gamescope-session-plus/sessions.d/steam.bak.123"

CLIENTS="$(gamescope_session_clients gamescope-session-plus | tr '\n' ' ')"
[ "$CLIENTS" = "steam ogui-steam " ]
check "clients: steam + ogui-steam, leftovers/non-steam excluded (got: $CLIENTS)" $?

# Nothing installed -> still yields the canonical "steam" so the hook has a home.
export GAMESCOPE_SHARE_DIRS="$TESTDIR/nothing-here"
[ "$(gamescope_session_clients gamescope-session-plus)" = "steam" ]
check "clients: no configs -> canonical steam" $?

# --- gamemode_hook_content: command rewrite ---------------------------------
# Sourcing the generated hook with a representative CLIENTCMD must yield a
# STEAMCMD that points at our wrapper AND keeps every original token.
HOOK="$TESTDIR/hook"
gamemode_hook_content > "$HOOK"

grep -qF "managed-by: slsteammoon" "$HOOK"; check "hook: carries sentinel" $?

# The hook only acts when the wrapper is really there, so give the fake HOME one.
TESTHOME="$TESTDIR/home"
WRAP="$TESTHOME/.local/share/SLSsteam/path/steam"
mkdir -p "$(dirname "$WRAP")"
printf '#!/bin/sh\n' > "$WRAP"
chmod +x "$WRAP"

(
	HOME="$TESTHOME"
	CLIENTCMD="steam -gamepadui -steamos3 -steampal -steamdeck"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "$WRAP -gamepadui -steamos3 -steampal -steamdeck" ]
)
check "hook: preserves flags + points at wrapper" $?

# Edge case: CLIENTCMD is just "steam" (no flags) -> no trailing space/args.
(
	HOME="$TESTHOME"
	CLIENTCMD="steam"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "$WRAP" ]
)
check "hook: bare 'steam' -> no trailing args" $?

# Edge case: empty CLIENTCMD -> still resolves to the wrapper alone.
(
	HOME="$TESTHOME"
	CLIENTCMD=""
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "$WRAP" ]
)
check "hook: empty CLIENTCMD -> wrapper alone" $?

# Bazzite "ogui-steam" on handheld hardware: OpenGamepadUI is placed IN FRONT of
# Steam. Only the `steam` token may be swapped; splitting on the first space
# would hand Steam's flags to OpenGamepadUI and drop Steam entirely.
(
	HOME="$TESTHOME"
	CLIENTCMD="opengamepadui --accessibility disabled --overlay-mode -- steam -gamepadui -steamdeck"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "opengamepadui --accessibility disabled --overlay-mode -- $WRAP -gamepadui -steamdeck" ]
)
check "hook: wrapped CLIENTCMD -> only the steam token is swapped" $?

# An absolute steam path is swapped too (some sessions use /usr/bin/steam).
(
	HOME="$TESTHOME"
	CLIENTCMD="/usr/bin/steam -gamepadui"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "$WRAP -gamepadui" ]
)
check "hook: absolute /usr/bin/steam is swapped" $?

# Idempotent: re-sourcing over an already-rewritten STEAMCMD is a no-op.
(
	HOME="$TESTHOME"
	CLIENTCMD="steam -gamepadui"
	STEAMCMD="$WRAP -gamepadui"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ "$STEAMCMD" = "$WRAP -gamepadui" ]
)
check "hook: idempotent over an existing STEAMCMD" $?

# A non-Steam gamescope client must never be hijacked.
(
	HOME="$TESTHOME"
	CLIENTCMD="kodi --standalone"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ -z "${STEAMCMD:-}" ]
)
check "hook: no steam token -> STEAMCMD left unset" $?

# Safety rail: no wrapper on disk (payload removed, hook orphaned) -> do NOT
# point Game Mode at a missing binary, which would leave the device unable to
# start Steam with no easy way out.
(
	HOME="$TESTDIR/empty-home"
	CLIENTCMD="steam -gamepadui"
	# shellcheck disable=SC1090
	. "$HOOK"
	[ -z "${STEAMCMD:-}" ]
)
check "hook: wrapper absent -> STEAMCMD left unset" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
