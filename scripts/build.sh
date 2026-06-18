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
# Pure helpers: perondepot online-fix matcher + WINEDLLOVERRIDES builder.
cp "$OVERLAY/backend/onlinefix.lua" "$OUT/backend/onlinefix.lua"
cp "$OVERLAY/backend/fix_overlays.lua" "$OUT/backend/fix_overlays.lua"
# Steam client language detection (Use Steam Language).
cp "$OVERLAY/backend/steamlang.lua" "$OUT/backend/steamlang.lua"

# Merge extra locale strings (new SpaceFix / Online Fix UI keys) into the
# shipped locale files. The locale manager only surfaces keys present in
# en.json, so every key is added to en + its translations. Rebase-safe:
# strings live in the overlay, not in the vendored upstream locale files.
if [[ -f "$OVERLAY/backend/locale_extra.json" ]]; then
  EXTRA="$OVERLAY/backend/locale_extra.json" "$PYBIN" - "$OUT/backend/locales" <<'PY'
import json, os, sys
locdir = sys.argv[1]
with open(os.environ["EXTRA"], "r", encoding="utf-8") as f:
    extra = json.load(f)
for code, kv in extra.items():
    path = os.path.join(locdir, code + ".json")
    if not os.path.isfile(path):
        sys.stderr.write("[build] locale_extra: %s.json not found, skipping\n" % code)
        continue
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    data.update(kv)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4, sort_keys=True)
        f.write("\n")
print("[build] merged locale_extra into %d locale file(s)" % len(extra))
PY
fi
mkdir -p "$OUT/backend/scripts"
cp "$OVERLAY/backend/scripts/restart_steam.sh" "$OUT/backend/scripts/restart_steam.sh"
# Override upstream downloader.sh with our env-resetting version (the
# upstream one fails under Steam's runtime LD_LIBRARY_PATH on Linux).
cp "$OVERLAY/backend/scripts/downloader.sh" "$OUT/backend/scripts/downloader.sh"
# Smart source selector (speed-first, completeness-aware race) used by the
# fast-download path.
cp "$OVERLAY/backend/scripts/smart_download.sh" "$OUT/backend/scripts/smart_download.sh"
chmod +x "$OUT/backend/scripts/restart_steam.sh" \
         "$OUT/backend/scripts/downloader.sh" \
         "$OUT/backend/scripts/smart_download.sh" 2>/dev/null || true
cp "$OVERLAY/backend/api.json" "$OUT/backend/api.json"

# Bundled static 7zz (fully static, multi-distro x86_64) for extracting fix
# archives — online fixes ship as .rar, which unzip can't handle. Shipping a
# static binary keeps the user dependency-free (the 25s manifest path still
# uses system unzip; the fix path prefers 7zz, see downloader.sh).
if [[ -f "$ROOT/linux/bin/7zz" ]]; then
  mkdir -p "$OUT/backend/bin"
  cp "$ROOT/linux/bin/7zz" "$OUT/backend/bin/7zz"
  chmod +x "$OUT/backend/bin/7zz" 2>/dev/null || true
fi

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

# 3a-bis. downloads.lua — inline the smart source selector functions
#     (start_add_via_luatools_smart + _launch_smart_download) just before the
#     module `return`. Kept in a separate .inc.lua to avoid shell-escaping a
#     large Lua block; inserted here so it can see downloads.lua's locals
#     (_set_download_state, the module requires, etc.).
SMART_INC="$OVERLAY/backend/smart_downloads.inc.lua"
if [[ ! -f "$SMART_INC" ]]; then
  echo "[build] missing smart selector include at $SMART_INC" >&2
  exit 2
fi
INC_FILE="$SMART_INC" "$PYBIN" - "$OUT/backend/downloads.lua" <<'PY'
import os, sys
path = sys.argv[1]
with open(os.environ["INC_FILE"], "r", encoding="utf-8") as f:
    inc = f.read()
with open(path, "r", encoding="utf-8") as f:
    s = f.read()
needle = "return downloads"
if s.count(needle) != 1:
    sys.stderr.write("[build] SMART INSERT ANCHOR FAILED: 'return downloads' "
                     "count != 1 in %s\n" % path)
    sys.exit(3)
s = s.replace(needle, inc.rstrip() + "\n\n" + needle, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
PY

# 3a-ter. main.lua — expose StartAddViaLuaToolsSmart so the frontend fast
#     path can request the smart race. Mirrors StartAddViaLuaTools(appid)
#     (Millennium passes { appid, contentScriptQuery } -> appid is first).
patch_replace "$OUT/backend/main.lua" \
'function StartAddViaLuaTools(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(downloads.start_add_via_luatools, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end' \
'function StartAddViaLuaTools(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(downloads.start_add_via_luatools, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function StartAddViaLuaToolsSmart(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(downloads.start_add_via_luatools_smart, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end'

# 3a-quater. downloads.lua — get_add_status only forwarded {status,error}
#     from the worker's state file, dropping the progress fields, so the
#     frontend progress bar (which reads state.bytesRead/totalBytes) was
#     always stuck at 0%. Forward bytesRead/totalBytes/currentApi too. nil
#     fields are skipped by _set_download_state's pairs() merge, so this is
#     safe for workers that don't emit them.
patch_replace "$OUT/backend/downloads.lua" \
'                _set_download_state(appid, { status = data.status, error = data.error })' \
'                _set_download_state(appid, {
                    status = data.status,
                    error = data.error,
                    bytesRead = data.bytesRead,
                    totalBytes = data.totalBytes,
                    currentApi = data.currentApi,
                })'

# 3a-quinquies. downloads.lua — the smart path leaves a <appid>_candidates.tsv
#     in temp_dl. The worker removes it via its EXIT trap, but if the worker is
#     killed before the trap runs the file leaks. Clean it defensively here too,
#     on both terminal transitions (extracted and failed), alongside the other
#     background-script artefacts.
patch_replace "$OUT/backend/downloads.lua" \
'                    -- Cleanup background script files
                    pcall(fs.remove, state_file)
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.ps1"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.sh"))
                elseif data.status == "failed" then
                    pcall(fs.remove, state_file)
                end' \
'                    -- Cleanup background script files
                    pcall(fs.remove, state_file)
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.ps1"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.sh"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_candidates.tsv"))
                elseif data.status == "failed" then
                    pcall(fs.remove, state_file)
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_candidates.tsv"))
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
'    -- slsteammoon: purge this game'"'"'s archived manifests from SLSsteam'"'"'s
    -- store first -- the .lua (which lists the depots) is about to be removed.
    do
        local ok_sls, sls = pcall(require, "slsteam")
        if ok_sls and sls and sls.purge_store_for_lua then
            for _, p in ipairs(candidates) do
                pcall(sls.purge_store_for_lua, p)
            end
        end
    end
    local deleted = {}
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

# 3b-bis. main.lua — expose GetProtonDBStatus so the store-page ProtonDB
#     badge can resolve a title's Linux/Proton compatibility tier server-side.
#     Fetching from the Lua backend avoids a cross-origin fetch from the store
#     page (protondb.com has no CORS headers for store.steampowered.com).
#     Mirrors CheckForFixes' shape: returns { success, data = { tier, ... } }.
patch_replace "$OUT/backend/main.lua" \
'function CheckForFixes(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixes.check_for_fixes, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end' \
'function CheckForFixes(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixes.check_for_fixes, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- slsteammoon: ProtonDB compatibility tier for the store-page badge.
function GetProtonDBStatus(appid)
    if type(appid) == "table" then appid = appid.appid end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    local ok, res = pcall(function()
        local url = "https://www.protondb.com/api/v1/reports/summaries/" .. tostring(appid) .. ".json"
        local resp = http_client.get(url, { timeout = 10 })
        if resp and resp.status == 200 and resp.body then
            local data = utils.decode_json(resp.body)
            if type(data) == "table" and data.tier then
                return {
                    success = true,
                    data = {
                        tier = data.tier,
                        trendingTier = data.trendingTier,
                        bestReportedTier = data.bestReportedTier,
                        confidence = data.confidence,
                        score = data.score,
                        total = data.total,
                    },
                }
            end
        end
        return { success = false, error = "no protondb data" }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end'

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

# 3c-bis. auto_update.lua — point the in-app updater at Codeberg'"'"'s
#     Forgejo releases API instead of GitHub. update.json now carries a
#     "codeberg" key (see step 4); read it (falling back to a legacy
#     "github" key) and query https://codeberg.org/api/v1/... which
#     returns the same JSON shape (.tag_name + .assets[].browser_download_url).
patch_replace "$OUT/backend/auto_update.lua" \
'    local gh_cfg = cfg.github
    if gh_cfg then
        local owner = gh_cfg.owner or ""
        local repo = gh_cfg.repo or ""
        local asset_name = gh_cfg.asset_name or "ltsteamplugin.zip"
        local tag = gh_cfg.tag or ""
        local tag_prefix = gh_cfg.tag_prefix or ""
        
        local endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/latest"
        if tag ~= "" then
            endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/tags/" .. tag
        end
        
        local resp = http_client.get(endpoint, {
            headers = {
                ["Accept"] = "application/vnd.github+json",
                ["User-Agent"] = "LuaTools-Updater"
            },
            timeout = 10
        })' \
'    local gh_cfg = cfg.codeberg or cfg.github
    if gh_cfg then
        local owner = gh_cfg.owner or ""
        local repo = gh_cfg.repo or ""
        local asset_name = gh_cfg.asset_name or "ltsteamplugin.zip"
        local tag = gh_cfg.tag or ""
        local tag_prefix = gh_cfg.tag_prefix or ""

        local api_base = "https://codeberg.org/api/v1/repos/"
        local endpoint = api_base .. owner .. "/" .. repo .. "/releases/latest"
        if tag ~= "" then
            endpoint = api_base .. owner .. "/" .. repo .. "/releases/tags/" .. tag
        end

        local resp = http_client.get(endpoint, {
            headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = "LuaTools-Updater"
            },
            timeout = 10
        })'

# 3d. auto_update.lua — the in-app updater downloads via a direct
#     curl|unzip that also runs under Steam'"'"'s runtime LD_LIBRARY_PATH;
#     strip those env vars so system curl/unzip load system libs.
patch_replace "$OUT/backend/auto_update.lua" \
'        cmd = string.format('"'"'curl -L -o "%s" "%s" && unzip -o -q "%s" -d "%s"'"'"', pending_zip, zip_url, pending_zip, paths.get_plugin_dir())' \
'        cmd = string.format('"'"'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; curl -L -o "%s" "%s" && unzip -o -q "%s" -d "%s"'"'"', pending_zip, zip_url, pending_zip, paths.get_plugin_dir())'

# 3e. main.lua — OpenExternalUrl (Discord button + other external links).
#     TWO upstream bugs on Linux:
#     (1) Millennium'"'"'s IPC bridge sorts JS object keys alphabetically and
#         passes their VALUES positionally. The frontend calls it with
#         { url, contentScriptQuery }, which sorts to [contentScriptQuery,
#         url]. The upstream signature OpenExternalUrl(url) therefore binds
#         `url` to the empty contentScriptQuery and the real URL is lost
#         (confirmed via logging: "ENTER raw= type=string"). Fix the
#         signature to (contentScriptQuery, url) to match the sorted order.
#     (2) The non-Windows branch ran `xdg-open` under Steam'"'"'s runtime env
#         (LD_LIBRARY_PATH/LD_AUDIT/LD_PRELOAD -> 32-bit Steam runtime),
#         which can crash spawned GUI binaries. Reset those vars + detach.
patch_replace "$OUT/backend/main.lua" \
'function OpenExternalUrl(url)
    if type(url) == "table" then url = url.url end' \
'function OpenExternalUrl(contentScriptQuery, url)
    -- Millennium sorts JS keys alphabetically -> { url, contentScriptQuery }
    -- arrives as (contentScriptQuery, url). Accept the table form too, and
    -- fall back to whichever arg actually carries the URL.
    if type(contentScriptQuery) == "table" then
        url = contentScriptQuery.url or url
    end
    if (type(url) ~= "string") or url == "" then
        if type(contentScriptQuery) == "string" and contentScriptQuery ~= "" then
            url = contentScriptQuery
        end
    end' \

patch_replace "$OUT/backend/main.lua" \
'    else
        pcall(m_utils.exec, '"'"'xdg-open "'"'"' .. url .. '"'"'"'"'"')
    end' \
'    else
        -- slsteammoon: reset the Steam runtime env and detach so the
        -- system browser launches with system libs (Steam exports a
        -- 32-bit runtime LD_LIBRARY_PATH/LD_AUDIT that crashes spawned
        -- GUI binaries otherwise).
        pcall(m_utils.exec,
            '"'"'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; '"'"' ..
            '"'"'setsid xdg-open "'"'"' .. url .. '"'"'" >/dev/null 2>&1 &'"'"')
    end'

# 3f. main.lua — OpenGameFolder wrapper. Same Millennium key-sort bug:
#     the frontend calls it with { path, contentScriptQuery }, which sorts
#     to [contentScriptQuery, path], so the upstream OpenGameFolder(path)
#     binds `path` to the empty contentScriptQuery (confirmed via logging).
#     Fix the signature to (contentScriptQuery, path) and resolve
#     defensively.
patch_replace "$OUT/backend/main.lua" \
'function OpenGameFolder(path)
    if type(path) == "table" then path = path.path end' \
'function OpenGameFolder(contentScriptQuery, path)
    -- Millennium sorts JS keys alphabetically -> { path, contentScriptQuery }
    -- arrives as (contentScriptQuery, path). Accept the table form too and
    -- fall back to whichever arg carries the path.
    if type(contentScriptQuery) == "table" then
        path = contentScriptQuery.path or path
    end
    if (type(path) ~= "string") or path == "" then
        if type(contentScriptQuery) == "string" and contentScriptQuery ~= "" then
            path = contentScriptQuery
        end
    end'

# 3g. steam_utils.lua — open_game_folder (Game folder button). Upstream
#     is Windows-only: it backslash-escapes the path and runs `explorer`,
#     which does nothing on Linux. Branch on OS and use xdg-open on Linux
#     with the same Steam-runtime env reset + detach as above.
patch_replace "$OUT/backend/steam_utils.lua" \
'function steam_utils.open_game_folder(path)
    if not path or path == "" or not fs.exists(path) then return false end
    
    -- In Windows, explorer accepts backslashes
    path = path:gsub("/", "\\")
    local cmd = '"'"'explorer "'"'"' .. path .. '"'"'"'"'"'
    m_utils.exec(cmd)
    return true
end' \
'function steam_utils.open_game_folder(path)
    if not path or path == "" or not fs.exists(path) then return false end

    local is_win = (m_utils.getenv("OS") or ""):find("Windows") ~= nil
    if is_win then
        -- In Windows, explorer accepts backslashes
        path = path:gsub("/", "\\")
        m_utils.exec('"'"'explorer "'"'"' .. path .. '"'"'"'"'"')
    else
        -- slsteammoon: open in the system file manager. Reset the Steam
        -- runtime env (LD_LIBRARY_PATH/LD_AUDIT/LD_PRELOAD point at the
        -- 32-bit Steam runtime and crash spawned GUI binaries) and
        -- detach via setsid so the manager uses system libs and outlives
        -- the Steam session.
        m_utils.exec(
            '"'"'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; '"'"' ..
            '"'"'setsid xdg-open "'"'"' .. path .. '"'"'" >/dev/null 2>&1 &'"'"')
    end
    return true
end'

# 3h. main.lua — SpaceFix (AIO button). On Linux the "All-In-One Fixes"
#     fix is not the Windows Unsteam emulator (Proton ignores the dropped
#     DLLs); instead we enable slsteam-moon's native FakeAppIds map so the
#     game reports as Spacewar (480) on the real Steam client layer
#     (matchmaking/presence/tickets — SLSsteam-fork src/feats/fakeappid.cpp).
#     Insert ApplySpaceFix just before GetApplyFixStatus.
patch_replace "$OUT/backend/main.lua" \
'function GetApplyFixStatus(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixes.get_apply_status, tonumber(appid))' \
'function ApplySpaceFix(appid, contentScriptQuery)
    -- AIO fix on Linux: enable slsteam-moon FakeAppIds { appid: 480 } so the
    -- game runs as Spacewar on the real client layer. No download/extract.
    if type(appid) == "table" then appid = appid.appid end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    local ok, res = pcall(function()
        local ok_sls, sls = pcall(require, "slsteam")
        if not (ok_sls and sls and sls.set_fake_appid) then
            error("slsteam helper unavailable")
        end
        local ok2, msg = sls.set_fake_appid(appid, 480)
        if not ok2 then error(tostring(msg)) end
        return { success = true, status = msg }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetApplyFixStatus(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixes.get_apply_status, tonumber(appid))'

# 3i. main.lua — UnFixGame (Manage Game / Un-Fix). Upstream is a stub. On
#     Linux "un-fix" undoes SpaceFix: drop the FakeAppIds mapping. Also
#     defensively remove orphan Unsteam files an older file-based apply may
#     have left in the install dir. No steam://validate (we never touched
#     game files — see the frontend patch).
patch_replace "$OUT/backend/main.lua" \
'function UnFixGame(appid, installPath, fixDate)
    if type(appid) == "table" then
        installPath = appid.installPath; fixDate = appid.fixDate; appid = appid.appid
    end
    -- Stub - unfix logic not yet ported
    return json_ok({ success = false, error = "Not yet implemented" })
end' \
'function UnFixGame(appid, installPath, fixDate)
    if type(appid) == "table" then
        installPath = appid.installPath; fixDate = appid.fixDate; appid = appid.appid
    end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    local ok, res = pcall(function()
        local ok_sls, sls = pcall(require, "slsteam")
        if ok_sls and sls and sls.unset_fake_appid then
            pcall(sls.unset_fake_appid, appid)
        end
        -- Defensive: remove orphan Unsteam files from an older file-based apply.
        local path = tostring(installPath or "")
        if path ~= "" then
            for _, name in ipairs({ "unsteam.dll", "unsteam.ini", "winmm.dll" }) do
                pcall(fs.remove, fs.join(path, name))
            end
        end
        return { success = true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end'

# 3j. fixes.lua — lift the 25s hard download cap for the fix-apply path.
#     downloader.sh defaults MAX_TIME=25 (right for small manifest zips, the
#     manual-add path it was written for). Game fixes are large (e.g. a Denuvo
#     bypass is hundreds of MB), so 25s aborts the download as "curl failed"
#     before it can extract. Pass MAX_TIME=0 (no total-time cap) for fix
#     downloads; the speed floor (--speed-limit/--speed-time in downloader.sh)
#     still aborts a genuinely stalled transfer. Linux branch only.
patch_replace "$OUT/backend/fixes.lua" \
'nohup bash "%s" "%s" "%s" "%s" "%s" > /dev/null 2>&1 &' \
'nohup env MAX_TIME=0 bash "%s" "%s" "%s" "%s" "%s" > /dev/null 2>&1 &'

# 3k. main.lua — GetFixLaunchOptions RPC. After an online/generic fix is
#     applied, the frontend reads the app's live launch options + compat tool
#     from Steam and asks us to scan the install dir for the fix's Windows
#     DLLs and merge a WINEDLLOVERRIDES into the options (so Proton loads the
#     native fix DLLs instead of its builtins). Native Linux apps -> apply=false.
#     All string logic lives in the unit-tested fix_overlays module. Inserted
#     before GetGameInstallPath.
patch_replace "$OUT/backend/main.lua" \
'function GetGameInstallPath(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(steam_utils.get_game_install_path_response, tonumber(appid))' \
'function GetFixLaunchOptions(appid, compatToolName, contentScriptQuery, currentLaunchOptions, installPath)
    -- Millennium sorts JS object keys alphabetically and passes values
    -- positionally: { appid, compatToolName, contentScriptQuery,
    -- currentLaunchOptions, installPath }.
    if type(appid) == "table" then
        compatToolName       = appid.compatToolName
        currentLaunchOptions = appid.currentLaunchOptions
        installPath          = appid.installPath
        appid                = appid.appid
    end
    local ok, res = pcall(function()
        local fix_overlays = require("fix_overlays")
        -- Gate on the fix DLLs actually being present in the install dir, NOT
        -- on the frontend compat-tool name: slsteam-moon injects the Proton
        -- CompatToolMapping into appinfo.vdf, so Steam'"'"'s AppDetails reports an
        -- empty compat tool and is_proton_tool would wrongly skip. The
        -- WINEDLLOVERRIDES is consumed only by Proton/Wine anyway (harmless if
        -- the title somehow runs native).
        local overrides = fix_overlays.overrides_for_install_dir(fs, tostring(installPath or ""))
        logger.log("GetFixLaunchOptions: appid=" .. tostring(appid)
            .. " compat=" .. tostring(compatToolName)
            .. " installPath=" .. tostring(installPath)
            .. " overrides=" .. tostring(overrides))
        if not overrides then
            return { success = true, apply = false }
        end
        local merged = fix_overlays.merge_launch_options(
            tostring(currentLaunchOptions or ""), overrides)
        return { success = true, apply = true, launchOptions = merged, overrides = overrides }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetGameInstallPath(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(steam_utils.get_game_install_path_response, tonumber(appid))'

# 3l. main.lua — ResolveOnlineFix RPC. The "Online Fix" button now sources
#     fixes from the perondepot online-fix mirror (the upstream luatools index
#     is rate-limited). We fetch the /all/ autoindex, match the store-page
#     game name to a .rar via the unit-tested onlinefix matcher, and return
#     its URL for the normal download/extract/apply flow (downloader.sh's
#     bundled 7zz handles .rar). Anchored on CancelApplyFix.
patch_replace "$OUT/backend/main.lua" \
'function CancelApplyFix(appid)
    return json_ok({ success = true })
end' \
'function CancelApplyFix(appid)
    return json_ok({ success = true })
end

function ResolveOnlineFix(appid, contentScriptQuery, gameName)
    -- Millennium sorts JS keys: { appid, contentScriptQuery, gameName }.
    if type(appid) == "table" then
        gameName = appid.gameName; appid = appid.appid
    end
    local ok, res = pcall(function()
        local onlinefix = require("onlinefix")
        local resp = http_client.get("http://api.perondepot.xyz/all/", { timeout = 15 })
        if not (resp and resp.status == 200 and resp.body) then
            error("online-fix index unavailable")
        end
        local entry = onlinefix.find_fix(resp.body, tostring(gameName or ""))
        if not entry then
            return { success = true, found = false }
        end
        return {
            success = true,
            found = true,
            url = "http://api.perondepot.xyz/all/" .. entry.href,
            name = entry.name,
        }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end'

# 3m. settings/manager.lua — implement Use Steam Language. Upstream's
#     _detect_steam_language() is a stub that always returns "en" (Millennium
#     couldn't read the registry), so the toggle never followed Steam. Read the
#     Steam language from ~/.steam/registry.vdf and map it to a LuaTools locale
#     via the unit-tested steamlang module.
patch_replace "$OUT/backend/settings/manager.lua" \
'-- Simple placeholder since we can'"'"'t easily read registry in Millennium Lua securely
local function _detect_steam_language()
    return "en"
end' \
'-- slsteammoon: read the Steam client language (~/.steam/registry.vdf) and map
-- it to a LuaTools locale code. Logic lives in the unit-tested steamlang module.
local function _detect_steam_language()
    local ok, steamlang = pcall(require, "steamlang")
    if ok and steamlang and steamlang.detect then
        local code = steamlang.detect()
        if code and code ~= "" then return code end
    end
    return "en"
end'

# 4. update.json -> this fork (Codeberg). auto_update.lua reads the
#    "codeberg" key and queries the Forgejo releases API (same JSON shape
#    as GitHub: .tag_name + .assets[].browser_download_url).
cat > "$OUT/backend/update.json" <<'EOF'
{
  "codeberg": {
    "owner": "unplausible",
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

  # Unit tests for the slsteam.lua overlay (AdditionalApps + FakeAppIds
  # config editors). Rebase-safe guard for the SpaceFix / Un-Fix flow.
  if [[ -f "$ROOT/scripts/test-slsteam.lua" ]]; then
    if ! ( cd "$ROOT" && luajit scripts/test-slsteam.lua >/dev/null 2>&1 ); then
      echo "[build] slsteam.lua unit tests FAILED" >&2
      exit 4
    fi
    echo "[build] slsteam.lua unit tests OK"
  fi

  # Pure-helper unit tests: online-fix matcher + WINEDLLOVERRIDES builder.
  for t in test-onlinefix test-fix-overlays test-steamlang; do
    if [[ -f "$ROOT/scripts/$t.lua" ]]; then
      if ! ( cd "$ROOT" && luajit "scripts/$t.lua" >/dev/null 2>&1 ); then
        echo "[build] $t unit tests FAILED" >&2
        exit 4
      fi
      echo "[build] $t unit tests OK"
    fi
  done
fi

# 6. Optional zip. The archive must contain the plugin contents at its
#    ROOT (plugin.json, backend/, public/, .millennium/ directly), NOT
#    wrapped in a luatools/ dir. This matches the upstream piqseu release
#    layout so the in-plugin auto-updater (which does
#    `unzip -d <plugin_dir>`) overwrites the install in place instead of
#    nesting it under <plugin_dir>/luatools/. install.sh locates
#    plugin.json by search, so it handles this layout too.
if [[ "$MAKE_ZIP" -eq 1 ]]; then
  if ! command -v zip >/dev/null 2>&1; then
    echo "[build] zip not found; skipping --zip" >&2
  else
    DIST_DIR="$(dirname "$OUT")"
    BUNDLE="$DIST_DIR/luatools-linux.zip"
    rm -f "$BUNDLE"
    (cd "$OUT" && zip -qr "$BUNDLE" .)
    echo "[build] wrote $BUNDLE (contents at root)"
  fi
fi

echo "[build] done -> $OUT (upstream $(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$OUT/plugin.json" | head -n1))"
