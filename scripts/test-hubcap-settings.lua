#!/usr/bin/env luajit

local SETTINGS_PATH = "/plugin/backend/data/settings.json"
local stored = {
    version = 1,
    values = {
        general = {
            language = "en",
            useSteamLanguage = false,
            morrenusApiKey = "smm_" .. string.rep("a", 96),
        },
    },
}
local atomic_write_count = 0
local non_atomic_write_count = 0

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

package.loaded.fs = {
    exists = function(path) return path == SETTINGS_PATH end,
    parent_path = function() return "/plugin/backend/data" end,
    create_directories = function() return true end,
    join = function(...) return table.concat({...}, "/") end,
}
package.loaded.json = {
    decode = function() return {} end,
}
package.loaded.paths = {
    backend_path = function(path) return "/plugin/backend/" .. path end,
    get_plugin_dir = function() return "/plugin" end,
}
package.loaded.plugin_logger = {
    log = function() end,
    warn = function() end,
}
package.loaded.plugin_utils = {
    read_json = function(path)
        if path == SETTINGS_PATH then return copy(stored) end
    end,
    write_json = function(path, value)
        non_atomic_write_count = non_atomic_write_count + 1
        if path == SETTINGS_PATH then stored = copy(value) end
        return true
    end,
    write_json_atomic = function(path, value)
        atomic_write_count = atomic_write_count + 1
        if path == SETTINGS_PATH then stored = copy(value) end
        return true
    end,
    read_text = function() return "" end,
}
package.loaded["locales.manager"] = {
    DEFAULT_LOCALE = "en",
    get_locale_manager = function()
        return {
            available_locales = function()
                return {{code = "en", name = "English", nativeName = "English"}}
            end,
            get_locale_strings = function() return {} end,
        }
    end,
}
package.loaded["settings.options"] = dofile("plugin/backend/settings/options.lua")

local manager = dofile("plugin/backend/settings/manager.lua")
local expected_key = "smm_" .. string.rep("a", 96)
local failures = 0

local function check(condition, message)
    if condition then
        print("ok   " .. message)
    else
        print("FAIL " .. message)
        failures = failures + 1
    end
end

check(type(manager.get_hubcap_api_key) == "function",
    "settings manager exposes the current Hubcap accessor")
if manager.get_hubcap_api_key then
    check(manager.get_hubcap_api_key() == expected_key,
        "legacy API key is available through the Hubcap setting")
end
check(stored.version == 2, "legacy settings are migrated to schema version 2")
check(stored.values.general.hubcapApiKey == expected_key,
    "legacy API key is persisted under hubcapApiKey")
check(stored.values.general.morrenusApiKey == nil,
    "obsolete setting key is removed after migration")
check(atomic_write_count > 0, "settings migration uses an atomic JSON write")
check(non_atomic_write_count == 0, "settings migration never uses the non-atomic writer")

if failures > 0 then os.exit(1) end
print("ALL HUBCAP SETTINGS CHECKS PASSED")
