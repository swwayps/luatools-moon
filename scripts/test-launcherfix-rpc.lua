#!/usr/bin/env luajit

package.path = "plugin/backend/?.lua;" .. package.path

local failures = 0
local function check(name, condition)
  if condition then
    print("ok " .. name)
  else
    print("FAIL " .. name)
    failures = failures + 1
  end
end

package.preload.json = function()
  return {
    encode = function(value) return value end,
    decode = function(value) return value end,
  }
end
package.preload.plugin_logger = function()
  return { log = function() end, warn = function() end, error = function() end }
end
package.preload.fix_overlays = function()
  return {
    overrides_for_install_dir = function() return nil end,
    remove_overrides = function(value)
      return tostring(value or "")
        :gsub('WINEDLLOVERRIDES=".-"%s*', "")
        :gsub("^%s+", "")
    end,
  }
end

for _, name in ipairs({
  "utils", "millennium", "fs", "http_client", "paths", "steam_utils",
  "plugin_utils", "locales.manager", "api_manifest", "downloads", "fixes",
  "lua_tools_auth", "lua_tools_fixes", "lua_tools_fix_index",
  "lua_tools_fix_state", "lua_tools_recommended_add", "lua_tools_auto_fix",
  "settings.manager", "auto_update",
}) do
  package.preload[name] = function() return {} end
end

dofile("plugin/backend/main.lua")

local result = GetFixLaunchOptions({
  appid = 123,
  compatToolName = "",
  currentLaunchOptions = "mangohud %command%",
  installPath = "scripts/fixtures/launcher-game",
})

local expected = [[mangohud bash -c "cmd=(%command%)"'; cmd[-1]="$PWD/Launcher.exe"; "${cmd[@]}"']]
check("RPC passes the game-relative launcher to the Proton wrapper",
  type(result) == "table" and result.launchOptions == expected)
check("RPC keeps the absolute launcher path for diagnostics",
  type(result) == "table"
    and result.launcher == "scripts/fixtures/launcher-game/Launcher.exe")

local cleanup = GetFixLaunchOptions({
  appid = 105600,
  compatToolName = "proton-cachyos",
  currentLaunchOptions = 'WINEDLLOVERRIDES="OnlineFix=n,b;steam_api=n,b" mangohud %command%',
  installPath = "scripts/fixtures/no-launcher-game",
})
check("RPC removes a stale inferred override when none is now required",
  type(cleanup) == "table"
    and cleanup.apply == true
    and cleanup.launchOptions == "mangohud %command%")

if failures > 0 then os.exit(1) end
