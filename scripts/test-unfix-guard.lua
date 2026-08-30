#!/usr/bin/env luajit
-- UnFixGame must derive its cleanup target from Steam metadata instead of
-- trusting the path supplied by the frontend RPC.

package.path = "plugin/backend/?.lua;" .. package.path

local removals = {}
local state_cleared = false
local restore_calls = 0
local restore_succeeds = true

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
    get_applied = function() return { manifestFilename = "238320.lua" } end,
    clear = function() state_cleared = true; return true end,
  }
end
package.preload.fixes = function()
  return {
    restore_game_fix = function(appid, path)
      restore_calls = restore_calls + 1
      return restore_succeeds, restore_succeeds and nil or "restore failed"
    end,
  }
end
package.preload.slsteam = function()
  return { unset_fake_appid = function() end }
end

for _, name in ipairs({
  "utils", "millennium", "http_client", "paths", "plugin_utils",
  "locales.manager", "api_manifest", "downloads",
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
check("a refused cleanup never starts a restore", restore_calls == 0)

removals = {}
state_cleared = false
result = UnFixGame({
  appid = 238320,
  installPath = "/steam/steamapps/common/Outlast",
})
check("the Steam-derived game path remains cleanable",
  type(result) == "table" and result.success == true)
check("cleanup restores the journal for the Steam-derived game path",
  restore_calls == 1)
check("cleanup removes only the known files below the derived game path",
  #removals == 3
    and removals[1] == "/steam/steamapps/common/Outlast/unsteam.dll"
    and removals[2] == "/steam/steamapps/common/Outlast/unsteam.ini"
    and removals[3] == "/steam/steamapps/common/Outlast/winmm.dll")
check("cleanup preserves the canonical app manifest",
  not table.concat(removals, "\n"):find("/config/stplug%-in/238320%.lua"))
check("successful cleanup clears its saved application state", state_cleared == true)

removals = {}
state_cleared = false
restore_succeeds = false
result = UnFixGame({
  appid = 238320,
  installPath = "/steam/steamapps/common/Outlast",
})
check("a failed restore fails Unfix", type(result) == "table" and result.success == false)
check("a failed restore preserves saved application state", state_cleared == false)
check("a failed restore performs no guessed legacy deletion", #removals == 0)

if failures > 0 then os.exit(1) end
