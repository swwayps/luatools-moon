#!/bin/bash
# downloader.sh — Linux download/extract worker for slsteammoon.
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
# load their own (system) libraries. Everything else mirrors upstream's
# protocol (the *_state.json status file the frontend polls).
#
# Args: <URL> <DEST_PATH> <EXTRACT_DIR> <STATE_FILE> [<USER_AGENT>]

# Use system libraries, not the Steam Runtime's pinned ones.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

URL="$1"
DEST_PATH="$2"
EXTRACT_DIR="$3"
STATE_FILE="$4"
USER_AGENT="${5:-discord(dot)gg/luatools}"

update_state() {
    if [ -n "$STATE_FILE" ]; then
        echo "{\"status\": \"$1\"}" > "$STATE_FILE"
    fi
}

write_failed() {
    if [ -n "$STATE_FILE" ]; then
        echo "{\"status\": \"failed\", \"error\": \"$1\"}" > "$STATE_FILE"
    fi
}

update_state "downloading"
curl -L -A "$USER_AGENT" -o "$DEST_PATH" "$URL"
if [ $? -ne 0 ]; then
    write_failed "curl failed"
    exit 1
fi

if [ -n "$EXTRACT_DIR" ]; then
    update_state "extracting"
    unzip -o -q "$DEST_PATH" -d "$EXTRACT_DIR"
    if [ $? -ne 0 ]; then
        write_failed "unzip failed"
        exit 1
    fi
    update_state "extracted"
else
    update_state "done"
fi
