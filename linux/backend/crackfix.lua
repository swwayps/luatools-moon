-- crackfix.lua  (Linux overlay for slsteammoon-ltsteamplugin)
--
-- Resolves a Steam appid to a Crack/Bypass archive on the ryuu.lol fixes
-- catalogue. There is no appid index endpoint on the source, so we ship a
-- pre-scraped JSON map (backend/ryuu_index.json, built by scripts/ryuu_index.sh)
-- and look it up offline. A user-local cache copy is refreshed in the
-- background (non-blocking) so newly added fixes appear without a new release.
--
--   index schema: { generated, source, count,
--                   fixes = { ["<appid>"] = { { file=, badge= }, ... } } }
--   download URL : https://generator.ryuu.lol/fixes/<url-encoded file>
--
-- The PURE helpers (url_encode, build_url, pick_entry, is_hypervisor,
-- lookup) carry the logic and are unit-tested (scripts/test-crackfix.lua).
-- check() is the impure entry point (fs + json + detached refresh) used by
-- the CheckForFixes RPC.

local crackfix = {}

local BASE_URL = "https://generator.ryuu.lol/fixes/"
local SOURCE_URL = "https://generator.ryuu.lol/fixes"
-- Refresh the user-local cache at most this often (seconds).
local REFRESH_TTL = 6 * 60 * 60

-- Percent-encode a fix filename for the download URL. Encodes everything that
-- isn't an RFC-3986 unreserved char or one of the few path-safe punctuation
-- marks ryuu filenames actually use, so spaces/®/&/' etc. become %XX. The
-- forward slash is never present in a filename, so encoding it is moot.
function crackfix.url_encode(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Full download URL for a fix filename.
function crackfix.build_url(filename)
  if type(filename) ~= "string" or filename == "" then return nil end
  return BASE_URL .. crackfix.url_encode(filename)
end

-- A hypervisor fix never runs under Proton. The index builder already drops
-- them, but guard at runtime too (defense in depth against a stale/odd index).
function crackfix.is_hypervisor(entry)
  if type(entry) ~= "table" then return false end
  local badge = tostring(entry.badge or ""):lower()
  local file = tostring(entry.file or ""):lower()
  return badge == "hypervisor" or file:find("hypervisor", 1, true) ~= nil
end

-- Choose the best entry from a list for one appid. Skips hypervisor entries.
-- Preference: a "bypass" badge first (pure DRM crack, most Linux-friendly),
-- then anything else, in list order. Returns the entry table or nil.
function crackfix.pick_entry(entries)
  if type(entries) ~= "table" then return nil end
  local first
  for _, e in ipairs(entries) do
    if type(e) == "table" and e.file and not crackfix.is_hypervisor(e) then
      if tostring(e.badge or ""):lower() == "bypass" then return e end
      if not first then first = e end
    end
  end
  return first
end

-- Look an appid up in a decoded index table. Returns a result table shaped
-- like the other fix entries: { status = 200|404, url?, file?, badge? }.
function crackfix.lookup(index, appid)
  local res = { status = 404, available = false }
  if type(index) ~= "table" or type(index.fixes) ~= "table" then return res end
  local entries = index.fixes[tostring(appid)]
  local entry = crackfix.pick_entry(entries)
  if not entry then return res end
  res.status = 200
  res.available = true
  res.url = crackfix.build_url(entry.file)
  res.file = entry.file
  res.badge = entry.badge
  return res
end

-- ---------------------------------------------------------------------------
-- Impure glue below (only exercised at runtime, not in the pure unit tests).
-- ---------------------------------------------------------------------------

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function file_mtime(path)
  -- Best-effort; returns 0 when stat is unavailable.
  local p = io.popen('stat -c %Y "' .. path .. '" 2>/dev/null')
  if not p then return 0 end
  local out = p:read("*a") or ""
  p:close()
  return tonumber((out:gsub("%s+", ""))) or 0
end

-- Spawn the index refresher detached so it never blocks this RPC. Writes the
-- user-local cache for the NEXT lookup. Best-effort: any failure is ignored.
local function spawn_refresh(script_path, cache_path)
  if not script_path or not cache_path then return end
  local cmd = string.format(
    'nohup bash "%s" "%s" "%s" >/dev/null 2>&1 &',
    script_path, cache_path, SOURCE_URL)
  pcall(os.execute, cmd)
end

-- check(appid, deps) -> result table for the CheckForFixes RPC.
-- `deps` is injectable for tests; in production it's nil and we resolve the
-- bundled index, the user cache, the decoder and the refresher ourselves.
function crackfix.check(appid, deps)
  appid = tonumber(appid)
  local res = { status = 0, available = false }
  if not appid then return res end

  deps = deps or {}
  local decode = deps.decode
  local bundled = deps.bundled_path
  local cache = deps.cache_path
  local readf = deps.read_file or read_file
  local mtime = deps.mtime or file_mtime
  local now = deps.now or os.time()

  if not decode then
    local ok, json = pcall(require, "json")
    if ok and json and json.decode then
      decode = function(s) local o, r = pcall(json.decode, s); return o and r or nil end
    else
      local ok2, u = pcall(require, "plugin_utils")
      if ok2 and u and u.decode_json then decode = u.decode_json end
    end
  end
  if not bundled then
    local ok, paths = pcall(require, "paths")
    if ok and paths and paths.get_plugin_dir then
      bundled = paths.get_plugin_dir() .. "/backend/ryuu_index.json"
    end
  end

  -- Prefer the freshest readable index: a non-stale cache, else the bundled.
  local raw
  if cache then
    local craw = readf(cache)
    if craw and craw ~= "" then raw = craw end
  end
  if not raw and bundled then raw = readf(bundled) end

  -- Kick a background refresh when the cache is missing or older than the TTL.
  if cache and deps.refresh_script then
    local age = now - (mtime(cache) or 0)
    if mtime(cache) == 0 or age > REFRESH_TTL then
      (deps.spawn_refresh or spawn_refresh)(deps.refresh_script, cache)
    end
  end

  if not raw or not decode then res.status = 404; return res end
  local index = decode(raw)
  if type(index) ~= "table" then res.status = 404; return res end
  return crackfix.lookup(index, appid)
end

return crackfix
