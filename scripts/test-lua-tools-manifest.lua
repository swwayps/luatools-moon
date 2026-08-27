#!/usr/bin/env luajit

package.path = "plugin/backend/?.lua;" .. package.path

package.loaded.json = {}
package.loaded.http_client = {}
package.loaded.lua_tools_auth = {}

local manifests = dofile("plugin/backend/lua_tools_manifest.lua")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local missing, missing_error = manifests.download_candidate(250900, {
  get_token = function() return nil, { code = "not_signed_in" } end,
})
check("M1 Luie download requires the shared lua.tools session",
  missing == nil and missing_error and missing_error.code == "not_signed_in")

local candidate = manifests.download_candidate("250900", {
  get_token = function() return "access-secret" end,
})
check("M2 Luie uses only the fixed official download route",
  candidate.url == "https://lua.tools/api/manifest/download?appid=250900&source=Luie")
check("M3 authenticated candidate is explicitly private backend data",
  candidate.bearer == "access-secret" and candidate.successCode == 200)
local invalid = manifests.download_candidate("250900&source=Other", {
  get_token = function() return "access-secret" end,
})
check("M4 app IDs cannot inject another source or query parameter", invalid == nil)

local request
local available = manifests.check(250900, {
  auth_status = function() return { success = true, configured = true } end,
  get = function(url, options)
    request = { url = url, options = options }
    return { status = 200, body = "sources" }
  end,
  decode = function() return { Luie = "available", Other = "unavailable" } end,
})
check("M5 availability uses the official app manifest discovery contract",
  request.url == "http://167.235.229.108/check_apis?appid=250900"
    and request.options.headers["User-Agent"] == "secretgoonpoon")
check("M6 availability accepts only the Luie status field",
  available.available == true and available.status == "available")

local signed_out = manifests.check(250900, {
  auth_status = function() return { success = true, configured = false } end,
})
check("M7 signed-out availability is a login gate without a network request",
  signed_out.locked == true and signed_out.needsLogin == true
    and signed_out.status == "auth_required")

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS MANIFEST CHECKS PASSED")
