#!/usr/bin/env luajit
-- Unit tests for plugin/backend/onlinefix.lua (perondepot index matcher).
--
-- onlinefix.lua is a PURE module (no Millennium deps): it parses the
-- perondepot /all/ autoindex HTML into (decoded game name -> rar href)
-- entries and resolves a Steam store-page game name to the matching rar,
-- tolerating punctuation/edition/case differences via normalization.
--
-- Run from the repo root:  luajit scripts/test-onlinefix.lua

package.path = "plugin/backend/?.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then
    io.write("ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. "\n")
    fails = fails + 1
  end
end

local of = dofile("plugin/backend/onlinefix.lua")

-- A trimmed but real-shaped slice of the perondepot /all/ autoindex. The
-- " по сети" marker (Cyrillic, UTF-8) separates the game name from the fix
-- code. hrefs are percent-encoded exactly as nginx emits them.
local HTML = [[
<html><head><title>Index of /all/</title></head><body><pre>
<a href="../">../</a>
<a href="100%25%20Orange%20Juice%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20100OJ_Fix_Repair_Steam_Generic.rar">100% Orange Juice ..&gt;</a> 15-Jun-2026 19:56 16M
<a href="Age%20of%20Mythology%20Extended%20Edition%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20AoMEE_Fix_Repair_Steam_Generic.rar">Age of Mythology ..&gt;</a> 15-Jun-2026 19:56 12M
<a href="Gang%20Beasts%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20GangBeasts_Fix_Repair_Steam_V4_Generic.rar">Gang Beasts ..&gt;</a> 15-Jun-2026 19:56 11M
<a href="readme.txt">readme.txt</a> 1K
</pre></body></html>
]]

-- ---------------------------------------------------------------------------
-- url_decode: percent-decode a path component.
-- ---------------------------------------------------------------------------
do
  check("U1 percent decode space", of.url_decode("Gang%20Beasts") == "Gang Beasts")
  check("U2 percent decode percent", of.url_decode("100%25") == "100%")
  check("U3 plain passthrough", of.url_decode("readme.txt") == "readme.txt")
end

-- ---------------------------------------------------------------------------
-- normalize: lowercase + strip non-alphanumeric so punctuation/edition
-- spacing differences between Steam and perondepot names collapse.
-- ---------------------------------------------------------------------------
do
  check("N1 strip punct+case", of.normalize("100% Orange Juice") == of.normalize("100 orange juice"))
  check("N2 colon vs space", of.normalize("Age of Mythology: Extended Edition") == of.normalize("Age of Mythology Extended Edition"))
  check("N3 trademark stripped", of.normalize("Gang Beasts\xe2\x84\xa2") == of.normalize("Gang Beasts"))
  check("N4 distinct stay distinct", of.normalize("Aragami 2") ~= of.normalize("Aragami"))
end

-- ---------------------------------------------------------------------------
-- parse_index: HTML -> entries with decoded name + raw (encoded) href.
-- ---------------------------------------------------------------------------
do
  local entries = of.parse_index(HTML)
  check("P1 three rar entries (ignores ../ and readme.txt)", #entries == 3)
  local byname = {}
  for _, e in ipairs(entries) do byname[e.name] = e end
  check("P2 Gang Beasts name decoded", byname["Gang Beasts"] ~= nil)
  check("P3 keeps encoded href for fetching",
        byname["Gang Beasts"] and byname["Gang Beasts"].href:find("%%20") ~= nil)
  check("P4 100%% name decoded", byname["100% Orange Juice"] ~= nil)
end

-- ---------------------------------------------------------------------------
-- find_fix: resolve a Steam store-page game name to the matching rar.
-- ---------------------------------------------------------------------------
do
  local m = of.find_fix(HTML, "Gang Beasts")
  check("F1 exact match", m and m.href:find("GangBeasts_Fix_Repair") ~= nil)

  -- Steam uses a colon; perondepot doesn't -> still matches via normalize.
  local m2 = of.find_fix(HTML, "Age of Mythology: Extended Edition")
  check("F2 punctuation-tolerant match", m2 and m2.href:find("AoMEE_Fix_Repair") ~= nil)

  -- Steam trademark suffix tolerated.
  local m3 = of.find_fix(HTML, "100% Orange Juice")
  check("F3 percent-name match", m3 and m3.href:find("100OJ_Fix_Repair") ~= nil)

  check("F4 no match -> nil", of.find_fix(HTML, "Half-Life 3") == nil)
  check("F5 empty name -> nil", of.find_fix(HTML, "") == nil)
end

-- ---------------------------------------------------------------------------
-- Separator variants (found via real-data accuracy testing): not every entry
-- uses the Cyrillic "по сети" marker. Some use English " Online", and a few
-- use just " - " before the fix code. The game name must still come out clean.
-- The fix code never contains " - ", so the name is everything before the
-- LAST " - ", minus a trailing "по сети"/"Online" marker.
-- ---------------------------------------------------------------------------
local HTML2 = [[
<pre>
<a href="Aliens%20Vs.%20Ghosts%20Online%20-%20AliensVsGhosts_Fix_Repair_Steam_Generic.rar">x</a>
<a href="Worms%20Reloaded%20-%20WR_Fix_Repair_Steam_Generic.rar">x</a>
<a href="CURE%20-%20A%20Hospital%20Simulator%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20CURE_Fix_Repair_Steam_Generic.rar">x</a>
</pre>
]]
do
  local byname = {}
  for _, e in ipairs(of.parse_index(HTML2)) do byname[e.name] = e end
  check("S1 English 'Online' separator", byname["Aliens Vs. Ghosts"] ~= nil)
  check("S2 bare ' - ' separator", byname["Worms Reloaded"] ~= nil)
  check("S3 internal ' - ' in name preserved", byname["CURE - A Hospital Simulator"] ~= nil)

  check("S4 find via Online-separated entry",
        of.find_fix(HTML2, "Aliens Vs. Ghosts") ~= nil)
  check("S5 find name with internal dash",
        of.find_fix(HTML2, "CURE: A Hospital Simulator") ~= nil)
end

-- ---------------------------------------------------------------------------
-- GTA aliases. Steam uses the full franchise names while mirrors frequently
-- abbreviate GTA / SA / DE and mix Roman and Arabic sequel numbers. These are
-- aliases, not edition erasure: an original game must stay distinct from DE.
-- ---------------------------------------------------------------------------
local GTA_HTML = [[
<pre>
<a href="GTA%20V%20Legacy%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20GTAVLegacy_Fix_Repair_Steam_Generic.rar">x</a>
<a href="GTA%20SA%20DE%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20GTASADE_Fix_Repair_Steam_Generic.rar">x</a>
<a href="GTA%20Vice%20DE%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20GTAViceDE_Fix_Repair_Steam_Generic.rar">x</a>
<a href="GTA%20III%20DE%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20GTA3DE_Fix_Repair_Steam_Generic.rar">x</a>
<a href="GTA%20Trilogy%20DE%20%D0%BF%D0%BE%20%D1%81%D0%B5%D1%82%D0%B8%20-%20GTATrilogyDE_Fix_Repair_Steam_Generic.rar">x</a>
</pre>
]]
do
  check("G1 GTA expands to Grand Theft Auto",
    of.find_fix(GTA_HTML, "Grand Theft Auto V Legacy") ~= nil)
  check("G2 SA+DE aliases match the Steam title",
    of.find_fix(GTA_HTML, "Grand Theft Auto: San Andreas – The Definitive Edition") ~= nil)
  check("G3 Vice+DE aliases match the Steam title",
    of.find_fix(GTA_HTML, "Grand Theft Auto: Vice City – The Definitive Edition") ~= nil)
  check("G4 Roman sequel and DE alias match",
    of.find_fix(GTA_HTML, "Grand Theft Auto III – The Definitive Edition") ~= nil)
  check("G5 Trilogy alias matches articles and DE suffix",
    of.find_fix(GTA_HTML, "Grand Theft Auto: The Trilogy – The Definitive Edition") ~= nil)
  check("G6 original and Definitive Edition remain distinct",
    of.normalize("GTA III") ~= of.normalize("GTA III DE"))
end

-- ── index fetch: cache + a bounded time budget ─────────────────────────────
-- The mirror is a third party and can take tens of seconds to answer (measured
-- 23s from one machine while another got 0.3s at the same moment). The plugin
-- backend runs inside Lumen's single-threaded loop, so every second spent here
-- is a second in which NO other RPC is served — a slow mirror froze the whole
-- Fixes Menu. Hence: serve from cache when fresh, spend a bounded amount of time
-- when not, and fall back to a stale copy rather than hanging.
do
  local function harness(opts)
    opts = opts or {}
    local clock = opts.start or 1000
    local state = {gets = 0, written = nil, sleeps = 0}
    local deps = {
      now = function() return clock end,
      get = function(_, o)
        state.gets = state.gets + 1
        state.last_timeout = o and o.timeout
        clock = clock + (opts.cost or 1)
        local reply = opts.replies and opts.replies[state.gets]
        if reply == nil then reply = opts.reply end
        return reply
      end,
      read = function() return opts.cached end,
      write = function(body) state.written = body; return true end,
      ttl = opts.ttl or 600,
      budget = opts.budget or 12,
    }
    return deps, state
  end

  local OK = {status = 200, body = "<html>fresh</html>"}

  local deps, state = harness({reply = OK})
  local body, from = of.fetch_index(deps)
  check("X1 a cold cache fetches", body == OK.body and from == "network")
  check("X2 the fetched index is cached", state.written == OK.body)
  check("X3 the request is given a bounded timeout",
    type(state.last_timeout) == "number" and state.last_timeout <= 10)

  deps, state = harness({cached = {body = "<html>cached</html>", at = 1000}, start = 1100})
  body, from = of.fetch_index(deps)
  check("X4 a fresh cache is served without touching the network",
    body == "<html>cached</html>" and from == "cache" and state.gets == 0)

  deps, state = harness({cached = {body = "<html>old</html>", at = 0}, start = 5000, reply = OK})
  body, from = of.fetch_index(deps)
  check("X5 an expired cache refetches", body == OK.body and state.gets == 1)

  -- Every attempt fails and each burns 6s: the budget must stop the retries.
  deps, state = harness({reply = nil, cost = 6, budget = 12})
  body, from = of.fetch_index(deps)
  check("X6 a dead mirror gives up", body == nil)
  check("X7 retries stop at the time budget", state.gets <= 2)

  -- A stale copy beats hanging the menu on an unreachable mirror.
  deps, state = harness({cached = {body = "<html>stale</html>", at = 0}, start = 9999,
                         reply = nil, cost = 6})
  body, from = of.fetch_index(deps)
  check("X8 an unreachable mirror falls back to the stale copy",
    body == "<html>stale</html>" and from == "stale")

  -- A transient first failure still succeeds on the second attempt.
  deps, state = harness({replies = {nil, OK}, cost = 1})
  body, from = of.fetch_index(deps)
  check("X9 a transient failure is retried", body == OK.body and state.gets == 2)

  -- A non-200 is not cached as if it were the index.
  deps, state = harness({reply = {status = 503, body = "nope"}, cost = 1})
  body = of.fetch_index(deps)
  check("X10 a non-200 reply is not accepted", body == nil and state.written == nil)
end

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
