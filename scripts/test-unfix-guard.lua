#!/usr/bin/env luajit
-- UnFixGame must derive its cleanup target from Steam metadata instead of
-- trusting the path supplied by the frontend RPC.

package.path = "plugin/backend/?.lua;" .. package.path

local removals = {}
local state_cleared = false

package.preload.json = function()
  return {
    encode = function(value) return value end,
    decode = function(value) return value end,
  }
end
package.preload.plugin_logger = function()
  return { log = function() end, warn = function() end, error = function() end }
end
package.preload.fs = function()
  return {
    join = function(...) return table.concat({ ... }, "/") end,
    remove = function(path)
      removals[#removals + 1] = path
      return true
    end,
  }
end
package.preload.steam_utils = function()
  return {
    detect_steam_install_path = function() return "/steam" end,
    get_game_install_state = function(appid)
      return {
        found = appid == 238320,
        installPath = "/steam/steamapps/common/Outlast",
        directoryExists = true,
      }
    end,
    game_library_path = function(path)
      if path == "/steam/steamapps/common/Outlast" then return path end
    end,
  }
end
package.preload.lua_tools_fix_state = function()
  return {
    get_applied = function() return nil end,
    clear = function() state_cleared = true; return true end,
  }
end
package.preload.slsteam = function()
  return { unset_fake_appid = function() end }
end

for _, name in ipairs({
  "utils", "millennium", "http_client", "paths", "plugin_utils",
  "locales.manager", "api_manifest", "downloads", "fixes",
  "lua_tools_auth", "lua_tools_fixes", "lua_tools_fix_index",
  "lua_tools_recommended_add", "lua_tools_auto_fix", "settings.manager",
  "auto_update", "launchopts", "fix_overlays", "launcherfix",
}) do
  package.preload[name] = function() return {} end
end

dofile("plugin/backend/main.lua")

local result = UnFixGame({
  appid = 238320,
  installPath = "/home/u/.config/autostart",
})

local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

check("a caller path that differs from Steam metadata is refused",
  type(result) == "table" and result.success == false)
check("a refused cleanup removes no files", #removals == 0)
check("a refused cleanup preserves saved application state", state_cleared == false)

removals = {}
state_cleared = false
result = UnFixGame({
  appid = 238320,
  installPath = "/steam/steamapps/common/Outlast",
})
check("the Steam-derived game path remains cleanable",
  type(result) == "table" and result.success == true)
check("cleanup removes only the known files below the derived game path",
  #removals == 3
    and removals[1] == "/steam/steamapps/common/Outlast/unsteam.dll"
    and removals[2] == "/steam/steamapps/common/Outlast/unsteam.ini"
    and removals[3] == "/steam/steamapps/common/Outlast/winmm.dll")
check("successful cleanup clears its saved application state", state_cleared == true)

if failures > 0 then os.exit(1) end
