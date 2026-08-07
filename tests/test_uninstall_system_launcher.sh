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

# Even without a backup directory, an active shim is an incomplete uninstall:
# returning success here would let the caller delete the wrapper while the
# package launcher still points at it. The shim must be detected before the
# missing-backup fast path and the state must remain retryable.
H0="$TMP/no-backup-shim"; HOME="$H0"; export HOME
NO_BACKUP_BIN="$TMP/no-backup-bin"; mkdir -p "$H0/.local/share/SLSsteam" "$NO_BACKUP_BIN"
cp "$SHIM" "$NO_BACKUP_BIN/steam"; chmod 0755 "$NO_BACKUP_BIN/steam"
SLSM_LAUNCHER_DIRS=("$NO_BACKUP_BIN")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_SUDO_PRIMED=0; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then no_backup_result=yes; else no_backup_result=no; fi
ck "shim without backup reports failure" "no" "$no_backup_result"
ck "shim without backup is retained" "yes" \
   "$(is_our_launcher_shim "$NO_BACKUP_BIN/steam" && echo yes || echo no)"
ck "shim without backup raises keep flag" "1" "$SLSM_KEEP_LAUNCHER_BACKUP"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0

# Immutable distros are never touched by the installer, so the uninstaller must
# skip restore too (mirrors setup.sh::setup_system_launcher guard).
printf 'ID=steamos\nID_LIKE=arch\n' > "$TMP/os-release"
OS_RELEASE_FILE="$TMP/os-release" restore_system_launchers >/dev/null 2>&1
ck "immutable distro -> restore is a no-op" "no" \
   "$([ -s "$RESTORE_OUT" ] && echo yes || echo no)"

# An existing shim on an immutable host cannot be restored, so report an
# incomplete uninstall and retain the complete helper tree for retry.
HIMM="$TMP/immutable-shim"; HOME="$HIMM"; export HOME
IMM_BIN="$TMP/immutable-bin"
mkdir -p "$HIMM/.local/share/SLSsteam" "$IMM_BIN"
cp "$SHIM" "$IMM_BIN/steam"; chmod 0755 "$IMM_BIN/steam"
SLSM_LAUNCHER_DIRS=("$IMM_BIN")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0
if OS_RELEASE_FILE="$TMP/os-release" restore_system_launchers >/dev/null 2>&1; then immutable_shim_result=yes; else immutable_shim_result=no; fi
ck "immutable active shim reports incomplete restore" "no" "$immutable_shim_result"
ck "immutable active shim retains backup state" "1" "$SLSM_KEEP_LAUNCHER_BACKUP"
ck "immutable active shim retains complete tree" "1" "$SLSM_KEEP_LAUNCHER_TREE"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

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
chmod 0755 "$BK/steam.orig"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nexec "%s/steam.orig" "$@"\n' \
  "$BK" > "$FAKEBIN/steam"; chmod 0755 "$FAKEBIN/steam"

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
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nexec "%s/steam.orig" "$@"\n' \
  "$BK" > "$FAKEBIN/steam"; chmod 0555 "$FAKEBIN/steam"
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
CALL_LINE="$(awk -v start="$BODY_LINE" 'NR>=start && /restore_system_launchers[[:space:];]/{print NR; exit}' "$HERE/uninstall.sh")"
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

# --- Mirrored launcher backups: distinct paths must restore independently ----
H5="$TMP/h5"; HOME="$H5"; export HOME
MIRROR_ROOT="$TMP/mirrored-launchers"
MIRROR_BACKUP="$H5/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$MIRROR_ROOT/usr/bin" "$MIRROR_ROOT/usr/games" \
         "$MIRROR_BACKUP$MIRROR_ROOT/usr/bin" \
         "$MIRROR_BACKUP$MIRROR_ROOT/usr/games"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s%s/usr/bin/steam.orig"\nexec /broken/bin\n' \
  "$MIRROR_BACKUP" "$MIRROR_ROOT" > "$MIRROR_ROOT/usr/bin/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s%s/usr/games/steam.orig"\nexec /broken/games\n' \
  "$MIRROR_BACKUP" "$MIRROR_ROOT" > "$MIRROR_ROOT/usr/games/steam"
printf '#!/bin/sh\nprintf "ORIGINAL-BIN\\n"\n' > "$MIRROR_BACKUP$MIRROR_ROOT/usr/bin/steam.orig"
printf '#!/bin/sh\nprintf "ORIGINAL-GAMES\\n"\n' > "$MIRROR_BACKUP$MIRROR_ROOT/usr/games/steam.orig"
chmod 0755 "$MIRROR_ROOT/usr/bin/steam" "$MIRROR_ROOT/usr/games/steam" \
           "$MIRROR_BACKUP$MIRROR_ROOT/usr/bin/steam.orig" "$MIRROR_BACKUP$MIRROR_ROOT/usr/games/steam.orig"
SLSM_LAUNCHER_DIRS=("$MIRROR_ROOT/usr/bin" "$MIRROR_ROOT/usr/games")
OS_RELEASE_FILE=/dev/null SLSM_SUDO_PRIMED=0 SLSM_SUDO_DENIED=0 \
  restore_system_launchers >/dev/null 2>&1
ck "mirrored bin launcher is restored" "ORIGINAL-BIN" \
   "$(sh "$MIRROR_ROOT/usr/bin/steam" | cut -d- -f1-2)"
ck "mirrored games launcher is restored" "ORIGINAL-GAMES" \
   "$(sh "$MIRROR_ROOT/usr/games/steam" | cut -d- -f1-2)"
ck "mirrored bin shim is removed" "no" \
   "$(is_our_launcher_shim "$MIRROR_ROOT/usr/bin/steam" && echo yes || echo no)"
ck "mirrored games shim is removed" "no" \
   "$(is_our_launcher_shim "$MIRROR_ROOT/usr/games/steam" && echo yes || echo no)"

# Exercise the installed shared-library branch with its full absolute mirror.
H6="$TMP/h6"; HOME="$H6"; export HOME
INST_ROOT="$TMP/installed-launchers"
INST_BACKUP="$H6/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$INST_ROOT/usr/bin" "$INST_BACKUP$INST_ROOT/usr/bin" \
         "$H6/.local/share/SLSsteam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s%s/usr/bin/steam.orig"\nexec /broken/installed\n' \
  "$INST_BACKUP" "$INST_ROOT" > "$INST_ROOT/usr/bin/steam"
printf '#!/bin/sh\nprintf "INSTALLED-ORIGINAL\\n"\n' > "$INST_BACKUP$INST_ROOT/usr/bin/steam.orig"
cp "$HERE/../slsteam-moon/tools/launcher-shim.lib.sh" \
   "$H6/.local/share/SLSsteam/launcher-shim.lib.sh"
chmod 0755 "$INST_ROOT/usr/bin/steam" "$INST_BACKUP$INST_ROOT/usr/bin/steam.orig"
SLSM_LAUNCHER_DIRS=("$INST_ROOT/usr/bin")
OS_RELEASE_FILE=/dev/null restore_system_launchers >/dev/null 2>&1
ck "installed launcher library restores its mirror" "INSTALLED-ORIGINAL" \
   "$(sh "$INST_ROOT/usr/bin/steam" | cut -d- -f1-2)"

# A mirrored backup must be visible to the one-shot sudo preflight.
OS_RELEASE_FILE=/dev/null SLSM_SYS_APPS="$TMP/no-system-apps" \
  SLSM_SYS_AUTOSTART="$TMP/no-system-autostart" \
  ck "sudo preflight sees mirrored launcher backups" "yes" \
     "$(system_restore_pending && echo yes || echo no)"

# A missing backup for one of several shims must keep the uninstall incomplete;
# restoring one launcher is not enough to delete the shared backup tree.
H7="$TMP/h7"; HOME="$H7"; export HOME
MISSING_ROOT="$TMP/missing-launchers"
MISSING_BACKUP="$H7/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$MISSING_ROOT/usr/bin" "$MISSING_ROOT/usr/games" \
         "$MISSING_BACKUP/usr/bin"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s%s/usr/bin/steam.orig"\nexec /broken/missing-bin\n' \
  "$MISSING_BACKUP" "$MISSING_ROOT" > "$MISSING_ROOT/usr/bin/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s%s/usr/games/steam.orig"\nexec /broken/missing-games\n' \
  "$MISSING_BACKUP" "$MISSING_ROOT" > "$MISSING_ROOT/usr/games/steam"
printf '#!/bin/sh\nprintf "MISSING-BIN-ORIGINAL\\n"\n' > "$MISSING_BACKUP/usr/bin/steam.orig"
chmod 0755 "$MISSING_ROOT/usr/bin/steam" "$MISSING_ROOT/usr/games/steam" \
           "$MISSING_BACKUP/usr/bin/steam.orig"
SLSM_LAUNCHER_DIRS=("$MISSING_ROOT/usr/bin" "$MISSING_ROOT/usr/games")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then missing_result=yes; else missing_result=no; fi
ck "missing mirrored backup reports failure" "no" "$missing_result"
ck "missing mirrored launcher shim is retained" "yes" \
   "$(is_our_launcher_shim "$MISSING_ROOT/usr/games/steam" && echo yes || echo no)"
ck "missing mirrored restore keeps the backup" "1" "$SLSM_KEEP_LAUNCHER_BACKUP"

# Legacy flat backups must skip a vanilla launcher and continue searching for
# the next candidate that is actually one of our shims.
H8="$TMP/h8"; HOME="$H8"; export HOME
FLAT_MIXED_ROOT="$TMP/flat-mixed"
FLAT_MIXED_BACKUP="$H8/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$FLAT_MIXED_ROOT/vanilla" "$FLAT_MIXED_ROOT/shim" "$FLAT_MIXED_BACKUP"
printf '#!/bin/sh\nprintf "VANILLA-FIRST\\n"\n' > "$FLAT_MIXED_ROOT/vanilla/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s/steam.orig"\nexec /broken/mixed\n' \
  "$FLAT_MIXED_BACKUP" > "$FLAT_MIXED_ROOT/shim/steam"
printf '#!/bin/sh\nprintf "FLAT-MIXED-ORIGINAL\\n"\n' > "$FLAT_MIXED_BACKUP/steam.orig"
chmod 0755 "$FLAT_MIXED_ROOT/vanilla/steam" "$FLAT_MIXED_ROOT/shim/steam" \
           "$FLAT_MIXED_BACKUP/steam.orig"
SLSM_LAUNCHER_DIRS=("$FLAT_MIXED_ROOT/vanilla" "$FLAT_MIXED_ROOT/shim")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
restore_system_launchers >/dev/null 2>&1
ck "flat fallback skips vanilla candidate" "VANILLA-FIRST" \
   "$(sh "$FLAT_MIXED_ROOT/vanilla/steam" | head -1)"
ck "flat fallback restores the later shim candidate" "FLAT-MIXED-ORIGINAL" \
   "$(sh "$FLAT_MIXED_ROOT/shim/steam" | head -1)"
ck "flat fallback removes the later shim" "no" \
   "$(is_our_launcher_shim "$FLAT_MIXED_ROOT/shim/steam" && echo yes || echo no)"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0

# Older installations may not have shipped launcher-shim.lib.sh. The fallback
# must retry a flat backup after restoring a mirrored launcher in the same run.
H9="$TMP/h9"; HOME="$H9"; export HOME
MIX_NO_LIB_ROOT="$TMP/mixed-no-library"
MIX_NO_LIB_BACKUP="$H9/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$MIX_NO_LIB_ROOT/usr/bin" "$MIX_NO_LIB_ROOT/usr/games" \
  "$MIX_NO_LIB_BACKUP" "$MIX_NO_LIB_BACKUP$MIX_NO_LIB_ROOT/usr/games"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s/steam.orig"\nexec /broken/no-lib-bin\n' \
  "$MIX_NO_LIB_BACKUP" > "$MIX_NO_LIB_ROOT/usr/bin/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s%s/usr/games/steam.orig"\nexec /broken/no-lib-games\n' \
  "$MIX_NO_LIB_BACKUP" "$MIX_NO_LIB_ROOT" > "$MIX_NO_LIB_ROOT/usr/games/steam"
printf '#!/bin/sh\nprintf "NO-LIB-BIN\\n"\n' > "$MIX_NO_LIB_BACKUP/steam.orig"
printf '#!/bin/sh\nprintf "NO-LIB-GAMES\\n"\n' > \
  "$MIX_NO_LIB_BACKUP$MIX_NO_LIB_ROOT/usr/games/steam.orig"
chmod 0755 "$MIX_NO_LIB_ROOT/usr/bin/steam" "$MIX_NO_LIB_ROOT/usr/games/steam" \
  "$MIX_NO_LIB_BACKUP/steam.orig" \
  "$MIX_NO_LIB_BACKUP$MIX_NO_LIB_ROOT/usr/games/steam.orig"
SLSM_LAUNCHER_DIRS=("$MIX_NO_LIB_ROOT/usr/bin" "$MIX_NO_LIB_ROOT/usr/games")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then mixed_no_lib_result=yes; else mixed_no_lib_result=no; fi
ck "compatibility mixed mirrored and flat restore succeeds" "yes" "$mixed_no_lib_result"
ck "compatibility restore recovers flat-backed launcher" "NO-LIB-BIN" \
   "$(sh "$MIX_NO_LIB_ROOT/usr/bin/steam" | head -1)"
ck "compatibility restore recovers mirrored launcher" "NO-LIB-GAMES" \
   "$(sh "$MIX_NO_LIB_ROOT/usr/games/steam" | head -1)"
ck "compatibility mixed restore removes both shims" "no" \
   "$([ -z "$(is_our_launcher_shim "$MIX_NO_LIB_ROOT/usr/bin/steam" && echo yes || true)" ] && \
       [ -z "$(is_our_launcher_shim "$MIX_NO_LIB_ROOT/usr/games/steam" && echo yes || true)" ] && echo no || echo yes)"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0

# A surviving shim with a valid mirrored original must win over a stale flat
# file, regardless of find(1) enumeration order.
H10="$TMP/h10"; HOME="$H10"; export HOME
MIX_STALE_ROOT="$TMP/mixed-stale-flat"
MIX_STALE_BACKUP="$H10/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$MIX_STALE_ROOT/usr/bin" "$MIX_STALE_ROOT/usr/games" \
  "$MIX_STALE_BACKUP$MIX_STALE_ROOT/usr/games"
printf '#!/bin/sh\nprintf "VANILLA-NEW\\n"\n' > "$MIX_STALE_ROOT/usr/bin/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\n# managed\nSLSM_ORIG="%s%s/usr/games/steam.orig"\nexec /broken/stale\n' \
  "$MIX_STALE_BACKUP" "$MIX_STALE_ROOT" > "$MIX_STALE_ROOT/usr/games/steam"
printf '#!/bin/sh\nprintf "STALE-FLAT\\n"\n' > "$MIX_STALE_BACKUP/steam.orig"
printf '#!/bin/sh\nprintf "MIRRORED-GAMES\\n"\n' > \
  "$MIX_STALE_BACKUP$MIX_STALE_ROOT/usr/games/steam.orig"
chmod 0755 "$MIX_STALE_ROOT/usr/bin/steam" "$MIX_STALE_ROOT/usr/games/steam" \
  "$MIX_STALE_BACKUP/steam.orig" \
  "$MIX_STALE_BACKUP$MIX_STALE_ROOT/usr/games/steam.orig"
SLSM_LAUNCHER_DIRS=("$MIX_STALE_ROOT/usr/bin" "$MIX_STALE_ROOT/usr/games")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then stale_result=yes; else stale_result=no; fi
ck "compatibility prefers mirrored backup over stale flat" "yes" "$stale_result"
ck "compatibility restores the mirrored original" "MIRRORED-GAMES" \
   "$(sh "$MIX_STALE_ROOT/usr/games/steam" | head -1)"
ck "compatibility leaves stale flat backup untouched" "yes" \
   "$([ -f "$MIX_STALE_BACKUP/steam.orig" ] && echo yes || echo no)"
# A shim with no recoverable backup must keep the complete SLSsteam tree: keeping
# only an already-missing backup directory would delete both the wrapper and the
# shim's last fallback.
H11="$TMP/h11"; HOME="$H11"; export HOME
NO_BACKUP_TREE="$H11/.local/share/SLSsteam"
NO_BACKUP_BIN="$TMP/no-backup-tree-bin"
mkdir -p "$NO_BACKUP_TREE/path" "$NO_BACKUP_BIN"
cp "$SHIM" "$NO_BACKUP_BIN/steam"; chmod 0755 "$NO_BACKUP_BIN/steam"
SLSM_LAUNCHER_DIRS=("$NO_BACKUP_BIN")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0
SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then no_backup_tree_result=yes; else no_backup_tree_result=no; fi
ck "missing backup directory reports failure" "no" "$no_backup_tree_result"
ck "missing backup requests full tree retention" "1" "$SLSM_KEEP_LAUNCHER_TREE"
ck "uninstaller guards full tree retention" "yes" \
   "$(grep -q 'SLSM_KEEP_LAUNCHER_TREE' "$HERE/uninstall.sh" && echo yes || echo no)"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

# Without the shared library, a flat backup must still belong to the surviving
# shim. A shim that points at another/missing original must be retained.
H12="$TMP/h12"; HOME="$H12"; export HOME
MISMATCH_ROOT="$TMP/mismatch-no-library"
MISMATCH_BACKUP="$H12/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$MISMATCH_ROOT/usr/bin" "$MISMATCH_BACKUP"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s/other.orig"\nexec /broken/mismatch\n' \
  "$MISMATCH_BACKUP" > "$MISMATCH_ROOT/usr/bin/steam"
printf '#!/bin/sh\nprintf "MISMATCH-FLAT\\n"\n' > "$MISMATCH_BACKUP/steam.orig"
chmod 0755 "$MISMATCH_ROOT/usr/bin/steam" "$MISMATCH_BACKUP/steam.orig"
SLSM_LAUNCHER_DIRS=("$MISMATCH_ROOT/usr/bin")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0
SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then mismatch_result=yes; else mismatch_result=no; fi
ck "unassociated flat backup reports failure" "no" "$mismatch_result"
ck "unassociated flat backup leaves shim" "yes" \
   "$(is_our_launcher_shim "$MISMATCH_ROOT/usr/bin/steam" && echo yes || echo no)"
ck "unassociated flat backup remains available" "yes" \
   "$([ -f "$MISMATCH_BACKUP/steam.orig" ] && echo yes || echo no)"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

# A mirrored backup in the no-library fallback must be executable and explicitly
# associated; a non-executable candidate must not be promoted to the launcher.
H16="$TMP/h16"; HOME="$H16"; export HOME
NONEXEC_MIRROR_ROOT="$TMP/nonexec-mirror"
NONEXEC_MIRROR_BACKUP="$H16/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$NONEXEC_MIRROR_ROOT/usr/bin" \
  "$NONEXEC_MIRROR_BACKUP$NONEXEC_MIRROR_ROOT/usr/bin"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s%s/usr/bin/steam.orig"\nexec /broken/nonexec-mirror\n' \
  "$NONEXEC_MIRROR_BACKUP" "$NONEXEC_MIRROR_ROOT" > "$NONEXEC_MIRROR_ROOT/usr/bin/steam"
printf '#!/bin/sh\nprintf "NONEXEC-MIRROR\\n"\n' > \
  "$NONEXEC_MIRROR_BACKUP$NONEXEC_MIRROR_ROOT/usr/bin/steam.orig"
chmod 0755 "$NONEXEC_MIRROR_ROOT/usr/bin/steam"
chmod 0644 "$NONEXEC_MIRROR_BACKUP$NONEXEC_MIRROR_ROOT/usr/bin/steam.orig"
SLSM_LAUNCHER_DIRS=("$NONEXEC_MIRROR_ROOT/usr/bin")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0
SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then nonexec_mirror_result=yes; else nonexec_mirror_result=no; fi
ck "non-executable mirrored fallback reports failure" "no" "$nonexec_mirror_result"
ck "non-executable mirrored fallback leaves shim" "yes" \
   "$(is_our_launcher_shim "$NONEXEC_MIRROR_ROOT/usr/bin/steam" && echo yes || echo no)"
ck "non-executable mirrored fallback retains tree state" "1" "$SLSM_KEEP_LAUNCHER_TREE"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

# The installed shared library must apply the same association rule; a flat
# backup that points at a different original must not be treated as usable.
H14="$TMP/h14"; HOME="$H14"; export HOME
MISMATCH_LIB_ROOT="$TMP/mismatch-with-library"
MISMATCH_LIB_BACKUP="$H14/.local/share/SLSsteam/system-launcher-backup"
mkdir -p "$MISMATCH_LIB_ROOT/usr/bin" "$MISMATCH_LIB_BACKUP" \
  "$H14/.local/share/SLSsteam"
cp "$HERE/../slsteam-moon/tools/launcher-shim.lib.sh" \
   "$H14/.local/share/SLSsteam/launcher-shim.lib.sh"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s/other.orig"\nexec /broken/mismatch-lib\n' \
  "$MISMATCH_LIB_BACKUP" > "$MISMATCH_LIB_ROOT/usr/bin/steam"
printf '#!/bin/sh\nprintf "MISMATCH-LIB-FLAT\\n"\n' > "$MISMATCH_LIB_BACKUP/steam.orig"
chmod 0755 "$MISMATCH_LIB_ROOT/usr/bin/steam" "$MISMATCH_LIB_BACKUP/steam.orig"
SLSM_LAUNCHER_DIRS=("$MISMATCH_LIB_ROOT/usr/bin")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0
SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0
if restore_system_launchers >/dev/null 2>&1; then mismatch_lib_result=yes; else mismatch_lib_result=no; fi
ck "shared library rejects unassociated flat backup" "no" "$mismatch_lib_result"
ck "shared library keeps unassociated shim state" "1" "$SLSM_KEEP_LAUNCHER_TREE"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

# Exercise the top-level cleanup guard: when restoration cannot recover a shim,
# uninstall_slsteam_moon must retain the wrapper tree instead of deleting it.
H13="$TMP/h13"; HOME="$H13"; export HOME
KEEP_TREE="$H13/.local/share/SLSsteam"
KEEP_BIN="$TMP/keep-tree-bin"
mkdir -p "$KEEP_TREE/path" "$KEEP_BIN" "$H13/no-system-apps" "$H13/no-system-autostart"
printf '#!/bin/sh\nprintf "KEEP-WRAPPER\\n"\n' > "$KEEP_TREE/path/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nexec /broken/no-backup\n' > "$KEEP_BIN/steam"
chmod 0755 "$KEEP_TREE/path/steam" "$KEEP_BIN/steam"
SLSM_LAUNCHER_DIRS=("$KEEP_BIN")
SLSM_SYS_APPS="$H13/no-system-apps"; SLSM_SYS_AUTOSTART="$H13/no-system-autostart"
HEAL_SYS_DESKTOP="$H13/no-system-desktop/steam.desktop"
disarm_desktop_guardian(){ :; }
record_shortcut_modes(){ :; }
restore_user_desktop_entries(){ :; }
restore_system_desktop_entries(){ :; }
heal_steam_launcher(){ :; }
restore_shortcut_modes(){ :; }
uninstall_slsteam_moon >/dev/null 2>&1
ck "failed launcher restore retains complete SLSsteam tree" "yes" \
   "$([ -d "$KEEP_TREE" ] && echo yes || echo no)"
ck "retained tree keeps the wrapper usable" "KEEP-WRAPPER" \
   "$(sh "$KEEP_TREE/path/steam" | head -1)"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

# The no-library mismatch must also retain the complete tree through the actual
# top-level uninstall, not merely report failure from the restore helper.
H15="$TMP/h15"; HOME="$H15"; export HOME
FULL_MISMATCH_ROOT="$TMP/full-mismatch"
FULL_MISMATCH_BACKUP="$H15/.local/share/SLSsteam/system-launcher-backup"
FULL_MISMATCH_TREE="$H15/.local/share/SLSsteam"
mkdir -p "$FULL_MISMATCH_ROOT/usr/bin" "$FULL_MISMATCH_BACKUP" \
  "$FULL_MISMATCH_TREE/path" "$H15/no-system-apps" "$H15/no-system-autostart"
printf '#!/bin/sh\nprintf "FULL-WRAPPER\\n"\n' > "$FULL_MISMATCH_TREE/path/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s/other.orig"\nexec /broken/full-mismatch\n' \
  "$FULL_MISMATCH_BACKUP" > "$FULL_MISMATCH_ROOT/usr/bin/steam"
printf '#!/bin/sh\nprintf "FULL-STALE-FLAT\\n"\n' > "$FULL_MISMATCH_BACKUP/steam.orig"
chmod 0755 "$FULL_MISMATCH_TREE/path/steam" "$FULL_MISMATCH_ROOT/usr/bin/steam" \
  "$FULL_MISMATCH_BACKUP/steam.orig"
SLSM_LAUNCHER_DIRS=("$FULL_MISMATCH_ROOT/usr/bin")
SLSM_SYS_APPS="$H15/no-system-apps"; SLSM_SYS_AUTOSTART="$H15/no-system-autostart"
HEAL_SYS_DESKTOP="$H15/no-system-desktop/steam.desktop"
uninstall_slsteam_moon >/dev/null 2>&1
ck "full uninstall retains unassociated-flat tree" "yes" \
   "$([ -d "$FULL_MISMATCH_TREE" ] && echo yes || echo no)"
ck "full uninstall retains unassociated shim" "yes" \
   "$(is_our_launcher_shim "$FULL_MISMATCH_ROOT/usr/bin/steam" && echo yes || echo no)"
ck "full uninstall retains unassociated flat backup" "yes" \
   "$([ -f "$FULL_MISMATCH_BACKUP/steam.orig" ] && echo yes || echo no)"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

ck "uninstaller clears the persisted coverage policy" "yes" \
   "$(grep -qE 'dc_forget_policy|coverage\.policy' "$HERE/uninstall.sh" && echo yes || echo no)"
ck "uninstaller supports the shared launcher restore library" "yes" \
   "$(grep -q 'ls_restore_shims' "$HERE/uninstall.sh" && echo yes || echo no)"
BODY_LINE="$(grep -n '^uninstall_slsteam_moon()' "$HERE/uninstall.sh" | cut -d: -f1)"
POLICY_LINE="$(awk -v s="$BODY_LINE" 'NR>=s && /dc_forget_policy/{print NR; exit}' "$HERE/uninstall.sh")"
LAUNCHER_RESTORE_LINE="$(awk -v s="$BODY_LINE" 'NR>=s && /restore_system_launchers[[:space:];]/{print NR; exit}' "$HERE/uninstall.sh")"
ck "policy cleanup follows launcher restoration" "after" \
   "$([ -n "$POLICY_LINE" ] && [ -n "$LAUNCHER_RESTORE_LINE" ] && [ "$POLICY_LINE" -gt "$LAUNCHER_RESTORE_LINE" ] && echo after || echo before)"

# Without the shared library, a flat backup belongs to the exact shim that
# references it. An unrelated surviving shim must not block that restoration.
H16="$TMP/h16"; HOME="$H16"; export HOME
NO_LIB_MIX_ROOT="$TMP/no-library-mixed-candidates"
NO_LIB_MIX_BACKUP="$H16/.local/share/SLSsteam/system-launcher-backup"
NO_LIB_MIX_FIRST="$NO_LIB_MIX_ROOT/usr/bin"
NO_LIB_MIX_OWNER="$NO_LIB_MIX_ROOT/usr/games"
mkdir -p "$NO_LIB_MIX_FIRST" "$NO_LIB_MIX_OWNER" "$NO_LIB_MIX_BACKUP"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s/missing.orig"\nexec /broken/no-library-first\n' \
  "$NO_LIB_MIX_BACKUP" > "$NO_LIB_MIX_FIRST/steam"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\nSLSM_ORIG="%s/steam.orig"\nexec /broken/no-library-owner\n' \
  "$NO_LIB_MIX_BACKUP" > "$NO_LIB_MIX_OWNER/steam"
printf '#!/bin/sh\nprintf "NO-LIB-FLAT-OWNER\\n"\n' > "$NO_LIB_MIX_BACKUP/steam.orig"
chmod 0755 "$NO_LIB_MIX_FIRST/steam" "$NO_LIB_MIX_OWNER/steam" \
  "$NO_LIB_MIX_BACKUP/steam.orig"
SLSM_LAUNCHER_DIRS=("$NO_LIB_MIX_FIRST" "$NO_LIB_MIX_OWNER")
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0
SLSM_SUDO_PRIMED=1; SLSM_SUDO_DENIED=0; SUDO_FAIL=0; export SUDO_FAIL
OS_RELEASE_FILE=/dev/null
if restore_system_launchers >/dev/null 2>&1; then no_lib_candidate_result=yes; else no_lib_candidate_result=no; fi
ck "flat fallback retains unresolved launcher state" "no" "$no_lib_candidate_result"
ck "flat fallback leaves unrelated shim retryable" "yes" \
   "$(is_our_launcher_shim "$NO_LIB_MIX_FIRST/steam" && echo yes || echo no)"
ck "flat fallback retains complete tree state" "1" "$SLSM_KEEP_LAUNCHER_TREE"
ck "flat fallback restores the exact flat owner" "NO-LIB-FLAT-OWNER" \
   "$(sh "$NO_LIB_MIX_OWNER/steam" | head -1)"
unset SLSM_LAUNCHER_DIRS
SLSM_KEEP_LAUNCHER_BACKUP=0; SLSM_KEEP_LAUNCHER_TREE=0

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
