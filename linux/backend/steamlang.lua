-- steamlang.lua  (Linux overlay for luatools-moon)
--
-- Detects the Steam client language and maps it to a LuaTools locale code so
-- the "Use Steam Language" setting actually follows Steam. Upstream's
-- _detect_steam_language() was a stub returning "en" (Millennium couldn't read
-- the registry); on Linux the language lives in ~/.steam/registry.vdf as
--   "language"  "brazilian"
-- (Steam's own language NAME). We map that name to the locale code LuaTools
-- ships (e.g. brazilian -> pt-BR), defaulting to "en".
--
-- PURE module (no Millennium deps) so it can be unit-tested with a stock lua
-- interpreter (scripts/test-steamlang.lua).

local steamlang = {}

-- Steam client language name -> LuaTools locale code. Only codes that have a
-- locale file are listed; anything else falls back to "en".
local MAP = {
  english = "en", brazilian = "pt-BR", portuguese = "pt", spanish = "es",
  latam = "es", russian = "ru", german = "de", french = "fr", italian = "it",
  dutch = "nl", polish = "pl", danish = "da", finnish = "fi",
  norwegian = "no", swedish = "sv", czech = "cs", hungarian = "hu",
  romanian = "ro", bulgarian = "bg", greek = "el", turkish = "tr",
  ukrainian = "uk", thai = "th", vietnamese = "vi", japanese = "ja",
  koreana = "ko", schinese = "zh-CN", tchinese = "zh-TW", arabic = "ar",
  indonesian = "id", hebrew = "he",
}

-- Map a Steam language name to a LuaTools locale code (case-insensitive), or nil.
function steamlang.map_name(name)
  if type(name) ~= "string" then return nil end
  return MAP[name:lower()]
end

-- Extract the "language" value from a registry.vdf blob, or nil.
function steamlang.parse_registry(raw)
  if type(raw) ~= "string" then return nil end
  return raw:match('"[Ll]anguage"%s*"([^"]+)"')
end

-- Detect the Steam language as a LuaTools locale code (default "en").
-- `read_file` is injectable for tests; defaults to an io-based reader.
function steamlang.detect(home, read_file)
  home = home or os.getenv("HOME") or ""
  if home == "" then return "en" end
  read_file = read_file or function(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
  end
  local candidates = {
    home .. "/.steam/registry.vdf",
    home .. "/.steam/steam/registry.vdf",
  }
  for _, p in ipairs(candidates) do
    local raw = read_file(p)
    if raw and raw ~= "" then
      local code = steamlang.map_name(steamlang.parse_registry(raw))
      if code then return code end
    end
  end
  return "en"
end

return steamlang
