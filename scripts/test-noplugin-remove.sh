#!/usr/bin/env bash
# Unit test for install.sh's --noplugin plugin removal (remove_plugin_if_present).
#
# Why this exists
# ---------------
# A --noplugin install must leave NO LuaTools plugin on disk: if a previous
# standard install put it under one of Millennium's plugin roots, the runtime-
# only install removes it; if it was never there, the step is a no-op and the
# install continues. This pins both branches against a temp HOME so it never
# touches the real Millennium plugin dir.
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
export HOME="$TESTDIR"
PLUGINS="$HOME/.local/share/millennium/plugins"

# --- plugin present -> removed ----------------------------------------------
mkdir -p "$PLUGINS/luatools/backend"
printf 'x' > "$PLUGINS/luatools/backend/main.py"
remove_plugin_if_present >/dev/null 2>&1
[ ! -e "$PLUGINS/luatools" ]; check "existing plugin dir is removed" $?

# --- sibling plugins left intact --------------------------------------------
mkdir -p "$PLUGINS/luatools" "$PLUGINS/some-other-plugin"
remove_plugin_if_present >/dev/null 2>&1
[ -d "$PLUGINS/some-other-plugin" ]; check "unrelated plugins left untouched" $?
[ ! -e "$PLUGINS/luatools" ]; check "plugin dir removed without touching siblings" $?

# --- plugin absent -> no-op, no error ---------------------------------------
rm -rf "$PLUGINS/luatools"
remove_plugin_if_present >/dev/null 2>&1
check "absent plugin: returns success (nothing to remove)" $?

rm -rf "$TESTDIR"
echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
