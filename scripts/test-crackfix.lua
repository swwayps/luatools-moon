#!/usr/bin/env luajit
-- Unit tests for linux/backend/crackfix.lua (ryuu Crack/Bypass resolver).
--
-- crackfix.lua's logic helpers are PURE: url-encoding, picking the best entry
-- for an appid, the hypervisor guard, and looking an appid up in a decoded
-- index. check() is impure (fs + json + detached refresh) but accepts an
-- injectable `deps` so the dispatch can be tested without a filesystem.
--
-- Run from the repo root:  luajit scripts/test-crackfix.lua

package.path = "linux/backend/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, cond)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    io.stderr:write("FAIL: " .. name .. "\n")
  end
end

local cf = dofile("linux/backend/crackfix.lua")

-- ---------------------------------------------------------------------------
-- url_encode / build_url
-- ---------------------------------------------------------------------------
check("U1 spaces -> %20", cf.url_encode("A Way Out.zip") == "A%20Way%20Out.zip")
check("U2 dotted name untouched-ish",
  cf.url_encode("007.first.light-voices38.zip") == "007.first.light-voices38.zip")
check("U3 apostrophe encoded",
  cf.url_encode("Assassin's Creed.zip") == "Assassin%27s%20Creed.zip")
check("U4 ampersand encoded", cf.url_encode("Tom & Jerry.zip") == "Tom%20%26%20Jerry.zip")
check("U5 unreserved kept", cf.url_encode("a-b_c.d~e") == "a-b_c.d~e")
check("U6 build_url prefixes base",
  cf.build_url("A Way Out.zip") == "https://generator.ryuu.lol/fixes/A%20Way%20Out.zip")
check("U7 build_url nil on empty", cf.build_url("") == nil)

-- ---------------------------------------------------------------------------
-- is_hypervisor
-- ---------------------------------------------------------------------------
check("H1 badge hypervisor", cf.is_hypervisor({ file = "x.zip", badge = "hypervisor" }) == true)
check("H2 filename HYPERVISOR",
  cf.is_hypervisor({ file = "RE.Requiem.HYPERVISOR.zip", badge = "" }) == true)
check("H3 normal not hypervisor", cf.is_hypervisor({ file = "x.zip", badge = "bypass" }) == false)
check("H4 non-table -> false", cf.is_hypervisor("nope") == false)

-- ---------------------------------------------------------------------------
-- pick_entry: prefer bypass, skip hypervisor, else first in order
-- ---------------------------------------------------------------------------
do
  local e = cf.pick_entry({
    { file = "a.zip", badge = "tested" },
    { file = "b.zip", badge = "bypass" },
  })
  check("P1 prefers bypass", e and e.file == "b.zip")
end
do
  local e = cf.pick_entry({
    { file = "a.zip", badge = "online" },
    { file = "b.zip", badge = "tested" },
  })
  check("P2 no bypass -> first in order", e and e.file == "a.zip")
end
do
  local e = cf.pick_entry({
    { file = "RE.HYPERVISOR.zip", badge = "hypervisor" },
    { file = "RE.Crack.zip", badge = "" },
  })
  check("P3 skips hypervisor", e and e.file == "RE.Crack.zip")
end
check("P4 empty -> nil", cf.pick_entry({}) == nil)
check("P5 all hypervisor -> nil",
  cf.pick_entry({ { file = "x.zip", badge = "hypervisor" } }) == nil)

-- ---------------------------------------------------------------------------
-- lookup against a decoded index
-- ---------------------------------------------------------------------------
local INDEX = {
  generated = "t", source = "s", count = 3,
  fixes = {
    ["3768760"] = { { file = "007.first.light-voices38.zip", badge = "bypass" } },
    ["812140"]  = { { file = "AC Odyssey 2.zip", badge = "tested" },
                    { file = "AC Odyssey 1.zip", badge = "tested" } },
    ["999"]     = { { file = "Only.HYPERVISOR.zip", badge = "hypervisor" } },
  },
}
do
  local r = cf.lookup(INDEX, 3768760)
  check("L1 hit status 200", r.status == 200 and r.available == true)
  check("L2 hit url", r.url == "https://generator.ryuu.lol/fixes/007.first.light-voices38.zip")
  check("L3 hit badge", r.badge == "bypass")
end
do
  local r = cf.lookup(INDEX, 812140)
  check("L4 multi picks an entry, builds url", r.status == 200 and r.url ~= nil)
end
do
  local r = cf.lookup(INDEX, 999)
  check("L5 hypervisor-only -> 404", r.status == 404 and r.available == false)
end
do
  local r = cf.lookup(INDEX, 555555)
  check("L6 miss -> 404", r.status == 404)
end
check("L7 garbage index -> 404", cf.lookup("nope", 1).status == 404)

-- ---------------------------------------------------------------------------
-- check() dispatch with injected deps (no filesystem, no network)
-- ---------------------------------------------------------------------------
do
  local json_blob = '{"fixes":{"42":[{"file":"Game 42.zip","badge":"bypass"}]}}'
  local refreshed = { called = false }
  local r = cf.check(42, {
    decode = function(s)
      -- trivial: only ever asked to decode json_blob
      return { fixes = { ["42"] = { { file = "Game 42.zip", badge = "bypass" } } } }
    end,
    read_file = function(p) return p == "/cache" and json_blob or nil end,
    cache_path = "/cache",
    bundled_path = "/bundled",
    mtime = function(_) return 1000 end,      -- fresh cache
    now = 1000,
    refresh_script = "/ryuu_index.sh",
    spawn_refresh = function() refreshed.called = true end,
  })
  check("C1 cache hit -> 200", r.status == 200)
  check("C2 cache url", r.url == "https://generator.ryuu.lol/fixes/Game%2042.zip")
  check("C3 fresh cache -> no refresh", refreshed.called == false)
end
do
  -- stale cache (mtime far in the past) triggers a background refresh.
  local refreshed = { called = false }
  cf.check(42, {
    decode = function(_) return { fixes = {} } end,
    read_file = function(_) return "{}" end,
    cache_path = "/cache",
    bundled_path = "/bundled",
    mtime = function(_) return 1 end,
    now = 10 ^ 9,
    refresh_script = "/ryuu_index.sh",
    spawn_refresh = function() refreshed.called = true end,
  })
  check("C4 stale cache -> refresh spawned", refreshed.called == true)
end
do
  local r = cf.check("notanumber", {})
  check("C5 bad appid -> status 0", r.status == 0)
end

print(string.format("crackfix: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
