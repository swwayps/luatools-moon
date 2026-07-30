#!/usr/bin/env bash
# Bounded parallel collector for LuaTools game-data APIs.
set -uo pipefail
export LC_ALL=C
umask 077

: "${COLLECTION_DEADLINE:=8}"
: "${COVERAGE_GRACE:=0.3}"
: "${CONNECT_TIMEOUT:=20}"
: "${SPEED_LIMIT:=1}"
: "${SPEED_TIME:=120}"
: "${ACTIVE_PROGRESS_WINDOW:=30}"
: "${MAX_TRANSFER_TIME:=600}"
: "${MAX_ARCHIVE_ENTRIES:=10000}"
: "${MAX_EXPANDED_BYTES:=1073741824}"

mono_pct() {
  local prev="${1:-0}" raw="${2:-0}"
  [[ "$raw" -gt 99 ]] && raw=99
  [[ "$raw" -lt 0 ]] && raw=0
  if [[ "$raw" -gt "$prev" ]]; then echo "$raw"; else echo "$prev"; fi
}
if [[ "${1:-}" == "mono_pct" ]]; then mono_pct "$2" "$3"; exit 0; fi

APPID="${1:?appid required}"
STATE_FILE="${2:?state_file required}"
DEST_ROOT="${3:?dest_root required}"
CANDIDATES_FILE="${4:?candidates_file required}"
COVERAGE_FILE="${5:-}"
STOP_FILE="${6:-}"
WORK="$DEST_ROOT/collect_${APPID}.$$"
EXTRACT_DIR="$DEST_ROOT/extracted_${APPID}"
LOCK="$DEST_ROOT/${APPID}.lock"

slog() { printf '%s INFO smart_download[%s pid %s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APPID" "$$" "$*"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'; }
write_state() {
  local status="$1" current="$2" bytes="$3" total="$4" error="${5:-}"
  local error_code="${6:-}" error_phase="${7:-}" tmp="${STATE_FILE}.tmp.$$"
  printf '{"status":"%s","currentApi":"%s","bytesRead":%s,"totalBytes":%s,"apiErrors":{},"error":"%s","errorCode":"%s","errorPhase":"%s"}\n' \
    "$status" "$(json_escape "$current")" "$bytes" "$total" \
    "$(json_escape "$error")" "$(json_escape "$error_code")" \
    "$(json_escape "$error_phase")" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}
now_ms() { date +%s%3N; }
mkdir -p "$DEST_ROOT"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  if ! flock -n 9; then slog "worker already active"; exit 0; fi
fi
mkdir -p "$WORK"
rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"
trap 'rm -rf "$WORK" 2>/dev/null; rm -f "$CANDIDATES_FILE" "$COVERAGE_FILE" 2>/dev/null' EXIT
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

# NUL records: source-index, display-name, URL, accepted HTTP status.
declare -a C_INDEX C_NAME C_URL C_CODE C_ZIP C_HEAD C_PIPE C_TOTAL_FILE C_TOTAL C_PID C_PARSE_PID C_STATE C_REASON
n=0
exec 3< "$CANDIDATES_FILE"
while IFS= read -r -d '' idx <&3; do
  IFS= read -r -d '' name <&3 || break
  IFS= read -r -d '' url <&3 || break
  IFS= read -r -d '' code <&3 || break
  [[ "$idx" =~ ^[0-9]+$ && "$code" =~ ^[0-9]+$ && -n "$url" ]] || continue
  C_INDEX[n]="$idx"; C_NAME[n]="$name"; C_URL[n]="$url"; C_CODE[n]="$code"
  C_ZIP[n]="$WORK/source_${n}.zip"; C_HEAD[n]="$WORK/source_${n}.headers"
  C_PIPE[n]="$WORK/source_${n}.stream"; C_TOTAL_FILE[n]="$WORK/source_${n}.total"
  C_TOTAL[n]=""; C_STATE[n]="pending"; C_REASON[n]=""
  n=$((n + 1))
done
exec 3<&-
if [[ "$n" -eq 0 ]]; then write_state failed "" 0 0 "No usable API sources"; exit 1; fi

declare -A EXPECTED BASE_DEPOTS
expected_count=0; base_depot_count=0
if [[ -n "$COVERAGE_FILE" && -f "$COVERAGE_FILE" ]]; then
  while IFS=$'\t' read -r depot gid kind relevant; do
    [[ "$depot" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || continue
    if [[ -z "${EXPECTED["${depot}_${gid}.manifest"]+set}" ]]; then
      EXPECTED["${depot}_${gid}.manifest"]=1
      expected_count=$((expected_count + 1))
    fi
    if [[ "$kind" == "base" && "$relevant" == "1" \
        && -z "${BASE_DEPOTS[$depot]+set}" ]]; then
      BASE_DEPOTS[$depot]=1
      base_depot_count=$((base_depot_count + 1))
    fi
  done < "$COVERAGE_FILE"
fi

zip_is_safe_and_usable() {
  local zip="$1" entries count expanded
  entries="$(unzip -Z1 "$zip" 2>/dev/null)" || return 1
  [[ -n "$entries" ]] || return 1
  if grep -Eq '(^/|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$)|\\)' <<<"$entries"; then return 1; fi
  if grep -Eq '(^|/)\.source-(name|index|priority)$' <<<"$entries"; then return 1; fi
  if unzip -Z -l "$zip" 2>/dev/null | grep -Eq '^[lhbcps]'; then return 1; fi
  count="$(printf '%s\n' "$entries" | wc -l)"
  [[ "$count" -le "$MAX_ARCHIVE_ENTRIES" ]] || return 1
  expanded="$(unzip -Z -t "$zip" 2>/dev/null \
    | awk '/bytes uncompressed/ { for (i=1;i<=NF;i++) if ($i=="bytes") {print $(i-1); exit} }')"
  [[ "$expanded" =~ ^[0-9]+$ && "$expanded" -le "$MAX_EXPANDED_BYTES" ]] || return 1
  count="$(grep -Ec "(^|/)${APPID}\\.lua$" <<<"$entries")"
  [[ "$count" -eq 1 ]]
}

manifest_has_payload_magic() {
  local signature
  signature="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  [[ "$signature" == "d017f671" ]]
}

coverage_complete() {
  [[ "$expected_count" -gt 0 ]] || return 1
  shopt -s nullglob globstar
  local file candidate matches found
  for file in "${!EXPECTED[@]}"; do
    matches=("$EXTRACT_DIR"/source_*/**/"$file")
    found=0
    for candidate in "${matches[@]}"; do
      if manifest_has_payload_magic "$candidate"; then
        found=1
        break
      fi
    done
    [[ "$found" -eq 1 ]] || return 1
  done
  return 0
}

extract_source() {
  local i="$1" dir unsafe
  printf -v dir '%s/source_%04d' "$EXTRACT_DIR" "${C_INDEX[i]}"
  rm -rf "$dir"; mkdir -p "$dir"
  unzip -q "${C_ZIP[i]}" -d "$dir" || { rm -rf "$dir"; return 1; }
  unsafe="$(find "$dir" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit 2>/dev/null)"
  [[ -z "$unsafe" ]] || { rm -rf "$dir"; return 1; }
  printf '%s' "${C_NAME[i]}" > "$dir/.source-name"
  printf '%s\n' "${C_INDEX[i]}" > "$dir/.source-index"
  printf '%s\n' "${C_INDEX[i]}" > "$dir/.source-priority"
}

aggregate_is_usable() {
  shopt -s nullglob globstar
  local files=("$EXTRACT_DIR"/source_*/**/"${APPID}.lua") file cleaned depot
  [[ "${#files[@]}" -gt 0 ]] || return 1
  local has_app=0 has_key=0
  for file in "${files[@]}"; do
    cleaned="$(sed 's/--.*$//' "$file" 2>/dev/null)"
    if grep -Eq "^[[:space:]]*addappid[[:space:]]*\\([[:space:]]*${APPID}([[:space:]]*\\)|[[:space:]]*,)" \
        <<<"$cleaned"; then
      has_app=1
    fi
    if [[ "$base_depot_count" -gt 0 ]]; then
      for depot in "${!BASE_DEPOTS[@]}"; do
        if grep -Eq "^[[:space:]]*addappid[[:space:]]*\\([[:space:]]*${depot}[[:space:]]*,[[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*['\"][0-9A-Fa-f]{64}['\"]" \
            <<<"$cleaned"; then
          has_key=1
          break
        fi
      done
    elif grep -Eq "^[[:space:]]*addappid[[:space:]]*\\([[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*['\"][0-9A-Fa-f]{64}['\"]" \
        <<<"$cleaned"; then
      has_key=1
    fi
  done
  [[ "$has_app" -eq 1 && "$has_key" -eq 1 ]]
}

capture_curl_headers() {
  local header_file="$1" total_file="$2"
  local line clean plain status=0 content_length="" total_tmp="${total_file}.tmp"
  : > "$header_file"
  rm -f "$total_file" "$total_tmp"
  while IFS= read -r line; do
    clean="${line%$'\r'}"
    if [[ "$clean" =~ ^\<\ HTTP/[0-9.]+[[:space:]]+([0-9]+) ]]; then
      status="${BASH_REMATCH[1]}"
      content_length=""
      plain="${clean#< }"
      printf '%s\n' "$plain" >> "$header_file"
    elif [[ "${clean,,}" =~ ^\<\ content-length:[[:space:]]*([0-9]+)$ ]]; then
      content_length="${BASH_REMATCH[1]}"
      plain="${clean#< }"
      printf '%s\n' "$plain" >> "$header_file"
    elif [[ "$clean" == "< " && "$status" -ge 200 \
        && ( "$status" -lt 300 || "$status" -ge 400 ) ]]; then
      if [[ "$content_length" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$content_length" > "$total_tmp"
        mv -f "$total_tmp" "$total_file"
      fi
    fi
  done
}

write_state downloading "" 0 0
for ((i=0; i<n; i++)); do
  mkfifo "${C_PIPE[i]}"
  capture_curl_headers "${C_HEAD[i]}" "${C_TOTAL_FILE[i]}" < "${C_PIPE[i]}" &
  C_PARSE_PID[i]=$!
  # The verbose stream carries only metadata through the FIFO; the response
  # body is written directly to the ZIP and this remains the source's only GET.
  # COLLECTION_DEADLINE is only a fast-path cutoff after another source has
  # succeeded. Before that, curl owns the generous connection/inactivity guards
  # so slow links and delayed archive generation cannot become false failures.
  stdbuf -e0 curl -sSLv -A 'discord(dot)gg/luatools' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TRANSFER_TIME" \
    --speed-limit "$SPEED_LIMIT" --speed-time "$SPEED_TIME" \
    -o "${C_ZIP[i]}" "${C_URL[i]}" > /dev/null 2> "${C_PIPE[i]}" &
  C_PID[i]=$!
done

start_ms="$(now_ms)"
quiet_ms="$(awk -v d="$COLLECTION_DEADLINE" 'BEGIN{printf "%.0f", d*1000}')"
grace_ms="$(awk -v g="$COVERAGE_GRACE" 'BEGIN{printf "%.0f", g*1000}')"
active_window_ms="$(awk -v s="$ACTIVE_PROGRESS_WINDOW" 'BEGIN{printf "%.0f", s*1000}')"
coverage_at=""; usable_at=""; completed=0; progress_bytes=0; extension_logged=0; cancelled=0
for ((i=0; i<n; i++)); do
  C_SIZE[i]=0
  C_LAST_PROGRESS[i]="$start_ms"
done
while :; do
  if [[ -n "$STOP_FILE" && -f "$STOP_FILE" ]]; then
    slog "cancellation requested"
    cancelled=1
    break
  fi
  running=0; bytes=0; poll_ms="$(now_ms)"
  for ((i=0; i<n; i++)); do
    size="$(stat -c %s "${C_ZIP[i]}" 2>/dev/null || echo 0)"
    live_http="$(awk '/^HTTP\// { code = $2 + 0 } END { if (code) print code }' \
      "${C_HEAD[i]}" 2>/dev/null)"
    if [[ "${live_http:-0}" == "${C_CODE[i]}" ]]; then
      bytes=$((bytes + size))
      if [[ "$size" -gt "${C_SIZE[i]:-0}" ]]; then
        C_SIZE[i]="$size"
        C_LAST_PROGRESS[i]="$poll_ms"
      fi
    fi
    [[ "${C_STATE[i]}" == pending ]] || continue
    if kill -0 "${C_PID[i]}" 2>/dev/null; then
      running=$((running + 1))
      continue
    fi
    wait "${C_PID[i]}"; rc=$?
    wait "${C_PARSE_PID[i]}"; parse_rc=$?
    http="$(awk '/^HTTP\// { code = $2 + 0 } END { if (code) print code }' \
      "${C_HEAD[i]}" 2>/dev/null)"
    if [[ "$rc" -ne 0 || "$parse_rc" -ne 0 ]]; then
      C_STATE[i]="failed"
      if [[ "$rc" -eq 28 ]]; then C_REASON[i]="timeout"; else C_REASON[i]="transfer"; fi
      slog "source index=${C_INDEX[i]} failed reason=${C_REASON[i]} rc=$rc http=${http:-0}"
    elif [[ "${http:-0}" != "${C_CODE[i]}" ]]; then
      C_STATE[i]="failed"
      if [[ "${http:-0}" == "404" ]]; then C_REASON[i]="not_found"; else C_REASON[i]="rejected"; fi
      slog "source index=${C_INDEX[i]} failed reason=${C_REASON[i]} rc=$rc http=${http:-0}"
    elif ! zip_is_safe_and_usable "${C_ZIP[i]}"; then
      C_STATE[i]="failed"; C_REASON[i]="invalid_package"
      slog "source index=${C_INDEX[i]} failed reason=invalid_package rc=$rc http=${http:-0}"
    elif extract_source "$i"; then
      C_STATE[i]="ok"; completed=$((completed + 1)); slog "source index=${C_INDEX[i]} collected"
    else
      C_STATE[i]="failed"; C_REASON[i]="extract"
      slog "source index=${C_INDEX[i]} failed reason=extract rc=$rc http=${http:-0}"
    fi
  done

  if [[ "$bytes" -gt "$progress_bytes" ]]; then progress_bytes="$bytes"; fi

  # curl writes every response header block while following redirects. Use a
  # Content-Length only from the latest non-redirect response, then expose an
  # aggregate total only when every participating source has a known size.
  aggregate_total=0; totals_known=1
  for ((i=0; i<n; i++)); do
    C_TOTAL[i]=""
    if [[ -f "${C_TOTAL_FILE[i]}" ]]; then
      IFS= read -r 'C_TOTAL[i]' < "${C_TOTAL_FILE[i]}" || true
    fi
    total_http="$(awk '/^HTTP\// { code = $2 + 0 } END { if (code) print code }' \
      "${C_HEAD[i]}" 2>/dev/null)"
    if [[ "${total_http:-0}" != "${C_CODE[i]}" ]]; then
      if [[ "${C_STATE[i]}" == pending ]]; then totals_known=0; fi
    elif [[ "${C_TOTAL[i]}" =~ ^[0-9]+$ ]]; then
      aggregate_total=$((aggregate_total + 10#${C_TOTAL[i]}))
    else
      totals_known=0
    fi
  done
  [[ "$totals_known" -eq 1 ]] || aggregate_total=0
  write_state downloading "" "$progress_bytes" "$aggregate_total"
  current_ms="$(now_ms)"
  if [[ -z "$usable_at" ]] && aggregate_is_usable; then
    usable_at="$current_ms"
    slog "usable aggregate available"
  fi
  if [[ -n "$usable_at" && -z "$coverage_at" ]] && coverage_complete; then
    coverage_at="$current_ms"
  fi
  if [[ "$running" -eq 0 ]]; then break; fi

  close_reason=""
  if [[ -n "$coverage_at" && $((current_ms - coverage_at)) -ge "$grace_ms" ]]; then
    close_reason="coverage grace"
  elif [[ -n "$usable_at" && $((current_ms - usable_at)) -ge "$quiet_ms" ]]; then
    close_reason="enrichment quiet window"
  fi

  if [[ -n "$close_reason" ]]; then
    active_pending=0
    for ((i=0; i<n; i++)); do
      [[ "${C_STATE[i]}" == pending ]] || continue
      if [[ "${C_SIZE[i]:-0}" -gt 0 \
          && $((current_ms - ${C_LAST_PROGRESS[i]:-$start_ms})) -le "$active_window_ms" ]]; then
        active_pending=$((active_pending + 1))
      fi
    done
    if [[ "$active_pending" -eq 0 ]]; then
      slog "closing after $close_reason; usable result retained active_sources=$active_pending"
      break
    fi
    if [[ "$extension_logged" -eq 0 ]]; then
      slog "extending past $close_reason for active_sources=$active_pending"
      extension_logged=1
    fi
  fi
  sleep 0.05
done

for ((i=0; i<n; i++)); do
  if [[ "${C_STATE[i]}" == pending ]]; then
    kill "${C_PID[i]}" 2>/dev/null || true
    wait "${C_PID[i]}" 2>/dev/null || true
    wait "${C_PARSE_PID[i]}" 2>/dev/null || true
    C_STATE[i]="cancelled"
  fi
done

if [[ "$cancelled" -eq 1 ]]; then
  rm -rf "$EXTRACT_DIR"
  write_state cancelled "" "$progress_bytes" 0 "" cancelled download
  exit 0
fi

if [[ "$completed" -eq 0 ]]; then
  rm -rf "$EXTRACT_DIR"
  not_found=0; invalid=0; unavailable=0; rejected=0
  for ((i=0; i<n; i++)); do
    case "${C_REASON[i]:-}" in
      not_found) not_found=$((not_found + 1)) ;;
      invalid_package|extract) invalid=$((invalid + 1)) ;;
      rejected) rejected=$((rejected + 1)) ;;
      *) unavailable=$((unavailable + 1)) ;;
    esac
  done
  if [[ "$not_found" -eq "$n" ]]; then
    write_state failed "" "$progress_bytes" 0 \
      "The configured sources do not have this app yet." not_found source
  elif [[ "$invalid" -gt 0 && "$unavailable" -eq 0 ]]; then
    write_state failed "" "$progress_bytes" 0 \
      "Sources responded, but none returned recognizable game data for this app." invalid_package validate
  elif [[ "$rejected" -gt 0 && "$unavailable" -eq 0 && "$invalid" -eq 0 ]]; then
    write_state failed "" "$progress_bytes" 0 \
      "The configured sources rejected the request or returned an unexpected status." source_rejected source
  else
    write_state failed "" "$progress_bytes" 0 \
      "No configured source completed a usable download. Check the connection and try again." source_unavailable download
  fi
  exit 1
fi
[[ "$progress_bytes" -gt 0 ]] || progress_bytes=1
write_state collected "Merged $completed sources" "$progress_bytes" "$progress_bytes"
slog "collection complete contributors=$completed"
exit 0
