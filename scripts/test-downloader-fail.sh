#!/usr/bin/env bash
# Tests for downloader.sh's failure reporting + diagnostics logging.
#
# Two goals this guards:
#   1. FRIENDLY failure reasons in the <appid>_state.json "error" field. The
#      old worker wrote raw "curl failed" / "extract failed", which the UI
#      surfaced verbatim ("Failed: curl failed"). A user shouldn't see curl
#      internals; the reason must read like a human wrote it.
#   2. DIAGNOSTICS: the worker must emit ISO-8601 slog lines to stdout (the
#      caller redirects stdout->~/.lumen.log), so every download — add-via-
#      LuaTools AND the fixes menu, both of which run this script — is logged.
#      Before, downloader.sh was silent and launched with >/dev/null, so a
#      failed add left NOTHING in the log.
#
# Run from the repo root:  bash scripts/test-downloader-fail.sh
set -u

fails=0
check() { if eval "$2"; then echo "ok $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DL="$REPO/linux/backend/scripts/downloader.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

err_of() { # read the "error" field from a state json
  sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}
status_of() {
  sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}

# ---------------------------------------------------------------------------
# T1: curl failure (source unreachable) -> friendly error + a slog line.
# ---------------------------------------------------------------------------
S1="$TMP/t1state.json"
OUT1="$(MAX_TIME=0 bash "$DL" "file://$TMP/does_not_exist.zip" \
        "$TMP/t1dl.zip" "$TMP/t1x" "$S1" 2>&1)"
check "T1 status failed"        "[ \"\$(status_of '$S1')\" = failed ]"
check "T1 not raw 'curl failed'" "[ \"\$(err_of '$S1')\" != 'curl failed' ]"
check "T1 friendly error text"  "err_of '$S1' | grep -qiE 'download|source|connect'"
check "T1 emits a downloader slog line" "printf '%s' \"\$OUT1\" | grep -q 'downloader\['"

# ---------------------------------------------------------------------------
# T2: extract failure (a valid download that is NOT a real archive) -> friendly
#     error, not raw "extract failed".
# ---------------------------------------------------------------------------
printf 'this is not a zip' > "$TMP/notzip.bin"
S2="$TMP/t2state.json"
OUT2="$(MAX_TIME=0 bash "$DL" "file://$TMP/notzip.bin" \
        "$TMP/t2dl.zip" "$TMP/t2x" "$S2" 2>&1)"
check "T2 status failed"          "[ \"\$(status_of '$S2')\" = failed ]"
check "T2 not raw 'extract failed'" "[ \"\$(err_of '$S2')\" != 'extract failed' ]"
check "T2 friendly extract text"  "err_of '$S2' | grep -qiE 'open|corrupt|package|extract'"

# ---------------------------------------------------------------------------
# T3: success path -> status 'extracted' + slog line naming the phase.
# ---------------------------------------------------------------------------
SRC="$TMP/t3src"; mkdir -p "$SRC"; printf 'hello' > "$SRC/1234567.lua"
( cd "$SRC" && zip -q -r "$TMP/t3.zip" . ) 2>/dev/null || {
  echo "SKIP: no zip to build fixture"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }
S3="$TMP/t3state.json"
OUT3="$(MAX_TIME=0 bash "$DL" "file://$TMP/t3.zip" \
        "$TMP/t3dl.zip" "$TMP/t3x" "$S3" 2>&1)"
check "T3 status extracted"       "[ \"\$(status_of '$S3')\" = extracted ]"
check "T3 emits a slog line"      "printf '%s' \"\$OUT3\" | grep -q 'downloader\['"

if [ "$fails" -eq 0 ]; then echo; echo "ALL TESTS OK"; else echo; echo "$fails FAILED"; exit 1; fi
