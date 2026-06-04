#!/usr/bin/env bash
# build.sh — assemble the Linux LuaTools plugin from the vendored
# upstream (piqseu/ltsteamplugin) plus this fork's Linux overlay.
#
# Upstream piqseu v8.x is already modular and largely cross-platform
# (it branches on OS == "Windows_NT" and ships backend/scripts/
# downloader.sh). So this fork is no longer a monolith rewrite — it is
# a small set of overlays + anchored patches on top of a pristine
# upstream tree:
#
#   1. Copy upstream/luatools/ verbatim into dist/luatools/.
#   2. Drop in the Linux overlay files (linux/):
#        backend/slsteam.lua                  (AdditionalApps registrar)
#        backend/scripts/restart_steam.sh     (wrapper-aware restart)
#        backend/api.json                     (adds SkyAPI by default)
#   3. Apply anchored patches to upstream files:
#        downloads.lua   -> register appid in SLSsteam after install
#        main.lua        -> unregister appid on delete
#        auto_update.lua -> Linux restart via restart_steam.sh
#        public/luatools.js -> "Restart Steam" button in the
#                              "Game Added" modal
#   4. Rewrite backend/update.json to point at this fork's repo.
#
# Every patch is ANCHORED: if the anchor text is gone (upstream moved
# it), apply_patch aborts the build loudly so the rebase is noticed
# instead of silently shipping an unpatched plugin.
#
# Usage:
#   scripts/build.sh            # build into dist/luatools/
#   scripts/build.sh --out DIR  # build into DIR
#   scripts/build.sh --zip      # also produce dist/luatools-linux.zip

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="$ROOT/upstream/luatools"
OVERLAY="$ROOT/linux"
OUT="$ROOT/dist/luatools"
MAKE_ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --zip) MAKE_ZIP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$UPSTREAM" ]]; then
  echo "[build] missing upstream at $UPSTREAM (run scripts/rebase-upstream.sh)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Anchored patch helper. Replaces the FIRST occurrence of a unique anchor
# block with a replacement, asserting the anchor exists exactly once.
#   apply_patch <file> <anchor-marker-desc> <python-snippet>
# We use python for reliable multi-line literal replacement.
# ---------------------------------------------------------------------------
PYBIN="$(command -v python3 || true)"
if [[ -z "$PYBIN" ]]; then
  echo "[build] python3 is required for anchored patching" >&2
  exit 2
fi

# patch_replace <file> <needle> <replacement>
# Asserts needle occurs exactly once, replaces it. Aborts otherwise.
patch_replace() {
  local file="$1" needle="$2" repl="$3"
  NEEDLE="$needle" REPL="$repl" "$PYBIN" - "$file" <<'PY'
import os, sys
path = sys.argv[1]
needle = os.environ["NEEDLE"]
repl = os.environ["REPL"]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()
n = s.count(needle)
if n != 1:
    sys.stderr.write(
        "[build] PATCH ANCHOR FAILED in %s: found %d matches (need 1)\n"
        "        anchor:\n%s\n" % (path, n, needle))
    sys.exit(3)
s = s.replace(needle, repl, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
PY
}

echo "[build] assembling into $OUT"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"

# 1. Pristine upstream.
cp -R "$UPSTREAM" "$OUT"

# Strip Windows-only artefacts (harmless on Linux, but no reason to ship).
rm -f "$OUT/backend/restart_steam.cmd" \
      "$OUT/backend/scripts/downloader.ps1" 2>/dev/null || true
# Strip volatile runtime artefacts if they slipped into the vendored tree.
rm -rf "$OUT/backend/temp_dl" 2>/dev/null || true
rm -f  "$OUT/backend/lua_runtime.log" \
       "$OUT/backend/loadedappids.txt" \
       "$OUT/backend/appidlogs.txt" 2>/dev/null || true

# 2. Linux overlay files.
cp "$OVERLAY/backend/slsteam.lua" "$OUT/backend/slsteam.lua"
mkdir -p "$OUT/backend/scripts"
cp "$OVERLAY/backend/scripts/restart_steam.sh" "$OUT/backend/scripts/restart_steam.sh"
# Override upstream downloader.sh with our env-resetting version (the
# upstream one fails under Steam's runtime LD_LIBRARY_PATH on Linux).
cp "$OVERLAY/backend/scripts/downloader.sh" "$OUT/backend/scripts/downloader.sh"
chmod +x "$OUT/backend/scripts/restart_steam.sh" \
         "$OUT/backend/scripts/downloader.sh" 2>/dev/null || true
cp "$OVERLAY/backend/api.json" "$OUT/backend/api.json"

# 3a. downloads.lua — register the appid into SLSsteam's AdditionalApps
#     immediately after the .lua is installed (the "done" transition).
patch_replace "$OUT/backend/downloads.lua" \
'    pcall(fs.remove_all, extract_dir)
    pcall(fs.remove, dest_path)
    _set_download_state(appid, { status = "done", success = true, api = api_name })
end' \
'    pcall(fs.remove_all, extract_dir)
    pcall(fs.remove, dest_path)
    -- slsteammoon: register the appid in SLSsteam'"'"'s AdditionalApps so
    -- slsteam-moon establishes ownership (depot keys from the .lua are
    -- not enough; config.yaml must list the appid). Non-fatal.
    do
        local ok_sls, sls = pcall(require, "slsteam")
        if ok_sls and sls then
            pcall(sls.register_app, appid, "added via LuaTools")
        end
    end
    _set_download_state(appid, { status = "done", success = true, api = api_name })
end'

# 3b. main.lua — unregister the appid from AdditionalApps when the user
#     deletes the .lua via the UI.
patch_replace "$OUT/backend/main.lua" \
'    local deleted = {}
    for _, p in ipairs(candidates) do
        if fs.exists(p) then
            pcall(fs.remove, p)
            table.insert(deleted, p)
        end
    end
    return json_ok({ success = true, deleted = deleted, count = #deleted })' \
'    local deleted = {}
    for _, p in ipairs(candidates) do
        if fs.exists(p) then
            pcall(fs.remove, p)
            table.insert(deleted, p)
        end
    end
    -- slsteammoon: drop the appid from SLSsteam'"'"'s AdditionalApps too.
    do
        local ok_sls, sls = pcall(require, "slsteam")
        if ok_sls and sls then pcall(sls.unregister_app, appid) end
    end
    return json_ok({ success = true, deleted = deleted, count = #deleted })'

# 3c. auto_update.lua — Linux restart must go through the slsteam-moon
#     wrapper (LD_AUDIT injection), not bare `steam`. Replace the
#     non-Windows branch with our detached restart worker.
patch_replace "$OUT/backend/auto_update.lua" \
'    else
        m_utils.exec("killall steam && steam &")
        return true
    end' \
'    else
        -- slsteammoon: relaunch via restart_steam.sh, which kills Steam
        -- cleanly, waits, then starts the slsteam-moon wrapper so
        -- SLSsteam injection + provisioning happen on the next launch.
        local sh = fs.join(paths.get_plugin_dir(), "backend", "scripts", "restart_steam.sh")
        m_utils.exec('"'"'chmod +x "'"'"' .. sh .. '"'"'" 2>/dev/null'"'"')
        m_utils.exec('"'"'nohup bash "'"'"' .. sh .. '"'"'" > /dev/null 2>&1 &'"'"')
        return true
    end'

# 3d. auto_update.lua — the in-app updater downloads via a direct
#     curl|unzip that also runs under Steam'"'"'s runtime LD_LIBRARY_PATH;
#     strip those env vars so system curl/unzip load system libs.
patch_replace "$OUT/backend/auto_update.lua" \
'        cmd = string.format('"'"'curl -L -o "%s" "%s" && unzip -o -q "%s" -d "%s"'"'"', pending_zip, zip_url, pending_zip, paths.get_plugin_dir())' \
'        cmd = string.format('"'"'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; curl -L -o "%s" "%s" && unzip -o -q "%s" -d "%s"'"'"', pending_zip, zip_url, pending_zip, paths.get_plugin_dir())'

# 4. update.json -> this fork.
cat > "$OUT/backend/update.json" <<'EOF'
{
  "github": {
    "owner": "nwrafael",
    "repo": "slsteammoon-ltsteamplugin",
    "asset_name": "luatools-linux.zip"
  }
}
EOF

# 4b. plugin.json version -> this fork's VERSION (single source of truth).
#     The in-app auto-update compares the GitHub release TAG (e.g. "v2")
#     against this version. Keeping it as upstream's "8.0.4" would make
#     a "v1"/"v2" tag always read as older -> auto-update never fires.
#     So we stamp our own monotonic fork version that matches the tag
#     scheme (tag "vN" -> version "N").
if [[ -f "$ROOT/VERSION" ]]; then
  FORK_VER="$(tr -d ' \t\n\r' < "$ROOT/VERSION")"
  if [[ -n "$FORK_VER" ]]; then
    FORK_VER="$FORK_VER" "$PYBIN" - "$OUT/plugin.json" <<'PY'
import json, os, sys
path = sys.argv[1]
ver = os.environ["FORK_VER"]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["version"] = ver
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    echo "[build] stamped plugin.json version = $FORK_VER"
  fi
fi

# 5. Frontend patch: add a "Restart Steam" button to the "Game Added"
#    success modal. Applied by a dedicated script to keep build.sh
#    readable (the JS anchor is large).
"$ROOT/scripts/patch-frontend.sh" "$OUT/public/luatools.js"

# ---------------------------------------------------------------------------
# Validation.
# ---------------------------------------------------------------------------
if command -v luajit >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    if ! luajit -e "local fn,e=loadfile('$f'); if not fn then io.stderr:write(e..'\n'); os.exit(1) end" >/dev/null 2>&1; then
      echo "[build] LUA SYNTAX ERROR in $f" >&2
      exit 4
    fi
  done < <(find "$OUT/backend" -name '*.lua' -print0)
  echo "[build] lua syntax OK"
fi

# 6. Optional zip.
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

echo "[build] done -> $OUT (upstream $(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$OUT/plugin.json" | head -n1))"
