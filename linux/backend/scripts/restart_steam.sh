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
