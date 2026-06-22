#!/usr/bin/env bash
# Unit test for install.sh's SteamOS Game Mode support.
#
# Why this exists
# ---------------
# SteamOS launches Game Mode Steam very differently from ChimeraOS/Bazzite:
# there is NO gamescope-session(-plus)/sessions.d/steam to override. Instead a
# systemd *user* unit, steam-launcher.service, runs /usr/lib/steamos/steam-
# launcher which does `exec steam ...` (resolved via PATH). So:
#   1. Detection must recognise SteamOS too (steam-launcher.service present),
#      otherwise the installer never offers the Game Mode step there.
#   2. The hook is a systemd user drop-in that PREPENDS the slsteam-moon wrapper
#      dir to PATH (so `exec steam` resolves to our wrapper), preserving the
#      distro's launcher + its ExecStartPre, and reversible by the uninstaller.
#
# Pins steamos_steam_launcher_unit / has_steamos_gamescope /
# has_gamescope_session / steamos_gamemode_dropin_content against synthetic
# fixtures so it runs on any dev host.
#
# Run: bash scripts/test-gamemode-steamos.sh

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

# --- detection: steamos_steam_launcher_unit / has_steamos_gamescope ----------

# No SteamOS unit anywhere -> not a SteamOS gamescope host.
export STEAMOS_SESSION_UNIT_DIRS="$TESTDIR/u1 $TESTDIR/e1"
export GAMESCOPE_SHARE_DIRS="$TESTDIR/empty-share $TESTDIR/empty-etc"
[ -z "$(steamos_steam_launcher_unit)" ]; check "unit: none present -> empty" $?
if has_steamos_gamescope; then r=1; else r=0; fi
check "detect: none present -> no" "$r"

# SteamOS layout: steam-launcher.service under a systemd user unit dir.
mkdir -p "$TESTDIR/u2/systemd-user"
: > "$TESTDIR/u2/systemd-user/steam-launcher.service"
export STEAMOS_SESSION_UNIT_DIRS="$TESTDIR/u2/systemd-user"
[ "$(steamos_steam_launcher_unit)" = "$TESTDIR/u2/systemd-user/steam-launcher.service" ]
check "unit: steam-launcher.service present -> path" $?
has_steamos_gamescope; check "detect: present -> yes" $?

# has_gamescope_session must return true on a SteamOS host even with NO
# ChimeraOS sessions.d layout present.
export GAMESCOPE_SHARE_DIRS="$TESTDIR/none-share $TESTDIR/none-etc"
has_gamescope_session; check "has_gamescope_session: SteamOS unit -> yes" $?

# ...and false when neither mechanism is present.
export STEAMOS_SESSION_UNIT_DIRS="$TESTDIR/u-empty"
export GAMESCOPE_SHARE_DIRS="$TESTDIR/s-empty $TESTDIR/e-empty"
if has_gamescope_session; then r=1; else r=0; fi
check "has_gamescope_session: neither -> no" "$r"

# --- steamos_gamemode_dropin_content -----------------------------------------

export STEAMOS_STEAM_LAUNCHER="/usr/lib/steamos/steam-launcher"
DROPIN="$TESTDIR/dropin.conf"
steamos_gamemode_dropin_content > "$DROPIN"

grep -qF "managed-by: slsteammoon" "$DROPIN"; check "dropin: carries sentinel" $?
grep -qx "\[Service\]" "$DROPIN"; check "dropin: has [Service] section" $?

# The empty ExecStart= MUST appear before the replacement so systemd resets the
# unit's command list (otherwise it errors on a second ExecStart for Type=notify
# wouldn't apply our wrapper).
grep -qx "ExecStart=" "$DROPIN"; check "dropin: resets ExecStart (empty line)" $?

# The replacement ExecStart prepends our wrapper dir to PATH and re-execs the
# distro launcher, preserving the runtime PATH via systemd's $$ escape.
grep -q 'ExecStart=/bin/sh -c' "$DROPIN"; check "dropin: wrapped ExecStart present" $?
grep -qF '.local/share/SLSsteam/path:' "$DROPIN"; check "dropin: prepends wrapper dir to PATH" $?
grep -qF '$$PATH' "$DROPIN"; check "dropin: preserves runtime PATH (\$\$ escape)" $?
grep -qF '/usr/lib/steamos/steam-launcher' "$DROPIN"; check "dropin: re-execs the distro launcher" $?

# %h (systemd home specifier) must be left for systemd to expand, NOT a literal
# \$HOME or an install-time-expanded absolute path.
grep -qF '%h/.local/share/SLSsteam/path' "$DROPIN"; check "dropin: uses %h home specifier" $?

if [ "$failures" -eq 0 ]; then echo; echo "ALL PASS"; exit 0; fi
echo; echo "$failures CHECK(S) FAILED"; exit 1
