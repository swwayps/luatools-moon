#!/bin/bash
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

update_state "downloading"
curl -L -A "$USER_AGENT" -o "$DEST_PATH" "$URL"
if [ $? -ne 0 ]; then
    if [ -n "$STATE_FILE" ]; then
        echo '{"status": "failed", "error": "curl failed"}' > "$STATE_FILE"
    fi
    exit 1
fi

if [ -n "$EXTRACT_DIR" ]; then
    update_state "extracting"
    unzip -o -q "$DEST_PATH" -d "$EXTRACT_DIR"
    if [ $? -ne 0 ]; then
        if [ -n "$STATE_FILE" ]; then
            echo '{"status": "failed", "error": "unzip failed"}' > "$STATE_FILE"
        fi
        exit 1
    fi
    update_state "extracted"
else
    update_state "done"
fi
