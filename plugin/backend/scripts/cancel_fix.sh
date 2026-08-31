#!/usr/bin/env bash
# Bounded cancellation for one automatic fix worker and its current transaction.
set -u

unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

STATE_FILE="${1:-}"
GAME_DIR="${2:-}"
BACKUP_ROOT="${3:-}"
TRANSACTION="${4:-}"
STOP_FILE="${STATE_FILE:+${STATE_FILE}.stop}"
PID_FILE="${STATE_FILE:+${STATE_FILE}.pid}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -n "$STATE_FILE" ] && [ -d "$GAME_DIR" ] || exit 1

read_transaction() {
  [ -r "$STATE_FILE" ] || return 0
  sed -n 's/.*"transaction"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$STATE_FILE" | head -n 1
}

valid_transaction() {
  [ -z "$1" ] && return 0
  case "$1" in
    txn.*) ;;
    *) return 1 ;;
  esac
  case "$1" in */*|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
}

if [ -z "$TRANSACTION" ]; then TRANSACTION="$(read_transaction)"; fi
valid_transaction "$TRANSACTION" || exit 1

printf 'cancel\n' > "${STOP_FILE}.tmp.$$" && mv -f "${STOP_FILE}.tmp.$$" "$STOP_FILE" \
  || exit 1

pid_matches_worker() {
  local pid="$1"
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fxq -- "$STATE_FILE"
}

PID=""
if [ -r "$PID_FILE" ]; then
  read -r PID < "$PID_FILE" || PID=""
fi
case "$PID" in ''|*[!0-9]*) PID="" ;; esac

signal_worker() {
  local signal="$1" pid="$2" pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  if [ "$pgid" = "$pid" ]; then
    kill -"$signal" -- "-$pid" 2>/dev/null || true
  else
    kill -"$signal" "$pid" 2>/dev/null || true
  fi
}

if [ -n "$PID" ] && pid_matches_worker "$PID"; then
  signal_worker TERM "$PID"
  for _ in 1 2 3 4 5 6 7 8; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.025
  done
  if kill -0 "$PID" 2>/dev/null; then signal_worker KILL "$PID"; fi
fi

status=0
if command -v flock >/dev/null 2>&1; then
  exec 9>"${STATE_FILE}.lock"
  flock -w 1 9 || status=1
fi
if [ "$status" -eq 0 ]; then
  if [ -z "$TRANSACTION" ]; then TRANSACTION="$(read_transaction)"; fi
  valid_transaction "$TRANSACTION" || status=1
  if [ "$status" -eq 0 ] && [ -n "$TRANSACTION" ] \
      && [ -d "$BACKUP_ROOT/$TRANSACTION" ]; then
    timeout --kill-after=0.2s 1s bash "$SCRIPT_DIR/restore_fix.sh" \
      "$GAME_DIR" "$BACKUP_ROOT" "$TRANSACTION" || status=1
  fi
fi

rm -f "$PID_FILE"
if [ "$status" -eq 0 ]; then
  printf '{"status": "cancelled", "bytesRead": 0, "totalBytes": 0}\n' \
    > "${STATE_FILE}.tmp.$$" && mv -f "${STATE_FILE}.tmp.$$" "$STATE_FILE" \
    || status=1
fi
exit "$status"
