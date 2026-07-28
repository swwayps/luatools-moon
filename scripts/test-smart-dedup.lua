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
  { name = "Missing Key", url = "https://key.test/<appid>?key=<apikey>", success_code = 200 },
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
preload("api_manifest", { load_api_manifest = function() return APIS end })
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
check(not candidate_data:find("Missing Key", 1, true), "(D5) API missing required key is skipped")
local mode_pipe = io.popen("stat -c %a '" .. candidate_path .. "' 2>/dev/null")
local mode = mode_pipe and mode_pipe:read("*l") or ""; if mode_pipe then mode_pipe:close() end
check(mode == "600", "(D6) candidate file is private mode 0600")
local coverage_path = TMP .. "/" .. APPID .. "_coverage.tsv"
local coverage = io.open(coverage_path, "rb")
check(coverage ~= nil, "(D7) coverage handoff exists even without cached appinfo")
if coverage then coverage:close() end
local launched_with_coverage = false
for _, cmd in ipairs(exec_commands) do
  if tostring(cmd):find(coverage_path, 1, true) then launched_with_coverage = true end
end
check(launched_with_coverage, "(D8) worker launch receives coverage path")

-- Manual source selection uses downloader.sh, whose terminal handoff is
-- "extracted". It must extract into a fresh indexed source directory so the
-- same validated finalizer handles it without seeing stale prior files.
os.remove(SF)
exec_commands = {}
exec_count = 0
local manual = downloads.start_add_via_luatools_from_url(APPID,
  "https://manual.test/" .. APPID .. ".zip", "Manual")
check(manual and manual.success == true, "(D9) manual download starts")
local manual_indexed = false
for _, cmd in ipairs(exec_commands) do
  if tostring(cmd):find("extracted_" .. APPID .. "/source_0000", 1, true) then
    manual_indexed = true
  end
end
check(manual_indexed, "(D10) manual download extracts into indexed source directory")

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

-- (E0) downloader.sh manual handoff must finalize, not poll forever.
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

os.execute("rm -rf " .. TMP)
print((fails == 0) and "\nALL DEDUP + LATCH CHECKS PASSED" or ("\n" .. fails .. " CHECK(S) FAILED"))
os.exit(fails == 0 and 0 or 1)
