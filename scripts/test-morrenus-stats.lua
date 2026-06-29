-- Harness: load the REAL dist main.lua with stubs and exercise GetMorrenusStats'
-- failure classification. The Morrenus key-status box must tell a genuinely
-- rejected key (HTTP 401/403) apart from a connectivity failure (no response,
-- 5xx, ...), so the UI can show the real problem instead of always blaming the
-- key. Run from the repo root AFTER a build: lua5.4 scripts/test-morrenus-stats.lua

-- Programmable HTTP result the stubbed http_client returns.
local MOCK_RESP, MOCK_ERR = nil, nil

local function preload(name, mod) package.preload[name] = function() return mod end end

-- Minimal JSON encoder good enough for the small error tables json_ok builds
-- (flat maps of string/number/boolean). The success path returns resp.body
-- verbatim, so it never reaches this.
local function encode(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = '"' .. tostring(k) .. '":' .. encode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return '"' .. v .. '"'
  else
    return tostring(v)
  end
end

preload("json", { encode = encode, decode = function() return {} end })
preload("utils", { getenv = function(k) return os.getenv(k) end, base64_encode = function() return "" end,
                   read_file = function() return nil end, read_json = function() return {} end,
                   read_text = function() return "" end, write_json = function() end })
preload("plugin_logger", { log = function() end, warn = function() end, info = function() end, error = function() end })
preload("millennium", { steam_path = function() return "/tmp" end, version = function() return "test" end,
                        add_browser_css = function() end, add_browser_js = function() end, ready = function() end })
preload("fs", { exists = function() return false end, join = function(...) return table.concat({ ... }, "/") end,
                backend_path = function(p) return p end, parent_path = function() return "" end })
preload("http_client", { get = function() return MOCK_RESP, MOCK_ERR end })
preload("paths", { get_plugin_dir = function() return "/tmp" end, get_backend_dir = function() return "/tmp" end,
                   backend_path = function(p) return "/tmp/" .. p end, public_path = function(p) return p end })
preload("steam_utils", { detect_steam_install_path = function() return "/tmp" end })
preload("plugin_utils", { ensure_temp_download_dir = function() return "/tmp" end,
                          read_json = function() return {} end, read_text = function() return "" end,
                          get_plugin_version = function() return "0" end })
preload("locales.manager", { get_locale_manager = function() return { get_locale_strings = function() return {} end,
                             available_locales = function() return {} end } end, DEFAULT_LOCALE = "en" })
preload("api_manifest", {})
preload("downloads", {})
preload("fixes", {})
preload("settings.manager", { get_morrenus_api_key = function() return "" end, init_settings = function() end })
preload("auto_update", {})

local ok_load = pcall(dofile, "dist/luatools/backend/main.lua")
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else print("FAIL " .. msg); fails = fails + 1 end end

check(ok_load and type(GetMorrenusStats) == "function", "dist main.lua loads and exports GetMorrenusStats")

if type(GetMorrenusStats) == "function" then
  local KEY = "smm_" .. string.rep("a", 96)

  -- 1) Valid key: HTTP 200 -> body passes through unchanged.
  MOCK_RESP, MOCK_ERR = { status = 200, body = '{"username":"sway0925","daily_usage":0,"daily_limit":25}' }, nil
  local r = GetMorrenusStats({ api_key = KEY })
  check(r:find('"username"', 1, true) ~= nil, "HTTP 200 returns the stats body (valid key)")

  -- 2) Genuine rejection: HTTP 403 -> errorType "rejected" (not unreachable).
  MOCK_RESP, MOCK_ERR = { status = 403, body = "" }, nil
  r = GetMorrenusStats({ api_key = KEY })
  check(r:find("rejected", 1, true) ~= nil, "HTTP 403 is classified as a rejected key")
  check(r:find("unreachable", 1, true) == nil, "  -> 403 is NOT reported as unreachable")

  -- 3) No HTTP response at all (DNS/TLS/timeout) -> errorType "unreachable".
  MOCK_RESP, MOCK_ERR = nil, "could not resolve host"
  r = GetMorrenusStats({ api_key = KEY })
  check(r:find("unreachable", 1, true) ~= nil, "no response is classified as unreachable (network)")
  check(r:find("rejected", 1, true) == nil, "  -> a network failure is NOT reported as a rejected key")

  -- 4) Server error 503 -> unreachable, not a key problem.
  MOCK_RESP, MOCK_ERR = { status = 503, body = "" }, nil
  r = GetMorrenusStats({ api_key = KEY })
  check(r:find("unreachable", 1, true) ~= nil, "HTTP 5xx is classified as unreachable, not a bad key")
end

if fails == 0 then print("test-morrenus-stats: ALL PASS") else print("test-morrenus-stats: " .. fails .. " FAILURE(S)"); os.exit(1) end
