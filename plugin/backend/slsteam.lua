-- slsteam.lua  (Linux overlay for luatools-moon)
--
-- App presence is discovered from config/stplug-in/*.lua by slsteam-moon, so
-- this module does not maintain AdditionalApps. It only edits settings that
-- remain in config.yaml and removes per-app manifest state.
--
-- Design notes:
--   * Pure Lua + os/io only (no Millennium fs needed).
--   * Edits preserve comments, ordering and unrelated keys.
--   * Atomic writes ensure watchers only observe complete files.

local slsteam = {}

local function config_root()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then return xdg end
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  return home .. "/.config"
end

local function config_path()
  local root = config_root()
  if not root then return nil end
  return root .. "/SLSsteam/config.yaml"
end

local function cache_dir()
  local root = config_root()
  if not root then return nil end
  return root .. "/SLSsteam/cache"
end

local function shell_single_quote(value)
  local quote = string.char(39)
  local escaped = tostring(value):gsub(quote,
    quote .. string.char(92) .. quote .. quote)
  return quote .. escaped .. quote
end

-- Return readable for a regular cache file, missing when metadata confirms
-- that it is absent, and unreadable when the path exists but cannot be opened.
-- The latter must fail closed: cleanup cannot delete the source Lua script
-- while an artifact's state is unknown.
local function file_state(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return "readable"
  end
  local status, reason, code = os.execute("test -f " .. shell_single_quote(path) ..
                                        " >/dev/null 2>&1")
  if status == true or status == 0 then return "unreadable" end
  -- test(1) exits 1 for a confirmed non-match. LuaJIT returns 256
  -- (the shell exit code shifted by 8), while newer Lua returns the code as
  -- the third result. Any other result means metadata inspection failed.
  if (status == nil or status == false) and code == 1 then return "missing" end
  if type(status) == "number" and status == 256 then return "missing" end
  return "unknown"
end

-- Quarantine app-scoped cache artifacts explicitly tied to an app removed by
-- LuaTools. ManifestId files are depot-scoped and are intentionally left to
-- the native watcher, which has the app-to-depot relation index needed to
-- preserve pins shared by multiple scripts. This mirrors
-- AppInfoProvision::forgetApp's recoverable contract: rename, never delete.
-- The Lua-side call is needed because Lumen and the injected client are
-- separate processes and the plugin has no C++ module loader.
-- Returns true,count | false,error,count.
local forget_sequence = 0

local function quarantine_file(original, suffix)
  for attempt = 0, 1024 do
    local target = original .. suffix
    if attempt > 0 then target = target .. "." .. tostring(attempt) end
    -- GNU mv -n performs an atomic no-replace rename. If the destination
    -- already exists it exits successfully but leaves the source in place;
    -- detect that case and retry with a suffix instead of unlinking a source
    -- that a native writer may have replaced concurrently.
    local status = os.execute("mv -n -- " .. shell_single_quote(original) ..
                             " " .. shell_single_quote(target) ..
                             " >/dev/null 2>&1")
    if status == true or status == 0 then
      local source_state = file_state(original)
      local target_state = file_state(target)
      if source_state == "missing"
         and (target_state == "readable" or target_state == "unreadable") then
        return target
      end
      if source_state == "readable" or source_state == "unreadable" then
        if target_state == "readable" or target_state == "unreadable" then
          -- No-replace collision: preserve the existing quarantine and try the
          -- next destination. A successful move must remove the source.
        else
          return nil
        end
      else
        return nil
      end
    else
      return nil
    end
  end
  return nil
end

function slsteam.forget_app(appid)
  appid = tonumber(appid)
  if not appid or appid <= 0 or appid ~= math.floor(appid) then
    return false, "invalid appid", 0
  end

  local dir = cache_dir()
  if not dir then return false, "HOME not set", 0 end
  local id = tostring(appid)
  local names = {
    "picsbuffer_" .. id .. ".bin",
    "picsbuffer_" .. id .. ".yaml",
    "synthetic_" .. id,
    "ticket_" .. id .. ".yaml",
    "encryptedTicket_" .. id .. ".yaml",
  }
  forget_sequence = forget_sequence + 1
  local suffix = ".forgotten." .. tostring(os.time()) .. "." ..
                 tostring(forget_sequence)
  local count = 0
  local failed = {}
  for _, name in ipairs(names) do
    local original = dir .. "/" .. name
    local state = file_state(original)
    if state == "unreadable" or state == "unknown" then
      failed[#failed + 1] = name
    elseif state == "readable" then
      if quarantine_file(original, suffix) then
        count = count + 1
      else
        failed[#failed + 1] = name
      end
    end
  end
  if #failed > 0 then
    return false, "failed to quarantine: " .. table.concat(failed, ", "), count
  end
  return true, count
end

-- Read the file while preserving its exact line endings.
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
-- FakeAppIds is a block map:
--   FakeAppIds:
--     <appid>: <fake>
-- It uses the same byte-preserving, atomic editing as the other helpers.
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
      local status = os.execute("rm -f -- " .. shsq(store .. "/" .. id .. "_") ..
                              "*.manifest 2>/dev/null")
      if status ~= true and status ~= 0 then
        return false, "failed to purge manifests for depot " .. id, count
      end
      count = count + 1
    end
  end
  return true, count
end


-- Purge this app's pins from slsteam-moon's ManifestPins map in config.yaml.
-- ManifestPins is a nested block map:
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
  if not lines then return true, "not_present" end

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
