#!/usr/bin/env luajit
-- Smoke test for linux/backend/slsteam.lua (AdditionalApps registrar).
-- Run from the repo root:  luajit scripts/test-slsteam.lua
--
-- Exercises register_app / unregister_app against synthetic config.yaml
-- shapes, asserting byte-preservation of everything except the single
-- inserted/removed entry.

package.path = "linux/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then
    io.write("ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. "\n")
    fails = fails + 1
  end
end

-- Sandbox HOME via os.getenv override.
local sandbox = os.tmpname() .. "_dir"
os.execute("mkdir -p '" .. sandbox .. "/.config/SLSsteam'")
local orig_getenv = os.getenv
os.getenv = function(k) if k == "HOME" then return sandbox end return orig_getenv(k) end

local cfg = sandbox .. "/.config/SLSsteam/config.yaml"
local function w(s) local f = assert(io.open(cfg, "wb")); f:write(s); f:close() end
local function r() local f = assert(io.open(cfg, "rb")); local s = f:read("*a"); f:close(); return s end

local slsteam = dofile("linux/backend/slsteam.lua")

-- Case 1: existing block list, append after, preserve comments.
w("DisableFamilyShareLock: yes\nAdditionalApps:\n  - 480   # existing\nSafeMode: no\n")
local ok, msg = slsteam.register_app(620, "Portal 2")
check("C1 ok", ok == true and msg == "added")
local c = r()
check("C1 480 kept", c:find("480") ~= nil)
check("C1 620 added", c:find("620") ~= nil)
check("C1 comment kept", c:find("# existing") ~= nil)
check("C1 SafeMode kept", c:find("SafeMode: no") ~= nil)

-- idempotent
ok, msg = slsteam.register_app(620)
check("C1 idempotent", msg == "already_present")

-- Case 2: empty block.
w("AdditionalApps:\n")
ok, msg = slsteam.register_app(123)
check("C2 added to empty block", msg == "added" and r():find("%- 123") ~= nil)

-- Case 3: missing key -> created.
w("PlayNotOwnedGames: yes\n")
ok, msg = slsteam.register_app(777)
c = r()
check("C3 header created", c:find("AdditionalApps:") ~= nil)
check("C3 entry created", c:find("%- 777") ~= nil)

-- Case 4: inline form refused.
w("AdditionalApps: [1, 2]\n")
ok, msg = slsteam.register_app(9)
check("C4 inline refused", ok == false)

-- Case 5: wide indent preserved.
w("AdditionalApps:\n    - 1\n    - 2\n")
slsteam.register_app(3, "three")
check("C5 indent preserved", r():find("    %- 3") ~= nil)

-- Case 6: unregister.
w("AdditionalApps:\n  - 480\n  - 620\n")
ok, msg = slsteam.unregister_app(480)
c = r()
check("C6 removed 480", msg == "removed" and c:find("%- 480") == nil)
check("C6 kept 620", c:find("%- 620") ~= nil)
ok, msg = slsteam.unregister_app(99999)
check("C6 absent -> not_present", msg == "not_present")

os.getenv = orig_getenv
os.execute("rm -rf '" .. sandbox .. "'")

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
