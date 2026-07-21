#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELATIVE_ROOT="dist/test-build-output.$$"
RUNTIME_MARKER="plugin/backend/data/.build-test-$$"
cleanup() {
  rm -rf "$RELATIVE_ROOT"
  rm -f "$RUNTIME_MARKER"
  rmdir plugin/backend/data 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$(dirname "$RUNTIME_MARKER")"
printf 'must not ship\n' > "$RUNTIME_MARKER"

SKIP_INDEX_REFRESH=1 scripts/build.sh \
  --out "$RELATIVE_ROOT/luatools" --zip >/dev/null

[[ -f "$RELATIVE_ROOT/luatools-linux.zip" ]] || {
  echo "relative --out must place the ZIP beside the output directory" >&2
  exit 1
}

ENTRIES="$RELATIVE_ROOT/zip-entries.txt"
unzip -Z1 "$RELATIVE_ROOT/luatools-linux.zip" > "$ENTRIES"
FIRST_ENTRY="$(sed -n '1p' "$ENTRIES")"
[[ "$FIRST_ENTRY" != "luatools/" ]] || {
  echo "the release ZIP must contain plugin files at its root" >&2
  exit 1
}

grep -qx 'plugin.json' "$ENTRIES"
grep -qx 'backend/api.defaults.json' "$ENTRIES"
if grep -qx 'backend/api.json' "$ENTRIES"; then
  echo "the release ZIP must not overwrite the legacy user API catalog" >&2
  exit 1
fi
if grep -q '^backend/data/' "$ENTRIES"; then
  echo "the release ZIP must not contain persistent user data" >&2
  exit 1
fi

echo "ok - release ZIP has root layout and excludes persistent user data"
