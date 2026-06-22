#!/usr/bin/env bash
# restart_steam.sh — Linux restart helper for slsteammoon-ltsteamplugin.
#
# Upstream's auto_update.restart_steam() runs `killall steam && steam &`
# on Linux. That has two problems for slsteam-moon:
#   1. It relaunches the bare `steam` binary, NOT the slsteam-moon
#      wrapper, so SLSsteam.so is never injected (LD_AUDIT missing) and
#      the freshly-added game is not provisioned -> it doesn't appear in
#      the library.
#   2. `killall steam` matches only an exact "steam" process and the
#      `&&` means the relaunch is skipped whenever it returns non-zero
#      (common: the process is steam.sh / steamwebhelper), and there is
#      no wait, so the new client races the dying one.
#
# This script terminates Steam cleanly, waits for it to fully exit, then
# relaunches through the slsteam-moon wrapper (installed on PATH at
# ~/.local/share/SLSsteam/path/steam by slsteam-moon's setup.sh) so the
# injection + provisioning happen on the next start.
#
# Detached via setsid+nohup so it survives the dying Steam session.

set -u

# Steam exports LD_LIBRARY_PATH/LD_AUDIT pointing at its runtime; strip
# them so our relaunch and any child binaries use system libraries.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

# --- Game Mode (gamescope session) fast path --------------------------------
# On a handheld/Deck-class session Steam is NOT launched from a .desktop; it is
# supervised by a gamescope-session systemd *user* unit (Bazzite/ChimeraOS:
# gamescope-session-plus@steam.service). A plain kill+relaunch fights that
# supervisor, so when such a unit is active we just restart it — the session
# re-sources its config (incl. our STEAMCMD override) and brings Steam back
# through the slsteam-moon wrapper, so injection is preserved.
#
# Discovered generically (NOT hardcoded to "-plus") so it adapts to any distro
# that exposes a "gamescope-session*" user unit. If none is active we fall
# through to the desktop kill+relaunch path below.
if command -v systemctl >/dev/null 2>&1; then
  : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
  export XDG_RUNTIME_DIR

  # SteamOS Game Mode: Steam runs as its OWN user unit (steam-launcher.service),
  # separate from the gamescope compositor (gamescope-session.service, which is
  # RefuseManualStart=yes and therefore CANNOT be restarted directly — that is
  # exactly why the button did nothing on SteamOS: the glob below matched the
  # un-restartable compositor). Restart just Steam: it comes back through our
  # steam-launcher.service.d drop-in (slsteam-moon wrapper on PATH, injection
  # preserved) while the compositor stays up. Checked BEFORE the gamescope glob.
  if systemctl --user is-active --quiet steam-launcher.service 2>/dev/null; then
    if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then echo "unit:steam-launcher.service"; exit 0; fi
    setsid nohup systemctl --user restart steam-launcher.service </dev/null >/dev/null 2>&1 &
    exit 0
  fi

  # Bazzite/ChimeraOS Game Mode: Steam is supervised by a gamescope-session*
  # service (e.g. gamescope-session-plus@steam.service). Restart that unit — it
  # re-sources its config (incl. our STEAMCMD override) and brings Steam back
  # through the wrapper. Discovered generically (NOT hardcoded to "-plus").
  gs_unit="$(
    systemctl --user list-units --type=service --state=active \
      --plain --no-legend 'gamescope-session*' 2>/dev/null \
      | awk '{print $1}' | head -n1
  )"
  if [ -n "${gs_unit:-}" ]; then
    if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then echo "unit:$gs_unit"; exit 0; fi
    setsid nohup systemctl --user restart "$gs_unit" </dev/null >/dev/null 2>&1 &
    exit 0
  fi
fi
# --- end Game Mode fast path ------------------------------------------------

# Resolve a launcher, preferring the slsteam-moon wrapper so injection
# is honoured. Fall back to the distro launcher only if the wrapper is
# absent (degraded: no injection, but at least Steam restarts).
LAUNCHER=""
for candidate in \
  "$HOME/.local/share/SLSsteam/path/steam" \
  "/usr/bin/steam" \
  "/usr/games/steam" \
  "/usr/local/bin/steam"; do
  if [ -x "$candidate" ]; then
    LAUNCHER="$candidate"
    break
  fi
done
if [ -z "$LAUNCHER" ] && command -v steam >/dev/null 2>&1; then
  LAUNCHER="$(command -v steam)"
fi

# Dry-run seam (tests): report the desktop decision and exit BEFORE touching
# the running Steam, so the strategy can be pinned without killing anything.
if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then
  echo "desktop:${LAUNCHER:-none}"
  exit 0
fi

# Ask Steam to shut down cleanly first.
if command -v steam >/dev/null 2>&1; then
  steam -shutdown >/dev/null 2>&1 || true
fi

# Wait up to ~10s for the i386 Steam client and webhelper to exit.
for _ in $(seq 1 50); do
  if ! pgrep -x steam >/dev/null 2>&1 \
     && ! pgrep -f 'steamwebhelper' >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

# Escalate if still alive: SIGTERM, then SIGKILL.
if pgrep -x steam >/dev/null 2>&1 || pgrep -f 'steamwebhelper' >/dev/null 2>&1; then
  pkill -TERM -x steam >/dev/null 2>&1 || true
  pkill -TERM -f 'steamwebhelper' >/dev/null 2>&1 || true
  sleep 2
fi
if pgrep -x steam >/dev/null 2>&1 || pgrep -f 'steamwebhelper' >/dev/null 2>&1; then
  pkill -KILL -x steam >/dev/null 2>&1 || true
  pkill -KILL -f 'steamwebhelper' >/dev/null 2>&1 || true
  sleep 1
fi

# A short settle so the lock/pipe files are released before relaunch.
sleep 1

if [ -n "$LAUNCHER" ]; then
  setsid nohup "$LAUNCHER" </dev/null >/dev/null 2>&1 &
fi
exit 0
