local cjson = require("json")
local http_client = require("http_client")
local lua_tools_auth = require("lua_tools_auth")

local manifests = {}

local API_BASE_URL = "https://lua.tools"
local DISCOVERY_URL = "http://167.235.229.108/check_apis"
local DISCOVERY_USER_AGENT = "secretgoonpoon"

local function positive_appid(value)
  local number = tonumber(value)
  if not number or number <= 0 or number ~= math.floor(number) then return nil end
  return math.floor(number)
end

function manifests.download_candidate(appid, deps)
  appid = positive_appid(appid)
  if not appid then
    return nil, { code = "invalid_appid", message = "Invalid Steam app ID." }
  end
  deps = deps or {}
  local token, token_error = (deps.get_token or lua_tools_auth.get_valid_access_token)(deps.auth_deps)
  if not token then return nil, token_error end
  return {
    url = API_BASE_URL .. "/api/manifest/download?appid=" .. tostring(appid)
      .. "&source=Luie",
    bearer = token,
    successCode = 200,
  }
end

function manifests.check(appid, deps)
  appid = positive_appid(appid)
  if not appid then
    return { available = false, status = "invalid_appid" }
  end
  deps = deps or {}
  local auth_status = (deps.auth_status or lua_tools_auth.status)(deps.auth_deps)
  if type(auth_status) ~= "table" or auth_status.configured ~= true then
    return {
      available = false,
      locked = true,
      needsLogin = true,
      status = "auth_required",
    }
  end

  -- allow_http is an explicit request for plaintext, honoured by the Lumen HTTP
  -- shim (which defaults to TLS) and ignored by Millennium's, which has no such
  -- option and permits http anyway. Either way it records the intent at the call
  -- site rather than leaving the plaintext fetch looking accidental.
  --
  -- This endpoint has no TLS at all: it is reachable only by bare IP, which cannot
  -- present a valid certificate. The exposure is real and deliberate —
  -- the queried AppID and the fixed discovery User-Agent both travel in the
  -- clear, and an observer on the path can force the "unavailable" answer. The
  -- failure mode is fail-closed (the source reports unavailable), so nothing is
  -- installed on a forged reply. Moving this probe behind a hostname with a
  -- certificate is the actual fix and needs a server-side change.
  local response = (deps.get or http_client.get)(
    DISCOVERY_URL .. "?appid=" .. tostring(appid), {
      headers = { ["User-Agent"] = DISCOVERY_USER_AGENT },
      timeout = 8,
      allow_http = true,
    })
  if type(response) ~= "table" or tonumber(response.status) ~= 200 then
    return { available = false, locked = false, needsLogin = true, status = "unavailable" }
  end
  local ok, statuses = pcall(deps.decode or cjson.decode, response.body or "")
  local status = ok and type(statuses) == "table" and statuses.Luie or nil
  return {
    available = status == "available",
    locked = false,
    needsLogin = true,
    status = type(status) == "string" and status or "unavailable",
  }
end

return manifests
