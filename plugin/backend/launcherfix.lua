-- launcherfix.lua  (Linux overlay for luatools-moon)
--
-- Some crack/bypass archives ship their OWN launcher (FC25's Launcher.exe, an
-- EA/Denuvo unlocker, ...) that is the real entry point: you run the launcher
-- and it starts the game the correct way (it injects the crack / has a "play"
-- button). On Linux the game runs through Proton, and the way to point Steam's
-- Play button at that launcher is the launch option:
--
--   bash -c "cmd=(%command%)"'; cmd[-1]="$PWD/Launcher.exe"; "${cmd[@]}"'
--
-- Steam expands %command% to Proton's argv. The wrapper captures that argv,
-- replaces only the final element (the Windows executable) with the launcher
-- shipped by the fix, then executes the resulting array unchanged. $PWD is
-- Steam's game install directory, so the launcher path remains relative.
--
-- This module is PURE (no Millennium deps) so it is unit-tested with a stock
-- lua interpreter (scripts/test-launcherfix.lua). The launcher is discovered
-- from the crack manifest downloader.sh writes (.slssteam_fix_launchers), so we
-- redirect only to a launcher the CRACK shipped, never to a game's own
-- pre-existing launcher.exe.

local launcherfix = {}

-- ---------------------------------------------------------------------------
-- Recognise a launcher exe by name.
-- ---------------------------------------------------------------------------

-- Basename of a (possibly slash/backslash) path, lowercased.
local function basename_lower(name)
  local b = tostring(name):gsub("\\", "/")
  b = b:match("[^/]+$") or b
  return b:lower()
end

-- is_launcher(name): true when `name`'s basename is launcher.exe,
-- launcher_<x>.exe or <x>_launcher.exe (case-insensitive). Anything else (a
-- plain game exe, a non-exe, a mere substring like "relauncher.exe") is false.
function launcherfix.is_launcher(name)
  if type(name) ~= "string" or name == "" then return false end
  local b = basename_lower(name)
  return b == "launcher.exe"
      or b:match("^launcher_.+%.exe$") ~= nil
      or b:match("^.+_launcher%.exe$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Pick the best launcher relpath from a list.
-- ---------------------------------------------------------------------------

-- Normalise a path to forward slashes and drop a leading "./".
local function norm_rel(p)
  p = tostring(p):gsub("\\", "/")
  p = p:gsub("^%./", "")
  return p
end

-- Path depth = number of slash-separated components.
local function depth(p)
  local n = 1
  for _ in p:gmatch("/") do n = n + 1 end
  return n
end

-- pick(relpaths): choose the best launcher among a list of relative paths.
-- Preference: an exact-basename "launcher.exe" first; otherwise the shallowest
-- launcher (then first in list order). Non-launcher entries are ignored.
-- Returns the chosen relpath (forward-slash normalised) or nil.
function launcherfix.pick(relpaths)
  if type(relpaths) ~= "table" then return nil end
  local best, best_depth
  for _, raw in ipairs(relpaths) do
    if type(raw) == "string" and launcherfix.is_launcher(raw) then
      local rel = norm_rel(raw)
      if basename_lower(rel) == "launcher.exe" then
        return rel  -- exact basename always wins
      end
      local d = depth(rel)
      if not best or d < best_depth then
        best, best_depth = rel, d
      end
    end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- Build / merge / strip the redirect launch option.
-- ---------------------------------------------------------------------------

-- Encode a game-relative path inside the double-quoted assignment which is, in
-- turn, contained in the single-quoted part of the outer launch option.
local function escape_launcher_path(rel)
  return (rel:gsub("[\"$`']", function(ch)
    if ch == "'" then return "'" .. "\\" .. "''" end
    return "\\" .. ch
  end))
end

-- build_redirect(rel_path): build the argv-preserving Proton wrapper for the
-- fix-provided launcher relative to Steam's game working directory. Quotes,
-- dollars, backticks and spaces in archive paths remain literal. Returns nil
-- for empty, absolute, traversal or control-character paths.
function launcherfix.build_redirect(rel_path)
  if type(rel_path) ~= "string" or rel_path == "" then return nil end
  local rel = norm_rel(rel_path)
  if rel == "" or rel:sub(1, 1) == "/" or rel:match("^%a:/")
      or rel == ".." or rel:match("^%.%./") or rel:find("/../", 1, true)
      or rel:sub(-3) == "/.." or rel:find("[%z\r\n]") then
    return nil
  end
  rel = escape_launcher_path(rel)
  return "bash -c \"cmd=(%command%)\"'; cmd[-1]=\"$PWD/" .. rel
      .. "\"; \"${cmd[@]}\"'"
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local WRAPPER_START = 'bash -c "cmd=(%command%)"\''
local WRAPPER_END = '; "${cmd[@]}"\''

local function remove_current_wrapper(current)
  local first = current:find(WRAPPER_START, 1, true)
  if not first then return nil end
  local _, last = current:find(WRAPPER_END, first + #WRAPPER_START, true)
  if not last then return nil end

  local before = trim(current:sub(1, first - 1))
  local after = trim(current:sub(last + 1))
  if before == "" and after == "" then return "" end

  local pieces = {}
  if before ~= "" then pieces[#pieces + 1] = before end
  pieces[#pieces + 1] = "%command%"
  if after ~= "" then pieces[#pieces + 1] = after end
  return table.concat(pieces, " ")
end

-- remove_redirect(current): strip our argv wrapper and restore %command% while
-- preserving surrounding user options. It also understands the legacy
-- '"<absolute launcher.exe>" %command%' form so reapply and Unfix migrate old
-- installs cleanly. If the redirect was the whole value, returns "".
function launcherfix.remove_redirect(current)
  current = tostring(current or "")
  local without_wrapper = remove_current_wrapper(current)
  if without_wrapper ~= nil then return without_wrapper end

  local cmd = current:find("%command%", 1, true)
  if not cmd then return current end
  local head = current:sub(1, cmd - 1)
  -- the launcher token is the last quoted *.exe right before %command%.
  local before = head:match('^(.-)%s*"[^"]*%.[eE][xX][eE]"%s*$')
  if not before then return current end
  before = trim(before)
  if before == "" then return "" end
  return before .. " %command%"
end

-- Replace the LAST occurrence of %command% in `s` with `repl` (plain strings;
-- no Lua-pattern interpretation of either side).
local function replace_last_command(s, repl)
  local last, from = nil, 1
  while true do
    local a = s:find("%command%", from, true)
    if not a then break end
    last = a; from = a + 1
  end
  if not last then return nil end
  return s:sub(1, last - 1) .. repl .. s:sub(last + #"%command%")
end

-- merge_launch_options(current, rel_path): compose the redirect for `rel_path`
-- into `current`, idempotently. Any prior launcher redirect (even to a
-- different exe) is removed first, so this both re-points and avoids stacking.
-- The redirect replaces the single %command% token (one is added if `current`
-- had none), so a leading env prefix / wrapper survives and exactly one
-- %command% remains. PURE.
function launcherfix.merge_launch_options(current, rel_path)
  local redirect = launcherfix.build_redirect(rel_path)
  if not redirect then return current or "" end

  local cleaned = launcherfix.remove_redirect(current or "")
  if not cleaned:find("%command%", 1, true) then
    cleaned = (cleaned == "") and "%command%" or (cleaned .. " %command%")
  end

  local out = replace_last_command(cleaned, redirect)
  return trim(out or redirect)
end

-- ---------------------------------------------------------------------------
-- Resolve the launcher from the crack manifest.
-- ---------------------------------------------------------------------------

-- Manifest written by downloader.sh: the launcher-pattern exes the crack
-- archive shipped, one relpath per line (forward-slash). '#' lines ignored.
local MANIFEST_NAME = ".slssteam_fix_launchers"

local function default_reader(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

-- Join an install dir and a relpath into an absolute path (single separator).
local function join(install_path, rel)
  return (install_path:gsub("/+$", "")) .. "/" .. rel
end

-- Parse the manifest text into a list of non-comment, non-blank relpaths.
local function parse_manifest(text)
  local out = {}
  for line in (tostring(text) .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
    local s = trim(line)
    if s ~= "" and s:sub(1, 1) ~= "#" then out[#out + 1] = s end
  end
  return out
end

-- launcher_for_install_dir(install_path, read_file): read the fix launcher
-- manifest, pick the best launcher, and return its absolute path plus its
-- game-relative path. The second value feeds build_redirect; retaining the
-- absolute first value keeps existing callers and diagnostics compatible.
function launcherfix.launcher_for_install_dir(install_path, read_file)
  install_path = tostring(install_path or "")
  if install_path == "" then return nil end
  read_file = read_file or default_reader

  local raw = read_file(join(install_path, MANIFEST_NAME))
  if not raw or raw == "" then return nil end
  local best = launcherfix.pick(parse_manifest(raw))
  if not best then return nil end
  return join(install_path, best), best
end

return launcherfix
