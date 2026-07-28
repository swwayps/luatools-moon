#!/usr/bin/env luajit
local REPO = (arg and arg[0] or ""):gsub("scripts/[^/]*$", "")
if REPO == "" then REPO = "./" end

local fails = 0
local function check(name, condition)
  if condition then
    print("ok   - " .. name)
  else
    print("FAIL - " .. name)
    fails = fails + 1
  end
end

local merge = dofile(REPO .. "plugin/backend/smart_merge.lua")
local K1 = string.rep("a", 64)
local K2 = string.rep("b", 64)
local K3 = string.rep("c", 64)

local parsed = assert(merge.parse_lua('addappid(10)\n'
  .. 'addappid(11, 1, "' .. K1 .. '")\n'
  .. '-- addappid(12, 1, "' .. K2 .. '")\n'
  .. 'setManifestid(11, "9001", 123)\n'
  .. 'print("must be dropped -- intact")\n'))
check("parser keeps bare addappid", parsed.bare[10] == true)
check("parser normalizes keyed addappid", parsed.keys[11] == K1)
check("parser ignores commented declaration", parsed.keys[12] == nil)
check("parser keeps manifest reference", parsed.manifests[11] == "9001")

local sources = {
  { index = 2, priority = 2, name = "Sushi", lua_text =
      'addappid(10)\naddappid(11,1,"' .. K2 .. '")\n' },
  { index = 0, priority = 0, name = "Hubcap", exact_current = { [11] = true }, lua_text =
      'addappid(10)\naddappid(11,1,"' .. K1 .. '")\n' },
  { index = 1, priority = 1, name = "Ryuu", lua_text =
      'addappid(12,1,"' .. K3 .. '")\naddappid(11,1,"' .. K2 .. '")\n' },
}
local result = assert(merge.merge_sources(10, sources, { [11] = 9001 }))
check("merge unions missing keys", result.keys[12] == K3)
check("exact-current source resolves key conflict", result.keys[11] == K1)
check("merge records conflict without failing", #result.conflicts == 1)
local consensus = assert(merge.merge_sources(10, {
  { index = 0, priority = 0, name = "first", lua_text = 'addappid(11,1,"' .. K1 .. '")' },
  { index = 1, priority = 1, name = "second", lua_text = 'addappid(11,1,"' .. K2 .. '")' },
  { index = 2, priority = 2, name = "third", lua_text = 'addappid(11,1,"' .. K2 .. '")' },
}, {}))
check("consensus outranks configured priority", consensus.keys[11] == K2)

local priority = assert(merge.merge_sources(10, {
  { index = 4, priority = 4, name = "late", lua_text = 'addappid(11,1,"' .. K2 .. '")' },
  { index = 1, priority = 1, name = "early", lua_text = 'addappid(11,1,"' .. K1 .. '")' },
}, {}))
check("configured priority breaks conflict tie", priority.keys[11] == K1)

local emitted = merge.emit_lua(10, result)
local reversed = assert(merge.merge_sources(10, { sources[3], sources[2], sources[1] }, { [11] = 9001 }))
check("emission is independent of completion order", emitted == merge.emit_lua(10, reversed))
check("emission starts with base app grant", emitted:match("^addappid%(10%)\n") ~= nil)
check("emission contains merged depot key", emitted:find('addappid(12, 1, "' .. K3 .. '")', 1, true) ~= nil)
check("emission drops arbitrary source Lua", emitted:find("print", 1, true) == nil)

local function u32(n)
  local b1 = n % 256; n = math.floor(n / 256)
  local b2 = n % 256; n = math.floor(n / 256)
  local b3 = n % 256; n = math.floor(n / 256)
  return string.char(b1, b2, b3, n % 256)
end
local function div_decimal(text, divisor)
  local out, carry = {}, 0
  for digit in text:gmatch("%d") do
    local value = carry * 10 + tonumber(digit)
    local q = math.floor(value / divisor)
    carry = value % divisor
    if #out > 0 or q > 0 then out[#out + 1] = tostring(q) end
  end
  return #out == 0 and "0" or table.concat(out), carry
end
local function varint(decimal)
  local out, value = {}, tostring(decimal)
  repeat
    local quotient, remainder = div_decimal(value, 128)
    out[#out + 1] = string.char(remainder + (quotient ~= "0" and 128 or 0))
    value = quotient
  until value == "0"
  return table.concat(out)
end
local function valid_manifest(depot, gid, created)
  local metadata = string.char(8) .. varint(depot)
    .. string.char(16) .. varint(gid)
    .. string.char(24) .. varint(created)
  return u32(0x71F617D0) .. u32(0)
    .. u32(0x1F4812BE) .. u32(#metadata) .. metadata
end

local BIG_GID = "3238948344654627795"
local current = merge.parse_appinfo_gids(
  '"appinfo" { "depots" { "11" { "manifests" { "public" { "gid" "'
  .. BIG_GID .. '" } } } } }')
check("appinfo parser preserves 64-bit gid", current[11] == BIG_GID)
local metadata = assert(merge.parse_manifest(valid_manifest(11, BIG_GID, 1700000000), 11, BIG_GID))
check("manifest parser validates depot identity", metadata.depot == 11)
check("manifest parser preserves gid", metadata.gid == BIG_GID)
check("manifest parser reads creation time", metadata.creation_time == 1700000000)
local terminated = merge.parse_manifest(
  valid_manifest(11, BIG_GID, 1700000000) .. u32(0x32C415AB), 11, BIG_GID)
check("manifest parser accepts Steam terminal marker", terminated ~= nil)
local bad, bad_error = merge.parse_manifest("broken", 11, BIG_GID)
check("manifest parser rejects bad magic", bad == nil and bad_error ~= nil)
local mismatch = merge.parse_manifest(valid_manifest(12, BIG_GID, 1700000000), 11, BIG_GID)
check("manifest parser rejects filename metadata mismatch", mismatch == nil)

local preferred = merge.select_preferred({
  { depot = 11, gid = "100", creation_time = 200, priority = 0 },
  { depot = 11, gid = BIG_GID, creation_time = 100, priority = 2 },
}, { [11] = BIG_GID })
check("exact appinfo gid outranks timestamp", preferred[11] == BIG_GID)
local newest = merge.select_preferred({
  { depot = 11, gid = "9999999999999999999", creation_time = 100, priority = 0 },
  { depot = 11, gid = "2", creation_time = 200, priority = 2 },
}, {})
check("creation metadata outranks numeric gid", newest[11] == "2")

if fails == 0 then
  print("\nALL TESTS OK")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end