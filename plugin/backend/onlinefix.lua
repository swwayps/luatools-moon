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

-- Normalize a title for matching. Most games only need lowercase ASCII words;
-- GTA mirrors also abbreviate the franchise, subtitles and edition names.
-- Expand only those GTA tokens so original and Definitive editions remain
-- distinct while "GTA SA DE" matches Steam's full display name.
function onlinefix.normalize(name)
  if type(name) ~= "string" then return "" end
  local words = {}
  for word in name:lower():gmatch("[a-z0-9]+") do words[#words + 1] = word end
  if #words == 0 then return "" end

  local gta = words[1] == "gta"
    or (words[1] == "grand" and words[2] == "theft" and words[3] == "auto")
  if not gta then return table.concat(words) end

  local out, start = { "grand", "theft", "auto" }, 1
  if words[1] == "gta" then start = 2 else start = 4 end
  local romans = { i = "1", ii = "2", iii = "3", iv = "4", v = "5", vi = "6" }
  for i = start, #words do
    local word = words[i]
    if word == "the" then
      -- Articles vary between Steam and mirror filenames.
    elseif word == "sa" then
      out[#out + 1] = "san"
      out[#out + 1] = "andreas"
    elseif word == "de" then
      out[#out + 1] = "definitive"
      out[#out + 1] = "edition"
    elseif word == "vice" and words[i + 1] ~= "city" then
      out[#out + 1] = "vice"
      out[#out + 1] = "city"
    else
      out[#out + 1] = romans[word] or word
    end
  end
  return table.concat(out)
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

-- fetch_index(deps) -> body|nil, source
-- Get the mirror's index, cheaply and with a hard ceiling on how long it may
-- take. This matters more than it looks: the plugin backend runs inside Lumen's
-- SINGLE-THREADED loop, so every second spent waiting on this third party is a
-- second in which no other RPC is answered. A mirror answering in 23s (measured)
-- used to freeze the whole Fixes Menu — a click on Crack/Bypass simply queued
-- behind it. So: serve a fresh cache without any request, bound the retries by a
-- total time budget, and prefer a stale copy over hanging.
--
-- deps = { get(url, opts), now(), read() -> {body=, at=}, write(body), ttl, budget }
onlinefix.INDEX_URL = "http://api.perondepot.xyz/all/"
onlinefix.INDEX_TTL = 600      -- seconds a cached index stays fresh
onlinefix.INDEX_BUDGET = 12    -- seconds of wall clock this call may consume
onlinefix.INDEX_TIMEOUT = 6    -- seconds per attempt

function onlinefix.fetch_index(deps)
  deps = deps or {}
  local now = deps.now or function() return os.time() end
  local ttl = deps.ttl or onlinefix.INDEX_TTL
  local budget = deps.budget or onlinefix.INDEX_BUDGET

  local cached = deps.read and deps.read() or nil
  local started = now()
  if type(cached) == "table" and cached.body and cached.body ~= ""
      and type(cached.at) == "number" and (started - cached.at) < ttl then
    return cached.body, "cache"
  end

  if deps.get then
    repeat
      local resp = deps.get(onlinefix.INDEX_URL, { timeout = onlinefix.INDEX_TIMEOUT })
      if type(resp) == "table" and resp.status == 200 and resp.body and resp.body ~= "" then
        if deps.write then deps.write(resp.body) end
        return resp.body, "network"
      end
    until (now() - started) >= budget
  end

  -- Unreachable or too slow: a stale index still answers the question for every
  -- fix that already existed, which beats a spinner that never resolves.
  if type(cached) == "table" and cached.body and cached.body ~= "" then
    return cached.body, "stale"
  end
  return nil, "unavailable"
end

return onlinefix
