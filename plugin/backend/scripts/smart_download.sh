#!/usr/bin/env bash
# Bounded parallel collector for LuaTools game-data APIs.
set -uo pipefail
export LC_ALL=C
umask 077

: "${COLLECTION_DEADLINE:=8}"
: "${COVERAGE_GRACE:=0.3}"
: "${CONNECT_TIMEOUT:=5}"
: "${SPEED_LIMIT:=1000}"
: "${SPEED_TIME:=3}"

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
WORK="$DEST_ROOT/collect_${APPID}.$$"
EXTRACT_DIR="$DEST_ROOT/extracted_${APPID}"
LOCK="$DEST_ROOT/${APPID}.lock"
mkdir -p "$WORK"
rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"
trap 'rm -rf "$WORK" 2>/dev/null; rm -f "$CANDIDATES_FILE" "$COVERAGE_FILE" 2>/dev/null' EXIT

slog() { printf '%s INFO smart_download[%s pid %s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APPID" "$$" "$*"; }
write_state() {
  local status="$1" current="$2" bytes="$3" total="$4" error="${5:-}" tmp="${STATE_FILE}.tmp.$$"
  printf '{"status":"%s","currentApi":"%s","bytesRead":%s,"totalBytes":%s,"apiErrors":{},"error":"%s"}\n' \
    "$status" "$current" "$bytes" "$total" "$error" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}
now_ms() { date +%s%3N; }
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  if ! flock -n 9; then slog "worker already active"; exit 0; fi
fi
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

# NUL records: source-index, display-name, URL, accepted HTTP status.
declare -a C_INDEX C_NAME C_URL C_CODE C_ZIP C_HEAD C_PIPE C_TOTAL_FILE C_TOTAL C_PID C_PARSE_PID C_STATE
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
  C_TOTAL[n]=""; C_STATE[n]="pending"
  n=$((n + 1))
done
exec 3<&-
if [[ "$n" -eq 0 ]]; then write_state failed "" 0 0 "No usable API sources"; exit 1; fi

declare -A EXPECTED
expected_count=0
if [[ -n "$COVERAGE_FILE" && -f "$COVERAGE_FILE" ]]; then
  while IFS=$'\t' read -r depot gid; do
    [[ "$depot" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || continue
    if [[ -z "${EXPECTED["${depot}_${gid}.manifest"]+set}" ]]; then
      EXPECTED["${depot}_${gid}.manifest"]=1
      expected_count=$((expected_count + 1))
    fi
  done < "$COVERAGE_FILE"
fi

zip_is_safe_and_usable() {
  local zip="$1" entries count
  entries="$(unzip -Z1 "$zip" 2>/dev/null)" || return 1
  [[ -n "$entries" ]] || return 1
  if grep -Eq '(^/|(^|/)\.\.(/|$))' <<<"$entries"; then return 1; fi
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
  local i="$1" dir
  printf -v dir '%s/source_%04d' "$EXTRACT_DIR" "${C_INDEX[i]}"
  rm -rf "$dir"; mkdir -p "$dir"
  unzip -q "${C_ZIP[i]}" -d "$dir" || { rm -rf "$dir"; return 1; }
  printf '%s' "${C_NAME[i]}" > "$dir/.source-name"
  printf '%s\n' "${C_INDEX[i]}" > "$dir/.source-index"
  printf '%s\n' "${C_INDEX[i]}" > "$dir/.source-priority"
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
  stdbuf -e0 curl -sSLv -A 'discord(dot)gg/luatools' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$COLLECTION_DEADLINE" \
    --speed-limit "$SPEED_LIMIT" --speed-time "$SPEED_TIME" \
    -o "${C_ZIP[i]}" "${C_URL[i]}" > /dev/null 2> "${C_PIPE[i]}" &
  C_PID[i]=$!
done

start_ms="$(now_ms)"
deadline_ms="$(awk -v s="$start_ms" -v d="$COLLECTION_DEADLINE" 'BEGIN{printf "%.0f", s+d*1000}')"
grace_ms="$(awk -v g="$COVERAGE_GRACE" 'BEGIN{printf "%.0f", g*1000}')"
coverage_at=""; completed=0; progress_bytes=0
while :; do
  running=0; bytes=0
  for ((i=0; i<n; i++)); do
    size="$(stat -c %s "${C_ZIP[i]}" 2>/dev/null || echo 0)"
    bytes=$((bytes + size))
    [[ "${C_STATE[i]}" == pending ]] || continue
    if kill -0 "${C_PID[i]}" 2>/dev/null; then
      running=$((running + 1))
      continue
    fi
    wait "${C_PID[i]}"; rc=$?
    wait "${C_PARSE_PID[i]}"; parse_rc=$?
    http="$(awk '/^HTTP\// { code = $2 + 0 } END { if (code) print code }' \
      "${C_HEAD[i]}" 2>/dev/null)"
    if [[ "$rc" -eq 0 && "$parse_rc" -eq 0 \
        && "${http:-0}" == "${C_CODE[i]}" ]] \
        && zip_is_safe_and_usable "${C_ZIP[i]}" && extract_source "$i"; then
      C_STATE[i]="ok"; completed=$((completed + 1)); slog "source index=${C_INDEX[i]} collected"
    else
      C_STATE[i]="failed"; slog "source index=${C_INDEX[i]} failed rc=$rc http=${http:-0}"
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
    if [[ "${C_TOTAL[i]}" =~ ^[0-9]+$ ]]; then
      aggregate_total=$((aggregate_total + 10#${C_TOTAL[i]}))
    else
      totals_known=0
    fi
  done
  [[ "$totals_known" -eq 1 ]] || aggregate_total=0
  write_state downloading "" "$progress_bytes" "$aggregate_total"
  current_ms="$(now_ms)"
  if [[ -z "$coverage_at" ]] && coverage_complete; then coverage_at="$current_ms"; fi
  if [[ "$running" -eq 0 ]]; then break; fi
  if [[ -n "$coverage_at" && $((current_ms - coverage_at)) -ge "$grace_ms" ]]; then break; fi
  if [[ "$current_ms" -ge "$deadline_ms" ]]; then break; fi
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

if [[ "$completed" -eq 0 ]]; then
  rm -rf "$EXTRACT_DIR"
  write_state failed "" "$progress_bytes" 0 "All sources failed or exceeded the collection deadline"
  exit 1
fi
[[ "$progress_bytes" -gt 0 ]] || progress_bytes=1
write_state collected "Merged $completed sources" "$progress_bytes" "$progress_bytes"
slog "collection complete contributors=$completed"
exit 0