#!/usr/bin/env luajit
-- Smoke test for plugin/backend/slsteam.lua configuration helpers.
-- Run from the repo root:  luajit scripts/test-slsteam.lua
--
-- App discovery is driven by config/stplug-in/*.lua filenames. This module
-- must not expose an AdditionalApps registrar; it only maintains settings
-- that still live in config.yaml.

package.path = "plugin/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then
    io.write("ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. "\n")
    fails = fails + 1
  end
end

-- Sandbox HOME via os.getenv override.
local sandbox = os.tmpname() .. "_dir"
os.execute("mkdir -p '" .. sandbox .. "/.config/SLSsteam'")
local orig_getenv = os.getenv
local test_env = { HOME = sandbox }
os.getenv = function(k)
  if test_env[k] ~= nil then return test_env[k] end
  return orig_getenv(k)
end

local cfg = sandbox .. "/.config/SLSsteam/config.yaml"
local function w(s) local f = assert(io.open(cfg, "wb")); f:write(s); f:close() end
local function r() local f = assert(io.open(cfg, "rb")); local s = f:read("*a"); f:close(); return s end

local slsteam = dofile("plugin/backend/slsteam.lua")

check("A1 register_app is absent", slsteam.register_app == nil)
check("A2 unregister_app is absent", slsteam.unregister_app == nil)

local ok, msg, c

-- ---------------------------------------------------------------------------
-- FakeAppIds map editor: set_fake_appid / unset_fake_appid.
-- FakeAppIds is a MAP block ("FakeAppIds:" then "  <appid>: <fake>" lines).
-- ---------------------------------------------------------------------------

-- F1: insert into an empty FakeAppIds block (default config shape), preserving
-- the following top-level key.
w("DisableFamilyShareLock: yes\nFakeAppIds:\nIdleStatus:\n  AppId: 0\n")
ok, msg = slsteam.set_fake_appid(285900)
check("F1 added", ok == true and msg == "added")
c = r()
check("F1 mapping written", c:find("285900:%s*480") ~= nil)
check("F1 IdleStatus preserved", c:find("IdleStatus:") ~= nil)
check("F1 AppId line preserved", c:find("  AppId: 0") ~= nil)

-- F1 idempotent: same appid+value already present.
ok, msg = slsteam.set_fake_appid(285900, 480)
check("F1 idempotent", ok == true and msg == "already_present")

-- F2: update an existing mapping's value in place (no duplicate line).
ok, msg = slsteam.set_fake_appid(285900, 481)
check("F2 updated", ok == true and msg == "updated")
c = r()
check("F2 new value", c:find("285900:%s*481") ~= nil)
check("F2 old value gone", c:find("285900:%s*480") == nil)
local _, n285 = c:gsub("285900%s*:", "")
check("F2 single mapping line", n285 == 1)

-- F3: header absent -> created with the entry.
w("PlayNotOwnedGames: yes\n")
ok, msg = slsteam.set_fake_appid(620)
c = r()
check("F3 header created", c:find("FakeAppIds:") ~= nil)
check("F3 entry created", c:find("620:%s*480") ~= nil)

-- F4: inline form refused (don't risk corrupting it).
w("FakeAppIds: {1: 2}\n")
ok, msg = slsteam.set_fake_appid(9)
check("F4 inline refused", ok == false)

-- F5: preserve comments + a sibling mapping while adding another.
w("FakeAppIds:\n  730: 480   # existing\nSafeMode: no\n")
ok, msg = slsteam.set_fake_appid(440)
c = r()
check("F5 730 kept", c:find("730:%s*480") ~= nil)
check("F5 comment kept", c:find("# existing") ~= nil)
check("F5 440 added", c:find("440:%s*480") ~= nil)
check("F5 SafeMode kept", c:find("SafeMode: no") ~= nil)

-- F6: wide indent preserved on insert.
w("FakeAppIds:\n    111: 480\n")
slsteam.set_fake_appid(222)
check("F6 indent preserved", r():find("    222:%s*480") ~= nil)

-- Manifest-store purge must report shell failures instead of claiming that
-- archived manifests were removed.
local store_lua = sandbox .. "/store-test.lua"
local store_file = assert(io.open(store_lua, "wb"))
store_file:write("addappid(321)\\n")
store_file:close()
local real_execute = os.execute
os.execute = function(command)
  if command:find("rm %-f") then return nil, "exit", 1 end
  return real_execute(command)
end
ok, msg, c = slsteam.purge_store_for_lua(store_lua)
os.execute = real_execute
check("F6b manifest purge failure is reported", ok == false and type(msg) == "string")
os.remove(store_lua)

-- F7: unset removes the mapping; absent -> not_present.
w("FakeAppIds:\n  285900: 480\n  620: 480\n")
ok, msg = slsteam.unset_fake_appid(285900)
c = r()
check("F7 removed 285900", ok == true and msg == "removed" and c:find("285900") == nil)
check("F7 kept 620", c:find("620:%s*480") ~= nil)
ok, msg = slsteam.unset_fake_appid(99999)
check("F7 absent -> not_present", ok == true and msg == "not_present")

-- ---------------------------------------------------------------------------
-- ManifestPins purge: purge_pins_for_app removes one app's nested pin block.
-- ManifestPins is a nested map: "ManifestPins:" -> "  <appid>:" -> { locked:, depots: { <depot>: gid } }.
-- ---------------------------------------------------------------------------

-- P1: two pinned apps; purge one keeps the other + the header + sibling keys.
w(table.concat({
  "AdditionalApps:",
  "  - 1054490",
  "ManifestPins:",
  "  1054490:",
  "    locked: true",
  "    depots:",
  '      1054491: "111"',
  "  285900:",
  "    locked: false",
  "    depots:",
  '      285904: "222"',
  "LogLevel: 2",
  "",
}, "\n"))
ok, msg = slsteam.purge_pins_for_app(1054490)
c = r()
check("P1 removed", ok == true and msg == "removed")
check("P1 target block gone", c:find("1054490:") == nil and c:find('1054491: "111"') == nil)
check("P1 other app kept", c:find("285900:") ~= nil and c:find('285904: "222"') ~= nil)
check("P1 header kept", c:find("ManifestPins:") ~= nil)
check("P1 AdditionalApps kept", c:find("  %- 1054490") ~= nil)
check("P1 LogLevel kept", c:find("LogLevel: 2") ~= nil)

-- P2: purging the last pinned app removes the ManifestPins header too.
w(table.concat({
  "ManifestPins:",
  "  285900:",
  "    locked: false",
  "    depots:",
  '      285904: "222"',
  "LogLevel: 2",
  "",
}, "\n"))
ok, msg = slsteam.purge_pins_for_app(285900)
c = r()
check("P2 removed", ok == true and msg == "removed")
check("P2 header gone when empty", c:find("ManifestPins:") == nil)
check("P2 sibling key kept", c:find("LogLevel: 2") ~= nil)

-- P3: appid not pinned -> not_present, file unchanged.
w("ManifestPins:\n  111:\n    locked: true\n    depots:\n      112: \"9\"\n")
ok, msg = slsteam.purge_pins_for_app(999)
c = r()
check("P3 not_present", ok == true and msg == "not_present")
check("P3 unchanged", c:find("111:") ~= nil and c:find('112: "9"') ~= nil)

-- P4: no ManifestPins block at all -> not_present.
w("AdditionalApps:\n  - 1\n")
ok, msg = slsteam.purge_pins_for_app(1)
check("P4 no block -> not_present", ok == true and msg == "not_present")

-- ---------------------------------------------------------------------------
-- Per-app appinfo cleanup: explicit artifacts are quarantined, not deleted.
-- ---------------------------------------------------------------------------
local cache_dir = sandbox .. "/.config/SLSsteam/cache"
os.execute("mkdir -p '" .. cache_dir .. "'")
local forgotten_names = {
  "picsbuffer_321.bin", "picsbuffer_321.yaml", "synthetic_321",
  "ticket_321.yaml", "encryptedTicket_321.yaml",
}
for _, name in ipairs(forgotten_names) do
  local f = assert(io.open(cache_dir .. "/" .. name, "wb"))
  f:write("cache")
  f:close()
end
-- manifestid_<n> is depot-scoped, not app-scoped. Lua cleanup must leave an
-- app-id-named manifest alone; the native watcher owns relation-aware cleanup.
local app_named_manifest = assert(io.open(cache_dir .. "/manifestid_321.yaml", "wb"))
app_named_manifest:write("depot-scoped")
app_named_manifest:close()
local other = assert(io.open(cache_dir .. "/picsbuffer_322.bin", "wb"))
other:write("other")
other:close()

-- The native cache helper uses an atomic no-replace move; keep a source-level
-- assertion here because a two-step hard-link/unlink can delete a cache that
-- a native writer publishes between those syscalls.
local helper_source_file = assert(io.open("plugin/backend/slsteam.lua", "rb"))
local helper_source = helper_source_file:read("*a") or ""
helper_source_file:close()
check("C0 Lua quarantine uses atomic no-replace move",
  helper_source:find("mv %-n") ~= nil)

ok, c = slsteam.forget_app(321)
check("C1 cleanup succeeds", ok == true and c == #forgotten_names)
for _, name in ipairs(forgotten_names) do
  check("C1 original moved " .. name,
    io.open(cache_dir .. "/" .. name, "rb") == nil)
  local moved = false
  local pipe = io.popen("find '" .. cache_dir .. "' -maxdepth 1 -type f -name '" .. name .. ".forgotten.*' -print -quit")
  if pipe then
    moved = (pipe:read("*l") or "") ~= ""
    pipe:close()
  end
  check("C1 quarantine exists " .. name, moved)
end
check("C1 other app remains",
  io.open(cache_dir .. "/picsbuffer_322.bin", "rb") ~= nil)
check("C1 app-id-named manifest remains depot-scoped",
  io.open(cache_dir .. "/manifestid_321.yaml", "rb") ~= nil)

-- A deterministic same-operation destination collision must preserve the old
-- quarantine and move the live artifact to a suffixed retry path.
local original_time = os.time
os.time = function() return 12345 end
local collision_original = assert(io.open(cache_dir .. "/picsbuffer_323.bin", "wb"))
collision_original:write("live")
collision_original:close()
local collision_target_path =
  cache_dir .. "/picsbuffer_323.bin.forgotten.12345.2"
local collision_target = assert(io.open(collision_target_path, "wb"))
collision_target:write("sentinel")
collision_target:close()
ok, c = slsteam.forget_app(323)
os.time = original_time
check("C1b collision cleanup succeeds", ok == true and c == 1)
local preserved_file = assert(io.open(collision_target_path, "rb"))
local preserved = preserved_file:read("*a")
preserved_file:close()
check("C1b existing quarantine preserved", preserved == "sentinel")
check("C1b live artifact moved after collision",
  io.open(cache_dir .. "/picsbuffer_323.bin", "rb") == nil and
  io.open(cache_dir .. "/picsbuffer_323.bin.forgotten.12345.2.1", "rb") ~= nil)

-- XDG_CONFIG_HOME must select the same cache root as slsteam-moon's C++
-- CConfig::getDir(), rather than silently falling back to $HOME/.config.
local xdg_root = sandbox .. "/xdg"
local xdg_cache = xdg_root .. "/SLSsteam/cache"
os.execute("mkdir -p '" .. xdg_cache .. "'")
test_env.XDG_CONFIG_HOME = xdg_root
local xdg_file = assert(io.open(xdg_cache .. "/picsbuffer_323.bin", "wb"))
xdg_file:write("xdg")
xdg_file:close()
local home_file = assert(io.open(cache_dir .. "/picsbuffer_323.bin", "wb"))
home_file:write("home")
home_file:close()
ok, c = slsteam.forget_app(323)
check("C2 XDG cleanup succeeds", ok == true and c == 1)
check("C2 XDG artifact moved", io.open(xdg_cache .. "/picsbuffer_323.bin", "rb") == nil)
check("C2 HOME artifact untouched", io.open(cache_dir .. "/picsbuffer_323.bin", "rb") ~= nil)

-- A read-only cache directory makes the rename fail; the helper must report
-- the partial cleanup instead of claiming success.
local blocked = assert(io.open(xdg_cache .. "/picsbuffer_324.bin", "wb"))
blocked:write("blocked")
blocked:close()
os.execute("chmod 0500 '" .. xdg_cache .. "'")
ok, msg, c = slsteam.forget_app(324)
os.execute("chmod 0700 '" .. xdg_cache .. "'")
check("C3 rename failure is reported", ok == false and type(msg) == "string")
check("C3 failed artifact remains", io.open(xdg_cache .. "/picsbuffer_324.bin", "rb") ~= nil)

-- An existing but unreadable artifact must fail closed: native/Lumen cleanup
-- cannot safely claim success or delete the source script until it is moved.
local unreadable = xdg_cache .. "/picsbuffer_325.bin"
local unreadable_file = assert(io.open(unreadable, "wb"))
unreadable_file:write("unreadable")
unreadable_file:close()
local real_io_open = io.open
io.open = function(path, mode)
  if path == unreadable then return nil, "simulated unreadable artifact" end
  return real_io_open(path, mode)
end
ok, msg, c = slsteam.forget_app(325)
io.open = real_io_open
check("C4 unreadable artifact fails closed", ok == false and type(msg) == "string")
check("C4 unreadable artifact remains", io.open(unreadable, "rb") ~= nil)

-- A metadata-command failure is not proof that the artifact is absent.
local metadata_unknown = xdg_cache .. "/picsbuffer_326.bin"
local metadata_file = assert(io.open(metadata_unknown, "wb"))
metadata_file:write("metadata unknown")
metadata_file:close()
local metadata_execute = os.execute
io.open = function(path, mode)
  if path == metadata_unknown then return nil, "simulated unreadable artifact" end
  return real_io_open(path, mode)
end
os.execute = function(command)
  if command:find("test %-f") and command:find("picsbuffer_326", 1, true) then
    return nil, "exit", 2
  end
  return metadata_execute(command)
end
ok, msg, c = slsteam.forget_app(326)
os.execute = metadata_execute
io.open = real_io_open
check("C5 metadata failure fails closed", ok == false and type(msg) == "string")
check("C5 metadata failure preserves artifact", io.open(metadata_unknown, "rb") ~= nil)

-- ---------------------------------------------------------------------------
-- DeleteLuaToolsForApp transaction: keep this coverage in the tracked smoke
-- test so a clean checkout exercises the same cleanup contract as the native
-- cache helper. The backend dependencies are reduced to deterministic stubs.
-- ---------------------------------------------------------------------------
os.execute("mkdir -p '" .. sandbox .. "/steam/config/stplug-in'")
local function json_escape(value)
  return tostring(value):gsub('\\\\', '\\\\\\\\'):gsub('"', '\\\\"')
end
local function backend_encode(value)
  if type(value) ~= "table" then
    if type(value) == "string" then return '"' .. json_escape(value) .. '"' end
    if type(value) == "boolean" then return value and "true" or "false" end
    return tostring(value)
  end
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = '"' .. json_escape(key) .. '":' .. backend_encode(item)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local backend_remove_failure
package.preload["json"] = function()
  return { encode = backend_encode, decode = function() return {} end }
end
package.preload["plugin_logger"] = function()
  return { log = function() end, warn = function() end, error = function() end }
end
package.preload["millennium"] = function() return {} end
package.preload["fs"] = function()
  return {
    join = function(a, b, c)
      local result = tostring(a) .. "/" .. tostring(b)
      if c then result = result .. "/" .. tostring(c) end
      return result
    end,
    exists = function(path)
      local file = io.open(path, "rb")
      if not file then return false end
      file:close()
      return true
    end,
    remove = function(path)
      if backend_remove_failure == path then return nil, "simulated remove failure" end
      return os.remove(path)
    end,
  }
end
package.preload["steam_utils"] = function()
  return { detect_steam_install_path = function() return sandbox .. "/steam" end }
end
package.preload["paths"] = function()
  return {
    get_plugin_dir = function() return sandbox end,
    backend_path = function(path) return sandbox .. "/" .. path end,
  }
end
for _, module in ipairs({
  "utils", "plugin_utils", "http_client", "locales.manager", "api_manifest",
  "downloads", "fixes", "ryuu_auth", "settings.manager", "auto_update",
}) do
  package.preload[module] = function() return {} end
end
package.loaded.slsteam = slsteam
local backend = dofile("plugin/backend/main.lua")
check("D1 backend loads", type(backend) == "table")

local function backend_script(appid)
  local path = sandbox .. "/steam/config/stplug-in/" .. tostring(appid) .. ".lua"
  local file = assert(io.open(path, "wb"))
  file:write("addappid(" .. tostring(appid) .. ")\n")
  file:close()
  return path
end
local function fake_backend(options)
  package.loaded.slsteam = {
    purge_store_for_lua = options.purge_store_for_lua or function() return true, 0 end,
    purge_pins_for_app = options.purge_pins_for_app or function() return true, "not_present" end,
    forget_app = options.forget_app or function() return true, 0 end,
  }
end

local script331 = backend_script(331)
local success331 = DeleteLuaToolsForApp(331)
check("D2 cleanup success is reported", success331:find('"success":true', 1, true) ~= nil)
check("D3 success reports no stale cache", success331:find('"cacheForgotten":0', 1, true) ~= nil)
check("D4 successful cleanup removes source", io.open(script331, "rb") == nil)

local script332 = backend_script(332)
fake_backend({})
backend_remove_failure = script332
local source_failure = DeleteLuaToolsForApp(332)
backend_remove_failure = nil
check("D5 source failure is reported", source_failure:find('"success":false', 1, true) ~= nil)
check("D6 source failure keeps script retryable", io.open(script332, "rb") ~= nil)

local script333 = backend_script(333)
fake_backend({ forget_app = function() return false, "simulated cache failure", 0 end })
local cache_failure = DeleteLuaToolsForApp(333)
check("D7 cache failure is reported", cache_failure:find('"success":false', 1, true) ~= nil)
check("D8 cache failure keeps script retryable", io.open(script333, "rb") ~= nil)

local script334 = backend_script(334)
fake_backend({
  purge_store_for_lua = function() return false, "simulated manifest purge failure" end,
})
local purge_failure = DeleteLuaToolsForApp(334)
check("D9 manifest failure is reported", purge_failure:find('"success":false', 1, true) ~= nil)
check("D10 manifest failure keeps script retryable", io.open(script334, "rb") ~= nil)

os.getenv = orig_getenv
os.execute("rm -rf '" .. sandbox .. "'")

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
