#!/usr/bin/env bash
# rebase-upstream.sh
#
# Pull a new upstream luatools.zip into upstream/ and three-way-merge
# the changes onto shared/backend/main.lua. The Linux-specific
# touchpoints in shared/main.lua are marked with `-- ADAPT-LINUX:`
# comments — the merge driver here keeps those local edits while
# accepting upstream's surrounding changes.
#
# Usage:
#   scripts/rebase-upstream.sh [<path-to-new-luatools.zip>]
#   scripts/rebase-upstream.sh --url https://...     # download first
#
# The script:
#   1. Snapshots the current vendored upstream as the merge base.
#   2. Replaces upstream/luatools/ with the new zip contents.
#   3. Builds a candidate shared/main.lua by re-applying the linux
#      touchpoints to the new upstream main.lua via `git merge-file`
#      with --diff3 (three-way) — base = old upstream main.lua,
#      ours = current shared/main.lua, theirs = new upstream main.lua.
#   4. Leaves conflict markers in place if any touchpoint can't be
#      reapplied cleanly, so the developer can resolve manually.
#
# Requires: git, unzip. Falls back to copy-only behaviour if git is
# unavailable, in which case the developer needs to merge by hand.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_DIR="$ROOT/upstream/luatools"
SHARED_MAIN="$ROOT/shared/backend/main.lua"

NEW_ZIP=""
URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    *)
      if [[ -z "$NEW_ZIP" ]]; then NEW_ZIP="$1"; fi
      shift
      ;;
  esac
done

if [[ -n "$URL" ]]; then
  NEW_ZIP="$(mktemp -t luatools.XXXXXX.zip)"
  echo "[rebase] fetching $URL"
  curl -sSL --fail "$URL" -o "$NEW_ZIP"
fi

if [[ -z "$NEW_ZIP" || ! -f "$NEW_ZIP" ]]; then
  echo "usage: $0 <path-to-luatools.zip> | --url <download-url>" >&2
  exit 2
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "[rebase] unzip not found; install it and retry" >&2
  exit 2
fi

# Workspace.
WORK="$(mktemp -d -t slsteammoon-rebase.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

OLD_MAIN="$WORK/old_upstream_main.lua"
NEW_MAIN="$WORK/new_upstream_main.lua"
NEW_TREE="$WORK/new"

# 1. Snapshot the current upstream main.lua as the merge base.
if [[ -f "$UPSTREAM_DIR/backend/main.lua" ]]; then
  cp "$UPSTREAM_DIR/backend/main.lua" "$OLD_MAIN"
else
  echo "[rebase] no existing upstream/luatools/backend/main.lua; treating as first import"
  : > "$OLD_MAIN"
fi

# 2. Extract the new upstream and replace the vendored copy.
mkdir -p "$NEW_TREE"
unzip -q -o "$NEW_ZIP" -d "$NEW_TREE"

if [[ ! -d "$NEW_TREE/luatools" ]]; then
  echo "[rebase] expected '$NEW_TREE/luatools/' inside the zip; aborting" >&2
  exit 3
fi

# Strip volatile runtime artefacts from the vendored snapshot.
rm -rf "$NEW_TREE/luatools/backend/temp_dl" || true
rm -f  "$NEW_TREE/luatools/backend/lua_runtime.log" \
       "$NEW_TREE/luatools/backend/loadedappids.txt" \
       "$NEW_TREE/luatools/backend/appidlogs.txt" \
       "$NEW_TREE/luatools/backend/main_teste_antigo.lua" || true

cp "$NEW_TREE/luatools/backend/main.lua" "$NEW_MAIN"

# Replace the pristine vendored tree.
rm -rf "$UPSTREAM_DIR"
mkdir -p "$(dirname "$UPSTREAM_DIR")"
mv "$NEW_TREE/luatools" "$UPSTREAM_DIR"

# 3. Three-way merge into shared/backend/main.lua.
if ! command -v git >/dev/null 2>&1; then
  echo "[rebase] git not found; vendored upstream replaced but shared/main.lua left untouched."
  echo "[rebase] diff manually against $UPSTREAM_DIR/backend/main.lua and reapply the ADAPT-LINUX edits."
  exit 0
fi

CAND="$WORK/shared_candidate.lua"
cp "$SHARED_MAIN" "$CAND"

set +e
git merge-file --diff3 -L "shared/main.lua (linux)" -L "upstream main.lua (base)" -L "upstream main.lua (new)" \
  "$CAND" "$OLD_MAIN" "$NEW_MAIN"
MERGE_RC=$?
set -e

cp "$CAND" "$SHARED_MAIN"

if [[ $MERGE_RC -eq 0 ]]; then
  echo "[rebase] shared/backend/main.lua merged cleanly. Verify ADAPT-LINUX touchpoints survived:"
  echo "         grep -nE '-- ADAPT-LINUX:' $SHARED_MAIN | wc -l"
elif [[ $MERGE_RC -gt 0 ]]; then
  echo "[rebase] $MERGE_RC merge conflict(s) in $SHARED_MAIN."
  echo "[rebase] Conflict markers left in place. Resolve, run scripts/build.sh, then commit."
fi

# Sanity: bail if the result no longer parses.
if command -v luajit >/dev/null 2>&1; then
  if ! luajit -e "local f, err = loadfile('$SHARED_MAIN'); if not f then io.stderr:write('SYNTAX: ' .. tostring(err) .. '\\n'); os.exit(1) end" >/dev/null 2>&1; then
    echo "[rebase] WARNING: $SHARED_MAIN no longer parses as Lua. Resolve conflicts before continuing." >&2
  fi
fi

echo "[rebase] done. Upstream pinned to: $(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$UPSTREAM_DIR/plugin.json" | head -n1)"
