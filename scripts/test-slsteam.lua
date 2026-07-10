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

-- Case 7: ZERO-indent list ("- 480" flush-left, valid YAML). Regression for
-- config_parse_abort_analysis.md: the new entry MUST match the existing 0
-- indentation. The old %s+ matcher broke the scan on the first item, so the
-- entry was inserted at the fallback 2-space indent right after the header ->
-- mixed indentation, which yaml-cpp rejects and can brick Steam at startup.
w("AdditionalApps:\n- 480\n- 620\nSafeMode: no\n")
ok, msg = slsteam.register_app(700, "added via LuaTools")
c = r()
check("C7 added", ok == true and msg == "added")
check("C7 new entry at 0 indent", c:find("\n%- 700") ~= nil)
check("C7 no mixed 2-space indent", c:find("  %- 700") == nil)
check("C7 existing kept", c:find("\n%- 480") ~= nil and c:find("\n%- 620") ~= nil)
check("C7 SafeMode kept", c:find("SafeMode: no") ~= nil)
-- idempotent on a zero-indent existing id
ok, msg = slsteam.register_app(480)
check("C7 idempotent on 0-indent id", msg == "already_present")

-- Case 8: unregister from a ZERO-indent list.
w("AdditionalApps:\n- 480\n- 620\nSafeMode: no\n")
ok, msg = slsteam.unregister_app(480)
c = r()
check("C8 removed 480", msg == "removed" and c:find("\n%- 480") == nil)
check("C8 kept 620", c:find("\n%- 620") ~= nil)

-- ---------------------------------------------------------------------------
-- FakeAppIds map editor: set_fake_appid / unset_fake_appid.
-- FakeAppIds is a MAP block ("FakeAppIds:" then "  <appid>: <fake>" lines),
-- unlike AdditionalApps which is a LIST. Default fake = 480 (Spacewar).
-- ---------------------------------------------------------------------------

-- F1: insert into an empty FakeAppIds block (default config shape), preserving
-- the following top-level key.
w("DisableFamilyShareLock: yes\nFakeAppIds:\nIdleStatus:\n  AppId: 0\n")
ok, msg = slsteam.set_fake_appid(285900)
check("F1 added", ok == true and msg == "added")
c = r()
check("F1 mapping written", c:find("285900:%s*480") ~= nil)
check("F1 IdleStatus preserved", c:find("IdleStatus:") ~= nil)
check("F1 AppId line preserved", c:find("  AppId: 0") ~= nil)

-- F1 idempotent: same appid+value already present.
ok, msg = slsteam.set_fake_appid(285900, 480)
check("F1 idempotent", ok == true and msg == "already_present")

-- F2: update an existing mapping's value in place (no duplicate line).
ok, msg = slsteam.set_fake_appid(285900, 481)
check("F2 updated", ok == true and msg == "updated")
c = r()
check("F2 new value", c:find("285900:%s*481") ~= nil)
check("F2 old value gone", c:find("285900:%s*480") == nil)
local _, n285 = c:gsub("285900%s*:", "")
check("F2 single mapping line", n285 == 1)

-- F3: header absent -> created with the entry.
w("PlayNotOwnedGames: yes\n")
ok, msg = slsteam.set_fake_appid(620)
c = r()
check("F3 header created", c:find("FakeAppIds:") ~= nil)
check("F3 entry created", c:find("620:%s*480") ~= nil)

-- F4: inline form refused (don't risk corrupting it).
w("FakeAppIds: {1: 2}\n")
ok, msg = slsteam.set_fake_appid(9)
check("F4 inline refused", ok == false)

-- F5: preserve comments + a sibling mapping while adding another.
w("FakeAppIds:\n  730: 480   # existing\nSafeMode: no\n")
ok, msg = slsteam.set_fake_appid(440)
c = r()
check("F5 730 kept", c:find("730:%s*480") ~= nil)
check("F5 comment kept", c:find("# existing") ~= nil)
check("F5 440 added", c:find("440:%s*480") ~= nil)
check("F5 SafeMode kept", c:find("SafeMode: no") ~= nil)

-- F6: wide indent preserved on insert.
w("FakeAppIds:\n    111: 480\n")
slsteam.set_fake_appid(222)
check("F6 indent preserved", r():find("    222:%s*480") ~= nil)

-- F7: unset removes the mapping; absent -> not_present.
w("FakeAppIds:\n  285900: 480\n  620: 480\n")
ok, msg = slsteam.unset_fake_appid(285900)
c = r()
check("F7 removed 285900", ok == true and msg == "removed" and c:find("285900") == nil)
check("F7 kept 620", c:find("620:%s*480") ~= nil)
ok, msg = slsteam.unset_fake_appid(99999)
check("F7 absent -> not_present", ok == true and msg == "not_present")

-- ---------------------------------------------------------------------------
-- ManifestPins purge: purge_pins_for_app removes one app's nested pin block.
-- ManifestPins is a nested map: "ManifestPins:" -> "  <appid>:" -> { locked:, depots: { <depot>: gid } }.
-- ---------------------------------------------------------------------------

-- P1: two pinned apps; purge one keeps the other + the header + sibling keys.
w(table.concat({
  "AdditionalApps:",
  "  - 1054490",
  "ManifestPins:",
  "  1054490:",
  "    locked: true",
  "    depots:",
  '      1054491: "111"',
  "  285900:",
  "    locked: false",
  "    depots:",
  '      285904: "222"',
  "LogLevel: 2",
  "",
}, "\n"))
ok, msg = slsteam.purge_pins_for_app(1054490)
c = r()
check("P1 removed", ok == true and msg == "removed")
check("P1 target block gone", c:find("1054490:") == nil and c:find('1054491: "111"') == nil)
check("P1 other app kept", c:find("285900:") ~= nil and c:find('285904: "222"') ~= nil)
check("P1 header kept", c:find("ManifestPins:") ~= nil)
check("P1 AdditionalApps kept", c:find("  %- 1054490") ~= nil)
check("P1 LogLevel kept", c:find("LogLevel: 2") ~= nil)

-- P2: purging the last pinned app removes the ManifestPins header too.
w(table.concat({
  "ManifestPins:",
  "  285900:",
  "    locked: false",
  "    depots:",
  '      285904: "222"',
  "LogLevel: 2",
  "",
}, "\n"))
ok, msg = slsteam.purge_pins_for_app(285900)
c = r()
check("P2 removed", ok == true and msg == "removed")
check("P2 header gone when empty", c:find("ManifestPins:") == nil)
check("P2 sibling key kept", c:find("LogLevel: 2") ~= nil)

-- P3: appid not pinned -> not_present, file unchanged.
w("ManifestPins:\n  111:\n    locked: true\n    depots:\n      112: \"9\"\n")
ok, msg = slsteam.purge_pins_for_app(999)
c = r()
check("P3 not_present", ok == true and msg == "not_present")
check("P3 unchanged", c:find("111:") ~= nil and c:find('112: "9"') ~= nil)

-- P4: no ManifestPins block at all -> not_present.
w("AdditionalApps:\n  - 1\n")
ok, msg = slsteam.purge_pins_for_app(1)
check("P4 no block -> not_present", ok == true and msg == "not_present")

os.getenv = orig_getenv
os.execute("rm -rf '" .. sandbox .. "'")

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
