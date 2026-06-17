#!/usr/bin/env bash
# Unit test for install.sh's distro detection + immutable-OS handling.
#
# Why this exists
# ---------------
# Bazzite and SteamOS are immutable/atomic systems: their root (`/usr`) is
# read-only and the package manager must NOT be used to install deps
# (rpm-ostree needs a reboot; SteamOS `steamos-readonly disable` + keyring
# re-init is fragile and wiped on update). The installer must recognise these
# systems so install_dependencies short-circuits instead of calling
# dnf/pacman. This pins get_distro_id / is_immutable_distro / get_distro_family
# against synthetic os-release fixtures (so it runs on any dev host).
#
# Run: bash scripts/test-distro-detect.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() { # $1 desc  $2 result(0/1)
	if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

TESTDIR="$(mktemp -d)"
export SLSPLUGIN_LIB_ONLY=1

# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

# Write an os-release fixture and point the installer at it.
fixture() { OS_RELEASE_FILE="$TESTDIR/os-release"; printf '%s\n' "$1" > "$OS_RELEASE_FILE"; export OS_RELEASE_FILE; }

# --- get_distro_id ----------------------------------------------------------

fixture 'ID=bazzite
ID_LIKE="fedora"'
[ "$(get_distro_id)" = "bazzite" ]; check "id: bazzite" $?

fixture 'ID=steamos
ID_LIKE="arch"'
[ "$(get_distro_id)" = "steamos" ]; check "id: steamos" $?

fixture 'ID=Ubuntu'
[ "$(get_distro_id)" = "ubuntu" ]; check "id: lowercases (Ubuntu->ubuntu)" $?

OS_RELEASE_FILE="$TESTDIR/missing"; export OS_RELEASE_FILE
[ "$(get_distro_id)" = "unknown" ]; check "id: missing os-release -> unknown" $?

# --- is_immutable_distro (ID-driven; secondary signals absent on dev host) --

fixture 'ID=bazzite
ID_LIKE="fedora"'
is_immutable_distro; check "immutable: bazzite -> yes" $?

fixture 'ID=steamos
ID_LIKE="arch"'
is_immutable_distro; check "immutable: steamos -> yes" $?

fixture 'ID=steamdeck'
is_immutable_distro; check "immutable: steamdeck -> yes" $?

fixture 'ID=fedora
VARIANT_ID=silverblue'
is_immutable_distro; check "immutable: silverblue variant -> yes" $?

fixture 'ID=ubuntu
ID_LIKE=debian'
if is_immutable_distro; then r=1; else r=0; fi
check "immutable: ubuntu -> no" "$r"

fixture 'ID=arch'
if is_immutable_distro; then r=1; else r=0; fi
check "immutable: arch -> no" "$r"

# --- get_distro_family (unchanged behaviour across the refactor) ------------

fixture 'ID=bazzite
ID_LIKE="fedora"'
[ "$(get_distro_family)" = "fedora" ]; check "family: bazzite -> fedora" $?

fixture 'ID=steamos
ID_LIKE="arch"'
[ "$(get_distro_family)" = "arch" ]; check "family: steamos -> arch" $?

fixture 'ID=linuxmint
ID_LIKE="ubuntu debian"'
[ "$(get_distro_family)" = "debian" ]; check "family: mint -> debian" $?

rm -rf "$TESTDIR"
echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
