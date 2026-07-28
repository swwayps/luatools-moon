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
SLOW_DIR="$(mktemp -d "$TMP/slow.XXXX")"
printf 'addappid(1134710)\n' > "$SLOW_DIR/1134710.lua"
python3 - "$SLOW_DIR/payload.bin" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as f:
    f.write(os.urandom(1024))
PY
( cd "$SLOW_DIR" && zip -qr "$TMP/slow.zip" . )
rm -rf "$SLOW_DIR"
cat > "$TMP/server.py" <<'PY'
import http.server, os, socketserver, sys, time
root=sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def do_GET(self):
    name=self.path.lstrip('/')
    if name == 'dead.zip':
      self.send_response(200); self.send_header('Content-Length','999999'); self.end_headers(); time.sleep(10); return
    if name == 'late.zip':
      time.sleep(0.7)
    status=201 if name == 'created.zip' else 200
    paced=name == 'paced.zip'
    slow=name == 'slow.zip'
    if name == 'created.zip' or name == 'late.zip': source='fast.zip'
    elif paced: source='large.zip'
    elif slow: source='slow.zip'
    else: source=name
    path=os.path.join(root, source)
    if not os.path.isfile(path): self.send_response(404); self.end_headers(); return
    if name == 'other.zip': time.sleep(0.7)
    if name == 'othercovered.zip': time.sleep(2.0)
    data=open(path,'rb').read(); self.send_response(status)
    self.send_header('Content-Length',str(len(data))); self.end_headers()
    if paced:
      for pos in range(0, len(data), 4096):
        self.wfile.write(data[pos:pos+4096]); self.wfile.flush(); time.sleep(0.005)
    elif slow:
      for pos in range(0, len(data), 64):
        self.wfile.write(data[pos:pos+64]); self.wfile.flush(); time.sleep(0.08)
    else:
      self.wfile.write(data)
server=socketserver.ThreadingTCPServer(('127.0.0.1',0),H); server.daemon_threads=True
print(server.server_address[1],flush=True); server.serve_forever()
PY
python3 "$TMP/server.py" "$TMP" > "$TMP/port" 2>/dev/null & SRV_PID=$!
PORT=""
for _ in $(seq 1 50); do PORT="$(head -1 "$TMP/port" 2>/dev/null)"; [[ -n "$PORT" ]] && break; sleep 0.1; done
[[ -n "$PORT" ]] || { echo "server failed"; exit 1; }
: > "$TMP/no-coverage"

# Before any source succeeds, the shared fast-path deadline must never turn a
# slow but healthy connection into a total failure.
D0A="$TMP/d0a"; mkdir -p "$D0A"; C0A="$TMP/c0a.bin"; : > "$C0A"
write_candidate "$C0A" 0 "Slow connection" "http://127.0.0.1:$PORT/slow.zip" 200
START=$(date +%s%3N)
COLLECTION_DEADLINE=0.2 SPEED_TIME=1 "$SCRIPT" 1134710 "$D0A/state.json" "$D0A" "$C0A" "$TMP/no-coverage" >/dev/null 2>&1
ELAPSED=$(( $(date +%s%3N) - START ))
check "sub-kilobyte healthy transfer is accepted" '[[ -f "$D0A/extracted_1134710/source_0000/payload.bin" ]]'
check "slow transfer continues beyond fast-path deadline" '[[ "$ELAPSED" -ge 1000 ]]'

# A source may take longer than the fast-path deadline to produce its first
# byte (slow network, TLS, or on-demand archive generation).
D0B="$TMP/d0b"; mkdir -p "$D0B"; C0B="$TMP/c0b.bin"; : > "$C0B"
write_candidate "$C0B" 0 "Late first byte" "http://127.0.0.1:$PORT/late.zip" 200
COLLECTION_DEADLINE=0.2 SPEED_TIME=2 "$SCRIPT" 1134710 "$D0B/state.json" "$D0B" "$C0B" "$TMP/no-coverage" >/dev/null 2>&1
check "first source can start after fast-path deadline" '[[ -f "$D0B/extracted_1134710/source_0000/1134710.lua" ]]'

# With no successful fallback, a truly stalled source is still bounded by its
# own inactivity guard rather than by the shared fast-path deadline.
D0C="$TMP/d0c"; mkdir -p "$D0C"; C0C="$TMP/c0c.bin"; : > "$C0C"
write_candidate "$C0C" 0 "Stalled" "http://127.0.0.1:$PORT/dead.zip" 200
START=$(date +%s%3N)
if COLLECTION_DEADLINE=0.2 SPEED_TIME=1 "$SCRIPT" 1134710 "$D0C/state.json" "$D0C" "$C0C" "$TMP/no-coverage" >/dev/null 2>&1; then
  STALLED_RC=0
else
  STALLED_RC=$?
fi
ELAPSED=$(( $(date +%s%3N) - START ))
check "fully stalled source still fails" '[[ "$STALLED_RC" -ne 0 && "$(state_field "$D0C/state.json" status)" == "failed" ]]'
# curl's 1-second inactivity guard should finish well before the fixture's
# 10-second server stall, with room for scheduling delays on CI runners.
check "stalled source uses bounded inactivity timeout" '[[ "$ELAPSED" -ge 800 && "$ELAPSED" -lt 8000 ]]'

# All healthy APIs, including a hostile custom display name, must contribute.
D1="$TMP/d1"; mkdir -p "$D1"; C1="$TMP/c1.bin"; : > "$C1"
CUSTOM_NAME=$'custom/name\tline\nbreak'
write_candidate "$C1" 0 "Fast" "http://127.0.0.1:$PORT/fast.zip" 200
write_candidate "$C1" 1 "$CUSTOM_NAME" "http://127.0.0.1:$PORT/other.zip" 200
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

# Exact coverage and the shared startup deadline must not truncate another
# healthy source that is actively transferring complementary data. This models
# large multi-DLC archives that legitimately need longer than the fast path.
D3A="$TMP/d3a"; mkdir -p "$D3A"; C3A="$TMP/c3a.bin"; : > "$C3A"
write_candidate "$C3A" 0 "Covered" "http://127.0.0.1:$PORT/fast.zip" 200
write_candidate "$C3A" 1 "Large active" "http://127.0.0.1:$PORT/paced.zip" 200
printf '1134711\t9001\n' > "$TMP/coverage-active"
COLLECTION_DEADLINE=0.3 COVERAGE_GRACE=0.1 SPEED_TIME=9 "$SCRIPT" 1134710 "$D3A/state.json" "$D3A" "$C3A" "$TMP/coverage-active" >/dev/null 2>&1
check "active large source survives coverage grace and startup deadline" '[[ -f "$D3A/extracted_1134710/source_0001/payload.bin" ]]'

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

# After one usable result, the fast-path deadline still bounds an unhealthy
# peer even when exact coverage is unavailable.
D4="$TMP/d4"; mkdir -p "$D4"; C4="$TMP/c4.bin"; : > "$C4"
write_candidate "$C4" 0 "Fast" "http://127.0.0.1:$PORT/fast.zip" 200
write_candidate "$C4" 1 "Dead" "http://127.0.0.1:$PORT/dead.zip" 200
START=$(date +%s%3N)
COLLECTION_DEADLINE=2 SPEED_TIME=9 "$SCRIPT" 1134710 "$D4/state.json" "$D4" "$C4" "$TMP/no-coverage" >/dev/null 2>&1
ELAPSED=$(( $(date +%s%3N) - START ))
# The exact close time may be earlier when the usable peer finishes while curl
# processes are still being started. What matters is that the unhealthy peer
# is bounded well before curl's 9-second inactivity timeout; the next assertion
# independently proves that the successful peer survives that early close.
check "global deadline bounds unhealthy source" '[[ "$ELAPSED" -lt 8000 ]]'
check "successful peer survives deadline" '[[ -f "$D4/extracted_1134710/source_0000/1134710.lua" ]]'

# Atomic state snapshots must remain valid JSON, progress must never drop,
# and known response sizes must expose real intermediate percentages.
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
    data = json.load(f)
print(int(data.get("bytesRead", 0)), int(data.get("totalBytes", 0)))
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
samples=[tuple(map(int, x.split())) for x in open(sys.argv[1]) if x.strip()]
values=[sample[0] for sample in samples]
raise SystemExit(0 if values and all(b >= a for a,b in zip(values, values[1:])) else 1)
PY'
check "known totals expose intermediate progress" 'python3 - "$D5/observed" <<'"'"'PY'"'"'
import sys
samples=[tuple(map(int, x.split())) for x in open(sys.argv[1]) if x.strip()]
pcts=[bytes_read * 100 / total for bytes_read, total in samples if total > 0]
raise SystemExit(0 if any(1 < pct < 99 for pct in pcts) else 1)
PY'

# Existing pure progress contract remains monotonic and capped.
check "progress never decreases" '[[ "$("$SCRIPT" mono_pct 50 30)" == 50 ]]'
check "progress remains below terminal 100" '[[ "$("$SCRIPT" mono_pct 50 100)" == 99 ]]'

echo
printf 'passed: %d, failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
