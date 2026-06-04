-- slsteam.lua  (Linux overlay for slsteammoon-ltsteamplugin)
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
      local entry_indent, rest = line:match("^(%s+)%-%s+(.*)$")
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
      local entry_indent, rest = line:match("^(%s+)%-%s+(.*)$")
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

return slsteam
