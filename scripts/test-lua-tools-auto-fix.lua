#!/usr/bin/env luajit

local json_store = {}
package.loaded.json = {
  encode = function(value) json_store.encoded = value; return "encoded" end,
  decode = function() return json_store.decoded or {} end,
}
package.loaded.millennium = { steam_path = function() return "/steam" end }
package.loaded.fs = {
  join = function(...) return table.concat({ ... }, "/"):gsub("/+", "/") end,
  exists = function() return false end,
  create_directories = function() return true end,
}
package.loaded.utils = {
  read_file = function() return nil end,
  write_file = function() return true end,
  exec = function() return true end,
  getenv = function() return "/home/test" end,
}
package.loaded.plugin_logger = { log = function() end, warn = function() end }
package.loaded.paths = { backend_path = function(name) return "/private/" .. name end }

local steam_utils = dofile("plugin/backend/steam_utils.lua")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local files = {
  ["/steam/config/libraryfolders.vdf"] = [[
    "libraryfolders" { "1" { "path" "/library-two" } }
  ]],
  ["/library-two/steamapps/appmanifest_3321460.acf"] = [[
    "AppState" {
      "appid" "3321460"
      "name" "Crimson Desert"
      "installdir" "Crimson Desert"
      "StateFlags" "2"
      "BytesDownloaded" "50"
      "BytesToDownload" "100"
    }
  ]],
  ["/library-two/steamapps/common/Crimson Desert"] = true,
}
local state_deps = {
  steam_path = "/steam",
  exists = function(path) return files[path] ~= nil end,
  read = function(path)
    return type(files[path]) == "string" and files[path] or nil
  end,
}
local downloading = steam_utils.get_game_install_state(3321460, state_deps)
check("J1 unioned Steam libraries find an in-progress appmanifest",
  downloading.found == true and downloading.libraryPath == "/library-two"
    and downloading.complete == false and downloading.stateFlags == 2)

files["/library-two/steamapps/appmanifest_3321460.acf"] = [[
  "AppState" {
    "appid" "3321460"
    "name" "Crimson Desert"
    "installdir" "Crimson Desert"
    "StateFlags" "4"
    "BytesDownloaded" "100"
    "BytesToDownload" "100"
  }
]]
local complete = steam_utils.get_game_install_state(3321460, state_deps)
check("J2 fully installed state plus completed bytes and directory is ready",
  complete.complete == true
    and complete.installPath == "/library-two/steamapps/common/Crimson Desert"
    and complete.gameName == "Crimson Desert")

files["/library-two/steamapps/common/Crimson Desert"] = nil
local missing_dir = steam_utils.get_game_install_state(3321460, state_deps)
check("J3 a fully flagged manifest without its game directory is not ready",
  missing_dir.found == true and missing_dir.complete == false)
files["/library-two/steamapps/common/Crimson Desert"] = true

local ok_module, auto_fix = pcall(dofile, "plugin/backend/lua_tools_auto_fix.lua")
if not ok_module then
  io.stderr:write("FAIL auto-fix module is loadable: " .. tostring(auto_fix) .. "\n")
  os.exit(1)
end

local FIX_ID = "33333333-3333-4333-8333-333333333333"
local database = { version = 1, jobs = {} }
local deps = {
  load = function() return database end,
  save = function(value) database = value; return true end,
  now = function() return 100 end,
}
check("J4 queue persists one private job without auth material",
  auto_fix.queue(3321460, FIX_ID, deps) == true
    and database.jobs["3321460"].fixId == FIX_ID
    and database.jobs["3321460"].token == nil
    and database.jobs["3321460"].url == nil)

local starts, polls, relays, completions = 0, 0, 0, 0
local install = { complete = true, installPath = "/game", gameName = "Crimson Desert" }
local poll_state = { success = true, state = { status = "downloading" } }
local callbacks = {
  auth_status = function() return { configured = true } end,
  install_state = function() return install end,
  start_fix = function(appid, fix_id)
    starts = starts + 1
    return { success = appid == 3321460 and fix_id == FIX_ID }
  end,
  poll_fix = function() polls = polls + 1; return poll_state end,
  launch_options = function()
    return { success = true, apply = true,
      launchOptions = 'WINEDLLOVERRIDES="steam_api64=n,b" %command%' }
  end,
  set_launch_options = function(appid, options)
    relays = relays + 1
    return appid == 3321460 and options:find("WINEDLLOVERRIDES", 1, true) ~= nil
  end,
  complete_fix = function(appid, fix_id)
    completions = completions + 1
    return { success = appid == 3321460 and fix_id == FIX_ID }
  end,
}

auto_fix.tick(101, callbacks, deps)
check("J5 a stale pre-existing complete manifest cannot satisfy a new install job",
  starts == 0 and database.jobs["3321460"].stablePolls == 0
    and database.jobs["3321460"].seenInstallActivity ~= true)
install = { complete = false }
auto_fix.tick(106, callbacks, deps)
check("J6 an absent or incomplete state proves the new installation became active",
  starts == 0 and database.jobs["3321460"].seenInstallActivity == true)
install = { complete = true, installPath = "/game", gameName = "Crimson Desert" }
install.postInstallBusy = true
auto_fix.tick(111, callbacks, deps)
auto_fix.tick(116, callbacks, deps)
check("J7 a complete appmanifest cannot start a fix during Steam post-install work",
  starts == 0 and database.jobs["3321460"].stablePolls == 0)
install.postInstallBusy = false
auto_fix.tick(121, callbacks, deps)
check("J8 first settled observation only stabilizes the appmanifest",
  starts == 0 and database.jobs["3321460"].stablePolls == 1)
auto_fix.tick(126, callbacks, deps)
check("J9 second settled observation starts exactly one fix transaction",
  starts == 1 and database.jobs["3321460"].phase == "applying")
poll_state = { success = true, state = {
  status = "downloading", bytesRead = 25, totalBytes = 100,
} }
local active_tick = auto_fix.tick(131, callbacks, deps)
check("J10 in-progress extraction remains serialized in the applying phase",
  polls == 1 and database.jobs["3321460"].phase == "applying")
check("J10b active jobs expose a compact real-progress view without credentials",
  active_tick.uiJobs and active_tick.uiJobs["3321460"]
    and active_tick.uiJobs["3321460"].gameName == "Crimson Desert"
    and active_tick.uiJobs["3321460"].stage == "downloading"
    and active_tick.uiJobs["3321460"].progress == 21
    and active_tick.uiJobs["3321460"].url == nil)

poll_state = { success = true, state = { status = "done" } }
auto_fix.tick(136, callbacks, deps)
check("J11 completed extraction advances to launch-option finalization",
  database.jobs["3321460"].phase == "finalizing" and relays == 0)
auto_fix.tick(141, callbacks, deps)
check("J12 receipt completes only after the SharedJS launch-option relay",
  relays == 1 and completions == 1 and database.jobs["3321460"] == nil)

auto_fix.queue(3321460, FIX_ID, deps)
callbacks.auth_status = function() return { configured = false } end
database.jobs["3321460"].stablePolls = 1
database.jobs["3321460"].seenInstallActivity = true
auto_fix.tick(146, callbacks, deps)
check("J13 signed-out automatic work pauses without starting a download",
  database.jobs["3321460"].phase == "needs_login" and starts == 1)
callbacks.auth_status = function() return { configured = true } end
auto_fix.tick(151, callbacks, deps)
check("J14 signing in resumes the persisted job", database.jobs["3321460"].phase == "waiting_install")

auto_fix.queue(3321460, FIX_ID, deps)
database.jobs["3321460"].stablePolls = 1
database.jobs["3321460"].seenInstallActivity = true
callbacks.start_fix = function()
  return { success = false, errorCode = "download_unavailable", error = "temporary" }
end
auto_fix.tick(156, callbacks, deps)
local retry_job = database.jobs["3321460"]
check("J15 transient start failures use bounded delayed retry",
  retry_job.phase == "waiting_install" and retry_job.retries == 1
    and retry_job.nextAttempt > 156)

auto_fix.queue(3321460, FIX_ID, deps)
database.jobs["3321460"].stablePolls = 1
database.jobs["3321460"].seenInstallActivity = true
callbacks.start_fix = function()
  return { success = false, errorCode = "unavailable", error = "removed" }
end
auto_fix.tick(200, callbacks, deps)
check("J16 removed indexed fixes stop permanently instead of looping",
  database.jobs["3321460"].phase == "failed"
    and database.jobs["3321460"].errorCode == "unavailable")

database.jobs = {}
auto_fix.queue(3321460, FIX_ID, deps)
database.jobs["3321460"].seenInstallActivity = true
database.jobs["3321460"].stablePolls = 1
local guarded_starts, pinned_build_ready = 0, false
callbacks.auth_status = function() return { configured = true } end
callbacks.install_state = function()
  return { complete = true, installPath = "/game", gameName = "Crimson Desert" }
end
callbacks.is_busy = function() return false end
callbacks.recommended_build_ready = function() return pinned_build_ready end
callbacks.start_fix = function()
  guarded_starts = guarded_starts + 1
  return { success = true }
end
auto_fix.tick(210, callbacks, deps)
check("J17 a fallback/latest install cannot receive the build-specific automatic fix",
  guarded_starts == 0 and database.jobs["3321460"].phase == "waiting_install"
    and database.jobs["3321460"].stablePolls == 0)
pinned_build_ready = true
auto_fix.tick(215, callbacks, deps)
auto_fix.tick(220, callbacks, deps)
check("J18 the fix resumes only after every installed depot matches its exact pin",
  guarded_starts == 1 and database.jobs["3321460"].phase == "applying")

local cancel_db = { version = 1, jobs = {} }
local cancel_deps = {
  load = function() return cancel_db end,
  save = function(value) cancel_db = value; return true end,
  now = function() return 300 end,
}
auto_fix.queue(990080, FIX_ID, cancel_deps)
local cancelled = type(auto_fix.cancel) == "function"
  and auto_fix.cancel(990080, cancel_deps) or { success = false }
check("J19 launch-without-fix can cancel work before file application starts",
  cancelled.success == true and cancel_db.jobs["990080"] == nil)
auto_fix.queue(990080, FIX_ID, cancel_deps)
cancel_db.jobs["990080"].phase = "applying"
local unsafe_cancel = type(auto_fix.cancel) == "function"
  and auto_fix.cancel(990080, cancel_deps) or { success = false }
check("J20 active file application cannot be skipped unsafely",
  unsafe_cancel.success == false and unsafe_cancel.errorCode == "already_applying"
    and cancel_db.jobs["990080"].phase == "applying")

-- A failed job used to vanish from the compact UI, which left the launch guard
-- holding a saved Play with nothing on screen but a 0% bar. A failure must stay
-- visible, carry its reason, and always be skippable.
local failed_db = { version = 1, jobs = {} }
local failed_deps = {
  load = function() return failed_db end,
  save = function(value) failed_db = value; return true end,
  now = function() return 400 end,
}
auto_fix.queue(990080, FIX_ID, failed_deps)
failed_db.jobs["990080"].gameName = "Resident Evil Requiem"
failed_db.jobs["990080"].phase = "failed"
failed_db.jobs["990080"].errorCode = "unavailable"
failed_db.jobs["990080"].error = "This recommendation is no longer available."
local failed_tick = auto_fix.tick(401, {
  auth_status = function() return { configured = true } end,
  install_state = function() return { complete = true, gameName = "Resident Evil Requiem" } end,
}, failed_deps)
local failed_view = failed_tick.uiJobs and failed_tick.uiJobs["990080"]
check("J21 a failed automatic fix stays visible instead of stalling at 0%",
  type(failed_view) == "table" and failed_view.phase == "failed"
    and failed_view.stage == "failed")
check("J22 the visible failure reports its reason and can always be skipped",
  type(failed_view) == "table" and failed_view.canSkip == true
    and failed_view.error == "This recommendation is no longer available."
    and failed_view.errorCode == "unavailable")
check("J23 a failed job is still cancellable so a launch is never trapped",
  auto_fix.cancel(990080, failed_deps).success == true
    and failed_db.jobs["990080"] == nil)

-- Reapplying is idempotent, so a queued fix for a build that already has one
-- must overwrite it rather than refuse. Queue must accept the same appid again.
local requeue_db = { version = 1, jobs = {} }
local requeue_deps = {
  load = function() return requeue_db end,
  save = function(value) requeue_db = value; return true end,
  now = function() return 500 end,
}
auto_fix.queue(990080, FIX_ID, requeue_deps)
requeue_db.jobs["990080"].phase = "failed"
requeue_db.jobs["990080"].retries = 3
requeue_db.jobs["990080"].errorCode = "unavailable"
check("J24 requeueing a fix clears the previous terminal failure",
  auto_fix.queue(990080, FIX_ID, requeue_deps) == true
    and requeue_db.jobs["990080"].phase == "waiting_install"
    and requeue_db.jobs["990080"].retries == 0
    and requeue_db.jobs["990080"].errorCode == nil)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS AUTO FIX CHECKS PASSED")
