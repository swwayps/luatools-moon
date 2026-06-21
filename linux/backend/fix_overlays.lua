-- fix_overlays.lua  (Linux overlay for slsteammoon-ltsteamplugin)
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

-- System DLLs Wine ships a builtin for, used as proxy/loader vectors by
-- cracks. When a fix replaces one of these the game still needs the real
-- implementation afterwards -> chain native THEN builtin ("n,b"). Anything
-- not here is treated as the fix's own code -> native only ("n"). Used by the
-- dlllist.txt path (build_overrides_from_list), which is NOT allowlist-limited.
local SYSTEM_PROXY = {
  winmm = true, winhttp = true, version = true, dxgi = true, dinput8 = true,
  dsound = true, d3d9 = true, d3d10 = true, d3d11 = true, d3d12 = true,
  wininet = true, dbghelp = true,
  xinput1_1 = true, xinput1_2 = true, xinput1_3 = true, xinput1_4 = true,
  xinput9_1_0 = true,
}

local function classify_suffix(stem_lower)
  return SYSTEM_PROXY[stem_lower] and "=n,b" or "=n"
end

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

-- parse_dlllist(text) -> ordered array of DLL basenames a fix's dlllist.txt
-- names. Tolerates CRLF, leading/trailing space, '#' comments and stray path
-- prefixes; keeps only *.dll entries. PURE.
function fix_overlays.parse_dlllist(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in (text .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
    local name = line:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:match("[^/\\]+$") or name  -- strip any path prefix
    if name ~= "" and name:sub(1, 1) ~= "#" and name:lower():match("%.dll$") then
      out[#out + 1] = name
    end
  end
  return out
end

-- build_overrides_from_list(names): like build_overrides but NOT limited to
-- the recognised-DLL allowlist -- it forces EVERY named DLL. This is the
-- dlllist.txt path: the fix author already told us exactly which DLLs to load
-- native, so a crack using an uncommon system proxy (dsound/d3d11/...) is
-- handled too. System-proxy names chain native+builtin; the rest native only.
-- Casing of the override key is preserved from the listed filename (Wine keys
-- are case-insensitive anyway); dedup is case-insensitive. Returns nil if the
-- list yields no .dll entries.
function fix_overlays.build_overrides_from_list(names)
  if type(names) ~= "table" then return nil end
  local seen, order = {}, {}
  for _, name in ipairs(names) do
    local stem = tostring(name):gsub("%.[Dd][Ll][Ll]$", "")
    if stem ~= tostring(name) then  -- had a .dll suffix
      local key = stem:lower()
      if not seen[key] then
        seen[key] = true
        order[#order + 1] = stem
      end
    end
  end
  if #order == 0 then return nil end
  local parts = {}
  for _, stem in ipairs(order) do
    parts[#parts + 1] = stem .. classify_suffix(stem:lower())
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

  -- Self-heal: a corrupted prior value can carry more than one %command%
  -- (e.g. an earlier buggy merge). Keep only the FIRST; drop the rest, so the
  -- result always has exactly one.
  do
    local first = rest:find("%%command%%")
    if first then
      local head = rest:sub(1, first - 1)
      local tail = rest:sub(first + 9):gsub("%%command%%", "")  -- 9 = #"%command%"
      rest = (head .. "%command%" .. tail):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end
  end

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

-- Remove any WINEDLLOVERRIDES assignment from `current`, returning the launch
-- options WITHOUT it. Used by Un-Fix to restore the game's original launch
-- options (the leftover fix DLLs are inert once Wine stops being told to load
-- them). Preserves the user's other options and a single %command%; self-heals
-- a duplicated %command%. If stripping leaves only a bare "%command%" (the fix
-- had added the override to an otherwise-empty field), returns "" so the field
-- is cleared fully back to its original empty state. PURE.
function fix_overlays.remove_overrides(current)
  current = current or ""
  local rest = strip_existing_override(current)

  -- self-heal: keep only the FIRST %command% if a prior buggy merge dupliated it.
  local first = rest:find("%%command%%")
  if first then
    local head = rest:sub(1, first - 1)
    local tail = rest:sub(first + 9):gsub("%%command%%", "")  -- 9 = #"%command%"
    rest = (head .. "%command%" .. tail):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  -- a bare %command% (or empty) == no custom options -> clear fully.
  if rest == "" or rest == "%command%" then return "" end
  return rest
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
-- expose list_recursive(path) -> array of entries with .name, .path and
-- .is_directory. `read_file` is injectable (defaults to io.open) and only
-- used to read a fix's dlllist.txt. Any failure degrades to nil (no override).
--
-- A fix's own dlllist.txt (when present) is AUTHORITATIVE: it names exactly
-- which DLLs to force native, so we honour it verbatim (covers cracks using
-- uncommon system proxies). Otherwise we fall back to the recognised-DLL
-- allowlist scan.
function fix_overlays.overrides_for_install_dir(fs_impl, install_path, read_file)
  if type(fs_impl) ~= "table" or type(fs_impl.list_recursive) ~= "function" then
    return nil
  end
  local ok, entries = pcall(fs_impl.list_recursive, install_path)
  if not ok or type(entries) ~= "table" then return nil end

  read_file = read_file or function(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
  end

  local names = {}
  local dlllist_path
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and not entry.is_directory and entry.name then
      names[#names + 1] = entry.name
      if not dlllist_path and entry.path
        and tostring(entry.name):lower() == "dlllist.txt" then
        dlllist_path = entry.path
      end
    end
  end

  if dlllist_path then
    local listed = fix_overlays.parse_dlllist(read_file(dlllist_path))
    local ov = fix_overlays.build_overrides_from_list(listed)
    if ov then return ov end
  end

  return fix_overlays.build_overrides(names)
end

return fix_overlays
