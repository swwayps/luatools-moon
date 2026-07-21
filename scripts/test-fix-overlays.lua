#!/usr/bin/env luajit
-- Unit tests for plugin/backend/fix_overlays.lua
--
-- fix_overlays is a PURE module (no Millennium deps) that:
--   * scans a directory for the Windows DLLs an online/generic fix ships
--     and builds the matching WINEDLLOVERRIDES string, and
--   * merges that override into an existing Steam launch-options string
--     idempotently, preserving the user's existing options and %command%.
--
-- Run from the repo root:  luajit scripts/test-fix-overlays.lua

package.path = "plugin/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then
    io.write("ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. "\n")
    fails = fails + 1
  end
end

local fo = dofile("plugin/backend/fix_overlays.lua")

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

-- C6b: a WINEDLLOVERRIDES is an ENV assignment, so it must sit at the very
-- FRONT -- before any wrapper like mangohud/gamemoderun. Steam only treats
-- leading VAR=VALUE tokens as environment; one placed after a wrapper is
-- passed as an argument to that wrapper and the override silently never
-- applies. So the override must precede the wrapper, not just %command%.
do
  local r = fo.merge_launch_options("mangohud %command%", OV)
  check("C6b override at the very front",
        r:sub(1, #OV) == OV)
  check("C6b wrapper after override", r:find("mangohud") > r:find("WINEDLLOVERRIDES"))
  check("C6b single %command%", select(2, r:gsub("%%command%%", "")) == 1)
  -- also ahead of a user's own earlier env assignment? both still precede the
  -- wrapper, which is what matters; our override just needs to be at front.
  local r2 = fo.merge_launch_options("gamemoderun %command%", OV)
  check("C6b2 override before gamemoderun", r2:find("gamemoderun") > r2:find("WINEDLLOVERRIDES"))
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

-- C12: self-heal a corrupted current that already has a DUPLICATE %command%
-- (a prior buggy apply). The result must contain EXACTLY ONE %command%.
do
  local r = fo.merge_launch_options("mangohud %command% %command%", OV)
  check("C12 single %command%", select(2, r:gsub("%%command%%", "")) == 1)
  check("C12 keeps mangohud", r:find("mangohud") ~= nil)
  check("C12 has override", r:find("WINEDLLOVERRIDES=") ~= nil)
  -- also when the dupe sits next to a stale override
  local r2 = fo.merge_launch_options('WINEDLLOVERRIDES="old=n" mangohud %command% %command%', OV)
  check("C12b single %command%", select(2, r2:gsub("%%command%%", "")) == 1)
  check("C12b single override", select(2, r2:gsub("WINEDLLOVERRIDES=", "")) == 1)
end

-- ---------------------------------------------------------------------------
-- remove_overrides(current): the Un-Fix inverse of merge_launch_options. Strip
-- the WINEDLLOVERRIDES assignment, restoring the user's original launch
-- options. A bare "%command%" left behind (fix had added the override to an
-- empty field) collapses to "" so the field clears fully.
-- ---------------------------------------------------------------------------

-- E1: override added to an empty field -> fully cleared.
do
  local r = fo.remove_overrides('WINEDLLOVERRIDES="OnlineFix64=n" %command%')
  check("E1 cleared to empty", r == "")
end

-- E2: override + user options -> keeps the user options & %command%.
do
  local r = fo.remove_overrides('WINEDLLOVERRIDES="OnlineFix64=n;winmm=n,b" mangohud %command%')
  check("E2 keeps mangohud", r == "mangohud %command%")
  check("E2 no override left", r:find("WINEDLLOVERRIDES=") == nil)
end

-- E3: no override present -> unchanged.
do
  local r = fo.remove_overrides("game-performance mangohud %command%")
  check("E3 unchanged", r == "game-performance mangohud %command%")
end

-- E4: empty / nil -> "".
do
  check("E4 empty", fo.remove_overrides("") == "")
  check("E4 nil", fo.remove_overrides(nil) == "")
end

-- E5: unquoted override form is stripped too.
do
  local r = fo.remove_overrides("WINEDLLOVERRIDES=steam_api64=n mangohud %command%")
  check("E5 unquoted stripped", r == "mangohud %command%")
end

-- E6: override only, no %command% -> "".
do
  check("E6 override only", fo.remove_overrides('WINEDLLOVERRIDES="x=n"') == "")
end

-- E7: round-trip with merge is idempotent and reversible.
do
  local merged = fo.merge_launch_options("mangohud %command%", OV)
  local back = fo.remove_overrides(merged)
  check("E7 reverses merge", back == "mangohud %command%")
  check("E7 remove idempotent", fo.remove_overrides(back) == back)
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

-- ---------------------------------------------------------------------------
-- parse_dlllist / build_overrides_from_list / dlllist.txt handling.
-- A fix's dlllist.txt is honoured (every named DLL forced, system-proxy names
-- chained native+builtin, the rest native only) AND unioned with the
-- recognised fix DLLs found in the folder, so a short/incomplete dlllist never
-- suppresses a DLL the game actually needs.
-- ---------------------------------------------------------------------------

-- D1: parse tolerates CRLF, spaces, comments, path prefixes, non-dll lines.
do
  local list = fo.parse_dlllist("OnlineFix64.dll\r\n  winmm.dll \n# comment\nnotes.txt\nBin/dsound.dll\n")
  check("D1 count", #list == 3)
  check("D1 keeps OnlineFix64", list[1] == "OnlineFix64.dll")
  check("D1 trims winmm", list[2] == "winmm.dll")
  check("D1 strips path prefix", list[3] == "dsound.dll")
end
check("D1 non-string -> empty", #fo.parse_dlllist(nil) == 0)

-- D2: build_overrides_from_list forces ALL named DLLs (not allowlist-limited);
-- uncommon system proxies chain n,b.
do
  local s = fo.build_overrides_from_list({ "EMP.dll", "dsound.dll", "uplay_r1_loader64.dll" })
  check("D2 EMP native", s:find("EMP=n") ~= nil)
  check("D2 dsound native+builtin (uncommon proxy)", s:find("dsound=n,b") ~= nil)
  check("D2 uplay loader native", s:find("uplay_r1_loader64=n") ~= nil)
  check("D2 quoted", s:sub(1, #'WINEDLLOVERRIDES="') == 'WINEDLLOVERRIDES="' and s:sub(-1) == '"')
end
check("D2 empty -> nil", fo.build_overrides_from_list({}) == nil)
check("D2 no dll -> nil", fo.build_overrides_from_list({ "readme.txt" }) == nil)

-- D3: case-insensitive dedup, preserves first-seen casing.
do
  local s = fo.build_overrides_from_list({ "WinMM.dll", "winmm.dll" })
  check("D3 single winmm", select(2, s:gsub("[Ww]in[Mm][Mm]=", "")) == 1)
end

-- D4: overrides_for_install_dir prefers a dlllist.txt when present, reading it
-- via the injected reader; uses its names verbatim over the allowlist scan.
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "OnlineFix64.dll", path = "/g/OnlineFix64.dll", is_directory = false },
        { name = "dsound.dll", path = "/g/dsound.dll", is_directory = false },
        { name = "dlllist.txt", path = "/g/dlllist.txt", is_directory = false },
      }
    end,
  }
  local reader = function(p) return p == "/g/dlllist.txt" and "OnlineFix64.dll\ndsound.dll\n" or nil end
  local s = fo.overrides_for_install_dir(ffs, "/g", reader)
  check("D4 uses dlllist OnlineFix64", s and s:find("OnlineFix64=n") ~= nil)
  check("D4 dlllist covers dsound (not in allowlist)", s and s:find("dsound=n,b") ~= nil)
end

-- D5: empty/missing dlllist.txt -> fall back to the allowlist scan.
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "steam_api64.dll", path = "/g/steam_api64.dll", is_directory = false },
        { name = "dlllist.txt", path = "/g/dlllist.txt", is_directory = false },
      }
    end,
  }
  local reader = function(_) return "" end  -- empty dlllist
  local s = fo.overrides_for_install_dir(ffs, "/g", reader)
  check("D5 falls back to allowlist scan", s and s:find("steam_api64=n") ~= nil)
end

-- D6: a SHORT/incomplete dlllist.txt must NOT suppress the folder DLLs. Many
-- OnlineFix payloads ship a dlllist.txt that names only OnlineFix64.dll (the
-- list the loader reads), yet the folder also carries SteamOverlay64/winmm/
-- dnet/steam_api64/winhttp -- all of which need a Wine override or the game
-- won't actually connect. The result must UNION the dlllist with every
-- recognised fix DLL present in the folder. (Meccha Chameleon regression.)
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "OnlineFix64.dll", path = "/g/OnlineFix64.dll", is_directory = false },
        { name = "SteamOverlay64.dll", path = "/g/SteamOverlay64.dll", is_directory = false },
        { name = "winmm.dll", path = "/g/winmm.dll", is_directory = false },
        { name = "dnet.dll", path = "/g/dnet.dll", is_directory = false },
        { name = "steam_api64.dll", path = "/g/steam_api64.dll", is_directory = false },
        { name = "winhttp.dll", path = "/g/winhttp.dll", is_directory = false },
        { name = "OnlineFix.ini", path = "/g/OnlineFix.ini", is_directory = false },
        { name = "dlllist.txt", path = "/g/dlllist.txt", is_directory = false },
      }
    end,
  }
  local reader = function(p) return p == "/g/dlllist.txt" and "OnlineFix64.dll\n" or nil end
  local s = fo.overrides_for_install_dir(ffs, "/g", reader)
  check("D6 keeps OnlineFix64", s and s:find("OnlineFix64=n") ~= nil)
  check("D6 adds SteamOverlay64 from folder", s and s:find("SteamOverlay64=n") ~= nil)
  check("D6 adds winmm (n,b) from folder", s and s:find("winmm=n,b") ~= nil)
  check("D6 adds dnet from folder", s and s:find("dnet=n") ~= nil)
  check("D6 adds steam_api64 from folder", s and s:find("steam_api64=n") ~= nil)
  check("D6 adds winhttp (n,b) from folder", s and s:find("winhttp=n,b") ~= nil)
  check("D6 single OnlineFix64 (no dupe)",
        s and select(2, s:gsub("OnlineFix64=", "")) == 1)
  check("D6 ignores OnlineFix.ini", s and s:find("OnlineFix%.ini") == nil)
end

-- D7: a dlllist.txt naming an uncommon proxy outside the allowlist is STILL
-- honoured on top of the folder scan (union, not replacement).
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "OnlineFix64.dll", path = "/g/OnlineFix64.dll", is_directory = false },
        { name = "dsound.dll", path = "/g/dsound.dll", is_directory = false },
        { name = "dlllist.txt", path = "/g/dlllist.txt", is_directory = false },
      }
    end,
  }
  local reader = function(p) return p == "/g/dlllist.txt" and "dsound.dll\n" or nil end
  local s = fo.overrides_for_install_dir(ffs, "/g", reader)
  check("D7 dlllist proxy dsound (n,b)", s and s:find("dsound=n,b") ~= nil)
  check("D7 folder OnlineFix64 still present", s and s:find("OnlineFix64=n") ~= nil)
end

-- D8: the REAL Meccha Chameleon "Steam Generic" fix layout. DLLs live nested
-- under Binaries/Win64 and Engine/Binaries/..., and dlllist.txt names ONLY
-- OnlineFix64.dll. The proxy LOADER (winmm.dll) MUST end up overridden -- it is
-- what makes Wine run the fix chain at all -- so the previous dlllist-verbatim
-- behaviour (OnlineFix64=n only) left the game non-working.
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "winmm.dll", path = "/g/Chameleon/Binaries/Win64/winmm.dll", is_directory = false },
        { name = "OnlineFix64.dll", path = "/g/Chameleon/Binaries/Win64/OnlineFix64.dll", is_directory = false },
        { name = "OnlineFix.ini", path = "/g/Chameleon/Binaries/Win64/OnlineFix.ini", is_directory = false },
        { name = "OnlineFix.url", path = "/g/Chameleon/Binaries/Win64/OnlineFix.url", is_directory = false },
        { name = "dlllist.txt", path = "/g/Chameleon/Binaries/Win64/dlllist.txt", is_directory = false },
        { name = "EOSSDK-Win64-Shipping.dll", path = "/g/Chameleon/Binaries/Win64/RedpointEOS/EOSSDK-Win64-Shipping.dll", is_directory = false },
        { name = "EOSSDK-Win64-Shipping.of", path = "/g/Chameleon/Binaries/Win64/RedpointEOS/EOSSDK-Win64-Shipping.of", is_directory = false },
        { name = "steam_api64.dll", path = "/g/Engine/Binaries/ThirdParty/Steamworks/Steamv157/Win64/steam_api64.dll", is_directory = false },
      }
    end,
  }
  local reader = function(p)
    return p == "/g/Chameleon/Binaries/Win64/dlllist.txt" and "OnlineFix64.dll" or nil
  end
  local s = fo.overrides_for_install_dir(ffs, "/g", reader)
  check("D8 OnlineFix64 native", s and s:find("OnlineFix64=n") ~= nil)
  check("D8 winmm proxy loader (n,b) -- the fix", s and s:find("winmm=n,b") ~= nil)
  check("D8 steam_api64 native", s and s:find("steam_api64=n") ~= nil)
  check("D8 no .of treated as dll", s and s:find("Shipping%.of") == nil)
end

-- D9: a crack whose LOADER is a system proxy Wine has a builtin for (dsound)
-- with NO dlllist.txt must still be caught by the folder scan -- otherwise Wine
-- loads its builtin and the crack never runs.
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "dsound.dll", path = "/g/dsound.dll", is_directory = false },
        { name = "OnlineFix64.dll", path = "/g/OnlineFix64.dll", is_directory = false },
      }
    end,
  }
  local s = fo.overrides_for_install_dir(ffs, "/g")  -- no reader, no dlllist
  check("D9 dsound proxy loader (n,b)", s and s:find("dsound=n,b") ~= nil)
  check("D9 OnlineFix64 native", s and s:find("OnlineFix64=n") ~= nil)
end

-- ---------------------------------------------------------------------------
-- build_overrides_all / fix manifest (.slssteam_fix_dlls).
-- The manifest, written by downloader.sh at apply time, lists EXACTLY the DLLs
-- the fix/crack archive shipped (not the game's own). It is authoritative: it
-- is the only way to tell a crack DLL (arbitrary name -- voices38, Goldberg's
-- steam_api64, any cracker) from the hundreds of game DLLs they get extracted
-- next to. Every listed DLL is forced =n,b (matches the proven community
-- launch line), so the override is crack-agnostic instead of name-allowlisted.
-- ---------------------------------------------------------------------------

-- M1: build_overrides_all forces n,b for every named DLL, dedups case-insensitively.
do
  local s = fo.build_overrides_all({ "steam_api64.dll", "voices38.dll", "Voices38.dll", "data.bin" })
  check("M1 steam_api64 n,b", s and s:find("steam_api64=n,b") ~= nil)
  check("M1 voices38 n,b", s and s:find("voices38=n,b") ~= nil)
  check("M1 dedup voices38", s and select(2, s:gsub("[Vv]oices38=", "")) == 1)
  check("M1 ignores non-dll", s and s:find("data") == nil)
  check("M1 quoted", s and s:sub(1, #'WINEDLLOVERRIDES="') == 'WINEDLLOVERRIDES="' and s:sub(-1) == '"')
end
check("M1 empty -> nil", fo.build_overrides_all({}) == nil)
check("M1 no dll -> nil", fo.build_overrides_all({ "readme.txt" }) == nil)

-- M2: overrides_for_install_dir uses the manifest when present, forcing EXACTLY
-- the crack's DLLs (voices38 + steam_api64) and NOT the game's own DLLs
-- (d3d11.dll, the game exe) that sit in the same tree.
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "SonicFrontiers.exe", path = "/g/SonicFrontiers.exe", is_directory = false },
        { name = "steam_api64.dll", path = "/g/steam_api64.dll", is_directory = false },
        { name = "voices38.dll", path = "/g/voices38.dll", is_directory = false },
        { name = "d3d11.dll", path = "/g/d3d11.dll", is_directory = false },        -- game's own
        { name = ".slssteam_fix_dlls", path = "/g/.slssteam_fix_dlls", is_directory = false },
      }
    end,
  }
  local reader = function(p)
    return p == "/g/.slssteam_fix_dlls" and "steam_api64.dll\nvoices38.dll\n" or nil
  end
  local s = fo.overrides_for_install_dir(ffs, "/g", reader)
  check("M2 steam_api64 from manifest", s and s:find("steam_api64=n,b") ~= nil)
  check("M2 voices38 from manifest", s and s:find("voices38=n,b") ~= nil)
  check("M2 does NOT touch game d3d11", s and s:find("d3d11") == nil)
end

-- M3: manifest is authoritative even over a dlllist.txt (manifest = exact ship
-- list; dlllist could be a short loader-list). Manifest wins.
do
  local ffs = {
    list_recursive = function(_)
      return {
        { name = "OnlineFix64.dll", path = "/g/OnlineFix64.dll", is_directory = false },
        { name = "winmm.dll", path = "/g/winmm.dll", is_directory = false },
        { name = "dlllist.txt", path = "/g/dlllist.txt", is_directory = false },
        { name = ".slssteam_fix_dlls", path = "/g/.slssteam_fix_dlls", is_directory = false },
      }
    end,
  }
  local reader = function(p)
    if p == "/g/.slssteam_fix_dlls" then return "OnlineFix64.dll\nwinmm.dll\n" end
    if p == "/g/dlllist.txt" then return "OnlineFix64.dll" end
    return nil
  end
  local s = fo.overrides_for_install_dir(ffs, "/g", reader)
  check("M3 manifest covers winmm", s and s:find("winmm=n,b") ~= nil)
  check("M3 manifest covers OnlineFix64", s and s:find("OnlineFix64=n,b") ~= nil)
end

if fails == 0 then
  io.write("\nALL TESTS OK\n")
else
  io.write("\n" .. fails .. " FAILED\n")
  os.exit(1)
end
