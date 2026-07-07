#!/usr/bin/env luajit
-- Tests for downloads._finalize_install_lua's register gate.
--
-- The bug this guards: a download whose archive carried NO usable <appid>.lua
-- (no depot keys) still registered the appid in SLSsteam's AdditionalApps and
-- reported "done" -> the game showed up "owned" but installed as 0 B (every
-- depot pruned for want of a key) and never appeared in the Lua-scripts list.
-- The fix: only register + mark done when the .lua actually landed on disk;
-- otherwise fail with a clear reason and register NOTHING. Both paths must log.
--
-- Runs against the BUILT dist backend (that's what ships). Load with a small
-- in-memory VFS + module shims so we can drive finalize without the network
-- or a real Steam tree.
--
-- Run from the repo root:  luajit scripts/test-finalize-register.lua

local REPO = (arg and arg[0] or ""):gsub("scripts/[^/]*$", "")
if REPO == "" then REPO = "./" end
local BACKEND = REPO .. "dist/luatools/backend"

-- ---- in-memory VFS -------------------------------------------------------
local FILES = {}    -- path -> content
local DIRS = {}     -- path -> true
local LIST = {}     -- dir  -> { {name=, path=, is_directory=}, ... }

local function join(...)
  local parts = { ... }
  return table.concat(parts, "/")
end

-- ---- observation sinks ---------------------------------------------------
local REGISTERED = {}   -- appids passed to slsteam.register_app
local LOGS = { info = {}, warn = {}, error = {} }

-- ---- module shims (installed before requiring downloads.lua) -------------
package.loaded["utils"] = {
  read_file = function(p) return FILES[p] end,
  write_file = function(p, c) FILES[p] = c; return true end,
  getenv = function(k) return os.getenv(k) end,
  exec = function() return true end,
}
package.loaded["fs"] = {
  join = join,
  exists = function(p) return FILES[p] ~= nil or DIRS[p] == true end,
  create_directories = function(p) DIRS[p] = true; return true end,
  list_recursive = function(dir) return LIST[dir] or {} end,
  remove_all = function() return true end,
  remove = function(p) FILES[p] = nil; return true end,
}
package.loaded["http_client"] = { get = function() end, head = function() end, post = function() end }
package.loaded["config"] = { USER_AGENT = "test", HTTP_TIMEOUT_SECONDS = 5 }
package.loaded["plugin_logger"] = {
  log = function(m) table.insert(LOGS.info, tostring(m)) end,
  info = function(m) table.insert(LOGS.info, tostring(m)) end,
  warn = function(m) table.insert(LOGS.warn, tostring(m)) end,
  error = function(m) table.insert(LOGS.error, tostring(m)) end,
}
package.loaded["paths"] = {
  get_plugin_dir = function() return "/tmp/plugin" end,
  backend_path = function(p) return "/tmp/plugin/backend/" .. tostring(p) end,
}
package.loaded["steam_utils"] = {
  detect_steam_install_path = function() return "/tmp/steam" end,
}
package.loaded["plugin_utils"] = {
  ensure_temp_download_dir = function() return "/tmp/dl" end,
}
package.loaded["api_manifest"] = { load_api_manifest = function() return {} end }
package.loaded["settings.manager"] = { get_morrenus_api_key = function() return "" end }
package.loaded["json"] = {
  decode = function() return nil end,
  encode = function() return "{}" end,
}
package.loaded["slsteam"] = {
  register_app = function(appid) table.insert(REGISTERED, tonumber(appid)); return true, "added" end,
}

local downloads = dofile(BACKEND .. "/downloads.lua")

-- ---- harness -------------------------------------------------------------
local fails = 0
local function check(name, cond)
  if cond then print("ok " .. name) else print("FAIL " .. name); fails = fails + 1 end
end
local function reset()
  FILES, DIRS, LIST = {}, {}, {}
  REGISTERED = {}
  LOGS = { info = {}, warn = {}, error = {} }
end
local function logs_match(bucket, pat)
  for _, m in ipairs(LOGS[bucket]) do if m:find(pat, 1, true) then return true end end
  return false
end

-- ==========================================================================
-- C1: archive HAS the game's <appid>.lua -> register + log the install.
-- ==========================================================================
reset()
local APP1 = 2830030
local ex1 = "/tmp/extract1"
local lua1 = ex1 .. "/" .. APP1 .. ".lua"
FILES[lua1] = 'addappid(' .. APP1 .. ', 1, "' .. string.rep("a", 64) .. '")\n'
LIST[ex1] = { { name = APP1 .. ".lua", path = lua1, is_directory = false } }
downloads._finalize_install_lua(APP1, ex1, "/tmp/d1.zip", "TestSource")

check("C1 registered the app", REGISTERED[1] == APP1)
check("C1 wrote target lua", FILES["/tmp/steam/config/stplug-in/" .. APP1 .. ".lua"] ~= nil)
check("C1 logged the install", logs_match("info", "installed"))

-- ==========================================================================
-- C2: archive has NO <appid>.lua -> DO NOT register; fail; warn in the log.
-- ==========================================================================
reset()
local APP2 = 2393730
local ex2 = "/tmp/extract2"
-- only a stray manifest, no lua
LIST[ex2] = { { name = "123_456.manifest", path = ex2 .. "/123_456.manifest", is_directory = false } }
FILES[ex2 .. "/123_456.manifest"] = "x"
downloads._finalize_install_lua(APP2, ex2, "/tmp/d2.zip", "TestSource")

check("C2 did NOT register the app", #REGISTERED == 0)
check("C2 did NOT write a target lua", FILES["/tmp/steam/config/stplug-in/" .. APP2 .. ".lua"] == nil)
check("C2 warned about missing game data", logs_match("warn", "NO .lua") or logs_match("warn", "no game data"))

if fails == 0 then print("\nALL TESTS OK") else print("\n" .. fails .. " FAILED"); os.exit(1) end
