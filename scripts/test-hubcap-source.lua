#!/usr/bin/env luajit

local requested_url
local head_count = 0
local key = "smm_" .. string.rep("a", 96)

package.loaded.utils = {
    getenv = function() return nil end,
}
package.loaded.fs = {
    join = function(...) return table.concat({...}, "/") end,
}
package.loaded.http_client = {
    get = function(url)
        requested_url = url
        return {status = 200, body = "{}"}
    end,
    head = function()
        head_count = head_count + 1
        return {status = 404}
    end,
}
package.loaded.config = {
    USER_AGENT = "discord(dot)gg/luatools",
}
package.loaded.plugin_logger = {
    log = function() end,
    warn = function() end,
}
package.loaded.paths = {
    get_plugin_dir = function() return "/plugin" end,
}
package.loaded.steam_utils = {}
package.loaded.plugin_utils = {}
package.loaded.api_manifest = {
    load_api_manifest = function()
        return {
            {
                builtin_id = "hubcap",
                name = "Sadie (Hubcap)",
                url = "https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>",
                success_code = 200,
                unavailable_code = 404,
                enabled = true,
            },
        }
    end,
    get_api_credential_state = function(api, hubcap_api_key)
        local needs_key = api.builtin_id == "hubcap"
            or tostring(api.url or ""):find("<moapikey>", 1, true) ~= nil
        return {
            needsKey = needs_key,
            locked = needs_key
                and tostring(hubcap_api_key or ""):match("%S") == nil,
        }
    end,
}
package.loaded["settings.manager"] = {
    get_hubcap_api_key = function() return key end,
}
package.loaded.smart_merge = {}
package.loaded.json = {
    encode = function() return "{}" end,
    decode = function() return {} end,
}

local downloads = dofile("plugin/backend/downloads.lua")
local result = downloads.check_apis_for_app(10)
local failures = 0

local function check(condition, message)
    if condition then
        print("ok   " .. message)
    else
        print("FAIL " .. message)
        failures = failures + 1
    end
end

check(result.success == true and #result.results == 1 and result.results[1].available,
    "Sadie (Hubcap) is checked successfully under its current name")
check(requested_url ==
    "https://hubcapmanifest.com/api/v1/status/10?api_key=" .. key,
    "Hubcap availability uses the authenticated status endpoint")
check(head_count == 0,
    "Hubcap is identified by source metadata instead of its display name")

key = "   "
requested_url = nil
local locked_result = downloads.check_apis_for_app(10)
check(locked_result.success == true and #locked_result.results == 1
        and locked_result.results[1].needsKey == true
        and locked_result.results[1].locked == true
        and locked_result.results[1].available == false,
    "Hubcap remains visible as locked when its key is blank")
check(requested_url == nil,
    "blank Hubcap key never reaches the network")

if failures > 0 then os.exit(1) end
print("ALL HUBCAP SOURCE CHECKS PASSED")
