#!/usr/bin/env luajit
-- Contract between ApplyGameFix and downloader.sh.
--
-- No shipped fix source asks for a request credential (the official catalogue
-- hands out pre-signed URLs, the online-fix fallback is a public mirror), so this
-- covers what the worker invocation must look like: no header file, a stall guard
-- tuned for large archives, hostile arguments quoted as data, and a typed
-- failure surfacing when a source refuses the download.
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
    return {status = "failed", error = "the source refused this", errorCode = "authentication"}
  end
  return {}
end }
package.loaded["settings.manager"] = {}
local fixes = dofile("plugin/backend/fixes.lua")
local failures = 0
local function check(name, cond)
  if cond then print("ok " .. name) else print("FAIL " .. name); failures = failures + 1 end
end

local applied = fixes.apply_game_fix(12100,
  "https://files.example/fixes/GTA%20III.zip", "/games/GTA3", "Generic", "GTA III")
check("A1 apply starts", applied.success == true)
check("A2 writes no curl header file",
  writes["/tmp/luatools/fix_12100_headers.txt"] == nil)
local worker = commands[#commands]
check("A3 passes an empty header argument to the downloader",
  worker and worker:find("headers.txt", 1, true) == nil)
-- A fix archive is tens of megabytes and the mirrors stall: measured an 11 MB
-- file arriving in 2s on one link and not finishing in 5 minutes on another. The
-- shared downloader defaults abort below 20 KB/s for 5s, which such a link can
-- never satisfy, so the fix path asks for a guard that only trips on a transfer
-- that is genuinely dead.
check("A3b fix downloads get a stall guard that tolerates a slow link",
  worker:find("SPEED_LIMIT=1024", 1, true) ~= nil
    and worker:find("SPEED_TIME=45", 1, true) ~= nil)
check("A3c fix downloads have a generous but finite overall limit",
  worker:find("MAX_TIME=1800", 1, true) ~= nil)

local before = #commands
local online = fixes.apply_game_fix(285900,
  "http://api.perondepot.xyz/all/Gang%20Beasts.rar", "/games/Gang", "Online", "Gang Beasts")
check("A5 the fallback mirror applies without any credential", online.success == true)
check("A6 and its worker command carries no header file",
  #commands == before + 2 and commands[#commands]:find("headers.txt", 1, true) == nil)

local hostile = "https://files.test/fix.zip';touch /tmp/lt-fix-injected;#"
fixes.apply_game_fix(285901, hostile, "/games/Gang';touch /tmp/lt-path-injected;#",
  "Online", "Gang Beasts")
local hostile_worker = commands[#commands] or ""
check("A6b user-controlled fix arguments are single-quoted shell data",
  hostile_worker:find("'https://files.test/fix.zip'\\'';touch /tmp/lt-fix-injected;#'", 1, true) ~= nil
    and hostile_worker:find("'/games/Gang'\\'';touch /tmp/lt-path-injected;#'", 1, true) ~= nil)

-- downloader.sh maps HTTP 401/403 to errorCode "authentication". The frontend
-- turns that into "the source refused this, try again" instead of the generic
-- corrupt-archive text, so the typed code has to survive the status read.
writes["/tmp/luatools/fix_12100_state.json"] =
  '{"status":"failed","error":"the source refused this","errorCode":"authentication"}'
local refused = fixes.get_apply_status(12100)
check("A9 a refused download is returned as a typed failure",
  refused.state and refused.state.errorCode == "authentication")
check("A10 and its state file is cleaned up",
  writes["/tmp/luatools/fix_12100_state.json"] == nil)

if failures > 0 then os.exit(1) end
print("ALL FIX DOWNLOAD CONTRACT CHECKS PASSED")
