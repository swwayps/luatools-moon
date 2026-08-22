#!/usr/bin/env luajit

package.loaded.fs = {}
package.loaded.utils = {}
package.loaded.json = {}
package.loaded.paths = { backend_path = function() return "/tmp/lua_tools_auth.json" end }
package.loaded.http_client = {}
package.loaded.sha256 = { digest = function(value) return value end }
package.loaded.b64 = {
  encode = function(value) return value end,
  decode = function(value) return value end,
}

local auth = dofile("plugin/backend/lua_tools_auth.lua")
local failures = 0

local function check(name, condition)
  if condition then
    print("ok   " .. name)
  else
    print("FAIL " .. name)
    failures = failures + 1
  end
end

local code = auth.normalize_code(" ab12cd ")
check("A1 login code is trimmed and uppercased", code == "AB12CD")

local short, short_error = auth.normalize_code("ABC")
check("A2 login code must contain exactly six characters",
  short == nil and tostring(short_error):find("six", 1, true) ~= nil)

local injected = auth.normalize_code("ABC\nDE")
check("A3 login code rejects control characters", injected == nil)

local requests, stored = {}, nil
local fixtures = {
  redeem = { token = "magic-hash" },
  session = {
    access_token = "access-secret",
    refresh_token = "refresh-secret",
    expires_in = 3600,
    user = {
      email = "user@example.invalid",
      user_metadata = {
        avatar_url = "https://cdn.discordapp.com/avatars/1/avatar.png",
        custom_claims = { global_name = "Lua User" },
      },
    },
  },
}
local signed = auth.sign_in_with_code("ab12cd", {
  post = function(url, options)
    requests[#requests + 1] = { url = url, options = options }
    if url:find("/api/auth/code/redeem", 1, true) then
      return { status = 200, body = "redeem" }
    end
    return { status = 200, body = "session" }
  end,
  decode = function(body) return fixtures[body] end,
  encode = function(value)
    if value.code then return '{"code":"' .. value.code .. '"}' end
    return "encoded"
  end,
  save = function(session) stored = session; return true end,
  now = function() return 1000 end,
})
check("A4 code login uses redeem then Supabase verification",
  #requests == 2
    and requests[1].url == "https://lua.tools/api/auth/code/redeem"
    and requests[2].url == "https://db.lua.tools/auth/v1/verify")
check("A5 code is normalized before redeem",
  requests[1].options.data:find("AB12CD", 1, true) ~= nil)
check("A6 verified session is persisted with an absolute expiry",
  stored and stored.access_token == "access-secret"
    and stored.refresh_token == "refresh-secret" and stored.expires_at == 4600)
check("A7 successful response exposes display-safe account data",
  signed and signed.success == true and signed.configured == true
    and signed.account and signed.account.displayName == "Lua User"
    and signed.account.avatarUrl:find("cdn.discordapp.com", 1, true) ~= nil)
check("A8 successful response never exposes bearer secrets",
  signed.access_token == nil and signed.refresh_token == nil
    and signed.account.access_token == nil and signed.account.refresh_token == nil)

local function rejected_code(status)
  return auth.sign_in_with_code("ABC123", {
    post = function() return { status = status, body = "{}" } end,
    encode = function() return "{}" end,
    decode = function() return {} end,
    save = function() return true end,
  })
end
check("A9 missing code is classified as invalid", rejected_code(404).errorCode == "invalid_code")
check("A10 consumed or expired code is classified as expired",
  rejected_code(410).errorCode == "expired_code")
check("A11 throttled code is classified as rate limited",
  rejected_code(429).errorCode == "rate_limited")
check("A12 server failures are distinct from invalid codes",
  rejected_code(503).errorCode == "service_unavailable")

local live_session = fixtures.session
live_session.expires_at = 5000
local visible = auth.status({ load = function() return live_session end, now = function() return 1000 end })
check("A13 status reports a stored session without secrets",
  visible.configured == true and visible.account.displayName == "Lua User"
    and visible.access_token == nil and visible.refresh_token == nil)
local absent = auth.status({ load = function() return nil end })
check("A14 status reports signed out when no session exists",
  absent.success == true and absent.configured == false and absent.account == nil)

local removed = 0
local cleared = auth.clear({ remove = function() removed = removed + 1; return true end })
check("A15 logout removes the persisted session", cleared.success == true
  and cleared.configured == false and removed == 1)

local refreshed, refresh_saved
local token, token_error = auth.get_valid_access_token({
  load = function()
    return { access_token = "old", refresh_token = "refresh-old", expires_at = 1050,
      user = fixtures.session.user }
  end,
  post = function(url, options)
    refreshed = { url = url, options = options }
    return { status = 200, body = "refresh-session" }
  end,
  decode = function(body)
    if body == "refresh-session" then
      return { access_token = "access-new", refresh_token = "refresh-new",
        expires_in = 7200, user = fixtures.session.user }
    end
  end,
  encode = function(value) return value.refresh_token or "{}" end,
  save = function(value) refresh_saved = value; return true end,
  now = function() return 1000 end,
})
check("A16 expiring access token refreshes through Supabase",
  token == "access-new" and token_error == nil
    and refreshed.url:find("grant_type=refresh_token", 1, true) ~= nil)
check("A17 refresh rotates and persists both tokens",
  refresh_saved and refresh_saved.refresh_token == "refresh-new"
    and refresh_saved.expires_at == 8200)

removed = 0
local rejected_token, rejected_error = auth.get_valid_access_token({
  load = function()
    return { access_token = "old", refresh_token = "revoked", expires_at = 0 }
  end,
  post = function() return { status = 401, body = "{}" } end,
  encode = function() return "{}" end,
  remove = function() removed = removed + 1; return true end,
  now = function() return 1000 end,
})
check("A18 revoked refresh token clears the local session",
  rejected_token == nil and rejected_error and rejected_error.code == "session_expired"
    and removed == 1)

local authorize_url = auth.build_authorize_url(
  "http://localhost:53789/callback", "challenge value")
check("A19 Discord OAuth uses the official Supabase PKCE endpoint",
  authorize_url:find("https://db.lua.tools/auth/v1/authorize?provider=discord", 1, true) == 1)
check("A20 OAuth URL contains encoded callback and S256 challenge",
  authorize_url:find("redirect_to=http%3A%2F%2Flocalhost%3A53789%2Fcallback", 1, true)
    and authorize_url:find("code_challenge=challenge%20value", 1, true)
    and authorize_url:find("code_challenge_method=s256", 1, true))
local callback_code, callback_error = auth.parse_callback(
  "GET /callback?code=auth%2Bcode HTTP/1.1")
check("A21 loopback callback parser decodes the authorization code",
  callback_code == "auth+code" and callback_error == nil)
local denied_code, denied_error = auth.parse_callback(
  "GET /callback?error_description=Access%20denied HTTP/1.1")
check("A22 loopback callback parser exposes OAuth denial",
  denied_code == nil and denied_error == "Access denied")

local listener = { accepted = false, closed = false }
function listener:bind(host, port) self.host, self.port = host, port; return true end
function listener:listen() return true end
function listener:settimeout(value) self.timeout = value end
function listener:close() self.closed = true end
function listener:accept()
  if self.accepted then return nil, "timeout" end
  self.accepted = true
  local client = { sent = "" }
  function client:settimeout() end
  function client:receive() return "GET /callback?code=oauth-code HTTP/1.1" end
  function client:send(value) self.sent = value; return #value end
  function client:close() self.closed = true end
  return client
end
local fake_socket = { tcp = function() return listener end }
local begin = auth.begin_pkce({
  socket = fake_socket,
  gen_random = function() return "verifier-value" end,
  now = function() return 1000 end,
})
check("A23 PKCE login binds only the registered loopback callback",
  begin.status == "waiting" and listener.host == "127.0.0.1"
    and listener.port == 53789 and listener.timeout == 0)
check("A24 PKCE login returns only the authorize URL",
  begin.authUrl and begin.authUrl:find("code_challenge=verifier%-value")
    and begin.verifier == nil)

local oauth_request, oauth_saved
local oauth_done = auth.poll_pkce({
  now = function() return 1001 end,
  post = function(url, options)
    oauth_request = { url = url, options = options }
    return { status = 200, body = "oauth-session" }
  end,
  decode = function()
    return { access_token = "oauth-access", refresh_token = "oauth-refresh",
      expires_in = 3600, user = fixtures.session.user }
  end,
  encode = function(value)
    return (value.auth_code or "") .. ":" .. (value.code_verifier or "")
  end,
  save = function(value) oauth_saved = value; return true end,
})
check("A25 PKCE callback exchanges code and private verifier in backend",
  oauth_done.status == "done" and oauth_request
    and oauth_request.url:find("grant_type=pkce", 1, true)
    and oauth_request.options.data == "oauth-code:verifier-value")
check("A26 PKCE result exposes account but no tokens or verifier",
  oauth_done.account and oauth_done.account.displayName == "Lua User"
    and oauth_done.access_token == nil and oauth_done.refresh_token == nil
    and oauth_done.verifier == nil and oauth_saved.refresh_token == "oauth-refresh")
check("A27 completed PKCE listener is closed", listener.closed == true)

local pending_listener = { closed = false }
function pending_listener:bind() return true end
function pending_listener:listen() return true end
function pending_listener:settimeout() end
function pending_listener:close() self.closed = true end
auth.begin_pkce({
  socket = { tcp = function() return pending_listener end },
  gen_random = function() return "pending-verifier" end,
  now = function() return 2000 end,
})
local pending_cleared = auth.clear({ remove = function() return true end })
check("A28 logout cancels a pending Discord login listener",
  pending_cleared.success == true and pending_listener.closed == true)

local expired_removed = 0
local expired_status = auth.status({
  load = function()
    return { access_token = "expired", refresh_token = "revoked", expires_at = 0 }
  end,
  post = function() return { status = 401, body = "{}" } end,
  encode = function() return "{}" end,
  remove = function() expired_removed = expired_removed + 1; return true end,
  now = function() return 3000 end,
})
check("A29 status immediately relocks a revoked lua.tools session",
  expired_status.success == true and expired_status.configured == false
    and expired_status.errorCode == "session_expired" and expired_removed == 1)

local adopted_request, adopted_saved
local adopted = auth.sign_in_with_session('{"refresh_token":"manual-refresh"}', {
  decode = function(body)
    if body == '{"refresh_token":"manual-refresh"}' then
      return { refresh_token = "manual-refresh" }
    end
    return { access_token = "adopted-access", refresh_token = "adopted-refresh",
      expires_in = 3600, user = fixtures.session.user }
  end,
  encode = function(value) return value.refresh_token or "{}" end,
  post = function(url, options)
    adopted_request = { url = url, options = options }
    return { status = 200, body = "adopted-session" }
  end,
  save = function(value) adopted_saved = value; return true end,
  now = function() return 4000 end,
})
check("A30 advanced session adoption verifies through Supabase refresh",
  adopted.success == true and adopted.configured == true
    and adopted_request.url:find("grant_type=refresh_token", 1, true)
    and adopted_request.options.data == "manual-refresh")
check("A31 adopted session is rotated and stored without exposing secrets",
  adopted_saved.refresh_token == "adopted-refresh" and adopted_saved.expires_at == 7600
    and adopted.access_token == nil and adopted.refresh_token == nil)

local cookie_adopted = auth.sign_in_with_session(
  "Cookie: sb-project-auth-token=base64-cookie-json; other=value", {
    decode = function(body)
      if body == "cookie-json" then return { refresh_token = "cookie-refresh" } end
      return { access_token = "cookie-access", refresh_token = "cookie-rotated",
        expires_in = 3600, user = fixtures.session.user }
    end,
    encode = function(value) return value.refresh_token or "{}" end,
    post = function() return { status = 200, body = "cookie-session" } end,
    save = function() return true end,
    now = function() return 5000 end,
  })
check("A32 a pasted Supabase auth cookie is accepted as the advanced fallback",
  cookie_adopted.success == true and cookie_adopted.configured == true)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS AUTH CHECKS PASSED")
