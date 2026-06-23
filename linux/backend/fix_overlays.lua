-- fix_overlays.lua  (Linux overlay for luatools-moon)
--
-- Online/generic game fixes are Windows DLLs (OnlineFix64.dll,
-- steam_api64.dll, ...). When the game runs through Proton, Wine loads
-- its own *builtin* implementations of those DLLs by default and ignores
-- the ones the fix dropped into the game folder, so the fix has no
-- effect (typical symptom: "SteamAPI_Init() failed" / online never
-- connects). The standard remedy on Linux is a WINEDLLOVERRIDES launch
-- option that forces Wine to load the *native* (fix-provided) DLLs first.
-- See the LinuxCrackSupport "Online-Fix" guides.
--
-- This module is PURE (no Millennium deps) so it can be unit-tested with
-- a stock lua interpreter (scripts/test-fix-overlays.lua). It does two
-- things:
--   * build_overrides(dll_names) -> the WINEDLLOVERRIDES string for the
--     DLLs a fix actually shipped (only those, never a blanket list).
--   * merge_launch_options(current, overrides) -> splice that override
--     into the user's existing launch options idempotently, preserving
--     their options and %command%.
-- Plus is_proton_tool() to gate the whole thing (native Linux builds
-- ignore Windows DLLs, so overriding there is pointless/noise).

local fix_overlays = {}

-- DLLs that are loader stubs Wine also provides and that the game still
-- needs to fall back to after the fix's hook runs -> load native THEN
-- builtin ("n,b"). Everything else the fix ships is its own code and
-- replaces the builtin entirely -> native only ("n").
local NATIVE_THEN_BUILTIN = {
  winmm = true,
  winhttp = true,
  version = true,
  dxgi = true,
  dinput8 = true,
}

-- DLL basenames (without extension, lowercased) we recognise as part of
-- a fix payload and are willing to override. Anything not here is left
-- alone so we never touch unrelated game DLLs.
local KNOWN_FIX_DLLS = {
  onlinefix64 = "OnlineFix64",
  onlinefix = "OnlineFix",
  steamoverlay64 = "SteamOverlay64",
  steamoverlay = "SteamOverlay",
  dnet = "dnet",
  steam_api64 = "steam_api64",
  steam_api = "steam_api",
  winmm = "winmm",
  winhttp = "winhttp",
  version = "version",
  dxgi = "dxgi",
  dinput8 = "dinput8",
}

-- Build the WINEDLLOVERRIDES string from a list of DLL basenames (as
-- found in the game folder). Returns the full launch-option fragment, or
-- nil if none of the names are recognised fix DLLs.
function fix_overlays.build_overrides(dll_names)
  if type(dll_names) ~= "table" then return nil end

  local seen = {}
  local order = {}
  for _, name in ipairs(dll_names) do
    local base = tostring(name):lower()
    -- strip a .dll extension if present; ignore anything else.
    local stem = base:match("^(.+)%.dll$")
    if stem and KNOWN_FIX_DLLS[stem] and not seen[stem] then
      seen[stem] = true
      order[#order + 1] = stem
    end
  end

  if #order == 0 then return nil end

  local parts = {}
  for _, stem in ipairs(order) do
    local key = KNOWN_FIX_DLLS[stem]
    if NATIVE_THEN_BUILTIN[stem] then
      parts[#parts + 1] = key .. "=n,b"
    else
      parts[#parts + 1] = key .. "=n"
    end
  end

  return 'WINEDLLOVERRIDES="' .. table.concat(parts, ";") .. '"'
end

-- Strip any existing WINEDLLOVERRIDES="..." (or unquoted) assignment from
-- a launch-options string, returning the remainder trimmed. Used so a
-- re-apply replaces rather than stacks.
local function strip_existing_override(s)
  -- quoted form: WINEDLLOVERRIDES="...."
  s = s:gsub('WINEDLLOVERRIDES=".-"%s*', "")
  -- unquoted form: WINEDLLOVERRIDES=foo=n;bar=n (up to next space)
  s = s:gsub("WINEDLLOVERRIDES=[^%s]+%s*", "")
  -- collapse doubled spaces left behind, trim ends.
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- Merge `overrides` (a full WINEDLLOVERRIDES="..." fragment) into the
-- user's `current` launch options. Idempotent and order-preserving:
--   * removes any prior WINEDLLOVERRIDES assignment first (no stacking),
--   * places the override BEFORE %command% (env precedes the command),
--   * keeps every other user option and a single %command%.
function fix_overlays.merge_launch_options(current, overrides)
  current = current or ""
  local rest = strip_existing_override(current)

  if rest == "" then
    return overrides .. " %command%"
  end

  if rest:find("%%command%%") then
    -- insert override immediately before the first %command%.
    local new = rest:gsub("%%command%%", overrides .. " %%command%%", 1)
    return (new:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
  end

  -- no %command% present: override first, then the user options, then a
  -- trailing %command% so the game still launches.
  return overrides .. " " .. rest .. " %command%"
end

-- True only for Proton / Wine-based compat tools, where Windows DLL
-- overrides make sense. Native Linux (empty tool) and the linux runtime
-- shims return false.
function fix_overlays.is_proton_tool(name)
  if type(name) ~= "string" or name == "" then return false end
  local l = name:lower()
  if l:find("steamlinuxruntime", 1, true) then return false end
  if l:find("proton", 1, true) then return true end
  return false
end

-- Scan a game install folder (recursively) for fix DLLs and return the
-- WINEDLLOVERRIDES string, or nil if none are present. `fs_impl` is the
-- Millennium fs module (injected so this stays unit-testable); it must
-- expose list_recursive(path) -> array of entries with .name and
-- .is_directory. Any failure degrades to nil (no override).
function fix_overlays.overrides_for_install_dir(fs_impl, install_path)
  if type(fs_impl) ~= "table" or type(fs_impl.list_recursive) ~= "function" then
    return nil
  end
  local ok, entries = pcall(fs_impl.list_recursive, install_path)
  if not ok or type(entries) ~= "table" then return nil end

  local names = {}
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and not entry.is_directory and entry.name then
      names[#names + 1] = entry.name
    end
  end
  return fix_overlays.build_overrides(names)
end

return fix_overlays
