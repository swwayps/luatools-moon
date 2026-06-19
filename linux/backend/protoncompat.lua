-- protoncompat.lua  (Linux overlay for slsteammoon-ltsteamplugin)
--
-- Tells whether the user has forced a Steam Play compatibility tool (Proton)
-- for a given appid. The Online Fix feature needs this: an online fix is a
-- bundle of Windows DLLs that only loads under Proton/Wine. A game that ships
-- a native Linux build runs WITHOUT Proton by default, so dropping a Windows
-- fix into it does nothing. The fix only makes sense once the user forces the
-- game through Proton (Properties -> Compatibility -> "Force the use of a
-- specific Steam Play compatibility tool").
--
-- Steam stores that per-game choice in:
--   <steam-root>/config/config.vdf
--     InstallConfigStore > Software > Valve > Steam > CompatToolMapping
--       "<appid>" { "name" "<tool>" "config" "" "priority" "250" }
--
-- "name" empty  -> no tool forced (native game stays native).
-- "name" set    -> forced through that tool (Proton makes the fix loadable).
--
-- (slsteam-moon injects a CompatToolMapping into appcache/appinfo.vdf for
-- Windows-only titles; that's a DIFFERENT file. config.vdf only ever holds
-- the user's own explicit choice, which is exactly what we want here.)
--
-- PURE module (no Millennium deps) so it can be unit-tested with a stock lua
-- interpreter (scripts/test-protoncompat.lua).

local protoncompat = {}

-- Steam Linux runtime tool names. Forcing one of THESE on a native game still
-- runs it natively (they are containers, not Wine), so a Windows online fix
-- still wouldn't load -> treated as "not Proton".
local NATIVE_RUNTIMES = {
  ["steamlinuxruntime"] = true,
  ["steamlinuxruntime_scout"] = true,
  ["steamlinuxruntime_soldier"] = true,
  ["steamlinuxruntime_sniper"] = true,
  ["steamlinuxruntime_1.0"] = true,
}

-- A non-empty tool name that isn't a bare Linux runtime means the game runs
-- through Proton/Wine, so a Windows online fix can load. Returns a boolean.
function protoncompat.is_proton_name(name)
  if type(name) ~= "string" then return false end
  local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then return false end
  if NATIVE_RUNTIMES[trimmed:lower()] then return false end
  return true
end

-- Walk from the byte at an opening '{' to its matching '}', skipping over
-- quoted strings so a brace inside a "..." value can't unbalance the count.
-- `open_pos` is the index of the '{'. Returns the inner substring, or nil.
local function block_after(s, open_pos)
  local depth = 0
  local i = open_pos
  local n = #s
  local content_start = open_pos + 1
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' then
      i = i + 1
      while i <= n and s:sub(i, i) ~= '"' do i = i + 1 end
    elseif c == '{' then
      depth = depth + 1
    elseif c == '}' then
      depth = depth - 1
      if depth == 0 then return s:sub(content_start, i - 1) end
    end
    i = i + 1
  end
  return nil
end

-- Inner block that follows a quoted key, e.g. "CompatToolMapping" { ... }.
local function section_block(s, key)
  local kpos = s:find('"' .. key .. '"', 1, true)
  if not kpos then return nil end
  local open = s:find("{", kpos, true)
  if not open then return nil end
  return block_after(s, open)
end

-- Forced tool name for an appid out of a config.vdf blob. Returns the name
-- string ("" when the entry exists but is unset) or nil when the appid has no
-- CompatToolMapping entry at all (or the file isn't config.vdf-shaped).
function protoncompat.tool_for_app(raw, appid)
  if type(raw) ~= "string" or raw == "" then return nil end
  appid = tostring(appid)
  if not appid:match("^%d+$") then return nil end

  local mapping = section_block(raw, "CompatToolMapping")
  if not mapping then return nil end

  -- Match the appid as a quoted KEY whose value is a block. The quotes anchor
  -- an exact match (so "5900" can't match inside "285900"), and requiring a
  -- following '{' skips any value that merely happens to equal the appid.
  local pat = '"' .. appid .. '"%s*{'
  local from = 1
  while true do
    local a, b = mapping:find(pat, from)
    if not a then return nil end
    local inner = block_after(mapping, b)  -- b is the '{'
    if inner then
      return inner:match('"[Nn]ame"%s*"([^"]*)"') or ""
    end
    from = b + 1
  end
end

local function default_reader(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

-- True only when `appid` is forced through a Proton/compat tool in config.vdf.
-- `read_file` is injectable for tests; defaults to an io-based reader.
-- Conservative on the "unknown" side: if no config.vdf is readable we return
-- false (not forced) rather than guess, so the caller can decide what to do.
function protoncompat.is_forced(home, appid, read_file)
  home = home or os.getenv("HOME") or ""
  if home == "" then return false end
  read_file = read_file or default_reader

  -- Steam's data root varies by distro/install; config.vdf lives at
  -- <root>/config/config.vdf. ~/.steam/steam is normally a symlink to it.
  local candidates = {
    home .. "/.steam/steam/config/config.vdf",
    home .. "/.local/share/Steam/config/config.vdf",
    home .. "/.steam/debian-installation/config/config.vdf",
    home .. "/.steam/root/config/config.vdf",
  }
  for _, p in ipairs(candidates) do
    local raw = read_file(p)
    if raw and raw ~= "" then
      local name = protoncompat.tool_for_app(raw, appid)
      if name ~= nil then
        return protoncompat.is_proton_name(name)
      end
    end
  end
  return false
end

return protoncompat
