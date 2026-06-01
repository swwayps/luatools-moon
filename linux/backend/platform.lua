-- platform.lua (Linux)
--
-- Concrete implementation of the platform abstraction consumed by
-- shared/backend/main.lua. Every function here corresponds to one
-- ADAPT-LINUX: site in main.lua. The Windows upstream inlined Win32
-- FFI calls (Kernel32, Shell32, Advapi32) and shelled out to
-- powershell.exe / wscript.exe / cmd.exe; this file replaces those
-- with native Linux equivalents.
--
-- Loading order: main.lua does `require("platform")` early. Millennium
-- adds `<plugin>/backend/` to package.path before invoking on_load,
-- so this file resolves as `platform`. If require fails (e.g. plugin
-- shipped without the linux overlay), main.lua falls back to a
-- minimal pure-Lua shim that handles only the path-separator case;
-- workers and Steam control are left disabled in that mode.

local M = {}

-- Path separator. Hardcoded for Linux. shared/main.lua reads
-- platform.sep (or platform.join) instead of literal "\\" or "/".
M.sep = "/"

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function shell_quote(value)
  -- Single-quote wrap with embedded single-quote escape; safe for
  -- /bin/sh argument passing.
  local s = tostring(value or "")
  return "'" .. s:gsub("'", [['"'"']]) .. "'"
end

-- ADAPT-LINUX: Steam exports LD_LIBRARY_PATH that points at
-- pinned_libs_64/ inside the Steam Runtime, which holds older copies
-- of libcurl, libssl, etc. When we shell out to /usr/bin/curl (built
-- against newer libs), the loader follows LD_LIBRARY_PATH first and
-- fails with messages like
--   `version 'CURL_OPENSSL_4' not found (required by curl)`
-- Same hazard applies to unzip, find, sed, etc. Solution: strip the
-- env vars that Valve injects before invoking userland binaries, so
-- the loader uses the system libraries those binaries were built
-- against.
local STEAM_RUNTIME_ENV_RESET =
  "unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; "

local function exec_silent(cmd)
  -- Run a command, swallow stdout/stderr, return exit code.
  local full = STEAM_RUNTIME_ENV_RESET .. cmd .. " >/dev/null 2>&1"
  local ok, _, code = os.execute(full)
  if type(ok) == "number" then return ok end
  return ok and 0 or (code or 1)
end

local function popen_lines(cmd)
  local out = {}
  local p = io.popen(STEAM_RUNTIME_ENV_RESET .. cmd, "r")
  if not p then return out end
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

local function popen_string(cmd)
  local p = io.popen(STEAM_RUNTIME_ENV_RESET .. cmd, "r")
  if not p then return "" end
  local s = p:read("*a") or ""
  p:close()
  return s
end

----------------------------------------------------------------------
-- Path helpers
----------------------------------------------------------------------

function M.normalize(path)
  -- Convert any "\\" residue in legacy strings to "/". Idempotent.
  return tostring(path or ""):gsub("\\", "/")
end

function M.join(...)
  local parts = { ... }
  local out = {}
  for _, p in ipairs(parts) do
    if p ~= nil and p ~= "" then
      out[#out + 1] = M.normalize(p):gsub("/+$", "")
    end
  end
  return table.concat(out, M.sep)
end

----------------------------------------------------------------------
-- File system
----------------------------------------------------------------------

function M.ensure_dir(path)
  path = M.normalize(path)
  if path == "" then return end
  exec_silent("mkdir -p " .. shell_quote(path))
end

function M.rmtree(path)
  path = M.normalize(path)
  if path == "" or path == "/" then return end
  exec_silent("rm -rf -- " .. shell_quote(path))
end

function M.list_files_recursive(path)
  path = M.normalize(path)
  if path == "" then return {} end
  return popen_lines("find " .. shell_quote(path) .. " -type f 2>/dev/null")
end

function M.unzip(zip_path, dest_dir)
  zip_path = M.normalize(zip_path)
  dest_dir = M.normalize(dest_dir)
  if zip_path == "" or dest_dir == "" then return false, "missing path" end
  M.rmtree(dest_dir)
  M.ensure_dir(dest_dir)
  local code = exec_silent("unzip -o -q " .. shell_quote(zip_path) ..
    " -d " .. shell_quote(dest_dir))
  if code ~= 0 then return false, "unzip exit " .. tostring(code) end
  return true, nil
end

----------------------------------------------------------------------
-- Time
----------------------------------------------------------------------

local has_ffi, ffi = pcall(require, "ffi")
local nanosleep_ready = false

function M.sleep_ms(ms)
  ms = tonumber(ms) or 0
  if ms <= 0 then return end
  if has_ffi and ffi then
    if not nanosleep_ready then
      pcall(function()
        ffi.cdef[[
          struct timespec_lt { long tv_sec; long tv_nsec; };
          int nanosleep(const struct timespec_lt* req, struct timespec_lt* rem);
        ]]
      end)
      nanosleep_ready = true
    end
    local req = ffi.new("struct timespec_lt")
    req.tv_sec = math.floor(ms / 1000)
    req.tv_nsec = (ms % 1000) * 1000000
    local ok = pcall(function() ffi.C.nanosleep(req, nil) end)
    if ok then return end
  end
  -- Fallback: shell out. Avoid busy-wait — Steam injection context is
  -- shared with other Lua coroutines.
  exec_silent("sleep " .. tostring(ms / 1000))
end

----------------------------------------------------------------------
-- Workers (async + sync)
----------------------------------------------------------------------
--
-- Worker convention on Linux: bash scripts under
-- <plugin>/backend/platform/workers/<name>.sh. Args are passed as
-- repeated --key value pairs in the same shape main.lua already uses
-- for the powershell variants. The script is responsible for daemon-
-- izing itself (via setsid/disown) so spawn_worker_async returns
-- immediately.

local function worker_path(plugin_root, name)
  return M.join(plugin_root, "backend", "platform", "workers", name .. ".sh")
end

local function format_args(args)
  -- args: array of {"--key", "value"} or flat alternating list.
  -- We accept the flat form main.lua already builds.
  local parts = {}
  for _, v in ipairs(args or {}) do
    parts[#parts + 1] = shell_quote(tostring(v or ""))
  end
  return table.concat(parts, " ")
end

function M.spawn_worker_async(plugin_root, worker_name, args)
  local script = worker_path(plugin_root, worker_name)
  -- ADAPT-LINUX: prefix with the env reset so the worker's curl/unzip/
  -- find calls don't load the Steam Runtime's pinned libs.
  local cmd = STEAM_RUNTIME_ENV_RESET ..
    "setsid /bin/bash " .. shell_quote(script) .. " " ..
    format_args(args) .. " </dev/null >/dev/null 2>&1 &"
  os.execute(cmd)
  return true
end

function M.spawn_worker_sync(plugin_root, worker_name, args, output_path, timeout_s)
  -- Run worker in foreground, capture exit, return whatever the
  -- worker wrote to output_path (mirrors steam_scan_helper.ps1
  -- semantics — main.lua then polls the file). Env reset is applied
  -- by exec_silent.
  local script = worker_path(plugin_root, worker_name)
  local cmd = "/bin/bash " .. shell_quote(script) .. " " .. format_args(args)
  if timeout_s and timeout_s > 0 then
    cmd = "timeout " .. tostring(timeout_s) .. " " .. cmd
  end
  exec_silent(cmd)
  -- Caller reads output_path itself; we just block until the worker
  -- exits or timeout fires.
  return true
end

----------------------------------------------------------------------
-- Steam control
----------------------------------------------------------------------

function M.restart_steam()
  -- ADAPT-LINUX: upstream shells out to backend\restart_steam.cmd
  -- which calls taskkill / start steam.exe. Linux equivalent is the
  -- restart_steam.sh worker shipped alongside.
  local plugin_root = M._plugin_root or ""
  if plugin_root ~= "" then
    M.spawn_worker_async(plugin_root, "restart_steam", {})
  else
    -- Last-resort fallback if main.lua hasn't called set_plugin_root.
    exec_silent("pkill -TERM -x steam; sleep 1; nohup steam >/dev/null 2>&1 &")
  end
end

function M.set_plugin_root(root)
  M._plugin_root = M.normalize(root)
end

----------------------------------------------------------------------
-- Open paths / URLs
----------------------------------------------------------------------

function M.open_path(path)
  path = M.normalize(path)
  if path == "" then return false end
  exec_silent("xdg-open " .. shell_quote(path))
  return true
end

function M.open_url(url)
  url = trim(url)
  if not url:match("^https?://") then return false end
  exec_silent("xdg-open " .. shell_quote(url))
  return true
end

----------------------------------------------------------------------
-- Locale
----------------------------------------------------------------------

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

function M.detect_steam_locale()
  -- ADAPT-LINUX: upstream reads HKCU\Software\Valve\Steam\Language
  -- via Advapi32!RegGetValueA. On Linux the equivalent lives in
  -- ~/.steam/registry.vdf as a plain VDF file.
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  local candidates = {
    home .. "/.steam/registry.vdf",
    home .. "/.local/share/Steam/registry.vdf",
  }
  for _, path in ipairs(candidates) do
    local f = io.open(path, "rb")
    if f then
      local data = f:read("*a") or ""
      f:close()
      -- Match: "Language"   "english"
      local lang = data:match('"Language"%s*"([^"]+)"')
      if lang then
        return STEAM_LANG_TO_LOCALE[lang:lower()]
      end
    end
  end
  return nil
end

----------------------------------------------------------------------
-- Watcher poke (Steam config rescan trigger)
----------------------------------------------------------------------

function M.poke_watchers(steam_root, appid)
  -- ADAPT-LINUX: upstream uses powershell to update LastWriteTime and
  -- write a probe file. Linux equivalent is `touch` plus a probe
  -- file. Steam on Linux uses inotify on these paths so the same
  -- nudge effect applies.
  if not steam_root or steam_root == "" then return end
  local paths = {
    M.join(steam_root, "config", "stplug-in"),
    M.join(steam_root, "depotcache"),
    M.join(steam_root, "config"),
    M.join(steam_root, "config", "stplug-in", tostring(appid or "") .. ".lua"),
  }
  for _, p in ipairs(paths) do
    exec_silent("touch -- " .. shell_quote(p))
  end
  -- Probe file in each directory.
  for i = 1, 3 do
    local dir = paths[i]
    local probe = M.join(dir, ".luatools_rescan_probe_" .. tostring(appid or "") .. ".tmp")
    exec_silent("touch -- " .. shell_quote(probe) ..
      " && rm -f -- " .. shell_quote(probe))
  end
end

----------------------------------------------------------------------
-- Process control helpers used by main.lua's run_hidden fallback
----------------------------------------------------------------------

function M.run_silent(exe, args)
  -- ADAPT-LINUX: upstream's run_hidden routes to ShellExecuteA with
  -- SW_HIDE. On Linux there's no "hidden window" concept — just exec.
  local cmd = shell_quote(tostring(exe or "")) .. " " .. tostring(args or "")
  exec_silent(cmd .. " &")
  return true
end

----------------------------------------------------------------------
-- SLSsteam config integration
----------------------------------------------------------------------
--
-- Append a new appid to the AdditionalApps: list in the SLSsteam
-- config (~/.config/SLSsteam/config.yaml) so the user no longer has
-- to edit the YAML by hand after "Add via LuaTools" succeeds.
--
-- Behaviour:
--   * Locates ~/.config/SLSsteam/config.yaml (only path SLSsteam
--     uses on Linux).
--   * Idempotent: scans the existing AdditionalApps: block. If the
--     appid is already there (with or without inline comment) the
--     function reports already-present and writes nothing.
--   * Preserves the rest of the file byte-for-byte. The YAML parser
--     in SLSsteam (yaml-cpp) is whitespace tolerant, but humans are
--     not — keeping comments and ordering matters.
--   * Writes through a temp file + rename so SLSsteam's inotify
--     watch fires once on a complete file rather than on partial
--     writes.
--
-- Returns: true, "added" | true, "already_present" | false, error.
local function find_slsteam_config()
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  local p = home .. "/.config/SLSsteam/config.yaml"
  local f = io.open(p, "rb")
  if not f then return nil end
  f:close()
  return p
end

local function read_lines(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a") or ""
  f:close()
  local lines, has_trailing_nl = {}, false
  if #data > 0 and data:sub(-1) == "\n" then has_trailing_nl = true end
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if has_trailing_nl then lines[#lines] = nil end
  return lines, has_trailing_nl
end

local function write_lines_atomic(path, lines, has_trailing_nl)
  local tmp = path .. ".tmp.luatools"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err or "open failed" end
  for i, line in ipairs(lines) do
    f:write(line)
    if i < #lines or has_trailing_nl then f:write("\n") end
  end
  f:close()
  -- os.rename is POSIX rename(2): atomic on the same filesystem,
  -- which is the case when both paths sit under $HOME.
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr or "rename failed"
  end
  return true
end

function M.append_additional_app(appid, comment)
  appid = tonumber(appid)
  if not appid then return false, "invalid appid" end

  local path = find_slsteam_config()
  if not path then return false, "SLSsteam config.yaml not found" end

  local lines, has_trailing_nl = read_lines(path)
  if not lines then return false, "config read failed" end

  -- Locate the AdditionalApps: header. yaml-cpp accepts either
  -- inline-list ("AdditionalApps: [1, 2]") or block-list with
  -- subsequent "  - <appid>" entries. We only handle the block form
  -- because that's the layout SLSsteam ships and what users edit by
  -- hand. Inline syntax is converted to block before we touch it.
  local header_idx = nil
  for i, line in ipairs(lines) do
    if line:match("^AdditionalApps%s*:") then
      header_idx = i
      break
    end
  end
  if not header_idx then
    return false, "AdditionalApps: key not found in config.yaml"
  end

  -- If the header has an inline value (something other than empty or
  -- a comment after the colon), refuse — rewriting inline lists is
  -- a different problem and rare enough that we'd rather flag it.
  local after_colon = lines[header_idx]:match("^AdditionalApps%s*:%s*(.-)%s*$") or ""
  -- Strip comment portion.
  local code_only = after_colon:gsub("#.*$", ""):gsub("%s+$", "")
  if code_only ~= "" then
    return false, "AdditionalApps: has an inline value, refusing to rewrite"
  end

  -- Walk forward over block-list entries and collect existing ids.
  -- A block-list entry under the header is a line that starts with
  -- whitespace and a "- " marker. Any other non-empty / non-comment
  -- line ends the block.
  local last_entry_idx = header_idx
  local existing = {}
  local indent = "  "
  for i = header_idx + 1, #lines do
    local line = lines[i]
    local stripped = line:gsub("^%s+", "")
    if stripped == "" or stripped:match("^#") then
      -- comments and blanks belong to whoever owns the section that
      -- follows; only update last_entry_idx for entries proper.
    else
      local entry_indent, rest = line:match("^(%s+)%-%s+(.*)$")
      if not entry_indent then
        break  -- next top-level key reached
      end
      indent = entry_indent
      last_entry_idx = i
      local id_str = rest:gsub("#.*$", ""):gsub("%s+$", "")
      local id_num = tonumber(id_str)
      if id_num then
        existing[id_num] = true
      end
    end
  end

  if existing[appid] then
    return true, "already_present"
  end

  local entry = indent .. "- " .. tostring(appid)
  if comment and comment ~= "" then
    -- Sanitise: collapse whitespace, strip control characters, cap
    -- length so a long game title doesn't push the file out of
    -- shape. Comments are advisory only — SLSsteam ignores them.
    local clean = tostring(comment):gsub("[%c]", " "):gsub("%s+", " ")
    clean = clean:sub(1, 80):gsub("^%s+", ""):gsub("%s+$", "")
    if #clean > 0 then entry = entry .. "   # " .. clean end
  end

  -- Insert immediately after the last entry (or the header itself if
  -- the block is empty). table.insert at position N+1 appends after N.
  table.insert(lines, last_entry_idx + 1, entry)

  local ok, err = write_lines_atomic(path, lines, has_trailing_nl)
  if not ok then return false, err end
  return true, "added"
end

return M
