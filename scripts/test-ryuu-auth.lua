#!/usr/bin/env luajit
-- Ryuu credentials are bearer secrets. Exercise the real normalization and
-- storage boundary without ever putting a live credential in a test fixture.

package.loaded.fs = {
  parent_path = function() return "/tmp" end,
  exists = function() return false end,
  create_directories = function() return true end,
}
package.loaded.utils = {
  read_file = function() return nil end,
  write_file = function() return true end,
  exec = function() return "", true end,
}
package.loaded.json = {
  encode = function() return "{}" end,
  decode = function() return {} end,
}
package.loaded.paths = {backend_path = function() return "/tmp/ryuu_auth.json" end}

local auth = dofile("plugin/backend/ryuu_auth.lua")
local failures = 0

local function check(name, condition)
  if condition then
    print("ok   " .. name)
  else
    print("FAIL " .. name)
    failures = failures + 1
  end
end

local full = auth.normalize("Cookie: theme=dark; session=.signed.session; locale=pt-BR")
check("R1 full Cookie header keeps only session", full and full.kind == "session"
  and full.value == ".signed.session")

local pair = auth.normalize("session=.another.session; theme=dark")
check("R2 Cookie value keeps only session", pair and pair.kind == "session"
  and pair.value == ".another.session")

local direct = auth.normalize("X-Auth-Key: api-secret")
check("R3 explicit X-Auth-Key header is accepted", direct and direct.kind == "key"
  and direct.value == "api-secret")

local raw_key = auth.normalize("api-secret")
check("R4 raw auth key is accepted", raw_key and raw_key.kind == "key"
  and raw_key.value == "api-secret")

local missing, missing_err = auth.normalize("Cookie: theme=dark; locale=pt-BR")
check("R5 Cookie without session is rejected", missing == nil
  and tostring(missing_err):lower():find("session", 1, true) ~= nil)

local injected = auth.normalize("session=good\nX-Evil: injected")
check("R6 multiline header paste is rejected", injected == nil)

check("R7 session becomes a Cookie request header",
  auth.header_line({kind = "session", value = ".signed.session"})
    == "Cookie: session=.signed.session\n")
check("R8 key becomes an X-Auth-Key request header",
  auth.header_line({kind = "key", value = "api-secret"})
    == "X-Auth-Key: api-secret\n")

local stored
local deps = {
  load = function() return stored end,
  save = function(value) stored = value; return true end,
  remove = function() stored = nil; return true end,
}

local saved = auth.save("Cookie: other=discard; session=.stored.session", deps)
check("R9 save persists only normalized session", saved and stored
  and stored.kind == "session" and stored.value == ".stored.session")
local status = auth.status(deps)
check("R10 status never returns the secret", status.configured == true
  and status.kind == "session" and status.value == nil)
check("R11 stored session can produce a downloader header",
  auth.get_header_line(deps) == "Cookie: session=.stored.session\n")
check("R12 clear removes the stored credential", auth.clear(deps) == true
  and auth.status(deps).configured == false)

-- The staging file must be unique per write. A fixed name lets two writers (a
-- second Steam session, or a stale sidecar) delete each other's staging file
-- mid-write: the readback then finds nothing and a perfectly good session is
-- reported as "Could not save Ryuu authentication."
local seen_temp = {}
for _ = 1, 50 do
  local path = auth.temp_path()
  if seen_temp[path] then
    print("FAIL R22 staging path is reused across writes")
    failures = failures + 1
    break
  end
  seen_temp[path] = true
end
check("R22 staging path is unique per write", failures == 0)
check("R23 staging path sits next to the credential (same filesystem, atomic rename)",
  auth.temp_path():find("^/tmp/ryuu_auth%.json%.") ~= nil)
check("R24 staging path is not the credential itself",
  auth.temp_path() ~= "/tmp/ryuu_auth.json")

-- adopt(): the in-client login hands over whatever cookie the Steam browser
-- holds. Ryuu issues an anonymous session BEFORE the Discord sign-in, so a
-- cookie is not proof of access: only a verified probe may be stored.
local probed
local function probe_deps(code)
  return {
    load = function() return stored end,
    save = function(value) stored = value; return true end,
    remove = function() stored = nil; return true end,
    probe = function(session) probed = session; return code end,
  }
end

stored, probed = nil, nil
local adopted, adopt_err = auth.adopt(".anonymous.session", probe_deps("302"))
check("R13 unverified session is refused", adopted == nil and stored == nil)
check("R14 refusal explains the sign-in is missing",
  tostring(adopt_err):lower():find("sign in", 1, true) ~= nil
    or tostring(adopt_err):lower():find("log in", 1, true) ~= nil)
check("R15 refusal still probed the candidate", probed == ".anonymous.session")

stored, probed = nil, nil
local ok_adopt = auth.adopt("session=.signed.in.session", probe_deps("200"))
check("R16 verified session is stored", ok_adopt and ok_adopt.configured == true
  and stored and stored.kind == "session" and stored.value == ".signed.in.session")
check("R17 adopt never returns the secret", ok_adopt.value == nil)

stored, probed = nil, nil
local blank = auth.adopt("", probe_deps("200"))
check("R18 empty candidate never reaches the network", blank == nil and probed == nil)

stored, probed = nil, nil
local bad = auth.adopt(".session\nX-Evil: 1", probe_deps("200"))
check("R19 malformed candidate never reaches the network", bad == nil and probed == nil)

-- A cookie read out of Steam's jar is a bare value, not a header line.
local bare = auth.normalize(".bare.jar.value")
check("R20 a bare session value is not mistaken for a cookie line",
  bare and bare.kind == "key")
stored, probed = nil, nil
local jar = auth.adopt_session_value(".bare.jar.value", probe_deps("200"))
check("R21 adopt_session_value stores it as a session cookie",
  jar and stored and stored.kind == "session" and stored.value == ".bare.jar.value")

if failures > 0 then os.exit(1) end
print("ALL RYUU AUTH CHECKS PASSED")
