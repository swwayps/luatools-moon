#!/usr/bin/env bash
# Unit test for install.sh's Millennium 32-bit OpenSSL dependency mapping.
#
# Why this exists (millennium branch only)
# ----------------------------------------
# Millennium's loader is a 32-bit .so, and its own installer hard-requires
# libssl-dev:i386 on apt/Debian distros (it `exit 1`s otherwise). We install
# the 32-bit OpenSSL dev package before running the Millennium installer. The
# package name differs per distro family and a wrong name would break the
# install, so this pins the exact mapping.
#
# Run: bash scripts/test-millennium-ssl-dep.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() { if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"; else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi; }

export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

[ "$(millennium_ssl_pkg debian)"   = "libssl-dev:i386" ]        ; check "debian   -> libssl-dev:i386" $?
[ "$(millennium_ssl_pkg fedora)"   = "openssl-devel.i686" ]     ; check "fedora   -> openssl-devel.i686" $?
[ "$(millennium_ssl_pkg arch)"     = "lib32-openssl" ]          ; check "arch     -> lib32-openssl" $?
[ "$(millennium_ssl_pkg opensuse)" = "libopenssl-devel-32bit" ] ; check "opensuse -> libopenssl-devel-32bit" $?
[ -z "$(millennium_ssl_pkg unknown)" ]                          ; check "unknown  -> empty" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
