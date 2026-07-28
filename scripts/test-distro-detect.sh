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

# --- NixOS ------------------------------------------------------------------
# NixOS has no /usr/bin, no system package manager the installer can drive,
# and no read-only root — it needs its own branches, not the immutable path.

fixture 'ID=nixos
ID_LIKE=""'
[ "$(get_distro_id)" = "nixos" ]; check "id: nixos" $?
if is_immutable_distro; then r=1; else r=0; fi
check "immutable: nixos -> no (declarative, not read-only)" "$r"
[ "$(get_distro_family)" = "unknown" ]; check "family: nixos -> unknown (no apt/dnf/pacman/zypper)" $?

# detect_steam_type's nixos branch: accept `steam` off PATH only when it
# resolves into the Nix store (real programs.steam.enable layout), not a
# flatpak/snap shim that happens to shadow the name.
FAKEBIN="$TESTDIR/fakebin"; mkdir -p "$FAKEBIN"
FAKESTORE="$TESTDIR/nix-store-pkg/bin"; mkdir -p "$FAKESTORE"
printf '#!/bin/sh\n' > "$FAKESTORE/steam"; chmod +x "$FAKESTORE/steam"
ln -sf "$FAKESTORE/steam" "$FAKEBIN/steam"
# readlink -f resolves through the symlink to $TESTDIR/nix-store-pkg/bin/steam,
# which isn't under /nix/store on a dev host — so fake `readlink` to prove the
# branch's logic (real /nix/store/* prefix) without needing an actual store.
readlink() { case "$*" in "-f "*) printf '/nix/store/abc123-steam-1.0/bin/steam\n' ;; esac; }
detect_steam_type_result="$(
	STEAM_FIXED_CANDIDATES="" STEAM_SEARCH_PATH="$FAKEBIN" detect_steam_type
)"
[ "$detect_steam_type_result" = "native" ]; check "steam type: nixos + steam resolving into /nix/store -> native" $?
unset -f readlink
rm -rf "$FAKEBIN" "$FAKESTORE"

# Negative: `steam` on PATH but NOT resolving into /nix/store (e.g. a stray
# script) must not be misdetected as native.
FAKEBIN2="$TESTDIR/fakebin2"; mkdir -p "$FAKEBIN2"
printf '#!/bin/sh\n' > "$FAKEBIN2/steam"; chmod +x "$FAKEBIN2/steam"
detect_steam_type_result="$(
	STEAM_FIXED_CANDIDATES="" STEAM_SEARCH_PATH="$FAKEBIN2" detect_steam_type
)"
[ "$detect_steam_type_result" != "native" ]; check "steam type: nixos + steam outside /nix/store -> not native" $?
rm -rf "$FAKEBIN2"

# Reinstall: setup.sh's wrapper is first, but detection must continue to the
# native NixOS launcher later in PATH.
WRAPPERBIN="$TESTDIR/home/.local/share/SLSsteam/path"
NATIVEBIN="$TESTDIR/nativebin"
mkdir -p "$WRAPPERBIN" "$NATIVEBIN"
printf '#!/bin/sh\n' > "$WRAPPERBIN/steam"; chmod +x "$WRAPPERBIN/steam"
printf '#!/bin/sh\n' > "$NATIVEBIN/steam"; chmod +x "$NATIVEBIN/steam"
readlink() {
	case "$2" in
		"$NATIVEBIN/steam") printf '/nix/store/abc123-steam-1.0/bin/steam\n' ;;
		*) printf '%s\n' "$2" ;;
	esac
}
detect_steam_type_result="$(
	HOME="$TESTDIR/home" STEAM_FIXED_CANDIDATES="" \
	STEAM_SEARCH_PATH="$WRAPPERBIN:$NATIVEBIN" detect_steam_type
)"
[ "$detect_steam_type_result" = "native" ]; check "steam type: reinstall skips own wrapper and finds native Steam" $?
unset -f readlink

# The same wrapper must be removed before control passes to slsteam-moon's own
# setup.sh, which performs a separate Steam lookup after recreating the wrapper.
setup_path="$(
	HOME="$TESTDIR/home" path_without_slsteam_wrapper "$WRAPPERBIN:$NATIVEBIN:/usr/bin"
)"
[ "$setup_path" = "$NATIVEBIN:/usr/bin" ]; check "setup handoff: strips own wrapper and preserves remaining PATH order" $?
rm -rf "$WRAPPERBIN" "$NATIVEBIN"

# The single dependency pass is independently testable. On NixOS it includes
# steam-run, treats notify-send as optional, and runs from main before
# check_internet, Steam shutdown, or cleanup.
PREREQBIN="$TESTDIR/prereqbin"; mkdir -p "$PREREQBIN"
for tool in jq tar unzip; do
	printf '#!/bin/sh\nexit 0\n' > "$PREREQBIN/$tool"
	chmod +x "$PREREQBIN/$tool"
done
if (DEPENDENCY_PATH="$PREREQBIN" check_dependencies >/dev/null 2>&1); then r=1; else r=0; fi
check "nixos preflight: missing curl and steam-run fails closed" "$r"
for tool in curl steam-run; do
	printf '#!/bin/sh\nexit 0\n' > "$PREREQBIN/$tool"
	chmod +x "$PREREQBIN/$tool"
done
DEPENDENCY_PATH="$PREREQBIN" check_dependencies >/dev/null 2>&1
check "nixos preflight: complete toolset passes" $?

# The preflight gate must stay side-effect free: a mutable distro missing tools
# defers to install_dependencies instead of invoking sudo/the package manager.
fixture 'ID=ubuntu
ID_LIKE=debian'
rm -f "$PREREQBIN/curl" "$PREREQBIN/steam-run"
SUDO_CALLS="$TESTDIR/sudo.calls"; : > "$SUDO_CALLS"
printf '#!/bin/sh\nprintf called >> "$SUDO_CALLS"\nexit 1\n' > "$PREREQBIN/sudo"
chmod +x "$PREREQBIN/sudo"
(PATH="$PREREQBIN:$PATH" SUDO_CALLS="$SUDO_CALLS" DEPENDENCY_PATH="$PREREQBIN" \
	check_dependencies >/dev/null 2>&1)
check "mutable preflight: defers instead of aborting" $?
if [ -s "$SUDO_CALLS" ]; then r=1; else r=0; fi
check "mutable preflight: never invokes sudo" "$r"
rm -rf "$PREREQBIN"

fixture 'ID=nixos
ID_LIKE=""'

# Pin the destructive-action ordering that motivated this preflight: pure
# detection before anything is touched, package installation only after the
# machine has been validated.
detect_calls="$(grep -Ec '^[[:space:]]+check_dependencies$' "$INSTALL_SH")"
install_calls="$(grep -Ec '^[[:space:]]+install_dependencies$' "$INSTALL_SH")"
detect_line="$(grep -nE '^[[:space:]]+check_dependencies$' "$INSTALL_SH" | cut -d: -f1)"
install_line="$(grep -nE '^[[:space:]]+install_dependencies$' "$INSTALL_SH" | cut -d: -f1)"
internet_line="$(grep -nE '^[[:space:]]+check_internet$' "$INSTALL_SH" | cut -d: -f1)"
native_line="$(grep -nE '^[[:space:]]+check_steam_native$' "$INSTALL_SH" | cut -d: -f1)"
bootstrap_line="$(grep -nE '^[[:space:]]+check_steam_bootstrapped$' "$INSTALL_SH" | cut -d: -f1)"
stop_line="$(grep -nE '^[[:space:]]+stop_steam$' "$INSTALL_SH" | cut -d: -f1)"
cleanup_line="$(grep -nE '^[[:space:]]+cleanup_previous_install$' "$INSTALL_SH" | cut -d: -f1)"
[ "$detect_calls" -eq 1 ]; check "dependency detection: called exactly once" $?
[ "$install_calls" -eq 1 ]; check "dependency install: called exactly once" $?
[ "$detect_line" -lt "$internet_line" ] \
	&& [ "$detect_line" -lt "$stop_line" ] \
	&& [ "$detect_line" -lt "$cleanup_line" ]
check "dependency detection: runs before internet, Steam shutdown, and cleanup" $?
[ "$install_line" -gt "$native_line" ] && [ "$install_line" -gt "$bootstrap_line" ]
check "dependency install: runs only after the machine is validated" $?

# nixos_pkg_for: nixpkgs attribute names (only "tar" differs -> gnutar).
[ "$(nixos_pkg_for tar)" = "gnutar" ]; check "nixos_pkg_for: tar -> gnutar" $?
[ "$(nixos_pkg_for notify-send)" = "libnotify" ]; check "nixos_pkg_for: notify-send -> libnotify" $?
[ "$(nixos_pkg_for jq)" = "jq" ]; check "nixos_pkg_for: jq -> jq (unchanged)" $?

rm -rf "$TESTDIR"
echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
