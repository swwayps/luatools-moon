local cjson = require("json")
local http_client = require("http_client")
local fs = require("fs")
local m_utils = require("utils")
local paths = require("paths")
local sha256 = require("sha256")
local b64 = require("b64")

local auth = {}

local API_BASE_URL = "https://lua.tools"
local SUPABASE_URL = "https://db.lua.tools"
local SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
  .. "eyJpYXQiOjE3NzYwMzkzNzYsImV4cCI6MTg5MzQ1NjAwMCwicm9sZSI6ImFub24iLCJpc3MiOiJzdXBhYmFzZSJ9."
  .. "f_-K38u3odjltP-g_67FVmG32Vg-_-k-lNBvIaVUVBM"
local SESSION_FILE = paths.backend_path("data/lua_tools_auth.json")
local OAUTH_CALLBACK = "http://localhost:53789/callback"
local OAUTH_TIMEOUT = 5 * 60

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local write_seq = 0
local function save_default(session)
  if type(session) ~= "table" or type(session.access_token) ~= "string"
      or type(session.refresh_token) ~= "string" then return false end
  local parent = fs.parent_path(SESSION_FILE)
  if not fs.exists(parent) and fs.create_directories(parent) == false then return false end
  local ok_encode, encoded = pcall(cjson.encode, session)
  if not ok_encode then return false end
  write_seq = write_seq + 1
  local temp = SESSION_FILE .. "." .. tostring(os.time()) .. "." .. tostring(write_seq) .. ".tmp"
  local ok_write, written = pcall(m_utils.write_file, temp, encoded)
  if not ok_write or written == false then pcall(os.remove, temp); return false end
  m_utils.exec("chmod 600 -- " .. shell_quote(temp))
  if not os.rename(temp, SESSION_FILE) then pcall(os.remove, temp); return false end
  m_utils.exec("chmod 600 -- " .. shell_quote(SESSION_FILE))
  return true
end

local function load_default()
  local raw = m_utils.read_file(SESSION_FILE)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, session = pcall(cjson.decode, raw)
  if not ok or type(session) ~= "table"
      or type(session.access_token) ~= "string" or session.access_token == ""
      or type(session.refresh_token) ~= "string" or session.refresh_token == "" then
    return nil
  end
  return session
end

local function remove_default()
  local ok, err = os.remove(SESSION_FILE)
  return ok == true or err == nil or not fs.exists(SESSION_FILE)
end

function auth.normalize_code(value)
  value = tostring(value or ""):match("^%s*(.-)%s*$") or ""
  value = value:upper()
  if not value:match("^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") then
    return nil, "Enter the six-character lua.tools login code."
  end
  return value
end

local function resolve_deps(deps)
  deps = deps or {}
  return {
    post = deps.post or http_client.post,
    decode = deps.decode or cjson.decode,
    encode = deps.encode or cjson.encode,
    load = deps.load or load_default,
    save = deps.save or save_default,
    remove = deps.remove or remove_default,
    now = deps.now or os.time,
  }
end

local function base64url(value)
  return (b64.encode(value):gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

local function urlencode(value)
  return (tostring(value or ""):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

local function urldecode(value)
  value = tostring(value or ""):gsub("+", " ")
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

function auth.build_authorize_url(redirect_uri, challenge)
  return SUPABASE_URL .. "/auth/v1/authorize?provider=discord"
    .. "&redirect_to=" .. urlencode(redirect_uri)
    .. "&code_challenge=" .. urlencode(challenge)
    .. "&code_challenge_method=s256"
end

function auth.parse_callback(request_line)
  local query = tostring(request_line or ""):match("%s/[^%s%?]*%?([^%s]*)%s")
    or tostring(request_line or ""):match("%s/[^%s%?]*%?([^%s]*)")
  if not query then return nil, "The lua.tools callback did not contain a login result." end
  local params = {}
  for key, value in query:gmatch("([^&=]+)=([^&]*)") do
    params[urldecode(key)] = urldecode(value)
  end
  if type(params.code) == "string" and params.code ~= "" then
    return params.code
  end
  return nil, params.error_description or params.error or
    "Discord did not return a lua.tools login code."
end

local function account_from_session(session)
  local user = type(session.user) == "table" and session.user or {}
  local meta = type(user.user_metadata) == "table" and user.user_metadata or {}
  local claims = type(meta.custom_claims) == "table" and meta.custom_claims or {}
  local display_name = claims.global_name or meta.full_name or meta.name or user.email
  return {
    displayName = tostring(display_name or "lua.tools account"),
    avatarUrl = type(meta.avatar_url) == "string" and meta.avatar_url or "",
  }
end

local function public_status(session)
  return {
    success = true,
    configured = true,
    account = account_from_session(session),
  }
end

local close_pending = function() end

local function redeem_error(status)
  status = tonumber(status)
  if status == 400 or status == 404 then
    return "invalid_code", "That lua.tools login code is invalid."
  end
  if status == 410 then
    return "expired_code", "That lua.tools login code has expired or was already used."
  end
  if status == 429 then
    return "rate_limited", "Too many login attempts. Wait a moment and try again."
  end
  return "service_unavailable", "lua.tools login is temporarily unavailable."
end

function auth.sign_in_with_code(input, deps)
  local code, code_error = auth.normalize_code(input)
  if not code then
    return { success = false, errorCode = "invalid_code", error = code_error }
  end
  local d = resolve_deps(deps)
  local redeem = d.post(API_BASE_URL .. "/api/auth/code/redeem", {
    data = d.encode({ code = code }),
    headers = { ["Content-Type"] = "application/json" },
    timeout = 30,
  })
  if type(redeem) ~= "table" or tonumber(redeem.status) ~= 200 then
    local error_code, message = redeem_error(type(redeem) == "table" and redeem.status or nil)
    return { success = false, errorCode = error_code, error = message }
  end
  local ok_redeem, redeem_body = pcall(d.decode, redeem.body or "")
  if not ok_redeem or type(redeem_body) ~= "table"
      or type(redeem_body.token) ~= "string" or redeem_body.token == "" then
    return { success = false, errorCode = "invalid_response", error = "lua.tools returned an invalid login response." }
  end

  local verified = d.post(SUPABASE_URL .. "/auth/v1/verify", {
    data = d.encode({ type = "magiclink", token_hash = redeem_body.token }),
    headers = {
      ["Content-Type"] = "application/json",
      ["apikey"] = SUPABASE_ANON_KEY,
    },
    timeout = 30,
  })
  if type(verified) ~= "table" or tonumber(verified.status) ~= 200 then
    return { success = false, errorCode = "verification_failed", error = "lua.tools could not verify this login code." }
  end
  local ok_session, session = pcall(d.decode, verified.body or "")
  if not ok_session or type(session) ~= "table"
      or type(session.access_token) ~= "string" or session.access_token == ""
      or type(session.refresh_token) ~= "string" or session.refresh_token == "" then
    return { success = false, errorCode = "invalid_response", error = "lua.tools returned an invalid session." }
  end
  session.expires_at = d.now() + (tonumber(session.expires_in) or 3600)
  if type(d.save) ~= "function" or d.save(session) ~= true then
    return { success = false, errorCode = "storage_failed", error = "Could not save the lua.tools session." }
  end
  return public_status(session)
end

local function decode_session_input(input, decode)
  input = tostring(input or ""):match("^%s*(.-)%s*$") or ""
  if input == "" or #input > 65536 or input:find("[\r\n]%s*[^Cc]ookie:") then return nil end

  if not input:match("^%s*[%[{]") then
    local whole, chunks = nil, {}
    for name, value in input:gmatch("([%w_%-%.]+)=([^;%s]+)") do
      if name:match("^sb%-[%w%-]+%-auth%-token$") then
        whole = value
      else
        local index = name:match("^sb%-[%w%-]+%-auth%-token%.(%d+)$")
        if index then chunks[#chunks + 1] = { index = tonumber(index), value = value } end
      end
    end
    if not whole and #chunks > 0 then
      table.sort(chunks, function(left, right) return left.index < right.index end)
      local values = {}
      for _, chunk in ipairs(chunks) do values[#values + 1] = chunk.value end
      whole = table.concat(values)
    end
    input = whole or input:gsub("^%s*[Cc]ookie:%s*", "")
  end

  input = urldecode(input)
  if input:sub(1, 7) == "base64-" then
    local encoded = input:sub(8):gsub("-", "+"):gsub("_", "/")
    encoded = encoded .. string.rep("=", (4 - #encoded % 4) % 4)
    input = b64.decode(encoded)
  end
  if type(input) ~= "string" or input == "" then return nil end
  local ok, decoded = pcall(decode, input)
  if not ok or type(decoded) ~= "table" then return nil end
  local refresh_token = decoded.refresh_token
    or (type(decoded.currentSession) == "table" and decoded.currentSession.refresh_token)
    or decoded[2]
  if type(refresh_token) ~= "string" or refresh_token == "" or #refresh_token > 8192
      or refresh_token:find("[\r\n]") then return nil end
  return refresh_token
end

function auth.sign_in_with_session(input, deps)
  local d = resolve_deps(deps)
  local refresh_token = decode_session_input(input, d.decode)
  if not refresh_token then
    return { success = false, errorCode = "invalid_session",
      error = "Paste a complete lua.tools session cookie." }
  end
  local ok_post, response = pcall(d.post,
    SUPABASE_URL .. "/auth/v1/token?grant_type=refresh_token", {
      data = d.encode({ refresh_token = refresh_token }),
      headers = {
        ["Content-Type"] = "application/json",
        ["apikey"] = SUPABASE_ANON_KEY,
      },
      timeout = 30,
    })
  if not ok_post or type(response) ~= "table" or tonumber(response.status) ~= 200 then
    return { success = false, errorCode = "invalid_session",
      error = "lua.tools rejected this session. Copy a current auth cookie and try again." }
  end
  local ok_decode, session = pcall(d.decode, response.body or "")
  if not ok_decode or type(session) ~= "table"
      or type(session.access_token) ~= "string" or session.access_token == ""
      or type(session.refresh_token) ~= "string" or session.refresh_token == "" then
    return { success = false, errorCode = "invalid_response",
      error = "lua.tools returned an invalid session." }
  end
  session.expires_at = d.now() + (tonumber(session.expires_in) or 3600)
  if d.save(session) ~= true then
    return { success = false, errorCode = "storage_failed",
      error = "Could not save the lua.tools session." }
  end
  return public_status(session)
end

function auth.status(deps)
  local d = resolve_deps(deps)
  local session = d.load()
  if type(session) ~= "table" or type(session.refresh_token) ~= "string"
      or session.refresh_token == "" then
    return { success = true, configured = false }
  end
  if not tonumber(session.expires_at) or session.expires_at <= d.now() + 120 then
    local token, token_error = auth.get_valid_access_token(deps)
    if not token then
      return {
        success = true,
        configured = false,
        errorCode = type(token_error) == "table" and token_error.code or "session_expired",
        error = type(token_error) == "table" and token_error.message or nil,
      }
    end
    session = d.load() or session
  end
  return public_status(session)
end

function auth.clear(deps)
  close_pending()
  local d = resolve_deps(deps)
  if d.remove() ~= true then
    return { success = false, configured = true, error = "Could not remove the lua.tools session." }
  end
  return { success = true, configured = false }
end

function auth.get_valid_access_token(deps)
  local d = resolve_deps(deps)
  local session = d.load()
  if type(session) ~= "table" or type(session.refresh_token) ~= "string"
      or session.refresh_token == "" then
    return nil, { code = "not_signed_in", message = "Sign in to lua.tools first." }
  end
  if type(session.access_token) == "string" and session.access_token ~= ""
      and tonumber(session.expires_at) and session.expires_at > d.now() + 120 then
    return session.access_token
  end

  local ok_post, response = pcall(d.post,
    SUPABASE_URL .. "/auth/v1/token?grant_type=refresh_token", {
      data = d.encode({ refresh_token = session.refresh_token }),
      headers = {
        ["Content-Type"] = "application/json",
        ["apikey"] = SUPABASE_ANON_KEY,
      },
      timeout = 30,
    })
  if not ok_post or type(response) ~= "table" or tonumber(response.status) ~= 200 then
    d.remove()
    return nil, { code = "session_expired", message = "The lua.tools session expired. Sign in again." }
  end
  local ok_decode, refreshed = pcall(d.decode, response.body or "")
  if not ok_decode or type(refreshed) ~= "table"
      or type(refreshed.access_token) ~= "string" or refreshed.access_token == "" then
    d.remove()
    return nil, { code = "session_expired", message = "The lua.tools session could not be refreshed." }
  end
  refreshed.refresh_token = type(refreshed.refresh_token) == "string"
      and refreshed.refresh_token ~= "" and refreshed.refresh_token or session.refresh_token
  refreshed.user = type(refreshed.user) == "table" and refreshed.user or session.user
  refreshed.expires_at = d.now() + (tonumber(refreshed.expires_in) or 3600)
  if d.save(refreshed) ~= true then
    return nil, { code = "storage_failed", message = "Could not update the lua.tools session." }
  end
  return refreshed.access_token
end

local pending_pkce = nil

close_pending = function()
  if pending_pkce and pending_pkce.listener then
    pcall(function() pending_pkce.listener:close() end)
  end
  pending_pkce = nil
end

local function default_gen_random(length)
  local file = io.open("/dev/urandom", "rb")
  if not file then return nil end
  local bytes = file:read(length)
  file:close()
  if type(bytes) ~= "string" or #bytes ~= length then return nil end
  return base64url(bytes)
end

local CALLBACK_HTML =
  "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" ..
  "Cache-Control: no-store\r\nConnection: close\r\n\r\n" ..
  "<!doctype html><html><body style=\"font-family:sans-serif;text-align:center;" ..
  "padding:60px;background:#171d25;color:#fff\"><h1>Signed in to lua.tools</h1>" ..
  "<p>You can close this page and return to Steam.</p>" ..
  "<script>window.setTimeout(function(){window.close()},800)</script></body></html>"

function auth.begin_pkce(deps)
  deps = deps or {}
  close_pending()

  local socket = deps.socket
  if not socket then
    local ok_socket, loaded = pcall(require, "socket")
    if ok_socket then socket = loaded end
  end
  if type(socket) ~= "table" or type(socket.tcp) ~= "function" then
    return { status = "error", error = "The local lua.tools login listener is unavailable." }
  end

  local ok_listener, listener = pcall(socket.tcp)
  if not ok_listener or not listener then
    return { status = "error", error = "The local lua.tools login listener is unavailable." }
  end
  local bound, bind_error = listener:bind("127.0.0.1", 53789)
  if not bound then
    pcall(function() listener:close() end)
    return { status = "error", error = "Could not start lua.tools login: " .. tostring(bind_error) }
  end
  local listening, listen_error = listener:listen()
  if listening == nil or listening == false then
    pcall(function() listener:close() end)
    return { status = "error", error = "Could not start lua.tools login: " .. tostring(listen_error) }
  end
  listener:settimeout(0)

  local generate = deps.gen_random or default_gen_random
  local verifier = generate(64)
  if type(verifier) ~= "string" or #verifier < 8 then
    pcall(function() listener:close() end)
    return { status = "error", error = "Secure random generation is unavailable." }
  end
  local challenge = base64url(sha256.digest(verifier))
  pending_pkce = {
    listener = listener,
    verifier = verifier,
    redirect_uri = OAUTH_CALLBACK,
    deadline = (deps.now or os.time)() + OAUTH_TIMEOUT,
  }
  return {
    status = "waiting",
    authUrl = auth.build_authorize_url(OAUTH_CALLBACK, challenge),
  }
end

function auth.poll_pkce(deps)
  if not pending_pkce then return { status = "idle" } end
  deps = deps or {}
  local now = deps.now or os.time
  if now() > pending_pkce.deadline then
    close_pending()
    return { status = "timeout", error = "lua.tools login timed out." }
  end

  local client = pending_pkce.listener:accept()
  if not client then return { status = "waiting" } end
  client:settimeout(2)
  local request_line = client:receive("*l") or ""
  pcall(function() client:send(CALLBACK_HTML) end)
  pcall(function() client:close() end)

  local code, callback_error = auth.parse_callback(request_line)
  if not code then
    close_pending()
    return { status = "error", error = callback_error }
  end

  local d = resolve_deps(deps)
  local verifier = pending_pkce.verifier
  local ok_post, response = pcall(d.post,
    SUPABASE_URL .. "/auth/v1/token?grant_type=pkce", {
      data = d.encode({ auth_code = code, code_verifier = verifier }),
      headers = {
        ["Content-Type"] = "application/json",
        ["apikey"] = SUPABASE_ANON_KEY,
      },
      timeout = 30,
    })
  if not ok_post or type(response) ~= "table" or tonumber(response.status) ~= 200 then
    close_pending()
    return { status = "error", error = "lua.tools could not complete Discord login." }
  end
  local ok_decode, session = pcall(d.decode, response.body or "")
  if not ok_decode or type(session) ~= "table"
      or type(session.access_token) ~= "string" or session.access_token == ""
      or type(session.refresh_token) ~= "string" or session.refresh_token == "" then
    close_pending()
    return { status = "error", error = "lua.tools returned an invalid session." }
  end
  session.expires_at = now() + (tonumber(session.expires_in) or 3600)
  if d.save(session) ~= true then
    close_pending()
    return { status = "error", error = "Could not save the lua.tools session." }
  end
  local result = public_status(session)
  result.status = "done"
  close_pending()
  return result
end

function auth.cancel_pkce()
  close_pending()
  return { success = true, status = "idle" }
end

return auth
