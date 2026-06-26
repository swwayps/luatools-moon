#!/usr/bin/env bash
# Unit test for install.sh's --noplugin plugin removal (remove_plugin_if_present).
#
# Why this exists
# ---------------
# A --noplugin install must leave NO LuaTools plugin on disk: if a previous
# standard install put it under ~/.local/share/Lumen/luatools, the runtime-only
# install removes it (so Lumen runs settings-menu-only); if it was never there,
# the step is a no-op and the install continues. This pins both branches against
# a temp LUMEN_DIR so it runs on any dev host.
#
# Run: bash scripts/test-noplugin-remove.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() { # $1 desc  $2 result(0/1)
	if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

TESTDIR="$(mktemp -d)"
LUMEN_DIR="$TESTDIR/Lumen"

# --- plugin present -> removed ----------------------------------------------
mkdir -p "$LUMEN_DIR/luatools/backend"
printf 'x' > "$LUMEN_DIR/luatools/backend/main.lua"
remove_plugin_if_present >/dev/null 2>&1
[ ! -e "$LUMEN_DIR/luatools" ]; check "existing plugin dir is removed" $?

# --- runtime files left intact ----------------------------------------------
mkdir -p "$LUMEN_DIR"
printf 'bin' > "$LUMEN_DIR/lumen"
mkdir -p "$LUMEN_DIR/luatools"
remove_plugin_if_present >/dev/null 2>&1
[ -f "$LUMEN_DIR/lumen" ]; check "lumen binary is left untouched" $?
[ ! -e "$LUMEN_DIR/luatools" ]; check "plugin dir removed without touching siblings" $?

# --- plugin absent -> no-op, no error ---------------------------------------
rm -rf "$LUMEN_DIR/luatools"
remove_plugin_if_present >/dev/null 2>&1
check "absent plugin: returns success (nothing to remove)" $?

rm -rf "$TESTDIR"
echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
