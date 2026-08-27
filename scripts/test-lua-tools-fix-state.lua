#!/usr/bin/env luajit

package.loaded.json = {
  encode = function() return "{}" end,
  decode = function() return {} end,
}
package.loaded.fs = {}
package.loaded.utils = {}
package.loaded.paths = { backend_path = function(name) return "/private/" .. name end }

local state = dofile("plugin/backend/lua_tools_fix_state.lua")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local valid = "-- official manifest\naddappid(250900, 1, \"abc\")\n"
check("R1 manifest validation accepts the exact requested AppID",
  state.validate_manifest(valid, 250900) == true)
local wrong, wrong_error = state.validate_manifest("addappid(480, 1)\n", 250900)
check("R2 manifest validation rejects a different AppID",
  wrong == false and wrong_error == "manifest_appid_mismatch")
check("R3 manifest validation rejects binary and oversized input",
  state.validate_manifest("addappid(250900)\0", 250900) == false
    and state.validate_manifest(string.rep("x", 2 * 1024 * 1024 + 1), 250900) == false)

local database = { version = 1, apps = {
  ["250900"] = { applied = { fixId = "old", category = "bypass" } },
} }
local deps = {
  load = function() return database end,
  save = function(value) database = value; return true end,
  now = function() return 123456 end,
}
local begun = state.begin(250900, {
  id = "33333333-3333-4333-8333-333333333333",
  title = "Recommended build", category = "voices38",
  manifestFilename = "250900.lua", fixFilename = "250900.zip",
}, "/private/staged.lua", deps)
check("R4 beginning a reapply preserves the last completed receipt",
  begun == true and state.get_applied(250900, deps).fixId == "old")
check("R5 pending state retains only the selected public metadata and private stage path",
  state.get_pending(250900, deps).fixId == "33333333-3333-4333-8333-333333333333"
    and state.get_pending(250900, deps).stagedManifest == "/private/staged.lua")

local files, renames, chmods = { ["/private/staged.lua"] = valid }, {}, {}
local installed, install_error = state.install_staged_manifest(250900, "/steam", {
  load = deps.load, save = deps.save,
  read = function(path) return files[path] end,
  write = function(path, body) files[path] = body; return true end,
  mkdir = function(path) files[path .. "/"] = true; return true end,
  rename = function(from, to)
    renames[#renames + 1] = { from, to }
    files[to], files[from] = files[from], nil
    return true
  end,
  remove = function(path) files[path] = nil; return true end,
  chmod = function(path) chmods[#chmods + 1] = path end,
})
check("R6 staged manifest atomically replaces the canonical stplug-in script",
  installed == true and install_error == nil
    and files["/steam/config/stplug-in/250900.lua"] == valid
    and renames[#renames][2] == "/steam/config/stplug-in/250900.lua")
check("R7 installed manifest staging file is removed and pending phase is durable",
  files["/private/staged.lua"] == nil
    and state.get_pending(250900, deps).manifestInstalled == true)

local direct_files = {
  ["/steam/config/stplug-in/250900.lua"] = "addappid(250900) -- previous\n",
}
local published, publish_error = state.publish_manifest(250900, valid, "/steam", {
  read = function(path) return direct_files[path] end,
  write = function(path, body) direct_files[path] = body; return true end,
  mkdir = function() return true end,
  rename = function(from, to)
    direct_files[to], direct_files[from] = direct_files[from], nil
    return true
  end,
  remove = function(path) direct_files[path] = nil; return true end,
  chmod = function() end,
})
check("R8 direct recommended publication atomically replaces the canonical script",
  published == true and publish_error == nil
    and direct_files["/steam/config/stplug-in/250900.lua"] == valid)

local old = "addappid(250900) -- keep me\n"
direct_files["/steam/config/stplug-in/250900.lua"] = old
local failed_publish, failed_error = state.publish_manifest(250900, valid, "/steam", {
  read = function(path) return direct_files[path] end,
  write = function(path, body) direct_files[path] = body; return true end,
  mkdir = function() return true end,
  rename = function() return false end,
  remove = function(path) direct_files[path] = nil; return true end,
  chmod = function() end,
})
check("R9 failed direct publication preserves the previous script",
  failed_publish == false and failed_error == "manifest_replace_failed"
    and direct_files["/steam/config/stplug-in/250900.lua"] == old)

local mismatched = state.complete(250900, "11111111-1111-4111-8111-111111111111", deps)
check("R10 a different fix cannot complete another pending transaction", mismatched == false)
local completed = state.complete(250900,
  "33333333-3333-4333-8333-333333333333", deps)
local receipt = state.get_applied(250900, deps)
check("R11 completion publishes a timestamped receipt and clears pending state",
  completed == true and receipt.fixId == "33333333-3333-4333-8333-333333333333"
    and receipt.category == "voices38" and receipt.source == "lua_tools"
    and receipt.appliedAt == 123456
    and state.get_pending(250900, deps) == nil)

local game = { fixes = {
  { id = "33333333-3333-4333-8333-333333333333", category = "voices38" },
  { id = "22222222-2222-4222-8222-222222222222", category = "bypass" },
} }
state.decorate_game(game, receipt)
check("R12 only the completed fix is decorated as applied",
  game.fixes[1].applied == true and game.fixes[2].applied == false
    and game.appliedFix.fixId == receipt.fixId)

local fallback_started = type(state.begin_fallback_online) == "function"
  and state.begin_fallback_online(250900, deps)
local fallback_completed = state.complete(250900, "online-fix-fallback", deps)
local fallback_receipt = state.get_applied(250900, deps)
check("R13 fallback completion supersedes the previous file-fix receipt",
  fallback_started == true and fallback_completed == true
    and fallback_receipt.fixId == "online-fix-fallback"
    and fallback_receipt.source == "online_fix_fallback")
local after_fallback = { fixes = {
  { id = "33333333-3333-4333-8333-333333333333", category = "voices38" },
} }
state.decorate_game(after_fallback, fallback_receipt)
check("R14 fallback receipt never marks an official lua.tools fix as applied",
  after_fallback.fixes[1].applied == false)
check("R15 applied-source classifier is exported", type(state.applied_sources) == "function")
if type(state.applied_sources) == "function" then
  local applied_sources = state.applied_sources(fallback_receipt)
  check("R15 applied-source flags identify the fallback receipt",
    applied_sources.luaTools == false and applied_sources.fallbackOnline == true)
end
check("R16 clearing an app removes its shared receipt",
  state.clear(250900, deps) == true and state.get_applied(250900, deps) == nil)

-- Applying a fix is idempotent, so a newer build's fix must overwrite the
-- receipt of an older one instead of being refused. Refusing would leave the
-- game on a stale fix with no way to move forward from the UI.
local overwrite_db = { version = 1, apps = {
  ["3764200"] = { applied = {
    fixId = "782261fd-5eb8-4f70-b0a8-1824b2f2aa47",
    source = "lua_tools", title = "22277314", category = "voices38",
    fixFilename = "3764200.zip", manifestFilename = "3764200.lua",
    appliedAt = 1000,
  } },
} }
local overwrite_deps = {
  load = function() return overwrite_db end,
  save = function(value) overwrite_db = value; return true end,
  now = function() return 2000 end,
}
local NEW_FIX = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
local rebegun = state.begin(3764200, {
  id = NEW_FIX, source = "lua_tools", title = "23634047", category = "voices38",
  fixFilename = "3764200.zip", manifestFilename = "3764200.lua",
}, "", overwrite_deps)
check("R17 a new build's fix can start over an already applied receipt",
  rebegun == true
    and state.get_applied(3764200, overwrite_deps).fixId
      == "782261fd-5eb8-4f70-b0a8-1824b2f2aa47")
check("R18 completing the new fix overwrites the previous receipt",
  state.complete(3764200, NEW_FIX, overwrite_deps) == true
    and state.get_applied(3764200, overwrite_deps).fixId == NEW_FIX
    and state.get_applied(3764200, overwrite_deps).title == "23634047"
    and state.get_applied(3764200, overwrite_deps).appliedAt == 2000)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS FIX STATE CHECKS PASSED")
