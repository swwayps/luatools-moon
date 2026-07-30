-- Harness: load the REAL dist downloads.lua with minimal stubs and exercise
--   (1) the dedup guard in start_add_via_luatools_smart, and
--   (2) the terminal-latch in get_add_status (a late "failed" must not override
--       an already-finalized "done").
-- Run from the repo root: lua5.4 scripts/test-smart-dedup.lua   (also luajit)
local TMP = "/tmp/lt-dedup-test"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP .. "/steam")

local exec_count = 0
local exec_commands = {}
local APIS = {
  { name = "Hubcap", url = "https://example.test/<appid>", success_code = 200 },
  { name = "custom/name\tline\nbreak", url = "https://custom.test/<appid>", success_code = 201 },
  { name = "Missing Key", url = "https://key.test/<appid>?key=<apikey>", api_key = "   ", success_code = 200 },
}

local function isdir(p)
  local h = io.popen("[ -d '" .. p .. "' ] && echo d || echo f")
  if not h then return false end
  local r = (h:read("*l") or "f"); h:close()
  return r == "d"
end

local function preload(name, mod) package.preload[name] = function() return mod end end

preload("fs", {
  exists = function(p) local f = io.open(p, "r"); if f then f:close(); return true end return isdir(p) end,
  join = function(...) return table.concat({ ... }, "/") end,
  create_directories = function(p) os.execute("mkdir -p '" .. p .. "'") return true end,
  list_recursive = function(dir)
    local out = {}
    local h = io.popen("find '" .. dir .. "' -mindepth 1 2>/dev/null")
    if h then
      for line in h:lines() do
        out[#out + 1] = { name = line:match("[^/]+$"), path = line, is_directory = isdir(line) }
      end
      h:close()
    end
    return out
  end,
  remove = function(p) os.remove(p); return true end,
  remove_all = function(p) os.execute("rm -rf '" .. p .. "'") return true end,
})
preload("utils", { -- m_utils
  read_file = function(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end,
  write_file = function(p, s) local f = io.open(p, "w"); if f then f:write(s); f:close() end return true end,
  getenv = function(k) if k == "HOME" then return TMP .. "/home" end return os.getenv(k) end,
  exec = function(cmd) exec_count = exec_count + 1; exec_commands[#exec_commands + 1] = cmd end, -- count launches, don't spawn
})
preload("http_client", {})
preload("config", {})
preload("plugin_logger", {
  log = function(m) print("  [log] " .. tostring(m)) end,
  warn = function(m) print("  [warn] " .. tostring(m)) end,
  info = function() end, error = function() end,
})
preload("paths", {
  get_plugin_dir = function() return "/tmp" end,
  backend_path = function(p) return TMP .. "/" .. tostring(p) end,
})
preload("steam_utils", { detect_steam_install_path = function() return TMP .. "/steam" end })
preload("plugin_utils", { ensure_temp_download_dir = function() return TMP end })
preload("api_manifest", {
  load_api_manifest = function() return APIS end,
  get_api_credential_state = function(api, hubcap_api_key)
    local url = tostring(api.url or "")
    local needs_hubcap = url:find("<moapikey>", 1, true) ~= nil
    local needs_custom = url:find("<apikey>", 1, true) ~= nil
    return {
      needsKey = needs_hubcap or needs_custom,
      locked = (needs_hubcap and tostring(hubcap_api_key or ""):match("%S") == nil)
        or (needs_custom and tostring(api.api_key or ""):match("%S") == nil),
    }
  end,
})
preload("settings.manager", { get_hubcap_api_key = function() return "" end })
preload("smart_merge", dofile("plugin/backend/smart_merge.lua"))
preload("json", { -- decode the fields downloads.lua reads from the state file
  decode = function(s)
    local status = s:match('"status"%s*:%s*"([^"]*)"')
    if not status then error("bad json") end
    return { status = status, currentApi = s:match('"currentApi"%s*:%s*"([^"]*)"'), error = s:match('"error"%s*:%s*"([^"]*)"') }
  end,
  encode = function() return "{}" end,
})

local downloads = dofile("dist/luatools/backend/downloads.lua")
local APPID = 367520
local SF = TMP .. "/" .. APPID .. "_state.json"

os.execute("mkdir -p '" .. TMP .. "/home/.config/SLSsteam/cache'")
do
  local f = assert(io.open(TMP .. "/home/.config/SLSsteam/cache/picsbuffer_" .. APPID .. ".bin", "w"))
  f:write('"appinfo" { "depots" {'
    .. ' "367521" { "config" { "oslist" "windows" }'
    .. ' "manifests" { "public" { "gid" "9001" } } }'
    .. ' "367522" { "config" { "oslist" "linux" } "dlcappid" "400000"'
    .. ' "manifests" { "public" { "gid" "9002" } } }'
    .. ' "367523" { "config" { "oslist" "macos" }'
    .. ' "manifests" { "public" { "gid" "9003" } } }'
    .. ' "400001" { "dlcappid" "400001" }'
    .. '} "extended" { "listofdlc" "400000,400001,4093670" } }')
  f:close()
end

local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else print("FAIL " .. msg); fails = fails + 1 end end

-- ── dedup guard (start_add_via_luatools_smart) ──────────────────────────────
-- (A) fresh in-flight state present -> must SKIP (no relaunch)
os.execute("printf '%s' '{\"status\":\"downloading\"}' > " .. SF)
exec_count = 0
local rA = downloads.start_add_via_luatools_smart(APPID)
check(exec_count == 0, "(A) fresh in-flight 'downloading' -> no relaunch (exec_count=" .. exec_count .. ")")
check(rA and rA.success == true, "(A) returns success (does not error the caller)")

-- (B) stale in-flight state (mtime 5 min ago) -> must RELAUNCH
os.execute("printf '%s' '{\"status\":\"downloading\"}' > " .. SF)
os.execute("touch -d '5 minutes ago' " .. SF)
exec_count = 0
downloads.start_add_via_luatools_smart(APPID)
check(exec_count >= 1, "(B) stale in-flight (>60s) -> relaunch (exec_count=" .. exec_count .. ")")

-- (C) no state file -> must PROCEED
os.execute("rm -f " .. SF)
exec_count = 0
downloads.start_add_via_luatools_smart(APPID)
check(exec_count >= 1, "(C) no state file -> proceed/launch (exec_count=" .. exec_count .. ")")

-- (D) terminal state 'done' present -> must PROCEED (re-add after success)
os.execute("printf '%s' '{\"status\":\"done\"}' > " .. SF)
exec_count = 0
downloads.start_add_via_luatools_smart(APPID)
check(exec_count >= 1, "(D) terminal 'done' -> proceed (exec_count=" .. exec_count .. ")")

-- (D2) candidate handoff is NUL-safe, ordered, custom-API aware, and private.
local candidate_path = TMP .. "/" .. APPID .. "_candidates.bin"
local candidate = io.open(candidate_path, "rb")
local candidate_data = candidate and candidate:read("*a") or ""
if candidate then candidate:close() end
local fields = {}
for field in candidate_data:gmatch("([^%z]*)%z") do fields[#fields + 1] = field end
check(#fields == 8, "(D2) two usable APIs produce two four-field NUL records")
check(fields[1] == "0" and fields[2] == "Hubcap"
  and fields[3] == "https://example.test/" .. APPID and fields[4] == "200",
  "(D3) first API preserves priority, URL substitution, and success code")
check(fields[5] == "1" and fields[6] == "custom/name\tline\nbreak"
  and fields[7] == "https://custom.test/" .. APPID and fields[8] == "201",
  "(D4) arbitrary custom API name survives NUL handoff")
check(not candidate_data:find("Missing Key", 1, true),
  "(D5) API with a blank required key is skipped")
local mode_pipe = io.popen("stat -c %a '" .. candidate_path .. "' 2>/dev/null")
local mode = mode_pipe and mode_pipe:read("*l") or ""; if mode_pipe then mode_pipe:close() end
check(mode == "600", "(D6) candidate file is private mode 0600")
local coverage_path = TMP .. "/" .. APPID .. "_coverage.tsv"
local coverage = io.open(coverage_path, "rb")
check(coverage ~= nil, "(D7) coverage handoff exists even without cached appinfo")
local coverage_data = coverage and coverage:read("*a") or ""
if coverage then coverage:close() end
check(coverage_data:find("367521\t9001\tbase\t1", 1, true) ~= nil,
  "(D7a) coverage marks Windows/Proton base depot as relevant")
check(coverage_data:find("367522\t9002\tdlc\t1", 1, true) ~= nil,
  "(D7b) coverage marks DLC depot as optional content")
check(coverage_data:find("367523\t9003\tbase\t0", 1, true) ~= nil,
  "(D7c) coverage marks macOS-only base depot as irrelevant")
local launched_with_coverage = false
for _, cmd in ipairs(exec_commands) do
  if tostring(cmd):find(coverage_path, 1, true) then launched_with_coverage = true end
end
check(launched_with_coverage, "(D8) worker launch receives coverage path")

-- Manual source selection must use the same NUL-safe smart worker. The URL is
-- data in the private candidate file, never shell syntax in the launch command.
os.remove(SF)
exec_commands = {}
exec_count = 0
local hostile_url = "https://manual.test/" .. APPID .. ".zip?x=';touch /tmp/lt-injected;#"
local manual = downloads.start_add_via_luatools_from_url(APPID,
  hostile_url, "Manual", 201)
check(manual and manual.success == true, "(D9) manual download starts")
local manual_smart, url_in_command = false, false
for _, cmd in ipairs(exec_commands) do
  if tostring(cmd):find("smart_download.sh", 1, true) then manual_smart = true end
  if tostring(cmd):find(hostile_url, 1, true) then url_in_command = true end
end
check(manual_smart, "(D10) manual download uses the validated smart worker")
check(not url_in_command, "(D11) manual URL is never interpolated into shell")
local manual_candidate = io.open(candidate_path, "rb")
local manual_data = manual_candidate and manual_candidate:read("*a") or ""
if manual_candidate then manual_candidate:close() end
check(manual_data:find(hostile_url, 1, true) ~= nil,
  "(D12) manual URL is preserved as candidate-file data")
check(manual_data:find("201%z", 1) ~= nil,
  "(D13) manual custom source keeps its accepted HTTP status")

local cancelled = downloads.cancel_add(APPID)
check(cancelled and cancelled.success == true,
  "(D14) cancellation request succeeds")
local stop = io.open(TMP .. "/" .. APPID .. "_stop", "r")
check(stop ~= nil, "(D15) cancellation reaches the worker through a stop marker")
if stop then stop:close() end
local cancel_status = downloads.get_add_status(APPID)
check(cancel_status and cancel_status.state and cancel_status.state.status == "cancelled",
  "(D16) cancelled is a terminal state")
os.remove(TMP .. "/" .. APPID .. "_stop")

-- ── terminal-latch (get_add_status) ─────────────────────────────────────────
-- Prepare a source tree so both manual 'extracted' and smart 'collected'
-- handoffs use the same strict finalizer.
local exdir = TMP .. "/extracted_" .. APPID
local source_dir = exdir .. "/source_0000"
local function prepare_source()
  os.execute("mkdir -p '" .. source_dir .. "'")
  local f = io.open(source_dir .. "/.source-name", "w"); f:write("Test"); f:close()
  f = io.open(source_dir .. "/.source-priority", "w"); f:write("0\n"); f:close()
  f = io.open(source_dir .. "/" .. APPID .. ".lua", "w")
  f:write("addappid(" .. APPID .. ")\naddappid(" .. (APPID + 1)
    .. ",1,\"" .. string.rep("a", 64) .. "\")\n")
  f:close()
end

-- (E0) Keep accepting the legacy "extracted" handoff while installed clients
-- transition to the unified smart collector.
prepare_source()
os.execute("printf '%s' '{\"status\":\"extracted\",\"currentApi\":\"Manual\"}' > " .. SF)
local manual_done = downloads.get_add_status(APPID)
check(manual_done and manual_done.state and manual_done.state.status == "done",
  "(E0) manual extracted -> validated finalize -> done")

-- (E1) collected -> merge/finalize -> done
prepare_source()
os.execute("printf '%s' '{\"status\":\"collected\",\"currentApi\":\"Merged 1 sources\"}' > " .. SF)
local r1 = downloads.get_add_status(APPID)
check(r1 and r1.state and r1.state.status == "done", "(E1) collected -> merge/finalize -> done")
-- (E2) a straggler worker writes 'failed' AFTER done -> latch must hold done
os.execute("printf '%s' '{\"status\":\"failed\",\"error\":\"boom\"}' > " .. SF)
local r2 = downloads.get_add_status(APPID)
check(r2 and r2.state and r2.state.status == "done", "(E2) late 'failed' ignored, stays 'done'")
do
  local h = io.open(SF, "r")
  check(h == nil, "(E3) stray 'failed' state file removed by latch")
  if h then h:close() end
end

-- ── isolated source draft ──────────────────────────────────────────────────
-- A draft reuses the configured smart sources but must not publish anything
-- until CommitGameDraft supplies the user's edited rows.
exec_commands = {}
os.remove(TMP .. "/steam/config/stplug-in/" .. APPID .. ".lua")
local stale_draft = TMP .. "/draft_1_deadbeef"
os.execute("mkdir -p '" .. stale_draft .. "' && touch -d '3 hours ago' '" .. stale_draft .. "'")
local config_path = TMP .. "/home/.config/SLSsteam/config.yaml"
local config = assert(io.open(config_path, "w"))
config:write("AdditionalApps:\nManifestPins:\n  " .. APPID
  .. ":\n    locked: true\n    depots:\n      " .. (APPID + 1)
  .. ": \"old\"\nLogLevel: 2\n")
config:close()
local started = downloads.start_game_draft(APPID)
check(started and started.success == true and type(started.session) == "string",
  "(F1) draft starts with a private session")
check(not isdir(stale_draft), "(F1b) starting a draft collects abandoned stale sessions")
local draft_root = TMP .. "/draft_" .. APPID .. "_" .. started.session
local draft_mode = io.popen("stat -c %a '" .. draft_root .. "' 2>/dev/null")
local draft_permissions = draft_mode and draft_mode:read("*l") or nil
if draft_mode then draft_mode:close() end
check(draft_permissions == "700", "(F1a) draft directory is private")
local draft_collection = draft_root .. "/extracted_" .. APPID
local draft_source = draft_collection .. "/source_0000"
os.execute("mkdir -p '" .. draft_source .. "'")
local df = assert(io.open(draft_source .. "/.source-name", "w")); df:write("Draft source"); df:close()
df = assert(io.open(draft_source .. "/.source-priority", "w")); df:write("0\n"); df:close()
df = assert(io.open(draft_source .. "/" .. APPID .. ".lua", "w"))
df:write("addappid(" .. APPID .. ")\naddappid(" .. (APPID + 1)
  .. ",1,\"" .. string.rep("d", 64) .. "\")\n")
df:close()
os.execute("printf '%s' '{\"status\":\"collected\"}' > '" .. draft_root .. "/state.json'")

local draft_status = downloads.get_game_draft_status(APPID, started.session)
check(draft_status and draft_status.success and draft_status.state.status == "ready",
  "(F2) collected source becomes an editable ready draft")
check(draft_status.state.draft and draft_status.state.draft.depots[1]
  and draft_status.state.draft.depots[1].key == string.rep("d", 64),
  "(F3) ready draft exposes the real editable key")
local draft_dlcs, virtual_row = {}, nil
for _, id in ipairs(draft_status.state.draft.dlc_appids or {}) do draft_dlcs[id] = true end
for _, row in ipairs(draft_status.state.draft.depots or {}) do
  if row.depot == 400001 then virtual_row = row end
end
check(draft_dlcs[400000] and draft_dlcs[400001] and draft_dlcs[4093670],
  "(F3a) draft combines all official product-info DLC appids")
check(virtual_row and virtual_row.virtualDepot == true and virtual_row.requiresKey == false,
  "(F3b) public draft marks virtual DLC as keyless")
local before_commit = io.open(TMP .. "/steam/config/stplug-in/" .. APPID .. ".lua", "r")
check(before_commit == nil, "(F4) preview publishes no game Lua")
if before_commit then before_commit:close() end

local committed = downloads.commit_game_draft(APPID, started.session, {
  dlc_appids = { APPID + 10 },
  depots = { { depot = APPID + 1, key = string.rep("e", 64), gid = "" } },
})
check(committed and committed.success and committed.lua:find(string.rep("e", 64), 1, true),
  "(F5) confirmation publishes the edited key")
check(committed and committed.pinsSynced == true,
  "(F5a) draft commit reports atomic ManifestPins synchronization")
check(committed.lua:find("setManifestid", 1, true) == nil,
  "(F6) blank draft manifest commits as Latest")
local committed_config = io.open(config_path, "r")
local committed_config_text = committed_config and committed_config:read("*a") or ""
if committed_config then committed_config:close() end
check(not committed_config_text:find("old", 1, true),
  "(F6a) Latest clears the older pin inside the draft transaction")
local import_marker_path = TMP .. "/home/.config/SLSsteam/lumen_lua_imports.txt"
local import_marker = io.open(import_marker_path, "r")
local import_marker_text = import_marker and import_marker:read("*a") or ""
if import_marker then import_marker:close() end
check(import_marker_text:find(tostring(APPID), 1, true) ~= nil,
  "(F6b) draft transaction records the source-created game")
local committed_retry = downloads.commit_game_draft(APPID, started.session, {
  dlc_appids = {}, depots = {},
})
check(committed_retry and committed_retry.success
  and committed_retry.lua == committed.lua,
  "(F6c) committed draft retries return the same result without republishing")
local finalize_committed = downloads.cancel_game_draft(APPID, started.session)
check(finalize_committed and finalize_committed.success,
  "(F6d) completed distributed draft can be finalized and discarded")

exec_count = 0
local cached_draft = downloads.start_game_draft(APPID)
local cached_status = cached_draft and downloads.get_game_draft_status(
  APPID, cached_draft.session)
check(cached_draft and cached_draft.success and exec_count == 0,
  "(F6e) repeated draft restores its validated private cache without a download")
check(cached_status and cached_status.success and cached_status.state.status == "ready",
  "(F6f) cached source package immediately recreates an editable draft")
if cached_draft then downloads.cancel_game_draft(APPID, cached_draft.session) end

local cancelled_draft = downloads.start_game_draft(APPID)
local cancelled_result = cancelled_draft and downloads.cancel_game_draft(
  APPID, cancelled_draft.session)
check(cancelled_result and cancelled_result.success == true,
  "(F7) one draft session can be cancelled independently")
local traditional_state = io.open(SF, "r")
check(traditional_state == nil,
  "(F8) draft lifecycle does not recreate the traditional add state")
if traditional_state then traditional_state:close() end

os.execute("rm -rf " .. TMP)
print((fails == 0) and "\nALL DEDUP + LATCH CHECKS PASSED" or ("\n" .. fails .. " CHECK(S) FAILED"))
os.exit(fails == 0 and 0 or 1)
