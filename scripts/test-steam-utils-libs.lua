-- Harness: load the REAL dist steam_utils.lua and exercise
--   steam_utils.get_game_install_path_response across multiple Steam library
--   folders, with the library list split between the two files Steam keeps:
--     config/libraryfolders.vdf      (one copy)
--     steamapps/libraryfolders.vdf   (the copy the content system reads)
--
-- Regression: a drive present only in steamapps/libraryfolders.vdf (the two
-- files had drifted) was invisible to the Fixes menu, so games installed on
-- that drive reported "not installed" no matter what. Detection must union
-- BOTH files (plus the Steam root).
--
-- Run from the repo root AFTER a build: lua5.4 scripts/test-steam-utils-libs.lua
local TMP = "/tmp/lt-steamutils-test"
os.execute("rm -rf " .. TMP)

local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
local function write(p, s)
  mkdir(p:match("^(.*)/[^/]+$"))
  local f = assert(io.open(p, "w")); f:write(s); f:close()
end
local function isdir(p)
  local h = io.popen("[ -d '" .. p .. "' ] && echo d || echo f")
  local r = (h:read("*l") or "f"); h:close(); return r == "d"
end
local function exists(p)
  local f = io.open(p, "r"); if f then f:close(); return true end
  return isdir(p)
end

local function preload(name, mod) package.preload[name] = function() return mod end end

local STEAM_ROOT = TMP .. "/steam"
preload("fs", {
  exists = exists,
  join = function(...)
    local parts = { ... }; local out = parts[1] or ""
    for i = 2, #parts do
      local seg = parts[i]
      if seg ~= nil and seg ~= "" then
        if out == "" then out = seg
        elseif out:sub(-1) == "/" then out = out .. seg
        else out = out .. "/" .. seg end
      end
    end
    return out
  end,
})
preload("utils", {
  read_file = function(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end,
  getenv = function(k) return os.getenv(k) end,
  exec = function() end,
})
preload("millennium", { steam_path = function() return STEAM_ROOT end })
preload("plugin_logger", { log = function() end, warn = function() end, info = function() end, error = function() end })
preload("paths", { get_plugin_dir = function() return TMP end })

-- libraryfolders.vdf fixtures ------------------------------------------------
local DRIVE_B = TMP .. "/mnt/DriveB/SteamLibrary"   -- only in steamapps copy
local DRIVE_C = TMP .. "/mnt/DriveC/SteamLibrary"   -- only in config copy

local function lib_entry(idx, path)
  return string.format('\t"%d"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n', idx, path)
end

-- config/ knows about: root + DriveC  (stale: missing DriveB)
write(STEAM_ROOT .. "/config/libraryfolders.vdf",
  '"libraryfolders"\n{\n' .. lib_entry(0, STEAM_ROOT) .. lib_entry(1, DRIVE_C) .. "}\n")
-- steamapps/ knows about: root + DriveB + DriveC  (current)
write(STEAM_ROOT .. "/steamapps/libraryfolders.vdf",
  '"libraryfolders"\n{\n' .. lib_entry(0, STEAM_ROOT) .. lib_entry(1, DRIVE_B) .. lib_entry(2, DRIVE_C) .. "}\n")

-- Game on DriveB (present only in the steamapps copy).
local APP_B = 111111
write(DRIVE_B .. "/steamapps/appmanifest_" .. APP_B .. ".acf",
  '"AppState"\n{\n\t"appid"\t\t"' .. APP_B .. '"\n\t"installdir"\t\t"GameB"\n}\n')
mkdir(DRIVE_B .. "/steamapps/common/GameB")

-- Game on the Steam root itself.
local APP_ROOT = 222222
write(STEAM_ROOT .. "/steamapps/appmanifest_" .. APP_ROOT .. ".acf",
  '"AppState"\n{\n\t"appid"\t\t"' .. APP_ROOT .. '"\n\t"installdir"\t\t"GameRoot"\n}\n')
mkdir(STEAM_ROOT .. "/steamapps/common/GameRoot")

-- ---------------------------------------------------------------------------
local steam_utils = dofile("dist/luatools/backend/steam_utils.lua")

local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else print("FAIL " .. msg); fails = fails + 1 end end

local rb = steam_utils.get_game_install_path_response(APP_B)
check(rb.success == true, "game on a drive listed only in steamapps/libraryfolders.vdf is detected")
check(rb.success and rb.installPath == DRIVE_B .. "/steamapps/common/GameB",
  "  -> install path resolves to the DriveB library")

local rr = steam_utils.get_game_install_path_response(APP_ROOT)
check(rr.success == true, "game in the Steam root library is detected")

local rmiss = steam_utils.get_game_install_path_response(999999)
check(rmiss.success == false, "a genuinely absent appid still reports not installed")

if fails == 0 then print("test-steam-utils-libs: ALL PASS") else print("test-steam-utils-libs: " .. fails .. " FAILURE(S)"); os.exit(1) end
