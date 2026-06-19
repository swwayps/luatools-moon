#!/usr/bin/env luajit
-- Unit tests for linux/backend/launchopts.lua: read a game's current Steam
-- "Launch Options" string out of localconfig.vdf, so the online-fix flow can
-- MERGE its WINEDLLOVERRIDES into the user's existing options (e.g. mangohud,
-- gamemoderun) instead of clobbering them. localconfig.vdf is the reliable
-- source (the in-page appDetailsStore read is unreliable from the store page).
--
-- Run from the repo root:  luajit scripts/test-launchopts.lua

package.path = "linux/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then io.write("ok " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

local lo = dofile("linux/backend/launchopts.lua")

-- A trimmed but real-shaped localconfig.vdf slice.
local LC = [[
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"285900"
					{
						"LastPlayed"		"123"
						"LaunchOptions"		"mangohud %command%"
					}
					"638510"
					{
						"LastPlayed"		"456"
					}
					"2050650"
					{
						"LaunchOptions"		"WINEDLLOVERRIDES=\"x=n\" gamemoderun %command%"
					}
				}
			}
		}
	}
}
]]

do
  check("L1 reads launch options", lo.for_app(LC, 285900) == "mangohud %command%")
  check("L1b string appid", lo.for_app(LC, "285900") == "mangohud %command%")
  check("L2 app present, no options -> empty", lo.for_app(LC, 638510) == "")
  check("L3 escaped quotes preserved",
        lo.for_app(LC, 2050650) == 'WINEDLLOVERRIDES="x=n" gamemoderun %command%')
  check("L4 unknown app -> empty", lo.for_app(LC, 999999) == "")
  check("L5 no substring false-match", lo.for_app(LC, 5900) == "")
  check("L6 empty input -> empty", lo.for_app("", 285900) == "")
  check("L7 garbage -> empty", lo.for_app("not vdf", 285900) == "")
end

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
