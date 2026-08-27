-- Contract test for the Steam catalog RPC used by Lumen's Add game typeahead.
-- Run from the repository root: lua5.4 scripts/test-steam-search.lua

local MOCK_RESP, MOCK_RESPONSES, MOCK_DATA, LAST_URL, LAST_OPTIONS, REQUEST_COUNT
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
  REQUEST_COUNT = (REQUEST_COUNT or 0) + 1
  if type(MOCK_RESPONSES) == "table" and #MOCK_RESPONSES > 0 then
    return table.remove(MOCK_RESPONSES, 1)
  end
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
preload("lua_tools_auth", {})
preload("lua_tools_fixes", {})
preload("lua_tools_fix_state", {})
preload("lua_tools_fix_index", {})
preload("lua_tools_recommended_add", {})
preload("lua_tools_auto_fix", { tick = function() return { success = true } end })
preload("settings.manager", {})
preload("auto_update", {})

local loaded, load_error = pcall(dofile, "plugin/backend/main.lua")
if not loaded then io.stderr:write("main.lua load failed: " .. tostring(load_error) .. "\n") end
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
      appid = tostring(2200 + index), name = "Game " .. index,
      logo = "https://cdn.test/" .. index .. ".jpg",
    }
  end
  items[#items + 1] = { appid = "bad", name = "Broken" }
  MOCK_RESP, MOCK_DATA = { status = 200, body = "search-results" }, items
  -- Lumen/Millennium sorts object keys before dispatch, so
  -- { language, query } reaches Lua positionally in that order.
  local result = SearchSteamGames("brazilian", "  LEGO Batman & ação  ")
  check(LAST_URL and LAST_URL:find(
      "steamcommunity.com/actions/SearchApps/LEGO%%20Batman%%20%%26%%20a%%C3%%A7%%C3%%A3o", 1) ~= nil,
    "global community query is trimmed and UTF-8 URL encoded")
  check(LAST_URL and LAST_URL:find("cc=", 1, true) == nil,
    "catalog search never pins a country")
  check(LAST_OPTIONS and LAST_OPTIONS.timeout and LAST_OPTIONS.timeout <= 10,
    "catalog request has a bounded timeout")
  check(LAST_OPTIONS and LAST_OPTIONS.max_bytes and LAST_OPTIONS.max_bytes <= 512 * 1024,
    "catalog response size is bounded")
  check(result:find('"success":true', 1, true) ~= nil,
    "successful catalog response is returned")
  local returned = select(2, result:gsub('"type":"app"', ""))
  check(returned == 8, "catalog response is filtered and capped at eight apps")
  check(result:find('"logo"', 1, true) == nil and result:find('"appid"', 1, true) == nil,
    "community response exposes only normalized app fields")

  MOCK_RESP, MOCK_DATA, LAST_URL = { status = 200, body = "empty" }, {}, nil
  result = SearchSteamGames("invalid-locale", "nothing")
  check(LAST_URL and LAST_URL:find("steamcommunity.com/actions/SearchApps/nothing", 1, true) ~= nil,
    "search remains global for unsupported UI languages")
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

check(type(GetSteamAppDetails) == "function",
  "main backend exports GetSteamAppDetails")

if type(GetSteamAppDetails) == "function" then
  MOCK_RESP, MOCK_DATA, LAST_URL = { status = 200, body = "product-info" }, {
    data = { ["320240"] = {
      common = { name = "We Happy Few", type = "Game" },
      extended = { listofdlc = "826260,919000,974570" },
    } },
  }, nil
  local result = GetSteamAppDetails({ appid = 320240 })
  check(LAST_URL == "https://api.steamcmd.net/v1/info/320240",
    "identity lookup uses global product info without a country")
  check(LAST_OPTIONS and LAST_OPTIONS.max_bytes and LAST_OPTIONS.max_bytes <= 4 * 1024 * 1024,
    "global product-info response size is bounded")
  check(result:find('"metadataAvailable":true', 1, true) ~= nil
      and result:find('"type":"game"', 1, true) ~= nil
      and result:find('"name":"We Happy Few"', 1, true) ~= nil,
    "base-game identity is normalized from product info")
  check(result:find("826260", 1, true) ~= nil and result:find("974570", 1, true) ~= nil,
    "global identity includes official DLC appids")

  MOCK_DATA = { data = { ["919000"] = {
    common = { name = "We Happy Few - Season Pass", type = "DLC", parent = "320240" },
    extended = {},
  } } }
  result = GetSteamAppDetails(919000)
  check(result:find('"type":"dlc"', 1, true) ~= nil
      and result:find('"fullgameAppid":320240', 1, true) ~= nil,
    "DLC identity preserves its global parent relation")

  MOCK_DATA = { data = { ["320240"] = {
    common = { name = "Malformed", type = true }, extended = {},
  } } }
  result = GetSteamAppDetails(320240)
  check(result:find('"metadataAvailable":false', 1, true) ~= nil,
    "malformed product-info type fails closed")

  MOCK_DATA = { data = { ["320240"] = {
    common = { name = "We Happy Few", type = "Game" }, extended = {},
  } } }
  MOCK_RESPONSES = {
    { status = 503, body = "temporary failure" },
    { status = 200, body = "product-info" },
  }
  REQUEST_COUNT = 0
  result = GetSteamAppDetails(320240)
  check(REQUEST_COUNT == 2 and result:find('"metadataAvailable":true', 1, true) ~= nil,
    "global product info retries one transient failure")

  MOCK_RESP, MOCK_RESPONSES, MOCK_DATA = { status = 503, body = "unavailable" }, nil, nil
  result = GetSteamAppDetails(320240)
  check(result:find('"success":true', 1, true) ~= nil
      and result:find('"metadataAvailable":false', 1, true) ~= nil,
    "unavailable global metadata remains a fail-closed identity result")
end

if failures > 0 then os.exit(1) end
print("test-steam-search: ALL PASS")
