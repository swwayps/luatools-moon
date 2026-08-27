#!/usr/bin/env luajit
-- Unit tests for plugin/backend/launchopts.lua: read a game's current Steam
-- "Launch Options" string out of localconfig.vdf, so the online-fix flow can
-- MERGE its WINEDLLOVERRIDES into the user's existing options (e.g. mangohud,
-- gamemoderun) instead of clobbering them. localconfig.vdf is the reliable
-- source (the in-page appDetailsStore read is unreliable from the store page).
--
-- Run from the repo root:  luajit scripts/test-launchopts.lua

package.path = "plugin/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then io.write("ok " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

local lo = dofile("plugin/backend/launchopts.lua")

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

-- ── launchopts.read: no shell involved ──────────────────────────────────────
-- read() used to enumerate the per-user config files with
--   io.popen("ls -1 " .. glob)
-- where the glob was built from $HOME with NO quoting at all. A Steam library or
-- home directory containing a space, a quote or a $(...) was enough to break the
-- listing, and in the substitution case to run something. It now walks the
-- directory tree directly.
do
  local walked = {}
  local files = {
    ["/h/.steam/steam/userdata/111/config/localconfig.vdf"] = LC,
    ["/h/.steam/steam/userdata/222/config/localconfig.vdf"] = "",
  }
  -- The injected lister receives a DIRECTORY and returns its entries, so no
  -- pattern is ever handed to a shell.
  local function list_dir(dir)
    walked[#walked + 1] = dir
    if dir == "/h/.steam/steam/userdata" then return { "111", "222" } end
    return {}
  end
  local function read_file(path) return files[path] end

  check("R1 reads options from a per-user config",
    lo.read(285900, "/h", list_dir, read_file) == "mangohud %command%")
  check("R2 the lister is given a directory, never a glob",
    walked[1] == "/h/.steam/steam/userdata")
  local globbed = false
  for _, d in ipairs(walked) do
    if d:find("*", 1, true) then globbed = true end
  end
  check("R3 no wildcard is ever passed to the lister", not globbed)
  check("R4 an unknown app yields empty",
    lo.read(999999, "/h", list_dir, read_file) == "")
  check("R5 no HOME yields empty", lo.read(285900, "", list_dir, read_file) == "")
end

do
  -- A home directory with shell metacharacters must be handled as data. With the
  -- old `ls -1 <glob>` this either listed nothing or executed the substitution.
  local hostile = "/h/we ird$(touch /tmp/lo-injected)'\"`x`"
  local seen = {}
  local function list_dir(dir) seen[#seen + 1] = dir; return {} end
  lo.read(285900, hostile, list_dir, function() return nil end)
  local ok_pass = false
  for _, d in ipairs(seen) do
    if d == hostile .. "/.steam/steam/userdata" then ok_pass = true end
  end
  check("R6 a hostile home is passed through verbatim as a path", ok_pass)
  local f = io.open("/tmp/lo-injected", "r")
  if f then f:close() end
  check("R7 nothing was executed", f == nil)
  os.remove("/tmp/lo-injected")
end

do
  -- The module must not contain a shell listing at all.
  local f = assert(io.open("plugin/backend/launchopts.lua", "r"))
  local source = f:read("*a")
  f:close()
  -- Comments may still describe the old behaviour; only code matters here.
  local code = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^%s*%-%-") then code[#code + 1] = line end
  end
  code = table.concat(code, "\n")
  check("R8 no io.popen in launchopts code", code:find("io.popen", 1, true) == nil)
  check("R9 no ls shell-out in launchopts code", code:find("ls -1", 1, true) == nil)
  check("R10 no os.execute in launchopts code",
    code:find("os.execute", 1, true) == nil)
end

if fails == 0 then io.write("\nALL READ TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
