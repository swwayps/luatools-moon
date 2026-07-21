-- launchopts.lua  (Linux overlay for luatools-moon)
--
-- Reads a game's current Steam "Launch Options" string from localconfig.vdf so
-- the online-fix flow can MERGE its WINEDLLOVERRIDES into whatever the user
-- already has (mangohud, gamemoderun, ...) instead of replacing it.
--
-- Why localconfig.vdf and not the in-client store? The store-page web view has
-- no SteamClient, and the SharedJSContext appDetailsStore.strLaunchOptions
-- reads back empty from that context. localconfig.vdf is the on-disk source of
-- truth Steam persists launch options to (verified: SteamClient.Apps.
-- SetAppLaunchOptions writes it within ~1s), so it is reliable here.
--
--   UserLocalConfigStore > Software > Valve > Steam > apps > <appid> >
--     "LaunchOptions"  "<string>"
--
-- The for_app() parser is PURE (no deps) and unit-tested (test-launchopts.lua).

local launchopts = {}

-- Walk from the '{' at `open_pos` to its matching '}', skipping quoted strings
-- (and \" escapes inside them) so braces in values can't unbalance the count.
-- Returns the inner substring, or nil.
local function block_after(s, open_pos)
  local depth, i, n = 0, open_pos, #s
  local start = open_pos + 1
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' then
      i = i + 1
      while i <= n do
        local d = s:sub(i, i)
        if d == "\\" then i = i + 2
        elseif d == '"' then break
        else i = i + 1 end
      end
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return s:sub(start, i - 1) end
    end
    i = i + 1
  end
  return nil
end

-- Inner block that follows a quoted key whose value is a block: "key" { ... }.
-- The next non-space after the key must be '{' (so a string value with the same
-- text isn't mistaken for a section).
local function key_block(s, key)
  local needle = '"' .. key .. '"'
  local from = 1
  while true do
    local a = s:find(needle, from, true)
    if not a then return nil end
    local b = s:find("[^%s]", a + #needle)
    if b and s:sub(b, b) == "{" then return block_after(s, b) end
    from = a + 1
  end
end

-- Read the quoted VDF string value that follows position `after`, unescaping
-- \" and \\. Returns the value or nil.
local function read_value(s, after)
  local q = s:find('"', after)
  if not q then return nil end
  local i, n, buf = q + 1, #s, {}
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" then
      local nx = s:sub(i + 1, i + 1)
      if nx == '"' then buf[#buf + 1] = '"'; i = i + 2
      elseif nx == "\\" then buf[#buf + 1] = "\\"; i = i + 2
      else buf[#buf + 1] = c; i = i + 1 end
    elseif c == '"' then
      return table.concat(buf)
    else
      buf[#buf + 1] = c; i = i + 1
    end
  end
  return nil
end

-- for_app(raw, appid) -> the LaunchOptions string for appid out of a
-- localconfig.vdf blob, or "" when absent/unset. PURE.
function launchopts.for_app(raw, appid)
  if type(raw) ~= "string" or raw == "" then return "" end
  appid = tostring(appid)
  if not appid:match("^%d+$") then return "" end

  local apps = key_block(raw, "apps")
  if not apps then return "" end
  local app = key_block(apps, appid)
  if not app then return "" end

  local marker = '"LaunchOptions"'
  local a = app:find(marker, 1, true)
  if not a then return "" end
  return read_value(app, a + #marker) or ""
end

local function default_reader(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

-- read(appid) -> current launch options string (""). Scans the Steam userdata
-- localconfig.vdf files (there may be several Steam roots / user ids) and
-- returns the first non-empty match. `list`/`read_file` are injectable for tests.
function launchopts.read(appid, home, list, read_file)
  home = home or os.getenv("HOME") or ""
  if home == "" then return "" end
  read_file = read_file or default_reader
  list = list or function(glob)
    local p = io.popen("ls -1 " .. glob .. " 2>/dev/null")
    if not p then return {} end
    local out = {}
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
  end

  local roots = {
    home .. "/.steam/steam",
    home .. "/.local/share/Steam",
    home .. "/.steam/debian-installation",
    home .. "/.steam/root",
  }
  for _, root in ipairs(roots) do
    for _, path in ipairs(list(root .. "/userdata/*/config/localconfig.vdf")) do
      local raw = read_file(path)
      if raw and raw ~= "" then
        local v = launchopts.for_app(raw, appid)
        if v ~= "" then return v end
      end
    end
  end
  return ""
end

return launchopts
