#!/usr/bin/env bash
# Unit tests for the uninstaller's desktop restoration and for taking the
# desktop guardian out of the picture before that restoration runs.
#
# Reproduces the CachyOS/KDE report: after `uninstall.sh`, both the desktop
# shortcut and the KDE launcher still pointed at
# ~/.local/share/SLSsteam/path/steam ("Could not find the program …"), and
# ~/.local/share/SLSsteam/backup had come back from the dead.
#
# Root cause: slsteam-desktop-guardian.path watches the very directories a
# restore writes to, so restoring TRIGGERED the guardian, which re-patched every
# entry, re-created the central backups and re-installed its own units. Tearing
# the units down after the restore loses that race. Contributing causes: the
# backstop only knew two fixed filenames (never the desktop shortcut, which on a
# localized session is not ~/Desktop), and a missing backup deleted the user's
# launcher instead of repairing it.
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

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
OS_RELEASE_FILE=/dev/null; export OS_RELEASE_FILE

# A systemctl stub: records every call and always reports the oneshot inactive
# so wait_guardian_idle returns immediately.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$SYSTEMCTL_LOG"
case "$*" in *"is-active"*) echo inactive ;; esac
exit 0
STUB
chmod +x "$ROOT/bin/systemctl"
PATH="$ROOT/bin:$PATH"; export PATH

# new_home <name> — an installed-looking tree with a localized desktop dir, so
# every test also proves XDG_DESKTOP_DIR is honoured (pt_BR: "Área de trabalho").
DESK='Área de trabalho'
new_home() {
	HOME="$ROOT/$1"; export HOME
	mkdir -p "$HOME/.config" "$HOME/.local/share/applications" \
	         "$HOME/.config/autostart" "$HOME/$DESK" \
	         "$HOME/.local/share/SLSsteam/path"
	printf 'XDG_DESKTOP_DIR="$HOME/%s"\n' "$DESK" > "$HOME/.config/user-dirs.dirs"
	: > "$HOME/.local/share/SLSsteam/path/steam"
	SYSTEMCTL_LOG="$HOME/systemctl.log"; export SYSTEMCTL_LOG
	: > "$SYSTEMCTL_LOG"
}

# write_patched <file> [seeded] — an entry as our installer leaves it.
write_patched() {
	local f="$1" seed="${2:-}"
	mkdir -p "$(dirname "$f")"
	{
		echo '[Desktop Entry]'
		echo 'X-SLSteamMoon-Patched=true'
		[ "$seed" = seeded ] && echo 'X-SLSteamMoon-Seeded=true'
		echo 'Name=Steam'
		echo "Exec=$HOME/.local/share/SLSsteam/path/steam %U"
		echo 'Icon=steam'
		echo 'Type=Application'
	} > "$f"
}

write_backup() {
	local original="$1" bak
	bak="$(desktop_backup_path "$original")"
	mkdir -p "$(dirname "$bak")"
	printf '[Desktop Entry]\nName=Steam\nExec=/usr/bin/steam %%U\nIcon=steam\nType=Application\n' > "$bak"
	printf '%s\n' "$bak"
}

echo "== XDG desktop dir resolution =="
new_home xdg
ck "honours a localized XDG_DESKTOP_DIR" "$HOME/$DESK" "$(uninstall_desktop_dir)"
printf 'XDG_DESKTOP_DIR="${HOME}/Bureau"\n' > "$HOME/.config/user-dirs.dirs"
ck "accepts the \${HOME} form"           "$HOME/Bureau" "$(uninstall_desktop_dir)"
: > "$HOME/.config/user-dirs.dirs"
ck "falls back to ~/Desktop"             "$HOME/Desktop" "$(uninstall_desktop_dir)"
ck "matches .desktop case-insensitively" "yes" \
   "$(is_desktop_file_name /x/STEAM.DESKTOP && echo yes || echo no)"
ck "ignores non-desktop files"           "no" \
   "$(is_desktop_file_name /x/steam.png && echo yes || echo no)"
# The sweep must NOT filter by filename: Steam's per-game shortcuts are patched
# by Exec content and are not named *steam*.desktop.
ck "a game shortcut name is a sweep candidate" "yes" \
   "$(is_desktop_file_name '/x/Gang Beasts.desktop' && echo yes || echo no)"

echo
echo "== the desktop shortcut is restored, not left pointing at the wrapper =="
new_home shortcut
SC="$HOME/$DESK/steam.desktop"
write_patched "$SC"; chmod 0755 "$SC"
BAK="$(write_backup "$SC")"
restore_user_desktop_entries >/dev/null 2>&1
ck "shortcut Exec restored from backup" "Exec=/usr/bin/steam %U" "$(grep -m1 '^Exec=' "$SC")"
ck "shortcut no longer references our tree" "0" "$(grep -c 'SLSsteam' "$SC")"
ck "shortcut stays executable"          "755" "$(stat -c '%a' "$SC")"
ck "consumed backup is deleted"         "no"  "$([ -e "$BAK" ] && echo yes || echo no)"

echo
echo "== a shortcut with no backup is repaired, never silently deleted =="
new_home nobackup
SC="$HOME/$DESK/steam.desktop"
write_patched "$SC"; chmod 0755 "$SC"
restore_user_desktop_entries >/dev/null 2>&1
ck "shortcut survives"                  "yes" "$([ -f "$SC" ] && echo yes || echo no)"
ck "shortcut launches vanilla steam"    "Exec=steam %U" "$(grep -m1 '^Exec=' "$SC")"
ck "our tags are gone"                  "0"   "$(grep -c 'X-SLSteamMoon' "$SC")"
ck "still executable"                   "755" "$(stat -c '%a' "$SC")"

echo
echo "== an entry we created is deleted, not restored to a file never owned =="
new_home seeded
SHADOW="$HOME/.local/share/applications/steam.desktop"
AUTO="$HOME/.config/autostart/steam.desktop"
write_patched "$SHADOW" seeded
write_patched "$AUTO" seeded
restore_user_desktop_entries >/dev/null 2>&1
ck "seeded application shadow removed" "no" "$([ -e "$SHADOW" ] && echo yes || echo no)"
ck "seeded autostart override removed" "no" "$([ -e "$AUTO" ] && echo yes || echo no)"

echo
echo "== every steam-named entry is swept, not just steam.desktop =="
new_home names
A="$HOME/.local/share/applications/steam-native.desktop"
B="$HOME/.local/share/applications/bazzite-steam.desktop"
C="$HOME/.local/share/applications/firefox.desktop"
write_patched "$A"; write_backup "$A" >/dev/null
write_patched "$B"; write_backup "$B" >/dev/null
printf '[Desktop Entry]\nName=Firefox\nExec=firefox %%u\n' > "$C"
restore_user_desktop_entries >/dev/null 2>&1
ck "steam-native.desktop restored"  "Exec=/usr/bin/steam %U" "$(grep -m1 '^Exec=' "$A")"
ck "bazzite-steam.desktop restored" "Exec=/usr/bin/steam %U" "$(grep -m1 '^Exec=' "$B")"
ck "unrelated entry untouched"      "Exec=firefox %u"        "$(grep -m1 '^Exec=' "$C")"

echo
echo "== Steam's per-game shortcuts are restored too (not named *steam*) =="
# The guardian classifies by Exec content, so "Gang Beasts.desktop" gets patched
# and backed up like any launcher. A name-based sweep skipped exactly these and
# left them pointing at the deleted wrapper.
new_home games
G="$HOME/.local/share/applications/Gang Beasts.desktop"
M="$HOME/$DESK/Mina the Hollower.desktop"
mkdir -p "$(dirname "$G")" "$(dirname "$M")"
for target in "$G" "$M"; do
	{
		echo '[Desktop Entry]'
		echo 'X-SLSteamMoon-Patched=true'
		echo 'Name=A Game'
		echo "Exec=$HOME/.local/share/SLSsteam/path/steam steam://rungameid/285900"
		echo 'Type=Application'
	} > "$target"
done
GB="$(desktop_backup_path "$G")"
mkdir -p "$(dirname "$GB")"
printf '[Desktop Entry]\nName=A Game\nExec=steam steam://rungameid/285900\nType=Application\n' > "$GB"
chmod 0755 "$M"
restore_user_desktop_entries >/dev/null 2>&1
ck "game shortcut restored from backup" "Exec=steam steam://rungameid/285900" "$(grep -m1 '^Exec=' "$G")"
ck "game shortcut without backup repaired in place" "Exec=steam steam://rungameid/285900" \
   "$(grep -m1 '^Exec=' "$M")"
ck "no game shortcut still points at our tree" "0" \
   "$(grep -lc 'SLSsteam' "$G" "$M" 2>/dev/null | wc -l)"

echo
echo "== a foreign entry mentioning SLSsteam is never deleted =="
# The sweep is content-based, so it can land on a file that is not ours. Such a
# file may be warned about, but must survive.
new_home foreignentry
FE="$HOME/.local/share/applications/my-tool.desktop"
printf '[Desktop Entry]\nName=My Tool\nComment=reads ~/.SLSsteam.log\nExec=/opt/mytool --log %s/.local/share/SLSsteam/log\nType=Application\n' "$HOME" > "$FE"
restore_user_desktop_entries >/dev/null 2>&1
ck "foreign entry survives"        "yes" "$([ -f "$FE" ] && echo yes || echo no)"
ck "foreign entry left unmodified" "Exec=/opt/mytool --log $HOME/.local/share/SLSsteam/log" \
   "$(grep -m1 '^Exec=' "$FE")"

echo
echo "== a backup that outlived its file is still put back =="
new_home orphan
GONE="$HOME/.local/share/applications/steam.desktop"
write_backup "$GONE" >/dev/null
restore_user_desktop_entries >/dev/null 2>&1
ck "orphaned backup restored"    "Exec=/usr/bin/steam %U" "$(grep -m1 '^Exec=' "$GONE" 2>/dev/null)"
ck "backup mirror is emptied"    "0" \
   "$(find "$HOME/.local/share/SLSsteam/backup" -type f -name '*.desktop' 2>/dev/null | wc -l)"

echo
echo "== guardian disarm =="
new_home guardian
UD="$HOME/.config/systemd/user"
mkdir -p "$UD/default.target.wants" "$UD/timers.target.wants" \
         "$UD/app-steam@autostart.service.d"
for u in path timer service; do
	printf '# X-SLSteamMoon-GuardianUnit=true\n[Unit]\nDescription=x\n' \
		> "$UD/slsteam-desktop-guardian.$u"
done
ln -sf "$UD/slsteam-desktop-guardian.path"  "$UD/default.target.wants/slsteam-desktop-guardian.path"
ln -sf "$UD/slsteam-desktop-guardian.timer" "$UD/timers.target.wants/slsteam-desktop-guardian.timer"
printf '# X-SLSteamMoon-AutostartDropIn=true\n[Service]\nExecStart=\n' \
	> "$UD/app-steam@autostart.service.d/slsteam-guardian.conf"
: > "$HOME/.local/share/SLSsteam/ensure-desktop-coverage.sh"
: > "$HOME/.local/share/SLSsteam/desktop-coverage.lib.sh"

disarm_desktop_guardian >/dev/null 2>&1

ck "path unit removed"    "no" "$([ -e "$UD/slsteam-desktop-guardian.path" ] && echo yes || echo no)"
ck "timer unit removed"   "no" "$([ -e "$UD/slsteam-desktop-guardian.timer" ] && echo yes || echo no)"
ck "service unit removed" "no" "$([ -e "$UD/slsteam-desktop-guardian.service" ] && echo yes || echo no)"
ck "default.target.wants link removed" "no" \
   "$([ -e "$UD/default.target.wants/slsteam-desktop-guardian.path" ] || \
      [ -L "$UD/default.target.wants/slsteam-desktop-guardian.path" ] && echo yes || echo no)"
ck "timers.target.wants link removed" "no" \
   "$([ -e "$UD/timers.target.wants/slsteam-desktop-guardian.timer" ] || \
      [ -L "$UD/timers.target.wants/slsteam-desktop-guardian.timer" ] && echo yes || echo no)"
ck "autostart drop-in removed" "no" \
   "$([ -e "$UD/app-steam@autostart.service.d/slsteam-guardian.conf" ] && echo yes || echo no)"
# The reconciliation CLI must go BEFORE anything is restored, so a trigger we
# could not reach can no longer re-patch a file. The coverage library must stay:
# dc_restore_all is what consumes the central backups.
ck "reconciliation CLI neutralized" "no" \
   "$([ -e "$HOME/.local/share/SLSsteam/ensure-desktop-coverage.sh" ] && echo yes || echo no)"
ck "coverage library retained for the restore" "yes" \
   "$([ -e "$HOME/.local/share/SLSsteam/desktop-coverage.lib.sh" ] && echo yes || echo no)"
ck "triggers disabled via systemd" "yes" \
   "$(grep -q 'disable --now .*slsteam-desktop-guardian.path' "$SYSTEMCTL_LOG" && echo yes || echo no)"
ck "in-flight service stopped"     "yes" \
   "$(grep -q 'stop slsteam-desktop-guardian.service' "$SYSTEMCTL_LOG" && echo yes || echo no)"
ck "manager reloaded after removal" "yes" \
   "$(grep -qxF -- '--user daemon-reload' "$SYSTEMCTL_LOG" && echo yes || echo no)"

echo
echo "== a foreign unit sharing our name is never removed =="
new_home foreign
UD="$HOME/.config/systemd/user"
mkdir -p "$UD"
printf '[Unit]\nDescription=somebody else\n' > "$UD/slsteam-desktop-guardian.service"
disarm_desktop_guardian >/dev/null 2>&1
ck "unsentineled unit preserved" "yes" \
   "$([ -e "$UD/slsteam-desktop-guardian.service" ] && echo yes || echo no)"

echo
echo "== disarm works with nothing installed (stale units, tree already gone) =="
new_home stale
rm -rf "$HOME/.local/share/SLSsteam"
UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
printf '# X-SLSteamMoon-GuardianUnit=true\n[Unit]\n' > "$UD/slsteam-desktop-guardian.timer"
disarm_desktop_guardian >/dev/null 2>&1
ck "stale unit removed without the library" "no" \
   "$([ -e "$UD/slsteam-desktop-guardian.timer" ] && echo yes || echo no)"

echo
echo "== structural: ordering inside uninstall_slsteam_moon =="
BODY="$(grep -n '^uninstall_slsteam_moon()' "$HERE/uninstall.sh" | cut -d: -f1)"
# Regex lookup for anchored call sites, fixed-string lookup for anything
# containing shell metacharacters (awk -v mangles backslash escapes).
line_re()    { awk -v s="$BODY" -v pat="$1" 'NR>=s && $0 ~ pat {print NR; exit}' "$HERE/uninstall.sh"; }
line_fixed() { awk -v s="$BODY" -v pat="$1" 'NR>=s && index($0, pat) {print NR; exit}' "$HERE/uninstall.sh"; }
DISARM="$(line_re '^[[:space:]]*disarm_desktop_guardian[[:space:]]*$')"
RESTORE_ALL="$(line_re '^[[:space:]]*dc_restore_all[[:space:]]*$')"
SWEEP="$(line_re '^[[:space:]]*restore_user_desktop_entries[[:space:]]*$')"
RM="$(line_fixed 'rm -rf "$HOME/.local/share/SLSsteam"')"
ck "disarm is called"                    "yes" "$([ -n "$DISARM" ] && echo yes || echo no)"
# The whole bug: with the guardian still armed, restoring triggers it and it
# patches everything straight back.
ck "disarm runs before dc_restore_all"   "before" \
   "$([ -n "$DISARM" ] && [ -n "$RESTORE_ALL" ] && [ "$DISARM" -lt "$RESTORE_ALL" ] && echo before || echo after)"
ck "disarm runs before the user sweep"   "before" \
   "$([ -n "$DISARM" ] && [ -n "$SWEEP" ] && [ "$DISARM" -lt "$SWEEP" ] && echo before || echo after)"
ck "disarm runs before the tree is deleted" "before" \
   "$([ -n "$DISARM" ] && [ -n "$RM" ] && [ "$DISARM" -lt "$RM" ] && echo before || echo after)"
# The removal must be verified rather than assumed: a resurrected backup/ tree
# surviving `rm -rf` is how the original report was diagnosed.
ck "tree removal is verified" "yes" \
   "$(awk -v s="$RM" 'NR>s && NR<s+14 && /Could not fully remove/{f=1} END{print f?"yes":"no"}' "$HERE/uninstall.sh")"
ck "guardian state directory is removed" "yes" \
   "$(grep -q 'uninstall_state_home)/slsteam-moon' "$HERE/uninstall.sh" && echo yes || echo no)"

echo
echo "== the desktop shortcut keeps its original permissions =="
# The shared library restores every entry as 0644 (dc_restore_one), stripping the
# executable bit KDE/GNOME need on a desktop shortcut. Observed on a real VM run:
# content byte-identical, mode 755 -> 644.
new_home modes
SC="$HOME/$DESK/steam.desktop"
write_patched "$SC"; chmod 0755 "$SC"
record_shortcut_modes
# Stand in for dc_restore_one: right content, flattened mode.
printf '[Desktop Entry]\nName=Steam\nExec=/usr/bin/steam %%U\n' > "$SC"
chmod 0644 "$SC"
restore_shortcut_modes >/dev/null 2>&1
ck "executable bit is restored" "755" "$(stat -c '%a' "$SC")"
# A mode that was never executable must stay as it was.
new_home modes2
PLAIN="$HOME/$DESK/notes.desktop"
printf '[Desktop Entry]\nName=Notes\nExec=notes\n' > "$PLAIN"; chmod 0644 "$PLAIN"
record_shortcut_modes
restore_shortcut_modes >/dev/null 2>&1
ck "a non-executable entry is left alone" "644" "$(stat -c '%a' "$PLAIN")"

echo
echo "== behavioral: a trigger firing after the disarm cannot re-patch =="
# The ordering assertions above are textual. This one is not: a fake
# reconciliation CLI that re-patches everything stands in for the guardian pass,
# and a systemctl that ignores disable/stop stands in for a manager we cannot
# reach. Neutralizing the CLI is what has to hold the line.
new_home race
cat > "$ROOT/bin/systemctl" <<'DEAF'
#!/bin/sh
echo "$*" >> "$SYSTEMCTL_LOG"
case "$*" in *"is-active"*) echo inactive ;; esac
exit 0
DEAF
chmod +x "$ROOT/bin/systemctl"
CLI="$HOME/.local/share/SLSsteam/ensure-desktop-coverage.sh"
cat > "$CLI" <<'REPATCH'
#!/bin/sh
for f in "$HOME/.local/share/applications"/*.desktop "$HOME/Área de trabalho"/*.desktop; do
	[ -f "$f" ] || continue
	grep -q X-SLSteamMoon-Patched "$f" 2>/dev/null && continue
	sed -i -e "s|Exec=/usr/bin/steam|Exec=$HOME/.local/share/SLSsteam/path/steam|g" \
	       -e '1a X-SLSteamMoon-Patched=true' "$f"
done
REPATCH
chmod +x "$CLI"
: > "$HOME/.local/share/SLSsteam/desktop-coverage.lib.sh"
SC="$HOME/$DESK/steam.desktop"
APP="$HOME/.local/share/applications/steam-native.desktop"
write_patched "$SC"; chmod 0755 "$SC"; write_backup "$SC" >/dev/null
write_patched "$APP"; write_backup "$APP" >/dev/null

# Sanity: the stand-in really does re-patch while it is still in place.
"$CLI" >/dev/null 2>&1
ck "the stand-in re-patches while armed" "1" "$(grep -c 'SLSsteam/path/steam' "$SC")"

disarm_desktop_guardian >/dev/null 2>&1
restore_user_desktop_entries >/dev/null 2>&1
# Fire the trigger again, mid-uninstall and after the restore.
"$CLI" >/dev/null 2>&1 || true
ck "shortcut stays restored"      "Exec=/usr/bin/steam %U" "$(grep -m1 '^Exec=' "$SC")"
ck "application stays restored"   "Exec=/usr/bin/steam %U" "$(grep -m1 '^Exec=' "$APP")"
ck "nothing points at our tree"   "0" \
   "$(grep -l 'SLSsteam' "$SC" "$APP" 2>/dev/null | wc -l)"
ck "no backup tree was resurrected" "0" \
   "$(find "$HOME/.local/share/SLSsteam/backup" -type f 2>/dev/null | wc -l)"

echo
echo "== a disabled Steam autostart is not silently re-enabled =="
# Steam deletes ~/.config/autostart/steam.desktop when "run at startup" is turned
# off. A backup we still hold must not resurrect it.
new_home autostart
AUTO="$HOME/.config/autostart/steam.desktop"
write_backup "$AUTO" >/dev/null
APPGONE="$HOME/.local/share/applications/steam.desktop"
write_backup "$APPGONE" >/dev/null
restore_user_desktop_entries >/dev/null 2>&1
ck "autostart entry is NOT recreated" "no"  "$([ -e "$AUTO" ] && echo yes || echo no)"
ck "application entry IS recreated"   "yes" "$([ -e "$APPGONE" ] && echo yes || echo no)"

echo
echo "== a legacy inline LD_AUDIT launcher is repaired, not deleted =="
# Older installs put LD_AUDIT straight into Exec. If the strip fails, the entry
# still reads as ours and the no-backup path DELETES it — the very regression
# this file exists to prevent.
new_home ldaudit
LEG="$HOME/.local/share/applications/steam.desktop"
mkdir -p "$(dirname "$LEG")"
printf '[Desktop Entry]\nX-SLSteamMoon-Patched=true\nName=Steam\nExec=env LD_AUDIT=%s/.local/share/SLSsteam/SLSsteam.so steam %%U\nType=Application\n' \
	"$HOME" > "$LEG"
restore_user_desktop_entries >/dev/null 2>&1
ck "legacy entry survives"            "yes" "$([ -f "$LEG" ] && echo yes || echo no)"
ck "LD_AUDIT assignment is stripped"  "Exec=env steam %U" "$(grep -m1 '^Exec=' "$LEG" 2>/dev/null)"
ck "no reference to our tree remains" "0"   "$(grep -c 'SLSsteam' "$LEG" 2>/dev/null)"

echo
echo "== a foreign symlinked entry is never removed =="
new_home symlink
ln -sf /usr/share/applications/firefox.desktop \
	"$HOME/.local/share/applications/my-editor.desktop"
ln -sf /usr/share/applications/firefox.desktop "$HOME/$DESK/my-editor.desktop"
restore_user_desktop_entries >/dev/null 2>&1
ck "symlink in the applications layer survives" "yes" \
   "$([ -L "$HOME/.local/share/applications/my-editor.desktop" ] && echo yes || echo no)"
ck "symlink on the desktop survives"            "yes" \
   "$([ -L "$HOME/$DESK/my-editor.desktop" ] && echo yes || echo no)"

echo
echo "== the system layer is selected by content, in any letter case =="
new_home system
SYSA="$ROOT/system/sysapps"; SYSB="$ROOT/system/sysautostart"
rm -rf "$ROOT/system"; mkdir -p "$SYSA" "$SYSB"
# Capitalized and game-shortcut names both have to be found.
write_patched "$SYSA/Steam.desktop"
write_patched "$SYSB/steam.desktop"
printf '[Desktop Entry]\nName=Firefox\nExec=firefox\n' > "$SYSA/firefox.desktop"
SLSM_SYS_APPS="$SYSA" SLSM_SYS_AUTOSTART="$SYSB" found="$(SLSM_SYS_APPS="$SYSA" SLSM_SYS_AUTOSTART="$SYSB" system_patched_desktop_entries | sort)"
ck "finds a capitalized system entry" "yes" \
   "$(printf '%s\n' "$found" | grep -qF "$SYSA/Steam.desktop" && echo yes || echo no)"
ck "finds a system autostart entry"   "yes" \
   "$(printf '%s\n' "$found" | grep -qF "$SYSB/steam.desktop" && echo yes || echo no)"
ck "ignores unrelated system entries" "no" \
   "$(printf '%s\n' "$found" | grep -qF firefox && echo yes || echo no)"
# And with pending system work but no privileges, the user is told rather than
# left guessing.
out="$(SLSM_SYS_APPS="$SYSA" SLSM_SYS_AUTOSTART="$SYSB" SLSM_SUDO_PRIMED=0 \
       SLSM_SUDO_DENIED=1 restore_system_desktop_entries 2>&1)"
ck "warns when the system layer cannot be restored" "yes" \
   "$(printf '%s' "$out" | grep -qi 'sistema\|system' && echo yes || echo no)"

echo
echo "== privileges are requested at most once =="
new_home prompt
mkdir -p "$HOME/.local/share/SLSsteam/system-launcher-backup"
: > "$HOME/.local/share/SLSsteam/system-launcher-backup/steam.orig"
cat > "$ROOT/bin/sudo" <<'SUDOSTUB'
#!/bin/sh
echo "call" >> "$SUDO_CALLS"
exit 1
SUDOSTUB
chmod +x "$ROOT/bin/sudo"
SUDO_CALLS="$HOME/sudo.calls"; export SUDO_CALLS
: > "$SUDO_CALLS"
SLSM_SUDO_PRIMED=0; SLSM_SUDO_DENIED=0
prime_sudo >/dev/null 2>&1
prime_sudo >/dev/null 2>&1
prime_sudo >/dev/null 2>&1
# One `sudo -n true` probe plus one `sudo -v` prompt, then the denial latches.
ck "denial latches after the first attempt" "2" "$(wc -l < "$SUDO_CALLS")"
rm -f "$ROOT/bin/sudo"

echo
echo "== the script is safe to source under set -u =="
# A `${#arr[@]}` on an unset array aborts the sourced file and silently leaves
# every later function undefined, which `bash -n` cannot catch.
SRC_ERR="$ROOT/source.err"
( set -u; SLSPLUGIN_LIB_ONLY=1 . "$HERE/uninstall.sh"; \
  for fn in main uninstall_slsteam_moon restore_system_launchers \
            disarm_desktop_guardian restore_user_desktop_entries; do
    [ "$(type -t "$fn")" = function ] || { echo "missing:$fn" >&2; exit 1; }
  done ) 2> "$SRC_ERR"
ck "sourcing defines every function" "0" "$?"
ck "sourcing is silent on stderr"    ""  "$(cat "$SRC_ERR")"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
