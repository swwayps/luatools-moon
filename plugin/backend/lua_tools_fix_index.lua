local cjson = require("json")
local paths = require("paths")
local m_utils = require("utils")
local domain = require("lua_tools_domain")

local fix_index = {}
local INDEX_FILENAME = "lua_tools_fix_index.json"
local CACHE = {}

local function valid_manifest_filename(appid, value)
  value = tostring(value or "")
  if value == "" or value:find("/", 1, true) or value:find("\\", 1, true)
      or value:find("\0", 1, true) then
    return nil
  end
  local escaped = tostring(appid):gsub("([^%w])", "%%%1")
  if not value:lower():match("^" .. escaped .. "[^/\\]*%.lua$") then return nil end
  return value
end

local function normalize_entry(appid, entry)
  if type(entry) ~= "table" then return nil end
  local fix_id = domain.fix_id(entry.fixId)
  local category = domain.category(entry.category)
  local manifest_filename = valid_manifest_filename(appid, entry.manifestFilename)
  if not fix_id or not category or not manifest_filename then return nil end
  return {
    fixId = fix_id,
    title = tostring(entry.title or "Recommended version"),
    category = category,
    createdAt = tostring(entry.createdAt or ""),
    manifestFilename = manifest_filename,
    hasFix = entry.hasFix == true,
  }
end

local function normalize_document(document)
  if type(document) ~= "table" or tonumber(document.schema) ~= 1
      or type(document.apps) ~= "table" then
    return nil
  end
  local apps = {}
  for raw_appid, entry in pairs(document.apps) do
    local appid = domain.positive_appid(raw_appid)
    if not appid or tostring(appid) ~= tostring(raw_appid) then return nil end
    local normalized = normalize_entry(appid, entry)
    if not normalized then return nil end
    apps[tostring(appid)] = normalized
  end
  return {
    schema = 1,
    generatedAt = tostring(document.generatedAt or ""),
    source = tostring(document.source or ""),
    apps = apps,
  }
end

local function load_document(deps)
  deps = deps or {}
  local cache_key = deps.cacheKey
  if cache_key ~= nil and CACHE[cache_key] ~= nil then return CACHE[cache_key] end

  local document
  if type(deps.load) == "function" then
    document = deps.load()
  else
    cache_key = cache_key or "runtime"
    if CACHE[cache_key] ~= nil then return CACHE[cache_key] end
    local path = paths.backend_path(INDEX_FILENAME)
    local raw = m_utils.read_file(path)
    if type(raw) == "string" and raw ~= "" then
      local ok, decoded = pcall(cjson.decode, raw)
      if ok then document = decoded end
    end
  end

  local normalized = normalize_document(document)
  if cache_key ~= nil then CACHE[cache_key] = normalized or false end
  return normalized
end

local function copy_entry(entry)
  if type(entry) ~= "table" then return nil end
  local copy = {}
  for key, value in pairs(entry) do copy[key] = value end
  return copy
end

function fix_index.lookup(appid, deps)
  appid = domain.positive_appid(appid)
  if not appid then return nil end
  local document = load_document(deps)
  if type(document) ~= "table" then return nil end
  return copy_entry(document.apps[tostring(appid)])
end

function fix_index.recommendation(appid, authenticated, deps)
  if authenticated ~= true then
    return { success = true, available = false, authRequired = true }
  end
  local entry = fix_index.lookup(appid, deps)
  if not entry then
    return { success = true, available = false, authRequired = false }
  end
  return {
    success = true,
    available = true,
    authRequired = false,
    recommendation = entry,
  }
end

function fix_index.validate(document)
  return normalize_document(document) ~= nil
end

return fix_index
