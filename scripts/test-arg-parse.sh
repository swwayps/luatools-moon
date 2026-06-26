#!/usr/bin/env bash
# Unit test for install.sh's command-line option parsing.
#
# Why this exists
# ---------------
# The installer grew a `--noplugin` flag (curl ... | bash -s -- --noplugin) that
# installs only the runtime stack (slsteam-moon + Millennium) and skips the
# LuaTools plugin. parse_args is the pure option parser behind it; this pins its
# behaviour (defaults, the flag, --help, unknown-option handling, and that state
# resets between calls) without running the full installer.
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

# --- --noplugin -------------------------------------------------------------
parse_args --noplugin; check "--noplugin: returns 0" $?
[ "$OPT_NOPLUGIN" = 1 ]; check "--noplugin: OPT_NOPLUGIN=1" $?

# --- --help / -h ------------------------------------------------------------
parse_args --help; [ "$OPT_HELP" = 1 ]; check "--help: OPT_HELP=1" $?
parse_args -h;     [ "$OPT_HELP" = 1 ]; check "-h: OPT_HELP=1" $?

# --- state resets between calls ---------------------------------------------
parse_args --noplugin; parse_args
[ "$OPT_NOPLUGIN" = 0 ]; check "OPT_NOPLUGIN resets to 0 on a fresh parse" $?

# --- unknown option ---------------------------------------------------------
if parse_args --bogus; then r=1; else r=0; fi
check "unknown option: returns non-zero" "$r"
[ "$OPT_BAD_ARG" = "--bogus" ]; check "unknown option: recorded in OPT_BAD_ARG" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
