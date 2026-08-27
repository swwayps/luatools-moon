#!/usr/bin/env luajit

package.path = "plugin/backend/?.lua;../lumen/lua/?.lua;" .. package.path
table.unpack = table.unpack or unpack

local failures = 0
local function check(name, condition)
  if condition then
    print("ok   " .. name)
  else
    print("FAIL " .. name)
    failures = failures + 1
  end
end

local function encode(value)
  if type(value) == "boolean" then return value and "true" or "false" end
  if type(value) == "number" then return tostring(value) end
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return "null" end
  local fields = {}
  for key, item in pairs(value) do
    fields[#fields + 1] = string.format("%q:%s", tostring(key), encode(item))
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

package.preload.json = function()
  return { encode = encode, decode = function() return {} end }
end
package.preload.plugin_logger = function()
  return { log = function() end, warn = function() end, error = function() end }
end

local captured
package.preload.lua_tools_recommended_add = function()
  return {
    start = function(appid, fix_id, auto_apply, deps)
      captured = {
        appid = appid,
        fixId = fix_id,
        autoApply = auto_apply,
        hasQueue = type(deps) == "table" and type(deps.queue) == "function",
        hasAtomicPublish = type(deps) == "table"
          and type(deps.publish) == "function",
        hasAvailability = type(deps) == "table"
          and type(deps.availability) == "function",
      }
      return { success = true }
    end,
  }
end

package.preload.lua_tools_auto_fix = function()
  return { queue = function() return true end }
end

for _, name in ipairs({
  "utils", "millennium", "fs", "http_client", "paths", "steam_utils",
  "plugin_utils", "locales.manager", "api_manifest", "downloads", "fixes",
  "lua_tools_auth", "lua_tools_fixes", "lua_tools_fix_index",
  "lua_tools_fix_state", "settings.manager", "auto_update",
}) do
  package.preload[name] = function() return {} end
end

local handoff
package.preload.downloads = function()
  return {
    get_game_draft_snapshot = function(appid, session)
      return {
        success = true, appid = appid, lua = "addappid(" .. appid .. ")\n",
        manifests = { { name = "1_2.manifest", data = "\0binary" } },
        draftSession = session,
      }
    end,
  }
end
package.preload.manifestpins = function()
  return {
    default_ctx = function() return { private = true } end,
    enrich_game_import_snapshot = function(ctx, import_session, appid, snapshot)
      handoff = {
        ctx = ctx, importSession = import_session, appid = appid,
        draftSession = snapshot.draftSession,
        binary = snapshot.manifests[1].data,
      }
      return true, { appid = appid, manifests = #snapshot.manifests }
    end,
  }
end

local lifecycle = dofile("plugin/backend/main.lua")
check("R1 backend loads with the recommended Add RPC", type(lifecycle) == "table"
  and type(StartLuaToolsRecommendedAdd) == "function")

local rpc = dofile("../lumen/lua/rpc.lua")
local fix_id = "b8b9bd15-b5e2-4c63-8a17-282f3f575eaf"
local ok = rpc.dispatch(StartLuaToolsRecommendedAdd, {
  appid = 3321460,
  autoApply = true,
  contentScriptQuery = "",
  fixId = fix_id,
})

check("R2 Millennium-style argument ordering preserves the AppID",
  ok == true and captured and captured.appid == 3321460)
check("R3 Millennium-style argument ordering preserves the fix ID",
  captured and captured.fixId == fix_id)
check("R4 Millennium-style argument ordering preserves auto-apply",
  captured and captured.autoApply == true)
check("R5 the RPC still supplies the private queue callback",
  captured and captured.hasQueue == true)
check("R6 the RPC supplies the atomic Lua + ManifestPins publisher",
  captured and captured.hasAtomicPublish == true)
check("R6b the RPC preflights exact manifest availability",
  captured and captured.hasAvailability == true)

captured = nil
rpc.dispatch(StartLuaToolsRecommendedAdd, {
  appid = "1e3",
  autoApply = true,
  contentScriptQuery = "",
  fixId = fix_id,
})
check("R6c non-decimal AppID aliases are rejected at the RPC boundary",
  captured == nil)

local handoff_result = EnrichGameImportFromDraft({
  appid = 1671210, importSession = "import123", draftSession = "draft456",
})
check("R7 draft handoff stays inside the backend and preserves both sessions",
  type(handoff_result) == "string" and handoff
    and handoff.importSession == "import123" and handoff.draftSession == "draft456")
check("R8 draft handoff preserves binary manifest bytes without browser JSON",
  handoff and handoff.appid == 1671210 and handoff.binary == "\0binary")

if failures > 0 then os.exit(1) end
