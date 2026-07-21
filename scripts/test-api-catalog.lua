#!/usr/bin/env luajit
-- Regression test for the split between shipped API defaults and user state.

local DEFAULT_PATH = "/plugin/backend/api.defaults.json"
local LEGACY_PATH = "/plugin/backend/api.json"
local USER_PATH = "/plugin/backend/data/api.json"
local remote_manifest
local write_count = 0

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local files = {
    [DEFAULT_PATH] = {
        api_list = {
            {
                builtin_id = "hubcap",
                name = "Sadie (Hubcap)",
                url = "https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>",
                success_code = 200,
                unavailable_code = 404,
                enabled = true,
            },
            {
                builtin_id = "ryuu",
                name = "Ryuu",
                url = "http://167.235.229.108/<appid>",
                success_code = 200,
                unavailable_code = 404,
                enabled = true,
            },
            {
                builtin_id = "sushi",
                name = "Sushi",
                url = "https://raw.githubusercontent.com/sushi-dev55-alt/sushitools-games-repo-alt/refs/heads/main/<appid>.zip",
                success_code = 200,
                unavailable_code = 404,
                enabled = true,
            },
        },
    },
    -- This is what install.sh migrates from an installation made before the
    -- persistent catalog existed.
    [USER_PATH] = {
        api_list = {
            {
                builtin_id = "morrenus",
                name = "Morrenus",
                url = "https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>",
                success_code = 200,
                unavailable_code = 404,
                enabled = false,
            },
            {
                name = "Minha Ryuu",
                url = "http://167.235.229.108/<appid>",
                success_code = 200,
                unavailable_code = 404,
                enabled = false,
            },
            {
                name = "TwentyTwo Cloud",
                url = "https://api.twentytwocloud.com/download?appid=<appid>",
                success_code = 200,
                unavailable_code = 404,
                enabled = true,
            },
            {
                name = "API da comunidade",
                url = "https://example.invalid/<appid>.zip",
                success_code = 201,
                unavailable_code = 410,
                enabled = true,
                api_key = "preserve-me",
            },
            {
                builtin_id = "skyapi",
                name = "Minha SkyAPI",
                url = "https://raw.githubusercontent.com/skyflarefox/Skyapi/refs/heads/main/<appid>.zip",
                success_code = 200,
                unavailable_code = 404,
                enabled = true,
            },
        },
    },
}
local shipped_defaults = copy(files[DEFAULT_PATH])

package.loaded.fs = {
    exists = function(path) return files[path] ~= nil end,
    parent_path = function(path) return path:match("^(.*)/[^/]+$") end,
    create_directories = function() return true end,
}
package.loaded.config = {
    API_DEFAULTS_FILE = "api.defaults.json",
    API_JSON_FILE = "api.json",
    API_MANIFEST_URL = "https://unused.invalid",
    API_MANIFEST_PROXY_URL = "https://unused.invalid",
    HTTP_PROXY_TIMEOUT_SECONDS = 1,
}
package.loaded.http_client = {
    get = function()
        if remote_manifest then
            return { status = 200, body = "REMOTE_MANIFEST" }
        end
    end,
}
package.loaded.plugin_logger = {
    log = function() end,
    warn = function() end,
}
package.loaded.paths = {
    backend_path = function(path) return "/plugin/backend/" .. path end,
}
package.loaded.plugin_utils = {
    read_text = function() return "" end,
    write_text = function() return true end,
    normalize_manifest_text = function(text) return text end,
    count_apis = function() return 0 end,
    decode_json = function(text)
        if text == "REMOTE_MANIFEST" then return copy(remote_manifest) end
        return {}
    end,
    encode_json = function() return "{}" end,
    read_json = function(path) return copy(files[path] or {}) end,
    write_json = function(path, value)
        write_count = write_count + 1
        files[path] = copy(value)
        return true
    end,
    write_json_atomic = function(path, value)
        write_count = write_count + 1
        files[path] = copy(value)
        return true
    end,
}
package.loaded["settings.manager"] = {
    get_hubcap_api_key = function() return "configured" end,
}

local api_manifest = dofile("plugin/backend/api_manifest.lua")
local failures = 0

local function check(condition, message)
    if condition then
        print("ok   " .. message)
    else
        print("FAIL " .. message)
        failures = failures + 1
    end
end

local function find_api(list, name)
    for _, api in ipairs(list or {}) do
        if api.name == name then return api end
    end
end

local all = api_manifest.get_all_apis().apis
check(#all == 5, "live defaults and custom APIs are visible")
check(find_api(all, "TwentyTwo Cloud") == nil, "retired TwentyTwo default is removed")
check(find_api(all, "Sadie (Hubcap)") ~= nil, "legacy Morrenus source adopts the current upstream name")
check(find_api(all, "Morrenus") == nil, "obsolete source name is not kept as a user-visible rename")
check(find_api(all, "Sadie (Hubcap)").enabled == false,
    "legacy Hubcap preferences survive the source identity migration")
local migrated_ryuu = find_api(all, "Minha Ryuu")
check(migrated_ryuu ~= nil, "renamed built-in keeps its user name")
check(migrated_ryuu and migrated_ryuu.enabled == false, "disabled built-in stays disabled")
check(find_api(all, "API da comunidade") ~= nil, "custom API survives reconciliation")
check(find_api(all, "Minha SkyAPI") ~= nil,
    "non-default SkyAPI is preserved instead of treated as retired")

local active = api_manifest.load_api_manifest()
check(find_api(active, "Minha Ryuu") == nil, "disabled API is excluded from downloads")
check(find_api(active, "API da comunidade") ~= nil, "enabled custom API is used for downloads")

local persisted_custom = find_api(files[USER_PATH].api_list, "API da comunidade")
check(persisted_custom and persisted_custom.custom == true, "legacy custom API is marked as user-owned")
check(persisted_custom and persisted_custom.api_key == "preserve-me", "custom API metadata is preserved")

api_manifest.add_custom_api({
    name = "Outra custom",
    url = "https://custom.invalid/<appid>",
    success_code = 202,
    unavailable_code = 418,
    api_key = "secret",
})
all = api_manifest.get_all_apis().apis
check(find_api(all, "Outra custom") ~= nil, "new custom API is stored in the persistent catalog")

api_manifest.remove_api("Sadie (Hubcap)")
all = api_manifest.get_all_apis().apis
check(find_api(all, "Sadie (Hubcap)") == nil, "removed built-in stays hidden after reconciliation")
local hubcap_state
for _, api in ipairs(files[USER_PATH].api_list) do
    if api.builtin_id == "hubcap" then hubcap_state = api end
end
check(hubcap_state and hubcap_state.removed == true, "built-in removal is saved as a tombstone")

files[DEFAULT_PATH].api_list[2].url = "https://new-ryuu.invalid/<appid>"
all = api_manifest.get_all_apis().apis
local ryuu = find_api(all, "Minha Ryuu")
check(ryuu and ryuu.url == "https://new-ryuu.invalid/<appid>", "updated built-in URL comes from shipped defaults")
check(ryuu and ryuu.enabled == false, "built-in preferences survive a default URL update")

remote_manifest = {
    api_list = {
        {
            name = "Ryuu",
            url = files[DEFAULT_PATH].api_list[2].url,
            enabled = true,
        },
        {
            name = "TwentyTwo Cloud",
            url = "https://api.twentytwocloud.com/download?appid=<appid>",
            enabled = true,
        },
        {
            name = "Free remota",
            url = "https://remote.invalid/<appid>",
            enabled = true,
        },
        {
            builtin_id = "community-feed",
            name = "Feed comunitário",
            url = "https://community-feed.invalid/<appid>",
            enabled = true,
        },
    },
}
local fetched = api_manifest.fetch_free_apis_now()
all = api_manifest.get_all_apis().apis
check(fetched.success and fetched.count == 3, "fetch reports live built-in and imported remote APIs")
check(find_api(all, "Free remota") ~= nil, "fetch adds a new remote API without replacing custom APIs")
check(find_api(all, "Feed comunitário") ~= nil,
    "fetch imports an unknown builtin_id as a custom remote API")
check(find_api(all, "API da comunidade") ~= nil, "fetch preserves existing custom APIs")
check(find_api(all, "Minha SkyAPI") ~= nil, "fetch preserves the user's non-default SkyAPI")
check(find_api(all, "TwentyTwo Cloud") == nil, "fetch cannot reintroduce a retired built-in")
check(find_api(all, "Ryuu") == nil, "fetch does not duplicate a renamed built-in with a current URL")

files[DEFAULT_PATH] = copy(shipped_defaults)
files[USER_PATH] = nil
files[LEGACY_PATH] = {
    api_list = {
        {
            name = "Custom antes do auto-update",
            url = "https://legacy-custom.invalid/<appid>",
            enabled = true,
        },
        {
            name = "TwentyTwo Cloud",
            url = "https://api.twentytwocloud.com/download?appid=<appid>",
            enabled = true,
        },
    },
}
remote_manifest = nil
local legacy_manifest = dofile("plugin/backend/api_manifest.lua")
all = legacy_manifest.get_all_apis().apis
check(find_api(all, "Custom antes do auto-update") ~= nil,
    "first boot migrates the legacy catalog left by the old auto-updater")
check(find_api(all, "TwentyTwo Cloud") == nil,
    "legacy auto-update migration removes retired defaults")
check(find_api(files[USER_PATH].api_list, "Custom antes do auto-update") ~= nil,
    "legacy catalog is persisted under backend/data")
check(find_api(files[LEGACY_PATH].api_list, "Custom antes do auto-update") ~= nil,
    "migration does not overwrite the recoverable legacy file")

files[USER_PATH] = { corrupt = "keep this for recovery" }
files[LEGACY_PATH] = nil
local writes_before_invalid_read = write_count
local invalid_manifest = dofile("plugin/backend/api_manifest.lua")
local invalid_result = invalid_manifest.get_all_apis()
check(invalid_result.success == false, "invalid persistent catalog is reported")
check(files[USER_PATH].corrupt == "keep this for recovery",
    "invalid persistent catalog is not replaced by defaults")
check(write_count == writes_before_invalid_read,
    "invalid persistent catalog is never rewritten implicitly")

files[DEFAULT_PATH] = { api_list = {} }
files[USER_PATH] = nil
files[LEGACY_PATH] = nil
remote_manifest = {
    api_list = {
        {
            name = "Sadie (Hubcap)",
            url = "https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>",
            enabled = true,
        },
        {
            name = "TwentyTwo Cloud",
            url = "https://api.twentytwocloud.com/download?appid=<appid>",
            enabled = true,
        },
    },
}
local fallback_manifest = dofile("plugin/backend/api_manifest.lua")
fallback_manifest.init_apis()
check(find_api(files[USER_PATH].api_list, "TwentyTwo Cloud") == nil,
    "missing defaults fallback does not persist a retired remote API")
active = fallback_manifest.load_api_manifest()
check(find_api(active, "Sadie (Hubcap)") ~= nil,
    "missing defaults fallback keeps a fetched API across reconciliation")

if failures > 0 then
    print("\n" .. failures .. " CHECK(S) FAILED")
    os.exit(1)
end
print("\nALL API CATALOG CHECKS PASSED")
