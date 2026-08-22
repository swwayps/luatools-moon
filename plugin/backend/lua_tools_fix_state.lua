local cjson = require("json")
local fs = require("fs")
local m_utils = require("utils")
local paths = require("paths")

local state = {}

local STATE_FILE = paths.backend_path("data/lua_tools_fix_state.json")
local MAX_MANIFEST_BYTES = 2 * 1024 * 1024
local write_sequence = 0
local unpack_values = table.unpack or unpack

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function positive_appid(value)
  local number = tonumber(value)
  if not number or number <= 0 or number ~= math.floor(number) then return nil end
  return math.floor(number)
end

local function path_join(...)
  local parts = { ... }
  if type(fs.join) == "function" then return fs.join(unpack_values(parts)) end
  return table.concat(parts, "/"):gsub("/+", "/")
end

local function empty_database()
  return { version = 1, apps = {} }
end

local function normalize_database(value)
  if type(value) ~= "table" then value = empty_database() end
  value.version = 1
  if type(value.apps) ~= "table" then value.apps = {} end
  return value
end

local function load_default()
  local raw = m_utils.read_file(STATE_FILE)
  if type(raw) ~= "string" or raw == "" then return empty_database() end
  local ok, decoded = pcall(cjson.decode, raw)
  if not ok then return empty_database() end
  return normalize_database(decoded)
end

local function save_default(database)
  database = normalize_database(database)
  local parent = type(fs.parent_path) == "function" and fs.parent_path(STATE_FILE)
    or STATE_FILE:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and not fs.exists(parent)
      and fs.create_directories(parent) == false then return false end
  local ok_encode, encoded = pcall(cjson.encode, database)
  if not ok_encode then return false end
  write_sequence = write_sequence + 1
  local temp = STATE_FILE .. "." .. tostring(os.time()) .. "."
    .. tostring(write_sequence) .. ".tmp"
  local ok_write, wrote = pcall(m_utils.write_file, temp, encoded)
  if not ok_write or wrote == false then pcall(os.remove, temp); return false end
  m_utils.exec("chmod 600 -- " .. shell_quote(temp))
  if not os.rename(temp, STATE_FILE) then pcall(os.remove, temp); return false end
  m_utils.exec("chmod 600 -- " .. shell_quote(STATE_FILE))
  return true
end

local function load(deps)
  local loader = deps and deps.load or load_default
  local ok, value = pcall(loader)
  if not ok then return empty_database() end
  return normalize_database(value)
end

local function save(database, deps)
  local saver = deps and deps.save or save_default
  local ok, result = pcall(saver, database)
  return ok and result == true
end

local function app_record(database, appid, create)
  local key = tostring(appid)
  local record = database.apps[key]
  if type(record) ~= "table" and create then
    record = {}
    database.apps[key] = record
  end
  return record, key
end

local function public_metadata(fix)
  local source = tostring(fix.source or "")
  if source == "" then source = "lua_tools" end
  return {
    fixId = tostring(fix.id or fix.fixId or ""):lower(),
    title = tostring(fix.title or "Fix"),
    category = tostring(fix.category or "other"),
    source = source,
    manifestFilename = tostring(fix.manifestFilename or ""),
    fixFilename = tostring(fix.fixFilename or ""),
  }
end

function state.validate_manifest(content, appid)
  appid = positive_appid(appid)
  if not appid then return false, "invalid_appid" end
  if type(content) ~= "string" or content == "" then
    return false, "invalid_manifest"
  end
  if #content > MAX_MANIFEST_BYTES then return false, "manifest_too_large" end
  if content:find("\0", 1, true) then return false, "binary_manifest" end
  local expected = tostring(appid)
  local found = false
  for declared in content:gmatch("addappid%s*%(%s*(%d+)") do
    if declared == expected then found = true; break end
  end
  if not found then return false, "manifest_appid_mismatch" end
  return true
end

function state.get_applied(appid, deps)
  appid = positive_appid(appid)
  if not appid then return nil end
  local record = app_record(load(deps), appid, false)
  return type(record) == "table" and type(record.applied) == "table"
    and record.applied or nil
end

function state.get_pending(appid, deps)
  appid = positive_appid(appid)
  if not appid then return nil end
  local record = app_record(load(deps), appid, false)
  return type(record) == "table" and type(record.pending) == "table"
    and record.pending or nil
end

function state.begin(appid, fix, staged_manifest, deps)
  appid = positive_appid(appid)
  if not appid or type(fix) ~= "table" then return false end
  local metadata = public_metadata(fix)
  if metadata.fixId == "" then return false end
  local database = load(deps)
  local record = app_record(database, appid, true)
  record.pending = metadata
  record.pending.stagedManifest = type(staged_manifest) == "string" and staged_manifest or ""
  record.pending.manifestInstalled = record.pending.stagedManifest == ""
  return save(database, deps)
end

function state.begin_fallback_online(appid, deps)
  return state.begin(appid, {
    id = "online-fix-fallback",
    title = "Online Fix · No login",
    category = "online_fix",
    source = "online_fix_fallback",
  }, "", deps)
end

function state.stage_manifest(appid, content, stage_dir, deps)
  appid = positive_appid(appid)
  local valid, validation_error = state.validate_manifest(content, appid)
  if not valid then return nil, validation_error end
  stage_dir = tostring(stage_dir or "")
  if stage_dir == "" then return nil, "invalid_stage_dir" end
  local mkdir = deps and deps.mkdir or fs.create_directories
  local write = deps and deps.write or m_utils.write_file
  local rename = deps and deps.rename or os.rename
  local chmod = deps and deps.chmod or function(path)
    m_utils.exec("chmod 600 -- " .. shell_quote(path))
  end
  local ok_mkdir, made = pcall(mkdir, stage_dir)
  if not ok_mkdir or made == false then return nil, "stage_create_failed" end
  local target = path_join(stage_dir, "fix_" .. tostring(appid) .. "_manifest.lua")
  local temp = target .. ".tmp"
  pcall(os.remove, temp)
  local ok_write, wrote = pcall(write, temp, content)
  if not ok_write or wrote == false then pcall(os.remove, temp); return nil, "stage_write_failed" end
  pcall(chmod, temp)
  local ok_rename, renamed = pcall(rename, temp, target)
  if not ok_rename or renamed == false then pcall(os.remove, temp); return nil, "stage_replace_failed" end
  pcall(chmod, target)
  return target
end

function state.publish_manifest(appid, content, steam_root, deps)
  appid = positive_appid(appid)
  if not appid then return false, "invalid_appid" end
  local valid, validation_error = state.validate_manifest(content, appid)
  if not valid then return false, validation_error end
  steam_root = tostring(steam_root or "")
  if steam_root == "" then return false, "steam_path_unavailable" end

  local write = deps and deps.write or m_utils.write_file
  local mkdir = deps and deps.mkdir or fs.create_directories
  local rename = deps and deps.rename or os.rename
  local remove = deps and deps.remove or os.remove
  local chmod = deps and deps.chmod or function(path)
    m_utils.exec("chmod 600 -- " .. shell_quote(path))
  end
  local target_dir = path_join(steam_root, "config", "stplug-in")
  local ok_mkdir, made = pcall(mkdir, target_dir)
  if not ok_mkdir or made == false then return false, "manifest_dir_failed" end

  local target = path_join(target_dir, tostring(appid) .. ".lua")
  write_sequence = write_sequence + 1
  local temp = target .. ".tmp." .. tostring(write_sequence)
  local ok_write, wrote = pcall(write, temp, content)
  if not ok_write or wrote == false then
    pcall(remove, temp)
    return false, "manifest_write_failed"
  end
  pcall(chmod, temp)
  local ok_rename, renamed = pcall(rename, temp, target)
  if not ok_rename or renamed == false then
    pcall(remove, temp)
    return false, "manifest_replace_failed"
  end
  pcall(chmod, target)
  return true
end

function state.install_staged_manifest(appid, steam_root, deps)
  appid = positive_appid(appid)
  if not appid then return false, "invalid_appid" end
  local database = load(deps)
  local record = app_record(database, appid, false)
  local pending = type(record) == "table" and record.pending or nil
  if type(pending) ~= "table" then return false, "no_pending_fix" end
  if pending.manifestInstalled == true then return true end
  local staged = tostring(pending.stagedManifest or "")
  if staged == "" then
    pending.manifestInstalled = true
    if not save(database, deps) then return false, "state_write_failed" end
    return true
  end

  steam_root = tostring(steam_root or "")
  if steam_root == "" then return false, "steam_path_unavailable" end
  local read = deps and deps.read or m_utils.read_file
  local write = deps and deps.write or m_utils.write_file
  local mkdir = deps and deps.mkdir or fs.create_directories
  local rename = deps and deps.rename or os.rename
  local remove = deps and deps.remove or os.remove
  local chmod = deps and deps.chmod or function(path)
    m_utils.exec("chmod 600 -- " .. shell_quote(path))
  end
  local content = read(staged)
  local valid, validation_error = state.validate_manifest(content, appid)
  if not valid then return false, validation_error end

  local target_dir = path_join(steam_root, "config", "stplug-in")
  local ok_mkdir, made = pcall(mkdir, target_dir)
  if not ok_mkdir or made == false then return false, "manifest_dir_failed" end
  local target = path_join(target_dir, tostring(appid) .. ".lua")
  write_sequence = write_sequence + 1
  local temp = target .. ".tmp." .. tostring(write_sequence)
  local ok_write, wrote = pcall(write, temp, content)
  if not ok_write or wrote == false then pcall(remove, temp); return false, "manifest_write_failed" end
  pcall(chmod, temp)
  local ok_rename, renamed = pcall(rename, temp, target)
  if not ok_rename or renamed == false then
    pcall(remove, temp)
    return false, "manifest_replace_failed"
  end
  pcall(chmod, target)
  pcall(remove, staged)
  pending.stagedManifest = nil
  pending.manifestInstalled = true
  if not save(database, deps) then return false, "state_write_failed" end
  return true
end

function state.complete(appid, fix_id, deps)
  appid = positive_appid(appid)
  fix_id = tostring(fix_id or ""):lower()
  if not appid or fix_id == "" then return false end
  local database = load(deps)
  local record = app_record(database, appid, false)
  local pending = type(record) == "table" and record.pending or nil
  if type(pending) ~= "table" or pending.fixId ~= fix_id
      or pending.manifestInstalled ~= true then return false end
  record.applied = public_metadata(pending)
  local now = deps and deps.now or os.time
  record.applied.appliedAt = tonumber(now()) or os.time()
  record.pending = nil
  return save(database, deps)
end

function state.abort(appid, deps)
  appid = positive_appid(appid)
  if not appid then return false end
  local database = load(deps)
  local record, key = app_record(database, appid, false)
  if type(record) ~= "table" then return true end
  if type(record.pending) == "table" and type(record.pending.stagedManifest) == "string" then
    local remove = deps and deps.remove or os.remove
    pcall(remove, record.pending.stagedManifest)
  end
  record.pending = nil
  if record.applied == nil then database.apps[key] = nil end
  return save(database, deps)
end

function state.clear(appid, deps)
  appid = positive_appid(appid)
  if not appid then return false end
  local database = load(deps)
  local record, key = app_record(database, appid, false)
  if type(record) == "table" and type(record.pending) == "table"
      and type(record.pending.stagedManifest) == "string" then
    local remove = deps and deps.remove or os.remove
    pcall(remove, record.pending.stagedManifest)
  end
  database.apps[key] = nil
  return save(database, deps)
end

function state.applied_sources(receipt)
  receipt = type(receipt) == "table" and receipt or nil
  local source = receipt and tostring(receipt.source or "") or ""
  -- Receipts written before source tagging all came from the official flow.
  if receipt and source == "" then source = "lua_tools" end
  return {
    luaTools = source == "lua_tools",
    fallbackOnline = source == "online_fix_fallback",
  }
end

function state.decorate_game(game, receipt)
  if type(game) ~= "table" then return game end
  receipt = type(receipt) == "table" and receipt or nil
  local sources = state.applied_sources(receipt)
  for _, fix in ipairs(type(game.fixes) == "table" and game.fixes or {}) do
    fix.applied = sources.luaTools and tostring(fix.id or "") == tostring(receipt.fixId or "")
  end
  game.appliedFix = receipt
  return game
end

return state
