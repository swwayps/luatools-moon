#!/usr/bin/env luajit

package.loaded.lua_tools_fix_index = {}
package.loaded.lua_tools_fixes = {}
package.loaded.lua_tools_fix_state = {}
package.loaded.http_client = {}
package.loaded.steam_utils = {}

local ok_module, recommended = pcall(dofile,
  "plugin/backend/lua_tools_recommended_add.lua")
if not ok_module then
  io.stderr:write("FAIL recommended Add module is loadable: " .. tostring(recommended) .. "\n")
  os.exit(1)
end

local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local APPID = 3321460
local FIX_ID = "33333333-3333-4333-8333-333333333333"
local VALID_LUA = "-- official\naddappid(3321460, 1, \"abc\")\n"
local calls = { resolve = 0, fetch = 0, publish = 0, queue = 0 }
local function base_deps()
  return {
    lookup = function(appid)
      if appid ~= APPID then return nil end
      return {
        fixId = FIX_ID, title = "Recommended", category = "voices38",
        createdAt = "2026-08-04T00:00:00Z",
        manifestFilename = "3321460.lua", hasFix = true,
      }
    end,
    resolve = function(fix_id, slot)
      calls.resolve = calls.resolve + 1
      if fix_id ~= FIX_ID or slot ~= "manifest" then return nil end
      return { url = "https://signed.example/private.lua?signature=secret" }
    end,
    get = function(url, options)
      calls.fetch = calls.fetch + 1
      check("A0 manifest fetch is bounded",
        url:find("https://signed.example/", 1, true) == 1
          and options.max_bytes == 2 * 1024 * 1024)
      return { status = 200, body = VALID_LUA }
    end,
    steam_root = function() return "/steam" end,
    availability = function()
      return { ready = false, offline = false, missing = 1, targets = 1 }
    end,
    publish = function(appid, body, root)
      calls.publish = calls.publish + 1
      return appid == APPID and body == VALID_LUA and root == "/steam"
    end,
    queue = function(appid, fix_id)
      calls.queue = calls.queue + 1
      return appid == APPID and fix_id == FIX_ID
    end,
  }
end

local invalid = recommended.start(APPID,
  "11111111-1111-4111-8111-111111111111", true, base_deps())
check("A1 an arbitrary frontend fix ID is rejected before network access",
  invalid.success == false and invalid.errorCode == "recommendation_mismatch"
    and calls.resolve == 0 and calls.fetch == 0 and calls.publish == 0)

local result = recommended.start(APPID, FIX_ID, true, base_deps())
check("A2 the authenticated recommended manifest is published",
  result.success == true and result.manifestInstalled == true
    and calls.resolve == 1 and calls.fetch == 1 and calls.publish == 1)
check("A3 automatic application is queued only after publication",
  result.autoApplyQueued == true and calls.queue == 1)
check("A4 signed download data never crosses the RPC result",
  result.url == nil and result.downloadUrl == nil and result.token == nil)

local queue_before = calls.queue
local manual = recommended.start(APPID, FIX_ID, false, base_deps())
check("A5 an unchecked recommendation creates no automatic-fix job",
  manual.success == true and manual.autoApplyQueued == false
    and calls.queue == queue_before)

local download_failed_deps = base_deps()
download_failed_deps.get = function() return { status = 503, body = "" } end
local failed = recommended.start(APPID, FIX_ID, true, download_failed_deps)
check("A6 failed download neither publishes nor queues",
  failed.success == false and failed.errorCode == "manifest_download_failed")

local publish_failed_deps = base_deps()
publish_failed_deps.publish = function() return false, "manifest_replace_failed" end
local publish_failed = recommended.start(APPID, FIX_ID, true, publish_failed_deps)
check("A7 failed atomic publication is reported and never queued",
  publish_failed.success == false
    and publish_failed.errorCode == "manifest_replace_failed")

local queue_failed_deps = base_deps()
queue_failed_deps.queue = function() return false, "state_write_failed" end
local queue_failed = recommended.start(APPID, FIX_ID, true, queue_failed_deps)
check("A8 a queue failure reports that the manifest was already installed",
  queue_failed.success == false and queue_failed.manifestInstalled == true
    and queue_failed.errorCode == "state_write_failed")

local publish_before, queue_before_offline = calls.publish, calls.queue
local offline_missing_deps = base_deps()
offline_missing_deps.availability = function()
  return { ready = false, offline = true, missing = 1, targets = 1 }
end
local unavailable = recommended.start(APPID, FIX_ID, true, offline_missing_deps)
check("A9 offline missing pins offer Latest before publishing recommended state",
  unavailable.success == false
    and unavailable.errorCode == "manifest_server_unavailable"
    and unavailable.fallbackLatest == true
    and calls.publish == publish_before)
check("A10 unavailable recommended builds never queue the automatic fix",
  unavailable.autoApplyQueued == false and calls.queue == queue_before_offline)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS RECOMMENDED ADD CHECKS PASSED")
