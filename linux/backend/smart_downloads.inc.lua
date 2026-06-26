-- slsteammoon: smart source selection (speed-first, completeness-aware).
-- Inlined into upstream downloads.lua before `return downloads` by build.sh.
-- Builds the candidate list from the enabled APIs (reusing the same
-- <moapikey>/<apikey>/<appid> substitution and skip-if-key-missing rules as
-- start_add_via_luatools) and launches scripts/smart_download.sh, which races
-- all sources in parallel, scores completeness, picks the best of the fast
-- ones, and reports progress/errors through the <appid>_state.json contract
-- that get_add_status already polls.

-- ~/.lumen.log path (the file the plugin logger writes to). HOME-based, with
-- the same /tmp fallback as lumen/lua/logger.lua, so the detached worker's
-- output lands in the same log as the rest of the plugin.
local function _lumen_log_path()
    local home = m_utils.getenv("HOME") or os.getenv("HOME") or "/tmp"
    return home .. "/.lumen.log"
end

local function _launch_smart_download(appid, candidates_file, dest_root, state_file)
    local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "smart_download.sh")
    m_utils.exec('chmod +x "' .. sh_path .. '"')
    -- Capture the detached worker's stdout+stderr into ~/.lumen.log (was
    -- /dev/null, which hid every race/download/extract failure -> the
    -- frontend's only signal was a bare "failed" state, surfaced as the
    -- opaque "Unknown error"). The worker emits ISO-8601 UTC diagnostics.
    local cmd = string.format(
        'nohup bash "%s" "%s" "%s" "%s" "%s" >> "%s" 2>&1 &',
        sh_path, tostring(appid), state_file, dest_root, candidates_file, _lumen_log_path()
    )
    m_utils.exec(cmd)
end

-- _smart_inflight_status(state_file) -> the worker's last-written status, or nil.
-- Used to dedup duplicate add requests (see start_add_via_luatools_smart).
local function _smart_inflight_status(state_file)
    if not fs.exists(state_file) then return nil end
    local content = m_utils.read_file(state_file)
    if not content or content == "" then return nil end
    local ok, data = pcall(cjson.decode, content)
    if not ok or type(data) ~= "table" then return nil end
    return data.status
end

-- _smart_state_age(state_file) -> seconds since the state file was last
-- modified, or a large number if it can't be stat'd. The worker rewrites the
-- state file every poll (~0.2s) while alive, so a fresh mtime means a live
-- worker; a stale one means it crashed and a relaunch is safe.
local function _smart_state_age(state_file)
    local p = io.popen('stat -c %Y "' .. state_file .. '" 2>/dev/null')
    if not p then return 1 / 0 end
    local out = p:read("*a") or ""
    p:close()
    local mtime = tonumber(out)
    if not mtime then return 1 / 0 end
    return os.time() - mtime
end

function downloads.start_add_via_luatools_smart(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    -- Dedup duplicate add requests for the same appid. The fast-download click
    -- can fire twice (the frontend is re-injected on CEF context recreation,
    -- attaching the delegated click listener more than once, and its in-page
    -- reentry guard is set only AFTER an async API check), producing two RPC
    -- calls within the same second. The Lumen RPC host is single-threaded, so
    -- the first call has already written the worker's state file before the
    -- second is dispatched. Two workers for the same appid share the same
    -- appid-keyed scratch/state/output paths and clobber each other -> spurious
    -- "failed" and the install flapping users see. If a non-terminal add is
    -- already in flight AND its state file is fresh (a crashed worker's stale
    -- file, older than the grace window, is ignored so a real retry still
    -- works), skip relaunching a second worker.
    do
        local dest_root = utils.ensure_temp_download_dir()
        local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")
        local st = _smart_inflight_status(state_file)
        local INFLIGHT = {
            downloading = true, extracting = true, extracted = true,
            processing = true, queued = true,
        }
        if st and INFLIGHT[st] then
            local age = _smart_state_age(state_file)
            if age <= 60 then
                logger.log("LuaTools: StartAddViaLuaToolsSmart appid=" .. tostring(appid)
                    .. " already in flight (status=" .. tostring(st)
                    .. ", age=" .. tostring(age) .. "s) -> skipping duplicate")
                return { success = true }
            end
            logger.warn("LuaTools: StartAddViaLuaToolsSmart appid=" .. tostring(appid)
                .. " stale in-flight state (status=" .. tostring(st)
                .. ", age=" .. tostring(age) .. "s) -> relaunching")
        end
    end

    logger.log("LuaTools: StartAddViaLuaToolsSmart appid=" .. tostring(appid))
    _set_download_state(appid, { status = "downloading", currentApi = "", bytesRead = 0, totalBytes = 0 })

    local apis = api_manifest.load_api_manifest()
    if not apis or #apis == 0 then
        _set_download_state(appid, { status = "failed", error = "No APIs available" })
        return { success = true }
    end

    local ok, res = pcall(function()
        local morrenus_api_key = settings_manager.get_morrenus_api_key()
        local lines = {}
        for _, api in ipairs(apis) do
            local name = api.name or "Unknown"
            local template = api.url or ""
            local skip = false

            if string.find(template, "<moapikey>") then
                if not morrenus_api_key or morrenus_api_key == "" then
                    skip = true
                else
                    template = template:gsub("<moapikey>", morrenus_api_key)
                end
            end
            if not skip and string.find(template, "<apikey>") then
                if not api.api_key or api.api_key == "" then
                    skip = true
                else
                    template = template:gsub("<apikey>", api.api_key)
                end
            end

            if not skip then
                local url = template:gsub("<appid>", tostring(appid))
                -- name<TAB>url, one candidate per line
                table.insert(lines, name .. "\t" .. url)
            end
        end
        if #lines == 0 then error("No usable API sources") end

        local dest_root = utils.ensure_temp_download_dir()
        local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")
        local candidates_file = fs.join(dest_root, tostring(appid) .. "_candidates.tsv")
        m_utils.write_file(candidates_file, table.concat(lines, "\n") .. "\n")
        m_utils.write_file(state_file, '{"status": "downloading"}')
        _launch_smart_download(appid, candidates_file, dest_root, state_file)
    end)

    if not ok then
        logger.warn("LuaTools: StartAddViaLuaToolsSmart crashed - " .. tostring(res))
        _set_download_state(appid, { status = "failed", error = tostring(res) })
        return { success = false, error = tostring(res) }
    end

    return { success = true }
end

