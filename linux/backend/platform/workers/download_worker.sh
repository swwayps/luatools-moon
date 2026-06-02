#!/usr/bin/env bash
# download_worker.sh — Linux equivalent of upstream backend/download_worker.ps1.
#
# Downloads a Lua-pack zip for `--app-id` from `--url`, extracts it
# under `<plugin-root>/backend/temp_dl/extract_<appid>/`, copies any
# `.manifest` files into `<steam-path>/depotcache/`, drops the .lua
# under `<steam-path>/config/stplug-in/<appid>.lua`, and writes a
# JSON status file at
# `<plugin-root>/backend/temp_dl/status_<appid>.json` for the
# frontend to poll via GetAddViaLuaToolsStatus.
#
# Args (key/value pairs, position-independent):
#   --app-id <appid>
#   --url <url>
#   --api-name <api-name>
#   --plugin-root <abs-path>
#   --steam-path <abs-path>
#
# Status file shape (matches upstream powershell worker so the
# frontend protocol stays identical):
#   { "status": "downloading|processing|done|failed",
#     "currentApi": "...", "bytesRead": N, "totalBytes": N,
#     "manifests": N, "dlcs": N, "error": "...", "success": bool }

set -u

# ADAPT-LINUX: when launched from inside Steam (Millennium spawns us
# while the i386 client process is alive), the inherited LD_LIBRARY_PATH
# points at the Steam Runtime's pinned_libs_64/, which holds older
# libcurl/libssl. /usr/bin/curl is built against the system libs and
# fails with `version 'CURL_OPENSSL_4' not found`. The platform.lua
# spawner already strips these, but we re-strip here so manual `bash
# download_worker.sh` invocations from a Steam-launched terminal also
# work.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

APP_ID=""
URL=""
API_NAME=""
PLUGIN_ROOT=""
STEAM_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --api-name) API_NAME="$2"; shift 2 ;;
    --plugin-root) PLUGIN_ROOT="$2"; shift 2 ;;
    --steam-path) STEAM_PATH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

TEMP_DIR="$PLUGIN_ROOT/backend/temp_dl"
STATUS_FILE="$TEMP_DIR/status_${APP_ID}.json"
ZIP_PATH="$TEMP_DIR/${APP_ID}.zip"
EXTRACT_DIR="$TEMP_DIR/extract_${APP_ID}"

mkdir -p "$TEMP_DIR"

json_escape() {
  # Minimal JSON string escaping for status payloads.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

write_status() {
  printf '%s' "$1" > "$STATUS_FILE"
}

fail() {
  local msg="$1"
  write_status "{\"status\":\"failed\",\"error\":\"$(json_escape "$msg")\"}"
  exit 1
}

# Mark downloading.
write_status "{\"status\":\"downloading\",\"currentApi\":\"$(json_escape "$API_NAME")\",\"bytesRead\":0,\"totalBytes\":0}"

# Fetch.
# ADAPT-LINUX-DEBUG: capture curl's stderr + exit code so failures
# spawned from within the Steam Linux Runtime sandbox surface the
# real reason instead of a bare "Download failed".
CURL_LOG="$TEMP_DIR/download_worker_${APP_ID}.log"
{
  echo "[$(date -Is)] curl GET $URL -> $ZIP_PATH"
  echo "[env] PATH=$PATH"
  echo "[env] LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
  echo "[env] SSL_CERT_FILE=${SSL_CERT_FILE:-<unset>}"
  echo "[env] SSL_CERT_DIR=${SSL_CERT_DIR:-<unset>}"
  echo "[env] CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-<unset>}"
  echo "[env] which curl: $(command -v curl 2>&1)"
} > "$CURL_LOG" 2>&1
curl -sSL --fail --max-time 600 "$URL" -o "$ZIP_PATH" 2>>"$CURL_LOG"
CURL_RC=$?
echo "[curl exit] $CURL_RC" >> "$CURL_LOG"
if [[ $CURL_RC -ne 0 ]]; then
  fail "Download failed (curl rc=$CURL_RC, see $(basename "$CURL_LOG"))"
fi

BYTES=$(stat -c%s "$ZIP_PATH" 2>/dev/null || echo 0)
write_status "{\"status\":\"processing\",\"currentApi\":\"$(json_escape "$API_NAME")\",\"bytesRead\":${BYTES},\"totalBytes\":${BYTES}}"

# Extract.
rm -rf -- "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
if ! unzip -o -q "$ZIP_PATH" -d "$EXTRACT_DIR"; then
  fail "Extraction failed"
fi

# Locate Lua + manifests.
LUA_FILE=""
PREFERRED="${EXTRACT_DIR}/${APP_ID}.lua"
if [[ -f "$PREFERRED" ]]; then
  LUA_FILE="$PREFERRED"
else
  LUA_FILE=$(find "$EXTRACT_DIR" -type f -iname '*.lua' | head -n1 || true)
fi
if [[ -z "$LUA_FILE" ]]; then
  fail "No lua file found in downloaded archive"
fi

DEPOT_DIR="$STEAM_PATH/depotcache"
TARGET_DIR="$STEAM_PATH/config/stplug-in"
mkdir -p "$DEPOT_DIR" "$TARGET_DIR"

MANIFESTS=0
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  cp -f "$m" "$DEPOT_DIR/$(basename "$m")"
  MANIFESTS=$((MANIFESTS + 1))
done < <(find "$EXTRACT_DIR" -type f -iname '*.manifest')

cp -f "$LUA_FILE" "$TARGET_DIR/${APP_ID}.lua" || fail "Failed to install lua file"

# ADAPT-LINUX: pre-fetch any manifest whose depot+gid is declared in
# the lua but whose `.manifest` file is missing from the pack. Steam
# Linux 2026 has no working in-process inline-rewrite path for the
# `ContentServerDirectory.GetManifestRequestCode#1` call (the
# slsteam-moon hook lands but the rewrite isn't honoured by
# downstream consumers — see SLSsteam-fork HANDOFF.md "Phase 4.5"),
# so the supported way to handle lua packs that ship only the .lua
# (Morrenus, SkyApi, etc) is to download the binary manifest from the
# public manifest-request-code provider chain + Steam CDN and drop
# it into depotcache/ before the user clicks Install. This makes
# Steam fall straight through to the cached file lookup and never
# emit `BYldRequestDepotManifest ... Failed`.
PREFETCHED=0
PREFETCH_FAILED=0
PREFETCH_SCRIPT="${PLUGIN_ROOT}/backend/platform/workers/manifest_prefetch.sh"
if [[ -x "$PREFETCH_SCRIPT" ]]; then
  while IFS=$'\t' read -r depot_id gid; do
    [[ -z "$depot_id" || -z "$gid" ]] && continue
    if [[ -f "$DEPOT_DIR/${depot_id}_${gid}.manifest" ]]; then
      continue
    fi
    if "$PREFETCH_SCRIPT" --depot-id "$depot_id" --gid "$gid" \
         --target-dir "$DEPOT_DIR" --quiet >>"$CURL_LOG" 2>&1
    then
      PREFETCHED=$((PREFETCHED + 1))
    else
      rc=$?
      if [[ "$rc" == "5" ]]; then
        # Already present (race or doubled lua entry); not a failure.
        :
      else
        PREFETCH_FAILED=$((PREFETCH_FAILED + 1))
        echo "[prefetch] depot=$depot_id gid=$gid rc=$rc" >> "$CURL_LOG"
      fi
    fi
  done < <(
    # Match `setManifestid(<depot>, "<gid>"...)` and
    # `setManifestid(<depot>, <gid>, ...)`. Some lua packs use
    # one form, some use the other. Sed (BRE) keeps this portable
    # across mawk-only systems where gawk's `match(s, re, arr)`
    # third-arg form isn't available.
    sed -nE 's/.*[Ss]et[Mm]anifest[Ii]d[[:space:]]*\([[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*"?([0-9]+)"?.*/\1\t\2/p' "$LUA_FILE" 2>/dev/null \
      | sort -u
  )
fi
MANIFESTS=$((MANIFESTS + PREFETCHED))

# Best-effort DLC count by scanning the lua for addappid(<id>).
DLCS=$(grep -oiE 'addappid[[:space:]]*\([[:space:]]*[0-9]+' "$LUA_FILE" 2>/dev/null \
  | grep -oE '[0-9]+' \
  | sort -u \
  | grep -vE "^${APP_ID}$" \
  | wc -l || echo 0)

# Cleanup.
rm -f -- "$ZIP_PATH"
rm -rf -- "$EXTRACT_DIR"

write_status "{\"status\":\"done\",\"success\":true,\"api\":\"$(json_escape "$API_NAME")\",\"bytesRead\":${BYTES},\"totalBytes\":${BYTES},\"manifests\":${MANIFESTS},\"dlcs\":${DLCS},\"prefetched\":${PREFETCHED:-0},\"prefetchFailed\":${PREFETCH_FAILED:-0}}"
exit 0
