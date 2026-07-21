#!/usr/bin/env bash
# Package the canonical plugin/ source tree into dist/.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/plugin"
OUT="$ROOT/dist/luatools"
MAKE_ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "[build] --out requires a directory" >&2; exit 2; }
      OUT="$2"
      shift 2
      ;;
    --zip)
      MAKE_ZIP=1
      shift
      ;;
    *)
      echo "[build] unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -f "$SOURCE/plugin.json" ]] || {
  echo "[build] canonical source is missing: $SOURCE/plugin.json" >&2
  exit 2
}

SOURCE_REAL="$(realpath "$SOURCE")"
OUT_REAL="$(realpath -m "$OUT")"
case "$OUT_REAL" in
  "$ROOT"|"$SOURCE_REAL"|"$SOURCE_REAL"/*)
    echo "[build] refusing unsafe output directory: $OUT" >&2
    exit 2
    ;;
esac
OUT="$OUT_REAL"

echo "[build] packaging $SOURCE -> $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$SOURCE/." "$OUT/"

# Runtime files never belong in a release, even if a developer accidentally
# leaves them in the source tree while testing the plugin in place.
rm -rf "$OUT/backend/data" \
       "$OUT/backend/temp_dl"
rm -f "$OUT/backend/lua_runtime.log" \
      "$OUT/backend/loadedappids.txt" \
      "$OUT/backend/appidlogs.txt"

chmod +x "$OUT/backend/scripts/"*.sh 2>/dev/null || true
[[ ! -f "$OUT/backend/bin/7zz" ]] || chmod +x "$OUT/backend/bin/7zz"

# Keep releases fresh when the live catalogue is reachable, but retain the
# committed fallback index when offline. Tests set SKIP_INDEX_REFRESH=1 so a
# build can be compared byte-for-byte with plugin/.
if [[ "${SKIP_INDEX_REFRESH:-0}" != "1" ]]; then
  if CONNECT_TIMEOUT=10 MAX_TIME=45 \
      bash "$OUT/backend/scripts/ryuu_index.sh" "$OUT/backend/ryuu_index.json" \
      >/dev/null 2>&1; then
    echo "[build] refreshed ryuu_index.json"
  else
    echo "[build] index refresh unavailable; using the bundled copy"
  fi
fi

python3 - "$OUT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
with (root / "plugin.json").open(encoding="utf-8") as source:
    plugin = json.load(source)
with (root / "backend" / "api.defaults.json").open(encoding="utf-8") as source:
    apis = json.load(source)

if not str(plugin.get("version", "")).strip():
    raise SystemExit("[build] plugin.json has no version")
if not isinstance(apis.get("api_list"), list):
    raise SystemExit("[build] backend/api.defaults.json has no api_list")
PY

if command -v luajit >/dev/null 2>&1; then
  while IFS= read -r -d '' file; do
    if ! luajit -e \
      "local fn,e=loadfile('$file'); if not fn then io.stderr:write(e..'\\n'); os.exit(1) end" \
      >/dev/null 2>&1; then
      echo "[build] Lua syntax error: $file" >&2
      exit 4
    fi
  done < <(find "$OUT/backend" -name '*.lua' -print0)
  echo "[build] Lua syntax OK"
fi

if command -v node >/dev/null 2>&1; then
  while IFS= read -r -d '' file; do
    if ! node --check "$file" >/dev/null; then
      echo "[build] JavaScript syntax error: $file" >&2
      exit 4
    fi
  done < <(find "$OUT" -type f -name '*.js' -print0)
  echo "[build] JavaScript syntax OK"
fi

if [[ "$MAKE_ZIP" -eq 1 ]]; then
  command -v zip >/dev/null 2>&1 || {
    echo "[build] zip is required for --zip" >&2
    exit 2
  }
  BUNDLE="$(dirname "$OUT")/luatools-linux.zip"
  rm -f "$BUNDLE"
  (cd "$OUT" && zip -qr "$BUNDLE" .)
  echo "[build] wrote $BUNDLE"
fi

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$OUT/plugin.json")"
echo "[build] done -> $OUT (version $VERSION)"
