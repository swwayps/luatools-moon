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
DL="$REPO/plugin/backend/scripts/downloader.sh"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

err_of() { # read the "error" field from a state json
  sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}
status_of() {
  sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}
error_code_of() {
  sed -n 's/.*"errorCode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
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

# ---------------------------------------------------------------------------
# T4-T6: Ryuu protects fix downloads with a session cookie or X-Auth-Key. An unauthenticated
# HTTP 401 must be reported as authorization (not as a corrupt archive), and a
# caller-supplied curl header file must make the same exact worker path succeed.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  AUTH_SRC="$TMP/auth-src"; mkdir -p "$AUTH_SRC"; printf 'authenticated' > "$AUTH_SRC/fix.txt"
  ( cd "$AUTH_SRC" && zip -q -r "$TMP/auth.zip" . )
  PORT_FILE="$TMP/server.port"
  python3 - "$PORT_FILE" "$TMP/auth.zip" <<'PY' &
import http.server
import pathlib
import sys

port_file = pathlib.Path(sys.argv[1])
archive = pathlib.Path(sys.argv[2]).read_bytes()

class Handler(http.server.BaseHTTPRequestHandler):
    def _authorized(self):
        return (
            self.headers.get("X-Auth-Key") == "test-secret"
            or self.headers.get("Cookie") == "session=test-session"
        )

    def _send(self, body):
        if not self._authorized():
            body = b'{"error":"Login, auth_key, or auth_code required."}\n'
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
        else:
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self._send(archive)

    def do_GET(self):
        self._send(archive)

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
PY
  SERVER_PID=$!
  i=0
  while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i+1)); done
  PORT="$(cat "$PORT_FILE")"
  AUTH_URL="http://127.0.0.1:$PORT/fix.zip"

  S4="$TMP/t4state.json"
  OUT4="$(MAX_TIME=0 bash "$DL" "$AUTH_URL" \
          "$TMP/t4dl.zip" "$TMP/t4x" "$S4" 2>&1)"
  check "T4 HTTP 401 status failed" "[ \"\$(status_of '$S4')\" = failed ]"
  check "T4 reports authorization, not corruption" \
    "err_of '$S4' | grep -qiE 'auth|login|key' && ! err_of '$S4' | grep -qi 'corrupt'"
  check "T4 exposes authentication error code" \
    "[ \"\$(error_code_of '$S4')\" = authentication ]"

  printf 'X-Auth-Key: test-secret\n' > "$TMP/t5.headers"
  S5="$TMP/t5state.json"
  OUT5="$(MAX_TIME=0 bash "$DL" "$AUTH_URL" \
          "$TMP/t5dl.zip" "$TMP/t5x" "$S5" '' "$TMP/t5.headers" 2>&1)"
  check "T5 authenticated status extracted" "[ \"\$(status_of '$S5')\" = extracted ]"
  check "T5 authenticated archive extracted" "[ \"\$(cat '$TMP/t5x/fix.txt')\" = authenticated ]"

  printf 'Cookie: session=test-session\n' > "$TMP/t6.headers"
  S6="$TMP/t6state.json"
  OUT6="$(MAX_TIME=0 bash "$DL" "$AUTH_URL" \
          "$TMP/t6dl.zip" "$TMP/t6x" "$S6" '' "$TMP/t6.headers" 2>&1)"
  check "T6 session-cookie status extracted" "[ \"\$(status_of '$S6')\" = extracted ]"
  check "T6 session-cookie archive extracted" "[ \"\$(cat '$TMP/t6x/fix.txt')\" = authenticated ]"
else
  echo "SKIP: no python3 for authenticated HTTP fixture"
fi

# T7: a URL the catalogue served unencoded (raw space) is rejected by curl before
# any connection is attempted (rc=3, "URL using bad/illegal format"). Blaming the
# network there sends the user chasing a connection problem that does not exist.
S7="$TMP/t7state.json"
OUT7="$(MAX_TIME=5 bash "$DL" "https://generator.ryuu.lol/fixes/Gang Beasts.zip" \
        "$TMP/t7dl.zip" "$TMP/t7x" "$S7" 2>&1)"
check "T7 status failed" "[ \"\$(status_of '$S7')\" = failed ]"
check "T7 blames the address, not the connection" \
  "err_of '$S7' | grep -qiE 'address|link|url' && ! err_of '$S7' | grep -qiE \"respond|interrupt\""
check "T7 exposes a distinct error code" "[ \"\$(error_code_of '$S7')\" = badurl ]"
check "T7 emits a slog line" "printf '%s' \"$OUT7\" | grep -q 'downloader'"

# A host that cannot resolve is a real connectivity failure, so it must NOT be
# reported as a bad link (offline users hit this path).
S8="$TMP/t8state.json"
OUT8="$(CONNECT_TIMEOUT=3 MAX_TIME=6 bash "$DL" "https://luatools-does-not-exist.invalid/fix.zip" \
        "$TMP/t8dl.zip" "$TMP/t8x" "$S8" 2>&1)"
check "T8 status failed" "[ \"\$(status_of '$S8')\" = failed ]"
check "T8 an unreachable host is not called a bad link" \
  "[ \"\$(error_code_of '$S8')\" != badurl ]"

if [ "$fails" -eq 0 ]; then echo; echo "ALL TESTS OK"; else echo; echo "$fails FAILED"; exit 1; fi
