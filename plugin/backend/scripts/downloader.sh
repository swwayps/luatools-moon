#!/bin/bash
# downloader.sh — Linux download/extract worker for slsteammoon.
#
# Used by the fix-application path. Game-data downloads, including manual
# source selection, use smart_download.sh and its validated merge pipeline.
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
# Args: <URL> <DEST_PATH> <EXTRACT_DIR> <STATE_FILE> [<USER_AGENT>] [<HEADER_FILE>]

# Use system libraries, not the Steam Runtime's pinned ones.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

URL="$1"
DEST_PATH="$2"
EXTRACT_DIR="$3"
STATE_FILE="$4"
USER_AGENT="${5:-discord(dot)gg/luatools}"
HEADER_FILE="${6:-}"

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
MAX_TIME="${MAX_TIME:-25}"
SPEED_LIMIT="${SPEED_LIMIT:-20000}"
SPEED_TIME="${SPEED_TIME:-5}"

# Diagnostics. The plugin launches this worker with stdout+stderr appended to
# ~/.lumen.log (see downloads.lua::_launch_async_download and fixes.lua's
# apply path), so these lines land in the same log as the rest of the plugin —
# every download (add-via-LuaTools AND the fixes menu) is now traceable. The
# ISO-8601 UTC prefix mirrors smart_download.sh/logger.lua; the state-file stem
# (e.g. "2830030_state" or "fix_2830030_state") + pid tie interleaved lines
# back to their run.
LUMEN_TAG="$(basename "${STATE_FILE:-download}" 2>/dev/null | sed 's/\.json$//')"
slog() { printf '%s INFO downloader[%s pid %s]: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LUMEN_TAG:-?}" "$$" "$*"; }

write_state() {
  # write_state <status> [bytesRead] [totalBytes]
  [ -n "$STATE_FILE" ] || return 0
  local status="$1" br="${2:-0}" tb="${3:-0}" tmp="${STATE_FILE}.tmp.$$"
  printf '{"status": "%s", "bytesRead": %s, "totalBytes": %s}\n' \
    "$status" "$br" "$tb" > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}

# json_escape <str> : escape backslash + double-quote so a reason with quotes
# can't break the state JSON the frontend parses.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

write_failed() {
  # write_failed <human-readable reason> [machine-readable code]. The reason is shown to the user
  # verbatim ("Failed: <reason>"), so keep it plain and non-technical.
  local reason="$1" error_code="${2:-}"
  slog "FAILED: $reason"
  [ -n "$STATE_FILE" ] || return 0
  local tmp="${STATE_FILE}.tmp.$$"
  if [ -n "$error_code" ]; then
    printf '{"status": "failed", "error": "%s", "errorCode": "%s"}\n' \
      "$(json_escape "$reason")" "$(json_escape "$error_code")" > "$tmp"
  else
    printf '{"status": "failed", "error": "%s"}\n' "$(json_escape "$reason")" > "$tmp"
  fi
  mv -f "$tmp" "$STATE_FILE"
}

if command -v flock >/dev/null 2>&1 && [ -n "$STATE_FILE" ]; then
  exec 9>"${STATE_FILE}.lock"
  if ! flock -n 9; then
    slog "worker already active for this operation"
    exit 0
  fi
fi

slog "worker start: dest=$DEST_PATH extract=$EXTRACT_DIR"
write_state "downloading" 0 0

# Authenticated sources pass a chmod-600 curl header file. Keep credentials out
# of the process command line and never send them to a source that did not ask
# for them (the backend only creates this file for generator.ryuu.lol URLs).
CURL_HEADERS=()
if [ -n "$HEADER_FILE" ] && [ -r "$HEADER_FILE" ]; then
  CURL_HEADERS=(--header "@$HEADER_FILE")
fi

# Best-effort total size for a real progress bar.
TOTAL="$(curl -sIL -A "$USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT" \
  --max-time 6 "${CURL_HEADERS[@]}" "$URL" 2>/dev/null | tr -d '\r' \
  | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v+0}')"
[ -z "$TOTAL" ] && TOTAL=0

# Download in the background so we can poll progress from the partial file.
PART_PATH="${DEST_PATH}.part.$$"
HTTP_CODE_PATH="${PART_PATH}.http"
curl --fail -L -A "$USER_AGENT" \
  --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
  --speed-limit "$SPEED_LIMIT" --speed-time "$SPEED_TIME" \
  --write-out '%{http_code}' "${CURL_HEADERS[@]}" -o "$PART_PATH" "$URL" \
  > "$HTTP_CODE_PATH" &
CURL_PID=$!

while kill -0 "$CURL_PID" 2>/dev/null; do
  if [ -f "$PART_PATH" ]; then
    sz="$(stat -c %s "$PART_PATH" 2>/dev/null || echo 0)"
    write_state "downloading" "$sz" "$TOTAL"
  fi
  sleep 0.3
done
wait "$CURL_PID"
rc=$?
HTTP_CODE="$(cat "$HTTP_CODE_PATH" 2>/dev/null || true)"
rm -f "$HTTP_CODE_PATH"

if [ "$rc" -ne 0 ]; then
  rm -f "$PART_PATH"
  slog "download failed (curl rc=$rc http=${HTTP_CODE:-none})"
  if [ "$rc" -eq 3 ]; then
    # rc=3 is "URL using bad/illegal format": curl rejected the address itself and
    # never opened a connection, so the catalogue served a broken link (an
    # unencoded filename does exactly this). Blaming the connection here sends the
    # user chasing a problem that does not exist. Note rc=6 (DNS) is deliberately
    # NOT included: that one really is a connectivity failure.
    write_failed "The download link from this source is not valid. It may have been renamed or removed. Try another source." "badurl"
  elif [ "$rc" -eq 28 ]; then
    # rc=28 also covers the stall guard (--speed-limit/--speed-time), which trips
    # on a slow LOCAL link just as much as on a slow source, so the message names
    # both instead of sending the user to hunt for another mirror.
    write_failed "Download stalled. The transfer stopped making progress, which can be the source or your own connection. Try again, or pick another source." "stalled"
  elif [ "$rc" -eq 22 ] && { [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; }; then
    write_failed "Ryuu authentication was rejected or expired — update your session cookie or auth key." "authentication"
  elif [ "$rc" -eq 22 ]; then
    write_failed "The source rejected the download request (HTTP ${HTTP_CODE:-error}). Try another source."
  else
    write_failed "Download failed — the source didn't respond or the connection was interrupted. Try another source."
  fi
  exit 1
fi
mv -f "$PART_PATH" "$DEST_PATH" || {
  write_failed "The downloaded file could not be saved. Check the destination permissions and try again."
  exit 1
}
slog "download ok ($(stat -c %s "$DEST_PATH" 2>/dev/null || echo '?') bytes)"

if [ -n "$EXTRACT_DIR" ]; then
  write_state "extracting" "$TOTAL" "$TOTAL"
  # Prefer the bundled static 7zz: it extracts BOTH .zip and .rar (online
  # fixes ship as .rar, which unzip can't handle). Fall back to system unzip
  # only when 7zz is absent (zip-only).
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SEVENZ="$SCRIPT_DIR/../bin/7zz"
  MAX_ARCHIVE_ENTRIES="${MAX_ARCHIVE_ENTRIES:-20000}"
  MAX_EXPANDED_BYTES="${MAX_EXPANDED_BYTES:-4294967296}"
  STAGE_DIR=""
  EXTRACT_WORK="$EXTRACT_DIR"
  cleanup_stage() { [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"; }
  trap cleanup_stage EXIT

  archive_is_safe() {
    local archive="$1" paths count expanded listing
    if [ -x "$SEVENZ" ]; then
      listing="$("$SEVENZ" l -slt "$archive" 2>/dev/null)" || return 1
      paths="$(printf '%s\n' "$listing" | sed -n 's/^Path = //p' | tail -n +2)"
      count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l)"
      expanded="$(printf '%s\n' "$listing" | awk -F' = ' '/^Size = [0-9]+$/ {s += $2} END {printf "%.0f", s}')"
    else
      paths="$(unzip -Z1 "$archive" 2>/dev/null)" || return 1
      count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l)"
      expanded="$(unzip -Z -t "$archive" 2>/dev/null \
        | awk '/bytes uncompressed/ { for (i=1;i<=NF;i++) if ($i=="bytes") {print $(i-1); exit} }')"
    fi
    [ "$count" -le "$MAX_ARCHIVE_ENTRIES" ] || return 1
    [[ "$expanded" =~ ^[0-9]+$ ]] && [ "$expanded" -le "$MAX_EXPANDED_BYTES" ] || return 1
    if printf '%s\n' "$paths" | grep -Eq '(^/|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$))'; then return 1; fi
    return 0
  }

  if ! archive_is_safe "$DEST_PATH"; then
    slog "archive preflight rejected"
    write_failed "The downloaded archive is unsafe, malformed, or exceeds the extraction limits." "unsafe_archive"
    exit 1
  fi

  if [ "${EXTRACT_NESTED:-0}" = "1" ]; then
    STAGE_DIR="$(mktemp -d "${DEST_PATH}.stage.XXXXXX")" || {
      write_failed "A private staging directory could not be created. Check free space and permissions."
      exit 1
    }
    EXTRACT_WORK="$STAGE_DIR"
  else
    mkdir -p "$EXTRACT_WORK"
  fi
  if [ -x "$SEVENZ" ]; then
    "$SEVENZ" x -bd -y -o"$EXTRACT_WORK" "$DEST_PATH" >/dev/null 2>&1
  else
    unzip -o -q "$DEST_PATH" -d "$EXTRACT_WORK"
  fi
  if [ $? -ne 0 ]; then
    slog "extract failed"
    write_failed "The downloaded file could not be opened — it may be corrupt or incomplete. Try another source."
    exit 1
  fi
  unsafe="$(find "$EXTRACT_WORK" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit 2>/dev/null)"
  if [ -n "$unsafe" ]; then
    slog "extracted tree contains a link or special file"
    write_failed "The downloaded archive contains an unsafe file type." "unsafe_archive"
    exit 1
  fi
  slog "extract ok -> private staging"

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
    MANIFEST="$EXTRACT_WORK/.slssteam_fix_dlls"
    DLL_ACC="$(mktemp 2>/dev/null)" || DLL_ACC=""
    list_fix_dlls() {  # $1 = archive -> append shipped .dll basenames to $DLL_ACC
      [ -n "$DLL_ACC" ] || return 0
      "$SEVENZ" l -ba -slt "$1" 2>/dev/null \
        | sed -n 's/^Path = //p' \
        | grep -iE '\.dll$' \
        | sed 's#.*[/\\]##' >> "$DLL_ACC"
    }

    # Some cracks ship their OWN launcher (FC25's Launcher.exe, an EA/Denuvo
    # unlocker, ...) that must run INSTEAD of the game's default exe. Record the
    # launcher-pattern exes (launcher.exe / launcher_*.exe / *_launcher.exe) the
    # archive(s) shipped, with their RELATIVE PATHS (the exe lands at
    # $EXTRACT_DIR/<path>), into .slssteam_fix_launchers. launcherfix.lua reads
    # this to redirect Steam's Play button at the launcher via a Proton launch
    # option. Listing the archive (not a dir scan) is what lets us tell a
    # crack-shipped launcher from the game's own pre-existing launcher.exe.
    LAUNCHER_MANIFEST="$EXTRACT_WORK/.slssteam_fix_launchers"
    LAUNCHER_ACC="$(mktemp 2>/dev/null)" || LAUNCHER_ACC=""
    list_fix_launchers() {  # $1 = archive -> append launcher exe relpaths to $LAUNCHER_ACC
      [ -n "$LAUNCHER_ACC" ] || return 0
      "$SEVENZ" l -ba -slt "$1" 2>/dev/null \
        | sed -n 's/^Path = //p' \
        | tr '\\' '/' \
        | grep -iE '(^|/)(launcher\.exe|launcher_[^/]+\.exe|[^/]+_launcher\.exe)$' \
        >> "$LAUNCHER_ACC"
    }
    # Primary archive (covers non-nested cracks whose files sit at top level).
    list_fix_dlls "$DEST_PATH"
    list_fix_launchers "$DEST_PATH"

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
        list_fix_launchers "$arc"  # capture nested-archive launcher exes too
        if ! archive_is_safe "$arc" \
            || ! "$SEVENZ" x -bd -y -o"$EXTRACT_WORK" "$arc" >/dev/null 2>&1; then
          slog "nested archive rejected or unreadable: $(basename "$arc")"
        fi
      fi
    done < <(find "$EXTRACT_WORK" -type f \( -iname '*.rar' -o -iname '*.zip' \
              -o -iname '*.7z' -o -iname '*.r[0-9][0-9]' -o -iname '*.z[0-9][0-9]' \) -print0 2>/dev/null)

    if [ "$found_archive" = "1" ]; then
      # Remove every archive volume now that their contents are extracted.
      find "$EXTRACT_WORK" -type f \( -iname '*.rar' -o -iname '*.zip' \
        -o -iname '*.7z' -o -iname '*.r[0-9][0-9]' -o -iname '*.z[0-9][0-9]' \) \
        -delete 2>/dev/null || true
    fi

    # Persist the manifest (case-insensitive unique) when any fix DLL was seen.
    if [ -n "$DLL_ACC" ] && [ -s "$DLL_ACC" ]; then
      sort -u -f "$DLL_ACC" > "$MANIFEST" 2>/dev/null || true
    fi
    [ -n "$DLL_ACC" ] && rm -f "$DLL_ACC"

    # Persist the launcher manifest (case-insensitive unique relpaths) when the
    # crack shipped a launcher exe.
    if [ -n "$LAUNCHER_ACC" ] && [ -s "$LAUNCHER_ACC" ]; then
      sort -u -f "$LAUNCHER_ACC" > "$LAUNCHER_MANIFEST" 2>/dev/null || true
    fi
    [ -n "$LAUNCHER_ACC" ] && rm -f "$LAUNCHER_ACC"
  fi

  # Fixes are assembled entirely in STAGE_DIR. Only now overlay that tree onto
  # the game. Existing files are backed up and restored if any copy fails;
  # archives that were already in the game directory are never scanned.
  if [ -n "$STAGE_DIR" ]; then
    BACKUP_DIR="$(mktemp -d "${DEST_PATH}.backup.XXXXXX")" || {
      write_failed "A rollback directory could not be created. Check free space and permissions."
      exit 1
    }
    JOURNAL="$BACKUP_DIR/journal"
    : > "$JOURNAL"
    apply_failed=0

    while IFS= read -r -d '' source_dir; do
      rel="${source_dir#"$STAGE_DIR"/}"
      [ "$source_dir" = "$STAGE_DIR" ] && continue
      target_dir="$EXTRACT_DIR/$rel"
      if [ -L "$target_dir" ]; then apply_failed=1; break; fi
      if [ -e "$target_dir" ] && [ ! -d "$target_dir" ]; then apply_failed=1; break; fi
      if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir" || { apply_failed=1; break; }
        printf 'D\t%s\n' "$rel" >> "$JOURNAL"
      fi
    done < <(find "$STAGE_DIR" -type d -print0)

    if [ "$apply_failed" -eq 0 ]; then
      while IFS= read -r -d '' source_file; do
        rel="${source_file#"$STAGE_DIR"/}"
        target_file="$EXTRACT_DIR/$rel"
        backup_file="$BACKUP_DIR/files/$rel"
        if [ -d "$target_file" ]; then apply_failed=1; break; fi
        mkdir -p "$(dirname "$target_file")" "$(dirname "$backup_file")" \
          || { apply_failed=1; break; }
        if [ -e "$target_file" ] || [ -L "$target_file" ]; then
          cp -a "$target_file" "$backup_file" || { apply_failed=1; break; }
          printf 'E\t%s\n' "$rel" >> "$JOURNAL"
        else
          printf 'N\t%s\n' "$rel" >> "$JOURNAL"
        fi
        temp_file="${target_file}.tmp.luatools.$$"
        rm -f "$temp_file"
        cp -a "$source_file" "$temp_file" && mv -f "$temp_file" "$target_file" \
          || { rm -f "$temp_file"; apply_failed=1; break; }
      done < <(find "$STAGE_DIR" -type f -print0)
    fi

    if [ "$apply_failed" -ne 0 ]; then
      while IFS=$'\t' read -r action rel; do
        target="$EXTRACT_DIR/$rel"
        if [ "$action" = "E" ]; then
          rm -rf "$target"
          mkdir -p "$(dirname "$target")"
          cp -a "$BACKUP_DIR/files/$rel" "$target" 2>/dev/null || true
        elif [ "$action" = "N" ]; then
          rm -rf "$target"
        fi
      done < "$JOURNAL"
      tac "$JOURNAL" 2>/dev/null | while IFS=$'\t' read -r action rel; do
        [ "$action" != "D" ] || rmdir "$EXTRACT_DIR/$rel" 2>/dev/null || true
      done
      rm -rf "$BACKUP_DIR"
      write_failed "The fix was extracted safely, but could not be applied. Existing game files were restored." "apply_failed"
      exit 1
    fi
    rm -rf "$BACKUP_DIR"
  fi

  slog "extracted -> handing off to finalize"
  write_state "extracted" "$TOTAL" "$TOTAL"
else
  slog "done (no extract requested)"
  write_state "done" "$TOTAL" "$TOTAL"
fi
