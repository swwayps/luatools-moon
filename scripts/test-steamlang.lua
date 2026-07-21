#!/usr/bin/env luajit
-- Unit tests for plugin/backend/steamlang.lua (Steam client language detection).
--
-- steamlang is a PURE module: it parses the Steam client language from
-- registry.vdf and maps the Steam language NAME (e.g. "brazilian") to a
-- LuaTools locale code (e.g. "pt-BR"), defaulting to "en".
--
-- Run from the repo root:  luajit scripts/test-steamlang.lua

package.path = "plugin/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then io.write("ok " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

local sl = dofile("plugin/backend/steamlang.lua")

-- map_name: Steam language name -> LuaTools locale code (only existing locales).
check("M1 brazilian -> pt-BR", sl.map_name("brazilian") == "pt-BR")
check("M2 english -> en", sl.map_name("english") == "en")
check("M3 portuguese -> pt", sl.map_name("portuguese") == "pt")
check("M4 schinese -> zh-CN", sl.map_name("schinese") == "zh-CN")
check("M5 tchinese -> zh-TW", sl.map_name("tchinese") == "zh-TW")
check("M6 koreana -> ko", sl.map_name("koreana") == "ko")
check("M7 case-insensitive", sl.map_name("Brazilian") == "pt-BR")
check("M8 unknown -> nil", sl.map_name("klingon") == nil)
check("M9 non-string -> nil", sl.map_name(nil) == nil)

-- parse_registry: pull the language value out of a registry.vdf blob.
local REG = [[
"Registry"
{
  "HKCU"
  {
    "Software"
    {
      "Valve"
      {
        "Steam"
        {
          "language"  "brazilian"
        }
      }
    }
  }
}
]]
check("P1 parse brazilian", sl.parse_registry(REG) == "brazilian")
check("P2 parse none -> nil", sl.parse_registry('"foo" "bar"') == nil)
check("P3 non-string -> nil", sl.parse_registry(nil) == nil)

-- detect(home, read_file): injected reader for testability.
local function reader_with(map)
  return function(p) return map[p] end
end

-- D1: registry resolves -> mapped locale.
do
  local home = "/home/u"
  local r = reader_with({ ["/home/u/.steam/registry.vdf"] = REG })
  check("D1 detect brazilian -> pt-BR", sl.detect(home, r) == "pt-BR")
end

-- D2: fallback path used when the primary is missing.
do
  local home = "/home/u"
  local r = reader_with({ ["/home/u/.steam/steam/registry.vdf"] = REG })
  check("D2 fallback path -> pt-BR", sl.detect(home, r) == "pt-BR")
end

-- D3: no registry anywhere -> "en".
check("D3 no registry -> en", sl.detect("/home/u", reader_with({})) == "en")

-- D4: unknown language -> "en".
do
  local r = reader_with({ ["/home/u/.steam/registry.vdf"] = '"language" "klingon"' })
  check("D4 unknown lang -> en", sl.detect("/home/u", r) == "en")
end

-- D5: empty HOME -> "en".
check("D5 empty home -> en", sl.detect("", reader_with({})) == "en")

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
