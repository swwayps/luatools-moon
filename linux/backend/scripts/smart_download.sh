#!/bin/bash
# smart_download.sh — smart source selector + download worker for slsteammoon.
#
# Replaces the fast-download "first available source" auto-select with a
# speed-first, completeness-aware race:
#   - download every candidate source in parallel; a source is dropped only by
#     its own curl guards (a connect timeout, and a speed floor that cancels a
#     stalled/dead host like a 25 KB/s one), never by a shared wall clock;
#   - apply a relative window: once the first COMPLETE source finishes, wait a
#     short grace for an even-more-complete peer, then take everyone done and
#     cancel the rest. While no complete source exists, keep awaiting whoever is
#     still actively downloading — the leading source is never cut for being slow;
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

# Force a dot decimal separator everywhere. Under comma-decimal locales
# (pt_BR, de_DE, ...) awk's printf emits "3,050"; downstream numeric awk
# comparisons then fail (a comma-bearing token isn't a clean number, so awk
# silently falls back to STRING comparison: "3,050" >= "25" tests '3' > '2'
# = true, slamming the race window shut at ~3s regardless of CAP). Pinning
# LC_ALL=C makes date/awk/curl all use dots and compare numerically.
export LC_ALL=C

# --- tunables (env-overridable for tests) ---------------------------------
# The race is cut RELATIVELY, never by a wall clock: a source is only dropped
# when (a) a faster, COMPLETE peer already won (speed-first GRACE), or (b) the
# source itself goes dead / extremely slow (the curl speed floor below). The
# leading source is never cancelled just for taking a while.
: "${GRACE_SECS:=3}"        # speed-first grace once a COMPLETE source exists:
                            # how long to await an even-more-complete peer before
                            # committing the winner and cancelling the rest.
: "${CONNECT_TIMEOUT:=10}"  # curl --connect-timeout: a source that can't even
                            # establish a connection fails fast.
: "${SPEED_LIMIT:=1000}"    # curl --speed-limit (bytes/s): THE limiter. A source
: "${SPEED_TIME:=20}"       # transferring below SPEED_LIMIT for SPEED_TIME
                            # sustained seconds is "dead/extremely slow" -> abort.
                            # A momentary dip recovers (the window is sustained),
                            # so the leading-but-temporarily-slow source survives.
                            # On-demand zip builders (e.g. Ryuu) with high TTFB are
                            # tolerated as long as bytes eventually flow.
: "${MAX_TIME:=600}"        # curl --max-time per source: anti-runaway ceiling
                            # ONLY (a misbehaving host streaming forever). It is
                            # deliberately huge — normal healthy downloads finish
                            # well before it; the speed floor, not this, is what
                            # drops dead sources.

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

# zip_has_app_key <appid> <zipfile>
# Peek inside a downloaded zip (without full extraction) and report whether
# its <appid>.lua carries a real app-depot key: addappid(<appid>, N, "<64hex>")
# with Lua comments stripped. Prints "yes"/"no". This is the mid-race signal
# that a completed candidate is already "complete enough" (has the app/Workshop
# depot key) so the race can stop early instead of waiting out the cap.
zip_has_app_key() {
  local appid="$1" zip="$2"
  [[ -f "$zip" ]] || { echo "no"; return; }
  local entry
  entry="$(unzip -Z1 "$zip" 2>/dev/null | grep -E "(^|/)${appid}\.lua$" | head -1)"
  [[ -n "$entry" ]] || { echo "no"; return; }
  if unzip -p "$zip" "$entry" 2>/dev/null | strip_lua_comments \
       | grep -Eq "addappid\s*\(\s*${appid}\s*,\s*[0-9]+\s*,\s*\"[0-9A-Fa-f]{64}\""; then
    echo "yes"
  else
    echo "no"
  fi
}

# window_decide <satisfied> <running> <elapsed> <since_satisfied>
# Decide whether to keep waiting for more racers ("wait") or close the
# collection window ("stop"). Relative-cut, completeness-aware — NEVER a
# wall-clock cap:
#   - all racers finished/died             -> stop
#   - a complete source already won        -> speed-first: stop GRACE_SECS after it
#                                             (its slower/still-running peers are
#                                              then cancelled — a faster, complete
#                                              source beat them)
#   - otherwise (no complete source yet, a racer still in flight) -> WAIT,
#     no matter how long it takes. A healthy source is never cut by time; only
#     its OWN curl (connect-timeout + speed floor) drops it when it goes dead or
#     extremely slow. This is what lets a slow-but-more-complete source (e.g. a
#     host that builds the zip on the fly, high TTFB) run to completion.
# `elapsed` is accepted for diagnostics/back-compat but no longer caps the wait.
# Honours GRACE_SECS from the environment.
window_decide() {
  local satisfied="$1" running="$2" elapsed="$3" since_sat="$4"
  # Defensive: normalise a comma decimal separator to a dot so the numeric
  # awk comparison below never degrades into string comparison, even if a
  # caller (or a comma-decimal locale) hands us "3,050" instead of "3.050".
  since_sat="${since_sat//,/.}"
  if [[ "${running:-0}" -eq 0 ]]; then echo "stop"; return; fi
  if [[ "${satisfied:-0}" -eq 1 ]]; then
    if awk -v s="$since_sat" -v g="$GRACE_SECS" 'BEGIN{exit !(s>=g)}'; then echo "stop"; return; fi
  fi
  echo "wait"
}

# mono_pct <prev_pct> <raw_pct>
# Progress-bar smoothing: the displayed percentage must never go backwards
# (the bar is a single 0..100 number but several differently-sized sources
# race in parallel, so the raw fraction can drop when the anchor switches),
# and must stay below 100 until the winner is committed (the extract phase
# reports 100). Returns max(prev, min(raw, 99)).
mono_pct() {
  local prev="${1:-0}" raw="${2:-0}"
  [[ "$raw" -gt 99 ]] && raw=99
  [[ "$raw" -lt 0 ]] && raw=0
  if [[ "$raw" -gt "$prev" ]]; then echo "$raw"; else echo "$prev"; fi
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
  appkey)
    zip_has_app_key "$2" "$3"
    exit 0
    ;;
  window)
    window_decide "$2" "$3" "$4" "$5"
    exit 0
    ;;
  mono_pct)
    mono_pct "$2" "$3"
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

# Diagnostics. This worker is launched detached with stdout+stderr appended to
# ~/.lumen.log (see smart_downloads.inc.lua::_launch_smart_download), so these
# lines land in the same log as the rest of the plugin. ISO-8601 UTC prefix
# mirrors logger.lua's format; the appid + pid tie interleaved lines (parallel
# sources, possibly more than one worker) back to their run.
slog() { printf '%s INFO smart_download[%s pid %s]: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APPID" "$$" "$*"; }
slog "worker start: state=$STATE_FILE dest=$DEST_ROOT candidates=$CANDIDATES_FILE"

# Use system libraries, not the Steam Runtime's pinned ones (see downloader.sh).
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

# Single-worker-per-appid lock. The fast-download click can fire more than once
# (the frontend is re-injected on CEF context recreation) and the backend
# dedups, but guard here too: two workers for the same appid would fight over
# the shared appid-keyed handoff paths (the state file, <appid>.zip,
# extracted_<appid>) and corrupt the install -> the spurious "failed"/flapping
# users saw. The lock (fd 9) is held for this worker's whole lifetime; a second
# worker that can't acquire it exits immediately without touching any state.
LOCK="$DEST_ROOT/${APPID}.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  if ! flock -n 9; then
    slog "another worker already holds the lock for appid $APPID -> exiting (no-op)"
    exit 0
  fi
fi

UA="discord(dot)gg/luatools"
# Per-worker (pid-suffixed) scratch dir so concurrent workers — should one ever
# slip past the lock + backend dedup — never share the race scratch. The
# appid-keyed HANDOFF paths (<appid>.zip, extracted_<appid>, the state file)
# stay as-is: get_add_status reads them by appid, and the lock guarantees a
# single writer.
WORK="$DEST_ROOT/race_${APPID}.$$"
rm -rf "$WORK"; mkdir -p "$WORK"
# Always remove the race scratch dir (all candidate downloads, winner and
# losers alike) AND the candidates manifest on any exit — success or failure —
# so unused source zips and the candidates list never linger on the user's
# disk. The winning zip is copied out to DEST_ROOT/<appid>.zip before exit,
# so this is safe.
trap 'rm -rf "$WORK" 2>/dev/null; rm -f "$CANDIDATES_FILE" 2>/dev/null' EXIT

declare -A API_ERR_TYPE
declare -A API_ERR_CODE

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

write_state() {
  # write_state <status> <currentApi> <bytesRead> <totalBytes> [error]
  local status="$1" capi="$2" br="$3" tb="$4" err="${5:-}"
  local errs="{" first=1 k
  for k in "${!API_ERR_TYPE[@]}"; do
    [[ $first -eq 0 ]] && errs+=","
    first=0
    errs+="\"$(json_escape "$k")\":{\"type\":\"${API_ERR_TYPE[$k]}\",\"code\":${API_ERR_CODE[$k]:-0}}"
  done
  errs+="}"
  # "error" carries a human-readable reason on the failure paths so the frontend
  # shows it instead of the opaque "Unknown error"; it is "" for live/ok states.
  printf '{"status":"%s","currentApi":"%s","bytesRead":%s,"totalBytes":%s,"apiErrors":%s,"error":"%s"}\n' \
    "$status" "$(json_escape "$capi")" "$br" "$tb" "$errs" "$(json_escape "$err")" > "$STATE_FILE"
}

now() { date +%s.%N; }

# --- load candidates ------------------------------------------------------
declare -a C_NAME C_URL C_ZIP C_STAT C_HDR C_PID C_TOTAL C_STATE
n=0
while IFS=$'\t' read -r name url; do
  [[ -z "${name:-}" || -z "${url:-}" ]] && continue
  C_NAME[n]="$name"
  C_URL[n]="$url"
  C_ZIP[n]="$WORK/cand_${n}.zip"
  C_STAT[n]="$WORK/cand_${n}.stat"
  C_HDR[n]="$WORK/cand_${n}.hdr"
  C_TOTAL[n]=0
  C_STATE[n]="pending"
  n=$((n + 1))
done < "$CANDIDATES_FILE"

if [[ $n -eq 0 ]]; then
  slog "no candidates parsed from $CANDIDATES_FILE -> failed"
  write_state "failed" "" 0 0 "No sources are configured for this game"
  exit 1
fi
slog "loaded $n candidate source(s): ${C_NAME[*]}"

write_state "downloading" "" 0 0

# --- best-effort HEAD burst for content lengths (for a real progress bar) -
for ((i = 0; i < n; i++)); do
  (
    len="$(curl -sIL -A "$UA" --connect-timeout 3 --max-time 3 "${C_URL[i]}" 2>/dev/null \
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
      -D "${C_HDR[i]}" \
      -o "${C_ZIP[i]}" -w '%{http_code} %{size_download} %{time_total}' \
      "${C_URL[i]}" 2>/dev/null)"
    rc=$?
    echo "$code $rc" > "${C_STAT[i]}"
  ) &
  C_PID[i]=$!
done

# --- poll loop with completeness-aware window -----------------------------
t0="$(now)"
first_satisfied=""   # time the first COMPLETE (app-key) candidate finished
satisfied=0          # 1 once any completed candidate carries the app-key
disp_pct=0           # monotonic progress percentage shown to the frontend
zip_has_lua() { unzip -Z1 "$1" 2>/dev/null | grep -Eq "(^|/)${APPID}\.lua$"; }

# read_total <idx> : best-known total bytes for a racer. Prefer the HEAD
# length; if missing (some hosts don't answer HEAD), parse Content-Length from
# the live GET response headers dumped by curl -D.
read_total() {
  local i="$1" t="${C_TOTAL[$1]}"
  if [[ "${t:-0}" -le 0 && -f "${C_HDR[i]}" ]]; then
    t="$(tr -d '\r' < "${C_HDR[i]}" | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v+0}')"
    [[ "${t:-0}" -gt 0 ]] && C_TOTAL[i]="$t"
  fi
  echo "${C_TOTAL[$1]:-0}"
}

while :; do
  running=0

  for ((i = 0; i < n; i++)); do
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
      # A completed candidate that already carries the app/Workshop depot key
      # makes the window "satisfied": from here, speed-first grace applies. A
      # completed candidate WITHOUT the key does NOT satisfy the window, so the
      # race keeps waiting for a slower source that might have
      # it — this is what stops a fast-but-incomplete source winning by default.
      if [[ "$(zip_has_app_key "$APPID" "${C_ZIP[i]}")" == "yes" ]]; then
        satisfied=1
        [[ -z "$first_satisfied" ]] && first_satisfied="$(now)"
        slog "source '${C_NAME[i]}' ok + has app key (http=${http:-?})"
      else
        slog "source '${C_NAME[i]}' ok but no app key (http=${http:-?})"
      fi
    else
      C_STATE[i]="failed"
      if [[ "${rc:-1}" == "28" ]]; then
        API_ERR_TYPE["${C_NAME[i]}"]="timeout"; API_ERR_CODE["${C_NAME[i]}"]=0
        slog "source '${C_NAME[i]}' failed: timeout (rc=28)"
      else
        API_ERR_TYPE["${C_NAME[i]}"]="error"; API_ERR_CODE["${C_NAME[i]}"]="${http:-0}"
        slog "source '${C_NAME[i]}' failed (http=${http:-0} rc=${rc:-?})"
      fi
    fi
  done

  # progress: anchor the bar to the racer with the LARGEST known total — the
  # most representative of the real install (the biggest archive is usually
  # the most complete one we end up picking). totalBytes is learned from HEAD
  # or, for hosts that don't answer HEAD, from the live GET response headers.
  # mono_pct keeps the displayed percentage monotonic and < 100, so a small
  # source finishing first can't slam the bar to 100% and a later anchor
  # switch can't make it jump backwards. currentApi stays EMPTY during the
  # race; only the winner is named at the extract phase below.
  anchor_idx=-1; anchor_total=0
  for ((i = 0; i < n; i++)); do
    [[ "${C_STATE[i]}" == "failed" || "${C_STATE[i]}" == "cancelled" ]] && continue
    it="$(read_total "$i")"
    if [[ "${it:-0}" -gt "$anchor_total" ]]; then anchor_total="$it"; anchor_idx=$i; fi
  done
  raw_pct=0
  if [[ "$anchor_idx" -ge 0 && "$anchor_total" -gt 0 ]]; then
    ab="$(stat -c %s "${C_ZIP[anchor_idx]}" 2>/dev/null || echo 0)"
    raw_pct=$(( ab * 100 / anchor_total ))
  fi
  disp_pct="$(mono_pct "$disp_pct" "$raw_pct")"
  tb="$anchor_total"
  br=$(( disp_pct * tb / 100 ))
  write_state "downloading" "" "$br" "$tb"

  # window: completeness-aware decision (see window_decide). Stop when all
  # racers are done, or — once a COMPLETE source exists — GRACE_SECS after it.
  # Keep waiting while no complete source has arrived yet and a racer is still
  # in flight; the still-running racer is never cut here by elapsed time, only
  # by its own curl speed floor (which marks it failed -> running drops).
  t="$(now)"
  elapsed="$(awk -v a="$t0" -v b="$t" 'BEGIN{printf "%.3f", b-a}')"
  since_sat="-1"
  [[ -n "$first_satisfied" ]] && since_sat="$(awk -v a="$first_satisfied" -v b="$t" 'BEGIN{printf "%.3f", b-a}')"
  [[ "$(window_decide "$satisfied" "$running" "$elapsed" "$since_sat")" == "stop" ]] && break
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
  errkeys="${!API_ERR_TYPE[*]}"; [[ -z "$errkeys" ]] && errkeys="none"
  slog "no source completed successfully -> failed (errored sources: $errkeys)"
  write_state "failed" "" 0 0 "All $n source(s) failed — no usable package was downloaded"
  exit 1
fi
slog "completed=$completed -> selecting winner"

winner="$(select_winner "$APPID" "$SEL")"
if [[ -z "$winner" ]]; then
  slog "select_winner returned empty -> failed"
  write_state "failed" "" 0 0 "Could not select a source from the downloaded packages"
  exit 1
fi
slog "winner='$winner'"

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
  slog "extract of winner '$winner' failed -> failed"
  write_state "failed" "$winner" 0 0 "Failed to extract the downloaded package"
  exit 1
fi

write_state "extracted" "$winner" "$win_size" "$win_size"
slog "winner '$winner' extracted -> handing off to finalize (extracted)"
rm -rf "$WORK" 2>/dev/null
exit 0
