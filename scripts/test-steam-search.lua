-- Contract test for the Steam catalog RPC used by Lumen's Add game typeahead.
-- Run from the repository root: lua5.4 scripts/test-steam-search.lua

local MOCK_RESP, MOCK_DATA, LAST_URL, LAST_OPTIONS
local function preload(name, mod) package.preload[name] = function() return mod end end

local function is_array(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
  end
  for index = 1, count do if value[index] == nil then return false end end
  return count > 0
end

local function escape(value)
  return tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function encode(value)
  if type(value) == "table" then
    local parts = {}
    if is_array(value) then
      for _, item in ipairs(value) do parts[#parts + 1] = encode(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
      parts[#parts + 1] = '"' .. escape(key) .. '":' .. encode(item)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(value) == "string" then
    return '"' .. escape(value) .. '"'
  elseif type(value) == "boolean" or type(value) == "number" then
    return tostring(value)
  end
  return "null"
end

preload("json", { encode = encode, decode = function() return MOCK_DATA end })
preload("utils", { read_file = function() return nil end, write_file = function() return true end })
preload("plugin_logger", { log = function() end, warn = function() end, info = function() end, error = function() end })
preload("millennium", { version = function() return "test" end, add_browser_css = function() end,
  add_browser_js = function() end, ready = function() end })
preload("fs", { exists = function() return false end, join = function(...) return table.concat({ ... }, "/") end,
  create_directories = function() return true end, remove = function() return true end })
preload("http_client", { get = function(url, options)
  LAST_URL, LAST_OPTIONS = url, options
  return MOCK_RESP
end })
preload("paths", { get_plugin_dir = function() return "/tmp" end, backend_path = function(p) return "/tmp/" .. p end })
preload("steam_utils", { detect_steam_install_path = function() return "/tmp" end })
preload("plugin_utils", { ensure_temp_download_dir = function() return "/tmp" end })
preload("locales.manager", { DEFAULT_LOCALE = "en", get_locale_manager = function()
  return { get_locale_strings = function() return {} end }
end })
preload("api_manifest", {})
preload("downloads", {})
preload("fixes", {})
preload("ryuu_auth", {})
preload("settings.manager", {})
preload("auto_update", {})

local loaded = pcall(dofile, "plugin/backend/main.lua")
local failures = 0
local function check(value, message)
  if value then print("ok   " .. message) else print("FAIL " .. message); failures = failures + 1 end
end

check(loaded and type(SearchSteamGames) == "function",
  "main backend exports SearchSteamGames")

if type(SearchSteamGames) == "function" then
  local items = {}
  for index = 1, 10 do
    items[#items + 1] = {
      id = 2200 + index, name = "Game " .. index,
      type = "app", tiny_image = "https://cdn.test/" .. index .. ".jpg",
      price = { final = 100 },
    }
  end
  items[#items + 1] = { id = 9999, name = "Package", type = "bundle" }
  items[#items + 1] = { id = "bad", name = "Broken", type = "app" }
  MOCK_RESP, MOCK_DATA = { status = 200, body = "search-results" }, { items = items }
  -- Lumen/Millennium sorts object keys before dispatch, so
  -- { language, query } reaches Lua positionally in that order.
  local result = SearchSteamGames("brazilian", "  LEGO Batman & ação  ")
  check(LAST_URL and LAST_URL:find("term=LEGO%%20Batman%%20%%26%%20a%%C3%%A7%%C3%%A3o", 1) ~= nil,
    "query is trimmed and UTF-8 URL encoded")
  check(LAST_URL and LAST_URL:find("&l=brazilian&cc=BR", 1, true) ~= nil,
    "supported Steam language is forwarded")
  check(LAST_OPTIONS and LAST_OPTIONS.timeout and LAST_OPTIONS.timeout <= 10,
    "catalog request has a bounded timeout")
  check(result:find('"success":true', 1, true) ~= nil,
    "successful catalog response is returned")
  local returned = select(2, result:gsub('"type":"app"', ""))
  check(returned == 8, "catalog response is filtered and capped at eight apps")
  check(result:find('"price"', 1, true) == nil and result:find('"bundle"', 1, true) == nil,
    "catalog response exposes only sanitized app fields")

  MOCK_RESP, MOCK_DATA, LAST_URL = { status = 200, body = "empty" }, { items = {} }, nil
  result = SearchSteamGames("invalid-locale", "nothing")
  check(LAST_URL and LAST_URL:find("&l=english&cc=BR", 1, true) ~= nil,
    "unsupported language falls back to English")
  check(result:find('"items":[]', 1, true) ~= nil,
    "empty catalog result serializes as an array")

  MOCK_RESP, MOCK_DATA = { status = 503, body = "unavailable" }, nil
  result = SearchSteamGames("english", "lego")
  check(result:find('"success":false', 1, true) ~= nil,
    "HTTP errors produce a failed RPC response")

  LAST_URL = nil
  result = SearchSteamGames("english", "   ")
  check(result:find('"success":false', 1, true) ~= nil and LAST_URL == nil,
    "blank searches are rejected without a network request")
end

if failures > 0 then os.exit(1) end
print("test-steam-search: ALL PASS")
