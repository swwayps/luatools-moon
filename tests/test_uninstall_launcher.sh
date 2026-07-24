#!/usr/bin/env bash
# Unit tests for the uninstall launcher safety net. Sourcing uninstall.sh with
# SLSPLUGIN_LIB_ONLY=1 defines functions WITHOUT running main().
#
# Reproduces the "icon disappeared after uninstall" report: dc_restore_one
# removes a patched entry when its central backup is missing, and any entry it
# leaves behind points at the about-to-be-deleted wrapper. heal_steam_launcher
# must guarantee a working steam.desktop survives.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SLSPLUGIN_LIB_ONLY=1 . "$HERE/uninstall.sh"
fail=0
ck(){ if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (want [$2] got [$3])"; fail=1; fi; }

type heal_steam_launcher >/dev/null 2>&1 \
  && echo "ok   - heal_steam_launcher defined" \
  || { echo "FAIL - heal_steam_launcher missing"; fail=1; }

# --- Case 1: a surviving entry still pointing at the wrapper is de-patched ----
R1="$(mktemp -d)"; export HOME="$R1"
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/SLSsteam/path"
WRAP="$HOME/.local/share/SLSsteam/path/steam"
cat > "$HOME/.local/share/applications/steam.desktop" <<EOF
[Desktop Entry]
X-SLSteamMoon-Patched=true
Name=Steam
Exec=$WRAP %U
Icon=steam
Type=Application
EOF
HEAL_SYS_DESKTOP="$R1/none/steam.desktop" OS_RELEASE_FILE=/dev/null heal_steam_launcher >/dev/null 2>&1
ck "de-patches wrapper Exec back to plain steam" "Exec=steam %U" \
  "$(grep -m1 '^Exec=' "$HOME/.local/share/applications/steam.desktop")"
ck "removes our ownership tag" "0" \
  "$(grep -c 'X-SLSteamMoon' "$HOME/.local/share/applications/steam.desktop")"
ck "entry no longer references the wrapper" "0" \
  "$(grep -c 'SLSsteam/path/steam' "$HOME/.local/share/applications/steam.desktop")"
rm -rf "$R1"

# --- Case 2: nothing survived restoration -> a working entry is recreated -----
R2="$(mktemp -d)"; export HOME="$R2"
mkdir -p "$HOME/.local/share/applications"
HEAL_SYS_DESKTOP="$R2/none/steam.desktop" OS_RELEASE_FILE=/dev/null heal_steam_launcher >/dev/null 2>&1
ck "recreates a user steam.desktop when none exists" "yes" \
  "$([ -f "$HOME/.local/share/applications/steam.desktop" ] && echo yes || echo no)"
ck "recreated entry launches vanilla steam" "Exec=steam %U" \
  "$(grep -m1 '^Exec=' "$HOME/.local/share/applications/steam.desktop" 2>/dev/null)"
rm -rf "$R2"

# --- Structural: uninstall must also remove the guardian units ----------------
grep -q 'dgu_remove_units\|desktop-guardian-units.lib.sh' "$HERE/uninstall.sh" \
  && echo "ok   - uninstall removes the desktop guardian units" \
  || { echo "FAIL - uninstall never removes guardian units"; fail=1; }

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
