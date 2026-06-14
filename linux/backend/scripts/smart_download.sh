#!/bin/bash
# smart_download.sh — smart source selector + download worker for slsteammoon.
#
# Replaces the fast-download "first available source" auto-select with a
# speed-first, completeness-aware race:
#   - download every candidate source in parallel (bounded by a connect
#     timeout, a max time, and a speed floor that cancels a stalled/slow
#     source like a 25 KB/s host);
#   - apply a hybrid window: once the first source completes, wait a short
#     grace, capped by an absolute deadline, then take everyone who finished;
#   - score each finished candidate for completeness (presence of the
#     app-depot key that enables Workshop, then total depot keys, then
#     bundled manifests) and pick the most complete, tie-broken by speed;
#   - report real progress + per-source errors through the <appid>_state.json
#     contract the frontend already polls.
#
# The pure logic is exposed as subcommands so it can be unit-tested without
# the network (see scripts/test-smart-download.sh):
#   smart_download.sh score  <appid> <candidate_dir>  -> "<app_key> <key_count> <manifest_count>"
#   smart_download.sh select <appid> <work_dir>       -> winning candidate name
#
# Full worker (network):
#   smart_download.sh <appid> <state_file> <dest_root> <candidates_file>

set -uo pipefail

# --- tunables (env-overridable for tests) ---------------------------------
: "${GRACE_SECS:=3}"        # after first completion, wait this long for better ones
: "${CAP_SECS:=8}"          # absolute deadline from t0 to stop collecting
: "${CONNECT_TIMEOUT:=8}"   # curl --connect-timeout
: "${MAX_TIME:=25}"         # curl --max-time per source
: "${SPEED_LIMIT:=20000}"   # curl --speed-limit (bytes/s) ...
: "${SPEED_TIME:=5}"        # ... sustained below for this many seconds -> abort

# ==========================================================================
# Pure logic
# ==========================================================================

# strip_lua_comments < file : echo the lua with `-- ...` comments removed
strip_lua_comments() {
  sed 's/--.*$//'
}

# score_candidate <appid> <candidate_dir>
# Prints "<app_key> <key_count> <manifest_count>".
#   app_key       = 1 if an addappid(<appid>, N, "<64hex>") line exists, else 0
#   key_count     = number of addappid(d, N, "<64hex>") lines (real depot keys)
#   manifest_count= number of *.manifest files in the directory
score_candidate() {
  local appid="$1" dir="$2"
  local lua
  lua="$(find "$dir" -maxdepth 1 -name '*.lua' -print -quit 2>/dev/null)"

  local app_key=0 key_count=0 manifest_count=0
  if [[ -n "$lua" && -f "$lua" ]]; then
    local stripped
    stripped="$(strip_lua_comments < "$lua")"
    if grep -Eq "addappid\s*\(\s*${appid}\s*,\s*[0-9]+\s*,\s*\"[0-9A-Fa-f]{64}\"" <<<"$stripped"; then
      app_key=1
    fi
    key_count="$(grep -Ec "addappid\s*\(\s*[0-9]+\s*,\s*[0-9]+\s*,\s*\"[0-9A-Fa-f]{64}\"" <<<"$stripped")"
    [[ -z "$key_count" ]] && key_count=0
  fi
  manifest_count="$(find "$dir" -maxdepth 1 -name '*.manifest' -type f 2>/dev/null | wc -l | tr -d ' ')"

  echo "$app_key $key_count $manifest_count"
}

# select_winner <appid> <work_dir>
# work_dir holds, per candidate, a subdir <name>/ with extracted files and a
# sibling <name>.time file with the download time (seconds). Prints the name
# of the most complete candidate (score tuple), tie-broken by smallest time.
select_winner() {
  local appid="$1" wd="$2"
  local best_name="" best_ak=-1 best_kc=-1 best_mc=-1 best_t=""
  local dir
  for dir in "$wd"/*/; do
    [[ -d "$dir" ]] || continue
    local name ak kc mc t
    name="$(basename "$dir")"
    read -r ak kc mc <<<"$(score_candidate "$appid" "$dir")"
    t=999999
    [[ -f "$wd/$name.time" ]] && t="$(cat "$wd/$name.time")"

    local verdict
    verdict="$(awk -v ak="$ak" -v kc="$kc" -v mc="$mc" -v t="$t" \
                   -v bak="$best_ak" -v bkc="$best_kc" -v bmc="$best_mc" -v bt="$best_t" 'BEGIN{
      if (bak < 0)   { print "yes"; exit }
      if (ak != bak) { print (ak > bak) ? "yes" : "no"; exit }
      if (kc != bkc) { print (kc > bkc) ? "yes" : "no"; exit }
      if (mc != bmc) { print (mc > bmc) ? "yes" : "no"; exit }
      print (t < bt) ? "yes" : "no"
    }')"

    if [[ "$verdict" == "yes" ]]; then
      best_name="$name"; best_ak="$ak"; best_kc="$kc"; best_mc="$mc"; best_t="$t"
    fi
  done
  echo "$best_name"
}

# ==========================================================================
# Subcommand dispatch
# ==========================================================================
case "${1:-}" in
  score)
    score_candidate "$2" "$3"
    exit 0
    ;;
  select)
    select_winner "$2" "$3"
    exit 0
    ;;
esac

# ==========================================================================
# Full worker (network): race -> window -> score -> select -> install
#   smart_download.sh <appid> <state_file> <dest_root> <candidates_file>
# ==========================================================================

APPID="${1:?appid required}"
STATE_FILE="${2:?state_file required}"
DEST_ROOT="${3:?dest_root required}"
CANDIDATES_FILE="${4:?candidates_file required}"

# Use system libraries, not the Steam Runtime's pinned ones (see downloader.sh).
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

UA="discord(dot)gg/luatools"
WORK="$DEST_ROOT/race_${APPID}"
rm -rf "$WORK"; mkdir -p "$WORK"
# Always remove the race scratch dir (all candidate downloads, winner and
# losers alike) on any exit — success or failure — so unused source zips
# never linger on the user's disk. The winning zip is copied out to
# DEST_ROOT/<appid>.zip before exit, so this is safe.
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

declare -A API_ERR_TYPE
declare -A API_ERR_CODE

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

write_state() {
  # write_state <status> <currentApi> <bytesRead> <totalBytes>
  local status="$1" capi="$2" br="$3" tb="$4"
  local errs="{" first=1 k
  for k in "${!API_ERR_TYPE[@]}"; do
    [[ $first -eq 0 ]] && errs+=","
    first=0
    errs+="\"$(json_escape "$k")\":{\"type\":\"${API_ERR_TYPE[$k]}\",\"code\":${API_ERR_CODE[$k]:-0}}"
  done
  errs+="}"
  printf '{"status":"%s","currentApi":"%s","bytesRead":%s,"totalBytes":%s,"apiErrors":%s}\n' \
    "$status" "$(json_escape "$capi")" "$br" "$tb" "$errs" > "$STATE_FILE"
}

now() { date +%s.%N; }
elapsed_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# --- load candidates ------------------------------------------------------
declare -a C_NAME C_URL C_ZIP C_STAT C_PID C_TOTAL C_STATE
n=0
while IFS=$'\t' read -r name url; do
  [[ -z "${name:-}" || -z "${url:-}" ]] && continue
  C_NAME[n]="$name"
  C_URL[n]="$url"
  C_ZIP[n]="$WORK/cand_${n}.zip"
  C_STAT[n]="$WORK/cand_${n}.stat"
  C_TOTAL[n]=0
  C_STATE[n]="pending"
  n=$((n + 1))
done < "$CANDIDATES_FILE"

if [[ $n -eq 0 ]]; then
  write_state "failed" "" 0 0
  exit 1
fi

write_state "downloading" "" 0 0

# --- best-effort HEAD burst for content lengths (for a real progress bar) -
for ((i = 0; i < n; i++)); do
  (
    len="$(curl -sIL -A "$UA" --connect-timeout 5 --max-time 6 "${C_URL[i]}" 2>/dev/null \
           | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v+0}')"
    echo "${len:-0}" > "$WORK/cand_${i}.len"
  ) &
done
wait
RACE_TOTAL=0
for ((i = 0; i < n; i++)); do
  if [[ -f "$WORK/cand_${i}.len" ]]; then
    C_TOTAL[i]="$(cat "$WORK/cand_${i}.len")"
    RACE_TOTAL=$((RACE_TOTAL + C_TOTAL[i]))
  fi
done

# --- launch the parallel GET race -----------------------------------------
for ((i = 0; i < n; i++)); do
  (
    code="$(curl -sL -A "$UA" \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      --speed-limit "$SPEED_LIMIT" --speed-time "$SPEED_TIME" \
      -o "${C_ZIP[i]}" -w '%{http_code} %{size_download} %{time_total}' \
      "${C_URL[i]}" 2>/dev/null)"
    rc=$?
    echo "$code $rc" > "${C_STAT[i]}"
  ) &
  C_PID[i]=$!
done

# --- poll loop with hybrid window -----------------------------------------
t0="$(now)"
first_done=""
zip_has_lua() { unzip -Z1 "$1" 2>/dev/null | grep -Eq "(^|/)${APPID}\.lua$"; }

while :; do
  running=0
  leader_name=""
  leader_bytes=-1
  leader_idx=-1

  for ((i = 0; i < n; i++)); do
    # track the leading (furthest-along) transfer for a single-file style bar
    if [[ -f "${C_ZIP[i]}" ]]; then
      sz="$(stat -c %s "${C_ZIP[i]}" 2>/dev/null || echo 0)"
      if [[ $sz -gt $leader_bytes ]]; then leader_bytes=$sz; leader_name="${C_NAME[i]}"; leader_idx=$i; fi
    fi

    [[ "${C_STATE[i]}" != "pending" ]] && continue
    if kill -0 "${C_PID[i]}" 2>/dev/null; then
      running=$((running + 1))
      continue
    fi
    # this candidate's curl finished — classify it
    local_line="$(cat "${C_STAT[i]}" 2>/dev/null)"
    http="$(awk '{print $1}' <<<"$local_line")"
    rc="$(awk '{print $4}' <<<"$local_line")"
    if [[ "${rc:-1}" == "0" && "${http:-0}" == "200" ]] && zip_has_lua "${C_ZIP[i]}"; then
      C_STATE[i]="ok"
      [[ -z "$first_done" ]] && first_done="$(now)"
    else
      C_STATE[i]="failed"
      if [[ "${rc:-1}" == "28" ]]; then
        API_ERR_TYPE["${C_NAME[i]}"]="timeout"; API_ERR_CODE["${C_NAME[i]}"]=0
      else
        API_ERR_TYPE["${C_NAME[i]}"]="error"; API_ERR_CODE["${C_NAME[i]}"]="${http:-0}"
      fi
    fi
  done

  # progress: report the leading transfer (a single source, 0..100%) rather
  # than the sum across all racers (which never nears 100% since losers are
  # cancelled mid-download). totalBytes from that source's HEAD length.
  # currentApi is left EMPTY during the race: the frontend locks the first
  # named source it sees as "Found", and the leader is often NOT the winner
  # (a fast but incomplete source can lead on bytes). Only the winner is
  # named, at the extracting/extracted phase below.
  br="$leader_bytes"; [[ "$br" -lt 0 ]] && br=0
  lead_total=0
  [[ "$leader_idx" -ge 0 ]] && lead_total="${C_TOTAL[leader_idx]}"
  tb="$lead_total"
  [[ "$tb" -le 0 ]] && tb="$br"
  [[ "$br" -gt "$tb" && "$tb" -gt 0 ]] && br="$tb"
  write_state "downloading" "" "$br" "$tb"

  # window: stop once grace after first completion, or absolute cap, elapsed
  t="$(now)"
  if [[ -n "$first_done" ]]; then
    grace_deadline="$(awk -v a="$first_done" -v g="$GRACE_SECS" 'BEGIN{printf "%.6f", a+g}')"
    elapsed_ge "$t" "$grace_deadline" && break
  fi
  cap_deadline="$(awk -v a="$t0" -v c="$CAP_SECS" 'BEGIN{printf "%.6f", a+c}')"
  elapsed_ge "$t" "$cap_deadline" && break
  [[ $running -eq 0 ]] && break
  sleep 0.2
done

# --- kill stragglers ------------------------------------------------------
for ((i = 0; i < n; i++)); do
  if [[ "${C_STATE[i]}" == "pending" ]]; then
    kill "${C_PID[i]}" 2>/dev/null
    C_STATE[i]="cancelled"
  fi
done

# --- build selection dir from successfully completed candidates -----------
SEL="$WORK/sel"
mkdir -p "$SEL"
completed=0
for ((i = 0; i < n; i++)); do
  [[ "${C_STATE[i]}" == "ok" ]] || continue
  d="$SEL/${C_NAME[i]}"
  mkdir -p "$d"
  unzip -o -q "${C_ZIP[i]}" -d "$d" 2>/dev/null || continue
  ttime="$(awk '{print $3}' "${C_STAT[i]}" 2>/dev/null)"
  echo "${ttime:-999999}" > "$SEL/${C_NAME[i]}.time"
  completed=$((completed + 1))
done

if [[ $completed -eq 0 ]]; then
  write_state "failed" "" 0 0
  exit 1
fi

winner="$(select_winner "$APPID" "$SEL")"
if [[ -z "$winner" ]]; then
  write_state "failed" "" 0 0
  exit 1
fi

# --- install the winner: place zip + extracted dir for _finalize_install_lua
DEST_ZIP="$DEST_ROOT/${APPID}.zip"
EXTRACT_DIR="$DEST_ROOT/extracted_${APPID}"
win_zip=""
for ((i = 0; i < n; i++)); do
  if [[ "${C_NAME[i]}" == "$winner" ]]; then win_zip="${C_ZIP[i]}"; break; fi
done

win_size="$(stat -c %s "$win_zip" 2>/dev/null || echo 1)"
[[ "${win_size:-0}" -le 0 ]] && win_size=1
# Surface the winner in a visible (non-"done") state, briefly, so the frontend
# (300ms poll, and it hides the source list on "done") can mark the winning
# source as "Found" before the success modal. Held just over 1 poll interval.
write_state "downloading" "$winner" "$win_size" "$win_size"
sleep 0.5
write_state "extracting" "$winner" "$win_size" "$win_size"
cp -f "$win_zip" "$DEST_ZIP" 2>/dev/null
rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"
if ! unzip -o -q "$DEST_ZIP" -d "$EXTRACT_DIR" 2>/dev/null; then
  write_state "failed" "$winner" 0 0
  exit 1
fi

write_state "extracted" "$winner" "$win_size" "$win_size"
rm -rf "$WORK" 2>/dev/null
exit 0
