-- fix_overlays.lua  (Linux overlay for luatools-moon)
--
-- Some Windows fixes replace a DLL for which Wine has a builtin implementation
-- (winmm, winhttp, version, ...). Wine may prefer that builtin and skip the
-- fix's proxy, so those collisions need a native-first WINEDLLOVERRIDES entry.
-- Private payload DLLs such as OnlineFix, steam_api and voices38 do not collide
-- with a Wine builtin: normal Windows DLL lookup already loads them natively,
-- and forcing them only adds noise and can hide the real failure mode.
--
-- This module is PURE (no Millennium deps) so it can be unit-tested with
-- a stock lua interpreter (scripts/test-fix-overlays.lua). It does two
-- things:
--   * build_overrides(dll_names) -> the WINEDLLOVERRIDES string for shipped
--     DLLs that actually collide with a known Wine builtin.
--   * merge_launch_options(current, overrides) -> splice that override
--     into the user's existing launch options idempotently, preserving
--     their options and %command%.
-- Plus is_proton_tool() to gate the whole thing (native Linux builds
-- ignore Windows DLLs, so overriding there is pointless/noise).

local fix_overlays = {}

-- Common Wine builtins used as proxy/loader vectors. We intentionally keep a
-- conservative allowlist: an unknown DLL is safer left to normal loader rules
-- than guessed into WINEDLLOVERRIDES. "n,b" means try native first and use the
-- builtin only if native loading fails; it does not load both implementations.
local SYSTEM_PROXY = {
  winmm = true, winhttp = true, version = true, dxgi = true, dinput8 = true,
  dinput = true, dsound = true, ddraw = true,
  d3d8 = true, d3d9 = true, d3d10 = true, d3d10_1 = true,
  d3d10core = true, d3d11 = true, d3d12 = true, d3d12core = true,
  wininet = true, wintrust = true, dbghelp = true, crypt32 = true,
  iphlpapi = true, opengl32 = true, ws2_32 = true,
  xinput1_1 = true, xinput1_2 = true, xinput1_3 = true, xinput1_4 = true,
  xinput9_1_0 = true, xinputuap = true,
}

local function is_system_proxy(stem_lower)
  if SYSTEM_PROXY[stem_lower] then return true end
  if stem_lower:match("^d3dcompiler_%d+$") then return true end
  if stem_lower:match("^d3dx9_%d+$") then return true end
  if stem_lower:match("^d3dx10_%d+$") then return true end
  if stem_lower:match("^d3dx11_%d+$") then return true end
  return false
end

local function build_inferred_overrides(names)
  if type(names) ~= "table" then return nil end
  local seen, order = {}, {}
  for _, name in ipairs(names) do
    local text = tostring(name)
    local stem = text:match("^(.-)%.[Dd][Ll][Ll]$")
    if stem then
      local key = stem:lower()
      if is_system_proxy(key) and not seen[key] then
        seen[key] = true
        order[#order + 1] = key
      end
    end
  end
  if #order == 0 then return nil end
  local parts = {}
  for _, stem in ipairs(order) do
    parts[#parts + 1] = stem .. "=n,b"
  end
  return 'WINEDLLOVERRIDES="' .. table.concat(parts, ";") .. '"'
end

-- Build the minimal override from DLL basenames found in a fix payload.
function fix_overlays.build_overrides(dll_names)
  return build_inferred_overrides(dll_names)
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

-- dlllist.txt is evidence about the fix's loader chain, but it is not Wine
-- load-order metadata. Apply the same conservative builtin-collision filter.
function fix_overlays.build_overrides_from_list(names)
  return build_inferred_overrides(names)
end

-- The extraction manifest is authoritative about which files the fix shipped,
-- not about Wine load order. Filter it to actual builtin collisions too.
function fix_overlays.build_overrides_all(names)
  return build_inferred_overrides(names)
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
--   * places the override at the FRONT -- it is an environment assignment, so
--     it must precede any wrapper (mangohud/gamemoderun/...): Steam only reads
--     leading VAR=VALUE tokens as env; one after a wrapper is passed as an
--     argument and never takes effect,
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

  -- Prepend the override so it sits before any wrapper. If the user options
  -- have no %command%, append one so the game still launches.
  if rest:find("%%command%%") then
    return (overrides .. " " .. rest):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
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
-- A fix's own dlllist.txt is not always complete, so legacy installs without an
-- extraction manifest union its entries with known system proxies found in the
-- folder. New installs use the exact extraction manifest and never fall through
-- to unrelated game DLLs, even when no override is needed.
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
  local manifest_path
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and not entry.is_directory and entry.name then
      names[#names + 1] = entry.name
      local low = tostring(entry.name):lower()
      if entry.path then
        if not manifest_path and low == ".slssteam_fix_dlls" then
          manifest_path = entry.path
        elseif not dlllist_path and low == "dlllist.txt" then
          dlllist_path = entry.path
        end
      end
    end
  end

  -- The extraction manifest is authoritative. Returning nil here is deliberate:
  -- it means the fix shipped no DLL that collides with a Wine builtin. Falling
  -- through would risk mistaking an unrelated game DLL for a fix proxy.
  if manifest_path then
    local listed = fix_overlays.parse_dlllist(read_file(manifest_path))
    return fix_overlays.build_overrides_all(listed)
  end

  -- Legacy fallback: retain only known Wine builtin collisions found on disk.
  local folder_recognized = {}
  for _, n in ipairs(names) do
    local stem = tostring(n):lower():match("^(.+)%.dll$")
    if stem and is_system_proxy(stem) then
      folder_recognized[#folder_recognized + 1] = tostring(n)
    end
  end

  -- Union dlllist evidence with folder proxies, then apply the same filter.
  local union = {}
  if dlllist_path then
    for _, n in ipairs(fix_overlays.parse_dlllist(read_file(dlllist_path))) do
      union[#union + 1] = n
    end
  end
  for _, n in ipairs(folder_recognized) do
    union[#union + 1] = n
  end

  return fix_overlays.build_overrides_from_list(union)
end

return fix_overlays
