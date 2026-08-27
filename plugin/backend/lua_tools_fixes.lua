local cjson = require("json")
local http_client = require("http_client")
local lua_tools_auth = require("lua_tools_auth")
local domain = require("lua_tools_domain")

local fixes = {}
local API_BASE_URL = "https://lua.tools"

local function urlencode(value)
  return (tostring(value or ""):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

local function tag_text(entry)
  local parts = { tostring(type(entry) == "table" and entry.title or "") }
  for _, tag in ipairs(type(entry) == "table" and entry.tags or {}) do
    if type(tag) == "table" then
      parts[#parts + 1] = tostring(tag.slug or "")
      parts[#parts + 1] = tostring(tag.name or "")
    else
      parts[#parts + 1] = tostring(tag)
    end
  end
  return table.concat(parts, " "):lower()
end

function fixes.classify(entry)
  local text = tag_text(entry)
  if text:find("voices38", 1, true) then return "voices38" end
  if text:find("bypass", 1, true) then return "bypass" end
  if text:find("online%-fix") or text:find("online fix", 1, true)
      or text:find("onlinefix", 1, true) then return "online_fix" end
  if text:find("freetp", 1, true) or text:find("free tp", 1, true) then return "freetp" end
  if text:find("denuvowo", 1, true) or text:find("hypervisor", 1, true) then
    return "denuvowo"
  end
  return "other"
end

local function normalize_tags(tags)
  local result = {}
  for _, tag in ipairs(type(tags) == "table" and tags or {}) do
    if type(tag) == "table" then
      result[#result + 1] = {
        name = tostring(tag.name or ""),
        slug = tostring(tag.slug or ""),
        color = tostring(tag.color or ""),
      }
    end
  end
  return result
end

local function normalize_fix(entry, source_order)
  if type(entry) ~= "table" then return nil end
  local id = domain.fix_id(entry.id)
  if not id then return nil end
  local category = fixes.classify(entry)
  return {
    id = id,
    title = tostring(entry.title or "Fix"),
    description = tostring(entry.description or ""),
    tags = normalize_tags(entry.tags),
    category = category,
    rank = domain.category_rank(category) or domain.category_rank("other"),
    requiresPreparation = category == "denuvowo",
    hasManifest = entry.hasManifest == true,
    hasFix = entry.hasFix == true,
    manifestFilename = tostring(entry.manifestFilename or ""),
    fixFilename = tostring(entry.fixFilename or ""),
    createdAt = tostring(entry.createdAt or ""),
    _sourceOrder = tonumber(source_order) or 0,
  }
end

local function auth_configured(deps)
  local ok, status = pcall((deps and deps.auth_status) or lua_tools_auth.status,
    deps and deps.auth_deps)
  return ok and type(status) == "table" and status.configured == true
end

function fixes.get_game(appid, deps)
  appid = domain.positive_appid(appid)
  if not appid then return { success = false, error = "Invalid Steam app ID.", fixes = {} } end
  deps = deps or {}
  local response = (deps.get or http_client.get)(
    API_BASE_URL .. "/api/denuvo/fixes?appid=" .. tostring(appid), { timeout = 15 })
  if type(response) ~= "table" or tonumber(response.status) ~= 200 then
    return {
      success = true, appid = appid, available = false, fixes = {},
      requiresAuth = true, authConfigured = auth_configured(deps),
    }
  end
  local ok, payload = pcall(deps.decode or cjson.decode, response.body or "")
  if not ok or type(payload) ~= "table" then
    return { success = false, error = "lua.tools returned an invalid fixes response.", fixes = {} }
  end
  local normalized = {}
  for source_order, entry in ipairs(type(payload.fixes) == "table" and payload.fixes or {}) do
    local fix = normalize_fix(entry, source_order)
    if fix then normalized[#normalized + 1] = fix end
  end
  table.sort(normalized, function(left, right)
    if left.rank ~= right.rank then return left.rank < right.rank end
    if left.createdAt ~= right.createdAt then return left.createdAt > right.createdAt end
    return left._sourceOrder < right._sourceOrder
  end)
  for _, fix in ipairs(normalized) do fix._sourceOrder = nil end
  return {
    success = true,
    appid = appid,
    name = tostring(payload.name or ("App " .. tostring(appid))),
    headerImage = tostring(payload.header_image or payload.headerImage or ""),
    available = #normalized > 0,
    fixes = normalized,
    recommended = normalized[1],
    requiresAuth = true,
    authConfigured = auth_configured(deps),
  }
end

function fixes.list_games(deps)
  deps = deps or {}
  local response = (deps.get or http_client.get)(
    API_BASE_URL .. "/api/denuvo/listings", { timeout = 20 })
  if type(response) ~= "table" or tonumber(response.status) ~= 200 then
    return { success = false, error = "lua.tools fixes catalogue is unavailable.", games = {} }
  end
  local ok, payload = pcall(deps.decode or cjson.decode, response.body or "")
  if not ok or type(payload) ~= "table" or type(payload.games) ~= "table" then
    return { success = false, error = "lua.tools returned an invalid fixes catalogue.", games = {} }
  end
  local games = {}
  for _, game in ipairs(payload.games) do
    local appid = domain.positive_appid(type(game) == "table" and game.appid)
    if appid then
      games[#games + 1] = {
        appid = appid,
        name = tostring(game.name or ("App " .. tostring(appid))),
        headerImage = tostring(game.header_image or game.headerImage or ""),
        fixCount = tonumber(game.fixCount or game.fix_count or game.count) or 0,
        tags = normalize_tags(game.tags),
      }
    end
  end
  return { success = true, games = games, tags = normalize_tags(payload.tags) }
end

function fixes.resolve_download(fix_id, slot, deps)
  fix_id = domain.fix_id(fix_id)
  if not fix_id or (slot ~= "manifest" and slot ~= "fix") then
    return nil, { code = "invalid_download", message = "Invalid lua.tools fix download." }
  end
  deps = deps or {}
  local token, token_error = (deps.get_token or lua_tools_auth.get_valid_access_token)(deps.auth_deps)
  if not token then return nil, token_error end
  local url = API_BASE_URL .. "/api/denuvo/download?fix=" .. urlencode(fix_id)
    .. "&slot=" .. urlencode(slot)
  local response = (deps.get or http_client.get)(url, {
    headers = { Authorization = "Bearer " .. token },
    timeout = 30,
    max_bytes = 1024 * 1024,
  })
  if type(response) ~= "table" or tonumber(response.status) ~= 200 then
    if type(response) == "table" and tonumber(response.status) == 401 then
      pcall((deps.clear_auth or lua_tools_auth.clear), deps.auth_deps)
      return nil, { code = "session_expired", message = "The lua.tools session expired. Sign in again." }
    end
    return nil, { code = "download_unavailable", message = "lua.tools could not prepare this download." }
  end
  local ok, payload = pcall(deps.decode or cjson.decode, response.body or "")
  local signed_url = ok and type(payload) == "table" and payload.url or nil
  if type(signed_url) ~= "string" or not signed_url:match("^https://")
      or signed_url:find("[\r\n]") then
    return nil, { code = "invalid_response", message = "lua.tools returned an invalid download link." }
  end
  return { url = signed_url }
end

return fixes
