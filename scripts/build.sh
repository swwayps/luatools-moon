#!/usr/bin/env bash
# build.sh — assemble a Millennium-installable Linux plugin tree.
#
# Layout produced (under dist/luatools/):
#   plugin.json                 (from upstream, version pinned)
#   backend/
#     main.lua                  (from shared/, ADAPT-LINUX patched)
#     platform.lua              (from linux/)
#     platform/workers/*.sh     (from linux/)
#     api.json, locales/, data/ (from upstream/)
#     update.json               (rewritten to point at *this* repo)
#   public/                     (from upstream/, frontend assets)
#
# Why this layout: Millennium loads the plugin from a single directory.
# We assemble it deterministically so the dev workflow is "edit
# shared/, edit linux/, run build.sh, copy dist/luatools to plugins/".
# Powershell .ps1 / .cmd / .vbs files from upstream are NOT shipped —
# they're Windows-only and the bash workers replace them.
#
# Usage:
#   scripts/build.sh                       # build into dist/luatools/
#   scripts/build.sh --out /path/to/plugins/luatools
#   scripts/build.sh --zip                 # also produce dist/luatools-linux.zip

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/luatools"
MAKE_ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --zip) MAKE_ZIP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

UPSTREAM="$ROOT/upstream/luatools"
SHARED="$ROOT/shared"
LINUX="$ROOT/linux"

if [[ ! -d "$UPSTREAM" ]]; then
  echo "[build] missing upstream tree at $UPSTREAM (run scripts/rebase-upstream.sh first)" >&2
  exit 2
fi

# Sanity-check the patched main.lua before we ship.
if command -v luajit >/dev/null 2>&1; then
  if ! luajit -e "local f, err = loadfile('$SHARED/backend/main.lua'); if not f then io.stderr:write('SYNTAX: ' .. tostring(err) .. '\\n'); os.exit(1) end" >/dev/null 2>&1; then
    echo "[build] $SHARED/backend/main.lua doesn't parse; aborting" >&2
    exit 3
  fi
fi

rm -rf "$OUT"
mkdir -p "$OUT/backend/platform/workers" "$OUT/backend/locales" "$OUT/backend/data" "$OUT/public/themes"

# 1. plugin.json from upstream (we keep upstream's version string so
#    "luatools 2.7.5-linux" maps cleanly to the original release).
cp "$UPSTREAM/plugin.json" "$OUT/plugin.json"

# 2. backend/main.lua — adapted shared copy.
cp "$SHARED/backend/main.lua" "$OUT/backend/main.lua"

# 3. backend/platform.lua + workers — Linux overlay.
cp "$LINUX/backend/platform.lua" "$OUT/backend/platform.lua"
cp "$LINUX/backend/platform/workers/"*.sh "$OUT/backend/platform/workers/"
chmod +x "$OUT/backend/platform/workers/"*.sh

# 4. backend assets that are platform-agnostic (api list, translations,
#    settings defaults).
cp "$UPSTREAM/backend/api.json" "$OUT/backend/api.json"
cp -R "$UPSTREAM/backend/locales/." "$OUT/backend/locales/"
if [[ -d "$UPSTREAM/backend/data" ]]; then
  cp -R "$UPSTREAM/backend/data/." "$OUT/backend/data/"
fi

# 5. update.json — rewrite to point at the slsteammoon-luatools repo
#    so the in-app update check pulls from this fork rather than the
#    Windows skyflarefox release.
cat > "$OUT/backend/update.json" <<'EOF'
{
  "github": {
    "owner": "nwrafael",
    "repo": "slsteammoon-luatools",
    "asset_name": "luatools-linux.zip"
  }
}
EOF

# 6. public/ — frontend bundle, identical to upstream.
cp -R "$UPSTREAM/public/." "$OUT/public/"

# Optional zip.
if [[ "$MAKE_ZIP" -eq 1 ]]; then
  if ! command -v zip >/dev/null 2>&1; then
    echo "[build] zip not found; skipping --zip" >&2
  else
    DIST_DIR="$(dirname "$OUT")"
    BUNDLE="$DIST_DIR/luatools-linux.zip"
    rm -f "$BUNDLE"
    (cd "$DIST_DIR" && zip -qr "$BUNDLE" "$(basename "$OUT")")
    echo "[build] wrote $BUNDLE"
  fi
fi

echo "[build] wrote $OUT"
echo "[build] install: cp -R $OUT  ~/.steam/steam/steamui/skins/Millennium/plugins/  (or wherever Millennium reads plugins on your install)"
