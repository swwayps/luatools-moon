#!/usr/bin/env bash
# test-smart-download.sh — unit tests for the smart source selector.
#
# Tests the PURE logic (no network) of plugin/backend/scripts/smart_download.sh
# via its subcommands:
#   smart_download.sh score  <appid> <candidate_dir>   -> "<app_key> <key_count> <manifest_count>"
#   smart_download.sh select <appid> <work_dir>        -> winning candidate name
#
# Run: scripts/test-smart-download.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugin/backend/scripts/smart_download.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "ok   - $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $desc"
    echo "        expected: [$expected]"
    echo "        actual:   [$actual]"
  fi
}

# --- fixtures: real NIMBY Rails (1134710) lua variants per source ---------
make_candidate() {
  # make_candidate <name> <n_manifests> <<lua-on-stdin
  local name="$1" n_manifests="$2"
  local dir="$TMP/$name"
  mkdir -p "$dir"
  cat > "$dir/1134710.lua"
  local i=0
  while [[ $i -lt $n_manifests ]]; do
    echo "dummy" > "$dir/depot_${i}_x.manifest"
    i=$((i + 1))
  done
}

# Hubcap: app-depot key present, 4 depot keys, 3 manifests
make_candidate hubcap 3 <<'LUA'
addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
setManifestid(1134711, "3238948344654627795", 49979014)
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
addappid(228989, 1, "ad69276eb476cf06c40312df7376d63deac0c838b9a2767005be8bb306ffb853")
LUA

# Ryuu: app-depot key present (bare addappid first), 3 depot keys, 2 manifests
make_candidate ryuu 2 <<'LUA'
addappid(1134710)
addappid(1134710,0,"1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA

# Sushi: NO app-depot key, 2 depot keys, 2 manifests, comment must be ignored
make_candidate sushi 2 <<'LUA'
addappid(1134710)
-- addappid(1134710,0,"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
addappid(1134711, 1, "E4C5307D44D1E6057D21C3828BC766B625266BC61281E682B3ACE83B0612F7D0")
addappid(1134712, 1, "6ACA6CE3DD1188B29E3251D88AEEF183FFD6BFE5F89260BE29C375811BA92903")
LUA

# Minimal: NO app-depot key, 2 depot keys, 0 manifests
make_candidate minimal 0 <<'LUA'
addappid(1134710)
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA

# --- scoring tests --------------------------------------------------------
assert_eq "hubcap score (app_key=1, 4 keys, 3 manifests)" \
  "1 4 3" "$("$SCRIPT" score 1134710 "$TMP/hubcap")"

assert_eq "ryuu score (app_key=1, 3 keys, 2 manifests)" \
  "1 3 2" "$("$SCRIPT" score 1134710 "$TMP/ryuu")"

assert_eq "sushi score (app_key=0, 2 keys, 2 manifests; comment ignored)" \
  "0 2 2" "$("$SCRIPT" score 1134710 "$TMP/sushi")"

assert_eq "minimal score (app_key=0, 2 keys, 0 manifests)" \
  "0 2 0" "$("$SCRIPT" score 1134710 "$TMP/minimal")"

# --- selection tests ------------------------------------------------------
# select <appid> <work_dir>: each candidate is a subdir <name>/ with the
# extracted files plus a sibling <name>.time file holding the download time
# (seconds). Winner = highest (app_key, key_count, manifest_count), tie
# broken by smallest time. Prints the winning candidate name.

make_sel_candidate() {
  # make_sel_candidate <work_dir> <name> <n_manifests> <time> <<lua
  local wd="$1" name="$2" n_manifests="$3" time="$4"
  local dir="$wd/$name"
  mkdir -p "$dir"
  cat > "$dir/1134710.lua"
  local i=0
  while [[ $i -lt $n_manifests ]]; do
    echo "dummy" > "$dir/depot_${i}_x.manifest"
    i=$((i + 1))
  done
  echo "$time" > "$wd/$name.time"
}

# Case 1: full candidate set -> fastcomplete wins (ties hubcap on (1,4,3), faster).
WD1="$TMP/sel_full"; mkdir -p "$WD1"
make_sel_candidate "$WD1" hubcap 3 2.0 <<'LUA'
addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
addappid(228989, 1, "ad69276eb476cf06c40312df7376d63deac0c838b9a2767005be8bb306ffb853")
LUA
make_sel_candidate "$WD1" fastcomplete 3 1.0 <<'LUA'
addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
addappid(228989, 1, "ad69276eb476cf06c40312df7376d63deac0c838b9a2767005be8bb306ffb853")
LUA
make_sel_candidate "$WD1" ryuu 2 50.0 <<'LUA'
addappid(1134710,0,"1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
make_sel_candidate "$WD1" sushi 2 0.5 <<'LUA'
addappid(1134710)
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
make_sel_candidate "$WD1" minimal 0 0.3 <<'LUA'
addappid(1134710)
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
assert_eq "select full candidate set -> fastcomplete (complete + fastest of the complete)" \
  "fastcomplete" "$("$SCRIPT" select 1134710 "$WD1")"

# Case 2: only incomplete sources -> sushi (more manifests) beats minimal.
WD2="$TMP/sel_incomplete"; mkdir -p "$WD2"
make_sel_candidate "$WD2" sushi 2 0.5 <<'LUA'
addappid(1134710)
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
make_sel_candidate "$WD2" minimal 0 0.3 <<'LUA'
addappid(1134710)
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
assert_eq "select incomplete-only -> sushi (more manifests than minimal)" \
  "sushi" "$("$SCRIPT" select 1134710 "$WD2")"

# Case 3: pure completeness tie -> faster time wins.
WD3="$TMP/sel_tie"; mkdir -p "$WD3"
make_sel_candidate "$WD3" slowcomplete 3 9.0 <<'LUA'
addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
addappid(228989, 1, "ad69276eb476cf06c40312df7376d63deac0c838b9a2767005be8bb306ffb853")
LUA
make_sel_candidate "$WD3" fastcomplete 3 1.2 <<'LUA'
addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
addappid(228989, 1, "ad69276eb476cf06c40312df7376d63deac0c838b9a2767005be8bb306ffb853")
LUA
assert_eq "select completeness tie -> faster wins" \
  "fastcomplete" "$("$SCRIPT" select 1134710 "$WD3")"

# --- app-key detection inside a zip (peek without full extraction) --------
# appkey <appid> <zipfile> -> "yes" if the in-zip <appid>.lua carries a real
# addappid(<appid>, N, "<64hex>") depot key (comments stripped), else "no".
# This is what lets the race know, mid-flight, whether a completed candidate
# is already "complete enough" (has the app/Workshop depot key) to stop early.
if command -v zip >/dev/null 2>&1; then
  mk_zip() {
    # mk_zip <zipfile> <<lua  (writes a 1134710.lua zip)
    local zf="$1" d
    d="$(mktemp -d)"
    cat > "$d/1134710.lua"
    ( cd "$d" && zip -qr "$zf" . )
    rm -rf "$d"
  }
  mk_zip "$TMP/ak_yes.zip" <<'LUA'
addappid(1134710)
addappid(1134710,0,"1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
LUA
  mk_zip "$TMP/ak_no.zip" <<'LUA'
addappid(1134710)
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
LUA
  mk_zip "$TMP/ak_comment.zip" <<'LUA'
addappid(1134710)
-- addappid(1134710,0,"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
LUA
  assert_eq "appkey: zip with app-depot key -> yes" \
    "yes" "$("$SCRIPT" appkey 1134710 "$TMP/ak_yes.zip")"
  assert_eq "appkey: zip without app-depot key -> no" \
    "no" "$("$SCRIPT" appkey 1134710 "$TMP/ak_no.zip")"
  assert_eq "appkey: commented-out app-depot key -> no" \
    "no" "$("$SCRIPT" appkey 1134710 "$TMP/ak_comment.zip")"
else
  echo "skip - zip not available for appkey tests"
fi

# --- window decision (pure, deterministic; no network/timing flakiness) ---
# window <satisfied> <running> <elapsed> <since_satisfied> -> "wait" | "stop"
#   satisfied        = 1 if a completed candidate already has the app-key
#   running          = number of candidates whose download is still in flight
#   elapsed          = seconds since the race (GET) started (diagnostic only)
#   since_satisfied  = seconds since the first app-key completion (-1 if none)
#
# Relative-cut model: the window NEVER closes on a wall-clock deadline. A
# healthy source still in flight is awaited no matter how long it takes; only
# its OWN curl (connect-timeout + speed floor) can drop it when it goes dead or
# extremely slow. The window closes only when:
#   - every source has finished/died (running==0), or
#   - a COMPLETE source has won and the speed-first GRACE_SECS has elapsed
#     (then the slower/still-running peers are cancelled — a faster, complete
#     source beat them).
# `elapsed` is passed for diagnostics but no longer caps the wait.
assert_eq "window: all candidates finished -> stop" \
  "stop" "$(GRACE_SECS=3 "$SCRIPT" window 0 0 1 -1)"

assert_eq "window: no complete source yet, still running -> wait" \
  "wait" "$(GRACE_SECS=3 "$SCRIPT" window 0 1 5 -1)"

# a slow source still downloading must be AWAITED, not cancelled, while no
# completed source has the app-key.
assert_eq "window: slow source still in flight, none complete -> wait" \
  "wait" "$(GRACE_SECS=3 "$SCRIPT" window 0 1 13 -1)"

# the core change: a long-running but healthy source with NO complete peer is
# NOT cut by any wall-clock cap. It is awaited until it finishes or its own
# curl speed floor drops it. (Previously a CAP_SECS backstop forced "stop".)
assert_eq "window: long-running source, none complete -> wait (no wall-clock cut)" \
  "wait" "$(GRACE_SECS=3 "$SCRIPT" window 0 1 120 -1)"

assert_eq "window: very long-running source, none complete -> wait" \
  "wait" "$(GRACE_SECS=3 "$SCRIPT" window 0 2 600 -1)"

assert_eq "window: complete source found, within grace -> wait" \
  "wait" "$(GRACE_SECS=3 "$SCRIPT" window 1 1 5 1)"

assert_eq "window: complete source found, past grace -> stop (speed-first)" \
  "stop" "$(GRACE_SECS=3 "$SCRIPT" window 1 1 8 4)"

# locale robustness: the grace comparison (since_satisfied vs GRACE_SECS) must
# stay NUMERIC even under comma-decimal locales (pt_BR/de_DE awk printf emits
# "12,000"); a string compare would mis-order it.
assert_eq "window: comma-decimal since-grace past grace -> stop" \
  "stop" "$(GRACE_SECS=3 "$SCRIPT" window 1 1 "12,000" "10,500")"

assert_eq "window: comma-decimal since-grace within grace -> wait" \
  "wait" "$(GRACE_SECS=3 "$SCRIPT" window 1 1 "5,500" "2,250")"

# --- progress: monotonic, capped percentage (no backward jumps) -----------
# mono_pct <prev_pct> <raw_pct> -> the percentage to display: never below the
# previously shown value (so switching the progress anchor between racers of
# different sizes can't drop the bar), and capped at 99 during the race (100%
# is reserved for the extract/finalize phase).
assert_eq "mono_pct: first sample passes through" \
  "50" "$("$SCRIPT" mono_pct 0 50)"
assert_eq "mono_pct: never decreases when a smaller-fraction anchor takes over" \
  "50" "$("$SCRIPT" mono_pct 50 30)"
assert_eq "mono_pct: a finished small source cannot show 100 mid-race (cap 99)" \
  "99" "$("$SCRIPT" mono_pct 50 100)"
assert_eq "mono_pct: stays capped at 99" \
  "99" "$("$SCRIPT" mono_pct 99 100)"
assert_eq "mono_pct: zero stays zero" \
  "0" "$("$SCRIPT" mono_pct 0 0)"
assert_eq "mono_pct: advances when raw exceeds prev" \
  "73" "$("$SCRIPT" mono_pct 40 73)"

# --- integration: full race over a local HTTP server (no real network) ----
# Serves fixture zips from a temp dir and runs the worker end-to-end.
# Asserts the final state is "extracted", the installed lua carries the
# app-depot key, and an incomplete source did not win.
if command -v python3 >/dev/null 2>&1; then
  SRV="$TMP/srv"; mkdir -p "$SRV"
  build_zip() {
    # build_zip <name> <n_manifests> <<lua
    local name="$1" n="$2"
    local d="$TMP/zsrc_$name"
    mkdir -p "$d"; cat > "$d/1134710.lua"
    local i=0; while [[ $i -lt $n ]]; do echo dummy > "$d/dep_${i}.manifest"; i=$((i+1)); done
    ( cd "$d" && zip -qr "$SRV/$name.zip" . )
  }
  build_zip complete 3 <<'LUA'
addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
addappid(228989, 1, "ad69276eb476cf06c40312df7376d63deac0c838b9a2767005be8bb306ffb853")
LUA
  build_zip incomplete 0 <<'LUA'
addappid(1134710)
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
LUA

  ( python3 - "$SRV" >"$SRV/port.txt" 2>/dev/null <<'PY'
import sys, os, http.server, socketserver
os.chdir(sys.argv[1])
httpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
httpd.daemon_threads = True
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY
  ) &
  SRV_PID=$!
  # discover the chosen port (printed on the first line)
  PORT=""
  for _ in $(seq 1 50); do
    PORT="$(head -1 "$SRV/port.txt" 2>/dev/null | grep -oE '^[0-9]+')"
    [[ -n "$PORT" ]] && break
    sleep 0.1
  done

  if [[ -n "$PORT" ]]; then
    CAND="$TMP/cands.txt"
    printf 'incomplete\thttp://127.0.0.1:%s/incomplete.zip\n' "$PORT" >  "$CAND"
    printf 'complete\thttp://127.0.0.1:%s/complete.zip\n'     "$PORT" >> "$CAND"
    DEST="$TMP/dl"; mkdir -p "$DEST"
    STATE="$DEST/1134710_state.json"
    "$SCRIPT" 1134710 "$STATE" "$DEST" "$CAND" >/dev/null 2>&1

    final_status="$(grep -oE '"status"[: ]*"[a-z]+"' "$STATE" 2>/dev/null | tail -1 | grep -oE '[a-z]+"$' | tr -d '"')"
    assert_eq "race: final state is extracted" "extracted" "$final_status"

    installed_lua="$(find "$DEST/extracted_1134710" -name '1134710.lua' -print -quit 2>/dev/null)"
    if [[ -n "$installed_lua" ]] && grep -Eq 'addappid\s*\(\s*1134710\s*,\s*[0-9]+\s*,\s*"[0-9A-Fa-f]{64}"' "$installed_lua"; then
      has_app_key="yes"
    else
      has_app_key="no"
    fi
    assert_eq "race: winning lua carries the app-depot key (complete source won)" "yes" "$has_app_key"

    if [[ -d "$DEST/race_1134710" ]]; then scratch="present"; else scratch="gone"; fi
    assert_eq "race: scratch dir cleaned on success (no leftover source zips)" "gone" "$scratch"

    # currentApi in the final state must be the WINNER (complete), not the
    # leading source mid-race (which the frontend would mislabel as Found).
    final_api="$(grep -oE '"currentApi"[: ]*"[^"]*"' "$STATE" 2>/dev/null | tail -1 | sed -E 's/.*"currentApi"[: ]*"([^"]*)"/\1/')"
    assert_eq "race: final currentApi is the winner, not the leader" "complete" "$final_api"

    # failure path: all sources 404 -> failed, and scratch still cleaned.
    CANDF="$TMP/cands_fail.txt"
    printf 'a\thttp://127.0.0.1:%s/nope1.zip\nb\thttp://127.0.0.1:%s/nope2.zip\n' "$PORT" "$PORT" > "$CANDF"
    DESTF="$TMP/dlf"; mkdir -p "$DESTF"
    STATEF="$DESTF/1134710_state.json"
    "$SCRIPT" 1134710 "$STATEF" "$DESTF" "$CANDF" >/dev/null 2>&1
    failst="$(grep -oE '"status"[: ]*"[a-z]+"' "$STATEF" 2>/dev/null | tail -1 | grep -oE '[a-z]+"$' | tr -d '"')"
    assert_eq "race: all-sources-fail -> failed state" "failed" "$failst"
    if [[ -d "$DESTF/race_1134710" ]]; then fscratch="present"; else fscratch="gone"; fi
    assert_eq "race: scratch dir cleaned on failure too" "gone" "$fscratch"
  else
    echo "skip - could not start local http server"
  fi
  kill "$SRV_PID" 2>/dev/null

  # --- completeness-aware window over a throttling HTTP server -------------
  # The Binding-of-Isaac bug: a fast source that lacks the app/Workshop depot
  # key must NOT win over a slower source that has it. The race must wait for
  # the slow-but-complete source while no completed source carries the key,
  # yet still preserve speed-first when a complete source arrives fast, and
  # never hang on a truly dead source.
  SRV2="$TMP/srv2"; mkdir -p "$SRV2"
  rm -rf "$TMP/zf" "$TMP/zfc" "$TMP/zs"; mkdir -p "$TMP/zf" "$TMP/zfc" "$TMP/zs"
  # fast-incomplete: instant, NO app-depot key
  printf 'addappid(1134710)\naddappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")\n' > "$TMP/zf/1134710.lua"
  ( cd "$TMP/zf" && zip -qr "$SRV2/fast.zip" . )
  # fast-complete: instant, HAS app-depot key
  printf 'addappid(1134710)\naddappid(1134710,0,"1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")\n' > "$TMP/zfc/1134710.lua"
  ( cd "$TMP/zfc" && zip -qr "$SRV2/fastcomplete.zip" . )
  # slow-complete: throttled, HAS app-depot key
  printf 'addappid(1134710)\naddappid(1134710,0,"1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")\n' > "$TMP/zs/1134710.lua"
  head -c 20000 /dev/zero | tr '\0' 'x' > "$TMP/zs/big.manifest"
  ( cd "$TMP/zs" && zip -qr0 "$SRV2/slow.zip" . )

  cat > "$TMP/slow_server.py" <<PY
import os, time, http.server, socketserver
DIR = "$SRV2"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _hdr(self, path):
        try: n = os.path.getsize(os.path.join(DIR, path))
        except OSError:
            self.send_response(404); self.end_headers(); return None
        self.send_response(200)
        self.send_header("Content-Length", str(n)); self.end_headers()
        return n
    def do_HEAD(self):
        # a "dead" host accepts the connection but never answers HEAD in time
        if "dead" in self.path:
            time.sleep(30); return
        self._hdr(self.path.lstrip("/"))
    def do_GET(self):
        name = self.path.lstrip("/")
        if "dead" in name:
            # send headers then hang forever -> curl --max-time must cancel it
            try:
                self.send_response(200); self.send_header("Content-Length", "100000"); self.end_headers()
            except Exception: return
            time.sleep(60); return
        n = self._hdr(name)
        if n is None: return
        data = open(os.path.join(DIR, name), "rb").read()
        if name == "slow.zip":
            # ~0.8s TTFB then ~2KB/s: finishes in a few seconds, well under MAX_TIME
            time.sleep(0.8)
            for i in range(0, len(data), 1024):
                try: self.wfile.write(data[i:i+1024]); self.wfile.flush()
                except Exception: return
                time.sleep(0.25)
        else:
            try: self.wfile.write(data)
            except Exception: pass
httpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
httpd.daemon_threads = True
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY
  ( python3 "$TMP/slow_server.py" >"$SRV2/port.txt" 2>/dev/null ) &
  SRV2_PID=$!
  PORT2=""
  for _ in $(seq 1 50); do
    PORT2="$(head -1 "$SRV2/port.txt" 2>/dev/null | grep -oE '^[0-9]+')"
    [[ -n "$PORT2" ]] && break
    sleep 0.1
  done

  has_app_key_lua() {
    # has_app_key_lua <extract_dir> -> "yes"/"no"
    local lua
    lua="$(find "$1" -name '1134710.lua' -print -quit 2>/dev/null)"
    if [[ -n "$lua" ]] && grep -Eq 'addappid\s*\(\s*1134710\s*,\s*[0-9]+\s*,\s*"[0-9A-Fa-f]{64}"' "$lua"; then
      echo "yes"; else echo "no"; fi
  }

  if [[ -n "$PORT2" ]]; then
    # Scenario A (the fix): slow-but-complete must beat fast-but-incomplete.
    CANDA="$TMP/candsA.txt"
    printf 'fastincomplete\thttp://127.0.0.1:%s/fast.zip\n' "$PORT2" >  "$CANDA"
    printf 'slowcomplete\thttp://127.0.0.1:%s/slow.zip\n'   "$PORT2" >> "$CANDA"
    DESTA="$TMP/dlA"; mkdir -p "$DESTA"
    STATEA="$DESTA/1134710_state.json"
    SPEED_LIMIT=1 SPEED_TIME=99 MAX_TIME=15 GRACE_SECS=2 CAP_SECS=20 \
      "$SCRIPT" 1134710 "$STATEA" "$DESTA" "$CANDA" >/dev/null 2>&1
    finA="$(grep -oE '"status"[: ]*"[a-z]+"' "$STATEA" 2>/dev/null | tail -1 | grep -oE '[a-z]+"$' | tr -d '"')"
    assert_eq "window: slow-complete vs fast-incomplete -> completes (extracted)" "extracted" "$finA"
    assert_eq "window: slow-complete source won (app-depot key present)" \
      "yes" "$(has_app_key_lua "$DESTA/extracted_1134710")"
    apiA="$(grep -oE '"currentApi"[: ]*"[^"]*"' "$STATEA" 2>/dev/null | tail -1 | sed -E 's/.*"currentApi"[: ]*"([^"]*)"/\1/')"
    assert_eq "window: winner reported is slowcomplete, not the fast leader" "slowcomplete" "$apiA"
    # the candidates file must be cleaned up after the run (no leftovers)
    if [[ -f "$CANDA" ]]; then leftA="present"; else leftA="gone"; fi
    assert_eq "cleanup: candidates file removed after run" "gone" "$leftA"

    # Scenario B (speed-first preserved): fast-complete wins promptly and the
    # slow (also complete) source is NOT awaited.
    CANDB="$TMP/candsB.txt"
    printf 'fastcomplete\thttp://127.0.0.1:%s/fastcomplete.zip\n' "$PORT2" >  "$CANDB"
    printf 'slowcomplete\thttp://127.0.0.1:%s/slow.zip\n'         "$PORT2" >> "$CANDB"
    DESTB="$TMP/dlB"; mkdir -p "$DESTB"
    STATEB="$DESTB/1134710_state.json"
    startB="$(date +%s)"
    SPEED_LIMIT=1 SPEED_TIME=99 MAX_TIME=15 GRACE_SECS=2 CAP_SECS=20 \
      "$SCRIPT" 1134710 "$STATEB" "$DESTB" "$CANDB" >/dev/null 2>&1
    endB="$(date +%s)"; elapB=$((endB - startB))
    apiB="$(grep -oE '"currentApi"[: ]*"[^"]*"' "$STATEB" 2>/dev/null | tail -1 | sed -E 's/.*"currentApi"[: ]*"([^"]*)"/\1/')"
    assert_eq "speed-first: fast-complete wins when it arrives first" "fastcomplete" "$apiB"
    if [[ "$elapB" -le 8 ]]; then promptB="yes"; else promptB="no"; fi
    assert_eq "speed-first: did not await the slow source (${elapB}s)" "yes" "$promptB"

    # Scenario C (no-hang via speed floor): a dead source that accepts the
    # connection then sends nothing must be dropped by curl's speed floor
    # (--speed-limit/--speed-time), NOT by a wall-clock --max-time. The only
    # completer (fast-incomplete) wins; the run is bounded by the speed floor.
    CANDC="$TMP/candsC.txt"
    printf 'deadslow\thttp://127.0.0.1:%s/dead.zip\n'      "$PORT2" >  "$CANDC"
    printf 'fastincomplete\thttp://127.0.0.1:%s/fast.zip\n' "$PORT2" >> "$CANDC"
    DESTC="$TMP/dlC"; mkdir -p "$DESTC"
    STATEC="$DESTC/1134710_state.json"
    startC="$(date +%s)"
    SPEED_LIMIT=1000 SPEED_TIME=3 GRACE_SECS=2 \
      "$SCRIPT" 1134710 "$STATEC" "$DESTC" "$CANDC" >/dev/null 2>&1
    endC="$(date +%s)"; elapC=$((endC - startC))
    finC="$(grep -oE '"status"[: ]*"[a-z]+"' "$STATEC" 2>/dev/null | tail -1 | grep -oE '[a-z]+"$' | tr -d '"')"
    assert_eq "no-hang: dead source does not block completion (extracted)" "extracted" "$finC"
    assert_eq "no-hang: the live (incomplete) source won" \
      "no" "$(has_app_key_lua "$DESTC/extracted_1134710")"
    if [[ "$elapC" -le 15 ]]; then withinC="yes"; else withinC="no"; fi
    assert_eq "no-hang: dropped by speed floor, did not hang (${elapC}s)" "yes" "$withinC"
  else
    echo "skip - could not start slow http server"
  fi
  kill "$SRV2_PID" 2>/dev/null
else
  echo "skip - python3 not available for race integration test"
fi

# --- summary --------------------------------------------------------------
echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
