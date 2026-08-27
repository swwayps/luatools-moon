#!/usr/bin/env luajit

package.path = "plugin/backend/?.lua;" .. package.path

package.loaded.json = { decode = function() return {} end }
package.loaded.paths = { backend_path = function(name) return "/plugin/backend/" .. name end }
package.loaded.utils = { read_file = function() return nil end }

local ok_module, index = pcall(dofile, "plugin/backend/lua_tools_fix_index.lua")
if not ok_module then
  io.stderr:write("FAIL index module is loadable: " .. tostring(index) .. "\n")
  os.exit(1)
end

local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local FIX_ID = "33333333-3333-4333-8333-333333333333"
local ONLINE_ID = "online-fix:6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf"
local fixture = {
  schema = 1,
  generatedAt = "2026-08-20T00:00:00Z",
  source = "https://lua.tools/api/denuvo",
  apps = {
    ["3321460"] = {
      fixId = FIX_ID,
      title = "Recommended",
      category = "voices38",
      createdAt = "2026-08-04T00:00:00.000Z",
      manifestFilename = "3321460.lua",
      hasFix = true,
    },
  },
}

local deps = { load = function() return fixture end }
local entry = index.lookup(3321460, deps)
check("I1 a valid manifest recommendation is found locally",
  entry and entry.fixId == FIX_ID and entry.hasFix == true
    and entry.manifestFilename == "3321460.lua")
check("I2 an archive-only entry is rejected",
  index.lookup(285900, deps) == nil)
check("I3 invalid AppIDs never index a different game",
  index.lookup("../3321460", deps) == nil and index.lookup(0, deps) == nil)

entry.title = "mutated"
check("I4 callers cannot mutate the cached index",
  index.lookup(3321460, deps).title == "Recommended")

local namespaced = {
  schema = 1, generatedAt = fixture.generatedAt, source = fixture.source,
  apps = { ["10"] = {
    fixId = ONLINE_ID, title = "Namespaced manifest", category = "online_fix",
    createdAt = fixture.generatedAt, manifestFilename = "10.lua", hasFix = false,
  } },
}
check("I5 namespaced official fix IDs are accepted",
  index.lookup(10, { load = function() return namespaced end }).fixId == ONLINE_ID)

for name, invalid in pairs({
  wrong_schema = { schema = 2, apps = fixture.apps },
  missing_apps = { schema = 1 },
  malformed_id = { schema = 1, apps = { ["10"] = {
    fixId = "../bad", title = "Bad", category = "voices38",
    manifestFilename = "10.lua", hasFix = true,
  } } },
  wrong_filename = { schema = 1, apps = { ["10"] = {
    fixId = FIX_ID, title = "Bad", category = "voices38",
    manifestFilename = "11.lua", hasFix = true,
  } } },
}) do
  check("I6 invalid index is rejected: " .. name,
    index.lookup(10, { load = function() return invalid end }) == nil)
end

local reads = 0
local cached_deps = {
  cacheKey = "runtime-index",
  load = function() reads = reads + 1; return fixture end,
}
index.lookup(3321460, cached_deps)
index.lookup(3321460, cached_deps)
check("I7 the runtime index is decoded once", reads == 1)

local signed_out = index.recommendation(3321460, false, deps)
local signed_in = index.recommendation(3321460, true, deps)
check("I8 signed-out Store lookups never expose a recommendation",
  signed_out.available == false and signed_out.authRequired == true
    and signed_out.recommendation == nil)
check("I9 signed-in Store lookups return only indexed public metadata",
  signed_in.available == true and signed_in.authRequired == false
    and signed_in.recommendation.fixId == FIX_ID
    and signed_in.recommendation.url == nil
    and signed_in.recommendation.token == nil)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS FIX INDEX CHECKS PASSED")
