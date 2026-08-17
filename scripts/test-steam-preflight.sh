#!/usr/bin/env bash
# Regression tests for native Steam preflight when sandboxed Steam packages
# coexist with the distro installation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGINAL_PATH="$PATH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() { # $1 description  $2 expected  $3 actual
	if [ "$2" = "$3" ]; then
		printf 'ok:   %s\n' "$1"
	else
		printf 'FAIL: %s (expected %q, got %q)\n' "$1" "$2" "$3"
		failures=$((failures + 1))
	fi
}

export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1091
. "$ROOT/install.sh" >/dev/null 2>&1
LANG_IS_PT=0

HOME_DIR="$TMP/home"
BIN_DIR="$TMP/bin"
NATIVE_LAUNCHER="$TMP/usr/games/steam"
OS_RELEASE="$TMP/os-release"
mkdir -p "$HOME_DIR/.steam" "$BIN_DIR" "$(dirname "$NATIVE_LAUNCHER")"
printf 'ID=zorin\nID_LIKE="ubuntu debian"\n' > "$OS_RELEASE"
printf '#!/bin/sh\nexit 0\n' > "$NATIVE_LAUNCHER"
chmod 0755 "$NATIVE_LAUNCHER"

# The fakes model the command-line interfaces used by install.sh while keeping
# the test independent of packages installed on the development host.
cat > "$BIN_DIR/flatpak" <<'EOF'
#!/usr/bin/env bash
if [ "${TEST_FLATPAK_STEAM:-0}" = 1 ] && [ "${1:-}" = list ]; then
	printf '%s\n' "${TEST_FLATPAK_APP_ID:-com.valvesoftware.Steam}"
	if [ "${TEST_LONG_LIST:-0}" = 1 ]; then
		i=0
		while [ "$i" -lt 20000 ]; do
			printf 'org.example.App%s\n' "$i"
			i=$((i + 1))
		done
	fi
	exit 0
fi
exit 1
EOF
cat > "$BIN_DIR/snap" <<'EOF'
#!/usr/bin/env bash
if [ "${TEST_SNAP_STEAM:-0}" = 1 ] && [ "${1:-}" = list ]; then
	printf 'steam  1.0  1  latest/stable  canonical**  -\n'
	exit 0
fi
exit 1
EOF
chmod 0755 "$BIN_DIR/flatpak" "$BIN_DIR/snap"

run_native_preflight() {
	HOME="$HOME_DIR" PATH="$BIN_DIR:$ORIGINAL_PATH" \
		OS_RELEASE_FILE="$OS_RELEASE" \
		STEAM_FIXED_CANDIDATES="$NATIVE_LAUNCHER" STEAM_SEARCH_PATH="" \
		check_steam_native && \
	HOME="$HOME_DIR" PATH="$BIN_DIR:$ORIGINAL_PATH" \
		OS_RELEASE_FILE="$OS_RELEASE" \
		STEAM_FIXED_CANDIDATES="$NATIVE_LAUNCHER" STEAM_SEARCH_PATH="" \
		check_steam_bootstrapped
}

# A valid native bootstrap wins even when the Flatpak is also installed.
NATIVE_ROOT="$TMP/native-root"
mkdir -p "$NATIVE_ROOT"
printf '#!/bin/sh\nexit 0\n' > "$NATIVE_ROOT/steam.sh"
chmod 0755 "$NATIVE_ROOT/steam.sh"
ln -s "$NATIVE_ROOT" "$HOME_DIR/.steam/steam"
native_with_flatpak_out="$(TEST_FLATPAK_STEAM=1 run_native_preflight 2>&1)"
native_with_flatpak_rc=$?
check "bootstrapped native Steam remains valid beside Flatpak" 0 "$native_with_flatpak_rc"
case "$native_with_flatpak_out" in
	*"Steam has been initialized"*) result=yes ;;
	*) result=no ;;
esac
check "coexisting install reports the native bootstrap" yes "$result"

# `install.sh` enables pipefail. Detection must consume a long package listing
# instead of letting an early grep exit turn the producer's SIGPIPE into a
# false "Flatpak not installed" result.
long_list_rc=0
HOME="$HOME_DIR" PATH="$BIN_DIR:$ORIGINAL_PATH" \
	TEST_FLATPAK_STEAM=1 TEST_LONG_LIST=1 \
	flatpak_steam_installed >/dev/null 2>&1 || long_list_rc=$?
check "long Flatpak listing cannot become a pipefail false negative" 0 "$long_list_rc"

near_match_detected=no
HOME="$HOME_DIR" PATH="$BIN_DIR:$ORIGINAL_PATH" \
	TEST_FLATPAK_STEAM=1 TEST_FLATPAK_APP_ID=com.valvesoftware.SteamLink \
	flatpak_steam_installed >/dev/null 2>&1 && near_match_detected=yes
check "Steam-like Flatpak application ID is not the Steam app" no "$near_match_detected"

both_isolated="$(
	HOME="$HOME_DIR" PATH="$BIN_DIR:$ORIGINAL_PATH" \
		TEST_FLATPAK_STEAM=1 TEST_SNAP_STEAM=1 \
		sandboxed_steam_installations
)"
check "simultaneous sandboxed packages are both reported" Flatpak/Snap "$both_isolated"

# Snap coexistence follows the same native-first rule.
native_with_snap_out="$(TEST_SNAP_STEAM=1 run_native_preflight 2>&1)"
native_with_snap_rc=$?
check "bootstrapped native Steam remains valid beside Snap" 0 "$native_with_snap_rc"
case "$native_with_snap_out" in
	*"Steam has been initialized"*) result=yes ;;
	*) result=no ;;
esac
check "Snap coexistence reports the native bootstrap" yes "$result"

# If only the sandboxed copy was opened, keep it installed and direct the user
# to the concrete native launcher instead of repeating the ambiguous menu-icon
# instruction.
rm "$HOME_DIR/.steam/steam"
flatpak_mismatch_out="$(TEST_FLATPAK_STEAM=1 run_native_preflight 2>&1)"
flatpak_mismatch_rc=$?
check "uninitialized native Steam still blocks installation" 1 "$flatpak_mismatch_rc"
case "$flatpak_mismatch_out" in
	*Flatpak*"$NATIVE_LAUNCHER"*) result=yes ;;
	*) result=no ;;
esac
check "mixed-install error identifies Flatpak and the native launcher" yes "$result"
case "$flatpak_mismatch_out" in
	*"do not need to uninstall"*|*"does not need to be uninstalled"*) result=yes ;;
	*) result=no ;;
esac
check "mixed-install error permits Flatpak to remain installed" yes "$result"

snap_mismatch_out="$(TEST_SNAP_STEAM=1 run_native_preflight 2>&1)"
snap_mismatch_rc=$?
check "uninitialized native Steam beside Snap still blocks installation" 1 "$snap_mismatch_rc"
case "$snap_mismatch_out" in
	*Snap*"$NATIVE_LAUNCHER"*) result=yes ;;
	*) result=no ;;
esac
check "mixed-install error identifies Snap and the native launcher" yes "$result"
case "$snap_mismatch_out" in
	*"do not need to uninstall"*|*"does not need to be uninstalled"*) result=yes ;;
	*) result=no ;;
esac
check "mixed-install error permits Snap to remain installed" yes "$result"

# A sandbox-only host still needs native Steam, but coexistence is supported:
# the installer must no longer require removal of the existing copy.
flatpak_only_out="$(
	HOME="$HOME_DIR" PATH="$BIN_DIR:$ORIGINAL_PATH" TEST_FLATPAK_STEAM=1 \
		OS_RELEASE_FILE="$OS_RELEASE" \
		STEAM_FIXED_CANDIDATES="" STEAM_SEARCH_PATH="" \
		check_steam_native 2>&1
)"
flatpak_only_rc=$?
check "Flatpak-only host still blocks installation" 1 "$flatpak_only_rc"
case "$flatpak_only_out" in
	*"flatpak uninstall"*) result=no ;;
	*) result=yes ;;
esac
check "Flatpak-only guidance does not require uninstalling it" yes "$result"
case "$flatpak_only_out" in
	*"keep"*Flatpak*|*Flatpak*"keep"*) result=yes ;;
	*) result=no ;;
esac
check "Flatpak-only guidance explicitly allows coexistence" yes "$result"

snap_only_out="$(
	HOME="$HOME_DIR" PATH="$BIN_DIR:$ORIGINAL_PATH" TEST_SNAP_STEAM=1 \
		OS_RELEASE_FILE="$OS_RELEASE" \
		STEAM_FIXED_CANDIDATES="" STEAM_SEARCH_PATH="" \
		check_steam_native 2>&1
)"
snap_only_rc=$?
check "Snap-only host still blocks installation" 1 "$snap_only_rc"
case "$snap_only_out" in
	*"snap remove"*) result=no ;;
	*) result=yes ;;
esac
check "Snap-only guidance does not require uninstalling it" yes "$result"
case "$snap_only_out" in
	*"keep"*Snap*|*Snap*"keep"*) result=yes ;;
	*) result=no ;;
esac
check "Snap-only guidance explicitly allows coexistence" yes "$result"

# Preserve the original safety boundary: a foreign/partial real directory at
# the canonical path must never masquerade as Valve's bootstrap symlink.
mkdir -p "$HOME_DIR/.steam/steam"
cp "$NATIVE_ROOT/steam.sh" "$HOME_DIR/.steam/steam/steam.sh"
real_dir_out="$(TEST_FLATPAK_STEAM=0 run_native_preflight 2>&1)"
real_dir_rc=$?
check "real directory at the canonical Steam path remains rejected" 1 "$real_dir_rc"

# Corrupt canonical states need their own fail-closed diagnosis even when a
# sandboxed package is present; telling the user merely to launch native Steam
# would not repair these states.
real_dir_flatpak_out="$(TEST_FLATPAK_STEAM=1 run_native_preflight 2>&1)"
case "$real_dir_flatpak_out" in
	*"not a symbolic link"*|*"not the expected symbolic link"*) result=yes ;;
	*) result=no ;;
esac
check "real directory beside Flatpak is diagnosed as a blocked canonical path" yes "$result"
case "$real_dir_flatpak_out" in
	*"do not modify"*|*"will not modify"*) result=yes ;;
	*) result=no ;;
esac
check "real directory diagnosis promises no automatic replacement" yes "$result"

rm -rf "$HOME_DIR/.steam/steam"
ln -s "$TMP/missing-native-root" "$HOME_DIR/.steam/steam"
broken_link_out="$(TEST_FLATPAK_STEAM=1 run_native_preflight 2>&1)"
broken_link_rc=$?
check "broken canonical Steam symlink remains rejected" 1 "$broken_link_rc"
case "$broken_link_out" in
	*"symbolic link is broken"*|*"broken symbolic link"*) result=yes ;;
	*) result=no ;;
esac
check "broken symlink beside Flatpak receives a specific diagnosis" yes "$result"

rm "$HOME_DIR/.steam/steam"
INCOMPLETE_ROOT="$TMP/incomplete-native-root"
mkdir -p "$INCOMPLETE_ROOT"
ln -s "$INCOMPLETE_ROOT" "$HOME_DIR/.steam/steam"
incomplete_root_out="$(TEST_FLATPAK_STEAM=1 run_native_preflight 2>&1)"
incomplete_root_rc=$?
check "native root without steam.sh remains rejected" 1 "$incomplete_root_rc"
case "$incomplete_root_out" in
	*"steam.sh"*"missing"*|*"missing"*"steam.sh"*) result=yes ;;
	*) result=no ;;
esac
check "incomplete native root beside Flatpak receives a specific diagnosis" yes "$result"

printf '\n'
if [ "$failures" -eq 0 ]; then
	echo "ALL PASS"
	exit 0
fi
echo "$failures CHECK(S) FAILED"
exit 1
