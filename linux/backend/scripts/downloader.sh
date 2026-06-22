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

  # Nested-archive pass (fix-apply path only; EXTRACT_NESTED=1). Some fixes
  # ship the actual crack as a .rar / multi-part .rar INSIDE the zip (the
  # parts ARE the crack, not a full-game repack). Unpack those one level into
  # the same dir, then delete the residual archives so they don't litter the
  # game folder. Requires 7zz (handles .rar v5 + multi-volume from the first
  # volume). Best-effort: a nested failure still leaves any loose crack files.
  if [ "${EXTRACT_NESTED:-0}" = "1" ] && [ -x "$SEVENZ" ]; then
    # Record the DLLs the fix/crack archive shipped into a manifest in the game
    # folder (.slssteam_fix_dlls). This is the ONLY moment we can tell a crack's
    # DLLs (arbitrary names -- voices38, an emulator's steam_api64, ...) apart
    # from the game's own DLLs, since they get extracted side by side. The
    # launch-option builder (fix_overlays.lua) reads this and forces native
    # (=n,b) on exactly these so Proton loads the fix DLLs instead of its
    # builtins. Listing the archive(s) (not a dir diff) is reliable even when a
    # crack DLL overwrites a same-named game DLL. Best-effort.
    MANIFEST="$EXTRACT_DIR/.slssteam_fix_dlls"
    DLL_ACC="$(mktemp 2>/dev/null)" || DLL_ACC=""
    list_fix_dlls() {  # $1 = archive -> append shipped .dll basenames to $DLL_ACC
      [ -n "$DLL_ACC" ] || return 0
      "$SEVENZ" l -ba -slt "$1" 2>/dev/null \
        | sed -n 's/^Path = //p' \
        | grep -iE '\.dll$' \
        | sed 's#.*[/\\]##' >> "$DLL_ACC"
    }
    # Primary archive (covers non-nested cracks whose DLLs sit at top level).
    list_fix_dlls "$DEST_PATH"

    # Is $1 a SECONDARY volume we should not invoke 7zz on directly?
    #   name.partN.rar (N>1), name.rNN, name.zNN  -> secondary
    is_secondary() {
      local b; b="$(basename "$1")"
      shopt -s nocasematch
      local rc=1
      if [[ "$b" =~ \.part0*([0-9]+)\.rar$ ]]; then
        [ "$((10#${BASH_REMATCH[1]}))" -ne 1 ] && rc=0
      elif [[ "$b" =~ \.r[0-9]+$ ]] || [[ "$b" =~ \.z[0-9]+$ ]]; then
        rc=0
      fi
      shopt -u nocasematch
      return $rc
    }

    found_archive=0
    while IFS= read -r -d '' arc; do
      found_archive=1
      if ! is_secondary "$arc"; then
        list_fix_dlls "$arc"   # capture nested-archive DLLs BEFORE deletion
        "$SEVENZ" x -bd -y -o"$EXTRACT_DIR" "$arc" >/dev/null 2>&1 || true
      fi
    done < <(find "$EXTRACT_DIR" -type f \( -iname '*.rar' -o -iname '*.zip' \
              -o -iname '*.7z' -o -iname '*.r[0-9][0-9]' -o -iname '*.z[0-9][0-9]' \) -print0 2>/dev/null)

    if [ "$found_archive" = "1" ]; then
      # Remove every archive volume now that their contents are extracted.
      find "$EXTRACT_DIR" -type f \( -iname '*.rar' -o -iname '*.zip' \
        -o -iname '*.7z' -o -iname '*.r[0-9][0-9]' -o -iname '*.z[0-9][0-9]' \) \
        -delete 2>/dev/null || true
    fi

    # Persist the manifest (case-insensitive unique) when any fix DLL was seen.
    if [ -n "$DLL_ACC" ] && [ -s "$DLL_ACC" ]; then
      sort -u -f "$DLL_ACC" > "$MANIFEST" 2>/dev/null || true
    fi
    [ -n "$DLL_ACC" ] && rm -f "$DLL_ACC"
  fi

  write_state "extracted" "$TOTAL" "$TOTAL"
else
  write_state "done" "$TOTAL" "$TOTAL"
fi
