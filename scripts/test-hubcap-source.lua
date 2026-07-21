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
}
package.loaded["settings.manager"] = {
    get_hubcap_api_key = function() return key end,
}
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

if failures > 0 then os.exit(1) end
print("ALL HUBCAP SOURCE CHECKS PASSED")
