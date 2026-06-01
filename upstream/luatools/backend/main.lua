local millennium = require("millennium")

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

local function load_apis()
  local path = plugin_root() .. "/backend/api.json"
  local text = read_file(path)
  local data = decode_json(text)
  local apis = {}
  if data and type(data.api_list) == "table" then
    for _, api in ipairs(data.api_list) do
      if type(api) == "table" and api.enabled ~= false then
        apis[#apis + 1] = {
          name = tostring(api.name or "Unknown"),
          url = tostring(api.url or ""),
          success_code = tonumber(api.success_code or 200) or 200,
        }
      end
    end
  end
  if #apis == 0 then
    for object in text:gmatch("{(.-)}") do
      local name = object:match('"name"%s*:%s*"([^"]+)"')
      local url = object:match('"url"%s*:%s*"([^"]+)"')
      local code = tonumber(object:match('"success_code"%s*:%s*(%d+)') or "200") or 200
      local enabled = object:match('"enabled"%s*:%s*false')
      if name and url and not enabled then
        apis[#apis + 1] = { name = name, url = url, success_code = code }
      end
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

  ensure_dir(plugin_root() .. "\\backend\\temp_dl")
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

local create_directory_ready = false
local kernel32 = nil

local function ensure_dir(path)
  path = tostring(path or ""):gsub("/", "\\")
  if path == "" then return end

  local ok, ffi = pcall(require, "ffi")
  if ok and ffi then
    if not create_directory_ready then
      pcall(function()
        ffi.cdef[[int CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);]]
      end)
      create_directory_ready = true
    end
    if not kernel32 then
      pcall(function() kernel32 = ffi.load("Kernel32") end)
    end
    local lib = kernel32 or ffi.C
    local current = ""
    for part in path:gmatch("[^\\]+") do
      if current == "" then
        current = part
      else
        current = current .. "\\" .. part
      end
      if current:match("^%a:$") then
        current = current .. "\\"
      else
        pcall(function() lib.CreateDirectoryA(current, nil) end)
      end
    end
    return
  end

  local vbs = plugin_root():gsub("/", "\\") .. "\\backend\\mkdir_hidden.vbs"
  os.execute('wscript.exe //B "' .. vbs:gsub('"', '\\"') .. '" "' .. path:gsub('"', '\\"') .. '" >nul 2>nul')
end

local function poke_steam_config_watchers(appid)
  local base = steam_path()
  if base == "" then return end
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local script = table.concat({
    "$ErrorActionPreference='SilentlyContinue';",
    "$steam=" .. string.format("%q", base:gsub("\\", "\\\\")) .. ";",
    "$appid=" .. string.format("%q", tostring(appid or "")) .. ";",
    "$paths=@(",
    "(Join-Path $steam 'config\\stplug-in'),",
    "(Join-Path $steam 'depotcache'),",
    "(Join-Path $steam 'config'),",
    "(Join-Path $steam ('config\\stplug-in\\' + $appid + '.lua'))",
    ");",
    "$now=Get-Date;",
    "foreach($p in $paths){if(Test-Path -LiteralPath $p){(Get-Item -LiteralPath $p -Force).LastWriteTime=$now}}",
    "foreach($d in $paths[0..2]){if(Test-Path -LiteralPath $d){$probe=Join-Path $d ('.luatools_rescan_probe_' + $appid + '.tmp'); Set-Content -LiteralPath $probe -Value " .. string.format("%q", now) .. " -Encoding ASCII; Remove-Item -LiteralPath $probe -Force}}"
  }, " ")
  local quoted_script = '"' .. tostring(script):gsub('"', '\\"') .. '"'
  os.execute('powershell.exe -WindowStyle Hidden -NoProfile -Command ' .. quoted_script .. ' >nul 2>nul')
  log_line("Poked Steam config watchers for " .. tostring(appid))
end

local function list_files_recursive(path)
  local files = {}
  local cmd = 'powershell.exe -WindowStyle Hidden -NoProfile -Command "Get-ChildItem -LiteralPath ' .. "'" .. tostring(path):gsub("'", "''") .. "'" .. ' -Recurse -File | ForEach-Object { $_.FullName }"'
  local p = io.popen(cmd)
  if p then
    for line in p:lines() do files[#files + 1] = line end
    p:close()
  end
  return files
end

local function filename(path)
  return (tostring(path):gsub("/", "\\"):match("([^\\]+)$") or tostring(path))
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

local shell_execute_ready = false
local shell32 = nil

local function run_hidden(exe, args)
  local ok, ffi = pcall(require, "ffi")
  if ok and ffi then
    if not shell_execute_ready then
      pcall(function()
        ffi.cdef[[
          void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);
        ]]
      end)
      shell_execute_ready = true
    end
    if not shell32 then
      pcall(function() shell32 = ffi.load("Shell32") end)
    end
    if shell_execute_ready then
      local call_ok = pcall(function()
        local lib = shell32 or ffi.C
        lib.ShellExecuteA(nil, "open", tostring(exe or ""), tostring(args or ""), nil, 0)
      end)
      if call_ok then return true end
    end
  end
  local root = plugin_root():gsub("/", "\\")
  local temp = root .. "\\backend\\temp_dl"
  ensure_dir(temp)
  local command_file = temp .. "\\hidden_command_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
  write_file(command_file, '"' .. tostring(exe or "") .. '" ' .. tostring(args or ""))
  local vbs = root .. "\\backend\\run_hidden.vbs"
  os.execute('wscript.exe //B "' .. vbs:gsub('"', '\\"') .. '" /file "' .. command_file:gsub('"', '\\"') .. '" >nul 2>nul')
  return false
end

local sleep_ready = false

local function sleep_ms(ms)
  local ok, ffi = pcall(require, "ffi")
  if ok and ffi then
    if not sleep_ready then
      pcall(function()
        ffi.cdef[[void Sleep(unsigned long dwMilliseconds);]]
      end)
      sleep_ready = true
    end
    local slept = pcall(function() ffi.C.Sleep(tonumber(ms) or 50) end)
    if slept then return end
  end

  local until_time = os.clock() + ((tonumber(ms) or 50) / 1000)
  while os.clock() < until_time do end
end

local function write_state_file(appid, json)
  ensure_dir(plugin_root() .. "\\backend\\temp_dl")
  write_file(state_path(appid), json)
end

local function launch_download_worker(appid, url, api_name)
  local root = plugin_root():gsub("/", "\\")
  local script = root .. "\\backend\\download_worker.ps1"
  local args = table.concat({
    '-WindowStyle Hidden',
    '-NoProfile',
    '-ExecutionPolicy Bypass',
    '-File ' .. ps_quote(script),
    '-AppId ' .. ps_quote(appid),
    '-Url ' .. ps_quote(url),
    '-ApiName ' .. ps_quote(api_name),
    '-PluginRoot ' .. ps_quote(root),
    '-SteamPath ' .. ps_quote(steam_path()),
  }, " ")
  log_line("Launching download worker for " .. tostring(appid) .. " via " .. tostring(api_name))
  run_hidden("powershell.exe", args)
end

local function run_scan_helper(action, appid)
  local root = plugin_root():gsub("/", "\\")
  local script = root .. "\\backend\\steam_scan_helper.ps1"
  local temp = root .. "\\backend\\temp_dl"
  ensure_dir(temp)
  local output_path = temp .. "\\scan_" .. tostring(action or "helper") .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".json"
  local args = table.concat({
    '-WindowStyle Hidden',
    '-NoProfile',
    '-ExecutionPolicy Bypass',
    '-File ' .. ps_quote(script),
    '-Action ' .. ps_quote(action),
    '-PluginRoot ' .. ps_quote(root),
    '-SteamPath ' .. ps_quote(steam_path()),
    '-AppId ' .. ps_quote(appid or ""),
    '-OutputPath ' .. ps_quote(output_path),
  }, " ")

  run_hidden("powershell.exe", args)

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
  local root = plugin_root():gsub("/", "\\")
  local script = root .. "\\backend\\fix_worker.ps1"
  local args = table.concat({
    '-WindowStyle Hidden',
    '-NoProfile',
    '-ExecutionPolicy Bypass',
    '-File ' .. ps_quote(script),
    '-Mode ' .. ps_quote(mode),
    '-AppId ' .. ps_quote(appid),
    '-PluginRoot ' .. ps_quote(root),
    '-DownloadUrl ' .. ps_quote(download_url or ""),
    '-InstallPath ' .. ps_quote(install_path or ""),
    '-FixType ' .. ps_quote(fix_type or ""),
    '-GameName ' .. ps_quote(game_name or ""),
    '-FixDate ' .. ps_quote(fix_date or ""),
  }, " ")
  log_line("Launching fix worker mode=" .. tostring(mode) .. " appid=" .. tostring(appid))
  run_hidden("powershell.exe", args)
end

local function cleanup_temp_download_artifacts()
  local root = plugin_root():gsub("/", "\\")
  local temp = root .. "\\backend\\temp_dl"
  ensure_dir(temp)
  local script = table.concat({
    "$ErrorActionPreference='SilentlyContinue';",
    "$temp=" .. ps_quote(temp) .. ";",
    "if(Test-Path -LiteralPath $temp){",
    "Get-ChildItem -LiteralPath $temp -Directory -Filter 'extract_*' | Remove-Item -Recurse -Force;",
    "Get-ChildItem -LiteralPath $temp -File -Filter '*.zip' | Remove-Item -Force;",
    "Get-ChildItem -LiteralPath $temp -File -Filter 'scan_*.json' | Remove-Item -Force;",
    "}",
  }, " ")
  run_hidden("powershell.exe", "-WindowStyle Hidden -NoProfile -Command " .. ps_quote(script))
end

local function install_lua_zip(appid, zip_path)
  local base = steam_path()
  local temp = plugin_root() .. "\\backend\\temp_dl\\extract_" .. tostring(appid)
  local depotcache = base .. "\\depotcache"
  local target = base .. "\\config\\stplug-in"
  ensure_dir(plugin_root() .. "\\backend\\temp_dl")
  ensure_dir(depotcache)
  ensure_dir(target)
  os.execute('powershell.exe -WindowStyle Hidden -NoProfile -Command "Remove-Item -LiteralPath ' .. "'" .. temp:gsub("'", "''") .. "'" .. ' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Path ' .. "'" .. temp:gsub("'", "''") .. "'" .. ' -Force | Out-Null; Expand-Archive -LiteralPath ' .. "'" .. tostring(zip_path):gsub("'", "''") .. "'" .. ' -DestinationPath ' .. "'" .. temp:gsub("'", "''") .. "'" .. ' -Force"')

  local lua_file = nil
  local manifests = 0
  for _, path in ipairs(list_files_recursive(temp)) do
    local name = filename(path)
    if name:lower():match("%.manifest$") then
      copy_file(path, depotcache .. "\\" .. name)
      manifests = manifests + 1
    elseif name:lower() == tostring(appid) .. ".lua" then
      lua_file = path
    elseif not lua_file and name:lower():match("%.lua$") then
      lua_file = path
    end
  end

  if not lua_file then return false, "No lua file found in downloaded archive" end
  local dlcs = dlc_count_from_lua(lua_file, appid)
  if not copy_file(lua_file, target .. "\\" .. tostring(appid) .. ".lua") then return false, "Failed to install lua file" end
  os.remove(zip_path)
  os.execute('powershell.exe -WindowStyle Hidden -NoProfile -Command "Remove-Item -LiteralPath ' .. "'" .. temp:gsub("'", "''") .. "'" .. ' -Recurse -Force -ErrorAction SilentlyContinue"')
  log_line("Installed appid " .. tostring(appid) .. " from zip; manifests=" .. tostring(manifests) .. " dlcs=" .. tostring(dlcs))
  return true, nil, manifests, dlcs
end

local function download_and_install(appid, url, api_name)
  local dest = plugin_root() .. "\\backend\\temp_dl\\" .. tostring(appid) .. ".zip"
  ensure_dir(plugin_root() .. "\\backend\\temp_dl")
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
  local script = plugin_root() .. "\\backend\\restart_steam.cmd"
  run_hidden("cmd.exe", '/C "' .. script:gsub('"', '\\"') .. '"')
  return json_ok()
end

function HasLuaToolsForApp(args)
  local appid = appid_from_args(args)
  if not appid then return json_fail("Invalid appid") end
  local base = steam_path()
  local p1 = base .. "\\config\\stplug-in\\" .. tostring(appid) .. ".lua"
  local p2 = base .. "\\config\\stplug-in\\" .. tostring(appid) .. ".lua.disabled"
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
  if file_state then return json_ok('"state":' .. file_state) end
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
  local base = steam_path() .. "\\config\\stplug-in\\"
  local deleted = {}
  for _, suffix in ipairs({ ".lua", ".lua.disabled" }) do
    local path = base .. tostring(appid) .. suffix
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
  local path = type(args) == "table" and tostring(args.path or "") or tostring(args or "")
  if path == "" then return json_fail("Failed to open path") end
  os.execute('explorer "' .. path:gsub('"', '\\"') .. '"')
  return json_ok()
end

function OpenExternalUrl(args)
  local url = url_from_args(args)
  if not url:match("^https?://") then return json_fail("Invalid URL") end
  local safe_url = url:gsub('"', '\\"')
  local ok = run_hidden("rundll32.exe", 'url.dll,FileProtocolHandler "' .. safe_url .. '"')
  if not ok then
    os.execute('cmd.exe /C start "" "' .. safe_url .. '"')
  end
  return json_ok()
end

local LOCALE_CODES = {
  "ar", "bg", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hu",
  "id", "it", "ja", "ko", "nl", "no", "peakstupid", "pirate", "pl", "pt",
  "pt-BR", "pt-decria", "ro", "ru", "sv", "th", "tr", "uk", "vi", "zh-CN",
  "zh-TW",
}

local STEAM_LANG_TO_LOCALE = {
  arabic = "ar", brazilian = "pt-BR", bulgarian = "bg", czech = "cs",
  danish = "da", dutch = "nl", english = "en", finnish = "fi", french = "fr",
  german = "de", greek = "el", hebrew = "he", hungarian = "hu",
  indonesian = "id", italian = "it", japanese = "ja", koreana = "ko",
  latam = "es", norwegian = "no", polish = "pl", portuguese = "pt",
  romanian = "ro", russian = "ru", schinese = "zh-CN", spanish = "es",
  swedish = "sv", tchinese = "zh-TW", thai = "th", turkish = "tr",
  ukrainian = "uk", vietnamese = "vi",
}

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
  }
end

local function settings_values_json(values)
  values = values or read_settings_values()
  return '{"general":{"useSteamLanguage":' .. (values.useSteamLanguage ~= false and "true" or "false") ..
    ',"language":' .. json_string(values.language or "en") ..
    ',"donateKeys":' .. (values.donateKeys ~= false and "true" or "false") ..
    ',"theme":' .. json_string(values.theme or "original") ..
    ',"fastDownload":' .. (values.fastDownload ~= false and "true" or "false") ..
    ',"morrenusApiKey":' .. json_string(values.morrenusApiKey or "") .. "}}"
end

local function write_settings_values(values)
  ensure_dir(plugin_root() .. "\\backend\\data")
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
  return '[{"key":"general","label":"General","description":"Global LuaTools preferences.","options":[' ..
    '{"key":"useSteamLanguage","label":"Use Steam Language","type":"toggle","description":"Use the Steam client language for LuaTools.","default":true,"choices":[],"requiresRestart":false,"metadata":{"yesLabel":"Yes","noLabel":"No"}},' ..
    '{"key":"language","label":"Language","type":"select","description":"Choose the language used by LuaTools.","default":"en","choices":[' .. table.concat(locale_choices, ",") .. '],"requiresRestart":false,"metadata":{"dynamicChoices":"locales"}},' ..
    '{"key":"donateKeys","label":"Donate Keys","type":"toggle","description":"Allow LuaTools to donate spare Steam keys.","default":true,"choices":[],"requiresRestart":false,"metadata":{"yesLabel":"Yes","noLabel":"No"}},' ..
    '{"key":"theme","label":"Theme","type":"select","description":"Choose the color theme for LuaTools interface.","default":"original","choices":' .. themes_json() .. ',"requiresRestart":false,"metadata":{"dynamicChoices":"themes"}},' ..
    '{"key":"fastDownload","label":"Fast Download","type":"toggle","description":"Automatically choose the first available source when adding a game.","default":true,"choices":[],"requiresRestart":false,"metadata":{"yesLabel":"Yes","noLabel":"No"}},' ..
    '{"key":"morrenusApiKey","label":"Morrenus API Key","type":"text","description":"API Key required to use Sadie Source. Get from hubcapmanifest.com","default":"","choices":[],"requiresRestart":false,"metadata":{"placeholder":"Enter your API key..."}}' ..
    "]}]"
end

local reg_get_value_ready = false
local advapi32 = nil

local function detect_steam_locale()
  local language = ""
  local ok, ffi = pcall(require, "ffi")
  if ok and ffi then
    pcall(function()
      if not reg_get_value_ready then
        pcall(function()
          ffi.cdef[[long RegGetValueA(void* hkey, const char* lpSubKey, const char* lpValue, unsigned long dwFlags, unsigned long* pdwType, void* pvData, unsigned long* pcbData);]]
        end)
        reg_get_value_ready = true
      end
      if not advapi32 then
        pcall(function() advapi32 = ffi.load("Advapi32") end)
      end
      local hkey = ffi.cast("void*", tonumber("0x80000001"))
      local typ = ffi.new("unsigned long[1]")
      local size = ffi.new("unsigned long[1]", 512)
      local buf = ffi.new("char[512]")
      local lib = advapi32 or ffi.C
      if lib.RegGetValueA(hkey, "Software\\Valve\\Steam", "Language", 0x00000002, typ, buf, size) == 0 then
        language = ffi.string(buf):lower()
      end
    end)
  end
  return STEAM_LANG_TO_LOCALE[language]
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
  if type(args) == "table" then payload = args.changes or args.changesJson or args.general or args end
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
  local root = plugin_root()
  local dst = steam_path() .. "\\steamui\\LuaTools"
  ensure_dir(dst)
  copy_file(root .. "/public/luatools.js", dst .. "\\luatools.js")
  copy_file(root .. "/public/luatools-icon.png", dst .. "\\luatools-icon.png")
  ensure_dir(dst .. "\\themes")
  local themes_src = root .. "\\public\\themes"
  for _, path in ipairs(list_files_recursive(themes_src)) do
    local name = filename(path)
    if name:lower():match("%.css$") then copy_file(path, dst .. "\\themes\\" .. name) end
  end
end

local function on_load()
  log_line("LuaTools bootstrap loading")
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
