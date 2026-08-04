#!/usr/bin/env bash
# Unit tests for the wrapped-system-launcher restoration added to uninstall.sh.
#
# Reproduces the "/usr/bin/steam and the KDE .desktop both fail after uninstall"
# report: setup.sh replaces /usr/bin/steam (and /usr/games/steam,
# /usr/local/bin/steam) with a shim that falls back to
#   exec "$HOME/.local/share/SLSsteam/system-launcher-backup/steam.orig"
# The standalone uninstaller used to `rm -rf ~/.local/share/SLSsteam` WITHOUT
# restoring those launchers first, so the shim's fallback aimed at a deleted
# file and every Steam launch failed. restore_system_launchers must put the
# originals back from that backup dir before it is removed.
#
# Sourcing uninstall.sh with SLSPLUGIN_LIB_ONLY=1 defines functions WITHOUT
# running main().
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SLSPLUGIN_LIB_ONLY=1 . "$HERE/uninstall.sh"
fail=0
ck(){ if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (want [$2] got [$3])"; fail=1; fi; }

# --- is_our_launcher_shim: detection ------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SHIM="$TMP/steam"
{
	echo '#!/bin/sh'
	echo '# slsteam-moon system launcher shim'
	echo '# Delegates to the full SLSsteam wrapper when present.'
	echo 'SLSM_WRAPPER="${HOME}/.local/share/SLSsteam/path/steam"'
	echo 'exec "$SLSM_WRAPPER" "$@"'
} > "$SHIM"

# A genuine Valve launcher is NOT our shim (no tag in the first 3 lines).
GENUINE="$TMP/steam-genuine"
{
	echo '#!/bin/sh'
	echo '# Steam launcher'
	echo 'exec /usr/lib/steam/bin_steam.sh "$@"'
} > "$GENUINE"

ck "detects our launcher shim"          "yes" "$(is_our_launcher_shim "$SHIM"    && echo yes || echo no)"
ck "rejects a genuine launcher"         "no"  "$(is_our_launcher_shim "$GENUINE" && echo yes || echo no)"
ck "missing file is not a shim"         "no"  "$(is_our_launcher_shim "$TMP/none" && echo yes || echo no)"

# --- restore_system_launchers: no-op safety ----------------------------------
# No backup dir -> nothing to do (must not error, must not touch anything).
HOME="$TMP/home"; export HOME
mkdir -p "$HOME"
RESTORE_OUT="$TMP/out"; : > "$RESTORE_OUT"
# Stub sudo so we can detect any unintended privileged call.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "SUDO $*" >> "%s/out"\n' "$TMP" > "$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"
PATH="$TMP/bin:$PATH"; export PATH

restore_system_launchers >/dev/null 2>&1
ck "no backup dir -> no sudo invocation" "no" "$([ -s "$RESTORE_OUT" ] && echo yes || echo no)"

# Immutable distros are never touched by the installer, so the uninstaller must
# skip restore too (mirrors setup.sh::setup_system_launcher guard).
printf 'ID=steamos\nID_LIKE=arch\n' > "$TMP/os-release"
OS_RELEASE_FILE="$TMP/os-release" restore_system_launchers >/dev/null 2>&1
ck "immutable distro -> restore is a no-op" "no" \
   "$([ -s "$RESTORE_OUT" ] && echo yes || echo no)"

# --- Structural: restore happens before the dir is removed --------------------
# The whole point: restore_system_launchers reads backups from inside
# ~/.local/share/SLSsteam, so it MUST run before `rm -rf` that directory.
# Assert the call precedes the removal in uninstall_slsteam_moon's body.
BODY_LINE="$(grep -n '^uninstall_slsteam_moon()' "$HERE/uninstall.sh" | cut -d: -f1)"
RM_LINE="$(awk -v start="$BODY_LINE" 'NR>=start && /rm -rf "\$HOME\/\.local\/share\/SLSsteam"/{print NR; exit}' "$HERE/uninstall.sh")"
CALL_LINE="$(awk -v start="$BODY_LINE" 'NR>=start && /^[[:space:]]*restore_system_launchers[[:space:]]*$/{print NR; exit}' "$HERE/uninstall.sh")"
ck "restore_system_launchers is called"      "yes" "$([ -n "$CALL_LINE" ] && echo yes || echo no)"
ck "restore runs before the rm -rf deletion"  "before" \
   "$([ -n "$RM_LINE" ] && [ -n "$CALL_LINE" ] && [ "$CALL_LINE" -lt "$RM_LINE" ] && echo before || echo after)"

# --- heal_steam_launcher: broken system desktop + no user entry -> seed -------
# When the system .desktop could not be de-patched (no sudo) and no user entry
# exists, KDE would show the broken system entry. heal must seed a working user
# entry (same ID shadows the system one).
H="$TMP/h2"; HOME="$H"; mkdir -p "$H"
HEAL_SYS_DESKTOP="$H/sys/steam.desktop"
mkdir -p "$(dirname "$HEAL_SYS_DESKTOP")"
cat > "$HEAL_SYS_DESKTOP" <<EOF
[Desktop Entry]
X-SLSteamMoon-Patched=true
Name=Steam
Exec=$H/.local/share/SLSsteam/path/steam %U
Icon=steam
Type=Application
EOF
OS_RELEASE_FILE=/dev/null heal_steam_launcher >/dev/null 2>&1
ck "seeds a user entry when the system one is still broken" "yes" \
   "$([ -f "$H/.local/share/applications/steam.desktop" ] && echo yes || echo no)"
ck "seeded entry launches vanilla steam" "Exec=steam %U" \
   "$(grep -m1 '^Exec=' "$H/.local/share/applications/steam.desktop" 2>/dev/null)"

# --- Backstop: user desktop restore must not be gated on the coverage helper ---
# dc_restore_all bails (return 2) on a SYSTEM-side failure BEFORE restoring the
# user layer, so the standalone uninstaller must restore user-owned desktops
# UNCONDITIONALLY. Otherwise the user backups at ~/.local/share/SLSsteam/backup
# are saved but never consumed before `rm -rf` deletes them.
USER_RESTORE_LINE="$(awk -v s="$BODY_LINE" 'NR>=s && /restore_or_remove_desktop "\$USER_DESKTOP"/{print NR; exit}' "$HERE/uninstall.sh")"
GATE_FOR_USER="$(awk -v s="$BODY_LINE" -v t="$USER_RESTORE_LINE" 'NR>=s && NR<t && /^[[:space:]]*if \[ "\$coverage_restored" = 0 \]/{c++} END{print c+0}' "$HERE/uninstall.sh")"
# After the fix there must be NO `if [ "$coverage_restored" = 0 ]` opening
# between the function start and the user desktop restore call.
ck "user desktop restore runs unconditionally (no coverage_restored gate)" "0" "$GATE_FOR_USER"

# Functional: a patched user desktop with a central backup is restored by the
# backstop function even when no coverage helper is sourced (dc_restore_all bail
# simulation). restore_or_remove_desktop is the backstop call.
H3="$TMP/h3"; HOME="$H3"; mkdir -p "$H3"
ACTIVE="$H3/.local/share/applications/steam.desktop"
CENTRAL="$(desktop_backup_path "$ACTIVE")"
mkdir -p "$(dirname "$ACTIVE")" "$(dirname "$CENTRAL")"
printf '[Desktop Entry]\nX-SLSteamMoon-Patched=true\nName=Steam\nExec=%s/.local/share/SLSsteam/path/steam %%U\n' "$H3" > "$ACTIVE"
printf '[Desktop Entry]\nName=Steam\nExec=/usr/bin/steam %%U\n' > "$CENTRAL"
OS_RELEASE_FILE=/dev/null restore_or_remove_desktop "$ACTIVE" >/dev/null 2>&1
ck "backstop consumes the user desktop backup" "Exec=/usr/bin/steam %U" \
   "$(grep -m1 '^Exec=' "$ACTIVE")"
ck "backstop deletes the consumed backup" "no" "$([ -e "$CENTRAL" ] && echo yes || echo no)"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
