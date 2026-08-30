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
