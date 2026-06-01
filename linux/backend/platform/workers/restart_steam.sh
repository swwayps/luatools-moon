#!/usr/bin/env bash
# restart_steam.sh — Linux equivalent of upstream
# backend/restart_steam.cmd. Politely terminates Steam, waits for
# the steamwebhelper child to exit, then relaunches via the user's
# wrapper so SLSsteam.so injection (LD_AUDIT) is honored.
#
# Detects the launcher by preferring, in order:
#   1. ~/.local/bin/launch_steam_with_slsteam.sh   (slsteam-moon helper)
#   2. /usr/bin/steam, /usr/games/steam, /usr/local/bin/steam (distro)
#   3. PATH `steam`
#
# Background-detaches from the parent (Steam itself) using setsid +
# nohup so the new Steam process isn't killed when the dying one
# tears down its session. Mirrors the .cmd's "kill, sleep, start"
# shape so the frontend's RestartSteam button feels identical.

set -u

# ADAPT-LINUX: clear Steam-runtime env vars (see download_worker.sh).
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY
LAUNCHER=""
for candidate in \
  "$HOME/.local/bin/launch_steam_with_slsteam.sh" \
  "/usr/bin/steam" \
  "/usr/games/steam" \
  "/usr/local/bin/steam"; do
  if [[ -x "$candidate" ]]; then
    LAUNCHER="$candidate"
    break
  fi
done

if [[ -z "$LAUNCHER" ]]; then
  if command -v steam >/dev/null 2>&1; then
    LAUNCHER="$(command -v steam)"
  fi
fi

# Ask Steam to shut down cleanly first; fall back to SIGTERM, then
# SIGKILL on the i386 client process specifically.
if command -v steam >/dev/null 2>&1; then
  steam -shutdown >/dev/null 2>&1 || true
fi

# Wait up to ~6 seconds for the i386 Steam client to exit.
for _ in $(seq 1 30); do
  if ! pgrep -x steam >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

# Final hammer if still around.
pkill -TERM -x steam >/dev/null 2>&1 || true
sleep 1
pkill -KILL -x steam >/dev/null 2>&1 || true

# Relaunch detached.
if [[ -n "$LAUNCHER" ]]; then
  setsid nohup "$LAUNCHER" </dev/null >/dev/null 2>&1 &
fi
exit 0
