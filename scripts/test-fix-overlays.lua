#!/usr/bin/env luajit
-- Unit tests for linux/backend/fix_overlays.lua
--
-- fix_overlays is a PURE module (no Millennium deps) that:
--   * scans a directory for the Windows DLLs an online/generic fix ships
--     and builds the matching WINEDLLOVERRIDES string, and
--   * merges that override into an existing Steam launch-options string
--     idempotently, preserving the user's existing options and %command%.
--
-- Run from the repo root:  luajit scripts/test-fix-overlays.lua

package.path = "linux/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then
    io.write("ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. "\n")
    fails = fails + 1
  end
end

local fo = dofile("linux/backend/fix_overlays.lua")

-- ---------------------------------------------------------------------------
-- build_overrides(dll_names): map a set of present DLL basenames to a
-- WINEDLLOVERRIDES string. Only DLLs the fix actually shipped get an entry,
-- so we never override a builtin that the game doesn't replace.
-- Native-first DLLs (the fix's own code) -> "=n". DLLs that must chain to the
-- builtin afterwards (winmm, winhttp, version) -> "=n,b".
-- ---------------------------------------------------------------------------

-- C1: a typical online-fix payload.
do
  local s = fo.build_overrides({
    "OnlineFix64.dll", "SteamOverlay64.dll", "winmm.dll",
    "dnet.dll", "steam_api64.dll",
  })
  check("C1 has prefix", s:sub(1, #'WINEDLLOVERRIDES="') == 'WINEDLLOVERRIDES="')
  check("C1 OnlineFix64 native", s:find("OnlineFix64=n") ~= nil)
  check("C1 steam_api64 native", s:find("steam_api64=n") ~= nil)
  check("C1 winmm native+builtin", s:find("winmm=n,b") ~= nil)
  check("C1 no .dll suffix in key", s:find("%.dll=") == nil)
  check("C1 quoted", s:sub(-1) == '"')
end

-- C2: only a steam_api64 (Goldberg-style) -> single override.
do
  local s = fo.build_overrides({ "steam_api64.dll" })
  check("C2 single steam_api64", s == 'WINEDLLOVERRIDES="steam_api64=n"')
end

-- C3: case-insensitive matching, dedup, ignore non-dll/unknown files.
do
  local s = fo.build_overrides({
    "WINMM.DLL", "winmm.dll", "readme.txt", "OnlineFix.ini",
  })
  local _, n = s:gsub("winmm=n,b", "")
  check("C3 winmm once (dedup, case-insensitive)", n == 1)
  check("C3 ignores readme.txt", s:find("readme") == nil)
  check("C3 ignores .ini", s:find("OnlineFix=") == nil)
end

-- C4: no recognised DLLs -> nil (nothing to override).
do
  local s = fo.build_overrides({ "data.bin", "config.ini" })
  check("C4 no dlls -> nil", s == nil)
  check("C4 empty -> nil", fo.build_overrides({}) == nil)
end

-- ---------------------------------------------------------------------------
-- merge_launch_options(current, overrides): produce the new launch-options
-- string. Must preserve the user's existing options & %command%, be
-- idempotent (re-applying replaces our old block, never stacks), and place
-- the WINEDLLOVERRIDES BEFORE %command% (env must precede the command).
-- ---------------------------------------------------------------------------
local OV = 'WINEDLLOVERRIDES="OnlineFix64=n;winmm=n,b"'

-- C5: empty current -> overrides + %command%.
do
  local r = fo.merge_launch_options("", OV)
  check("C5 empty -> ov + %command%", r == OV .. " %command%")
end
do
  local r = fo.merge_launch_options(nil, OV)
  check("C5 nil -> ov + %command%", r == OV .. " %command%")
end

-- C6: existing options WITH %command% -> inject override before %command%,
-- keep the rest intact and in order.
do
  local r = fo.merge_launch_options("game-performance mangohud %command%", OV)
  check("C6 keeps mangohud", r:find("mangohud") ~= nil)
  check("C6 keeps game-performance", r:find("game%-performance") ~= nil)
  check("C6 has override", r:find('WINEDLLOVERRIDES=') ~= nil)
  check("C6 override before %command%",
        r:find("WINEDLLOVERRIDES") < r:find("%%command%%"))
  check("C6 single %command%", select(2, r:gsub("%%command%%", "")) == 1)
end

-- C7: existing options WITHOUT %command% -> still inject, append %command%.
do
  local r = fo.merge_launch_options("mangohud", OV)
  check("C7 keeps mangohud", r:find("mangohud") ~= nil)
  check("C7 adds %command%", r:find("%%command%%") ~= nil)
  check("C7 override present", r:find("WINEDLLOVERRIDES=") ~= nil)
end

-- C8: idempotent — applying twice does not stack overrides.
do
  local once = fo.merge_launch_options("game-performance %command%", OV)
  local twice = fo.merge_launch_options(once, OV)
  check("C8 idempotent equal", once == twice)
  check("C8 single override", select(2, twice:gsub("WINEDLLOVERRIDES=", "")) == 1)
end

-- C9: re-applying a DIFFERENT override replaces the previous one (the user
-- applied a new fix) rather than leaving two WINEDLLOVERRIDES.
do
  local OV2 = 'WINEDLLOVERRIDES="steam_api64=n"'
  local first = fo.merge_launch_options("mangohud %command%", OV)
  local second = fo.merge_launch_options(first, OV2)
  check("C9 single override after replace",
        select(2, second:gsub("WINEDLLOVERRIDES=", "")) == 1)
  check("C9 has new override", second:find("steam_api64=n") ~= nil)
  check("C9 dropped old override", second:find("OnlineFix64") == nil)
  check("C9 keeps mangohud", second:find("mangohud") ~= nil)
end

-- C10: a user's pre-existing, hand-written WINEDLLOVERRIDES is respected as
-- "already overridden" form too (we replace the whole assignment, not append).
do
  local cur = 'WINEDLLOVERRIDES="dxgi=n,b" mangohud %command%'
  local r = fo.merge_launch_options(cur, OV)
  check("C10 single override", select(2, r:gsub("WINEDLLOVERRIDES=", "")) == 1)
  check("C10 our override wins", r:find("OnlineFix64=n") ~= nil)
  check("C10 keeps mangohud", r:find("mangohud") ~= nil)
end

-- ---------------------------------------------------------------------------
-- is_proton_tool(name): only Proton/compat tools warrant DLL overrides.
-- ---------------------------------------------------------------------------
do
  check("C11 proton_experimental", fo.is_proton_tool("proton_experimental") == true)
  check("C11 proton_9", fo.is_proton_tool("proton_9") == true)
  check("C11 GE-Proton", fo.is_proton_tool("GE-Proton8-32") == true)
  check("C11 empty -> false (native)", fo.is_proton_tool("") == false)
  check("C11 nil -> false", fo.is_proton_tool(nil) == false)
  check("C11 steamlinuxruntime -> false", fo.is_proton_tool("steamlinuxruntime_soldier") == false)
end

-- ---------------------------------------------------------------------------
-- overrides_for_install_dir(fs_impl, install_path): scan a game folder
-- (recursively) for fix DLLs and return the WINEDLLOVERRIDES string, or nil.
-- fs_impl is injected so we can unit-test without Millennium. It must expose
-- list_recursive(path) -> entries with .name / .is_directory (matching the
-- Millennium fs module the backend uses).
-- ---------------------------------------------------------------------------

local function fake_fs(entries)
  return {
    list_recursive = function(_)
      return entries
    end,
  }
end

-- C12: finds DLLs nested anywhere in the tree, ignores directories/non-dll.
do
  local ffs = fake_fs({
    { name = "Game.exe", is_directory = false },
    { name = "OnlineFix64.dll", is_directory = false },
    { name = "bin", is_directory = true },
    { name = "steam_api64.dll", is_directory = false },
    { name = "readme.txt", is_directory = false },
  })
  local s = fo.overrides_for_install_dir(ffs, "/games/foo")
  check("C12 builds override from tree", s ~= nil)
  check("C12 has OnlineFix64", s and s:find("OnlineFix64=n") ~= nil)
  check("C12 has steam_api64", s and s:find("steam_api64=n") ~= nil)
end

-- C13: no fix DLLs in the tree -> nil.
do
  local ffs = fake_fs({
    { name = "Game.exe", is_directory = false },
    { name = "data.pak", is_directory = false },
  })
  check("C13 no dlls -> nil", fo.overrides_for_install_dir(ffs, "/games/bar") == nil)
end

-- C14: fs failure (nil/empty) -> nil, no crash.
do
  local ffs = { list_recursive = function(_) return nil end }
  check("C14 fs nil -> nil", fo.overrides_for_install_dir(ffs, "/x") == nil)
  check("C14 bad fs -> nil", fo.overrides_for_install_dir(nil, "/x") == nil)
end

if fails == 0 then
  io.write("\nALL TESTS OK\n")
else
  io.write("\n" .. fails .. " FAILED\n")
  os.exit(1)
end
