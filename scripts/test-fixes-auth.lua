#!/usr/bin/env luajit
-- Contract between ApplyGameFix and downloader.sh for authenticated Ryuu fixes.

-- guard.lua is a pure validation module with no side effects, so it is
-- required for real rather than stubbed.
package.path = "plugin/backend/?.lua;" .. package.path
local writes, commands = {}, {}

package.loaded.utils = {
  getenv = function() return nil end,
  write_file = function(path, data) writes[path] = data; return true end,
  read_file = function(path) return writes[path] end,
  exec = function(cmd) commands[#commands + 1] = cmd; return true end,
}
package.loaded.fs = {
  join = function(...) return table.concat({...}, "/") end,
  exists = function(path) return writes[path] ~= nil end,
  remove = function(path) writes[path] = nil; return true end,
}
package.loaded.http_client = {}
package.loaded.plugin_logger = { log = function() end, warn = function() end }
package.loaded.plugin_utils = {
  ensure_temp_download_dir = function() return "/tmp/luatools" end,
}
package.loaded.paths = { get_plugin_dir = function() return "/plugin" end }
package.loaded.json = { decode = function(raw)
  if raw and raw:find('"errorCode"%s*:%s*"authentication"') then
    return {status = "failed", error = "expired", errorCode = "authentication"}
  end
  return {}
end }
package.loaded["settings.manager"] = {}
package.loaded.ryuu_auth = {
  get_header_line = function() return "Cookie: session=test-session\n" end,
  clear = function() package.loaded.ryuu_auth.cleared = (package.loaded.ryuu_auth.cleared or 0) + 1; return true end,
}

local fixes = dofile("plugin/backend/fixes.lua")
local failures = 0
local function check(name, cond)
  if cond then print("ok " .. name) else print("FAIL " .. name); failures = failures + 1 end
end

-- apply_game_fix now checks the destination against the install path the
-- backend derives for that AppID, so the tests supply that resolver.
local INSTALLED = {
  [12100] = "/games/GTA3",
  [285900] = "/games/Gang",
  [285901] = "/games/Gang",
}
local function apply(appid, url, path, kind, name)
  return fixes.apply_game_fix(appid, url, path, kind, name, {
    install_state = function(id)
      local install = INSTALLED[tonumber(id)]
      if not install then return { found = false, error = "notInstalled" } end
      return { found = true, installPath = install, directoryExists = true }
    end,
    -- The derived path is contained too (a ".." in the appmanifest's installdir
    -- must not escape the library). These fixtures use bare /games paths, so the
    -- containment check is stubbed to accept them.
    library_path = function(p) return p end,
  })
end

local ryuu = apply(12100,
  "https://generator.ryuu.lol/fixes/GTA%20III.zip", "/games/GTA3", "Crack", "GTA III")
local header_path = "/tmp/luatools/fix_12100_headers.txt"
check("A1 authenticated Ryuu apply starts", ryuu.success == true)
check("A2 writes a curl header file", writes[header_path] == "Cookie: session=test-session\n")
local ryuu_worker = commands[#commands]
check("A3 passes only the header path to downloader",
  ryuu_worker and ryuu_worker:find(header_path, 1, true) ~= nil)
-- A fix archive is tens of megabytes and the mirrors stall: measured an 11 MB
-- file arriving in 2s on one link and not finishing in 5 minutes on another. The
-- shared downloader defaults abort below 20 KB/s for 5s, which such a link can
-- never satisfy, so the fix path asks for a guard that only trips on a transfer
-- that is genuinely dead.
check("A3b fix downloads get a stall guard that tolerates a slow link",
  ryuu_worker:find("SPEED_LIMIT=1024", 1, true) ~= nil
    and ryuu_worker:find("SPEED_TIME=45", 1, true) ~= nil)
check("A3c fix downloads have a generous but finite overall limit",
  ryuu_worker:find("MAX_TIME=1800", 1, true) ~= nil)

check("A4 never exposes the key on the process command line",
  ryuu_worker and ryuu_worker:find("test-session", 1, true) == nil)

local before = #commands
local online = apply(285900,
  "https://api.perondepot.xyz/all/Gang%20Beasts.rar", "/games/Gang", "Online", "Gang Beasts")
check("A5 non-Ryuu apply starts without auth", online.success == true)
check("A6 non-Ryuu command has no Ryuu header file",
  #commands == before + 2 and commands[#commands]:find("headers.txt", 1, true) == nil)

-- A hostile URL and a hostile destination are now refused outright rather than
-- merely quoted: the source host is not one we publish, and the destination is
-- not the game's install directory. (Quoting is still asserted, on the values
-- that DO pass validation, by scripts/test-endpoint-guards.lua.)
local hostile_before = #commands
local hostile = "https://files.test/fix.zip';touch /tmp/lt-fix-injected;#"
local hostile_result = apply(285901, hostile,
  "/games/Gang';touch /tmp/lt-path-injected;#", "Online", "Gang Beasts")
check("A6b a hostile source and destination are refused",
  hostile_result.success == false)
check("A6c a refused apply starts no worker", #commands == hostile_before)

package.loaded.ryuu_auth.get_header_line = function() return nil end
package.loaded.ryuu_auth = package.loaded.ryuu_auth
local no_key_fixes = dofile("plugin/backend/fixes.lua")
local no_key_before = #commands
local denied = no_key_fixes.apply_game_fix(12100,
  "https://generator.ryuu.lol/fixes/GTA%20III.zip", "/games/GTA3", "Crack", "GTA III",
  { install_state = function()
      return { found = true, installPath = "/games/GTA3", directoryExists = true }
    end,
    library_path = function(p) return p end })
check("A7 missing Ryuu key is rejected before launch",
  denied.success == false and tostring(denied.error):lower():find("auth", 1, true) ~= nil)
check("A8 missing Ryuu key launches no worker", #commands == no_key_before)

writes["/tmp/luatools/fix_12100_state.json"] =
  '{"status":"failed","error":"expired","errorCode":"authentication"}'
local expired = no_key_fixes.get_apply_status(12100)
check("A9 expired auth is returned as a typed failure",
  expired.state and expired.state.errorCode == "authentication")
check("A10 expired auth clears the saved credential",
  package.loaded.ryuu_auth.cleared == 1)

if failures > 0 then os.exit(1) end
print("ALL FIX AUTH CHECKS PASSED")
