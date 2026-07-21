-- onlinefix.lua  (Linux overlay for luatools-moon)
--
-- Resolves a Steam store-page game name to an online-fix archive on the
-- perondepot mirror (http://api.perondepot.xyz/all/), which is an nginx
-- autoindex of .rar files named:
--
--   <Game Name> по сети - <code>_Fix_Repair_<Store>[_Vn]_Generic.rar
--
-- ("по сети" = "over network"/online.) There is no appid index, so we match
-- by name. The plugin runs on the Steam store page, which exposes the exact
-- game name, so matching is name-based with normalization to absorb
-- punctuation/edition/case/trademark differences between Steam and the mirror.
--
-- PURE module (no Millennium deps) so it can be unit-tested with a stock lua
-- interpreter (scripts/test-onlinefix.lua).

local onlinefix = {}

-- Cyrillic "по сети" marker that separates the game name from the fix code.
-- Stored as literal UTF-8 bytes; matched with plain (non-pattern) find.
local MARKER = "\208\191\208\190 \209\129\208\181\209\130\208\184" -- "по сети"

-- Percent-decode a URL path component.
function onlinefix.url_decode(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- Normalize a title for matching: lowercase, keep only [a-z0-9]. This
-- collapses spaces, punctuation, colons, ™/® and any UTF-8 high bytes, so
-- "Age of Mythology: Extended Edition" == "Age of Mythology Extended Edition".
function onlinefix.normalize(name)
  if type(name) ~= "string" then return "" end
  return (name:lower():gsub("[^a-z0-9]", ""))
end

-- Extract the clean game name from a decoded ".rar" filename. The naming is
--   <Game Name>[ по сети| Online] - <code>_Fix_Repair_...rar
-- The fix <code> never contains " - " (it uses underscores), so the name is
-- everything before the LAST " - ", minus a trailing "по сети"/"Online"
-- marker. This preserves names that themselves contain " - " (e.g.
-- "CURE - A Hospital Simulator") and handles all three separator variants.
local function clean_name(decoded)
  local s = decoded:gsub("%.rar$", "")
  -- Split on the last " - ".
  local cut
  local pos = 1
  while true do
    local a = s:find(" %- ", pos)
    if not a then break end
    cut = a
    pos = a + 1
  end
  if cut then s = s:sub(1, cut - 1) end
  -- Strip a trailing online marker (Cyrillic "по сети" or English "Online").
  local m = s:find(MARKER, 1, true)
  if m then
    s = s:sub(1, m - 1)
  else
    s = s:gsub("%s+[Oo]nline%s*$", "")
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parse the autoindex HTML into entries { name = <decoded game name>,
-- href = <raw percent-encoded filename, for fetching> }. Ignores non-.rar
-- links (../, readme, etc.).
function onlinefix.parse_index(html)
  local out = {}
  if type(html) ~= "string" then return out end
  for href in html:gmatch('href="([^"]-%.rar)"') do
    local name = clean_name(onlinefix.url_decode(href))
    if name ~= "" then
      out[#out + 1] = { name = name, href = href }
    end
  end
  return out
end

-- Resolve a Steam game name to its fix entry, or nil. Exact normalized match.
function onlinefix.find_fix(html, game_name)
  if type(game_name) ~= "string" or game_name == "" then return nil end
  local target = onlinefix.normalize(game_name)
  if target == "" then return nil end
  for _, e in ipairs(onlinefix.parse_index(html)) do
    if onlinefix.normalize(e.name) == target then
      return e
    end
  end
  return nil
end

return onlinefix
