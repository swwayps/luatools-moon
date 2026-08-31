#!/usr/bin/env bash
# End-to-end check for persistent per-apply file journals and reverse Unfix.
set -u

fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

SEVENZ_SYS="$(command -v 7zz || command -v 7z || command -v 7za || true)"
[ -n "$SEVENZ_SYS" ] || { echo "SKIP: no system 7z/7zz available"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
. "$REPO/scripts/testlib-httpd.sh"
trap 'stop_static_server 2>/dev/null || true; rm -rf "$TMP"' EXIT
start_static_server "$TMP" || { echo "SKIP: no python3 http server"; exit 0; }

mkdir -p "$TMP/backend/scripts" "$TMP/backend/bin"
cp "$REPO/plugin/backend/scripts/downloader.sh" "$TMP/backend/scripts/downloader.sh"
ln -s "$SEVENZ_SYS" "$TMP/backend/bin/7zz"
DOWNLOADER="$TMP/backend/scripts/downloader.sh"
RESTORE="$REPO/plugin/backend/scripts/restore_fix.sh"
CANCEL_HELPER="$REPO/plugin/backend/scripts/cancel_fix.sh"
GAME="$TMP/game"
BACKUPS="$TMP/backups/480"
mkdir -p "$GAME"
printf 'original\n' > "$GAME/shared.dll"
printf 'user\n' > "$GAME/user.cfg"

make_archive() {
  local label="$1" shared="$2" added="$3"
  local source="$TMP/${label}-src"
  mkdir -p "$source/nested"
  printf '%s\n' "$shared" > "$source/shared.dll"
  printf '%s\n' "$label" > "$source/nested/$added"
  (cd "$source" && "$SEVENZ_SYS" a -tzip "$TMP/$label.zip" . >/dev/null 2>&1)
}

apply_archive() {
  local label="$1"
  EXTRACT_NESTED=1 MAX_TIME=0 ALLOW_HTTP=1 bash "$DOWNLOADER" \
    "$HTTPD_URL/$label.zip" "$TMP/$label-download.zip" "$GAME" \
    "$TMP/$label-state.json" '' '' "$BACKUPS" >/dev/null 2>&1
}

make_archive a first a-only.dll
apply_archive a
make_archive b second b-only.dll
apply_archive b

check "two successful applies keep two rollback transactions" \
  "[ \"\$(find '$BACKUPS' -mindepth 1 -maxdepth 1 -type d | wc -l)\" -eq 2 ]"
check "second apply is live before Unfix" \
  "[ \"\$(cat '$GAME/shared.dll')\" = second ]"
check "files from both applications are present before Unfix" \
  "[ -f '$GAME/nested/a-only.dll' ] && [ -f '$GAME/nested/b-only.dll' ]"

LATEST_TXN="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)"
bash "$RESTORE" "$GAME" "$BACKUPS" "$LATEST_TXN" >/dev/null 2>&1
check "targeted rollback restores only the interrupted latest apply" \
  "[ \"\$(cat '$GAME/shared.dll')\" = first ] && [ -f '$GAME/nested/a-only.dll' ] && [ ! -e '$GAME/nested/b-only.dll' ]"
check "targeted rollback preserves older transactions for normal Unfix" \
  "[ \"\$(find '$BACKUPS' -mindepth 1 -maxdepth 1 -type d | wc -l)\" -eq 1 ]"

bash "$RESTORE" "$GAME" "$BACKUPS" >/dev/null 2>&1
restore_status=$?
check "Unfix restore succeeds" "[ '$restore_status' -eq 0 ]"
check "reverse replay restores the pre-first-fix file" \
  "[ \"\$(cat '$GAME/shared.dll')\" = original ]"
check "reverse replay removes files added by every fix" \
  "[ ! -e '$GAME/nested/a-only.dll' ] && [ ! -e '$GAME/nested/b-only.dll' ]"
check "reverse replay removes now-empty fix directories" "[ ! -d '$GAME/nested' ]"
check "Unfix leaves unrelated game files untouched" \
  "[ \"\$(cat '$GAME/user.cfg')\" = user ]"
check "consumed rollback transactions are removed" "[ ! -d '$BACKUPS' ]"

# Cancellation must be red-capable while the worker is inside the live apply
# loop. The test-only delay widens that exact boundary without changing normal
# production timing.
CANCEL_SRC="$TMP/cancel-src"
CANCEL_STATE="$TMP/cancel-state.json"
mkdir -p "$CANCEL_SRC/nested"
printf 'cancelled-overlay\n' > "$CANCEL_SRC/shared.dll"
for n in $(seq 1 40); do printf 'new %s\n' "$n" > "$CANCEL_SRC/nested/cancel-$n.dll"; done
(cd "$CANCEL_SRC" && "$SEVENZ_SYS" a -tzip "$TMP/cancel.zip" . >/dev/null 2>&1)
EXTRACT_NESTED=1 MAX_TIME=0 ALLOW_HTTP=1 LUATOOLS_APPLY_STEP_DELAY=0.03 \
  bash "$DOWNLOADER" "$HTTPD_URL/cancel.zip" "$TMP/cancel-download.zip" \
    "$GAME" "$CANCEL_STATE" '' '' "$BACKUPS" >/dev/null 2>&1 &
CANCEL_WORKER=$!
for _ in $(seq 1 200); do
  grep -q '"status": "applying"' "$CANCEL_STATE" 2>/dev/null && break
  kill -0 "$CANCEL_WORKER" 2>/dev/null || break
  sleep 0.02
done
bash "$CANCEL_HELPER" "$CANCEL_STATE" "$GAME" "$BACKUPS" '' >/dev/null 2>&1
CANCEL_STATUS=$?
wait "$CANCEL_WORKER" 2>/dev/null || true
check "cancelling live apply reports a terminal cancelled state" \
  "[ '$CANCEL_STATUS' -eq 0 ] && grep -q '\"status\": \"cancelled\"' '$CANCEL_STATE'"
check "cancelling live apply restores the replaced original file" \
  "[ \"\$(cat '$GAME/shared.dll')\" = original ]"
check "cancelling live apply removes every file introduced by that transaction" \
  "[ -z \"\$(find '$GAME/nested' -name 'cancel-*.dll' -print -quit 2>/dev/null)\" ]"
check "cancelled worker releases its pid and rollback transaction" \
  "[ ! -e '${CANCEL_STATE}.pid' ] && [ ! -d '$BACKUPS' ]"

WATCH_STATE="$TMP/watchdog-state.json"
bash -c 'while :; do sleep 1; done' "$WATCH_STATE" &
HUNG_WORKER=$!
printf '%s\n' "$HUNG_WORKER" > "${WATCH_STATE}.pid"
WATCH_STARTED=$SECONDS
bash "$CANCEL_HELPER" "$WATCH_STATE" "$GAME" "$BACKUPS" '' >/dev/null 2>&1
WATCH_STATUS=$?
WATCH_ELAPSED=$((SECONDS - WATCH_STARTED))
if kill -0 "$HUNG_WORKER" 2>/dev/null; then HUNG_DEAD=0; kill -KILL "$HUNG_WORKER" 2>/dev/null || true
else HUNG_DEAD=1; fi
wait "$HUNG_WORKER" 2>/dev/null || true
check "watchdog terminates a matching stalled worker within its fixed bound" \
  "[ '$WATCH_STATUS' -eq 0 ] && [ '$HUNG_DEAD' -eq 1 ] && [ '$WATCH_ELAPSED' -lt 3 ]"

sleep 30 &
UNRELATED_PID=$!
printf '%s\n' "$UNRELATED_PID" > "${WATCH_STATE}.pid"
bash "$CANCEL_HELPER" "$WATCH_STATE" "$GAME" "$BACKUPS" '' >/dev/null 2>&1 || true
if kill -0 "$UNRELATED_PID" 2>/dev/null; then UNRELATED_ALIVE=1; else UNRELATED_ALIVE=0; fi
kill "$UNRELATED_PID" 2>/dev/null || true
wait "$UNRELATED_PID" 2>/dev/null || true
check "watchdog never signals a stale pid belonging to another command" \
  "[ '$UNRELATED_ALIVE' -eq 1 ]"

LATE_STATE="$TMP/late-worker-state.json"
bash "$CANCEL_HELPER" "$LATE_STATE" "$GAME" "$BACKUPS" '' >/dev/null 2>&1
check "a cancellation requested before worker startup remains armed" \
  "[ -f '${LATE_STATE}.stop' ]"
EXTRACT_NESTED=1 MAX_TIME=0 ALLOW_HTTP=1 \
  bash "$DOWNLOADER" "$HTTPD_URL/cancel.zip" "$TMP/late-worker.zip" \
    "$GAME" "$LATE_STATE" '' '' "$BACKUPS" >/dev/null 2>&1 || true
check "a late-starting worker observes cancellation before touching the game" \
  "grep -q '\"status\": \"cancelled\"' '$LATE_STATE' \
    && [ \"\$(cat '$GAME/shared.dll')\" = original ] \
    && [ ! -e '${LATE_STATE}.pid' ] && [ ! -e '${LATE_STATE}.stop' ]"

# Keep later corruption-path checks independent even when the red half runs
# against an implementation that does not support cancellation yet.
bash "$RESTORE" "$GAME" "$BACKUPS" >/dev/null 2>&1 || true
rm -rf "$GAME/nested"
printf 'original\n' > "$GAME/shared.dll"

make_archive c third c-only.dll
apply_archive c
rm -f "$GAME/nested/c-only.dll"
mkdir -p "$GAME/nested/c-only.dll"
if bash "$RESTORE" "$GAME" "$BACKUPS" >/dev/null 2>&1; then failed_status=0; else failed_status=$?; fi
check "a conflicting directory makes restore fail safely" "[ '$failed_status' -ne 0 ]"
check "a failed restore keeps its transaction for retry" "[ -d '$BACKUPS' ]"

rm -rf "$GAME" "$BACKUPS"
GAME="$TMP/symlink-game"
BACKUPS="$TMP/symlink-backups/480"
OUTSIDE="$TMP/outside"
mkdir -p "$GAME" "$OUTSIDE"
printf 'original\n' > "$GAME/shared.dll"
printf 'outside\n' > "$OUTSIDE/d-only.dll"
make_archive d fourth d-only.dll
apply_archive d
rm -f "$GAME/nested/d-only.dll"
rmdir "$GAME/nested"
ln -s "$OUTSIDE" "$GAME/nested"
if bash "$RESTORE" "$GAME" "$BACKUPS" >/dev/null 2>&1; then symlink_status=0; else symlink_status=$?; fi
check "restore refuses a symlink introduced below the game root" \
  "[ '$symlink_status' -ne 0 ]"
check "restore never follows that symlink outside the game" \
  "[ \"\$(cat '$OUTSIDE/d-only.dll')\" = outside ]"
check "a refused symlink restore remains retryable" "[ -d '$BACKUPS' ]"

echo
echo "$fails failure(s)"
[ "$fails" -eq 0 ]
