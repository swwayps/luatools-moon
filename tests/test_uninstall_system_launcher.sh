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
# The uninstaller resolves the XDG layers itself. Pin every test to $HOME so a
# developer's own XDG_* settings cannot steer these assertions.
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_DIRS XDG_CONFIG_DIRS
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
# The stub records the call, honours SUDO_FAIL=1 to simulate denied privileges,
# and otherwise RUNS the command so restoration can be verified for real.
cat > "$TMP/bin/sudo" <<STUB
#!/bin/sh
echo "SUDO \$*" >> "$TMP/out"
[ "\${SUDO_FAIL:-0}" = 1 ] && exit 1
while [ \$# -gt 0 ]; do
	case "\$1" in -n|-v|-A) shift ;; *) break ;; esac
done
[ \$# -eq 0 ] && exit 0
exec "\$@"
STUB
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

# --- A surviving shim keeps its fallback ---------------------------------------
# The shim runs `exec "$SLSDIR/system-launcher-backup/<name>.orig"` once the
# wrapper is gone. When we cannot restore /usr/bin/steam (no administrator
# access), deleting that backup turns a still-working launcher into a broken one
# — and the minimal entry heal_steam_launcher seeds (Exec=steam %U) resolves
# straight into the same shim. So restoration failure must raise
# SLSM_KEEP_LAUNCHER_BACKUP and the removal step must spare that one directory.
H4="$TMP/h4"; HOME="$H4"; export HOME
BK="$H4/.local/share/SLSsteam/system-launcher-backup"
FAKEBIN="$TMP/fakebin"
mkdir -p "$BK" "$FAKEBIN"
printf '#!/bin/sh\nexec /usr/lib/steam/steam "$@"\n' > "$BK/steam.orig"
cp "$SHIM" "$FAKEBIN/steam"; chmod 0755 "$FAKEBIN/steam"

# Run in the CURRENT shell (not a command substitution) so SLSM_KEEP_LAUNCHER_BACKUP
# can propagate, capturing output to a file instead.
SLSM_LAUNCHER_DIRS=("$FAKEBIN")
OS_RELEASE_FILE=/dev/null

# Case A: privileges available -> the shim is genuinely restored, nothing kept.
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_SUDO_PRIMED=0; SUDO_FAIL=0; export SUDO_FAIL
restore_system_launchers > "$TMP/outA" 2>&1
ck "wrapped shim is restored"         "no" "$(is_our_launcher_shim "$FAKEBIN/steam" && echo yes || echo no)"
ck "restored launcher is the original" 'exec /usr/lib/steam/steam "$@"' \
   "$(tail -1 "$FAKEBIN/steam")"
ck "no need to keep the backup"       "0"  "$SLSM_KEEP_LAUNCHER_BACKUP"

# Case B: privileges denied and the shim is not writable -> it survives, so its
# fallback must be preserved and the finishing command shown.
cp "$SHIM" "$FAKEBIN/steam"; chmod 0555 "$FAKEBIN/steam"
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_SUDO_PRIMED=0; SUDO_FAIL=1; export SUDO_FAIL
restore_system_launchers > "$TMP/outB" 2>&1
SUDO_FAIL=0; export SUDO_FAIL
ck "unrestorable shim is left in place" "yes" \
   "$(is_our_launcher_shim "$FAKEBIN/steam" && echo yes || echo no)"
ck "keep-backup flag is raised"         "1" "$SLSM_KEEP_LAUNCHER_BACKUP"
ck "the fallback file still exists"     "yes" "$([ -f "$BK/steam.orig" ] && echo yes || echo no)"
ck "the finishing command is printed"   "yes" \
   "$(grep -qF "sudo cp '$BK/steam.orig' '$FAKEBIN/steam'" "$TMP/outB" && echo yes || echo no)"
chmod 0755 "$FAKEBIN/steam"
unset SLSM_LAUNCHER_DIRS
SLSM_SUDO_PRIMED=0

# And the removal step must spare exactly that directory when the flag is set.
grep -q '! -name system-launcher-backup' "$HERE/uninstall.sh" \
  && echo "ok   - removal spares the retained launcher backup" \
  || { echo "FAIL - removal deletes the backup a surviving shim needs"; fail=1; }
HOME="$TMP/home"; export HOME

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
# Privileges are denied, so the system entry cannot be de-patched.
SUDO_FAIL=1; export SUDO_FAIL
OS_RELEASE_FILE=/dev/null heal_steam_launcher >/dev/null 2>&1
SUDO_FAIL=0; export SUDO_FAIL
ck "system entry stays patched without privileges" "1" \
   "$(grep -c 'X-SLSteamMoon-Patched' "$HEAL_SYS_DESKTOP")"
ck "seeds a user entry when the system one is still broken" "yes" \
   "$([ -f "$H/.local/share/applications/steam.desktop" ] && echo yes || echo no)"
ck "seeded entry launches vanilla steam" "Exec=steam %U" \
   "$(grep -m1 '^Exec=' "$H/.local/share/applications/steam.desktop" 2>/dev/null)"

# --- Backstop: user desktop restore must not be gated on the coverage helper ---
# dc_restore_all bails (return 2) on a SYSTEM-side failure BEFORE restoring the
# user layer, so the standalone uninstaller must restore user-owned desktops
# UNCONDITIONALLY. Otherwise the user backups at ~/.local/share/SLSsteam/backup
# are saved but never consumed before `rm -rf` deletes them.
USER_RESTORE_LINE="$(awk -v s="$BODY_LINE" 'NR>=s && /^[[:space:]]*restore_user_desktop_entries[[:space:]]*$/{print NR; exit}' "$HERE/uninstall.sh")"
ck "user desktop restore sweep is called" "yes" "$([ -n "$USER_RESTORE_LINE" ] && echo yes || echo no)"
ck "user desktop restore runs before the rm -rf deletion" "before" \
   "$([ -n "$RM_LINE" ] && [ -n "$USER_RESTORE_LINE" ] && [ "$USER_RESTORE_LINE" -lt "$RM_LINE" ] && echo before || echo after)"
# The gate that used to skip the user layer whenever the coverage helper ran is
# gone for good: no `coverage_restored` bookkeeping may come back.
ck "no coverage_restored gate remains" "0" \
   "$(grep -c 'coverage_restored' "$HERE/uninstall.sh")"

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
