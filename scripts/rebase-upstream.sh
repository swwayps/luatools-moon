#!/usr/bin/env bash
# rebase-upstream.sh — pull a new upstream piqseu/ltsteamplugin release
# into upstream/luatools/ and verify this fork's patches still apply.
#
# Since piqseu v8.x is modular and cross-platform, the fork no longer
# carries a patched monolith. Rebasing is now just:
#   1. Replace upstream/luatools/ with the new release contents.
#   2. Run scripts/build.sh as a dry run. Every patch in build.sh and
#      patch-frontend.sh is ANCHORED and aborts if its anchor moved, so
#      a clean build == the fork still applies. A failed build names the
#      file/anchor that needs updating.
#
# Usage:
#   scripts/rebase-upstream.sh <path-to-ltsteamplugin.zip>
#   scripts/rebase-upstream.sh --url https://.../ltsteamplugin.zip
#   scripts/rebase-upstream.sh --latest      # fetch piqseu latest release

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_DIR="$ROOT/upstream/luatools"
REPO="piqseu/ltsteamplugin"
ASSET="ltsteamplugin.zip"

NEW_ZIP=""
URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --latest)
      URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -oE "https://[^\"]*$ASSET" | head -n1)"
      [[ -n "$URL" ]] || { echo "[rebase] could not resolve latest asset URL" >&2; exit 2; }
      shift ;;
    *) [[ -z "$NEW_ZIP" ]] && NEW_ZIP="$1"; shift ;;
  esac
done

if [[ -n "$URL" ]]; then
  NEW_ZIP="$(mktemp -t ltsteamplugin.XXXXXX.zip)"
  echo "[rebase] fetching $URL"
  curl -fsSL "$URL" -o "$NEW_ZIP"
fi

if [[ -z "$NEW_ZIP" || ! -f "$NEW_ZIP" ]]; then
  echo "usage: $0 <ltsteamplugin.zip> | --url <url> | --latest" >&2
  exit 2
fi

command -v unzip >/dev/null 2>&1 || { echo "[rebase] unzip required" >&2; exit 2; }

WORK="$(mktemp -d -t slsteammoon-rebase.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

unzip -q -o "$NEW_ZIP" -d "$WORK"

# The release zip's top level IS the plugin (plugin.json at the root).
if [[ ! -f "$WORK/plugin.json" ]]; then
  # Some releases nest under a single dir; descend into it.
  inner="$(find "$WORK" -maxdepth 2 -name plugin.json -type f | head -n1)"
  [[ -n "$inner" ]] || { echo "[rebase] no plugin.json found in zip" >&2; exit 3; }
  WORK="$(dirname "$inner")"
fi

# Strip volatile runtime artefacts before vendoring.
rm -rf "$WORK/backend/temp_dl" 2>/dev/null || true
rm -f  "$WORK/backend/lua_runtime.log" \
       "$WORK/backend/loadedappids.txt" \
       "$WORK/backend/appidlogs.txt" 2>/dev/null || true

OLD_VER="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$UPSTREAM_DIR/plugin.json" 2>/dev/null | head -n1 || echo unknown)"
NEW_VER="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$WORK/plugin.json" | head -n1)"

rm -rf "$UPSTREAM_DIR"
mkdir -p "$(dirname "$UPSTREAM_DIR")"
cp -R "$WORK" "$UPSTREAM_DIR"
echo "[rebase] vendored upstream: $OLD_VER -> $NEW_VER"

# Verify the fork still applies by building.
echo "[rebase] verifying patches apply (scripts/build.sh)..."
if "$ROOT/scripts/build.sh"; then
  echo "[rebase] OK — all anchored patches applied cleanly."
  echo "[rebase] review dist/luatools, then commit upstream/ + dist."
else
  echo "[rebase] BUILD FAILED — an anchor moved. Fix the named patch in" >&2
  echo "[rebase] scripts/build.sh or scripts/patch-frontend.sh, then re-run." >&2
  exit 4
fi
