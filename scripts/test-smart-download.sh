#!/usr/bin/env bash
# test-smart-download.sh — unit tests for the smart source selector.
#
# Tests the PURE logic (no network) of linux/backend/scripts/smart_download.sh
# via its subcommands:
#   smart_download.sh score  <appid> <candidate_dir>   -> "<app_key> <key_count> <manifest_count>"
#   smart_download.sh select <appid> <work_dir>        -> winning candidate name
#
# Run: scripts/test-smart-download.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/linux/backend/scripts/smart_download.sh"

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

# Morrenus: app-depot key present, 4 depot keys, 3 manifests
make_candidate morrenus 3 <<'LUA'
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

# SkyAPI: NO app-depot key, 2 depot keys, 0 manifests
make_candidate skyapi 0 <<'LUA'
addappid(1134710)
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA

# --- scoring tests --------------------------------------------------------
assert_eq "morrenus score (app_key=1, 4 keys, 3 manifests)" \
  "1 4 3" "$("$SCRIPT" score 1134710 "$TMP/morrenus")"

assert_eq "ryuu score (app_key=1, 3 keys, 2 manifests)" \
  "1 3 2" "$("$SCRIPT" score 1134710 "$TMP/ryuu")"

assert_eq "sushi score (app_key=0, 2 keys, 2 manifests; comment ignored)" \
  "0 2 2" "$("$SCRIPT" score 1134710 "$TMP/sushi")"

assert_eq "skyapi score (app_key=0, 2 keys, 0 manifests)" \
  "0 2 0" "$("$SCRIPT" score 1134710 "$TMP/skyapi")"

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

# Case 1: full NIMBY set -> twentytwo wins (ties morrenus on (1,4,3), faster).
WD1="$TMP/sel_full"; mkdir -p "$WD1"
make_sel_candidate "$WD1" morrenus 3 2.0 <<'LUA'
addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
addappid(228989, 1, "ad69276eb476cf06c40312df7376d63deac0c838b9a2767005be8bb306ffb853")
LUA
make_sel_candidate "$WD1" twentytwo 3 1.0 <<'LUA'
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
make_sel_candidate "$WD1" skyapi 0 0.3 <<'LUA'
addappid(1134710)
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
assert_eq "select full NIMBY set -> twentytwo (complete + fastest of the complete)" \
  "twentytwo" "$("$SCRIPT" select 1134710 "$WD1")"

# Case 2: only incomplete sources -> sushi (more manifests) beats skyapi.
WD2="$TMP/sel_incomplete"; mkdir -p "$WD2"
make_sel_candidate "$WD2" sushi 2 0.5 <<'LUA'
addappid(1134710)
addappid(1134711, 1, "e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712, 1, "6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
make_sel_candidate "$WD2" skyapi 0 0.3 <<'LUA'
addappid(1134710)
addappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")
addappid(1134712,0,"6aca6ce3dd1188b29e3251d88aeef183ffd6bfe5f89260be29c375811ba92903")
LUA
assert_eq "select incomplete-only -> sushi (more manifests than skyapi)" \
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

  # --- slow-source cancellation: a slow (more complete) source must not
  #     hang the race; a fast valid source wins and the slow one is flagged.
  SRV2="$TMP/srv2"; mkdir -p "$SRV2"
  # fast.zip: valid, incomplete, tiny. slow.zip: complete but padded big.
  rm -rf "$TMP/zf" "$TMP/zs"; mkdir -p "$TMP/zf" "$TMP/zs"
  printf 'addappid(1134710)\naddappid(1134711,0,"e4c5307d44d1e6057d21c3828bc766b625266bc61281e682b3ace83b0612f7d0")\n' > "$TMP/zf/1134710.lua"
  ( cd "$TMP/zf" && zip -qr "$SRV2/fast.zip" . )
  printf 'addappid(1134710, 1, "1dae66a4c21dcad9351a9ec70d59e36fd9055197ee7f7806e157156af1c505aa")\n' > "$TMP/zs/1134710.lua"
  head -c 40000 /dev/zero | tr '\0' 'x' > "$TMP/zs/big.manifest"
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
        self._hdr(self.path.lstrip("/"))
    def do_GET(self):
        name = self.path.lstrip("/")
        n = self._hdr(name)
        if n is None: return
        data = open(os.path.join(DIR, name), "rb").read()
        if name == "slow.zip":
            for i in range(0, len(data), 512):
                try: self.wfile.write(data[i:i+512]); self.wfile.flush()
                except Exception: return
                time.sleep(0.5)
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

  if [[ -n "$PORT2" ]]; then
    CAND2="$TMP/cands2.txt"
    printf 'slow\thttp://127.0.0.1:%s/slow.zip\n' "$PORT2" >  "$CAND2"
    printf 'fast\thttp://127.0.0.1:%s/fast.zip\n' "$PORT2" >> "$CAND2"
    DEST2="$TMP/dl2"; mkdir -p "$DEST2"
    STATE2="$DEST2/1134710_state.json"
    start_s="$(date +%s)"
    SPEED_LIMIT=100000 SPEED_TIME=1 MAX_TIME=4 GRACE_SECS=1 CAP_SECS=5 \
      "$SCRIPT" 1134710 "$STATE2" "$DEST2" "$CAND2" >/dev/null 2>&1
    end_s="$(date +%s)"
    elapsed=$((end_s - start_s))

    final2="$(grep -oE '"status"[: ]*"[a-z]+"' "$STATE2" 2>/dev/null | tail -1 | grep -oE '[a-z]+"$' | tr -d '"')"
    assert_eq "slow-source: race still completes (extracted)" "extracted" "$final2"

    win_lua="$(find "$DEST2/extracted_1134710" -name '1134710.lua' -print -quit 2>/dev/null)"
    # fast.zip is the incomplete one -> winner has NO app-depot key (slow was cancelled)
    if [[ -n "$win_lua" ]] && ! grep -Eq 'addappid\s*\(\s*1134710\s*,\s*[0-9]+\s*,\s*"[0-9A-Fa-f]{64}"' "$win_lua"; then
      fast_won="yes"; else fast_won="no"; fi
    assert_eq "slow-source: fast source won (slow one cancelled, not awaited)" "yes" "$fast_won"

    if [[ "$elapsed" -le 5 ]]; then within="yes"; else within="no"; fi
    assert_eq "slow-source: did not hang (finished within cap, ${elapsed}s)" "yes" "$within"
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
