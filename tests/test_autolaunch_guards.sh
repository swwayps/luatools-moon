#!/usr/bin/env bash
# Unit tests for the guarded auto-launch predicate. Sourcing install.sh with
# SLSPLUGIN_LIB_ONLY=1 defines the functions WITHOUT running main().
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SLSPLUGIN_LIB_ONLY=1 . "$HERE/install.sh"
fail=0
ck(){ if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (want $2 got $3)"; fail=1; fi; }

# display + desktop (not gamescope) + not opted out -> launch
ck "display + desktop -> launch" "yes" \
  "$(OPT_NOLAUNCH=0 SLS_NO_LAUNCH= DISPLAY=:0 WAYLAND_DISPLAY= GAMESCOPE=0 should_autolaunch && echo yes || echo no)"
# no display at all -> skip
ck "no display -> skip" "no" \
  "$(OPT_NOLAUNCH=0 SLS_NO_LAUNCH= DISPLAY= WAYLAND_DISPLAY= GAMESCOPE=0 should_autolaunch && echo yes || echo no)"
# --nolaunch -> skip
ck "--nolaunch -> skip" "no" \
  "$(OPT_NOLAUNCH=1 SLS_NO_LAUNCH= DISPLAY=:0 GAMESCOPE=0 should_autolaunch && echo yes || echo no)"
# SLS_NO_LAUNCH env -> skip
ck "SLS_NO_LAUNCH -> skip" "no" \
  "$(OPT_NOLAUNCH=0 SLS_NO_LAUNCH=1 DISPLAY=:0 should_autolaunch && echo yes || echo no)"
# Bazzite/SteamOS Desktop mode (installer only ever runs here) -> launch
ck "deck desktop mode -> launch" "yes" \
  "$(OPT_NOLAUNCH=0 SLS_NO_LAUNCH= WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE should_autolaunch && echo yes || echo no)"

# do_autolaunch must exist and usage must document --nolaunch
type do_autolaunch >/dev/null 2>&1 && echo "ok   - do_autolaunch defined" || { echo "FAIL - do_autolaunch missing"; fail=1; }
grep -q -- '--nolaunch' "$HERE/install.sh" && echo "ok   - usage documents --nolaunch" || { echo "FAIL - usage lacks --nolaunch"; fail=1; }
grep -q 'should_autolaunch' "$HERE/install.sh" && echo "ok   - main gates on should_autolaunch" || { echo "FAIL - main does not gate"; fail=1; }

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
