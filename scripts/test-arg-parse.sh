#!/usr/bin/env bash
# Unit test for install.sh's command-line option parsing.
#
# Why this exists
# ---------------
# The installer grew a `--noplugin` flag (curl ... | bash -s -- --noplugin) that
# installs only the runtime stack (slsteam-moon + Lumen) and skips both the
# LuaTools plugin and the optional CloudRedirect prompt. parse_args is the pure
# option parser behind it; this pins its behaviour (defaults, component update
# channels, the flag, --help, invalid-option handling, and that state resets
# between calls) without running the full installer.
#
# Run: bash scripts/test-arg-parse.sh

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

# --- defaults ---------------------------------------------------------------
parse_args; check "no args: returns 0" $?
[ "$OPT_NOPLUGIN" = 0 ]; check "no args: OPT_NOPLUGIN=0" $?
[ "$OPT_HELP" = 0 ];     check "no args: OPT_HELP=0" $?
[ "$OPT_SLS_CHANNEL" = stable ];    check "no args: slsteam channel defaults to stable" $?
[ "$OPT_PLUGIN_CHANNEL" = stable ]; check "no args: plugin channel defaults to stable" $?
[ "$OPT_LUMEN_CHANNEL" = stable ];  check "no args: Lumen channel defaults to stable" $?

# --- per-component channels -------------------------------------------------
parse_args \
	--slsteam-channel beta \
	--plugin-channel stable \
	--lumen-channel beta
check "channel options: return 0" $?
[ "$OPT_SLS_CHANNEL" = beta ];      check "channel options: slsteam beta" $?
[ "$OPT_PLUGIN_CHANNEL" = stable ]; check "channel options: plugin stable" $?
[ "$OPT_LUMEN_CHANNEL" = beta ];    check "channel options: Lumen beta" $?

if parse_args --lumen-channel; then r=1; else r=0; fi
check "missing channel value: returns non-zero" "$r"
[ "$OPT_BAD_ARG" = "--lumen-channel" ]; check "missing channel value: records option" $?

if parse_args --plugin-channel nightly; then r=1; else r=0; fi
check "invalid channel value: returns non-zero" "$r"
[ "$OPT_BAD_ARG" = "--plugin-channel nightly" ]; check "invalid channel value: records option and value" $?

# --- --noplugin -------------------------------------------------------------
parse_args --noplugin; check "--noplugin: returns 0" $?
[ "$OPT_NOPLUGIN" = 1 ]; check "--noplugin: OPT_NOPLUGIN=1" $?

# --- --help / -h ------------------------------------------------------------
parse_args --help; [ "$OPT_HELP" = 1 ]; check "--help: OPT_HELP=1" $?
parse_args -h;     [ "$OPT_HELP" = 1 ]; check "-h: OPT_HELP=1" $?

# --- state resets between calls ---------------------------------------------
parse_args --noplugin --slsteam-channel beta --plugin-channel beta --lumen-channel beta; parse_args
[ "$OPT_NOPLUGIN" = 0 ]; check "OPT_NOPLUGIN resets to 0 on a fresh parse" $?
[ "$OPT_SLS_CHANNEL" = stable ];    check "slsteam channel resets to stable" $?
[ "$OPT_PLUGIN_CHANNEL" = stable ]; check "plugin channel resets to stable" $?
[ "$OPT_LUMEN_CHANNEL" = stable ];  check "Lumen channel resets to stable" $?

# --- unknown option ---------------------------------------------------------
if parse_args --bogus; then r=1; else r=0; fi
check "unknown option: returns non-zero" "$r"
[ "$OPT_BAD_ARG" = "--bogus" ]; check "unknown option: recorded in OPT_BAD_ARG" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
