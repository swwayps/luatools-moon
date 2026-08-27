#!/usr/bin/env luajit
-- Transport rules for game-data and fix sources.
--
-- A source's payload becomes the game's Lua script and depot manifests, and a
-- fix archive is unpacked over the game's own directory. Over plaintext http an
-- observer on the path chooses that content, and every AppID the user installs
-- is visible in the clear — which also defeats the project's own anonymity
-- requirement. So: https for everything that can be https, and a source that
-- genuinely has no TLS must say so in the catalogue rather than be accepted
-- silently.
--
-- Run from the repo root:  luajit scripts/test-source-transport.lua
package.path = "plugin/backend/?.lua;" .. package.path

local failures, checks = 0, 0
local function check(name, cond)
  checks = checks + 1
  if cond then io.write("ok   " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); failures = failures + 1 end
end

-- ── the online-fix mirror serves https, so nothing should reach it over http ──
do
  package.loaded.http_client = { get = function() return nil end }
  package.loaded.plugin_logger = { log = function() end, warn = function() end }
  package.loaded.plugin_utils = { decode_json = function() return {} end }
  local onlinefix = dofile("plugin/backend/onlinefix.lua")
  check("T1 the online-fix index is fetched over https",
    tostring(onlinefix.INDEX_URL):sub(1, 8) == "https://")
  check("T2 the online-fix index still points at the same mirror",
    tostring(onlinefix.INDEX_URL):find("api.perondepot.xyz", 1, true) ~= nil)
end

do
  local f = assert(io.open("plugin/backend/main.lua", "r"))
  local source = f:read("*a")
  f:close()
  check("T3 no plaintext online-fix artefact URL is built in main.lua",
    source:find('http://api.perondepot.xyz', 1, true) == nil)
end

-- ── the catalogue must declare a plaintext source ────────────────────────────
do
  local f = assert(io.open("plugin/backend/api.defaults.json", "r"))
  local raw = f:read("*a")
  f:close()
  -- Every built-in whose URL is http:// has to carry the "insecure" marker, and
  -- every https one must not.
  for entry in raw:gmatch("{[^{}]*}") do
    local url = entry:match('"url"%s*:%s*"([^"]*)"')
    if url and url ~= "" then
      local id = entry:match('"builtin_id"%s*:%s*"([^"]*)"') or "?"
      local marked = entry:match('"insecure"%s*:%s*true') ~= nil
      if url:sub(1, 7) == "http://" then
        check("T4 plaintext built-in '" .. id .. "' is marked insecure", marked)
      else
        check("T5 https built-in '" .. id .. "' is not marked insecure", not marked)
      end
    end
  end
end

-- ── api_manifest refuses an unmarked plaintext source ────────────────────────
do
  package.loaded.config = {
    API_DEFAULTS_FILE = "api.defaults.json", API_JSON_FILE = "api.json",
  }
  package.loaded.http_client = {}
  package.loaded.plugin_logger = { log = function() end, warn = function() end }
  package.loaded.plugin_utils = {}
  package.loaded.paths = {
    backend_path = function(n) return "/plugin/backend/" .. tostring(n) end,
  }
  package.loaded.fs = {
    join = function(...) return table.concat({ ... }, "/") end,
    exists = function() return false end,
    parent_path = function(x) return (x:match("^(.*)/[^/]+$")) or "/" end,
    create_directories = function() return true end,
  }
  local api_manifest = dofile("plugin/backend/api_manifest.lua")

  check("T6 an https source is usable",
    api_manifest.source_transport_ok(
      { url = "https://mirror.example/<appid>.zip" }) == true)
  check("T7 an unmarked plaintext source is refused",
    api_manifest.source_transport_ok(
      { url = "http://mirror.example/<appid>.zip" }) == false)
  check("T8 a plaintext source that declares itself is allowed through",
    api_manifest.source_transport_ok(
      { url = "http://mirror.example/<appid>.zip", insecure = true }) == true)
  check("T9 the marker cannot smuggle a non-web scheme",
    api_manifest.source_transport_ok(
      { url = "file:///etc/passwd", insecure = true }) == false)
  check("T10 a managed source with no URL is unaffected",
    api_manifest.source_transport_ok({ managed = true }) == true)

  -- The marker is a property of the built-in catalogue, not something a caller
  -- can set: add_custom_api must still refuse plaintext even with it present.
  local catalog = { api_list = {} }
  local deps = { catalog = function() return catalog end, save = function() return true end }
  local added = api_manifest.add_custom_api(
    { name = "X", url = "http://mirror.example/<appid>", insecure = true }, deps)
  check("T11 a custom source cannot opt itself out of TLS", added.success == false)
end

-- ── the plaintext discovery probe is explicit, not accidental ────────────────
do
  local f = assert(io.open("plugin/backend/lua_tools_manifest.lua", "r"))
  local source = f:read("*a")
  f:close()
  check("T12 the plaintext discovery probe opts in explicitly",
    source:find("allow_http = true", 1, true) ~= nil)
  check("T13 the plaintext discovery probe is documented as such",
    source:find("no TLS", 1, true) ~= nil)
end

-- ── the key-donation module is gone ─────────────────────────────────────────
do
  local probe = io.open("plugin/backend/donate_keys.lua", "r")
  if probe then probe:close() end
  check("T14 the plaintext key-donation module is removed", probe == nil)
  local f = assert(io.open("plugin/backend/settings/options.lua", "r"))
  local source = f:read("*a")
  f:close()
  check("T15 no settings option advertises key donation",
    source:lower():find("donatekeys", 1, true) == nil)
end

io.write(("\n%d check(s), %d failure(s)\n"):format(checks, failures))
if failures > 0 then os.exit(1) end
