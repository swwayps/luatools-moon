#!/usr/bin/env bash
# fix_worker.sh — Linux port stub for upstream backend/fix_worker.ps1.
#
# Upstream behaviour (Apply mode):
#   1. Download <download_url> to a temp zip.
#   2. Expand-Archive into a temp folder.
#   3. Recursively copy the contents over <install_path>, optionally
#      backing up replaced files into a fix-history directory under
#      the install root.
#   4. Write a fix-state JSON file consumed by GetApplyFixStatus.
#
# Upstream behaviour (Unfix mode):
#   1. Walk the fix-history directory for <appid> + <fix_date>.
#   2. Restore originals over the replaced files, delete history.
#   3. Write an unfix-state JSON file consumed by GetUnfixStatus.
#
# This Linux port is intentionally stubbed: GameBypasses / OnlineFix
# zips are Windows-targeted and most won't apply meaningfully under
# Proton without per-fix logic (DLL drop-ins, registry pokes,
# winetricks calls). Until that's modelled in slsteammoon-luatools,
# the worker reports a structured error so the frontend's "Apply Fix"
# button surfaces a clear message instead of hanging.
#
# When porting in earnest, the JSON state-file shapes to honour are:
#   apply:  { status, currentApi?, bytesRead, totalBytes, success?,
#             error?, fixDate?, gameName? }
#   unfix:  { status, progress, success?, error? }
# Status is one of: queued, downloading, processing, done, failed,
# cancelled. See upstream/luatools/backend/fix_worker.ps1 for the
# canonical writer order.

set -u

# ADAPT-LINUX: clear Steam-runtime env vars (see download_worker.sh).
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

MODE=""
APP_ID=""
PLUGIN_ROOT=""
DOWNLOAD_URL=""
INSTALL_PATH=""
FIX_TYPE=""
GAME_NAME=""
FIX_DATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --app-id) APP_ID="$2"; shift 2 ;;
    --plugin-root) PLUGIN_ROOT="$2"; shift 2 ;;
    --download-url) DOWNLOAD_URL="$2"; shift 2 ;;
    --install-path) INSTALL_PATH="$2"; shift 2 ;;
    --fix-type) FIX_TYPE="$2"; shift 2 ;;
    --game-name) GAME_NAME="$2"; shift 2 ;;
    --fix-date) FIX_DATE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

TEMP_DIR="$PLUGIN_ROOT/backend/temp_dl"
mkdir -p "$TEMP_DIR"

case "$MODE" in
  Apply|apply)
    STATE_FILE="$TEMP_DIR/fix_status_${APP_ID}.json"
    cat > "$STATE_FILE" <<EOF
{"status":"failed","success":false,"error":"Game fixes are not yet supported on Linux. See backend/platform/workers/fix_worker.sh for the porting notes."}
EOF
    ;;
  Unfix|unfix)
    STATE_FILE="$TEMP_DIR/unfix_status_${APP_ID}.json"
    cat > "$STATE_FILE" <<EOF
{"status":"failed","success":false,"error":"Game fix removal is not yet supported on Linux."}
EOF
    ;;
  *)
    # Unknown mode — write a generic failure to whichever file the
    # caller is most likely polling.
    STATE_FILE="$TEMP_DIR/fix_status_${APP_ID}.json"
    cat > "$STATE_FILE" <<EOF
{"status":"failed","success":false,"error":"Unknown fix worker mode: ${MODE}"}
EOF
    ;;
esac
exit 0
