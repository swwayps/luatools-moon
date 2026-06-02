#!/usr/bin/env bash
# manifest_prefetch.sh — fetch a single Steam binary manifest from
# `manifest.steam.run` + Steam CDN and drop it into a target directory
# so the local Steam client never needs to ask the CM for a request
# code. Used by `download_worker.sh` to backfill .manifest files for
# lua packs that ship only the .lua and depot keys.
#
# This is the Linux equivalent of LumaCore's PacketRouter
# `GetManifestRequestCode` injection on Windows. The hook-side path
# is implemented in slsteam-moon's `feats/manifestcode.cpp` but the
# rewrite isn't honoured by Steam Linux 2026 (see SLSsteam-fork
# HANDOFF.md "Phase 4.5"). This worker is the supported path.
#
# Args (key/value, position-independent):
#   --depot-id <id>
#   --gid <gid>
#   --target-dir <abs-path>     (writes <depot_id>_<gid>.manifest there)
#   [--cdn-host <host>]         (default: cache1-gru1.steamcontent.com)
#   [--quiet]                   (no progress output)
#
# Provider chain mirrors slsteam-moon's ManifestFetch defaults:
#   1. https://manifest.steam.run/api/manifest/<gid>   (JSON {"content":"<code>"})
#   2. http://gmrc.wudrm.com/manifest/<gid>            (plain digit string)
#
# Steam CDN endpoint shape:
#   http://<cdn-host>/depot/<depot_id>/manifest/<gid>/5/<request_code>
#   -> zip with one file "z" whose body is the binary manifest
#
# Exit codes:
#   0  success — manifest written
#   1  bad args
#   2  request-code lookup failed (all providers)
#   3  CDN fetch failed
#   4  zip extract failed / payload doesn't look like a Steam manifest
#   5  target file already present and identical (informational only;
#      caller treats this as success too)

set -u

DEPOT_ID=""
GID=""
TARGET_DIR=""
CDN_HOST="cache1-gru1.steamcontent.com"
QUIET=0

log() { [[ "$QUIET" -eq 1 ]] || printf '[manifest_prefetch] %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --depot-id) DEPOT_ID="$2"; shift 2 ;;
    --gid) GID="$2"; shift 2 ;;
    --target-dir) TARGET_DIR="$2"; shift 2 ;;
    --cdn-host) CDN_HOST="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$DEPOT_ID" || -z "$GID" || -z "$TARGET_DIR" ]]; then
  echo "usage: manifest_prefetch.sh --depot-id N --gid N --target-dir DIR [--cdn-host HOST] [--quiet]" >&2
  exit 1
fi

OUT_FILE="$TARGET_DIR/${DEPOT_ID}_${GID}.manifest"
if [[ -f "$OUT_FILE" && -s "$OUT_FILE" ]]; then
  # Existing file with non-zero size — assume good.
  log "depot=$DEPOT_ID gid=$GID already present at $OUT_FILE"
  exit 5
fi

mkdir -p "$TARGET_DIR"

# Provider 1: manifest.steam.run (JSON).
fetch_code_steamrun() {
  local body
  body=$(curl -sSL --max-time 12 --fail \
    "https://manifest.steam.run/api/manifest/${GID}" 2>/dev/null) || return 1
  # Pluck the first quoted run of digits from the body. JSON-light;
  # avoids depending on jq which the Steam runtime may not ship.
  printf '%s' "$body" | grep -oE '"[0-9]+"' | head -n1 | tr -d '"'
}

# Provider 2: gmrc.wudrm.com (plain digits).
fetch_code_wudrm() {
  curl -sSL --max-time 12 --fail \
    "http://gmrc.wudrm.com/manifest/${GID}" 2>/dev/null | tr -dc '0-9'
}

REQUEST_CODE=""
for provider in steamrun wudrm; do
  case "$provider" in
    steamrun) REQUEST_CODE=$(fetch_code_steamrun) ;;
    wudrm)    REQUEST_CODE=$(fetch_code_wudrm) ;;
  esac
  if [[ -n "$REQUEST_CODE" && "$REQUEST_CODE" != "0" ]]; then
    log "depot=$DEPOT_ID gid=$GID resolved code=$REQUEST_CODE via $provider"
    break
  fi
  REQUEST_CODE=""
  log "depot=$DEPOT_ID gid=$GID provider=$provider returned nothing usable"
done

if [[ -z "$REQUEST_CODE" ]]; then
  log "depot=$DEPOT_ID gid=$GID all providers exhausted"
  exit 2
fi

# Steam CDN. Manifest endpoint is `/depot/<id>/manifest/<gid>/5/<code>`;
# the leading `5` is the canonical "manifest" route version Valve has
# used since the 2017 redesign.
CDN_URL="http://${CDN_HOST}/depot/${DEPOT_ID}/manifest/${GID}/5/${REQUEST_CODE}"
TMP_ZIP=$(mktemp -t slsteammoon_manifest.XXXXXX.zip)
trap 'rm -f "$TMP_ZIP"' EXIT

if ! curl -sSL --fail --max-time 60 "$CDN_URL" -o "$TMP_ZIP"; then
  log "depot=$DEPOT_ID gid=$GID CDN fetch failed"
  exit 3
fi

# Steam packs the manifest in a zip with a single member named "z".
# Extract whatever's inside (single file) directly to the output path.
TMP_OUT=$(mktemp -t slsteammoon_manifest.XXXXXX.bin)
trap 'rm -f "$TMP_ZIP" "$TMP_OUT"' EXIT
if ! unzip -p "$TMP_ZIP" > "$TMP_OUT" 2>/dev/null; then
  log "depot=$DEPOT_ID gid=$GID zip extract failed"
  exit 4
fi

# Steam manifest magic is 0xD017F671 stored little-endian in the
# file (so first 4 bytes on disk are D0 17 F6 71). `od -An -t x1`
# emits raw bytes in file order so we compare against the on-disk
# byte sequence directly.
MAGIC=$(head -c 4 "$TMP_OUT" | od -An -t x1 | tr -d ' \n')
if [[ "$MAGIC" != "d017f671" ]]; then
  log "depot=$DEPOT_ID gid=$GID payload magic '$MAGIC' != expected d017f671"
  exit 4
fi

# Atomic move into the target so a partial write never poisons the
# depotcache.
mv -f "$TMP_OUT" "$OUT_FILE"
log "depot=$DEPOT_ID gid=$GID wrote $OUT_FILE"
exit 0
