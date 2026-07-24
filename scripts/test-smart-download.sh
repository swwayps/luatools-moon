#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugin/backend/scripts/smart_download.sh"
TMP="$(mktemp -d)"
PASS=0; FAIL=0; SRV_PID=""
trap '[[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

check() {
  local name="$1"
  if eval "$2"; then echo "ok   - $name"; PASS=$((PASS + 1))
  else echo "FAIL - $name"; FAIL=$((FAIL + 1)); fi
}
state_field() {
  python3 - "$1" "$2" <<'PY'
import json,sys
with open(sys.argv[1], encoding="utf-8") as f: data=json.load(f)
print(data.get(sys.argv[2], ""))
PY
}
write_candidate() {
  printf '%s\0%s\0%s\0%s\0' "$2" "$3" "$4" "$5" >> "$1"
}
make_zip() {
  local zipfile="$1" manifest="${2:-}"
  local dir="$(mktemp -d "$TMP/zip.XXXX")"
  printf 'addappid(1134710)\naddappid(1134710,1,"%064d")\n' 0 > "$dir/1134710.lua"
  if [[ -n "$manifest" ]]; then
    printf '\320\027\366\161' > "$dir/$manifest"
  fi
  ( cd "$dir" && zip -qr "$zipfile" . )
  rm -rf "$dir"
}
make_invalid_zip() {
  local zipfile="$1" manifest="$2" dir
  dir="$(mktemp -d "$TMP/invalid.XXXX")"
  printf 'addappid(1134710)\naddappid(1134710,1,"%064d")\n' 0 > "$dir/1134710.lua"
  printf 'not-a-steam-manifest' > "$dir/$manifest"
  ( cd "$dir" && zip -qr "$zipfile" . )
  rm -rf "$dir"
}

make_zip "$TMP/fast.zip" "1134711_9001.manifest"
make_zip "$TMP/other.zip" "1134712_9002.manifest"
make_zip "$TMP/othercovered.zip" "1134711_9001.manifest"
make_invalid_zip "$TMP/invalid.zip" "1134711_9001.manifest"
LARGE_DIR="$(mktemp -d "$TMP/large.XXXX")"
printf 'addappid(1134710)\n' > "$LARGE_DIR/1134710.lua"
python3 - "$LARGE_DIR/payload.bin" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as f:
    f.write(os.urandom(512 * 1024))
PY
( cd "$LARGE_DIR" && zip -qr "$TMP/large.zip" . )
rm -rf "$LARGE_DIR"
cat > "$TMP/server.py" <<'PY'
import http.server, os, socketserver, sys, time
root=sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def do_GET(self):
    name=self.path.lstrip('/')
    if name == 'dead.zip':
      self.send_response(200); self.send_header('Content-Length','999999'); self.end_headers(); time.sleep(10); return
    status=201 if name == 'created.zip' else 200
    paced=name == 'paced.zip'
    source='fast.zip' if name == 'created.zip' else ('large.zip' if paced else name)
    path=os.path.join(root, source)
    if not os.path.isfile(path): self.send_response(404); self.end_headers(); return
    if name == 'other.zip': time.sleep(0.7)
    if name == 'othercovered.zip': time.sleep(2.0)
    data=open(path,'rb').read(); self.send_response(status)
    self.send_header('Content-Length',str(len(data))); self.end_headers()
    if paced:
      for pos in range(0, len(data), 4096):
        self.wfile.write(data[pos:pos+4096]); self.wfile.flush(); time.sleep(0.005)
    else:
      self.wfile.write(data)
server=socketserver.ThreadingTCPServer(('127.0.0.1',0),H); server.daemon_threads=True
print(server.server_address[1],flush=True); server.serve_forever()
PY
python3 "$TMP/server.py" "$TMP" > "$TMP/port" 2>/dev/null & SRV_PID=$!
PORT=""
for _ in $(seq 1 50); do PORT="$(head -1 "$TMP/port" 2>/dev/null)"; [[ -n "$PORT" ]] && break; sleep 0.1; done
[[ -n "$PORT" ]] || { echo "server failed"; exit 1; }
# All healthy APIs, including a hostile custom display name, must contribute.
D1="$TMP/d1"; mkdir -p "$D1"; C1="$TMP/c1.bin"; : > "$C1"
CUSTOM_NAME=$'custom/name\tline\nbreak'
write_candidate "$C1" 0 "Fast" "http://127.0.0.1:$PORT/fast.zip" 200
write_candidate "$C1" 1 "$CUSTOM_NAME" "http://127.0.0.1:$PORT/other.zip" 200
: > "$TMP/no-coverage"
COLLECTION_DEADLINE=3 COVERAGE_GRACE=0.2 "$SCRIPT" 1134710 "$D1/state.json" "$D1" "$C1" "$TMP/no-coverage" >/dev/null 2>&1
check "all healthy sources collected" '[[ "$(state_field "$D1/state.json" status)" == "collected" ]]'
check "first indexed source preserved" '[[ -f "$D1/extracted_1134710/source_0000/1134710.lua" ]]'
check "second indexed source preserved" '[[ -f "$D1/extracted_1134710/source_0001/1134710.lua" ]]'
check "custom display name cannot become a path" '[[ ! -e "$D1/extracted_1134710/custom" ]]'
check "custom display name preserved as metadata" '[[ "$(cat "$D1/extracted_1134710/source_0001/.source-name")" == "$CUSTOM_NAME" ]]'

# Configured non-200 success code must be accepted.
D2="$TMP/d2"; mkdir -p "$D2"; C2="$TMP/c2.bin"; : > "$C2"
write_candidate "$C2" 0 "Created" "http://127.0.0.1:$PORT/created.zip" 201
COLLECTION_DEADLINE=2 "$SCRIPT" 1134710 "$D2/state.json" "$D2" "$C2" "$TMP/no-coverage" >/dev/null 2>&1
check "configured success code accepted" '[[ -f "$D2/extracted_1134710/source_0000/1134710.lua" ]]'

# Exact cached coverage allows a short grace instead of awaiting a dead peer.
D3="$TMP/d3"; mkdir -p "$D3"; C3="$TMP/c3.bin"; : > "$C3"
write_candidate "$C3" 0 "Covered" "http://127.0.0.1:$PORT/fast.zip" 200
write_candidate "$C3" 1 "Dead" "http://127.0.0.1:$PORT/dead.zip" 200
printf '1134711\t9001\n' > "$TMP/coverage"
START=$(date +%s%3N)
COLLECTION_DEADLINE=5 COVERAGE_GRACE=0.2 SPEED_TIME=9 "$SCRIPT" 1134710 "$D3/state.json" "$D3" "$C3" "$TMP/coverage" >/dev/null 2>&1
ELAPSED=$(( $(date +%s%3N) - START ))
check "exact coverage closes collection early" '[[ "$ELAPSED" -lt 2000 ]]'
check "covered source collected" '[[ -f "$D3/extracted_1134710/source_0000/1134711_9001.manifest" ]]'
check "dead source excluded" '[[ ! -d "$D3/extracted_1134710/source_0001" ]]'

# A filename alone is not coverage: an invalid exact-named manifest must not
# cancel a slower source carrying a real Steam manifest.
D3B="$TMP/d3b"; mkdir -p "$D3B"; C3B="$TMP/c3b.bin"; : > "$C3B"
write_candidate "$C3B" 0 "Invalid exact name" "http://127.0.0.1:$PORT/invalid.zip" 200
write_candidate "$C3B" 1 "Valid slower peer" "http://127.0.0.1:$PORT/othercovered.zip" 200
printf '1134711\t9001\n' > "$TMP/coverage-invalid"
START=$(date +%s%3N)
COLLECTION_DEADLINE=3 COVERAGE_GRACE=0.2 "$SCRIPT" 1134710 "$D3B/state.json" "$D3B" "$C3B" "$TMP/coverage-invalid" >/dev/null 2>&1
ELAPSED=$(( $(date +%s%3N) - START ))
check "invalid named manifest cannot satisfy early coverage" '[[ "$ELAPSED" -ge 1500 ]]'
check "invalid source itself is still collected for its valid Lua" '[[ -f "$D3B/extracted_1134710/source_0000/1134710.lua" ]]'
check "valid slower coverage source survives" '[[ -f "$D3B/extracted_1134710/source_0001/1134711_9001.manifest" ]]'

# Without coverage, the global deadline is the absolute bound.
D4="$TMP/d4"; mkdir -p "$D4"; C4="$TMP/c4.bin"; : > "$C4"
write_candidate "$C4" 0 "Fast" "http://127.0.0.1:$PORT/fast.zip" 200
write_candidate "$C4" 1 "Dead" "http://127.0.0.1:$PORT/dead.zip" 200
START=$(date +%s%3N)
COLLECTION_DEADLINE=2 SPEED_TIME=9 "$SCRIPT" 1134710 "$D4/state.json" "$D4" "$C4" "$TMP/no-coverage" >/dev/null 2>&1
ELAPSED=$(( $(date +%s%3N) - START ))
check "global deadline bounds unhealthy source" '[[ "$ELAPSED" -ge 1800 && "$ELAPSED" -lt 3500 ]]'
check "successful peer survives deadline" '[[ -f "$D4/extracted_1134710/source_0000/1134710.lua" ]]'

# Atomic state snapshots must remain valid JSON and progress must never drop
# when a completed source leaves the pending set.
D5="$TMP/d5"; mkdir -p "$D5"; C5="$TMP/c5.bin"; : > "$C5"
write_candidate "$C5" 0 "Paced" "http://127.0.0.1:$PORT/paced.zip" 200
write_candidate "$C5" 1 "Dead" "http://127.0.0.1:$PORT/dead.zip" 200
COLLECTION_DEADLINE=1.5 SPEED_TIME=9 "$SCRIPT" 1134710 "$D5/state.json" "$D5" "$C5" "$TMP/no-coverage" >/dev/null 2>&1 &
WORKER_PID=$!
: > "$D5/observed"
JSON_ERRORS=0
while kill -0 "$WORKER_PID" 2>/dev/null; do
  if [[ -f "$D5/state.json" ]]; then
    value="$(python3 - "$D5/state.json" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(int(json.load(f).get("bytesRead", 0)))
PY
)" || JSON_ERRORS=$((JSON_ERRORS + 1))
    [[ -n "$value" ]] && printf '%s\n' "$value" >> "$D5/observed"
  fi
  sleep 0.01
done
wait "$WORKER_PID"
check "state remains valid JSON during rapid polling" '[[ "$JSON_ERRORS" -eq 0 ]]'
check "live byte progress is monotonic" 'python3 - "$D5/observed" <<'"'"'PY'"'"'
import sys
values=[int(x) for x in open(sys.argv[1]) if x.strip()]
raise SystemExit(0 if values and all(b >= a for a,b in zip(values, values[1:])) else 1)
PY'

# Existing pure progress contract remains monotonic and capped.
check "progress never decreases" '[[ "$("$SCRIPT" mono_pct 50 30)" == 50 ]]'
check "progress remains below terminal 100" '[[ "$("$SCRIPT" mono_pct 50 100)" == 99 ]]'

echo
printf 'passed: %d, failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]