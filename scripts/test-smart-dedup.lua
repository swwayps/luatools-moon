-- Harness: load the REAL dist downloads.lua with minimal stubs and exercise
--   (1) the dedup guard in start_add_via_luatools_smart, and
--   (2) the terminal-latch in get_add_status (a late "failed" must not override
--       an already-finalized "done").
-- Run from the repo root: lua5.4 scripts/test-smart-dedup.lua   (also luajit)
local TMP = "/tmp/lt-dedup-test"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP .. "/steam")

local exec_count = 0

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
  getenv = function(k) return os.getenv(k) end,
  exec = function() exec_count = exec_count + 1 end, -- count launches, don't spawn
})
preload("http_client", {})
preload("config", {})
preload("plugin_logger", {
  log = function(m) print("  [log] " .. tostring(m)) end,
  warn = function(m) print("  [warn] " .. tostring(m)) end,
  info = function() end, error = function() end,
})
preload("paths", { get_plugin_dir = function() return "/tmp" end })
preload("steam_utils", { detect_steam_install_path = function() return TMP .. "/steam" end })
preload("plugin_utils", { ensure_temp_download_dir = function() return TMP end })
preload("api_manifest", { load_api_manifest = function() return { { name = "Test", url = "http://127.0.0.1/<appid>" } } end })
preload("settings.manager", { get_morrenus_api_key = function() return "" end })
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

-- ── terminal-latch (get_add_status) ─────────────────────────────────────────
-- Prepare an extracted package so get_add_status('extracted') finalizes to done.
local exdir = TMP .. "/extracted_" .. APPID
os.execute("mkdir -p '" .. exdir .. "'")
do
  local f = io.open(exdir .. "/" .. APPID .. ".lua", "w")
  f:write("addappid(" .. APPID .. ")\naddappid(" .. APPID .. ',0,"abc")\n')
  f:close()
end
-- (E1) extracted -> finalize -> done
os.execute("printf '%s' '{\"status\":\"extracted\",\"currentApi\":\"Test\"}' > " .. SF)
local r1 = downloads.get_add_status(APPID)
check(r1 and r1.state and r1.state.status == "done", "(E1) extracted -> finalize -> done")
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
