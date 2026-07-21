#!/usr/bin/env luajit
-- Unit tests for plugin/backend/protoncompat.lua (forced compat-tool reader).
--
-- protoncompat.lua is a PURE module (no Millennium deps): it parses Steam's
-- config/config.vdf CompatToolMapping block to tell whether the user has
-- forced a Steam Play compatibility tool (Proton) for a given appid. The
-- Online Fix feature uses this to block applying a Windows online fix to a
-- title that ships a native Linux build and is NOT being forced through
-- Proton (online fixes are Windows DLLs that only load under Proton/Wine).
--
-- Run from the repo root:  luajit scripts/test-protoncompat.lua

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

local pc = dofile("plugin/backend/protoncompat.lua")

-- A trimmed but real-shaped config.vdf slice. Steam writes the per-game
-- "Force the use of a specific Steam Play compatibility tool" choice here,
-- under InstallConfigStore > Software > Valve > Steam > CompatToolMapping.
local VDF = [[
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"285900"
					{
						"name"		"proton_experimental"
						"config"		""
						"priority"		"250"
					}
					"638510"
					{
						"name"		""
						"config"		""
						"priority"		"250"
					}
					"1857080"
					{
						"name"		"GE-Proton9-20"
						"config"		""
						"priority"		"250"
					}
					"1621690"
					{
						"name"		"steamlinuxruntime_soldier"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
]]

-- ---------------------------------------------------------------------------
-- is_proton_name: a non-empty tool name that isn't a bare Linux runtime
-- counts as "running through Proton/compat" (so a Windows fix can load).
-- ---------------------------------------------------------------------------
do
  check("PN1 proton_experimental is proton", pc.is_proton_name("proton_experimental") == true)
  check("PN2 GE-Proton is proton", pc.is_proton_name("GE-Proton9-20") == true)
  check("PN3 empty string is not", pc.is_proton_name("") == false)
  check("PN4 whitespace-only is not", pc.is_proton_name("   ") == false)
  check("PN5 nil is not", pc.is_proton_name(nil) == false)
  check("PN6 linux runtime is not proton", pc.is_proton_name("steamlinuxruntime_soldier") == false)
  check("PN7 linux runtime case-insensitive", pc.is_proton_name("SteamLinuxRuntime_Sniper") == false)
end

-- ---------------------------------------------------------------------------
-- tool_for_app: pull the forced tool name for an appid out of config.vdf.
-- Returns the name string ("" when the entry exists but is unset) or nil
-- when the appid has no mapping at all.
-- ---------------------------------------------------------------------------
do
  check("T1 forced proton", pc.tool_for_app(VDF, 285900) == "proton_experimental")
  check("T2 forced proton (string appid)", pc.tool_for_app(VDF, "285900") == "proton_experimental")
  check("T3 entry present but unset -> empty", pc.tool_for_app(VDF, 638510) == "")
  check("T4 GE proton", pc.tool_for_app(VDF, 1857080) == "GE-Proton9-20")
  check("T5 linux runtime name returned verbatim", pc.tool_for_app(VDF, 1621690) == "steamlinuxruntime_soldier")
  check("T6 appid not mapped -> nil", pc.tool_for_app(VDF, 999999) == nil)
  check("T7 no substring false-match", pc.tool_for_app(VDF, 5900) == nil)
  check("T8 empty input -> nil", pc.tool_for_app("", 285900) == nil)
  check("T9 missing mapping section -> nil", pc.tool_for_app('"InstallConfigStore"\n{\n}\n', 285900) == nil)
end

-- ---------------------------------------------------------------------------
-- is_forced: end-to-end with an injected reader (no real filesystem). True
-- only when the appid is forced through a Proton/compat tool.
-- ---------------------------------------------------------------------------
do
  local reader = function(_) return VDF end
  check("F1 proton-forced appid", pc.is_forced("/home/u", 285900, reader) == true)
  check("F2 unset entry -> not forced", pc.is_forced("/home/u", 638510, reader) == false)
  check("F3 GE proton -> forced", pc.is_forced("/home/u", 1857080, reader) == true)
  check("F4 linux runtime -> not forced", pc.is_forced("/home/u", 1621690, reader) == false)
  check("F5 unmapped appid -> not forced", pc.is_forced("/home/u", 999999, reader) == false)

  -- No config.vdf anywhere -> not forced (don't block; let the user proceed).
  local none = function(_) return nil end
  check("F6 no config.vdf -> not forced", pc.is_forced("/home/u", 285900, none) == false)

  -- Empty HOME is handled gracefully.
  check("F7 empty home -> not forced", pc.is_forced("", 285900, reader) == false)
end

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
