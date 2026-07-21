#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/plugin"

[[ -f "$SOURCE/plugin.json" ]] || {
  echo "plugin/ must contain the canonical, fully patched source tree" >&2
  exit 1
}

for legacy in upstream linux scripts/patch-frontend.sh scripts/rebase-upstream.sh; do
  [[ ! -e "$ROOT/$legacy" ]] || {
    echo "legacy patchset path still exists: $legacy" >&2
    exit 1
  }
done

[[ ! -e "$SOURCE/.millennium" ]] || {
  echo "generated Millennium cache must not be committed or released" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SKIP_INDEX_REFRESH=1 "$ROOT/scripts/build.sh" --out "$TMP/luatools" >/dev/null
diff -qr "$SOURCE" "$TMP/luatools"

echo "ok - build packages the canonical plugin source without a patch layer"
