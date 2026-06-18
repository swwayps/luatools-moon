#!/bin/bash
# downloader.sh — Linux download/extract worker for slsteammoon.
#
# Used by the MANUAL source-selection path (fast download off). The fast
# path uses smart_download.sh instead.
#
# Overrides upstream's backend/scripts/downloader.sh. Upstream's version
# works on Windows but, on Linux, the plugin spawns this from inside the
# Steam process, which exports a Steam Runtime LD_LIBRARY_PATH (its
# pinned_libs_*) ahead of the system libs. /usr/bin/curl (and unzip) are
# built against the system libraries and fail under that environment,
# e.g.:
#   curl: error while loading shared libraries: libidn.so.11: ...
# surfacing in the UI as "Failed: curl failed".
#
# Fix: strip the Steam-injected loader env vars so the system binaries
# load their own (system) libraries. This fork also adds connect/transfer
# timeouts + a speed floor (so a stalled or crawling source aborts instead
# of hanging the dialog) and emits bytesRead/totalBytes into the state file
# so the frontend progress bar actually moves.
#
# Args: <URL> <DEST_PATH> <EXTRACT_DIR> <STATE_FILE> [<USER_AGENT>]

# Use system libraries, not the Steam Runtime's pinned ones.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

URL="$1"
DEST_PATH="$2"
EXTRACT_DIR="$3"
STATE_FILE="$4"
USER_AGENT="${5:-discord(dot)gg/luatools}"

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
MAX_TIME="${MAX_TIME:-25}"
SPEED_LIMIT="${SPEED_LIMIT:-20000}"
SPEED_TIME="${SPEED_TIME:-5}"

write_state() {
  # write_state <status> [bytesRead] [totalBytes]
  [ -n "$STATE_FILE" ] || return 0
  local status="$1" br="${2:-0}" tb="${3:-0}"
  printf '{"status": "%s", "bytesRead": %s, "totalBytes": %s}\n' \
    "$status" "$br" "$tb" > "$STATE_FILE"
}

write_failed() {
  [ -n "$STATE_FILE" ] || return 0
  printf '{"status": "failed", "error": "%s"}\n' "$1" > "$STATE_FILE"
}

write_state "downloading" 0 0

# Best-effort total size for a real progress bar.
TOTAL="$(curl -sIL -A "$USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT" \
  --max-time 6 "$URL" 2>/dev/null | tr -d '\r' \
  | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v+0}')"
[ -z "$TOTAL" ] && TOTAL=0

# Download in the background so we can poll progress from the partial file.
curl -L -A "$USER_AGENT" \
  --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
  --speed-limit "$SPEED_LIMIT" --speed-time "$SPEED_TIME" \
  -o "$DEST_PATH" "$URL" &
CURL_PID=$!

while kill -0 "$CURL_PID" 2>/dev/null; do
  if [ -f "$DEST_PATH" ]; then
    sz="$(stat -c %s "$DEST_PATH" 2>/dev/null || echo 0)"
    write_state "downloading" "$sz" "$TOTAL"
  fi
  sleep 0.3
done
wait "$CURL_PID"
rc=$?

if [ "$rc" -ne 0 ]; then
  write_failed "curl failed"
  exit 1
fi

if [ -n "$EXTRACT_DIR" ]; then
  write_state "extracting" "$TOTAL" "$TOTAL"
  # Prefer the bundled static 7zz: it extracts BOTH .zip and .rar (online
  # fixes ship as .rar, which unzip can't handle). Fall back to system unzip
  # only when 7zz is absent (zip-only).
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SEVENZ="$SCRIPT_DIR/../bin/7zz"
  if [ -x "$SEVENZ" ]; then
    "$SEVENZ" x -bd -y -o"$EXTRACT_DIR" "$DEST_PATH" >/dev/null 2>&1
  else
    unzip -o -q "$DEST_PATH" -d "$EXTRACT_DIR"
  fi
  if [ $? -ne 0 ]; then
    write_failed "extract failed"
    exit 1
  fi
  write_state "extracted" "$TOTAL" "$TOTAL"
else
  write_state "done" "$TOTAL" "$TOTAL"
fi
