#!/usr/bin/env luajit
-- Unit tests for linux/backend/launcherfix.lua
--
-- A crack/bypass archive sometimes ships its OWN launcher (FC25's Launcher.exe,
-- an EA/Denuvo unlocker, ...) that must be run INSTEAD of the game's default
-- exe. On Linux/Proton the proven way to point Steam's Play button at a
-- different exe (without knowing the game's default exe name) is a launch
-- option that wraps %command% with a bash exec that swaps the last argument
-- (the exe Proton runs) for the launcher:
--
--   bash -c 'exec "${@:1:$#-1}" "<launcher>"' -- %command%
--
-- launcherfix is PURE (no Millennium deps) so it can be unit-tested with a
-- stock lua interpreter. It:
--   * recognises a launcher exe by name (is_launcher),
--   * picks the best launcher among the crack's shipped exes (pick),
--   * builds the redirect launch-option fragment (build_redirect),
--   * merges it into the user's existing options, composing with a leading
--     WINEDLLOVERRIDES env prefix and a single %command% (merge_launch_options),
--   * strips it back out for Un-Fix (remove_redirect),
--   * resolves the launcher from the crack manifest downloader.sh writes
--     (.slssteam_fix_launchers) (launcher_for_install_dir).
--
-- Run from the repo root:  luajit scripts/test-launcherfix.lua

package.path = "linux/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then io.write("ok " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

local lf = dofile("linux/backend/launcherfix.lua")

-- The redirect simply points Steam at the launcher exe (in quotes) followed by
-- %command%. Steam runs the leading exe through the game's Proton; the launcher
-- then starts the game itself. Proven manually: '"<path>" %command%'.
local function redir(p) return string.format([["%s" %%command%%]], p) end

-- ---------------------------------------------------------------------------
-- is_launcher: launcher.exe / launcher_*.exe / *_launcher.exe (case-insens.)
-- ---------------------------------------------------------------------------
do
  check("A1 exact launcher.exe", lf.is_launcher("launcher.exe") == true)
  check("A2 case-insensitive", lf.is_launcher("Launcher.EXE") == true)
  check("A3 launcher_ prefix", lf.is_launcher("Launcher_x64.exe") == true)
  check("A4 _launcher suffix", lf.is_launcher("FC25_Launcher.exe") == true)
  check("A5 basename of a path", lf.is_launcher("tools/game_launcher.exe") == true)
  check("A6 plain game exe -> no", lf.is_launcher("FIFA23.exe") == false)
  check("A7 not an exe -> no", lf.is_launcher("launcher.txt") == false)
  check("A8 substring only -> no", lf.is_launcher("relauncher.exe") == false)
  check("A9 launchpad -> no", lf.is_launcher("launchpad.exe") == false)
  check("A10 nil/empty -> no", lf.is_launcher(nil) == false and lf.is_launcher("") == false)
end

-- ---------------------------------------------------------------------------
-- pick: choose the best launcher relpath from a list (prefer exact basename
-- launcher.exe, else shallowest path, else first). Ignores non-launchers.
-- ---------------------------------------------------------------------------
do
  check("B1 prefers exact launcher.exe",
        lf.pick({ "data/x.exe", "Launcher.exe", "tools/game_launcher.exe" }) == "Launcher.exe")
  check("B2 no exact -> shallowest",
        lf.pick({ "a/b/c/foo_launcher.exe", "x_launcher.exe" }) == "x_launcher.exe")
  check("B3 ignores non-launchers", lf.pick({ "game.exe", "data.bin" }) == nil)
  check("B4 empty -> nil", lf.pick({}) == nil)
  check("B5 not a table -> nil", lf.pick(nil) == nil)
  check("B6 normalises backslashes",
        lf.pick({ "sub\\Launcher_64.exe" }) == "sub/Launcher_64.exe")
end

-- ---------------------------------------------------------------------------
-- build_redirect: the launch-option fragment '"<path>" %command%'.
-- ---------------------------------------------------------------------------
do
  check("C1 basic redirect",
        lf.build_redirect("/games/FIFA 23/Launcher.exe")
          == redir("/games/FIFA 23/Launcher.exe"))
  check("C2 nil/empty -> nil",
        lf.build_redirect(nil) == nil and lf.build_redirect("") == nil)
  -- a single quote in the path is fine inside the double quotes (no escaping).
  check("C3 single quote passes through",
        lf.build_redirect("/g/it's/L.exe") == [["/g/it's/L.exe" %command%]])
end

-- ---------------------------------------------------------------------------
-- merge_launch_options: compose redirect into current options.
-- ---------------------------------------------------------------------------
local L1 = "/games/FIFA 23/Launcher.exe"
local L2 = "/games/FIFA 23/Other_launcher.exe"
do
  check("D1 empty -> redirect alone", lf.merge_launch_options("", L1) == redir(L1))
  check("D2 bare %command% -> redirect alone",
        lf.merge_launch_options("%command%", L1) == redir(L1))
  check("D3 keeps WINEDLLOVERRIDES env prefix",
        lf.merge_launch_options('WINEDLLOVERRIDES="x=n" %command%', L1)
          == 'WINEDLLOVERRIDES="x=n" ' .. redir(L1))
  check("D4 keeps a wrapper prefix",
        lf.merge_launch_options("mangohud %command%", L1)
          == "mangohud " .. redir(L1))
  check("D5 idempotent (re-apply same launcher)",
        lf.merge_launch_options(lf.merge_launch_options('WINEDLLOVERRIDES="x=n" %command%', L1), L1)
          == 'WINEDLLOVERRIDES="x=n" ' .. redir(L1))
  check("D6 re-points to a new launcher (old redirect gone)",
        lf.merge_launch_options(lf.merge_launch_options("%command%", L1), L2)
          == redir(L2))
  check("D7 options without %command% gain one",
        lf.merge_launch_options("-foo", L1) == "-foo " .. redir(L1))
end

-- ---------------------------------------------------------------------------
-- remove_redirect: strip our wrapper for Un-Fix, restoring %command%.
-- ---------------------------------------------------------------------------
do
  check("E1 redirect alone -> cleared", lf.remove_redirect(redir(L1)) == "")
  check("E2 keeps env prefix, restores %command%",
        lf.remove_redirect('WINEDLLOVERRIDES="x=n" ' .. redir(L1))
          == 'WINEDLLOVERRIDES="x=n" %command%')
  check("E3 keeps wrapper prefix",
        lf.remove_redirect("mangohud " .. redir(L1)) == "mangohud %command%")
  check("E4 no redirect -> unchanged",
        lf.remove_redirect("mangohud %command%") == "mangohud %command%")
  check("E5 empty -> empty", lf.remove_redirect("") == "")
end

-- ---------------------------------------------------------------------------
-- launcher_for_install_dir: resolve the launcher abs path from the crack
-- manifest (.slssteam_fix_launchers) downloader.sh writes. read_file injected.
-- ---------------------------------------------------------------------------
do
  local function reader_with(content)
    return function(path)
      if path == "/games/FIFA 23/.slssteam_fix_launchers" then return content end
      return nil
    end
  end
  check("F1 resolves abs path from manifest",
        lf.launcher_for_install_dir("/games/FIFA 23", reader_with("Launcher.exe\n"))
          == "/games/FIFA 23/Launcher.exe")
  check("F2 trailing slash on install path tolerated",
        lf.launcher_for_install_dir("/games/FIFA 23/", reader_with("Launcher.exe\n"))
          == "/games/FIFA 23/Launcher.exe")
  check("F3 picks best of several",
        lf.launcher_for_install_dir("/games/FIFA 23",
            reader_with("tools/a_launcher.exe\nLauncher.exe\n"))
          == "/games/FIFA 23/Launcher.exe")
  check("F4 no manifest -> nil",
        lf.launcher_for_install_dir("/games/FIFA 23", function(_) return nil end) == nil)
  check("F5 empty install path -> nil",
        lf.launcher_for_install_dir("", reader_with("Launcher.exe\n")) == nil)
  check("F6 manifest with no launcher entry -> nil",
        lf.launcher_for_install_dir("/games/FIFA 23", reader_with("# nothing\n")) == nil)
end

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
