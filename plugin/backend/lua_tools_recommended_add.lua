local fix_index = require("lua_tools_fix_index")
local lua_tools_fixes = require("lua_tools_fixes")
local http_client = require("http_client")
local steam_utils = require("steam_utils")

local recommended_add = {}
local MAX_MANIFEST_BYTES = 2 * 1024 * 1024

local function positive_appid(value)
  local number = tonumber(value)
  if not number or number <= 0 or number ~= math.floor(number) then return nil end
  return math.floor(number)
end

local function failure(code, message, extra)
  local result = {
    success = false,
    errorCode = tostring(code or "recommended_add_failed"),
    error = tostring(message or "The recommended version could not be added."),
  }
  for key, value in pairs(type(extra) == "table" and extra or {}) do
    result[key] = value
  end
  return result
end

function recommended_add.start(appid, fix_id, auto_apply, deps)
  appid = positive_appid(appid)
  fix_id = tostring(fix_id or ""):lower()
  if not appid then return failure("invalid_appid", "Invalid Steam app ID.") end
  deps = deps or {}

  local lookup = deps.lookup or fix_index.lookup
  local ok_lookup, recommendation = pcall(lookup, appid)
  if not ok_lookup then return failure("index_unavailable", "The local recommendation index is unavailable.") end
  if type(recommendation) ~= "table" or recommendation.fixId ~= fix_id then
    return failure("recommendation_mismatch", "This recommendation is no longer available.")
  end

  local resolve = deps.resolve or lua_tools_fixes.resolve_download
  local ok_resolve, download, download_error = pcall(resolve, fix_id, "manifest")
  if not ok_resolve then
    return failure("download_unavailable", "lua.tools could not prepare the manifest download.")
  end
  if type(download) ~= "table" or type(download.url) ~= "string"
      or not download.url:match("^https://") or download.url:find("[\r\n]") then
    return failure(
      type(download_error) == "table" and download_error.code or "download_unavailable",
      type(download_error) == "table" and download_error.message
        or "lua.tools could not prepare the manifest download."
    )
  end

  local get = deps.get or http_client.get
  local ok_fetch, response = pcall(get, download.url, {
    timeout = 60,
    max_bytes = MAX_MANIFEST_BYTES,
  })
  if not ok_fetch or type(response) ~= "table" or tonumber(response.status) ~= 200
      or type(response.body) ~= "string" then
    return failure("manifest_download_failed", "The recommended manifest could not be downloaded.")
  end

  local steam_root = deps.steam_root or steam_utils.detect_steam_install_path
  local ok_root, root = pcall(steam_root)
  if not ok_root or type(root) ~= "string" or root == "" then
    return failure("steam_path_unavailable", "Steam's install path is unavailable.")
  end

  local publish = deps.publish
  if type(publish) ~= "function" then
    return failure("manifest_pin_unavailable",
      "The recommended manifest could not be installed safely.")
  end
  local ok_publish, published, publish_error = pcall(
    publish, appid, response.body, root)
  if not ok_publish then
    return failure("manifest_publish_failed", "The recommended manifest could not be installed.")
  end
  if published ~= true then
    return failure(publish_error or "manifest_publish_failed",
      "The recommended manifest could not be installed.")
  end

  if auto_apply == true then
    local queue = deps.queue
    if type(queue) ~= "function" then
      return failure("auto_fix_unavailable",
        "The manifest was installed, but automatic fix application is unavailable.",
        { manifestInstalled = true })
    end
    local ok_queue, queued, queue_error = pcall(queue, appid, fix_id)
    if not ok_queue or queued ~= true then
      return failure(queue_error or "state_write_failed",
        "The manifest was installed, but the automatic fix could not be queued.",
        { manifestInstalled = true })
    end
  end

  return {
    success = true,
    manifestInstalled = true,
    autoApplyQueued = auto_apply == true,
    fixId = fix_id,
    category = recommendation.category,
  }
end

return recommended_add
