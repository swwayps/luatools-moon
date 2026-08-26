local cjson = require("json")
local fs = require("fs")
local m_utils = require("utils")
local paths = require("paths")

local auto_fix = {}
local STATE_FILE = paths.backend_path("data/lua_tools_auto_fix.json")
local write_sequence = 0
local MAX_RETRIES = 3

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function positive_appid(value)
  local number = tonumber(value)
  if not number or number <= 0 or number ~= math.floor(number) then return nil end
  return math.floor(number)
end

local function valid_fix_id(value)
  value = tostring(value or ""):lower()
  local namespace, uuid = value:match("^([a-z0-9][a-z0-9_%-]*):(.+)$")
  if namespace then
    if #namespace > 32 then return nil end
    value = uuid
  end
  local a, b, c, d, e = value:match("^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
  if not a or #a ~= 8 or #b ~= 4 or #c ~= 4 or #d ~= 4 or #e ~= 12 then return nil end
  local normalized = value:lower()
  return namespace and (namespace .. ":" .. normalized) or normalized
end

local function empty_database()
  return { version = 1, jobs = {} }
end

local function normalize_database(value)
  if type(value) ~= "table" then value = empty_database() end
  value.version = 1
  if type(value.jobs) ~= "table" then value.jobs = {} end
  return value
end

local function load_default()
  local raw = m_utils.read_file(STATE_FILE)
  if type(raw) ~= "string" or raw == "" then return empty_database() end
  local ok, decoded = pcall(cjson.decode, raw)
  return ok and normalize_database(decoded) or empty_database()
end

local function save_default(database)
  local parent = type(fs.parent_path) == "function" and fs.parent_path(STATE_FILE)
    or STATE_FILE:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and not fs.exists(parent)
      and fs.create_directories(parent) == false then return false end
  local ok_encode, encoded = pcall(cjson.encode, normalize_database(database))
  if not ok_encode then return false end
  write_sequence = write_sequence + 1
  local temporary = STATE_FILE .. "." .. tostring(os.time()) .. "."
    .. tostring(write_sequence) .. ".tmp"
  local ok_write, wrote = pcall(m_utils.write_file, temporary, encoded)
  if not ok_write or wrote == false then pcall(os.remove, temporary); return false end
  m_utils.exec("chmod 600 -- " .. shell_quote(temporary))
  if not os.rename(temporary, STATE_FILE) then
    pcall(os.remove, temporary)
    return false
  end
  m_utils.exec("chmod 600 -- " .. shell_quote(STATE_FILE))
  return true
end

local function load(deps)
  local loader = deps and deps.load or load_default
  local ok, value = pcall(loader)
  return ok and normalize_database(value) or empty_database()
end

local function save(database, deps)
  local saver = deps and deps.save or save_default
  local ok, result = pcall(saver, normalize_database(database))
  return ok and result == true
end

local function now_value(deps)
  local clock = deps and deps.now or os.time
  local ok, value = pcall(clock)
  return ok and tonumber(value) or os.time()
end

local function configured(callbacks)
  local fn = callbacks and callbacks.auth_status
  if type(fn) ~= "function" then return false end
  local ok, status = pcall(fn)
  return ok and type(status) == "table" and status.configured == true
end

local function permanent_error(code)
  return code == "unavailable" or code == "preparation_required"
    or code == "invalid_appid" or code == "recommendation_mismatch"
end

local function auth_error(code)
  return code == "authentication" or code == "not_signed_in"
    or code == "session_expired"
end

local function set_failure(job, result, now)
  local code = tostring(type(result) == "table" and result.errorCode or "auto_fix_failed")
  job.errorCode = code
  job.error = tostring(type(result) == "table" and result.error or "Automatic fix failed.")
  if auth_error(code) then
    job.phase = "needs_login"
    job.nextAttempt = 0
    return
  end
  if permanent_error(code) or (tonumber(job.retries) or 0) >= MAX_RETRIES then
    job.phase = "failed"
    job.nextAttempt = 0
    return
  end
  job.retries = (tonumber(job.retries) or 0) + 1
  job.phase = "waiting_install"
  job.stablePolls = 0
  job.nextAttempt = now + math.min(60, 5 * (2 ^ (job.retries - 1)))
end

function auto_fix.queue(appid, fix_id, deps)
  appid = positive_appid(appid)
  fix_id = valid_fix_id(fix_id)
  if not appid or not fix_id then return false, "invalid_job" end
  local database = load(deps)
  database.jobs[tostring(appid)] = {
    fixId = fix_id,
    phase = "waiting_install",
    createdAt = now_value(deps),
    retries = 0,
    nextAttempt = 0,
    stablePolls = 0,
    seenInstallActivity = false,
  }
  if not save(database, deps) then return false, "state_write_failed" end
  return true
end

function auto_fix.get(appid, deps)
  appid = positive_appid(appid)
  if not appid then return nil end
  return load(deps).jobs[tostring(appid)]
end

function auto_fix.cancel(appid, deps)
  appid = positive_appid(appid)
  if not appid then
    return { success = false, errorCode = "invalid_appid", error = "Invalid Steam app ID." }
  end
  local database = load(deps)
  local key = tostring(appid)
  local job = database.jobs[key]
  if type(job) ~= "table" then return { success = true, cancelled = false } end
  if job.phase == "applying" or job.phase == "finalizing" then
    return {
      success = false,
      errorCode = "already_applying",
      error = "The fix is already writing game files and cannot be skipped safely.",
    }
  end
  database.jobs[key] = nil
  if not save(database, deps) then
    return { success = false, errorCode = "state_write_failed",
      error = "Could not cancel the automatic fix." }
  end
  return { success = true, cancelled = true }
end

local function ui_job(appid, job, observed)
  if type(job) ~= "table" or job.phase == "failed" then return nil end
  local phase = tostring(job.phase or "waiting_install")
  local stage, progress = "preparing", 0
  if phase == "needs_login" then
    stage = "needs_login"
  elseif phase == "applying" then
    local status = type(observed) == "table" and tostring(observed.status or "") or ""
    if status == "downloading" then
      stage = "downloading"
      local read = math.max(0, tonumber(observed.bytesRead) or 0)
      local total = math.max(0, tonumber(observed.totalBytes) or 0)
      progress = total > 0 and math.min(85, math.floor((read / total) * 85)) or 5
    elseif status == "extracting" then
      stage, progress = "extracting", 90
    elseif status == "applying" then
      stage, progress = "applying", 96
    else
      stage, progress = "preparing_fix", 2
    end
  elseif phase == "finalizing" then
    stage, progress = "finalizing", 99
  end
  return {
    appid = appid,
    gameName = tostring(job.gameName or ("App " .. tostring(appid))),
    phase = phase,
    stage = stage,
    progress = progress,
    canSkip = phase == "waiting_install" or phase == "needs_login",
  }
end

function auto_fix.tick(now, callbacks, deps)
  now = tonumber(now) or now_value(deps)
  callbacks = callbacks or {}
  local database = load(deps)
  local keys = {}
  for key in pairs(database.jobs) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right) return tonumber(left) < tonumber(right) end)
  local changed = false
  local observed = {}

  for _, key in ipairs(keys) do
    local appid = positive_appid(key)
    local job = database.jobs[key]
    if appid and type(job) == "table" and job.phase ~= "failed"
        and now >= (tonumber(job.nextAttempt) or 0) then
      if job.phase == "needs_login" then
        if configured(callbacks) then
          job.phase = "waiting_install"
          job.stablePolls = 0
          job.error = nil
          job.errorCode = nil
          changed = true
        end
      elseif job.phase == "waiting_install" then
        local ok_install, install = pcall(callbacks.install_state, appid)
        if ok_install and type(install) == "table"
            and type(install.gameName) == "string" and install.gameName ~= ""
            and job.gameName ~= install.gameName then
          job.gameName = install.gameName
          changed = true
        end
        if ok_install and type(install) == "table" and install.complete == true
            and install.postInstallBusy ~= true then
          local build_ready = true
          if type(callbacks.recommended_build_ready) == "function" then
            local checked, ready = pcall(
              callbacks.recommended_build_ready, appid)
            build_ready = checked and ready == true
          end
          if not build_ready then
            job.stablePolls = 0
            job.nextAttempt = now + 5
            changed = true
          else
            if job.seenInstallActivity == true then
              job.stablePolls = (tonumber(job.stablePolls) or 0) + 1
              changed = true
            else
              job.stablePolls = 0
            end
            if job.seenInstallActivity == true and job.stablePolls >= 2 then
              if not configured(callbacks) then
                job.phase = "needs_login"
              elseif type(callbacks.is_busy) == "function"
                  and callbacks.is_busy(appid) == true then
                job.nextAttempt = now + 5
              else
                local ok_start, result = pcall(callbacks.start_fix, appid, job.fixId)
                if ok_start and type(result) == "table" and result.success == true then
                  job.phase = "applying"
                  job.retries = 0
                  job.nextAttempt = 0
                  job.error = nil
                  job.errorCode = nil
                else
                  set_failure(job, ok_start and result or {
                    errorCode = "start_failed", error = tostring(result),
                  }, now)
                end
              end
            end
          end
        else
          if job.stablePolls ~= 0 or job.seenInstallActivity ~= true then
            changed = true
          end
          job.stablePolls = 0
          job.seenInstallActivity = true
        end
      elseif job.phase == "applying" then
        local ok_poll, payload = pcall(callbacks.poll_fix, appid)
        local state = ok_poll and type(payload) == "table" and payload.state or nil
        observed[key] = state
        if type(state) == "table" and state.status == "done" then
          job.phase = "finalizing"
          job.nextAttempt = 0
          changed = true
        elseif type(state) == "table"
            and (state.status == "failed" or state.status == "cancelled") then
          set_failure(job, state, now)
          changed = true
        end
      elseif job.phase == "finalizing" then
        local ok_options, options = pcall(callbacks.launch_options, appid)
        if not ok_options or type(options) ~= "table" or options.success ~= true then
          set_failure(job, ok_options and options or {
            errorCode = "launch_options_failed", error = tostring(options),
          }, now)
          changed = true
        else
          local relayed = true
          if options.apply == true and type(options.launchOptions) == "string"
              and options.launchOptions ~= "" then
            local ok_relay, result = pcall(callbacks.set_launch_options,
              appid, options.launchOptions)
            relayed = ok_relay and result == true
          end
          if not relayed then
            job.nextAttempt = now + 5
            job.errorCode = "launch_options_relay_failed"
            changed = true
          else
            local ok_complete, completed = pcall(callbacks.complete_fix,
              appid, job.fixId)
            if ok_complete and type(completed) == "table"
                and completed.success == true then
              database.jobs[key] = nil
              changed = true
            else
              set_failure(job, ok_complete and completed or {
                errorCode = "complete_failed", error = tostring(completed),
              }, now)
              changed = true
            end
          end
        end
      end
    end
  end

  if changed and not save(database, deps) then
    return { success = false, errorCode = "state_write_failed" }
  end
  local ui_jobs = {}
  for key, job in pairs(database.jobs) do
    local view = ui_job(positive_appid(key), job, observed[key])
    if view then ui_jobs[key] = view end
  end
  return { success = true, changed = changed, jobs = database.jobs, uiJobs = ui_jobs }
end

return auto_fix
