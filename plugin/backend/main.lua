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
local ryuu_auth        = require("ryuu_auth")
local lua_tools_auth   = require("lua_tools_auth")
local lua_tools_fixes  = require("lua_tools_fixes")
local lua_tools_fix_index = require("lua_tools_fix_index")
local lua_tools_fix_state = require("lua_tools_fix_state")
local lua_tools_recommended_add = require("lua_tools_recommended_add")
local lua_tools_auto_fix = require("lua_tools_auto_fix")
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

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function url_encode(value)
    return (tostring(value or ""):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
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

local function decode_rpc_table(raw)
    if type(raw) == "table" then return raw end
    if type(raw) ~= "string" then return nil end
    local ok, decoded = pcall(cjson.decode, raw)
    return ok and type(decoded) == "table" and decoded or nil
end

local function on_tick(now, controls)
    controls = type(controls) == "table" and controls or {}
    return lua_tools_auto_fix.tick(now, {
        auth_status = function()
            local ok, status = pcall(lua_tools_auth.status)
            return ok and status or { configured = false }
        end,
        install_state = function(appid)
            local state = steam_utils.get_game_install_state(appid)
            if type(state) == "table" and state.complete == true
                and type(controls.is_app_busy) == "function" then
                state.postInstallBusy = controls.is_app_busy(appid) == true
            end
            return state
        end,
        recommended_build_ready = function(appid)
            local ok_module, manifestpins = pcall(require, "manifestpins")
            if not ok_module or type(manifestpins) ~= "table"
                or type(manifestpins.app_at_pinned_gids) ~= "function" then
                return false
            end
            return manifestpins.app_at_pinned_gids(
                manifestpins.default_ctx(), appid) == true
        end,
        is_busy = function(appid)
            return lua_tools_fix_state.get_pending(appid) ~= nil
        end,
        start_fix = function(appid, fix_id)
            return decode_rpc_table(StartLuaToolsFix({
                appid = appid,
                fixId = fix_id,
                gameName = "",
                installPath = "",
                contentScriptQuery = "",
            })) or { success = false, errorCode = "start_failed" }
        end,
        poll_fix = function(appid)
            return decode_rpc_table(GetApplyFixStatus({ appid = appid,
                contentScriptQuery = "" }))
                or { success = false, state = { status = "failed",
                    errorCode = "status_failed" } }
        end,
        launch_options = function(appid)
            local install = steam_utils.get_game_install_path_response(appid)
            if type(install) ~= "table" or install.success ~= true then
                return { success = false, errorCode = "not_installed",
                    error = type(install) == "table" and install.error
                        or "Game is not installed." }
            end
            return decode_rpc_table(GetFixLaunchOptions({
                appid = appid,
                compatToolName = "",
                currentLaunchOptions = "",
                installPath = install.installPath,
                contentScriptQuery = "",
            })) or { success = false, errorCode = "launch_options_failed" }
        end,
        set_launch_options = function(appid, options)
            return type(controls.set_launch_options) == "function"
                and controls.set_launch_options(appid, options) == true
        end,
        complete_fix = function(appid, fix_id)
            return decode_rpc_table(CompleteLuaToolsFixApply({
                appid = appid,
                fixId = fix_id,
                contentScriptQuery = "",
            })) or { success = false, errorCode = "complete_failed" }
        end,
    })
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

function StartAddViaLuaToolsSource(appid, contentScriptQuery, sourceName)
    if type(appid) == "table" then
        sourceName = appid.sourceName or appid.source
        appid = appid.appid
    end
    local ok, res = pcall(downloads.start_add_via_luatools_source,
        tonumber(appid), tostring(sourceName or ""))
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

function StartGameDraft(params)
    local appid = type(params) == "table" and params.appid or params
    local ok, res = pcall(downloads.start_game_draft, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
end

function GetGameDraftStatus(params, session)
    local appid = params
    if type(params) == "table" then
        appid, session = params.appid, params.session
    end
    local ok, res = pcall(downloads.get_game_draft_status,
        tonumber(appid), tostring(session or ""))
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- Keep source manifests inside the local backend process. The browser passes
-- only two private session identifiers; LuaTools reads its validated draft and
-- Lumen attaches the full snapshot to the staged import transaction.
function EnrichGameImportFromDraft(params, import_session, draft_session)
    local appid = params
    if type(params) == "table" then
        appid = params.appid
        import_session = params.importSession or params.import_session
        draft_session = params.draftSession or params.draft_session
    end
    appid = tonumber(appid)
    if not appid or type(import_session) ~= "string"
        or type(draft_session) ~= "string" then
        return json_err("Invalid draft handoff")
    end
    local snapshot_ok, snapshot = pcall(
        downloads.get_game_draft_snapshot, appid, draft_session)
    if not snapshot_ok then return json_err(snapshot) end
    if type(snapshot) ~= "table" or snapshot.success ~= true then
        return json_err(type(snapshot) == "table" and snapshot.error
            or "Draft is not ready")
    end
    local loaded, manifestpins = pcall(require, "manifestpins")
    if not loaded or type(manifestpins) ~= "table"
        or type(manifestpins.enrich_game_import_snapshot) ~= "function" then
        return json_err("Lumen import handoff is unavailable")
    end
    local called, attached, result = pcall(
        manifestpins.enrich_game_import_snapshot,
        manifestpins.default_ctx(), import_session, appid, snapshot)
    if not called then return json_err(attached) end
    if not attached then return json_err(result) end
    result = type(result) == "table" and result or {}
    result.success = true
    return json_ok(result)
end

-- Lumen/Millennium passes object values alphabetically: appid, editsJson,
-- session. Keep this signature in that exact order.
function CommitGameDraft(params, edits, session)
    local appid = params
    if type(params) == "table" then
        appid, session = params.appid, params.session
        edits = params.edits or params.editsJson
    end
    if type(edits) == "string" then
        local decoded, value = pcall(cjson.decode, edits)
        if not decoded or type(value) ~= "table" then return json_err("Invalid draft edits") end
        edits = value
    end
    local ok, res = pcall(downloads.commit_game_draft,
        tonumber(appid), tostring(session or ""), edits)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function CancelGameDraft(params, session)
    local appid = params
    if type(params) == "table" then
        appid, session = params.appid, params.session
    end
    local ok, res = pcall(downloads.cancel_game_draft,
        tonumber(appid), tostring(session or ""))
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- Lumen/Millennium sorts { language, query } alphabetically and passes the
-- values positionally. Keep this signature in that order.
function SearchSteamGames(language, query)
    if type(language) == "table" then
        query, language = language.query, language.language
    end
    query = trim(query)
    if query == "" then return json_err("Search query is required") end
    if #query > 160 then query = query:sub(1, 160) end

    local endpoint = "https://steamcommunity.com/actions/SearchApps/"
        .. url_encode(query)
    local ok_request, response = pcall(http_client.get, endpoint, {
        timeout = 8, max_bytes = 512 * 1024,
    })
    if not ok_request or type(response) ~= "table" or response.status ~= 200
        or type(response.body) ~= "string" then
        return json_err("Steam catalog is unavailable")
    end
    local ok_decode, payload = pcall(cjson.decode, response.body)
    if not ok_decode or type(payload) ~= "table" then
        return json_err("Steam catalog returned invalid data")
    end

    local items = {}
    for _, item in ipairs(payload) do
        local id = tonumber(type(item) == "table" and item.appid or nil)
        if type(item) == "table" and id and id > 0 and id % 1 == 0 then
            items[#items + 1] = {
                id = id,
                name = trim(item.name) ~= "" and trim(item.name) or ("App " .. tostring(id)),
                tiny_image = type(item.logo) == "string" and item.logo
                    or (type(item.icon) == "string" and item.icon or ""),
                type = "app",
            }
            if #items >= 8 then break end
        end
    end
    return json_ok_array({ success = true, items = items }, "items")
end

local function unavailable_app_details(appid)
    return json_ok_array({
        success = true,
        appid = appid,
        metadataAvailable = false,
        dlc = {},
    }, "dlc")
end

local function fetch_global_appinfo(endpoint)
    for _ = 1, 2 do
        local ok_request, response = pcall(http_client.get, endpoint, {
            timeout = 8, max_bytes = 4 * 1024 * 1024,
        })
        if ok_request and type(response) == "table" and response.status == 200
            and type(response.body) == "string" then
            return response
        end
        if ok_request and type(response) == "table"
            and tonumber(response.status) and response.status >= 400
            and response.status < 500 then
            break
        end
    end
    return nil
end

function GetSteamAppDetails(params)
    local appid = type(params) == "table" and params.appid or params
    appid = tonumber(appid)
    if not appid or appid <= 0 or appid % 1 ~= 0 then
        return json_err("Invalid appid")
    end

    local endpoint = "https://api.steamcmd.net/v1/info/" .. tostring(appid)
    local response = fetch_global_appinfo(endpoint)
    if not response then return unavailable_app_details(appid) end
    local ok_decode, payload = pcall(cjson.decode, response.body)
    if not ok_decode or type(payload) ~= "table" then
        return unavailable_app_details(appid)
    end

    local data = type(payload.data) == "table" and payload.data[tostring(appid)] or nil
    local common = type(data) == "table" and data.common or nil
    if type(common) ~= "table" then return unavailable_app_details(appid) end

    if type(common.type) ~= "string" then return unavailable_app_details(appid) end
    local app_type = trim(common.type):lower()
    if app_type == "" then return unavailable_app_details(appid) end
    local parent = tonumber(common.parent)
    if not parent or parent <= 0 or parent % 1 ~= 0 or parent == appid then parent = nil end

    local dlc, seen = {}, {}
    local extended = type(data.extended) == "table" and data.extended or {}
    for raw_id in tostring(extended.listofdlc or ""):gmatch("[^,%s]+") do
        local id = tonumber(raw_id)
        if id and id > 0 and id % 1 == 0 and id ~= appid and not seen[id] then
            dlc[#dlc + 1], seen[id] = id, true
        end
    end
    table.sort(dlc)

    return json_ok_array({
        success = true,
        appid = appid,
        name = type(common.name) == "string" and trim(common.name) ~= ""
            and trim(common.name) or ("App " .. tostring(appid)),
        type = app_type,
        fullgameAppid = parent,
        metadataAvailable = true,
        dlc = dlc,
    }, "dlc")
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
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(downloads.cancel_add, tonumber(appid))
    if not ok then return json_err(res) end
    return json_ok(res)
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

function StartAddViaLuaToolsFromUrl(apiName, appid, contentScriptQuery, successCode, url)
    -- Millennium's IPC bridge sorts JS object keys alphabetically and passes their values as positional arguments.
    -- New clients also pass successCode. Keep the four-argument layout working
    -- while frontends update: in that form the URL arrives in argument four.
    if url == nil then url, successCode = successCode, nil end

    logger.log("StartAddViaLuaToolsFromUrl CALLED: appid=" ..
    tostring(appid) .. ", apiName=" .. tostring(apiName))

    local ok, res = pcall(downloads.start_add_via_luatools_from_url,
        appid, url, apiName, successCode)
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
    appid = tonumber(appid)
    if not appid or appid <= 0 or appid ~= math.floor(appid) then
        return json_err("invalid appid")
    end

    local base_ok, base = pcall(steam_utils.detect_steam_install_path)
    if not base_ok or type(base) ~= "string" or base == "" then
        return json_err("Steam install path unavailable")
    end

    local target_dir = fs.join(base, "config", "stplug-in")
    local candidates = {
        fs.join(target_dir, tostring(appid) .. ".lua"),
        fs.join(target_dir, tostring(appid) .. ".lua.disabled"),
    }
    local failures = {}
    local function fail(stage, detail)
        failures[#failures + 1] = stage .. ": " .. tostring(detail or "operation failed")
    end

    -- Cleanup must finish before removing the source script. The script is
    -- the only durable record of the depot list used by manifest cleanup, and
    -- retaining it makes a failed operation retryable from the UI.
    local helper_ok, sls = pcall(require, "slsteam")
    if not helper_ok or type(sls) ~= "table" then
        fail("slsteam helper", sls or "unavailable")
    else
        if type(sls.purge_store_for_lua) ~= "function" then
            fail("manifest store cleanup", "helper unavailable")
        else
            for _, path in ipairs(candidates) do
                local call_ok, operation_ok, detail =
                    pcall(sls.purge_store_for_lua, path)
                if not call_ok then
                    fail("manifest store cleanup", operation_ok)
                elseif operation_ok ~= true then
                    fail("manifest store cleanup", detail)
                end
            end
        end

        if type(sls.purge_pins_for_app) ~= "function" then
            fail("manifest pin cleanup", "helper unavailable")
        else
            local call_ok, operation_ok, detail =
                pcall(sls.purge_pins_for_app, appid)
            if not call_ok then
                fail("manifest pin cleanup", operation_ok)
            elseif operation_ok ~= true then
                fail("manifest pin cleanup", detail)
            end
        end
    end

    local cacheForgotten = 0
    if helper_ok and type(sls) == "table" and type(sls.forget_app) == "function" then
        local call_ok, operation_ok, detail, moved =
            pcall(sls.forget_app, appid)
        if not call_ok then
            fail("app cache cleanup", operation_ok)
        elseif operation_ok ~= true then
            cacheForgotten = tonumber(moved) or 0
            fail("app cache cleanup", detail)
        else
            cacheForgotten = tonumber(detail) or 0
        end
    elseif helper_ok then
        fail("app cache cleanup", "helper unavailable")
    end

    local deleted = {}
    if #failures == 0 then
        for _, path in ipairs(candidates) do
            local exists_ok, exists = pcall(fs.exists, path)
            if not exists_ok then
                fail("script inspection", exists)
            elseif exists then
                local remove_ok, removed, remove_error = pcall(fs.remove, path)
                local after_ok, remains = pcall(fs.exists, path)
                if not remove_ok then
                    fail("script removal", removed)
                elseif removed ~= true then
                    fail("script removal", remove_error or "remove failed")
                elseif not after_ok then
                    fail("script inspection", remains)
                elseif remains then
                    fail("script removal", "file remains after remove")
                else
                    deleted[#deleted + 1] = path
                end
            end
        end
    end

    local response = {
        success = #failures == 0,
        deleted = deleted,
        count = #deleted,
        cacheForgotten = cacheForgotten,
    }
    if #failures > 0 then response.error = table.concat(failures, "; ") end
    return json_ok(response)
end

function CheckForFixes(appid)
    if type(appid) == "table" then appid = appid.appid end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    local res = {
        success = true,
        appid = appid,
        gameName = "Unknown Game (" .. tostring(appid) .. ")",
        genericFix = { status = 404, available = false },
        onlineFix = { status = 404, available = false },
    }
    -- The official lua.tools catalogue supersedes Ryuu for this surface. The
    -- public response contains metadata only; bearer tokens and signed download
    -- URLs stay in lua_tools_fixes and never cross the RPC boundary.
    local ok_official, official = pcall(lua_tools_fixes.get_game, appid)
    if not ok_official or type(official) ~= "table" then
        official = { success = false, available = false, fixes = {} }
    end
    local applied_receipt = lua_tools_fix_state.get_applied(appid)
    local applied_sources = lua_tools_fix_state.applied_sources(applied_receipt)
    lua_tools_fix_state.decorate_game(official, applied_receipt)
    res.luaToolsFixes = official
    res.fallbackOnlineApplied = applied_sources.fallbackOnline
    local ok_sls, sls = pcall(require, "slsteam")
    res.spacewarApplied = ok_sls and sls and sls.get_fake_appid
        and sls.get_fake_appid(appid) == 480 or false
    if official.name and official.name ~= "" then res.gameName = official.name end
    local recommended = official.recommended
    if type(recommended) == "table" then
        res.crackFix = {
            status = 200,
            available = true,
            fixId = recommended.id,
            title = recommended.title,
            category = recommended.category,
            tags = recommended.tags,
            requiresPreparation = recommended.requiresPreparation == true,
            requiresAuth = true,
            authConfigured = official.authConfigured == true,
            hasManifest = recommended.hasManifest == true,
            hasFix = recommended.hasFix == true,
            manifestFilename = recommended.manifestFilename,
            fixFilename = recommended.fixFilename,
        }
    else
        res.crackFix = {
            status = 404,
            available = false,
            requiresAuth = true,
            authConfigured = official.authConfigured == true,
        }
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

function ApplyGameFix(appid, contentScriptQuery, downloadUrl, fixType, gameName, installPath, receiptKind)
    -- Millennium's IPC bridge sorts JS object keys alphabetically and passes
    -- their values positionally. receiptKind is a stable internal identifier;
    -- user-visible/localized fixType is never used as persisted identity.

    if type(appid) == "table" then
        local payload = appid
        appid, downloadUrl = payload.appid, payload.downloadUrl
        fixType, gameName = payload.fixType, payload.gameName
        installPath, receiptKind = payload.installPath, payload.receiptKind
    end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    local tracks_fallback = tostring(receiptKind or "") == "online_fix_fallback"
    if tracks_fallback then
        pcall(lua_tools_fix_state.abort, appid)
        if not lua_tools_fix_state.begin_fallback_online(appid) then
            return json_ok({ success = false, errorCode = "state_write_failed",
                error = "Could not save the fallback fix application state." })
        end
    end

    local ok, res = pcall(fixes.apply_game_fix,
        appid, tostring(downloadUrl or ""),
        tostring(installPath or ""), tostring(fixType or ""), tostring(gameName or ""))
    if not ok then
        if tracks_fallback then pcall(lua_tools_fix_state.abort, appid) end
        logger.warn("ApplyGameFix CRASHED: " .. tostring(res))
        return json_err(res)
    end
    if tracks_fallback and (type(res) ~= "table" or res.success ~= true) then
        pcall(lua_tools_fix_state.abort, appid)
    elseif tracks_fallback and type(res) == "table" then
        res.fixId = "online-fix-fallback"
    end
    return json_ok(res)
end

function GetLuaToolsAuthStatus()
    local ok, status = pcall(lua_tools_auth.status)
    if not ok then return json_err(status) end
    return json_ok(status)
end

function LoginLuaToolsWithCode(code, contentScriptQuery)
    if type(code) == "table" then code = code.code end
    local ok, status = pcall(lua_tools_auth.sign_in_with_code, tostring(code or ""))
    if not ok then return json_err(status) end
    return json_ok(status)
end

function AdoptLuaToolsSessionValue(contentScriptQuery, session)
    if type(contentScriptQuery) == "table" then
        session = contentScriptQuery.session or contentScriptQuery.cookie
    end
    local ok, status = pcall(lua_tools_auth.sign_in_with_session, tostring(session or ""))
    if not ok then return json_err(status) end
    return json_ok(status)
end

function StartLuaToolsDiscordLogin()
    local ok, status = pcall(lua_tools_auth.begin_pkce)
    if not ok then return json_err(status) end
    return json_ok(status)
end

function PollLuaToolsDiscordLogin()
    local ok, status = pcall(lua_tools_auth.poll_pkce)
    if not ok then return json_err(status) end
    return json_ok(status)
end

function CancelLuaToolsDiscordLogin()
    local ok, status = pcall(lua_tools_auth.cancel_pkce)
    if not ok then return json_err(status) end
    return json_ok(status)
end

function LogoutLuaTools()
    local ok, status = pcall(lua_tools_auth.clear)
    if not ok then return json_err(status) end
    return json_ok(status)
end

function GetLuaToolsFixesCatalogue()
    local ok_auth, auth_status = pcall(lua_tools_auth.status)
    if not ok_auth then return json_err(auth_status) end
    if type(auth_status) ~= "table" or auth_status.configured ~= true then
        return json_ok_array({ success = true, authRequired = true, games = {} }, "games")
    end
    local ok, result = pcall(lua_tools_fixes.list_games)
    if not ok then return json_err(result) end
    result.authRequired = false
    return json_ok_array(result, "games")
end

function GetLuaToolsAddRecommendation(appid)
    if type(appid) == "table" then appid = appid.appid end
    appid = tonumber(appid)
    if not appid or appid <= 0 or appid ~= math.floor(appid) then
        return json_err("invalid appid")
    end
    local ok_auth, auth_status = pcall(lua_tools_auth.status)
    if not ok_auth then return json_err(auth_status) end
    local configured = type(auth_status) == "table" and auth_status.configured == true
    local ok_index, result = pcall(lua_tools_fix_index.recommendation,
        appid, configured)
    if not ok_index then return json_err(result) end
    return json_ok(result)
end

function CancelLuaToolsAutoFix(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, result = pcall(lua_tools_auto_fix.cancel, tonumber(appid))
    if not ok then return json_err(result) end
    return json_ok(result)
end

function StartLuaToolsRecommendedAdd(appid, auto_apply, content_script_query, fix_id)
    local payload = type(appid) == "table" and appid or {
        appid = appid,
        autoApply = auto_apply,
        contentScriptQuery = content_script_query,
        fixId = fix_id,
    }
    local ok, result = pcall(lua_tools_recommended_add.start,
        tonumber(payload.appid), tostring(payload.fixId or ""),
        payload.autoApply == true, {
            availability = function(check_appid, lua_body, steam_root)
                local ok_module, manifestpins = pcall(require, "manifestpins")
                if not ok_module or type(manifestpins) ~= "table"
                    or type(manifestpins.recommended_manifest_availability)
                        ~= "function" then
                    return nil
                end
                local ctx = manifestpins.default_ctx()
                ctx.steam_root = steam_root
                return manifestpins.recommended_manifest_availability(
                    ctx, check_appid, lua_body, steam_root)
            end,
            publish = function(publish_appid, lua_body, steam_root)
                local ok_module, manifestpins = pcall(require, "manifestpins")
                if not ok_module or type(manifestpins) ~= "table"
                    or type(manifestpins.install_luatools_manifest) ~= "function" then
                    return false, "manifest_pin_unavailable"
                end
                local ctx = manifestpins.default_ctx()
                ctx.stplug_dir = tostring(steam_root):gsub("/+$", "")
                    .. "/config/stplug-in"
                return manifestpins.install_luatools_manifest(
                    ctx, publish_appid, lua_body)
            end,
            queue = function(queued_appid, fix_id)
                return lua_tools_auto_fix.queue(queued_appid, fix_id)
            end,
        })
    if not ok then return json_err(result) end
    return json_ok(result)
end

function GetLuaToolsFixesForGame(appid)
    if type(appid) == "table" then appid = appid.appid end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    local ok_auth, auth_status = pcall(lua_tools_auth.status)
    if not ok_auth then return json_err(auth_status) end
    if type(auth_status) ~= "table" or auth_status.configured ~= true then
        return json_ok({ success = true, authRequired = true, appid = appid, fixes = {} })
    end
    local ok, game = pcall(lua_tools_fixes.get_game, appid)
    if not ok then return json_err(game) end
    lua_tools_fix_state.decorate_game(game, lua_tools_fix_state.get_applied(appid))
    game.authRequired = false
    return json_ok_array(game, "fixes")
end

function StartLuaToolsFix(appid, contentScriptQuery, fixId, gameName, installPath)
    if type(appid) == "table" then
        local payload = appid
        appid, fixId = payload.appid, payload.fixId
        gameName, installPath = payload.gameName, payload.installPath
    end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end

    local ok_game, game = pcall(lua_tools_fixes.get_game, appid)
    if not ok_game or type(game) ~= "table" then return json_err(game) end
    local selected
    for _, candidate in ipairs(type(game.fixes) == "table" and game.fixes or {}) do
        if candidate.id == tostring(fixId or ""):lower() then selected = candidate; break end
    end
    if not selected or (selected.hasFix ~= true and selected.hasManifest ~= true) then
        return json_ok({ success = false, errorCode = "unavailable",
            error = "This lua.tools fix has no downloadable files." })
    end
    if selected.requiresPreparation == true then
        return json_ok({ success = false, errorCode = "preparation_required",
            error = "DenuvOwO preparation is not configured on this Linux system yet." })
    end

    -- Never trust a frontend-provided extraction directory. Resolve the game
    -- library path from Steam's own appmanifest for this exact AppID.
    local ok_install, install = pcall(steam_utils.get_game_install_path_response, appid)
    if not ok_install or type(install) ~= "table" or install.success ~= true
        or type(install.installPath) ~= "string" or install.installPath == "" then
        return json_ok({ success = false, errorCode = "not_installed",
            error = type(install) == "table" and install.error or "Game is not installed." })
    end

    local fix_download, manifest_download
    for _, slot in ipairs({ "fix", "manifest" }) do
        if (slot == "fix" and selected.hasFix == true)
            or (slot == "manifest" and selected.hasManifest == true) then
            local ok_resolve, download, download_error = pcall(
                lua_tools_fixes.resolve_download, selected.id, slot)
            if not ok_resolve then return json_err(download) end
            if not download then
                return json_ok({ success = false,
                    errorCode = type(download_error) == "table" and download_error.code or "download_unavailable",
                    error = type(download_error) == "table" and download_error.message or "Download unavailable." })
            end
            if slot == "fix" then fix_download = download else manifest_download = download end
        end
    end

    local staged_manifest = ""
    if manifest_download then
        local ok_fetch, response = pcall(http_client.get, manifest_download.url, {
            timeout = 60,
            max_bytes = 2 * 1024 * 1024,
        })
        if not ok_fetch or type(response) ~= "table" or tonumber(response.status) ~= 200
            or type(response.body) ~= "string" then
            return json_ok({ success = false, errorCode = "manifest_download_failed",
                error = "The lua.tools manifest could not be downloaded." })
        end
        local staged, stage_error = lua_tools_fix_state.stage_manifest(
            appid, response.body, utils.ensure_temp_download_dir())
        if not staged then
            return json_ok({ success = false, errorCode = stage_error,
                error = "The lua.tools manifest is invalid for this game." })
        end
        staged_manifest = staged
    end

    -- A prior interrupted reapply never replaces its completed receipt. Drop
    -- only its private staging transaction before starting the new one.
    pcall(lua_tools_fix_state.abort, appid)
    if not lua_tools_fix_state.begin(appid, selected, staged_manifest) then
        if staged_manifest ~= "" then pcall(os.remove, staged_manifest) end
        return json_ok({ success = false, errorCode = "state_write_failed",
            error = "Could not save the fix application state." })
    end

    local ok_apply, result
    if fix_download then
        ok_apply, result = pcall(fixes.apply_game_fix, appid, fix_download.url,
            install.installPath, "lua.tools", tostring(gameName or game.name or ""))
    else
        ok_apply, result = pcall(fixes.mark_apply_ready, appid)
    end
    if not ok_apply then
        pcall(lua_tools_fix_state.abort, appid)
        return json_err(result)
    end
    if type(result) ~= "table" or result.success ~= true then
        pcall(lua_tools_fix_state.abort, appid)
    end
    if type(result) == "table" then
        result.fixId = selected.id
        result.category = selected.category
    end
    return json_ok(result)
end

function CompleteLuaToolsFixApply(appid, contentScriptQuery, fixId)
    if type(appid) == "table" then fixId = appid.fixId; appid = appid.appid end
    appid = tonumber(appid)
    if not appid then return json_err("invalid appid") end
    local completed = lua_tools_fix_state.complete(appid, tostring(fixId or ""))
    if not completed then
        return json_ok({ success = false, errorCode = "not_ready",
            error = "The selected fix has not finished applying." })
    end
    return json_ok({ success = true, appliedFix = lua_tools_fix_state.get_applied(appid) })
end

function GetRyuuAuthStatus()
    local ok, status = pcall(ryuu_auth.status)
    if not ok then return json_err(status) end
    status.success = true
    return json_ok(status)
end

function SaveRyuuAuthCredential(contentScriptQuery, credential)
    local ok, status, err = pcall(ryuu_auth.save, tostring(credential or ""))
    if not ok then return json_err(status) end
    if not status then return json_err(err or "Invalid Ryuu authentication.") end
    status.success = true
    return json_ok(status)
end

-- Adopt the session cookie Steam's own browser holds after the in-client Ryuu
-- login. Called by Lumen's injector with a value read from the CEF cookie jar,
-- never by JavaScript: the secret stays inside Lua.
function AdoptRyuuSessionValue(contentScriptQuery, session)
    local ok, status, err = pcall(ryuu_auth.adopt_session_value, tostring(session or ""))
    if not ok then return json_err(status) end
    if not status then return json_err(err or "Ryuu has not accepted this session yet.") end
    status.success = true
    return json_ok(status)
end

function ClearRyuuAuthCredential()
    local ok, removed = pcall(ryuu_auth.clear)
    if not ok then return json_err(removed) end
    if not removed then return json_err("Could not remove Ryuu authentication.") end
    return json_ok({ success = true, configured = false })
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
    if type(res) == "table" and type(res.state) == "table" then
        if res.state.status == "done" then
            local pending = lua_tools_fix_state.get_pending(tonumber(appid))
            if pending then
                local installed, install_error = lua_tools_fix_state.install_staged_manifest(
                    tonumber(appid), steam_utils.detect_steam_install_path())
                if not installed then
                    pcall(lua_tools_fix_state.abort, tonumber(appid))
                    return json_ok({ success = true, state = {
                        status = "failed", errorCode = install_error,
                        error = "The fix files were extracted, but the Lua manifest could not be installed.",
                    } })
                end
                res.state.fixId = pending.fixId
                res.state.category = pending.category
            end
        elseif res.state.status == "failed" or res.state.status == "cancelled" then
            pcall(lua_tools_fix_state.abort, tonumber(appid))
        end
    end
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
        -- The mirror is a third party and its response time varies wildly (0.3s
        -- from one machine, 23s from another at the same moment). This handler
        -- runs inside Lumen's single-threaded loop, so a slow mirror used to
        -- freeze every other RPC — a Crack/Bypass click just queued behind it.
        -- onlinefix.fetch_index caches, bounds the wait, and prefers a stale
        -- index over hanging. See scripts/test-onlinefix.lua (X1..X10).
        local cache_path = paths.backend_path("data/onlinefix_index.json")
        local body = onlinefix.fetch_index({
            get = function(url, opts) return http_client.get(url, opts) end,
            read = function()
                local raw = m_utils.read_file(cache_path)
                if not raw or raw == "" then return nil end
                local ok_decode, decoded = pcall(cjson.decode, raw)
                if not ok_decode or type(decoded) ~= "table" then return nil end
                return decoded
            end,
            write = function(index_body)
                local ok_encode, encoded = pcall(cjson.encode,
                    { at = os.time(), body = index_body })
                if ok_encode then m_utils.write_file(cache_path, encoded) end
                return true
            end,
        })
        if not body then
            error("online-fix index unavailable")
        end
        local entry = onlinefix.find_fix(body, tostring(gameName or ""))
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
        local applied_receipt = lua_tools_fix_state.get_applied(appid)
        if type(applied_receipt) == "table"
            and tostring(applied_receipt.manifestFilename or "") ~= "" then
            local steam_root = steam_utils.detect_steam_install_path()
            if steam_root and steam_root ~= "" then
                pcall(fs.remove, fs.join(steam_root, "config", "stplug-in",
                    tostring(appid) .. ".lua"))
            end
        end
        pcall(lua_tools_fix_state.clear, appid)
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
        local launcher, launcher_rel = launcherfix.launcher_for_install_dir(install)
        logger.log("GetFixLaunchOptions: appid=" .. tostring(appid)
            .. " compat=" .. tostring(compatToolName)
            .. " installPath=" .. tostring(installPath)
            .. " overrides=" .. tostring(overrides)
            .. " launcher=" .. tostring(launcher)
            .. " launcherRel=" .. tostring(launcher_rel))
        -- Merge into the user's EXISTING launch options so wrappers like
        -- mangohud/gamemoderun survive. The frontend can't read them (no
        -- SteamClient on the store page; appDetailsStore reads back empty), so
        -- pull the reliable on-disk value from localconfig.vdf when not given.
        local current = tostring(currentLaunchOptions or "")
        if current == "" then
            local ok_lo, lo = pcall(require, "launchopts")
            if ok_lo and lo and lo.read then current = lo.read(tonumber(appid)) or "" end
        end
        -- A newer inference pass can legitimately decide that a previously
        -- generated override is unnecessary (for example OnlineFix+steam_api,
        -- which Wine already loads natively). Reapplying must remove that stale
        -- block instead of returning early and leaving the old launch options.
        if not overrides and not launcher then
            local cleaned = fix_overlays.remove_overrides
                and fix_overlays.remove_overrides(current) or current
            if cleaned ~= current then
                return { success = true, apply = true, launchOptions = cleaned }
            end
            return { success = true, apply = false }
        end
        -- When the crack ships a launcher, it IS the entry point: it starts the
        -- game the correct way itself. Preserve Proton's generated argv and
        -- replace only its final executable with the game-relative launcher.
        -- Do NOT add WINEDLLOVERRIDES: the launcher handles the fix, and forcing
        -- those DLLs native can conflict. Strip any override a prior apply left
        -- behind. Otherwise keep the override merge for the bare DLL fix.
        local merged
        if launcher then
            local base = current
            if fix_overlays.remove_overrides then base = fix_overlays.remove_overrides(base) end
            merged = launcherfix.merge_launch_options(base, launcher_rel)
        else
            merged = fix_overlays.merge_launch_options(current, overrides)
        end
        return { success = true, apply = true, launchOptions = merged,
            overrides = overrides, launcher = launcher,
            launcherRelative = launcher_rel }
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
    -- Validation and quoting live in steam_utils.open_external_url so they are
    -- unit-testable (scripts/test-endpoint-guards.lua).
    local ok, opened = pcall(steam_utils.open_external_url, tostring(url or ""))
    if not (ok and opened) then return json_err("Invalid URL") end
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

    -- Settings may contain API credentials. Never serialize them into the log.
    logger.log("ApplySettingsChanges: applying validated settings payload")

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
    on_tick            = on_tick,
}
