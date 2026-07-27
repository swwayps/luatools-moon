local fs = require("fs")
local m_utils = require("utils")
local cjson = require("json")
local paths = require("paths")

local auth = {}
local CREDENTIAL_FILE = paths.backend_path("data/ryuu_auth.json")

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Accept what DevTools commonly copies: a complete `Cookie:` line, the Cookie
-- value, `session=...`, an X-Auth-Key line, or a raw API key. Only the Ryuu
-- session value survives normalization; unrelated browser cookies are dropped.
function auth.normalize(input)
  input = trim(input)
  if input == "" then return nil, "Enter a Ryuu session cookie or auth key." end
  if #input > 8192 then return nil, "The Ryuu credential is too long." end
  if input:find("[\r\n]") then
    return nil, "Paste only the Cookie or X-Auth-Key line, not multiple headers."
  end

  local header_name, header_value = input:match("^([%w%-]+)%s*:%s*(.-)%s*$")
  local is_cookie_header = header_name and header_name:lower() == "cookie"
  if is_cookie_header then
    input = header_value
  elseif header_name and header_name:lower() == "x-auth-key" then
    local value = trim(header_value)
    if value == "" then return nil, "The Ryuu auth key is empty." end
    return {kind = "key", value = value}
  elseif header_name then
    return nil, "Paste the Cookie or X-Auth-Key request header."
  end

  local session_value
  for part in input:gmatch("[^;]+") do
    local name, value = part:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
    if name and trim(name):lower() == "session" then
      session_value = trim(value)
      break
    end
  end
  if session_value ~= nil then
    if session_value == "" then return nil, "The Ryuu session cookie is empty." end
    return {kind = "session", value = session_value}
  end

  if is_cookie_header or input:find(";", 1, true) then
    return nil, "The copied Cookie header does not contain session=."
  end

  return {kind = "key", value = input}
end

function auth.header_line(credential)
  if type(credential) ~= "table" then return nil end
  local value = trim(credential.value)
  if value == "" or value:find("[\r\n]") then return nil end
  if credential.kind == "session" then
    return "Cookie: session=" .. value .. "\n"
  end
  if credential.kind == "key" then
    return "X-Auth-Key: " .. value .. "\n"
  end
  return nil
end

local function load_default()
  local raw = m_utils.read_file(CREDENTIAL_FILE)
  if not raw or raw == "" then return nil end
  local ok, decoded = pcall(cjson.decode, raw)
  if not ok or not auth.header_line(decoded) then return nil end
  return decoded
end

-- Staging path for one write. It must be UNIQUE: with a fixed name a second
-- writer (a stale sidecar, or another Steam session) deletes this one's staging
-- file between the write and the readback, and a perfectly good session is then
-- reported as unsaveable. It must also sit NEXT TO the credential so os.rename
-- stays an atomic same-filesystem move.
local temp_seq = 0
function auth.temp_path()
  temp_seq = temp_seq + 1
  local salt = tostring({}):match("0x(%x+)") or tostring(math.random(1000000000))
  return CREDENTIAL_FILE .. "." .. os.time() .. "." .. temp_seq .. "." .. salt .. ".tmp"
end

local function save_default(credential)
  local dir = fs.parent_path(CREDENTIAL_FILE)
  if not fs.exists(dir) and fs.create_directories(dir) == false then return false end
  local ok, encoded = pcall(cjson.encode, credential)
  if not ok then return false end

  local temp_path = auth.temp_path()
  local write_ok, write_result = pcall(m_utils.write_file, temp_path, encoded)
  if not write_ok or write_result == false then
    pcall(os.remove, temp_path)
    return false
  end
  m_utils.exec("chmod 600 " .. shell_quote(temp_path))
  local verify_ok, verified = pcall(cjson.decode, m_utils.read_file(temp_path) or "")
  if not verify_ok or not auth.header_line(verified) then
    pcall(os.remove, temp_path)
    return false
  end
  if not os.rename(temp_path, CREDENTIAL_FILE) then
    pcall(os.remove, temp_path)
    return false
  end
  m_utils.exec("chmod 600 " .. shell_quote(CREDENTIAL_FILE))
  return true
end

local function remove_default()
  -- Staging files are unique per write and always renamed or removed by the
  -- writer, so clearing must not touch another writer's in-flight file.
  local ok, err = os.remove(CREDENTIAL_FILE)
  return ok == true or err == nil or not fs.exists(CREDENTIAL_FILE)
end

-- Verify a candidate session against Ryuu itself. HEAD /fixes answers 200 for a
-- signed-in session and 302 (-> /login) otherwise, with no body transferred.
-- Ryuu hands out an anonymous session cookie before the Discord sign-in (it
-- carries the OAuth state), so possession of a cookie proves nothing: only this
-- probe does. The secret goes through a chmod-600 header file, never argv.
local PROBE_URL = "https://generator.ryuu.lol/fixes"
local PROBE_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
  .. "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

local function probe_default(session)
  local header_path = CREDENTIAL_FILE .. ".probe"
  pcall(os.remove, header_path)
  local ok, written = pcall(m_utils.write_file, header_path,
    "Cookie: session=" .. session .. "\n")
  if not ok or written == false then return nil end
  m_utils.exec("chmod 600 " .. shell_quote(header_path))
  local cmd = "curl -s -I -o /dev/null -w '%{http_code}' --max-time 20"
    .. " -A " .. shell_quote(PROBE_UA)
    .. " --header @" .. shell_quote(header_path)
    .. " " .. shell_quote(PROBE_URL)
  local out = m_utils.exec(cmd)
  pcall(os.remove, header_path)
  return trim(out):match("(%d%d%d)%s*$")
end

local function resolve_deps(deps)
  deps = deps or {}
  return {
    load = deps.load or load_default,
    save = deps.save or save_default,
    remove = deps.remove or remove_default,
    probe = deps.probe or probe_default,
  }
end

-- adopt(input): validate a candidate credential against Ryuu and store it only
-- if the probe proves the session is signed in. Used by the in-client login
-- flow, which reads whatever cookie Steam's browser currently holds.
function auth.adopt(input, deps)
  local credential, err = auth.normalize(input)
  if not credential then return nil, err end
  local io = resolve_deps(deps)
  local code = io.probe(credential.value)
  if code ~= "200" then
    return nil, "Ryuu did not accept this session yet. Sign in on the page that opened."
  end
  if io.save(credential) ~= true then
    return nil, "Could not save Ryuu authentication."
  end
  return {configured = true, kind = credential.kind}
end

-- Same as adopt(), for a raw cookie value read straight out of Steam's cookie
-- jar. A bare value has no "session=" prefix, so normalize() would classify it
-- as an auth key; force the session shape before validating.
function auth.adopt_session_value(value, deps)
  value = trim(value)
  if value == "" then return nil, "Enter a Ryuu session cookie or auth key." end
  if value:find("[\r\n;]") then return nil, "The Ryuu session cookie is malformed." end
  return auth.adopt("session=" .. value, deps)
end

function auth.save(input, deps)
  local credential, err = auth.normalize(input)
  if not credential then return nil, err end
  local io = resolve_deps(deps)
  if io.save(credential) ~= true then
    return nil, "Could not save Ryuu authentication."
  end
  return {configured = true, kind = credential.kind}
end

function auth.status(deps)
  local credential = resolve_deps(deps).load()
  if not auth.header_line(credential) then return {configured = false} end
  return {configured = true, kind = credential.kind}
end

function auth.get_header_line(deps)
  return auth.header_line(resolve_deps(deps).load())
end

function auth.clear(deps)
  return resolve_deps(deps).remove() == true
end

return auth
