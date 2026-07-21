local fs = require("fs")
local config = require("config")
local http_client = require("http_client")
local logger = require("plugin_logger")
local utils = require("plugin_utils")
local paths = require("paths")

local api_manifest = {}

local DEFAULT_API_PATH = paths.backend_path(config.API_DEFAULTS_FILE or config.API_JSON_FILE)
local LEGACY_API_PATH = paths.backend_path(config.API_JSON_FILE)
local USER_API_PATH = paths.backend_path("data/" .. config.API_JSON_FILE)
local CATALOG_SCHEMA_VERSION = 1

local _APIS_INIT_DONE = false
local _INIT_APIS_LAST_MESSAGE = ""

-- Built-in identities from older LuaTools releases. URL matching lets a
-- renamed/disabled built-in retain its preferences while retired providers
-- are removed. Entries that do not match are user-owned custom APIs.
local LEGACY_BUILTIN_IDS = {
    ["https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>"] = "hubcap",
    ["http://167.235.229.108/<appid>"] = "ryuu",
    ["https://api.twentytwocloud.com/download?appid=<appid>"] = "twentytwo-cloud",
    ["https://raw.githubusercontent.com/sushi-dev55-alt/sushitools-games-repo-alt/refs/heads/main/<appid>.zip"] = "sushi",
    ["https://luatools-moon-donations.workers.dev/db/<appid>.zip"] = "moon-internal",
}
local BUILTIN_ID_ALIASES = {
    ["morrenus"] = "hubcap",
}
local HISTORICAL_BUILTIN_NAMES = {
    ["hubcap"] = {
        ["Morrenus"] = true,
        ["Sadie (Morrenus)"] = true,
        ["Sadie (Hubcap)"] = true,
    },
}
local RETIRED_BUILTIN_IDS = {
    ["twentytwo-cloud"] = true,
    ["moon-internal"] = true,
}

local function copy_table(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do
        result[copy_table(key)] = copy_table(item)
    end
    return result
end

local function builtin_id(api, honor_custom_marker)
    if type(api) ~= "table" then return nil end
    if honor_custom_marker and api.custom == true then return nil end
    if type(api.builtin_id) == "string" and api.builtin_id ~= "" then
        return BUILTIN_ID_ALIASES[api.builtin_id] or api.builtin_id
    end
    return LEGACY_BUILTIN_IDS[api.url]
end

local function read_catalog(path)
    if not fs.exists(path) then return nil, "missing" end
    local data = utils.read_json(path)
    if type(data) ~= "table" or type(data.api_list) ~= "table" then
        return nil, "invalid"
    end
    return data, "valid"
end

local function write_user_catalog(data)
    local parent = fs.parent_path(USER_API_PATH)
    if parent and parent ~= "" and not fs.exists(parent) then
        fs.create_directories(parent)
    end
    data.schema_version = CATALOG_SCHEMA_VERSION
    local writer = utils.write_json_atomic or utils.write_json
    return writer(USER_API_PATH, data)
end

local function reconcile_catalog(defaults, user_data)
    local default_by_id = {}
    local default_order = {}

    for _, default in ipairs(defaults.api_list or {}) do
        local id = builtin_id(default, false)
        if id then
            local normalized = copy_table(default)
            normalized.builtin_id = id
            normalized.custom = nil
            normalized.removed = nil
            default_by_id[id] = normalized
            table.insert(default_order, id)
        end
    end

    local reconciled = {
        schema_version = CATALOG_SCHEMA_VERSION,
        api_list = {},
    }
    local seen_builtins = {}

    local function append_custom(saved)
        local custom = copy_table(saved)
        custom.builtin_id = nil
        custom.custom = true
        custom.removed = nil
        if type(custom.name) == "string" and custom.name ~= ""
            and type(custom.url) == "string" and custom.url ~= "" then
            table.insert(reconciled.api_list, custom)
        end
    end

    for _, saved in ipairs(user_data.api_list or {}) do
        local id = builtin_id(saved, true)
        if id then
            local default = default_by_id[id]
            if default and not seen_builtins[id] then
                local merged = copy_table(default)
                local historical_names = HISTORICAL_BUILTIN_NAMES[id] or {}
                if type(saved.name) == "string" and saved.name ~= ""
                    and not historical_names[saved.name] then
                    merged.name = saved.name
                end
                if saved.enabled ~= nil then
                    merged.enabled = saved.enabled ~= false
                end
                if saved.api_key ~= nil then
                    merged.api_key = saved.api_key
                end
                if saved.removed == true then
                    merged.removed = true
                    merged.enabled = false
                end
                table.insert(reconciled.api_list, merged)
                seen_builtins[id] = true
            elseif not RETIRED_BUILTIN_IDS[id] then
                -- An external catalogue may attach its own stable ID. If that
                -- ID is neither shipped nor explicitly retired, it is still a
                -- user-owned source and must not disappear during updates.
                append_custom(saved)
            end
        else
            append_custom(saved)
        end
    end

    for _, id in ipairs(default_order) do
        if not seen_builtins[id] then
            table.insert(reconciled.api_list, copy_table(default_by_id[id]))
        end
    end

    return reconciled
end

local function ensure_user_catalog()
    local defaults, defaults_status = read_catalog(DEFAULT_API_PATH)
    if defaults_status == "invalid" then
        return nil, "Shipped API defaults are invalid"
    end
    defaults = defaults or { api_list = {} }

    local user_data, user_status = read_catalog(USER_API_PATH)
    if user_status == "invalid" then
        return nil, "User API catalog is invalid; file left untouched at " .. USER_API_PATH
    end

    if user_status == "missing" then
        local legacy_data, legacy_status = read_catalog(LEGACY_API_PATH)
        if legacy_status == "invalid" then
            return nil, "Legacy API catalog is invalid; file left untouched at " .. LEGACY_API_PATH
        end
        user_data = legacy_data or { api_list = {} }
    end

    local reconciled = reconcile_catalog(defaults, user_data)
    if not write_user_catalog(reconciled) then
        return nil, "Failed to persist API catalog at " .. USER_API_PATH
    end
    return reconciled
end

local function find_api_by_name(data, name, include_removed)
    for index, api in ipairs(data.api_list or {}) do
        if api.name == name and (include_removed or api.removed ~= true) then
            return api, index
        end
    end
end

local function fetch_remote_manifest()
    logger.log("LuaTools: Fetching manifest from " .. config.API_MANIFEST_URL)
    local resp = http_client.get(config.API_MANIFEST_URL, { timeout = 15 })
    if not (resp and resp.status == 200 and resp.body) then
        logger.warn("LuaTools: Primary manifest URL failed, trying proxy...")
        resp = http_client.get(config.API_MANIFEST_PROXY_URL, {
            timeout = config.HTTP_PROXY_TIMEOUT_SECONDS,
        })
    end

    if not (resp and resp.status == 200 and resp.body) then
        return nil, "Both URLs failed"
    end

    local normalized = utils.normalize_manifest_text(resp.body)
    if not normalized or normalized == "" then
        return nil, "Empty manifest"
    end

    local data = utils.decode_json(normalized)
    if type(data) ~= "table" or type(data.api_list) ~= "table" then
        return nil, "Invalid manifest"
    end
    return data
end

function api_manifest.init_apis()
    logger.log("InitApis: invoked")
    if _APIS_INIT_DONE then
        logger.log("InitApis: already completed this session, skipping")
        return { success = true, message = _INIT_APIS_LAST_MESSAGE }
    end

    local defaults, defaults_status = read_catalog(DEFAULT_API_PATH)
    local message = ""

    if defaults_status == "invalid" then
        return { success = false, error = "Shipped API defaults are invalid" }
    elseif defaults and #(defaults.api_list or {}) > 0 then
        local _, err = ensure_user_catalog()
        if err then return { success = false, error = err } end
        logger.log("InitApis: Reconciled shipped defaults with user API catalog")
    else
        local data, catalog_err = ensure_user_catalog()
        if not data then return { success = false, error = catalog_err } end
        local remote, err = fetch_remote_manifest()
        if remote then
            local existing_urls = {}
            for _, api in ipairs(data.api_list) do
                if api.url then existing_urls[api.url] = true end
            end
            local loaded = 0
            for _, api in ipairs(remote.api_list) do
                local id = builtin_id(api, false)
                if not (id and RETIRED_BUILTIN_IDS[id])
                    and type(api.url) == "string" and api.url ~= ""
                    and not existing_urls[api.url] then
                    local item = copy_table(api)
                    item.builtin_id = nil
                    item.custom = true
                    item.remote = true
                    item.removed = nil
                    table.insert(data.api_list, item)
                    existing_urls[item.url] = true
                    loaded = loaded + 1
                end
            end
            if not write_user_catalog(data) then
                return { success = false, error = "Failed to save API catalog" }
            end
            message = "No API's Configured, Loaded " .. tostring(loaded) .. " Free Ones :D"
        else
            message = "No API's Configured and failed to load free ones"
            logger.warn("InitApis: " .. tostring(err))
        end
    end

    _APIS_INIT_DONE = true
    _INIT_APIS_LAST_MESSAGE = message
    return { success = true, message = message }
end

function api_manifest.get_init_apis_message()
    local message = _INIT_APIS_LAST_MESSAGE or ""
    _INIT_APIS_LAST_MESSAGE = ""
    return { success = true, message = message }
end

function api_manifest.store_last_message(message)
    _INIT_APIS_LAST_MESSAGE = message or ""
end

function api_manifest.fetch_free_apis_now()
    logger.log("LuaTools: FetchFreeApisNow invoked")
    local remote, err = fetch_remote_manifest()
    if not remote then
        return { success = false, error = err }
    end

    local data, catalog_err = ensure_user_catalog()
    if not data then return { success = false, error = catalog_err } end
    local retained = {}
    local existing_urls = {}

    for _, api in ipairs(data.api_list) do
        if api.remote ~= true then
            table.insert(retained, api)
            if api.url then existing_urls[api.url] = true end
        end
    end

    local loaded = 0
    local current_defaults = read_catalog(DEFAULT_API_PATH) or { api_list = {} }
    local live_builtins = {}
    local live_builtin_by_url = {}
    for _, api in ipairs(current_defaults.api_list or {}) do
        local id = builtin_id(api, false)
        if id then
            live_builtins[id] = true
            if type(api.url) == "string" and api.url ~= "" then
                live_builtin_by_url[api.url] = id
            end
        end
    end

    for _, api in ipairs(remote.api_list) do
        local id = builtin_id(api, false) or live_builtin_by_url[api.url]
        if id and RETIRED_BUILTIN_IDS[id] then
            -- Explicitly retired providers never return through remote refresh.
        elseif id and live_builtins[id] then
            -- The shipped copy is authoritative and already present.
            loaded = loaded + 1
        elseif type(api.url) == "string" and api.url ~= ""
            and not existing_urls[api.url] then
            local item = copy_table(api)
            item.builtin_id = nil
            item.custom = true
            item.remote = true
            item.removed = nil
            table.insert(retained, item)
            existing_urls[item.url] = true
            loaded = loaded + 1
        end
    end

    data.api_list = retained
    if not write_user_catalog(data) then
        return { success = false, error = "Failed to save API catalog" }
    end
    return { success = true, count = loaded }
end

function api_manifest.load_api_manifest()
    local data, err = ensure_user_catalog()
    if not data then
        logger.warn("LuaTools: " .. tostring(err))
        return {}
    end
    local apis = {}
    for _, api in ipairs(data.api_list) do
        if api.enabled ~= false and api.removed ~= true then
            table.insert(apis, api)
        end
    end
    return apis
end

function api_manifest.add_custom_api(payload)
    if not payload or type(payload.name) ~= "string" or type(payload.url) ~= "string"
        or payload.name == "" or payload.url == "" then
        return { success = false, error = "Invalid payload: name and url are required" }
    end

    local data, err = ensure_user_catalog()
    if not data then return { success = false, error = err } end
    local new_api = {
        name = payload.name,
        url = payload.url,
        success_code = payload.success_code or 200,
        unavailable_code = payload.unavailable_code or 404,
        enabled = true,
        custom = true,
    }
    if payload.api_key and payload.api_key ~= "" then
        new_api.api_key = payload.api_key
    end

    table.insert(data.api_list, new_api)
    if not write_user_catalog(data) then
        return { success = false, error = "Failed to save API catalog" }
    end
    logger.log("LuaTools: Added custom API: " .. payload.name)
    return { success = true }
end

function api_manifest.get_api_list()
    local success, apis = pcall(api_manifest.load_api_manifest)
    if not success then
        return { success = false, error = tostring(apis), apis = {} }
    end

    local hubcap_api_key = ""
    local ok, settings_manager = pcall(require, "settings.manager")
    if ok and settings_manager and settings_manager.get_hubcap_api_key then
        hubcap_api_key = settings_manager.get_hubcap_api_key() or ""
    end

    local api_names = {}
    for index, api in ipairs(apis) do
        local url = api.url or ""
        if not (string.find(url, "<moapikey>", 1, true) and hubcap_api_key == "") then
            table.insert(api_names, {
                name = api.name or "Unknown",
                index = index - 1,
            })
        end
    end
    return { success = true, apis = api_names }
end

function api_manifest.get_all_apis()
    local data, err = ensure_user_catalog()
    if not data then return { success = false, error = err, apis = {} } end
    local apis = {}
    for _, api in ipairs(data.api_list) do
        if api.removed ~= true then
            table.insert(apis, {
                name = api.name or "Unknown",
                url = api.url or "",
                enabled = api.enabled ~= false,
            })
        end
    end
    return { success = true, apis = apis }
end

function api_manifest.toggle_api(name)
    if type(name) ~= "string" or name == "" then
        return { success = false, error = "name is required" }
    end

    local data, err = ensure_user_catalog()
    if not data then return { success = false, error = err } end
    local api = find_api_by_name(data, name, false)
    if not api then
        return { success = false, error = "API not found: " .. name }
    end

    api.enabled = not (api.enabled ~= false)
    if not write_user_catalog(data) then
        return { success = false, error = "Failed to save API catalog" }
    end
    logger.log("LuaTools: Toggled API '" .. name .. "' -> " .. tostring(api.enabled))
    return { success = true, enabled = api.enabled }
end

function api_manifest.remove_api(name)
    if type(name) ~= "string" or name == "" then
        return { success = false, error = "name is required" }
    end

    local data, err = ensure_user_catalog()
    if not data then return { success = false, error = err } end
    local api, index = find_api_by_name(data, name, false)
    if not api then
        return { success = false, error = "API not found: " .. name }
    end

    if builtin_id(api, true) then
        api.removed = true
        api.enabled = false
    else
        table.remove(data.api_list, index)
    end

    if not write_user_catalog(data) then
        return { success = false, error = "Failed to save API catalog" }
    end
    logger.log("LuaTools: Removed API '" .. name .. "'")
    return { success = true }
end

function api_manifest.rename_api(old_name, new_name)
    if type(old_name) ~= "string" or old_name == ""
        or type(new_name) ~= "string" or new_name == "" then
        return { success = false, error = "old_name and new_name are required" }
    end

    local data, err = ensure_user_catalog()
    if not data then return { success = false, error = err } end
    local api = find_api_by_name(data, old_name, false)
    if not api then
        return { success = false, error = "API not found: " .. old_name }
    end

    api.name = new_name
    if not write_user_catalog(data) then
        return { success = false, error = "Failed to save API catalog" }
    end
    logger.log("LuaTools: Renamed API '" .. old_name .. "' -> '" .. new_name .. "'")
    return { success = true }
end

function api_manifest.set_api_order(ordered_names)
    if type(ordered_names) ~= "table" then
        return { success = false, error = "ordered_names must be a table" }
    end

    local data, err = ensure_user_catalog()
    if not data then return { success = false, error = err } end
    local new_list = {}
    local added = {}

    for _, name in ipairs(ordered_names) do
        for index, api in ipairs(data.api_list) do
            if api.name == name and api.removed ~= true and not added[index] then
                table.insert(new_list, api)
                added[index] = true
                break
            end
        end
    end

    for index, api in ipairs(data.api_list) do
        if not added[index] then
            table.insert(new_list, api)
        end
    end

    data.api_list = new_list
    if not write_user_catalog(data) then
        return { success = false, error = "Failed to save API catalog" }
    end
    logger.log("LuaTools: Reordered APIs")
    return { success = true }
end

return api_manifest
