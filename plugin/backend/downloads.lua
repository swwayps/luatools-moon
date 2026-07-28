local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local config = require("config")
local logger = require("plugin_logger")
local paths = require("paths")
local steam_utils = require("steam_utils")
local utils = require("plugin_utils")
local api_manifest = require("api_manifest")
local settings_manager = require("settings.manager")
local cjson = require("json")
local smart_merge = require("smart_merge")

local downloads = {}
local DOWNLOAD_STATE = {}
local FINALIZING = {}
local _start_smart_records

local function _atomic_write(path, content)
    local temp = path .. ".tmp." .. tostring(os.time()) .. "." .. tostring(math.random(100000, 999999))
    local ok, written = pcall(m_utils.write_file, temp, content)
    if not ok or written == false then
        pcall(fs.remove, temp)
        return false
    end
    local renamed = os.rename(temp, path)
    if not renamed then pcall(fs.remove, temp) end
    return renamed and true or false
end

local function _job_paths(appid)
    local root = utils.ensure_temp_download_dir()
    local stem = tostring(appid)
    return {
        root = root,
        state = fs.join(root, stem .. "_state.json"),
        candidates = fs.join(root, stem .. "_candidates.bin"),
        coverage = fs.join(root, stem .. "_coverage.tsv"),
        collection = fs.join(root, "extracted_" .. stem),
        stop = fs.join(root, stem .. "_stop"),
    }
end

local function _cleanup_job_files(job, keep_stop)
    pcall(fs.remove, job.state)
    pcall(fs.remove, job.candidates)
    pcall(fs.remove, job.coverage)
    if not keep_stop then pcall(fs.remove, job.stop) end
end

local function _get_hubcap_api_key()
    if settings_manager.get_hubcap_api_key then
        return settings_manager.get_hubcap_api_key()
    end
    if settings_manager.get_morrenus_api_key then
        return settings_manager.get_morrenus_api_key()
    end
    return ""
end

local function _is_hubcap_api(api)
    if type(api) ~= "table" then return false end
    if api.builtin_id == "hubcap" or api.builtin_id == "morrenus" then return true end
    return type(api.url) == "string"
        and string.find(api.url, "hubcapmanifest.com", 1, true) ~= nil
end

local function _set_download_state(appid, update)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not DOWNLOAD_STATE[appid] then DOWNLOAD_STATE[appid] = {} end
    for k, v in pairs(update) do
        DOWNLOAD_STATE[appid][k] = v
    end
end

local function _get_download_state(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    local state = DOWNLOAD_STATE[appid] or {}
    local copy = {}
    for k, v in pairs(state) do copy[k] = v end
    return copy
end

function downloads.get_add_status(appid)
    if type(appid) == "string" then appid = tonumber(appid) end

    local job = _job_paths(appid)
    local state_file = job.state

    if fs.exists(state_file) then
        local content = m_utils.read_file(state_file)
        if content and content ~= "" then
            local success, data = pcall(cjson.decode, content)
            if success and type(data) == "table" and data.status then
                if data.status == "failed" then
                    local _cur = _get_download_state(appid)
                    if _cur and _cur.status == "done" then
                        pcall(fs.remove, state_file)
                        return { success = true, state = _cur }
                    end
                end
                _set_download_state(appid, {
                    status = data.status,
                    error = data.error,
                    bytesRead = data.bytesRead,
                    totalBytes = data.totalBytes,
                    currentApi = data.currentApi,
                    apiErrors = data.apiErrors,
                    errorCode = data.errorCode,
                    errorPhase = data.errorPhase,
                })

                if data.status == "collected" or data.status == "extracted" then
                    -- Claim the handoff before publishing. This closes the
                    -- window where overlapping frontend polls could run the
                    -- merge twice against the same collection.
                    if not FINALIZING[appid] then
                        FINALIZING[appid] = true
                        _atomic_write(state_file, '{"status":"processing"}\n')
                        local apiName = _get_download_state(appid).currentApi or "Merged sources"
                        local ok, res = pcall(downloads._finalize_install_lua,
                            appid, job.collection, nil, apiName)
                        FINALIZING[appid] = nil
                        if not ok then
                            _set_download_state(appid, {
                                status = "failed", error = tostring(res),
                                errorCode = "finalize_exception", errorPhase = "publish",
                            })
                        end
                        _cleanup_job_files(job)
                    end
                elseif data.status == "failed" then
                    _cleanup_job_files(job)
                elseif data.status == "cancelled" then
                    -- The worker consumes this marker and terminates its curl
                    -- children. A fast frontend poll must not remove it first.
                    _cleanup_job_files(job, true)
                end
            end
        end
    end

    return { success = true, state = _get_download_state(appid) }
end

function downloads._finalize_install_lua(appid, collection_dir, _, api_name)
    _set_download_state(appid, { status = "processing" })
    local base_path = steam_utils.detect_steam_install_path()
    local home = m_utils.getenv("HOME") or os.getenv("HOME") or ""
    local appinfo_path = fs.join(home, ".config", "SLSsteam", "cache",
        "picsbuffer_" .. tostring(appid) .. ".bin")
    local appinfo_text = fs.exists(appinfo_path) and (m_utils.read_file(appinfo_path) or "") or ""

    local result, err = smart_merge.install(appid, collection_dir, {
        home = home,
        steam_root = base_path,
        appinfo_text = appinfo_text,
        read_file = m_utils.read_file,
        write_file = function(path, content)
            local ok, written = pcall(m_utils.write_file, path, content)
            return ok and written ~= false
        end,
        exists = fs.exists,
        list_recursive = fs.list_recursive,
        mkdir = fs.create_directories,
        rename = os.rename,
        remove = function(path) local ok = pcall(fs.remove, path); return ok end,
    })

    pcall(fs.remove_all, collection_dir)
    if not result then
        logger.warn("LuaTools: aggregate finalize appid=" .. tostring(appid)
            .. " -> " .. tostring(err))
        local error_code, error_phase, message = "invalid_game_data", "validate",
            "The downloaded packages did not contain recognizable game data for this app."
        if err == "no_usable_base_key" then
            error_code = "missing_base_key"
            message = "The sources responded, but none contained a usable key for the base game. Optional DLC data was kept from blocking the result."
        elseif err == "wrong_app" then
            error_code = "wrong_app"
            message = "The downloaded packages were for a different app."
        elseif err == "install paths unavailable" then
            error_code, error_phase = "install_path_unavailable", "publish"
            message = "Steam's install path could not be resolved. Start Steam once and try again."
        elseif tostring(err):match("^failed to stage ") then
            error_code, error_phase = "stage_failed", "publish"
            message = "The game data was valid, but it could not be staged locally. Check free space and permissions."
        elseif tostring(err):match("^failed to publish ") then
            error_code, error_phase = "publish_failed", "publish"
            message = "The game data was valid, but it could not be installed locally. Check free space and permissions."
        end
        _set_download_state(appid, {
            status = "failed",
            error = message,
            errorCode = error_code,
            errorPhase = error_phase,
        })
        return false
    end

    for _, conflict in ipairs(result.conflicts or {}) do
        logger.warn("LuaTools: key conflict appid=" .. tostring(appid)
            .. " depot=" .. tostring(conflict.id) .. " resolved automatically")
    end
    local contributors = table.concat(result.contributors or {}, ", ")
    logger.log("LuaTools: aggregate finalize appid=" .. tostring(appid)
        .. " sources=" .. contributors
        .. " manifests=" .. tostring(result.manifest_count or 0)
        .. " -> installed " .. tostring(result.installed_path))
    _set_download_state(appid, {
        status = "done", success = true, api = contributors,
        installedPath = result.installed_path,
    })
    return true
end

function downloads.start_add_via_luatools_from_url(appid, url, apiName, success_code)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    logger.log("LuaTools: StartAddViaLuaToolsFromUrl appid=" .. tostring(appid) .. " api=" .. tostring(apiName))
    if type(url) ~= "string" or url == "" or url:find("\0", 1, true) then
        return { success = false, error = "Invalid URL provided" }
    end
    local code = tonumber(success_code) or 200
    if code < 100 or code > 599 then code = 200 end
    local name = tostring(apiName or "Manual source"):gsub("%z", "")
    local records = { table.concat({ "0", name, url, tostring(code), "" }, "\0") }
    return _start_smart_records(appid, records, name)
end

function downloads.start_add_via_luatools(appid)
    return downloads.start_add_via_luatools_smart(appid)
end

function downloads.check_apis_for_app(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    local apis = api_manifest.load_api_manifest()
    if not apis or #apis == 0 then
        return { success = true, results = {} }
    end

    local results = {}
    local hubcap_api_key = _get_hubcap_api_key()

    for _, api in ipairs(apis) do
        local name = api.name or "Unknown"
        local template = api.url or ""
        local success_code = tonumber(api.success_code) or 200

        if string.find(template, "<moapikey>") then
            if not hubcap_api_key or hubcap_api_key == "" then
                goto continue
            end
            template = template:gsub("<moapikey>", hubcap_api_key)
        end
        if string.find(template, "<apikey>") then
            if not api.api_key or api.api_key == "" then
                goto continue
            end
            template = template:gsub("<apikey>", api.api_key)
        end

        local url = template:gsub("<appid>", tostring(appid))
        local available = false

        if _is_hubcap_api(api) then
            local status_url = "https://hubcapmanifest.com/api/v1/status/" .. tostring(appid) .. "?api_key=" .. tostring(hubcap_api_key)
            local resp = http_client.get(status_url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
            if resp and resp.status == success_code then
                available = true
            end
        else
            local success = false
            local resp = http_client.head(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
            if resp and resp.status == success_code then
                success = true
            else
                -- Fallback to GET if HEAD fails
                local get_resp = http_client.get(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                if get_resp and get_resp.status == success_code then
                    success = true
                end
            end

            if success then
                available = true
            end
        end

        table.insert(results, {
            name = name,
            available = available,
            url = available and url or nil,
            successCode = success_code,
        })

        ::continue::
    end

    return { success = true, results = results }
end

-- slsteammoon: bounded parallel Smart Download aggregation.
-- Builds candidates from every enabled API (including custom entries), reusing
-- the <moapikey>/<apikey>/<appid> substitution and missing-key skip rules. The
-- worker downloads each source once, preserves every source completed before
-- coverage/deadline closure, and hands the isolated trees to smart_merge.

-- ~/.lumen.log path (the file the plugin logger writes to). HOME-based, with
-- the same /tmp fallback as lumen/lua/logger.lua, so the detached worker's
-- output lands in the same log as the rest of the plugin.
local function _lumen_log_path()
    local home = m_utils.getenv("HOME") or os.getenv("HOME") or "/tmp"
    return home .. "/.lumen.log"
end

local function _shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function _launch_smart_download(appid, candidates_file, coverage_file, dest_root, state_file, stop_file)
    local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "smart_download.sh")
    m_utils.exec("chmod +x -- " .. _shell_quote(sh_path))
    -- Capture the detached worker's stdout+stderr into ~/.lumen.log (was
    -- /dev/null, which hid download/extract/collection failures -> the
    -- frontend's only signal was a bare "failed" state, surfaced as the
    -- opaque "Unknown error"). The worker emits ISO-8601 UTC diagnostics.
    local cmd = string.format(
        "nohup bash %s %s %s %s %s %s %s >> %s 2>&1 &",
        _shell_quote(sh_path), _shell_quote(appid), _shell_quote(state_file),
        _shell_quote(dest_root), _shell_quote(candidates_file), _shell_quote(coverage_file),
        _shell_quote(stop_file), _shell_quote(_lumen_log_path())
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

local INFLIGHT_STATUS = {
    downloading = true, extracting = true, extracted = true,
    collected = true, processing = true, queued = true,
}

local function _has_fresh_job(appid)
    local job = _job_paths(appid)
    local status = _smart_inflight_status(job.state)
    if status and INFLIGHT_STATUS[status] then
        local age = _smart_state_age(job.state)
        if age <= 60 then
            logger.log("LuaTools: appid=" .. tostring(appid)
                .. " already in flight (status=" .. tostring(status)
                .. ", age=" .. tostring(age) .. "s) -> skipping duplicate")
            return true
        end
        logger.warn("LuaTools: appid=" .. tostring(appid)
            .. " stale in-flight state (status=" .. tostring(status)
            .. ", age=" .. tostring(age) .. "s) -> relaunching")
    end
    return false
end

local function _write_coverage(appid, coverage_file)
    local home = m_utils.getenv("HOME") or os.getenv("HOME") or ""
    local appinfo_path = fs.join(home, ".config", "SLSsteam", "cache",
        "picsbuffer_" .. tostring(appid) .. ".bin")
    local depot_info = {}
    if fs.exists(appinfo_path) then
        depot_info = smart_merge.parse_appinfo_depots(m_utils.read_file(appinfo_path) or "")
    end
    local coverage_lines, depots = {}, {}
    for depot, info in pairs(depot_info) do
        if info.gid then depots[#depots + 1] = depot end
    end
    table.sort(depots)
    for _, depot in ipairs(depots) do
        local info = depot_info[depot]
        coverage_lines[#coverage_lines + 1] = table.concat({
            tostring(depot), tostring(info.gid), tostring(info.kind),
            info.relevant and "1" or "0",
        }, "\t")
    end
    return m_utils.write_file(coverage_file,
        #coverage_lines > 0 and (table.concat(coverage_lines, "\n") .. "\n") or "") ~= false
end

_start_smart_records = function(appid, records, current_api)
    if _has_fresh_job(appid) then return { success = true } end
    local job = _job_paths(appid)
    local ok, err = pcall(function()
        if type(records) ~= "table" or #records == 0 then error("No usable API sources") end
        pcall(fs.remove, job.stop)
        pcall(fs.remove_all, job.collection)
        if m_utils.write_file(job.candidates, table.concat(records)) == false then
            error("Could not prepare source list")
        end
        os.execute("chmod 600 -- " .. _shell_quote(job.candidates))
        if not _write_coverage(appid, job.coverage) then error("Could not prepare depot coverage") end
        os.execute("chmod 600 -- " .. _shell_quote(job.coverage))
        if not _atomic_write(job.state, '{"status":"downloading"}\n') then
            error("Could not create download state")
        end
        DOWNLOAD_STATE[appid] = {}
        _set_download_state(appid, {
            status = "downloading", currentApi = current_api or "",
            bytesRead = 0, totalBytes = 0,
        })
        _launch_smart_download(appid, job.candidates, job.coverage,
            job.root, job.state, job.stop)
    end)
    if not ok then
        logger.warn("LuaTools: download launch failed appid=" .. tostring(appid)
            .. " -> " .. tostring(err))
        _cleanup_job_files(job)
        _set_download_state(appid, {
            status = "failed", error = tostring(err),
            errorCode = "launch_failed", errorPhase = "prepare",
        })
        return { success = false, error = tostring(err) }
    end
    return { success = true }
end

function downloads.start_add_via_luatools_smart(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    logger.log("LuaTools: StartAddViaLuaToolsSmart appid=" .. tostring(appid))

    local apis = api_manifest.load_api_manifest()
    if not apis or #apis == 0 then
        _set_download_state(appid, { status = "failed", error = "No APIs available" })
        return { success = true }
    end

    local ok, records_or_error = pcall(function()
        local hubcap_api_key = _get_hubcap_api_key()
        local records = {}
        for index, api in ipairs(apis) do
            local name = tostring(api.name or "Unknown"):gsub("%z", "")
            local template = tostring(api.url or ""):gsub("%z", "")
            local skip = template == ""

            if string.find(template, "<moapikey>", 1, true) then
                if not hubcap_api_key or hubcap_api_key == "" then
                    skip = true
                else
                    template = template:gsub("<moapikey>", hubcap_api_key)
                end
            end
            if not skip and string.find(template, "<apikey>", 1, true) then
                if not api.api_key or api.api_key == "" then
                    skip = true
                else
                    template = template:gsub("<apikey>", api.api_key)
                end
            end

            if not skip then
                local url = template:gsub("<appid>", tostring(appid))
                records[#records + 1] = table.concat({
                    tostring(index - 1), name, url,
                    tostring(tonumber(api.success_code) or 200), "",
                }, "\0")
            end
        end
        if #records == 0 then error("No usable API sources") end
        return records
    end)

    if not ok then
        logger.warn("LuaTools: StartAddViaLuaToolsSmart crashed - " .. tostring(records_or_error))
        _set_download_state(appid, { status = "failed", error = tostring(records_or_error) })
        return { success = false, error = tostring(records_or_error) }
    end
    return _start_smart_records(appid, records_or_error, "")
end

function downloads.cancel_add(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end
    local job = _job_paths(appid)
    if m_utils.write_file(job.stop, "cancel\n") == false then
        return { success = false, error = "Could not request cancellation" }
    end
    _atomic_write(job.state,
        '{"status":"cancelled","errorCode":"cancelled","errorPhase":"download"}\n')
    _set_download_state(appid, {
        status = "cancelled", error = nil,
        errorCode = "cancelled", errorPhase = "download",
    })
    logger.log("LuaTools: cancellation requested appid=" .. tostring(appid))
    return { success = true }
end

return downloads
