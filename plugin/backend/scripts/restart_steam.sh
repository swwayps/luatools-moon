#!/usr/bin/env bash
# restart_steam.sh — Linux restart helper for luatools-moon.
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

# --- Shutdown + relaunch ----------------------------------------------------
# This path is on the user's critical path: they watch the window close and wait
# for the next client. A measured restart spent 15s between Steam's own
# `Shutdown` line and the relaunch, so every wait here ends the instant its
# condition is met, and nothing is waited on that cannot actually block a new
# client.
#
# Two invariants this must not trade away:
#   1. The quit has to be the CLEAN one. Steam writes `Shutdown` to
#      bootstrap_log.txt from the bootstrapper's normal exit path; without that
#      line the next startup runs `Checking for update on startup` plus
#      `Verifying all executable checksums` (measured median 3s, p90 4s, max
#      28s, plus an HTTPS manifest round-trip). SIGKILL skips the write, so
#      signals stay a last resort rather than the default.
#   2. Never start a second client over a live one.

restart_trace() {
  printf '%s [restart_steam] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" \
    >> "$HOME/.lumen.log" 2>/dev/null || true
}

now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null)"
  case "$value" in
    ''|*[!0-9]*) echo 0 ;;
    *)           echo "$value" ;;
  esac
}

since_ms() { # $1 start stamp from now_ms
  local end
  end="$(now_ms)"
  if [ "$1" = 0 ] || [ "$end" = 0 ]; then echo '?'; else echo $(( end - $1 )); fi
}

# The client and its webhelper are the only processes that gate a relaunch:
# Steam's single-instance guard is the client's own IPC endpoint. `steam.sh` is
# the client's PARENT, so it always outlives it, and the srt-logger helpers are
# reparented to init and merely hold log FDs. Waiting on either of those only
# postpones the restart — and refusing over them cancelled restarts outright.
client_alive() {
  pgrep -x steam >/dev/null 2>&1 && return 0
  pgrep -x steamwebhelper >/dev/null 2>&1 && return 0
  return 1
}

# Poll until the client is gone. $1 = number of 100ms slices to allow.
await_client_exit() {
  local slices="$1" i=0
  while [ "$i" -lt "$slices" ]; do
    client_alive || return 0
    sleep 0.1
    i=$(( i + 1 ))
  done
  ! client_alive
}

restart_begin="$(now_ms)"

# Only ask a RUNNING client to quit. With nothing to answer the request,
# `steam -shutdown` boots an entire bootstrapper just to deliver it: measured at
# ~10s, ending in `Verifying all executable checksums` and no `Shutdown` line —
# precisely the cost this path exists to avoid.
if client_alive; then
  shutdown_begin="$(now_ms)"
  if command -v steam >/dev/null 2>&1; then
    steam -shutdown >/dev/null 2>&1 || true
  fi

  if ! await_client_exit 120; then  # up to ~12s for the clean quit
    restart_trace 'clean shutdown unfinished after 12s, escalating to SIGTERM'
    pkill -TERM -x steam >/dev/null 2>&1 || true
    pkill -TERM -x steamwebhelper >/dev/null 2>&1 || true
    if ! await_client_exit 30; then  # up to ~3s
      restart_trace 'SIGTERM did not stop Steam, escalating to SIGKILL (next start will re-verify)'
      pkill -KILL -x steam >/dev/null 2>&1 || true
      pkill -KILL -x steamwebhelper >/dev/null 2>&1 || true
      await_client_exit 20 || true
    fi
  fi
  restart_trace "shutdown completed in $(since_ms "$shutdown_begin")ms"
fi

if client_alive; then
  # Report it: the caller detaches this script and discards the exit code, so a
  # silent abort is indistinguishable from Steam never coming back.
  restart_trace 'aborted: Steam is still running, refusing to start a second client'
  exit 1
fi

# Brief settle so the exiting client's socket and pipe files are reaped before a
# new client probes them. The old fixed 1s was pure latency on every restart.
sleep 0.3

if [ -n "$LAUNCHER" ]; then
  setsid nohup "$LAUNCHER" </dev/null >/dev/null 2>&1 &
fi
restart_trace "relaunch issued $(since_ms "$restart_begin")ms after the request"
exit 0
