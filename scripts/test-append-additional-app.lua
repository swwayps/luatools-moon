#!/usr/bin/env luajit
-- Smoke test for platform.append_additional_app.
-- Builds a few synthetic config.yaml shapes, exercises the appender,
-- asserts the output is what SLSsteam's yaml-cpp will parse back as
-- the expected list, byte-preserving for everything else.

package.path = "linux/backend/?.lua;" .. package.path

-- Override HOME so find_slsteam_config picks up our temp tree.
local tmpdir = os.tmpname() .. "_dir"
os.execute("mkdir -p '" .. tmpdir .. "/.config/SLSsteam'")
os.getenv = (function(orig)
  return function(name)
    if name == "HOME" then return tmpdir end
    return orig(name)
  end
end)(os.getenv)

local platform = require("platform")
local cfg_path = tmpdir .. "/.config/SLSsteam/config.yaml"

local function write(content)
  local f = assert(io.open(cfg_path, "wb"))
  f:write(content); f:close()
end

local function read()
  local f = assert(io.open(cfg_path, "rb"))
  local s = f:read("*a"); f:close()
  return s
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    io.stderr:write("FAIL " .. label .. "\n")
    io.stderr:write("--- expected ---\n" .. tostring(expected) .. "\n")
    io.stderr:write("--- actual   ---\n" .. tostring(actual) .. "\n")
    os.exit(1)
  else
    io.write("ok " .. label .. "\n")
  end
end

-- Case 1: empty AdditionalApps block.
write([[
DisableFamilyShareLock: yes

AdditionalApps:

DlcData:
]])
local ok, msg = platform.append_additional_app(367520, "Hollow Knight")
assert(ok, "case1 returned false: " .. tostring(msg))
assert_eq(msg, "added", "case1 returns added")
assert_eq(read(), [[
DisableFamilyShareLock: yes

AdditionalApps:
  - 367520   # Hollow Knight

DlcData:
]], "case1 file content")

-- Case 2: existing entries, idempotent on duplicate.
write([[
AdditionalApps:
  - 413150   # Stardew Valley
  - 489830   # Skyrim AE

PlayNotOwnedGames: yes
]])
ok, msg = platform.append_additional_app(413150, "anything")
assert(ok, "case2 dup returned false")
assert_eq(msg, "already_present", "case2 dup is no-op")
assert_eq(read(), [[
AdditionalApps:
  - 413150   # Stardew Valley
  - 489830   # Skyrim AE

PlayNotOwnedGames: yes
]], "case2 file unchanged on dup")

-- Case 3: existing entries, append after them.
ok, msg = platform.append_additional_app(367520, "Hollow Knight")
assert(ok, "case3 returned false")
assert_eq(msg, "added", "case3 returns added")
assert_eq(read(), [[
AdditionalApps:
  - 413150   # Stardew Valley
  - 489830   # Skyrim AE
  - 367520   # Hollow Knight

PlayNotOwnedGames: yes
]], "case3 file content")

-- Case 4: existing entries with a comment between them.
write([[
AdditionalApps:
  - 413150   # Stardew Valley
  # this is a stray user comment
  - 489830   # Skyrim AE
]])
ok, msg = platform.append_additional_app(367520, nil)
assert(ok, "case4 returned false")
assert_eq(msg, "added", "case4 returns added")
assert_eq(read(), [[
AdditionalApps:
  - 413150   # Stardew Valley
  # this is a stray user comment
  - 489830   # Skyrim AE
  - 367520
]], "case4 file content (no comment passed)")

-- Case 5: tab indentation refused via fallback to two-space (we just
-- preserve whatever indent the existing entries used).
write([[
AdditionalApps:
    - 1
    - 2
]])
ok, msg = platform.append_additional_app(3, "three")
assert(ok, "case5 returned false")
assert_eq(read(), [[
AdditionalApps:
    - 1
    - 2
    - 3   # three
]], "case5 preserves wider indent")

-- Case 6: inline list refused, untouched.
write([[
AdditionalApps: [1, 2, 3]
PlayNotOwnedGames: yes
]])
ok, msg = platform.append_additional_app(4, "four")
assert(not ok, "case6 should refuse inline")
assert_eq(read(), [[
AdditionalApps: [1, 2, 3]
PlayNotOwnedGames: yes
]], "case6 file untouched on refusal")

-- Case 7: missing key.
write([[
DisableFamilyShareLock: yes
PlayNotOwnedGames: yes
]])
ok, msg = platform.append_additional_app(5, "five")
assert(not ok, "case7 should refuse when key missing")

-- Case 8: missing config file.
os.remove(cfg_path)
ok, msg = platform.append_additional_app(6, "six")
assert(not ok, "case8 should refuse when config missing")

os.execute("rm -rf '" .. tmpdir .. "'")
io.write("\nALL TESTS OK\n")
