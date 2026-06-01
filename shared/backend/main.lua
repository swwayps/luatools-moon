local millennium = require("millennium")

-- ADAPT-LINUX: platform abstraction. The Windows upstream inlined
-- Win32 FFI calls and shelled out to powershell.exe / cmd.exe / wscript.exe.
-- Every site below that previously did so now routes through
-- `platform`. The Linux overlay ships backend/platform.lua with the
-- real implementations; if missing, we fall back to a minimal shim
-- so the plugin still loads (path joins work, side-effecting calls
-- become no-ops). The shim path is for diagnostics only — workers,
-- Steam restart, and watcher pokes are inert without the overlay.
local platform
do
  local ok, mod = pcall(require, "platform")
  if ok and type(mod) == "table" then
    platform = mod
  else
    platform = {
      sep = package.config:sub(1, 1),
      normalize = function(p) return tostring(p or "") end,
      join = function(...)
        local parts, sep = { ... }, package.config:sub(1, 1)
        local out = {}
        for _, p in ipairs(parts) do
          if p ~= nil and p ~= "" then out[#out + 1] = tostring(p) end
        end
        return table.concat(out, sep)
      end,
      ensure_dir = function() end,
      rmtree = function() end,
      list_files_recursive = function() return {} end,
      unzip = function() return false, "platform overlay missing" end,
      sleep_ms = function(ms)
        local until_time = os.clock() + ((tonumber(ms) or 50) / 1000)
        while os.clock() < until_time do end
      end,
      spawn_worker_async = function() return false end,
      spawn_worker_sync = function() return false end,
      restart_steam = function() end,
      set_plugin_root = function() end,
      open_path = function() return false end,
      open_url = function() return false end,
      detect_steam_locale = function() return nil end,
      poke_watchers = function() end,
      run_silent = function() return false end,
      append_additional_app = function() return false, "platform overlay missing" end,
    }
  end
end

local SEP = platform.sep
local function pjoin(...) return platform.join(...) end

local function esc(value)
  value = tostring(value or "")
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n")
  return value
end

local function json_ok(extra)
  extra = extra or ""
  if extra ~= "" then extra = "," .. extra end
  return '{"success":true' .. extra .. "}"
end

local function json_fail(message)
  return '{"success":false,"error":"' .. esc(message or "Unknown error") .. '"}'
end

local startup_message = ""

local function steam_path()
  local ok, value = pcall(millennium.steam_path)
  if ok and value then return tostring(value) end
  return ""
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source or ""
  source = source:gsub("^@", ""):gsub("\\", "/")
  return source:gsub("/backend/main%.lua$", "")
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local data = f:read("*a") or ""
  f:close()
  return data
end

local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data or "")
  f:close()
  return true
end

local function copy_file(src, dst)
  local data = read_file(src)
  if data == "" then return false end
  return write_file(dst, data)
end

local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
  data = tostring(data or "")
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local a = data:byte(i) or 0
    local b = data:byte(i + 1) or 0
    local c = data:byte(i + 2) or 0
    local n = a * 65536 + b * 256 + c
    local pad = (i + 1 > len and 2) or (i + 2 > len and 1) or 0
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = base64_chars:sub(c1 + 1, c1 + 1)
    out[#out + 1] = base64_chars:sub(c2 + 1, c2 + 1)
    out[#out + 1] = pad >= 2 and "=" or base64_chars:sub(c3 + 1, c3 + 1)
    out[#out + 1] = pad >= 1 and "=" or base64_chars:sub(c4 + 1, c4 + 1)
    i = i + 3
  end
  return table.concat(out)
end

local log_line

local function appid_from_args(args)
  if type(args) == "table" then
    if args.appid or args[1] then return tonumber(args.appid or args[1]) end
    for k, v in pairs(args) do
      local nk = tostring(k):lower()
      if nk == "appid" or nk == "app_id" or nk == "id" then return tonumber(v) end
      if tonumber(v) and tostring(v):match("^%d+$") then return tonumber(v) end
    end
  end
  return tonumber(args)
end

local function dump_args(label, args)
  if not log_line then return end
  if type(args) ~= "table" then
    log_line(label .. " arg type=" .. type(args) .. " value=" .. tostring(args))
    return
  end
  local parts = {}
  for k, v in pairs(args) do
    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
  end
  log_line(label .. " table args: " .. table.concat(parts, ", "))
end

local function url_from_args(args)
  if type(args) == "table" then return tostring(args.url or args[1] or "") end
  return tostring(args or "")
end

local function url_encode(value)
  return tostring(value or ""):gsub("([^%w%-%._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

log_line = function(message)
  local root = plugin_root()
  local f = io.open(root .. "/backend/lua_runtime.log", "ab")
  if f then
    f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(message) .. "\n")
    f:close()
  end
end

local require_json_cached = nil
local require_json_warned = false

local function require_json()
  if require_json_cached ~= nil then return require_json_cached end
  local ok, mod = pcall(require, "cjson")
  if ok then
    require_json_cached = mod
    return mod
  end
  if not require_json_warned then
    log_line("cjson unavailable: " .. tostring(mod))
    require_json_warned = true
  end
  require_json_cached = false
  return nil
end

local function require_http()
  local ok, mod = pcall(require, "http")
  if ok then return mod end
  log_line("http unavailable: " .. tostring(mod))
  return nil
end

local function response_status(res)
  if type(res) ~= "table" then return 0 end
  return tonumber(res.status or res.status_code or res.code or 0) or 0
end

local function response_body(res)
  if type(res) ~= "table" then return "" end
  return tostring(res.body or res.text or res.data or "")
end

local function http_request(method, url, timeout)
  local h = require_http()
  if not h then return nil, "http module unavailable" end
  local opts = {
    method = method or "GET",
    timeout = timeout or 8,
    follow_redirects = true,
    headers = { ["User-Agent"] = "discord(dot)gg/luatools" },
    user_agent = "discord(dot)gg/luatools",
  }
  local ok, res = pcall(function()
    if method == "GET" and h.get then return h.get(url, opts) end
    if h.request then return h.request(url, opts) end
    return nil
  end)
  if not ok then
    log_line("http " .. tostring(method) .. " failed for " .. tostring(url) .. ": " .. tostring(res))
    return nil, tostring(res)
  end
  return res, nil
end

local function decode_json(text)
  local json = require_json()
  if json then
    local ok, data = pcall(json.decode, text or "")
    if ok and type(data) == "table" then return data end
  end
  return nil
end

local function get_morrenus_key()
  local settings = read_file(plugin_root() .. "/backend/data/settings.json")
  return settings:match('"morrenusApiKey"%s*:%s*"([^"]*)"') or ""
end

local function api_setting_key(name)
  local key = tostring(name or "api"):lower()
  key = key:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if key == "" then key = "api" end
  return "api_" .. key
end

local function read_settings_api_overrides()
  local text = read_file(plugin_root() .. "/backend/data/settings.json")
  local data = decode_json(text)
  local values = data and type(data.values) == "table" and data.values or nil
  local apis = values and type(values.apis) == "table" and values.apis or nil
  local out = {}
  if apis then
    for key, enabled in pairs(apis) do
      if type(enabled) == "boolean" then out[tostring(key)] = enabled end
    end
    return out
  end

  local api_block = text:match('"apis"%s*:%s*{(.-)}')
  if api_block then
    for key, value in api_block:gmatch('"([^"]+)"%s*:%s*([%a]+)') do
      if value == "true" then out[key] = true end
      if value == "false" then out[key] = false end
    end
  end
  return out
end

local function load_api_manifest_entries()
  local path = plugin_root() .. "/backend/api.json"
  local text = read_file(path)
  local data = decode_json(text)
  local entries = {}
  if data and type(data.api_list) == "table" then
    for _, api in ipairs(data.api_list) do
      if type(api) == "table" then
        entries[#entries + 1] = {
          name = tostring(api.name or "Unknown"),
          url = tostring(api.url or ""),
          success_code = tonumber(api.success_code or 200) or 200,
          enabled = api.enabled ~= false,
        }
      end
    end
  end
  if #entries == 0 then
    for object in text:gmatch("{(.-)}") do
      local name = object:match('"name"%s*:%s*"([^"]+)"')
      local url = object:match('"url"%s*:%s*"([^"]+)"')
      local code = tonumber(object:match('"success_code"%s*:%s*(%d+)') or "200") or 200
      local disabled = object:match('"enabled"%s*:%s*false')
      if name and url then
        entries[#entries + 1] = { name = name, url = url, success_code = code, enabled = not disabled }
      end
    end
  end
  return entries
end

local function load_apis()
  local overrides = read_settings_api_overrides()
  local apis = {}
  for _, api in ipairs(load_api_manifest_entries()) do
    local setting_key = api_setting_key(api.name)
    local enabled = overrides[setting_key]
    if enabled == nil then enabled = api.enabled ~= false end
    if enabled then
      apis[#apis + 1] = {
        name = api.name,
        url = api.url,
        success_code = api.success_code,
      }
    end
  end
  return apis
end

local function refresh_free_apis()
  local urls = {
    "https://raw.githubusercontent.com/madoiscool/lt_api_links/refs/heads/main/load_free_manifest_apis",
    "https://luatools.vercel.app/load_free_manifest_apis",
  }
  local last_error = ""
  for _, url in ipairs(urls) do
    local res, err = http_request("GET", url, 15)
    if res and response_status(res) == 200 then
      local body = response_body(res)
      if body and body:find('"api_list"', 1, true) then
        write_file(plugin_root() .. "/backend/api.json", body)
        local count = 0
        for _ in body:gmatch('"name"%s*:') do count = count + 1 end
        return true, count, ""
      end
      last_error = "Empty manifest"
    else
      last_error = err or ("HTTP " .. tostring(response_status(res)))
    end
  end
  return false, 0, last_error
end

local function ensure_cached_json_file(filename, urls, timeout)
  local path = plugin_root() .. "/backend/temp_dl/" .. filename
  local existing = read_file(path)
  if existing ~= "" then return existing end

  -- ADAPT-LINUX: temp_dl path joined with pjoin (was "\\backend\\temp_dl").
  ensure_dir(pjoin(plugin_root(), "backend", "temp_dl"))
  for _, url in ipairs(urls) do
    local res, err = http_request("GET", url, timeout or 30)
    if res and response_status(res) == 200 then
      local body = response_body(res)
      local trimmed = body:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or body
      if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
        write_file(path, body)
        return body
      end
    else
      log_line("Failed to refresh cache " .. tostring(filename) .. " from " .. tostring(url) .. ": " .. tostring(err or response_status(res)))
    end
  end

  return ""
end

local function plugin_version()
  local text = read_file(plugin_root() .. "/plugin.json")
  return text:match('"version"%s*:%s*"([^"]+)"') or "0"
end

local function version_parts(value)
  local parts = {}
  for n in tostring(value or ""):gmatch("(%d+)") do parts[#parts + 1] = tonumber(n) or 0 end
  return parts
end

local function compare_versions(a, b)
  local av = version_parts(a)
  local bv = version_parts(b)
  local max = math.max(#av, #bv)
  for i = 1, max do
    local ai = av[i] or 0
    local bi = bv[i] or 0
    if ai ~= bi then return ai > bi and 1 or -1 end
  end
  return 0
end

local function latest_release_info()
  local res = http_request("GET", "https://api.github.com/repos/madoiscool/ltsteamplugin/releases/latest", 15)
  local body = res and response_body(res) or ""
  if not res or response_status(res) ~= 200 or body == "" then
    res = http_request("GET", "https://luatools.vercel.app/api/github-latest", 15)
    body = res and response_body(res) or ""
  end
  if not res or response_status(res) ~= 200 or body == "" then return nil end
  local tag = body:match('"tag_name"%s*:%s*"([^"]+)"') or body:match('"name"%s*:%s*"([^"]+)"') or ""
  local version = tag:gsub("^v", "")
  local zip_url = body:match('"name"%s*:%s*"ltsteamplugin%.zip".-"browser_download_url"%s*:%s*"([^"]+)"')
  if zip_url then zip_url = zip_url:gsub("\\/", "/") end
  if zip_url == nil and tag ~= "" then zip_url = "https://luatools.vercel.app/api/get-plugin/" .. tag end
  if version == "" then return nil end
  return { version = version, zip_url = zip_url or "" }
end

local function api_url_for_app(api, appid, morrenus_key)
  local url = tostring(api.url or "")
  if url:find("<moapikey>", 1, true) then
    if morrenus_key == "" then return nil end
    url = url:gsub("<moapikey>", url_encode(morrenus_key))
  end
  return url:gsub("<appid>", tostring(appid))
end

local add_state = {}
local morrenus_stats_cache = {}
local fixes_index_cache = nil
-- ADAPT-LINUX: tracks AdditionalApps: appends so the inotify-driven
-- SLSsteam config rewrite runs at most once per appid per session.
-- Persistence isn't needed: append_additional_app is idempotent
-- against the on-disk YAML, but skipping repeated attempts cuts log
-- noise during the frontend's poll loop.
local additional_apps_registered = {}
local fixes_index_cache_time = 0

local function json_value(value)
  if type(value) == "number" then return tostring(value) end
  if type(value) == "boolean" then return value and "true" or "false" end
  return '"' .. esc(value or "") .. '"'
end

local function arg_value(args, ...)
  if type(args) ~= "table" then return nil end
  local keys = { ... }
  for _, key in ipairs(keys) do
    if args[key] ~= nil then return args[key] end
  end
  return nil
end

-- ADAPT-LINUX: ensure_dir was a Win32 FFI mkdir loop with a wscript
-- VBS fallback. Linux replaces this with a single mkdir -p via
-- platform.ensure_dir.
local function ensure_dir(path)
  platform.ensure_dir(platform.normalize(path))
end

-- ADAPT-LINUX: poke_steam_config_watchers shelled out to powershell
-- to bump LastWriteTime + drop a probe file. Linux uses inotify on
-- the same paths; platform.poke_watchers does the equivalent with
-- `touch` + brief probe-file create/remove.
local function poke_steam_config_watchers(appid)
  local base = steam_path()
  if base == "" then return end
  platform.poke_watchers(platform.normalize(base), appid)
  log_line("Poked Steam config watchers for " .. tostring(appid))
end

-- ADAPT-LINUX: list_files_recursive used powershell Get-ChildItem.
-- Linux uses `find -type f` via platform.list_files_recursive.
local function list_files_recursive(path)
  return platform.list_files_recursive(platform.normalize(path))
end

-- ADAPT-LINUX: filename worked off "\\" separators on Windows. We
-- accept both forms and strip whichever appears, returning the
-- basename. Pure-Lua, no platform call needed.
local function filename(path)
  local s = tostring(path or "")
  return (s:gsub("\\", "/"):match("([^/]+)$") or s)
end

local function dlc_count_from_lua(path, base_appid)
  local text = read_file(path)
  local count = tonumber(text:match("%-%-%s*[Tt]otal%s+DLCs%s*:%s*(%d+)") or "")
  if count and count > 0 then return count end

  local depots = {}
  for id in text:gmatch("[Ss]etManifestid%s*%(%s*(%d+)") do
    depots[tostring(id)] = true
  end

  local dlcs = {}
  local base = tostring(base_appid or "")
  for id in text:gmatch("[Aa]ddappid%s*%(%s*(%d+)") do
    id = tostring(id)
    if id ~= base and not depots[id] then
      dlcs[id] = true
    end
  end

  local total = 0
  for _ in pairs(dlcs) do total = total + 1 end
  return total
end

local function append_loaded_app(appid, name)
  local path = plugin_root() .. "/backend/loadedappids.txt"
  local lines = {}
  local prefix = tostring(appid) .. ":"
  for line in read_file(path):gmatch("[^\r\n]+") do
    if line:sub(1, #prefix) ~= prefix then lines[#lines + 1] = line end
  end
  lines[#lines + 1] = tostring(appid) .. ":" .. tostring(name or ("UNKNOWN (" .. tostring(appid) .. ")"))
  write_file(path, table.concat(lines, "\n") .. "\n")
end

local function state_path(appid)
  return plugin_root() .. "/backend/temp_dl/status_" .. tostring(appid) .. ".json"
end

local function fix_state_path(appid)
  return plugin_root() .. "/backend/temp_dl/fix_status_" .. tostring(appid) .. ".json"
end

local function unfix_state_path(appid)
  return plugin_root() .. "/backend/temp_dl/unfix_status_" .. tostring(appid) .. ".json"
end

local function state_json(appid)
  local text = read_file(state_path(appid))
  text = text:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or text
  if text ~= "" then return text end
  return nil
end

local function status_field(text, name)
  return tostring(text or ""):match('"' .. name .. '"%s*:%s*"([^"]*)"')
end

local function status_number(text, name)
  return tonumber(tostring(text or ""):match('"' .. name .. '"%s*:%s*(%d+)') or "")
end

local function normalized_state_json(appid)
  local text = state_json(appid)
  if not text then return nil end
  local status = status_field(text, "status") or "downloading"
  local current_api = status_field(text, "currentApi") or status_field(text, "api") or ""
  local err = status_field(text, "error")
  local bytes = status_number(text, "bytesRead") or 0
  local total = status_number(text, "totalBytes") or 0
  local manifests = status_number(text, "manifests")
  local dlcs = status_number(text, "dlcs")
  local success = tostring(text):match('"success"%s*:%s*true') ~= nil
  local out = {
    '"status":"' .. esc(status) .. '"',
    '"bytesRead":' .. tostring(bytes),
    '"totalBytes":' .. tostring(total),
  }
  if current_api ~= "" then out[#out + 1] = '"currentApi":"' .. esc(current_api) .. '"' end
  if current_api ~= "" then out[#out + 1] = '"api":"' .. esc(current_api) .. '"' end
  if manifests then out[#out + 1] = '"manifests":' .. tostring(manifests) end
  if dlcs then out[#out + 1] = '"dlcs":' .. tostring(dlcs) end
  if success then out[#out + 1] = '"success":true' end
  if err and err ~= "" then out[#out + 1] = '"error":"' .. esc(err) .. '"' end
  return "{" .. table.concat(out, ",") .. "}"
end

local function raw_json_object(path)
  local text = read_file(path)
  text = text:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or text
  if text ~= "" and text:sub(1, 1) == "{" then return text end
  return "{}"
end

local function ps_quote(value)
  return '"' .. tostring(value or ""):gsub('"', '\\"') .. '"'
end

-- ADAPT-LINUX: sleep_ms was Kernel32!Sleep with a busy-wait fallback.
-- Linux uses platform.sleep_ms (nanosleep via FFI, or `sleep` shell
-- fallback). Same blocking semantics, no busy-wait.
local function sleep_ms(ms)
  platform.sleep_ms(ms)
end

local function write_state_file(appid, json)
  -- ADAPT-LINUX: backend/temp_dl path uses pjoin instead of literal "\\".
  ensure_dir(pjoin(plugin_root(), "backend", "temp_dl"))
  write_file(state_path(appid), json)
end

-- ADAPT-LINUX: launch_*_worker on Windows spawned a hidden powershell
-- with the .ps1 path and named args. On Linux we ship equivalent
-- bash scripts under backend/platform/workers/<name>.sh and pass the
-- same logical args. platform.spawn_worker_async daemonizes via setsid.
local function worker_args_kv(pairs_list)
  local out = {}
  for i = 1, #pairs_list, 2 do
    out[#out + 1] = pairs_list[i]
    out[#out + 1] = pairs_list[i + 1] or ""
  end
  return out
end

local function launch_download_worker(appid, url, api_name)
  local args = worker_args_kv({
    "--app-id", tostring(appid or ""),
    "--url", tostring(url or ""),
    "--api-name", tostring(api_name or ""),
    "--plugin-root", plugin_root(),
    "--steam-path", steam_path(),
  })
  log_line("Launching download worker for " .. tostring(appid) .. " via " .. tostring(api_name))
  platform.spawn_worker_async(plugin_root(), "download_worker", args)
end

local function run_scan_helper(action, appid)
  -- ADAPT-LINUX: synchronous scan helper, mirrors steam_scan_helper.ps1
  -- semantics — the worker writes JSON to --output-path and we poll.
  local temp = pjoin(plugin_root(), "backend", "temp_dl")
  ensure_dir(temp)
  local output_path = pjoin(temp, "scan_" .. tostring(action or "helper") ..
    "_" .. tostring(os.time()) .. "_" ..
    tostring(math.random(1000, 9999)) .. ".json")
  local args = worker_args_kv({
    "--action", tostring(action or ""),
    "--plugin-root", plugin_root(),
    "--steam-path", steam_path(),
    "--app-id", tostring(appid or ""),
    "--output-path", output_path,
  })

  platform.spawn_worker_async(plugin_root(), "steam_scan_helper", args)

  local output = ""
  local started = os.time()
  while (os.time() - started) < 12 do
    output = read_file(output_path)
    if output ~= "" then break end
    sleep_ms(80)
  end

  output = output:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or output
  pcall(function() os.remove(output_path) end)
  if output ~= "" and output:sub(1, 1) == "{" then return output end
  log_line("steam_scan_helper returned invalid output for " .. tostring(action) .. ": " .. tostring(output))
  return json_fail("Helper timed out or returned invalid output")
end

local function launch_fix_worker(mode, appid, download_url, install_path, fix_type, game_name, fix_date)
  local args = worker_args_kv({
    "--mode", tostring(mode or ""),
    "--app-id", tostring(appid or ""),
    "--plugin-root", plugin_root(),
    "--download-url", tostring(download_url or ""),
    "--install-path", tostring(install_path or ""),
    "--fix-type", tostring(fix_type or ""),
    "--game-name", tostring(game_name or ""),
    "--fix-date", tostring(fix_date or ""),
  })
  log_line("Launching fix worker mode=" .. tostring(mode) .. " appid=" .. tostring(appid))
  platform.spawn_worker_async(plugin_root(), "fix_worker", args)
end

local function cleanup_temp_download_artifacts()
  -- ADAPT-LINUX: upstream ran a powershell one-liner that swept the
  -- temp_dl directory. Linux does the equivalent with `find` +
  -- platform.rmtree, no shell-escaping gymnastics needed.
  local temp = pjoin(plugin_root(), "backend", "temp_dl")
  ensure_dir(temp)
  local p = io.popen("find " .. ("'" .. temp:gsub("'", [['"'"']]) .. "'") ..
    " -mindepth 1 -maxdepth 1 \\( -type d -name 'extract_*' -o -name '*.zip' -o -name 'scan_*.json' \\) 2>/dev/null", "r")
  if p then
    for entry in p:lines() do
      if entry ~= "" then
        if entry:match("/extract_[^/]*$") then
          platform.rmtree(entry)
        else
          pcall(function() os.remove(entry) end)
        end
      end
    end
    p:close()
  end
end

local function install_lua_zip(appid, zip_path)
  -- ADAPT-LINUX: paths use pjoin; extraction uses platform.unzip.
  local base = steam_path()
  local temp = pjoin(plugin_root(), "backend", "temp_dl", "extract_" .. tostring(appid))
  local depotcache = pjoin(base, "depotcache")
  local target = pjoin(base, "config", "stplug-in")
  ensure_dir(pjoin(plugin_root(), "backend", "temp_dl"))
  ensure_dir(depotcache)
  ensure_dir(target)
  local ok_unzip, unzip_err = platform.unzip(zip_path, temp)
  if not ok_unzip then
    return false, unzip_err or "unzip failed"
  end

  local lua_file = nil
  local manifests = 0
  for _, path in ipairs(list_files_recursive(temp)) do
    local name = filename(path)
    if name:lower():match("%.manifest$") then
      copy_file(path, pjoin(depotcache, name))
      manifests = manifests + 1
    elseif name:lower() == tostring(appid) .. ".lua" then
      lua_file = path
    elseif not lua_file and name:lower():match("%.lua$") then
      lua_file = path
    end
  end

  if not lua_file then return false, "No lua file found in downloaded archive" end
  local dlcs = dlc_count_from_lua(lua_file, appid)
  if not copy_file(lua_file, pjoin(target, tostring(appid) .. ".lua")) then return false, "Failed to install lua file" end
  os.remove(zip_path)
  platform.rmtree(temp)
  log_line("Installed appid " .. tostring(appid) .. " from zip; manifests=" .. tostring(manifests) .. " dlcs=" .. tostring(dlcs))
  return true, nil, manifests, dlcs
end

local function download_and_install(appid, url, api_name)
  -- ADAPT-LINUX: dest path uses pjoin instead of "\\backend\\temp_dl\\".
  local dest = pjoin(plugin_root(), "backend", "temp_dl", tostring(appid) .. ".zip")
  ensure_dir(pjoin(plugin_root(), "backend", "temp_dl"))
  add_state[appid] = { status = "downloading", currentApi = api_name, bytesRead = 0, totalBytes = 0 }
  local res, err = http_request("GET", url, 120)
  if not res then
    add_state[appid] = { status = "failed", error = err or "Download failed" }
    return false
  end
  local status = response_status(res)
  if status < 200 or status >= 300 then
    add_state[appid] = { status = "failed", error = "HTTP " .. tostring(status) }
    return false
  end
  local body = response_body(res)
  write_file(dest, body)
  add_state[appid] = { status = "processing", currentApi = api_name, bytesRead = #body, totalBytes = #body }
  local ok_install, install_err, manifests, dlcs = install_lua_zip(appid, dest)
  if not ok_install then
    add_state[appid] = { status = "failed", error = install_err or "Install failed" }
    return false
  end
  poke_steam_config_watchers(appid)
  append_loaded_app(appid, "UNKNOWN (" .. tostring(appid) .. ")")
  -- ADAPT-LINUX: auto-register the appid in SLSsteam's
  -- AdditionalApps: list. On Windows the .so reads the same list
  -- from an INI-ish config; the LuaTools UX has historically been
  -- "drop the .lua and let the user edit the config". On Linux the
  -- config lives at ~/.config/SLSsteam/config.yaml and SLSsteam
  -- watches it via inotify, so a successful append makes the new
  -- appid live without further user action (Steam restart still
  -- required for PICS injection to refresh — same as before).
  -- Idempotent + non-fatal: if the YAML can't be parsed (or already
  -- has the appid) we just log and continue.
  local cfg_ok, cfg_msg = platform.append_additional_app(appid,
    "added via LuaTools")
  if cfg_ok then
    log_line("SLSsteam config: " .. tostring(cfg_msg) .. " " .. tostring(appid))
  else
    log_line("SLSsteam config update skipped for " .. tostring(appid) ..
      ": " .. tostring(cfg_msg))
  end
  add_state[appid] = { status = "done", success = true, api = api_name, bytesRead = #body, totalBytes = #body, manifests = manifests or 0, dlcs = dlcs or 0 }
  return true
end

function LoggerLog(args) log_line("[Frontend] " .. tostring(type(args) == "table" and args.message or args)); return json_ok() end
function LoggerWarn(args) log_line("[Frontend WARN] " .. tostring(type(args) == "table" and args.message or args)); return json_ok() end
function LoggerError(args) log_line("[Frontend ERROR] " .. tostring(type(args) == "table" and args.message or args)); return json_ok() end

function GetPluginDir() return plugin_root() end
function InitApis()
  if read_file(plugin_root() .. "/backend/api.json") == "" then
    local ok, count = refresh_free_apis()
    if ok then startup_message = "No API's Configured, Loaded " .. tostring(count) .. " Free Ones :D" end
  end
  return json_ok('"message":"' .. esc(startup_message or "") .. '"')
end
function GetInitApisMessage()
  local msg = startup_message or ""
  startup_message = ""
  return json_ok('"message":"' .. esc(msg) .. '"')
end
function FetchFreeApisNow()
  local ok, count, err = refresh_free_apis()
  if ok then return json_ok('"count":' .. tostring(count)) end
  return json_fail(err or "Failed to fetch API manifest")
end

function CheckForUpdatesNow()
  local info = latest_release_info()
  if not info then return json_fail("Failed to check for updates") end
  local current = plugin_version()
  if compare_versions(info.version, current) > 0 then
    return json_ok('"message":"LuaTools update available: ' .. esc(info.version) .. '. Download it from the LuaTools release page."')
  end
  return json_ok('"message":""')
end
function RestartSteam()
  -- ADAPT-LINUX: upstream ran backend/restart_steam.cmd via cmd.exe.
  -- Linux ships restart_steam.sh under backend/platform/workers/;
  -- platform.restart_steam fires it asynchronously.
  platform.restart_steam()
  return json_ok()
end

function HasLuaToolsForApp(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  -- ADAPT-LINUX: stplug-in path uses pjoin instead of "\\config\\stplug-in\\".
  local base = steam_path()
  local p1 = pjoin(base, "config", "stplug-in", tostring(appid) .. ".lua")
  local p2 = pjoin(base, "config", "stplug-in", tostring(appid) .. ".lua.disabled")
  return json_ok('"exists":' .. ((exists(p1) or exists(p2)) and "true" or "false"))
end

function GetIconDataUrl()
  local data = read_file(plugin_root() .. "/public/luatools-icon.png")
  if data == "" then return json_fail("Icon not found") end
  return json_ok('"dataUrl":"data:image/png;base64,' .. base64_encode(data) .. '"')
end

function GetApiList()
  local key = get_morrenus_key()
  local items = {}
  for i, api in ipairs(load_apis()) do
    if not api.url:find("<moapikey>", 1, true) or key ~= "" then
      items[#items + 1] = '{"name":"' .. esc(api.name) .. '","index":' .. tostring(i - 1) .. "}"
    end
  end
  log_line("GetApiList returned " .. tostring(#items) .. " APIs")
  return json_ok('"apis":[' .. table.concat(items, ",") .. "]")
end

function CheckApisForApp(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end

  local key = get_morrenus_key()
  local fast = nil
  do
    local res = http_request("GET", "http://167.235.229.108/check_apis?appid=" .. tostring(appid), 5)
    if res and response_status(res) == 200 then
      fast = decode_json(response_body(res))
      log_line("Fast API check responded for " .. tostring(appid))
    else
      log_line("Fast API check unavailable for " .. tostring(appid))
    end
  end

  local results = {}
  for _, api in ipairs(load_apis()) do
    local url = api_url_for_app(api, appid, key)
    if url then
      local available = false
      if type(fast) == "table" then
        local fast_key = api.name:lower() == "morrenus" and "Sadie (Morrenus)" or api.name
        available = fast[fast_key] == "available"
      else
        local check_url = url
        if api.name:lower() == "morrenus" then
          check_url = "https://hubcapmanifest.com/api/v1/status/" .. tostring(appid) .. "?api_key=" .. key
        end

        local res = http_request("HEAD", check_url, 6)
        local status = response_status(res)
        if status == 405 or status == 0 then
          res = http_request("GET", check_url, 6)
          status = response_status(res)
        end
        available = status == api.success_code
        log_line("Checked API " .. api.name .. " for " .. tostring(appid) .. " status=" .. tostring(status) .. " available=" .. tostring(available))
      end

      results[#results + 1] =
        '{"name":"' .. esc(api.name) .. '","available":' .. (available and "true" or "false") ..
        ',"url":' .. (available and ('"' .. esc(url) .. '"') or "null") .. "}"
    end
  end

  return json_ok('"results":[' .. table.concat(results, ",") .. "]")
end
function StartAddViaLuaTools(args, maybe_url, maybe_api_name)
  dump_args("StartAddViaLuaTools", args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  log_line("StartAddViaLuaTools called for " .. tostring(appid))
  local key = get_morrenus_key()
  add_state[appid] = { status = "checking", bytesRead = 0, totalBytes = 0 }
  for _, api in ipairs(load_apis()) do
    local url = api_url_for_app(api, appid, key)
    if url then
      local res = http_request("HEAD", url, 6)
      local status = response_status(res)
      if status == 405 or status == 0 then
        res = http_request("GET", url, 10)
        status = response_status(res)
      end
      if status == api.success_code then
        write_state_file(appid, '{"status":"downloading","currentApi":"' .. esc(api.name) .. '","bytesRead":0,"totalBytes":0}')
        launch_download_worker(appid, url, api.name)
        return json_ok()
      end
    end
  end
  add_state[appid] = { status = "failed", error = "Not available on any API" }
  return json_ok()
end

function StartAddViaLuaToolsFromUrl(args, maybe_url, maybe_api_name)
  dump_args("StartAddViaLuaToolsFromUrl", args)
  local appid = appid_from_args(args)
  local url = ""
  local api_name = "Unknown"
  if type(args) == "table" then
    url = tostring(args.url or args.URL or "")
    api_name = tostring(args.apiName or args.apiname or args.api_name or args.name or "Unknown")
    if api_name == "Unknown" and args[1] then api_name = tostring(args[1]) end
    if not appid and args[2] then appid = tonumber(args[2]) end
    if url == "" and args[3] then url = tostring(args[3]) end
    if url == "" then
      for _, v in pairs(args) do
        local s = tostring(v)
        if s:match("^https?://") then url = s end
      end
    end
  else
    if appid then
      url = tostring(maybe_url or "")
      api_name = tostring(maybe_api_name or "Unknown")
    else
      api_name = tostring(args or "Unknown")
      appid = tonumber(maybe_url)
      url = tostring(maybe_api_name or "")
    end
  end
  if not appid then return json_fail("Invalid appid") end
  if url == "" then return json_fail("Missing URL") end
  log_line("StartAddViaLuaToolsFromUrl called for " .. tostring(appid) .. " via " .. tostring(api_name))
  add_state[appid] = { status = "downloading", currentApi = api_name, bytesRead = 0, totalBytes = 0 }
  write_state_file(appid, '{"status":"downloading","currentApi":"' .. esc(api_name) .. '","bytesRead":0,"totalBytes":0}')
  launch_download_worker(appid, url, api_name)
  return json_ok()
end

function GetAddViaLuaToolsStatus(args)
  local appid = appid_from_args(args)
  local file_state = appid and normalized_state_json(appid) or nil
  if file_state then
    -- ADAPT-LINUX: when the worker reports done, side-effect once per
    -- appid: register the appid in SLSsteam's AdditionalApps:.
    -- Mirror of the same call in the in-process download_and_install
    -- path (which the legacy frontend takes); the worker-driven path
    -- needs the hook here because download_worker.sh writes its own
    -- status file out-of-band.
    if appid and file_state:match('"status":"done"') and
       not additional_apps_registered[appid] then
      additional_apps_registered[appid] = true
      local cfg_ok, cfg_msg = platform.append_additional_app(appid,
        "added via LuaTools")
      if cfg_ok then
        log_line("SLSsteam config: " .. tostring(cfg_msg) .. " " .. tostring(appid))
      else
        log_line("SLSsteam config update skipped for " .. tostring(appid) ..
          ": " .. tostring(cfg_msg))
      end
    end
    return json_ok('"state":' .. file_state)
  end
  local state = add_state[appid or 0] or {}
  local parts = {}
  for k, v in pairs(state) do
    if type(v) == "number" then parts[#parts + 1] = '"' .. esc(k) .. '":' .. tostring(v)
    elseif type(v) == "boolean" then parts[#parts + 1] = '"' .. esc(k) .. '":' .. (v and "true" or "false")
    else parts[#parts + 1] = '"' .. esc(k) .. '":"' .. esc(v) .. '"' end
  end
  return json_ok('"state":{' .. table.concat(parts, ",") .. "}")
end

function CancelAddViaLuaTools(args)
  local appid = appid_from_args(args)
  if appid then
    add_state[appid] = { status = "cancelled", error = "Cancelled by user" }
    write_state_file(appid, '{"status":"cancelled","error":"Cancelled by user"}')
  end
  return json_ok()
end

function GetGamesDatabase()
  local data = ensure_cached_json_file("games.json", {
    "https://toolsdb.piqseu.cc/games.json",
  }, 60)
  if data ~= "" then return data end
  return "{}"
end

function ReadLoadedApps()
  local path = plugin_root() .. "/backend/loadedappids.txt"
  local apps = {}
  for line in read_file(path):gmatch("[^\r\n]+") do
    local id, name = line:match("^(%d+):(.*)$")
    if id and name then apps[#apps + 1] = '{"appid":' .. id .. ',"name":"' .. esc(name) .. '"}' end
  end
  return json_ok('"apps":[' .. table.concat(apps, ",") .. "]")
end

function DismissLoadedApps()
  write_file(plugin_root() .. "/backend/loadedappids.txt", "")
  return json_ok()
end

function DeleteLuaToolsForApp(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  -- ADAPT-LINUX: stplug-in path uses pjoin.
  local base = pjoin(steam_path(), "config", "stplug-in")
  local deleted = {}
  for _, suffix in ipairs({ ".lua", ".lua.disabled" }) do
    local path = pjoin(base, tostring(appid) .. suffix)
    if exists(path) then
      local ok = os.remove(path)
      if ok then deleted[#deleted + 1] = '"' .. esc(path) .. '"' end
    end
  end

  local loaded_path = plugin_root() .. "/backend/loadedappids.txt"
  local lines = {}
  local removed_name = "UNKNOWN (" .. tostring(appid) .. ")"
  local prefix = tostring(appid) .. ":"
  for line in read_file(loaded_path):gmatch("[^\r\n]+") do
    if line:sub(1, #prefix) == prefix then
      removed_name = line:sub(#prefix + 1)
    else
      lines[#lines + 1] = line
    end
  end
  write_file(loaded_path, (#lines > 0 and table.concat(lines, "\n") .. "\n" or ""))
  if #deleted > 0 then
    local log_path = plugin_root() .. "/backend/appidlogs.txt"
    local existing = read_file(log_path)
    write_file(log_path, existing .. "[REMOVED] " .. tostring(appid) .. " - " .. removed_name .. " - " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
  end
  return json_ok('"deleted":[' .. table.concat(deleted, ",") .. '],"count":' .. tostring(#deleted))
end

function CheckForFixes(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  local generic_url = "https://files.luatools.work/GameBypasses/" .. tostring(appid) .. ".zip"
  local online_url = "https://files.luatools.work/OnlineFix1/" .. tostring(appid) .. ".zip"
  local generic_available = false
  local online_available = false

  local now = os.time()
  if not fixes_index_cache or (now - fixes_index_cache_time) > 900 then
    local res = http_request("GET", "https://index.luatools.work/fixes-index.json", 10)
    if res and response_status(res) == 200 then
      fixes_index_cache = response_body(res)
      fixes_index_cache_time = now
      log_line("Loaded fixes index")
    else
      fixes_index_cache = nil
    end
  end

  local function array_has(key)
    local body = tostring(fixes_index_cache or "")
    local pattern = '"' .. key .. '"%s*:%s*(%b[])'
    local segment = body:match(pattern) or ""
    return segment:find("[^%d]" .. tostring(appid) .. "[^%d]") ~= nil or segment:find("^%[" .. tostring(appid) .. "[^%d]") ~= nil
  end

  if fixes_index_cache then
    generic_available = array_has("genericFixes")
    online_available = array_has("onlineFixes")
  else
    local generic = http_request("HEAD", generic_url, 8)
    local online = http_request("HEAD", online_url, 8)
    generic_available = response_status(generic) == 200
    online_available = response_status(online) == 200
  end

  return '{"success":true,"appid":' .. tostring(appid) ..
    ',"gameName":"Unknown Game (' .. esc(appid) .. ')"' ..
    ',"genericFix":{"status":' .. (generic_available and "200" or "404") .. ',"available":' .. (generic_available and "true" or "false") .. (generic_available and ',"url":"' .. esc(generic_url) .. '"' or "") .. "}" ..
    ',"onlineFix":{"status":' .. (online_available and "200" or "404") .. ',"available":' .. (online_available and "true" or "false") .. (online_available and ',"url":"' .. esc(online_url) .. '"' or "") .. "}}"
end

function ApplyGameFix(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  local download_url = tostring(arg_value(args, "downloadUrl", "download_url", "url") or "")
  local install_path = tostring(arg_value(args, "installPath", "install_path", "path") or "")
  local fix_type = tostring(arg_value(args, "fixType", "fix_type") or "")
  local game_name = tostring(arg_value(args, "gameName", "game_name") or "")
  if download_url == "" or install_path == "" then return json_fail("Missing download URL or install path") end
  write_file(fix_state_path(appid), '{"status":"queued","bytesRead":0,"totalBytes":0}')
  launch_fix_worker("Apply", appid, download_url, install_path, fix_type, game_name, "")
  return json_ok()
end

function GetApplyFixStatus(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  return json_ok('"state":' .. raw_json_object(fix_state_path(appid)))
end

function CancelApplyFix(args)
  local appid = appid_from_args(args)
  if appid then write_file(fix_state_path(appid), '{"status":"cancelled","success":false,"error":"Cancelled by user"}') end
  return json_ok()
end

function UnFixGame(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  local install_path = tostring(arg_value(args, "installPath", "install_path", "path") or "")
  local fix_date = tostring(arg_value(args, "fixDate", "fix_date", "date") or "")
  if install_path == "" then
    local payload = run_scan_helper("GetGameInstallPath", appid)
    install_path = payload:match('"installPath"%s*:%s*"([^"]+)"') or ""
    -- ADAPT-LINUX: upstream un-doubled "\\\\" → "\\" because the
    -- scan helper JSON-encoded backslashes. Linux scan helper emits
    -- forward slashes; this normalization is a no-op but harmless,
    -- and we keep it so JSON-shaped Windows backups still parse.
    install_path = install_path:gsub("\\\\", "\\")
  end
  if install_path == "" then return json_fail("Could not find game install path") end
  write_file(unfix_state_path(appid), '{"status":"queued","progress":""}')
  launch_fix_worker("Unfix", appid, "", install_path, "", "", fix_date)
  return json_ok()
end

function GetUnfixStatus(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  return json_ok('"state":' .. raw_json_object(unfix_state_path(appid)))
end

function GetInstalledFixes()
  return run_scan_helper("GetInstalledFixes")
end

function GetInstalledLuaScripts()
  return run_scan_helper("GetInstalledLuaScripts")
end

function GetGameInstallPath(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  return run_scan_helper("GetGameInstallPath", appid)
end

function OpenGameFolder(args)
  -- ADAPT-LINUX: explorer.exe → xdg-open via platform.open_path.
  local path = type(args) == "table" and tostring(args.path or "") or tostring(args or "")
  if path == "" then return json_fail("Failed to open path") end
  if not platform.open_path(path) then return json_fail("Failed to open path") end
  return json_ok()
end

function OpenExternalUrl(args)
  -- ADAPT-LINUX: rundll32 url.dll,FileProtocolHandler → xdg-open via
  -- platform.open_url.
  local url = url_from_args(args)
  if not url:match("^https?://") then return json_fail("Invalid URL") end
  if not platform.open_url(url) then return json_fail("Failed to open URL") end
  return json_ok()
end

local LOCALE_CODES = {
  "ar", "bg", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hu",
  "id", "it", "ja", "ko", "nl", "no", "peakstupid", "pirate", "pl", "pt",
  "pt-BR", "pt-decria", "ro", "ru", "sv", "th", "tr", "uk", "vi", "zh-CN",
  "zh-TW",
}

-- ADAPT-LINUX: STEAM_LANG_TO_LOCALE moved to platform.lua. The mapping
-- from Steam's internal language strings (e.g. "schinese") to BCP-47
-- locale codes is platform-agnostic, but the call site that used it
-- (detect_steam_locale) is platform-specific, so the table follows.

local function json_string(value)
  return '"' .. esc(value or "") .. '"'
end

local function settings_path()
  return plugin_root() .. "/backend/data/settings.json"
end

local function setting_string(text, key, default)
  local value = tostring(text or ""):match('"' .. key .. '"%s*:%s*"([^"]*)"')
  if value == nil or value == "" then return default end
  return value
end

local function setting_bool(text, key, default)
  local value = tostring(text or ""):match('"' .. key .. '"%s*:%s*(true)') or tostring(text or ""):match('"' .. key .. '"%s*:%s*(false)')
  if value == "true" then return true end
  if value == "false" then return false end
  return default
end

local function normalize_locale_code(value)
  local raw = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if raw == "" then return "en" end
  local lower = raw:lower():gsub("_", "-")
  local aliases = {
    ["brazilian"] = "pt-BR",
    ["pt-br"] = "pt-BR",
    ["schinese"] = "zh-CN",
    ["zh-cn"] = "zh-CN",
    ["tchinese"] = "zh-TW",
    ["zh-tw"] = "zh-TW",
    ["latam"] = "es",
    ["es-419"] = "es",
  }
  if aliases[lower] then return aliases[lower] end
  for _, code in ipairs(LOCALE_CODES) do
    if lower == code:lower() then return code end
  end
  return raw
end

local function read_settings_values()
  local text = read_file(settings_path())
  return {
    useSteamLanguage = setting_bool(text, "useSteamLanguage", true),
    language = normalize_locale_code(setting_string(text, "language", "en")),
    donateKeys = setting_bool(text, "donateKeys", true),
    theme = setting_string(text, "theme", "original"),
    fastDownload = setting_bool(text, "fastDownload", true),
    morrenusApiKey = setting_string(text, "morrenusApiKey", ""),
    apis = read_settings_api_overrides(),
  }
end

local function api_settings_json(values)
  local apis = values and type(values.apis) == "table" and values.apis or {}
  local keys = {}
  for key, enabled in pairs(apis) do
    if type(enabled) == "boolean" then keys[#keys + 1] = tostring(key) end
  end
  table.sort(keys)
  local items = {}
  for _, key in ipairs(keys) do
    items[#items + 1] = json_string(key) .. ":" .. (apis[key] == true and "true" or "false")
  end
  return "{" .. table.concat(items, ",") .. "}"
end

local function settings_values_json(values)
  values = values or read_settings_values()
  return '{"general":{"useSteamLanguage":' .. (values.useSteamLanguage ~= false and "true" or "false") ..
    ',"language":' .. json_string(values.language or "en") ..
    ',"donateKeys":' .. (values.donateKeys ~= false and "true" or "false") ..
    ',"theme":' .. json_string(values.theme or "original") ..
    ',"fastDownload":' .. (values.fastDownload ~= false and "true" or "false") ..
    ',"morrenusApiKey":' .. json_string(values.morrenusApiKey or "") ..
    '},"apis":' .. api_settings_json(values) .. "}"
end

local function write_settings_values(values)
  -- ADAPT-LINUX: backend/data path joined with pjoin.
  ensure_dir(pjoin(plugin_root(), "backend", "data"))
  return write_file(settings_path(), '{\n  "version": 1,\n  "values": ' .. settings_values_json(values) .. "\n}\n")
end

local function locales_json()
  local items = {}
  for _, code in ipairs(LOCALE_CODES) do
    local path = plugin_root() .. "/backend/locales/" .. code .. ".json"
    if exists(path) then
      local text = read_file(path)
      local name = text:match('"__name"%s*:%s*"([^"]+)"') or code
      local native = text:match('"__nativeName"%s*:%s*"([^"]+)"') or name
      items[#items + 1] = '{"code":' .. json_string(code) .. ',"name":' .. json_string(name) .. ',"nativeName":' .. json_string(native) .. "}"
    end
  end
  if #items == 0 then items[#items + 1] = '{"code":"en","name":"English","nativeName":"English"}' end
  return "[" .. table.concat(items, ",") .. "]"
end

local function themes_json()
  local text = read_file(plugin_root() .. "/public/themes/themes.json")
  text = text:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or text
  if text ~= "" and text:sub(1, 1) == "[" then return text end
  return '[{"value":"original","label":"Original"}]'
end

local function settings_schema_json()
  local locale_choices = {}
  for _, code in ipairs(LOCALE_CODES) do
    if exists(plugin_root() .. "/backend/locales/" .. code .. ".json") then
      locale_choices[#locale_choices + 1] = '{"value":' .. json_string(code) .. ',"label":' .. json_string(code) .. "}"
    end
  end
  local groups = {}
  groups[#groups + 1] = '{"key":"general","label":"General","description":"Global LuaTools preferences.","options":[' ..
    '{"key":"useSteamLanguage","label":"Use Steam Language","type":"toggle","description":"Use the Steam client language for LuaTools.","default":true,"choices":[],"requiresRestart":false,"metadata":{"yesLabel":"Yes","noLabel":"No"}},' ..
    '{"key":"language","label":"Language","type":"select","description":"Choose the language used by LuaTools.","default":"en","choices":[' .. table.concat(locale_choices, ",") .. '],"requiresRestart":false,"metadata":{"dynamicChoices":"locales"}},' ..
    '{"key":"donateKeys","label":"Donate Keys","type":"toggle","description":"Allow LuaTools to donate spare Steam keys.","default":true,"choices":[],"requiresRestart":false,"metadata":{"yesLabel":"Yes","noLabel":"No"}},' ..
    '{"key":"theme","label":"Theme","type":"select","description":"Choose the color theme for LuaTools interface.","default":"original","choices":' .. themes_json() .. ',"requiresRestart":false,"metadata":{"dynamicChoices":"themes"}},' ..
    '{"key":"fastDownload","label":"Fast Download","type":"toggle","description":"Automatically choose the first available source when adding a game.","default":true,"choices":[],"requiresRestart":false,"metadata":{"yesLabel":"Yes","noLabel":"No"}},' ..
    '{"key":"morrenusApiKey","label":"Morrenus API Key","type":"text","description":"API Key required to use Sadie Source. Get from hubcapmanifest.com","default":"","choices":[],"requiresRestart":false,"metadata":{"placeholder":"Enter your API key..."}}' ..
    "]}"

  local api_options = {}
  for _, api in ipairs(load_api_manifest_entries()) do
    local name = tostring(api.name or "Unknown")
    api_options[#api_options + 1] =
      '{"key":' .. json_string(api_setting_key(name)) ..
      ',"label":' .. json_string(name) ..
      ',"type":"toggle","description":' ..
      json_string("Use " .. name .. " when checking and downloading Lua manifests.") ..
      ',"default":' .. (api.enabled ~= false and "true" or "false") ..
      ',"choices":[],"requiresRestart":false,"metadata":{"yesLabel":"On","noLabel":"Off"}}'
  end
  if #api_options > 0 then
    groups[#groups + 1] =
      '{"key":"apis","label":"APIs","description":"Choose which manifest APIs LuaTools can use.","options":[' ..
      table.concat(api_options, ",") .. "]}"
  end

  return "[" .. table.concat(groups, ",") .. "]"
end

-- ADAPT-LINUX: detect_steam_locale on Windows read HKCU\Software\
-- Valve\Steam\Language via Advapi32!RegGetValueA. The Linux Steam
-- client persists the same value to ~/.steam/registry.vdf as a
-- plain VDF text file; platform.detect_steam_locale parses it.
-- The Windows-side STEAM_LANG_TO_LOCALE table is duplicated inside
-- platform.lua so the mapping stays platform-local and main.lua
-- only needs the resolved locale code back.
local function detect_steam_locale()
  return platform.detect_steam_locale()
end

local function current_settings_language(values)
  values = values or read_settings_values()
  if values.useSteamLanguage ~= false then
    local detected = detect_steam_locale()
    if detected then return detected end
  end
  if exists(plugin_root() .. "/backend/locales/" .. tostring(values.language or "") .. ".json") then return tostring(values.language) end
  return "en"
end

local function translations_json(language)
  local lang = language and normalize_locale_code(language) or current_settings_language()
  local path = plugin_root() .. "/backend/locales/" .. tostring(lang) .. ".json"
  if not exists(path) then lang = "en"; path = plugin_root() .. "/backend/locales/en.json" end
  local text = read_file(path)
  text = text:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or text
  if text == "" or text:sub(1, 1) ~= "{" then text = "{}" end
  return lang, text
end

local function apply_setting_payload(values, payload)
  local text = type(payload) == "string" and payload or ""
  if type(payload) == "table" then
    local general = type(payload.general) == "table" and payload.general or payload
    if type(payload.apis) == "table" then
      values.apis = values.apis or {}
      for key, enabled in pairs(payload.apis) do
        values.apis[tostring(key)] = enabled == true
      end
    end
    if general.useSteamLanguage ~= nil then values.useSteamLanguage = general.useSteamLanguage == true end
    if general.language ~= nil then
      values.language = normalize_locale_code(general.language)
      values.useSteamLanguage = false
    end
    if general.donateKeys ~= nil then values.donateKeys = general.donateKeys == true end
    if general.theme ~= nil then values.theme = tostring(general.theme) end
    if general.fastDownload ~= nil then values.fastDownload = general.fastDownload == true end
    if general.morrenusApiKey ~= nil then values.morrenusApiKey = tostring(general.morrenusApiKey) end
    return values
  end
  local decoded = decode_json(text)
  if type(decoded) == "table" then return apply_setting_payload(values, decoded) end

  values.apis = values.apis or {}
  local api_block = text:match('"apis"%s*:%s*{(.-)}')
  if api_block then
    for key, value in api_block:gmatch('"([^"]+)"%s*:%s*([%a]+)') do
      if value == "true" then values.apis[key] = true end
      if value == "false" then values.apis[key] = false end
    end
  end

  local function maybe_bool(key)
    local v = setting_bool(text, key, nil)
    if v ~= nil then values[key] = v end
  end
  maybe_bool("useSteamLanguage")
  maybe_bool("donateKeys")
  maybe_bool("fastDownload")
  local next_language = setting_string(text, "language", values.language)
  values.language = normalize_locale_code(next_language)
  if text:find('"language"%s*:') then values.useSteamLanguage = false end
  values.theme = setting_string(text, "theme", values.theme)
  values.morrenusApiKey = setting_string(text, "morrenusApiKey", values.morrenusApiKey)
  return values
end

function GetSettingsConfig()
  local values = read_settings_values()
  local lang, strings = translations_json(current_settings_language(values))
  return json_ok('"schemaVersion":1,"schema":' .. settings_schema_json() .. ',"values":' .. settings_values_json(values) .. ',"language":' .. json_string(lang) .. ',"locales":' .. locales_json() .. ',"translations":' .. strings)
end

function ApplySettingsChanges(args)
  local values = read_settings_values()
  local payload = args
  if type(args) == "table" then payload = args.changes or args.changesJson or args end
  values = apply_setting_payload(values, payload)
  write_settings_values(values)
  local lang, strings = translations_json(current_settings_language(values))
  log_line("Settings saved: language=" .. tostring(values.language) .. " useSteamLanguage=" .. tostring(values.useSteamLanguage) .. " resolved=" .. tostring(lang) .. " theme=" .. tostring(values.theme))
  return json_ok('"values":' .. settings_values_json(values) .. ',"language":' .. json_string(lang) .. ',"translations":' .. strings .. ',"locales":' .. locales_json())
end

function GetAvailableLocales() return json_ok('"locales":' .. locales_json()) end
function GetTranslations(args)
  local language = type(args) == "table" and (args.language or args[1]) or args
  if language == "" then language = nil end
  local lang, strings = translations_json(language)
  return json_ok('"language":' .. json_string(lang) .. ',"locales":' .. locales_json() .. ',"strings":' .. strings)
end
function GetThemes() return json_ok('"themes":' .. themes_json()) end
function GetAvailableThemes() return GetThemes() end
function GetMorrenusStats(args)
  local key = ""
  local force_refresh = false
  if type(args) == "table" then
    key = tostring(args.api_key or args.apiKey or args[1] or "")
    force_refresh = args.force_refresh == true or args.forceRefresh == true
  else
    key = tostring(args or "")
  end
  key = key:gsub("^%s+", ""):gsub("%s+$", "")
  if key == "" then return json_fail("Missing API key") end

  local now = os.time()
  if not force_refresh and morrenus_stats_cache[key] and now - morrenus_stats_cache[key].time < 600 then
    return morrenus_stats_cache[key].data
  end

  local res, err = http_request("GET", "https://hubcapmanifest.com/api/v1/user/stats?api_key=" .. url_encode(key), 10)
  local status = response_status(res)
  local body = response_body(res)
  if body ~= "" then
    if status == 200 then morrenus_stats_cache[key] = { time = now, data = body } end
    return body
  end
  return json_fail(err or ("HTTP " .. tostring(status)))
end

local function on_frontend_loaded()
  -- ADAPT-LINUX: steamui/LuaTools is the destination Millennium reads
  -- from for add_browser_js. Path joining now uses pjoin so the same
  -- code works regardless of platform separator.
  local root = plugin_root()
  local dst = pjoin(steam_path(), "steamui", "LuaTools")
  ensure_dir(dst)
  copy_file(pjoin(root, "public", "luatools.js"), pjoin(dst, "luatools.js"))
  copy_file(pjoin(root, "public", "luatools-icon.png"), pjoin(dst, "luatools-icon.png"))
  ensure_dir(pjoin(dst, "themes"))
  local themes_src = pjoin(root, "public", "themes")
  for _, path in ipairs(list_files_recursive(themes_src)) do
    local name = filename(path)
    if name:lower():match("%.css$") then
      copy_file(path, pjoin(dst, "themes", name))
    end
  end
end

local function on_load()
  log_line("LuaTools bootstrap loading")
  -- ADAPT-LINUX: hand the plugin root to platform so things like
  -- restart_steam can locate workers without main.lua re-passing it.
  platform.set_plugin_root(plugin_root())
  millennium.ready()
  cleanup_temp_download_artifacts()
  on_frontend_loaded()
  millennium.add_browser_js("LuaTools/luatools.js")
  log_line("LuaTools bootstrap ready")
end

local function on_unload()
  log_line("LuaTools bootstrap unloading")
end

return {
  on_load = on_load,
  on_unload = on_unload,
  on_frontend_loaded = on_frontend_loaded,
  LoggerLog = LoggerLog,
  LoggerWarn = LoggerWarn,
  LoggerError = LoggerError,
  GetPluginDir = GetPluginDir,
  InitApis = InitApis,
  GetInitApisMessage = GetInitApisMessage,
  FetchFreeApisNow = FetchFreeApisNow,
  CheckForUpdatesNow = CheckForUpdatesNow,
  RestartSteam = RestartSteam,
  HasLuaToolsForApp = HasLuaToolsForApp,
  GetIconDataUrl = GetIconDataUrl,
  GetApiList = GetApiList,
  CheckApisForApp = CheckApisForApp,
  StartAddViaLuaTools = StartAddViaLuaTools,
  StartAddViaLuaToolsFromUrl = StartAddViaLuaToolsFromUrl,
  GetAddViaLuaToolsStatus = GetAddViaLuaToolsStatus,
  CancelAddViaLuaTools = CancelAddViaLuaTools,
  GetGamesDatabase = GetGamesDatabase,
  ReadLoadedApps = ReadLoadedApps,
  DismissLoadedApps = DismissLoadedApps,
  DeleteLuaToolsForApp = DeleteLuaToolsForApp,
  CheckForFixes = CheckForFixes,
  ApplyGameFix = ApplyGameFix,
  GetApplyFixStatus = GetApplyFixStatus,
  CancelApplyFix = CancelApplyFix,
  UnFixGame = UnFixGame,
  GetUnfixStatus = GetUnfixStatus,
  GetInstalledFixes = GetInstalledFixes,
  GetInstalledLuaScripts = GetInstalledLuaScripts,
  GetGameInstallPath = GetGameInstallPath,
  OpenGameFolder = OpenGameFolder,
  OpenExternalUrl = OpenExternalUrl,
  GetSettingsConfig = GetSettingsConfig,
  ApplySettingsChanges = ApplySettingsChanges,
  GetAvailableLocales = GetAvailableLocales,
  GetTranslations = GetTranslations,
  GetThemes = GetThemes,
  GetAvailableThemes = GetAvailableThemes,
  GetMorrenusStats = GetMorrenusStats,
}
