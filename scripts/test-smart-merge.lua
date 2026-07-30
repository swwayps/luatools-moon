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

local long_blocks = merge.parse_lua('--[[\naddappid(20)\naddappid(21,1,"' .. K2
  .. '")\n]]\n[=[\naddappid(22)\nsetManifestid(21,"9002")\n]=]\n')
check("parser ignores declarations in multiline comments", long_blocks.bare[20] == nil
  and long_blocks.keys[21] == nil)
check("parser ignores declarations in multiline strings", long_blocks.bare[22] == nil
  and long_blocks.manifests[21] == nil)
local after_blocks = merge.parse_lua('--[=[ ignored\naddappid(99)\n]=] addappid(23)\n'
  .. '[==[addappid(98)]==] addappid(24)\n')
check("parser resumes after long-block terminators", after_blocks.bare[23] == true
  and after_blocks.bare[24] == true and after_blocks.bare[99] == nil
  and after_blocks.bare[98] == nil)

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

local edited, edited_error = merge.build_edited_lua(10, {
  dlc_appids = { "1200", 1300, 1200 },
  depots = {
    { depot = "11", key = K1, gid = "9001" },
    { depot = 12, key = K2, gid = "" },
  },
}, {})
check("edited draft accepts masked-field values without replacing the key",
  edited_error == nil and edited:find(K1, 1, true) ~= nil)
check("edited draft emits DLC declarations", edited:find("addappid(1200)", 1, true) ~= nil
  and edited:find("addappid(1300)", 1, true) ~= nil)
check("blank manifest means latest", edited:find("setManifestid(12", 1, true) == nil)
check("explicit manifest remains pinned",
  edited:find('setManifestid(11, "9001")', 1, true) ~= nil)
local invalid_edited = merge.build_edited_lua(10, {
  depots = { { depot = 11, key = "******", gid = "9001" } },
}, {})
check("masked display placeholder is never persisted as a key", invalid_edited == nil)
local overflow_edited = merge.build_edited_lua(10, {
  depots = { { depot = 11, key = K1, gid = "18446744073709551616" } },
}, {})
check("edited draft rejects a manifest gid above uint64", overflow_edited == nil)
local dlc_key_only_edited, dlc_key_only_error = merge.build_edited_lua(10, {
  depots = {
    { depot = 11, key = "", gid = "" },
    { depot = 12, key = K2, gid = "" },
  },
}, { base_depots = { 11 } })
check("edited draft still requires a usable base-depot key",
  dlc_key_only_edited == nil and dlc_key_only_error == "no_usable_base_key")

local appinfo = '"appinfo" { "depots" {'
  .. ' "11" { "config" { "oslist" "windows" }'
  .. ' "manifests" { "public" { "gid" "9001" } } }'
  .. ' "12" { "config" { "oslist" "linux" } "dlcappid" "1200"'
  .. ' "manifests" { "public" { "gid" "9002" } } }'
  .. ' "1201" { "dlcappid" "1201" }'
  .. ' "13" { "config" { "oslist" "macos" }'
  .. ' "manifests" { "public" { "gid" "9003" } } }'
  .. ' } "extended" { "listofdlc" "1200,1201,1300" } }'
local depots = assert(merge.parse_appinfo_depots(appinfo))
check("appinfo classifies relevant base depot", depots[11]
  and depots[11].kind == "base" and depots[11].relevant == true)
check("appinfo classifies DLC content depot", depots[12]
  and depots[12].kind == "dlc" and depots[12].relevant == true)
check("appinfo classifies virtual DLC without requiring a key", depots[1201]
  and depots[1201].kind == "virtual_dlc")
check("appinfo excludes macOS-only depot from Linux viability", depots[13]
  and depots[13].relevant == false)
local official_dlcs = merge.parse_appinfo_dlc_appids(appinfo)
check("appinfo combines depot and declared DLC appids", official_dlcs[1200]
  and official_dlcs[1201] and official_dlcs[1300])

local base_only = assert(merge.evaluate_sources(10, {
  { index = 0, priority = 0, name = "Base", lua_text =
      'addappid(10)\naddappid(11,1,"' .. K1 .. '")\n' },
}, appinfo))
check("usable base key succeeds without DLC key", base_only.usable == true
  and base_only.base_key_count == 1 and base_only.dlc_key_count == 0)

local dlc_only = assert(merge.evaluate_sources(10, {
  { index = 0, priority = 0, name = "DLC only", lua_text =
      'addappid(10)\naddappid(12,1,"' .. K2 .. '")\n' },
}, appinfo))
check("DLC key alone is not mistaken for usable base content",
  dlc_only.usable == false and dlc_only.reason == "no_usable_base_key")

local fallback = assert(merge.evaluate_sources(10, {
  { index = 0, priority = 0, name = "Token limited", lua_text =
      'addappid(10)\naddappid(99,1,"' .. K3 .. '")\n' },
}, '"appinfo" { "depots" { } }'))
check("unclassifiable appinfo falls back to any valid key", fallback.usable == true)

local newest = merge.select_preferred({
  { depot = 11, gid = "9001", creation_time = 100, priority = 0, source_index = 0 },
  { depot = 11, gid = "9002", creation_time = 200, priority = 1, source_index = 1 },
}, { [11] = "9001" })
check("newest manifest wins even when older candidate is current public GID",
  newest[11] == "9002")

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
local overflow_manifest = merge.parse_manifest(
  valid_manifest(11, "18446744073709551616", 1700000000))
check("manifest parser rejects a gid above uint64", overflow_manifest == nil)

local preferred = merge.select_preferred({
  { depot = 11, gid = "100", creation_time = 200, priority = 0 },
  { depot = 11, gid = BIG_GID, creation_time = 100, priority = 2 },
}, { [11] = BIG_GID })
check("newer timestamp outranks exact appinfo gid", preferred[11] == "100")
local newest = merge.select_preferred({
  { depot = 11, gid = "9999999999999999999", creation_time = 100, priority = 0 },
  { depot = 11, gid = "2", creation_time = 200, priority = 2 },
}, {})
check("creation metadata outranks numeric gid", newest[11] == "2")

local preview_files = {
  ["/collection/source_0000/.source-name"] = "Ryuu",
  ["/collection/source_0000/.source-priority"] = "0\n",
  ["/collection/source_0000/10.lua"] = 'addappid(10)\naddappid(11,1,"' .. K1 .. '")\n',
  ["/collection/source_0000/11_100.manifest"] = valid_manifest(11, "100", 200),
}
local preview_entries = {}
for path in pairs(preview_files) do
  preview_entries[#preview_entries + 1] = {
    path = path, name = path:match("[^/]+$"), is_directory = false,
  }
end
local preview = assert(merge.preview(10, "/collection", {
  home = "/tmp/preview-home",
  appinfo_text = appinfo,
  list_recursive = function() return preview_entries end,
  read_file = function(path) return preview_files[path] end,
  exists = function() return false end,
}))
local preview_dlcs = {}
for _, id in ipairs(preview.dlc_appids) do preview_dlcs[id] = true end
check("preview includes official DLCs omitted by a source Lua", preview_dlcs[1200]
  and preview_dlcs[1201] and preview_dlcs[1300])
local preview_rows = {}
for _, row in ipairs(preview.depots) do preview_rows[row.depot] = row end
check("preview surfaces virtual DLC without a content key", preview_rows[1201]
  and preview_rows[1201].kind == "virtual_dlc"
  and preview_rows[1201].key == "" and preview_rows[1201].requires_key == false)
check("preview reports the source that provided a ManifestID", preview_rows[11]
  and preview_rows[11].manifest_source == "Ryuu")

if fails == 0 then
  print("\nALL TESTS OK")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end
