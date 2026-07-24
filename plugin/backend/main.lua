-- LuaTools backend main.lua
-- All exported functions return JSON-encoded strings, mirroring the Python backend's json.dumps() returns.
-- This is required because Millennium's Lua bridge does not deep-serialize nested Lua tables.

local cjson            = require("json")
local m_utils          = require("utils")
local logger           = require("plugin_logger")
local millennium       = require("millennium")
local fs               = require("fs")
local http_client      = require("http_client")
local paths            = require("paths")
local steam_utils      = require("steam_utils")
local utils            = require("plugin_utils")
local locales_mod      = require("locales.manager")

local api_manifest     = require("api_manifest")
local downloads        = require("downloads")
local fixes            = require("fixes")
local settings_manager = require("settings.manager")
local auto_update      = require("auto_update")

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Safely encode a Lua table to a JSON string (same as Python json.dumps).
local function json_ok(data)
    local ok, s = pcall(cjson.encode, data)
    if ok then return s end
    logger.warn("json_ok encode failed: " .. tostring(s))
    return '{"success":false,"error":"serialization error"}'
end

local function json_err(msg)
    return json_ok({ success = false, error = tostring(msg) })
end

-- Lua's JSON bridge encodes an empty table as {}, even when the value is an
-- array. Keep list-shaped RPC fields valid for JavaScript callers.
local function json_ok_array(data, field)
    if type(data) ~= "table" or type(data[field]) ~= "table"
        or next(data[field]) ~= nil then
        return json_ok(data)
    end

    local rest = {}
    for key, value in pairs(data) do
        if key ~= field then rest[key] = value end
    end

    local ok, encoded = pcall(cjson.encode, rest)
    if not ok or type(encoded) ~= "string" or encoded:sub(-1) ~= "}" then
        logger.warn("json_ok_array encode failed: " .. tostring(encoded))
        return json_err("serialization error")
    end

    local separator = next(rest) and "," or ""
    return encoded:sub(1, -2) .. separator .. cjson.encode(field) .. ":[]}"
end

-- ── Webkit file management ───────────────────────────────────────────────────

local function copy_webkit_files()
    local steam_dir = steam_utils.detect_steam_install_path()
    if not steam_dir or steam_dir == "" then return end

    local target_webkit_dir = fs.join(steam_dir, "steamui", "webkit")
    if not fs.exists(target_webkit_dir) then
        fs.create_directories(target_webkit_dir)
    end

    local public_dir = fs.join(paths.get_plugin_dir(), "public")

    local src_js = fs.join(public_dir, "luatools.js")
    local dst_js = fs.join(target_webkit_dir, "luatools.js")
    if fs.exists(src_js) then
        local content = m_utils.read_file(src_js)
        if content then m_utils.write_file(dst_js, content) end
    end

    local src_css = fs.join(public_dir, "steamdb-webkit.css")
    local dst_css = fs.join(target_webkit_dir, "steamdb-webkit.css")
    if fs.exists(src_css) then
        local content = m_utils.read_file(src_css)
        if content then m_utils.write_file(dst_css, content) end
    end
end

local function inject_webkit_files()
    millennium.add_browser_css("webkit/steamdb-webkit.css")
    millennium.add_browser_js("webkit/luatools.js")
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

local function on_load()
    logger.log("Bootstrapping LuaTools plugin, millennium " .. millennium.version())
    steam_utils.detect_steam_install_path()
    utils.ensure_temp_download_dir()

    local ok_s, err_s = pcall(settings_manager.init_settings)
    if not ok_s then logger.warn("settings init failed: " .. tostring(err_s)) end

    local ok_u, upd_msg = pcall(auto_update.apply_pending_update_if_any)
    if ok_u and upd_msg and upd_msg ~= "" then
        api_manifest.store_last_message(upd_msg)
    end

    copy_webkit_files()
    inject_webkit_files()

    local res = api_manifest.init_apis()
    logger.log("InitApis (boot) result: " .. tostring(res.message or ""))

    millennium.ready()

    local keys = {}
    for k, v in pairs(millennium) do table.insert(keys, k .. ":" .. type(v)) end
    logger.log("MILLENNIUM KEYS: " .. table.concat(keys, ", "))
end

local function on_unload()
    logger.log("unloading LuaTools plugin")
end

local function on_frontend_loaded()
    logger.log("Frontend loaded")
    copy_webkit_files()
end

-- ── Logger (called as "Logger.log" from JS) ──────────────────────────────────

Logger = {}

function Logger.log(message)
    local msg = type(message) == "table" and tostring(message.message or "") or tostring(message or "")
    logger.log("[Frontend] " .. msg)
    return json_ok({ success = true })
end

function Logger.warn(message)
    local msg = type(message) == "table" and tostring(message.message or "") or tostring(message or "")
    logger.warn("[Frontend] " .. msg)
    return json_ok({ success = true })
end

function Logger.error(message)
    local msg = type(message) == "table" and tostring(message.message or "") or tostring(message or "")
    logger.error("[Frontend] " .. msg)
    return json_ok({ success = true })
end

-- Millennium looks up "Logger.log" as a dotted global key
_G["Logger.log"]   = Logger.log
_G["Logger.warn"]  = Logger.warn
_G["Logger.error"] = Logger.error

-- ── Exported API Methods ─────────────────────────────────────────────────────
-- Every function returns a JSON string, matching the Python backend exactly.

function GetPluginDir()
    return paths.get_plugin_dir() -- plain string, matches Python
end

function InitApis()
    local ok, res = pcall(api_manifest.init_apis)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetInitApisMessage()
    local ok, res = pcall(api_manifest.get_init_apis_message)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function FetchFreeApisNow()
    local ok, res = pcall(api_manifest.fetch_free_apis_now)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function CheckForUpdatesNow()
    local ok, res = pcall(auto_update.check_for_updates_now)
    if not ok then
        logger.warn("CheckForUpdatesNow failed: " .. tostring(res))
        return json_err(res)
    end
    return json_ok(res)
end

function RestartSteam()
    local ok, success = pcall(auto_update.restart_steam)
    if ok and success then
        return json_ok({ success = true })
    end
    return json_ok({ success = false, error = "Failed to restart Steam" })
end

function HasLuaToolsForApp(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, exists = pcall(steam_utils.has_lua_for_app, tonumber(appid))
    if not ok then return json_err(exists) end
    return json_ok({ success = true, exists = exists == true })
end

function StartAddViaLuaTools(appid)
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
end

function GetAddViaLuaToolsStatus(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(downloads.get_add_status, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetApiList()
    local ok, res = pcall(api_manifest.get_api_list)
    if not ok then return json_err(res) end
    return json_ok_array(res, "apis")
end

function AddCustomApi(api_key, contentScriptQuery, name, url)
    -- JS passes: { api_key, contentScriptQuery, name, url }
    -- Reconstruct the payload object for api_manifest
    local payload = {
        name = tostring(name or ""),
        url = tostring(url or ""),
        api_key = tostring(api_key or "")
    }
    local ok, res = pcall(api_manifest.add_custom_api, payload)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetAllApis()
    local ok, res = pcall(api_manifest.get_all_apis)
    if not ok then return json_err(res) end
    return json_ok_array(res, "apis")
end

function ToggleApi(params, contentScriptQuery)
    local apiName = params
    if type(params) == "table" then apiName = params.apiName or params.name end
    local ok, res = pcall(api_manifest.toggle_api, tostring(apiName or ""))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function RemoveApi(params, contentScriptQuery)
    local apiName = params
    if type(params) == "table" then apiName = params.apiName or params.name end
    local ok, res = pcall(api_manifest.remove_api, tostring(apiName or ""))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function RenameApi(params, contentScriptQuery)
    local old_name, new_name
    if type(params) == "table" then
        new_name = params.new_name
        old_name = params.old_name or params.apiName or params.name
    else
        -- If somehow positional
        old_name = params
    end
    local ok, res = pcall(api_manifest.rename_api, tostring(old_name or ""), tostring(new_name or ""))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function ReorderApis(params, contentScriptQuery)
    local names = params
    if type(params) == "table" and params.apiNames then
        names = params.apiNames
    end
    -- Millennium's Lua bridge doesn't deep-deserialize nested JSON arrays/objects
    if type(names) == "string" then
        local ok, parsed = pcall(cjson.decode, names)
        if ok and type(parsed) == "table" then
            names = parsed
        end
    end
    if type(names) ~= "table" then
        return json_ok({ success = false, error = "Invalid argument, got type: " .. type(names) })
    end
    local ok, res = pcall(api_manifest.set_api_order, names)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function CancelAddViaLuaTools(appid)
    -- No-op cancel stub; download is synchronous in Lua
    return json_ok({ success = true })
end

function CheckApisForApp(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(downloads.check_apis_for_app, tonumber(appid))
    if not ok then return json_err(res) end

    return json_ok_array(res, "results")
end

function GetHubcapStats(api_key, force_refresh)
    if type(api_key) == "table" then
        force_refresh = api_key.force_refresh
        api_key = api_key.api_key
    end
    api_key = tostring(api_key or "")
    if api_key == "" then return json_err("api_key required") end
    local endpoint = "https://hubcapmanifest.com/api/v1/user/stats?api_key=" .. api_key
    local ok, resp = pcall(http_client.get, endpoint, { timeout = 10 })
    -- http_client.get returns (nil, err) when the request never reached the
    -- server (DNS/TLS/timeout/refused); a returned table carries the HTTP
    -- status. A valid key answers 200; only 401/403 mean the server actively
    -- rejected the key. Anything else (no response, 5xx, 429, ...) is
    -- "couldn't verify", NOT "your key is bad" -- surface that distinction so
    -- the UI can show the real problem instead of always blaming the key.
    if not ok or type(resp) ~= "table" then
        return json_ok({ success = false, errorType = "unreachable" })
    end
    if resp.status == 200 then
        return resp.body -- already JSON string
    end
    if resp.status == 401 or resp.status == 403 then
        return json_ok({ success = false, errorType = "rejected", status = resp.status })
    end
    return json_ok({ success = false, errorType = "unreachable", status = resp.status })
end

-- Keep the old RPC name callable while installed frontends transition.
GetMorrenusStats = GetHubcapStats

function StartAddViaLuaToolsFromUrl(apiName, appid, contentScriptQuery, url)
    -- Millennium's IPC bridge sorts JS object keys alphabetically and passes their values as positional arguments.
    -- The JS passes: { apiName: ..., appid: ..., contentScriptQuery: "", url: ... }
    -- So the Lua signature MUST be (apiName, appid, contentScriptQuery, url)

    logger.log("StartAddViaLuaToolsFromUrl CALLED: appid=" ..
    tostring(appid) .. ", url=" .. tostring(url) .. ", apiName=" .. tostring(apiName))

    local ok, res = pcall(downloads.start_add_via_luatools_from_url, appid, url, apiName)
    if not ok then
        logger.warn("StartAddViaLuaToolsFromUrl CRASHED inside pcall: " .. tostring(res))
        return json_err(res)
    end

    return json_ok(res)
end

function GetIconDataUrl()
    -- Python read an icon file from the public dir and base64-encoded it
    local icon_path = fs.join(paths.get_plugin_dir(), "public", "luatools-icon.png")
    if fs.exists(icon_path) then
        local content = m_utils.read_file(icon_path)
        if content then
            return json_ok({ success = true, dataUrl = "data:image/png;base64," ..
            (m_utils.base64_encode and m_utils.base64_encode(content) or "") })
        end
    end
    return json_ok({ success = false, error = "icon not found" })
end

function GetGamesDatabase()
    local ok, res = pcall(function()
        local db_path = paths.backend_path("data/applist.json")
        if fs.exists(db_path) then
            local data = utils.read_json(db_path)
            return { success = true, apps = data.apps or data or {} }
        end
        return { success = true, apps = {} }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function ReadLoadedApps()
    local ok, res = pcall(function()
        local log_path = paths.backend_path("loadedappids.txt")
        local apps = {}
        if fs.exists(log_path) then
            local text = utils.read_text(log_path)
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local appid = tonumber(line:match("^%s*(%d+)%s*$"))
                if appid then table.insert(apps, appid) end
            end
        end
        return { success = true, apps = apps }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function DismissLoadedApps()
    local ok, err = pcall(function()
        local log_path = paths.backend_path("loadedappids.txt")
        if fs.exists(log_path) then
            m_utils.write_file(log_path, "")
        end
    end)
    if not ok then return json_err(err) end
    return json_ok({ success = true })
end

function DeleteLuaToolsForApp(appid)
    if type(appid) == "table" then appid = appid.appid end
    local base = steam_utils.detect_steam_install_path()
    local target_dir = fs.join(base, "config", "stplug-in")
    local candidates = {
        fs.join(target_dir, tostring(appid) .. ".lua"),
        fs.join(target_dir, tostring(appid) .. ".lua.disabled"),
    }
    -- slsteammoon: purge this game's archived manifests from SLSsteam's
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
    -- slsteammoon: purge any manifest version pins for the removed script.
    do
        local ok_sls, sls = pcall(require, "slsteam")
        if ok_sls and sls and sls.purge_pins_for_app then
            pcall(sls.purge_pins_for_app, appid)
        end
    end
    return json_ok({ success = true, deleted = deleted, count = #deleted })
end

function CheckForFixes(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixes.check_for_fixes, tonumber(appid))
    if not ok then return json_err(res) end
    -- slsteammoon: augment with the ryuu Crack/Bypass lookup (bundled index +
    -- non-blocking background refresh). Never fails the call.
    pcall(function()
        local crackfix = require("crackfix")
        local home = os.getenv("HOME") or ""
        local plugin_dir = ""
        local okp, paths = pcall(require, "paths")
        if okp and paths and paths.get_plugin_dir then plugin_dir = paths.get_plugin_dir() end
        res.crackFix = crackfix.check(tonumber(appid), {
            cache_path = (home ~= "") and (home .. "/.local/share/Lumen/ryuu_index.json") or nil,
            bundled_path = (plugin_dir ~= "") and (plugin_dir .. "/backend/ryuu_index.json") or nil,
            refresh_script = (plugin_dir ~= "") and (plugin_dir .. "/backend/scripts/ryuu_index.sh") or nil,
        })
    end)
    if type(res) == "table" and type(res.crackFix) ~= "table" then
        res.crackFix = { status = 404, available = false }
    end
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
end

function ApplyGameFix(appid, contentScriptQuery, downloadUrl, fixType, gameName, installPath)
    -- Millennium's IPC bridge sorts JS object keys alphabetically and passes their values as positional arguments.
    -- The JS passes: { appid, contentScriptQuery, downloadUrl, fixType, gameName, installPath }
    -- So the Lua signature MUST be (appid, contentScriptQuery, downloadUrl, fixType, gameName, installPath)

    local ok, res = pcall(fixes.apply_game_fix,
        tonumber(appid), tostring(downloadUrl or ""),
        tostring(installPath or ""), tostring(fixType or ""), tostring(gameName or ""))
    if not ok then
        logger.warn("ApplyGameFix CRASHED: " .. tostring(res))
        return json_err(res)
    end
    return json_ok(res)
end

function ApplySpaceFix(appid, contentScriptQuery)
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
    local ok, res = pcall(fixes.get_apply_status, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function CancelApplyFix(appid)
    return json_ok({ success = true })
end

function ResolveOnlineFix(appid, contentScriptQuery, gameName)
    -- Millennium sorts JS keys: { appid, contentScriptQuery, gameName }.
    if type(appid) == "table" then
        gameName = appid.gameName; appid = appid.appid
    end
    local ok, res = pcall(function()
        local onlinefix = require("onlinefix")
        -- Retry a few times: the mirror is behind Cloudflare and the index
        -- fetch occasionally times out transiently (e.g. right after a Steam
        -- restart). A couple of immediate retries avoids a spurious
        -- "unavailable" on an otherwise-reachable mirror.
        local resp
        for _ = 1, 3 do
            resp = http_client.get("http://api.perondepot.xyz/all/", { timeout = 15 })
            if resp and resp.status == 200 and resp.body then break end
            resp = nil
        end
        if not resp then
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
end

function IsCompatToolForced(appid, contentScriptQuery)
    -- Millennium sorts JS keys: { appid, contentScriptQuery }.
    if type(appid) == "table" then appid = appid.appid end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    -- An online fix is a Windows DLL bundle that only loads under Proton. For
    -- a title that ships a native Linux build the frontend gates Online Fix on
    -- this: true only when the user forced a Proton/compat tool for the game.
    local ok, res = pcall(function()
        local protoncompat = require("protoncompat")
        return { success = true, forced = protoncompat.is_forced(nil, appid) and true or false }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function UninstallFix(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixes.uninstall_fix, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function UnFixGame(appid, installPath, fixDate)
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
        -- slsteammoon: clear the WINEDLLOVERRIDES launch option a Crack/Online
        -- fix added AND any launcher redirect (FC25-style), restoring the
        -- original launch options (the leftover fix DLLs / launcher are inert
        -- without it). The actual write happens in the frontend via the Lumen
        -- relay (SteamClient lives in SharedJSContext), so here we just compute
        -- and return the cleaned value.
        local clearLaunchOptions, launchOptions = false, nil
        do
            local ok_lo, lo = pcall(require, "launchopts")
            local ok_fo, fo = pcall(require, "fix_overlays")
            local ok_lf, lf = pcall(require, "launcherfix")
            if ok_lo and lo and lo.read then
                local current = lo.read(appid) or ""
                local hadOverride = ok_fo and fo and fo.remove_overrides
                    and current:find("WINEDLLOVERRIDES=", 1, true) ~= nil
                local hadRedirect = ok_lf and lf and lf.remove_redirect
                    and lf.remove_redirect(current) ~= current
                if hadOverride or hadRedirect then
                    local cleaned = current
                    if hadOverride then cleaned = fo.remove_overrides(cleaned) end
                    if hadRedirect then cleaned = lf.remove_redirect(cleaned) end
                    launchOptions = cleaned
                    clearLaunchOptions = true
                end
            end
        end
        return { success = true, clearLaunchOptions = clearLaunchOptions, launchOptions = launchOptions }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetUnfixStatus(appid)
    return json_ok({ success = true, state = { status = "done" } })
end

function GetInstalledFixes()
    return json_ok({ success = true, fixes = {} })
end

function GetInstalledLuaScripts()
    local ok, res = pcall(function()
        local base = steam_utils.detect_steam_install_path()
        local target_dir = fs.join(base, "config", "stplug-in")
        local scripts = {}
        local ok2, files = pcall(fs.list, target_dir)
        if ok2 and files then
            for _, entry in ipairs(files) do
                local name = entry.name or ""
                if name:match("%.lua$") or name:match("%.lua%.disabled$") then
                    local aid = name:match("^(%d+)%.")
                    if aid then
                        table.insert(scripts, {
                            appid      = tonumber(aid),
                            gameName   = "Unknown Game (" .. aid .. ")",
                            filename   = name,
                            isDisabled = name:match("%.disabled$") ~= nil,
                            path       = entry.path or ""
                        })
                    end
                end
            end
        end
        return { success = true, scripts = scripts }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetFixLaunchOptions(appid, compatToolName, contentScriptQuery, currentLaunchOptions, installPath)
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
        local launcherfix = require("launcherfix")
        -- Gate on the fix DLLs actually being present in the install dir, NOT
        -- on the frontend compat-tool name: slsteam-moon injects the Proton
        -- CompatToolMapping into appinfo.vdf, so Steam's AppDetails reports an
        -- empty compat tool and is_proton_tool would wrongly skip. The
        -- WINEDLLOVERRIDES is consumed only by Proton/Wine anyway (harmless if
        -- the title somehow runs native).
        local install = tostring(installPath or "")
        local overrides = fix_overlays.overrides_for_install_dir(fs, install)
        -- Some cracks ship their OWN launcher (FC25 Launcher.exe, an unlocker,
        -- ...) that must run INSTEAD of the game's default exe. Redirect the
        -- Play button to it via a Proton launch option. Only a launcher the
        -- crack SHIPPED (recorded in .slssteam_fix_launchers by downloader.sh)
        -- is used, never a game's own pre-existing launcher.exe.
        local launcher = launcherfix.launcher_for_install_dir(install)
        logger.log("GetFixLaunchOptions: appid=" .. tostring(appid)
            .. " compat=" .. tostring(compatToolName)
            .. " installPath=" .. tostring(installPath)
            .. " overrides=" .. tostring(overrides)
            .. " launcher=" .. tostring(launcher))
        if not overrides and not launcher then
            return { success = true, apply = false }
        end
        -- Merge into the user's EXISTING launch options so wrappers like
        -- mangohud/gamemoderun survive. The frontend can't read them (no
        -- SteamClient on the store page; appDetailsStore reads back empty), so
        -- pull the reliable on-disk value from localconfig.vdf when not given.
        local current = tostring(currentLaunchOptions or "")
        if current == "" then
            local ok_lo, lo = pcall(require, "launchopts")
            if ok_lo and lo and lo.read then current = lo.read(tonumber(appid)) or "" end
        end
        -- When the crack ships a launcher, it IS the entry point: it starts the
        -- game the correct way itself. Point Play straight at it (the
        -- "<launcher>" %command% form) and do NOT add WINEDLLOVERRIDES -- the
        -- launcher handles the crack, and forcing those DLLs native can
        -- conflict. Strip any override a prior apply left behind. Otherwise (no
        -- launcher) keep the WINEDLLOVERRIDES merge for the bare DLL crack.
        local merged
        if launcher then
            local base = current
            if fix_overlays.remove_overrides then base = fix_overlays.remove_overrides(base) end
            merged = launcherfix.merge_launch_options(base, launcher)
        else
            merged = fix_overlays.merge_launch_options(current, overrides)
        end
        return { success = true, apply = true, launchOptions = merged, overrides = overrides, launcher = launcher }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetGameInstallPath(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(steam_utils.get_game_install_path_response, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function OpenGameFolder(contentScriptQuery, path)
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
    end
    local ok, success = pcall(steam_utils.open_game_folder, tostring(path or ""))
    if ok and success then
        return json_ok({ success = true })
    end
    return json_ok({ success = false, error = "Failed to open path" })
end

function OpenExternalUrl(contentScriptQuery, url)
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
    end
    url = tostring(url or "")
    if not (url:sub(1, 7) == "http://" or url:sub(1, 8) == "https://") then
        return json_err("Invalid URL")
    end
    local is_win = (m_utils.getenv("OS") or ""):find("Windows") ~= nil
    if is_win then
        pcall(m_utils.exec, 'start "" "' .. url .. '"')
    else
        -- slsteammoon: reset the Steam runtime env and detach so the
        -- system browser launches with system libs (Steam exports a
        -- 32-bit runtime LD_LIBRARY_PATH/LD_AUDIT that crashes spawned
        -- GUI binaries otherwise).
        pcall(m_utils.exec,
            'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; ' ..
            'setsid xdg-open "' .. url .. '" >/dev/null 2>&1 &')
    end
    return json_ok({ success = true })
end

function GetSettingsConfig()
    local ok, payload = pcall(settings_manager.get_settings_payload)
    if not ok then
        logger.warn("GetSettingsConfig failed: " .. tostring(payload))
        return json_err(payload)
    end
    return json_ok({
        success       = true,
        schemaVersion = payload.version,
        schema        = payload.schema or {},
        values        = payload.values or {},
        language      = payload.language,
        locales       = payload.locales or {},
        translations  = payload.translations or {}
    })
end

function GetThemes()
    local themes_json_path = fs.join(paths.get_plugin_dir(), "public", "themes", "themes.json")
    local themes_array = {}

    if fs.exists(themes_json_path) then
        local success, data = pcall(cjson.decode, utils.read_text(themes_json_path))
        if success and type(data) == "table" then
            themes_array = data
        else
            logger.warn("GetThemes failed to decode themes.json")
        end
    else
        logger.warn("GetThemes: themes.json not found")
    end

    return json_ok({ success = true, themes = themes_array })
end

function ApplySettingsChanges(changes)
    -- Millennium may pass the argument as a JSON string rather than a decoded table.
    -- Mirror the Python version's parsing logic exactly.
    local payload = nil

    if type(changes) == "string" and changes ~= "" then
        -- Try to decode the JSON string
        local ok, decoded = pcall(cjson.decode, changes)
        if not ok then
            logger.warn("ApplySettingsChanges: failed to parse changes string")
            return json_err("Invalid JSON payload")
        end
        -- Unwrap nested wrappers the JS bridge sometimes adds
        if type(decoded) == "table" and decoded.changes then
            payload = decoded.changes
        elseif type(decoded) == "table" and type(decoded.changesJson) == "string" then
            local ok2, inner = pcall(cjson.decode, decoded.changesJson)
            if ok2 then payload = inner else return json_err("Invalid JSON payload") end
        else
            payload = decoded
        end
    elseif type(changes) == "table" then
        -- Already a decoded table – handle wrapper keys
        if changes.changes then
            payload = changes.changes
        elseif type(changes.changesJson) == "string" then
            local ok2, inner = pcall(cjson.decode, changes.changesJson)
            if ok2 then payload = inner else return json_err("Invalid JSON payload") end
        else
            payload = changes
        end
    else
        payload = {}
    end

    if payload == nil then payload = {} end

    if type(payload) ~= "table" then
        logger.warn("ApplySettingsChanges: payload is not a table: " .. tostring(payload))
        return json_err("Invalid payload format")
    end

    logger.log("ApplySettingsChanges payload: " .. (pcall(cjson.encode, payload) and cjson.encode(payload) or "?"))

    local ok, res = pcall(settings_manager.apply_settings_changes, payload)
    if not ok then
        logger.warn("ApplySettingsChanges failed: " .. tostring(res))
        return json_err(res)
    end
    return json_ok(res)
end

function GetAvailableLocales()
    local ok, locs = pcall(settings_manager.get_available_locales)
    if not ok then return json_err(locs) end
    return json_ok({ success = true, locales = locs })
end

function GetTranslations(language)
    -- Handle both {language="en"} table and plain string argument
    if type(language) == "table" then
        language = language.language or language.lang
    end
    language = tostring(language or locales_mod.DEFAULT_LOCALE)

    local ok, strings = pcall(function()
        return locales_mod.get_locale_manager():get_locale_strings(language)
    end)
    if not ok then
        logger.warn("GetTranslations failed: " .. tostring(strings))
        return json_err(strings)
    end

    -- Frontend expects: { success, strings:{...}, language, locales:[...] }
    local ok2, locs = pcall(settings_manager.get_available_locales)
    return json_ok({
        success  = true,
        strings  = strings or {},
        language = language,
        locales  = ok2 and locs or {}
    })
end

function GetAvailableThemes()
    return json_ok({ success = true, themes = {} })
end

-- ── Return lifecycle table ────────────────────────────────────────────────────

return {
    on_load            = on_load,
    on_unload          = on_unload,
    on_frontend_loaded = on_frontend_loaded,
}
