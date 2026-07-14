#!/usr/bin/env bash
# The standalone uninstaller must restore .desktop originals from the central
# SLSsteam/backup mirror and consume legacy adjacent backups when encountered.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME="$TMP/home"; export HOME
mkdir -p "$HOME"
# Load function definitions without executing uninstall main().
sed '/^main "\$@"$/d' "$HERE/uninstall.sh" > "$TMP/uninstall-lib.sh"
# shellcheck source=/dev/null
. "$TMP/uninstall-lib.sh"

fail=0
check() {
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s (want=[%s] got=[%s])\n' "$1" "$2" "$3"; fail=1; fi
}

active="$HOME/.local/share/applications/steam.desktop"
central="$HOME/.local/share/SLSsteam/backup/${active#/}"
mkdir -p "$(dirname "$active")" "$(dirname "$central")"
printf '[Desktop Entry]\nX-SLSteamMoon-Patched=true\nName=Steam\nExec=%s/.local/share/SLSsteam/path/steam %%U\n' "$HOME" > "$active"
printf '[Desktop Entry]\nName=Steam\nExec=/usr/bin/steam %%U\n' > "$central"
restore_or_remove_desktop "$active"
check "uninstaller restores central backup" "Exec=/usr/bin/steam %U" "$(grep -m1 '^Exec=' "$active")"
check "uninstaller consumes central backup" "no" "$([ -e "$central" ] && echo yes || echo no)"

legacy="$active.slssteam-backup"
printf '[Desktop Entry]\nX-SLSteamMoon-Patched=true\nName=Steam\nExec=%s/.local/share/SLSsteam/path/steam %%U\n' "$HOME" > "$active"
printf '[Desktop Entry]\nName=Steam\nExec=/usr/games/steam %%U\n' > "$legacy"
restore_or_remove_desktop "$active"
check "uninstaller accepts legacy adjacent backup" "Exec=/usr/games/steam %U" "$(grep -m1 '^Exec=' "$active")"
check "uninstaller removes legacy adjacent backup" "no" "$([ -e "$legacy" ] && echo yes || echo no)"

# The uninstaller follows the same no-sudo rule as the installer on immutable
# systems, including when restoring the central backup tree.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$SUDO_CALLS"
exit 1
EOF
chmod +x "$TMP/bin/sudo"
printf 'ID=steamos\nID_LIKE=arch\n' > "$TMP/os-release"
export PATH="$TMP/bin:$PATH" SUDO_CALLS="$TMP/sudo.calls" OS_RELEASE_FILE="$TMP/os-release"
check "immutable uninstaller returns no sudo prefix" "" "$(sudo_prefix)"
check "immutable uninstaller never invokes sudo" "no" "$([ -s "$SUDO_CALLS" ] && echo yes || echo no)"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
