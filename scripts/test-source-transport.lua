#!/usr/bin/env luajit
-- Transport rules for game-data and fix sources.
--
-- What a source may be is a validation question, not a TLS question: whether a
-- given mirror serves TLS is its operator's deployment choice, and one shipped
-- built-in is reachable only by bare IP (which cannot hold a certificate). So
-- plaintext is accepted; what is refused is a "source" that is not a download at
-- all — file:///etc/passwd was a usable value before — or one that hides its real
-- authority behind userinfo, or that has no <appid> placeholder.
--
-- The online-fix mirror is a separate case: it does serve TLS (verified), and its
-- archive is unpacked over the game's own directory, so it uses https.
--
-- Run from the repo root:  luajit scripts/test-source-transport.lua
package.path = "plugin/backend/?.lua;" .. package.path

local failures, checks = 0, 0
local function check(name, cond)
  checks = checks + 1
  if cond then io.write("ok   " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); failures = failures + 1 end
end

-- ── the online-fix mirror serves https, so nothing reaches it over http ──────
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

-- ── a source URL must be a download URL ─────────────────────────────────────
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

  check("T4 an https source is accepted",
    api_manifest.validate_source_url("https://mirror.example/<appid>.zip") ~= nil)
  -- Plaintext is a deployment choice, not a rejection reason.
  check("T5 a plaintext source is accepted",
    api_manifest.validate_source_url("http://167.235.229.108/<appid>") ~= nil)
  check("T6 a file:// source is refused",
    api_manifest.validate_source_url("file:///etc/passwd") == nil)
  check("T7 an ftp:// source is refused",
    api_manifest.validate_source_url("ftp://mirror.example/<appid>") == nil)
  check("T8 a source without the appid placeholder is refused",
    api_manifest.validate_source_url("https://mirror.example/all.zip") == nil)
  check("T9 a CRLF-carrying source is refused",
    api_manifest.validate_source_url("https://mirror.example/<appid>\r\nX: y") == nil)
  check("T10 a userinfo-disguised source is refused",
    api_manifest.validate_source_url("https://mirror.example@evil.example/<appid>") == nil)
  check("T11 an empty source is refused",
    api_manifest.validate_source_url("") == nil)

  -- No source is dropped from the list for its scheme.
  check("T12 the source list applies no transport filter",
    api_manifest.source_transport_ok == nil)
end

-- ── the download worker refuses a scheme that is not a download ─────────────
do
  local f = assert(io.open("plugin/backend/scripts/smart_download.sh", "r"))
  local source = f:read("*a")
  f:close()
  check("T13 the worker pins the request protocol per candidate",
    source:find("--proto \"${C_PROTO[i]}\"", 1, true) ~= nil)
  check("T14 the worker pins the redirect protocol too",
    source:find("--proto-redir", 1, true) ~= nil)
  check("T15 an https candidate cannot be downgraded to http",
    source:find('https://*) C_PROTO[n]="=https" ;;', 1, true) ~= nil)
  check("T16 an unsupported scheme drops the candidate",
    source:find("unsupported address type", 1, true) ~= nil)
end

-- ── the key-donation module is gone ─────────────────────────────────────────
do
  local probe = io.open("plugin/backend/donate_keys.lua", "r")
  if probe then probe:close() end
  check("T17 the plaintext key-donation module is removed", probe == nil)
  local f = assert(io.open("plugin/backend/settings/options.lua", "r"))
  local source = f:read("*a")
  f:close()
  check("T18 no settings option advertises key donation",
    source:lower():find("donatekeys", 1, true) == nil)
end

io.write(("\n%d check(s), %d failure(s)\n"):format(checks, failures))
if failures > 0 then os.exit(1) end
