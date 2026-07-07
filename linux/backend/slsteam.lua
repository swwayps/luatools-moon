-- slsteam.lua  (Linux overlay for luatools-moon)
--
-- slsteam-moon establishes ownership of an "added" game by reading the
-- appid from the AdditionalApps: list in ~/.config/SLSsteam/config.yaml
-- (see SLSsteam-fork src/config.cpp: getList<uint32_t>(node,
-- "AdditionalApps")).  Dropping the .lua into config/stplug-in only
-- provides depot KEYS; the appid itself must be present in
-- AdditionalApps for the game to show up and install.
--
-- This module is the integration point the upstream LuaTools plugin
-- lacks (it was written for SteamTools/Windows).  It maintains the
-- AdditionalApps: block in config.yaml:
--
--   * register_app(appid)   -> add after a successful "Add via LuaTools"
--   * unregister_app(appid) -> remove when the user deletes the .lua
--
-- Design notes:
--   * Pure Lua + os/io only (no Millennium fs needed), so it can be
--     unit-tested with a stock lua interpreter.
--   * Edits are byte-preserving except for the single inserted/removed
--     entry: comments, ordering and unrelated keys are kept intact
--     (yaml-cpp is whitespace tolerant, humans are not).
--   * Block-list form only ("AdditionalApps:" followed by "  - <id>"
--     lines).  Inline form ("AdditionalApps: [1,2]") is refused rather
--     than risk corrupting the file.
--   * Atomic write via temp file + os.rename so SLSsteam's inotify
--     watch fires once on a complete file.

local slsteam = {}

local function config_path()
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  return home .. "/.config/SLSsteam/config.yaml"
end

local function read_lines(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a") or ""
  f:close()
  local lines = {}
  local has_trailing_nl = (#data > 0 and data:sub(-1) == "\n")
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if has_trailing_nl then lines[#lines] = nil end
  return lines, has_trailing_nl
end

local function write_lines_atomic(path, lines, has_trailing_nl)
  local tmp = path .. ".tmp.luatools"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err or "open failed" end
  for i, line in ipairs(lines) do
    f:write(line)
    if i < #lines or has_trailing_nl then f:write("\n") end
  end
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr or "rename failed"
  end
  return true
end

-- Locate the "AdditionalApps:" header line index, or nil.
local function find_header(lines)
  for i, line in ipairs(lines) do
    if line:match("^AdditionalApps%s*:") then return i end
  end
  return nil
end

-- Returns true if the header carries an inline value (e.g. "[1,2]").
local function header_is_inline(lines, header_idx)
  local after = lines[header_idx]:match("^AdditionalApps%s*:%s*(.-)%s*$") or ""
  local code_only = after:gsub("#.*$", ""):gsub("%s+$", "")
  return code_only ~= ""
end

-- Walk the block-list under the header. Returns (existing_ids_set,
-- last_entry_idx, indent).
local function scan_block(lines, header_idx)
  local existing = {}
  local last_entry_idx = header_idx
  local indent = "  "
  for i = header_idx + 1, #lines do
    local line = lines[i]
    local stripped = line:gsub("^%s+", "")
    if stripped == "" or stripped:match("^#") then
      -- comment/blank: belongs to whatever section follows; skip.
    else
      -- %s* (not %s+): block-sequence items may be flush-left ("- 123" at
      -- zero indent is valid YAML under a mapping key). Requiring a leading
      -- space made a zero-indent list break the scan on its first item, so the
      -- new entry was inserted at the fallback 2-space indent right after the
      -- header -> mixed indentation that yaml-cpp rejects, bricking Steam at
      -- startup (see .kiro/config_parse_abort_analysis.md).
      local entry_indent, rest = line:match("^(%s*)%-%s+(.*)$")
      if not entry_indent then break end  -- next top-level key
      indent = entry_indent
      last_entry_idx = i
      local id_num = tonumber((rest:gsub("#.*$", ""):gsub("%s+$", "")))
      if id_num then existing[id_num] = true end
    end
  end
  return existing, last_entry_idx, indent
end

-- Add appid to AdditionalApps. Returns true,"added" |
-- true,"already_present" | false,error.
function slsteam.register_app(appid, comment)
  appid = tonumber(appid)
  if not appid then return false, "invalid appid" end

  local path = config_path()
  if not path then return false, "HOME not set" end
  local lines, has_trailing_nl = read_lines(path)
  if not lines then return false, "SLSsteam config.yaml not found" end

  local header_idx = find_header(lines)
  -- If there is no AdditionalApps: key at all, create an empty block at
  -- the end of the file so we have somewhere to append.
  if not header_idx then
    if #lines > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
    lines[#lines + 1] = "AdditionalApps:"
    header_idx = #lines
  elseif header_is_inline(lines, header_idx) then
    return false, "AdditionalApps: has an inline value, refusing to rewrite"
  end

  local existing, last_entry_idx, indent = scan_block(lines, header_idx)
  if existing[appid] then return true, "already_present" end

  local entry = indent .. "- " .. tostring(appid)
  if comment and comment ~= "" then
    local clean = tostring(comment):gsub("[%c]", " "):gsub("%s+", " ")
    clean = clean:sub(1, 80):gsub("^%s+", ""):gsub("%s+$", "")
    if #clean > 0 then entry = entry .. "   # " .. clean end
  end
  table.insert(lines, last_entry_idx + 1, entry)

  local ok, werr = write_lines_atomic(path, lines, has_trailing_nl)
  if not ok then return false, werr end
  return true, "added"
end

-- Remove appid from AdditionalApps. Returns true,"removed" |
-- true,"not_present" | false,error.
function slsteam.unregister_app(appid)
  appid = tonumber(appid)
  if not appid then return false, "invalid appid" end

  local path = config_path()
  if not path then return false, "HOME not set" end
  local lines, has_trailing_nl = read_lines(path)
  if not lines then return false, "SLSsteam config.yaml not found" end

  local header_idx = find_header(lines)
  if not header_idx then return true, "not_present" end
  if header_is_inline(lines, header_idx) then
    return false, "AdditionalApps: has an inline value"
  end

  local target_idx = nil
  for i = header_idx + 1, #lines do
    local line = lines[i]
    local stripped = line:gsub("^%s+", "")
    if stripped == "" or stripped:match("^#") then
      -- skip
    else
      -- %s* (not %s+): match flush-left "- 123" items too, so a zero-indent
      -- list stays editable (the old %s+ silently reported not_present).
      local entry_indent, rest = line:match("^(%s*)%-%s+(.*)$")
      if not entry_indent then break end
      local id_num = tonumber((rest:gsub("#.*$", ""):gsub("%s+$", "")))
      if id_num == appid then target_idx = i break end
    end
  end

  if not target_idx then return true, "not_present" end
  table.remove(lines, target_idx)
  local ok, werr = write_lines_atomic(path, lines, has_trailing_nl)
  if not ok then return false, werr end
  return true, "removed"
end

-- Shell-single-quote a string so a path with spaces/quotes survives
-- os.execute (Linux overlay only).
local function shsq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- ---------------------------------------------------------------------------
-- FakeAppIds map editor.
--
-- slsteam-moon's FakeAppIds: config map (realAppId -> fakeAppId) makes a game
-- report itself under a different appid on the real Steam client layer
-- (games-played presence, matchmaking, server lists, ticket -- see
-- SLSsteam-fork src/feats/fakeappid.cpp). Mapping a game to 480 (Spacewar) is
-- the native equivalent of the Windows "Unsteam" emulator the AIO fix ships.
--
-- Unlike AdditionalApps (a block LIST), FakeAppIds is a block MAP:
--   FakeAppIds:
--     <appid>: <fake>
-- Same careful, byte-preserving, atomic editing as register_app.
-- ---------------------------------------------------------------------------

local function fakeappids_header(lines)
  for i, line in ipairs(lines) do
    if line:match("^FakeAppIds%s*:") then return i end
  end
  return nil
end

local function fakeappids_is_inline(lines, header_idx)
  local after = lines[header_idx]:match("^FakeAppIds%s*:%s*(.-)%s*$") or ""
  local code_only = after:gsub("#.*$", ""):gsub("%s+$", "")
  return code_only ~= ""
end

-- Walk the map block under the header. Returns (entries, last_entry_idx,
-- indent) where entries[key] = { idx = line_index, value = "<stripped value>" }.
local function scan_map_block(lines, header_idx)
  local entries = {}
  local last_entry_idx = header_idx
  local indent = "  "
  for i = header_idx + 1, #lines do
    local line = lines[i]
    local stripped = line:gsub("^%s+", "")
    if stripped == "" or stripped:match("^#") then
      -- comment/blank: belongs to whatever section follows; skip.
    else
      local entry_indent, key, val = line:match("^(%s+)(%d+)%s*:%s*(.-)%s*$")
      if not entry_indent then break end  -- next top-level key / non-entry
      indent = entry_indent
      last_entry_idx = i
      local keynum = tonumber(key)
      if keynum then
        entries[keynum] = { idx = i, value = (val:gsub("#.*$", ""):gsub("%s+$", "")) }
      end
    end
  end
  return entries, last_entry_idx, indent
end

-- Map appid -> fake (default 480 / Spacewar). Returns true,"added" |
-- true,"updated" | true,"already_present" | false,error.
function slsteam.set_fake_appid(appid, fake)
  appid = tonumber(appid)
  if not appid then return false, "invalid appid" end
  fake = tonumber(fake) or 480

  local path = config_path()
  if not path then return false, "HOME not set" end
  local lines, has_trailing_nl = read_lines(path)
  if not lines then return false, "SLSsteam config.yaml not found" end

  local header_idx = fakeappids_header(lines)
  if not header_idx then
    if #lines > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
    lines[#lines + 1] = "FakeAppIds:"
    header_idx = #lines
  elseif fakeappids_is_inline(lines, header_idx) then
    return false, "FakeAppIds: has an inline value, refusing to rewrite"
  end

  local entries, last_entry_idx, indent = scan_map_block(lines, header_idx)
  local existing = entries[appid]
  if existing then
    if existing.value == tostring(fake) then return true, "already_present" end
    lines[existing.idx] = indent .. tostring(appid) .. ": " .. tostring(fake)
    local ok, werr = write_lines_atomic(path, lines, has_trailing_nl)
    if not ok then return false, werr end
    return true, "updated"
  end

  local entry = indent .. tostring(appid) .. ": " .. tostring(fake)
  table.insert(lines, last_entry_idx + 1, entry)
  local ok, werr = write_lines_atomic(path, lines, has_trailing_nl)
  if not ok then return false, werr end
  return true, "added"
end

-- Remove appid from FakeAppIds. Returns true,"removed" |
-- true,"not_present" | false,error.
function slsteam.unset_fake_appid(appid)
  appid = tonumber(appid)
  if not appid then return false, "invalid appid" end

  local path = config_path()
  if not path then return false, "HOME not set" end
  local lines, has_trailing_nl = read_lines(path)
  if not lines then return false, "SLSsteam config.yaml not found" end

  local header_idx = fakeappids_header(lines)
  if not header_idx then return true, "not_present" end
  if fakeappids_is_inline(lines, header_idx) then
    return false, "FakeAppIds: has an inline value"
  end

  local entries = scan_map_block(lines, header_idx)
  local existing = entries[appid]
  if not existing then return true, "not_present" end

  table.remove(lines, existing.idx)
  local ok, werr = write_lines_atomic(path, lines, has_trailing_nl)
  if not ok then return false, werr end
  return true, "removed"
end


-- Purge archived manifests for every depot referenced by a .lua, BEFORE the
-- .lua is deleted (it's what tells us which depots belong to the game).
-- Reads `addappid(<id> ...)` ids and deletes
-- ~/.config/SLSsteam/manifests/<id>_*.manifest for each (no-op when absent).
-- The persistent store (ManifestStore in slsteam-moon) keeps every manifest
-- version a game ever staged; when the user removes the game via LuaTools its
-- archived manifests would otherwise linger forever, so drop them here.
-- Returns true,count | false,error.
function slsteam.purge_store_for_lua(lua_path)
  local home = os.getenv("HOME") or ""
  if home == "" then return false, "HOME not set" end
  local f = io.open(lua_path, "rb")
  if not f then return true, 0 end
  local data = f:read("*a") or ""
  f:close()

  local store = home .. "/.config/SLSsteam/manifests"
  local seen, count = {}, 0
  for id in data:gmatch("addappid%s*%(%s*(%d+)") do
    if not seen[id] then
      seen[id] = true
      -- prefix single-quoted; the glob stays unquoted so the shell expands it.
      os.execute("rm -f -- " .. shsq(store .. "/" .. id .. "_") ..
                 "*.manifest 2>/dev/null")
      count = count + 1
    end
  end
  return true, count
end


-- Purge this app's pins from slsteam-moon's ManifestPins map in config.yaml
-- (game-updates-pinning design §1 Cleanup / §4.4). ManifestPins is a nested
-- block map:
--   ManifestPins:
--     <appid>:
--       locked: <bool>
--       depots:
--         <depot>: "<gid>"
-- Removes the whole "  <appid>:" sub-block (header + locked + depots + entries)
-- and, if that leaves ManifestPins with no app entries, the "ManifestPins:"
-- header too. Byte-preserving + atomic, like the other editors here.
-- Returns true,"removed" | true,"not_present" | false,error.
function slsteam.purge_pins_for_app(appid)
  appid = tonumber(appid)
  if not appid then return false, "invalid appid" end

  local path = config_path()
  if not path then return false, "HOME not set" end
  local lines, has_trailing_nl = read_lines(path)
  if not lines then return false, "SLSsteam config.yaml not found" end

  -- locate the ManifestPins block [header_idx .. block_end]
  local header_idx
  for i, line in ipairs(lines) do
    if line:match("^ManifestPins%s*:") then header_idx = i break end
  end
  if not header_idx then return true, "not_present" end

  local block_end = #lines
  for i = header_idx + 1, #lines do
    if lines[i]:match("^%S") then block_end = i - 1 break end
  end

  -- find the target app's sub-block: "  <appid>:" until the next "  <id>:"
  -- (2-space-indented key) or the end of the block.
  local app_start, app_end
  for i = header_idx + 1, block_end do
    local id = lines[i]:match("^  (%d+)%s*:%s*$")
    if id then
      if tonumber(id) == appid then
        app_start = i
        app_end = block_end
        for j = i + 1, block_end do
          if lines[j]:match("^  %S") then app_end = j - 1 break end
        end
        break
      end
    end
  end
  if not app_start then return true, "not_present" end

  for i = app_end, app_start, -1 do table.remove(lines, i) end

  -- if no app entries remain under the header, drop the header line as well.
  local new_end = #lines
  for i = header_idx + 1, #lines do
    if lines[i]:match("^%S") then new_end = i - 1 break end
  end
  local any_app = false
  for i = header_idx + 1, new_end do
    if lines[i]:match("^  (%d+)%s*:") then any_app = true break end
  end
  if not any_app then table.remove(lines, header_idx) end

  local ok, werr = write_lines_atomic(path, lines, has_trailing_nl)
  if not ok then return false, werr end
  return true, "removed"
end

return slsteam
