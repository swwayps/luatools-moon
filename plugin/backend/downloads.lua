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

    local dest_root = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")

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
                })

                if data.status == "collected" or data.status == "extracted" then
                    -- Both the parallel collector (collected) and the manual
                    -- single-source downloader (extracted) use the same strict
                    -- merge/validation/publication path.
                    local collection_dir = fs.join(dest_root, "extracted_" .. tostring(appid))
                    local apiName = _get_download_state(appid).currentApi or "Merged sources"

                    local ok, res = pcall(downloads._finalize_install_lua,
                        appid, collection_dir, nil, apiName)
                    if not ok then
                        _set_download_state(appid, { status = "failed", error = tostring(res) })
                    end

                    -- Cleanup background script files
                    pcall(fs.remove, state_file)
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.ps1"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.sh"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_candidates.bin"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_coverage.tsv"))
                elseif data.status == "failed" then
                    pcall(fs.remove, state_file)
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_candidates.bin"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_coverage.tsv"))
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
        _set_download_state(appid, {
            status = "failed",
            error = "No valid game data was available from the configured sources.",
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

local function _launch_async_download(appid, url, dest_path, extract_dir)
    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local dest_root = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")

    m_utils.write_file(state_file, '{"status": "downloading"}')
    if not fs.exists(extract_dir) then fs.create_directories(extract_dir) end

    if is_windows then
        local ps1_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.ps1")
        local cmd = string.format(
            'powershell -WindowStyle Hidden -Command "Start-Process -FilePath powershell -WindowStyle Hidden -ArgumentList \'-ExecutionPolicy Bypass -File \\"%s\\" -Url \\"%s\\" -DestPath \\"%s\\" -ExtractDir \\"%s\\" -StateFile \\"%s\\"\'"',
            ps1_path, url, dest_path, extract_dir, state_file
        )
        m_utils.exec(cmd)
    else
        local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.sh")
        m_utils.exec('chmod +x "' .. sh_path .. '"')
        local cmd = string.format(
            'nohup bash "%s" "%s" "%s" "%s" "%s" >> "${HOME:-/tmp}/.lumen.log" 2>&1 &',
            sh_path, url, dest_path, extract_dir, state_file
        )
        m_utils.exec(cmd)
    end
end

local function _prepare_single_source_dir(appid, api_name)
    local dest_root = utils.ensure_temp_download_dir()
    local collection_dir = fs.join(dest_root, "extracted_" .. tostring(appid))
    local source_dir = fs.join(collection_dir, "source_0000")
    -- Never allow a prior successful extraction to satisfy a later broken ZIP.
    pcall(fs.remove_all, collection_dir)
    fs.create_directories(source_dir)
    m_utils.write_file(fs.join(source_dir, ".source-name"),
        tostring(api_name or "Manual source"):gsub("%z", ""))
    m_utils.write_file(fs.join(source_dir, ".source-priority"), "0\n")
    return dest_root, source_dir
end

function downloads.start_add_via_luatools_from_url(appid, url, apiName)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    logger.log("LuaTools: StartAddViaLuaToolsFromUrl appid=" .. tostring(appid) .. " api=" .. tostring(apiName))
    _set_download_state(appid, { status = "downloading", currentApi = apiName, bytesRead = 0, totalBytes = 0 })

    local ok, res = pcall(function()
        if not url or url == "" then error("Invalid URL provided") end
        local dest_root, extract_dir = _prepare_single_source_dir(appid, apiName)
        local dest_path = fs.join(dest_root, tostring(appid) .. ".zip")
        _launch_async_download(appid, url, dest_path, extract_dir)
    end)

    if not ok then
        logger.warn("LuaTools: Async Download crashed - " .. tostring(res))
        _set_download_state(appid, { status = "failed", error = tostring(res) })
        return { success = false, error = tostring(res) }
    end

    return { success = true }
end

function downloads.start_add_via_luatools(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    logger.log("LuaTools: StartAddViaLuaTools appid=" .. tostring(appid))
    _set_download_state(appid, { status = "queued", bytesRead = 0, totalBytes = 0 })

    local apis = api_manifest.load_api_manifest()
    if not apis or #apis == 0 then
        _set_download_state(appid, { status = "failed", error = "No APIs available" })
        return { success = true }
    end

    local dest_root = utils.ensure_temp_download_dir()
    local dest_path = fs.join(dest_root, tostring(appid) .. ".zip")
    local hubcap_api_key = _get_hubcap_api_key()

    local ok, res = pcall(function()
        -- Legacy automatic path: probe APIs in configured order and hand the
        -- first available source to the validated single-source finalizer.
        local target_url = nil
        local target_name = nil
        for _, api in ipairs(apis) do
            local name = api.name or "Unknown"
            local template = api.url or ""
            local success_code = tonumber(api.success_code) or 200

            if string.find(template, "<moapikey>") then
                if not hubcap_api_key or hubcap_api_key == "" then goto continue end
                template = template:gsub("<moapikey>", hubcap_api_key)
            end
            if string.find(template, "<apikey>") then
                if not api.api_key or api.api_key == "" then goto continue end
                template = template:gsub("<apikey>", api.api_key)
            end

            local url = template:gsub("<appid>", tostring(appid))

            local success = false
            if _is_hubcap_api(api) then
                local status_url = "https://hubcapmanifest.com/api/v1/status/" .. tostring(appid) .. "?api_key=" .. tostring(hubcap_api_key)
                local s_resp = http_client.get(status_url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                if s_resp and s_resp.status == success_code then
                    success = true
                end
            else
                local resp = http_client.head(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                if resp and resp.status == success_code then
                    success = true
                else
                    local get_resp = http_client.get(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                    if get_resp and get_resp.status == success_code then
                        success = true
                    end
                end
            end

            if success then
                target_url = url
                target_name = name
                break
            end
            ::continue::
        end
        if not target_url then error("Not available on any API") end

        _set_download_state(appid, { status = "downloading", currentApi = target_name })
        local _, extract_dir = _prepare_single_source_dir(appid, target_name)
        _launch_async_download(appid, target_url, dest_path, extract_dir)
    end)

    if not ok then
        logger.warn("LuaTools: start_add_via_luatools crashed - " .. tostring(res))
        _set_download_state(appid, { status = "failed", error = tostring(res) })
        return { success = false, error = tostring(res) }
    end

    return { success = true }
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
            url = available and url or nil
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

local function _launch_smart_download(appid, candidates_file, coverage_file, dest_root, state_file)
    local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "smart_download.sh")
    m_utils.exec('chmod +x "' .. sh_path .. '"')
    -- Capture the detached worker's stdout+stderr into ~/.lumen.log (was
    -- /dev/null, which hid download/extract/collection failures -> the
    -- frontend's only signal was a bare "failed" state, surfaced as the
    -- opaque "Unknown error"). The worker emits ISO-8601 UTC diagnostics.
    local cmd = string.format(
        'nohup bash "%s" "%s" "%s" "%s" "%s" "%s" >> "%s" 2>&1 &',
        sh_path, tostring(appid), state_file, dest_root, candidates_file,
        coverage_file, _lumen_log_path()
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
    -- file, older than the freshness window, is ignored so a real retry still
    -- works), skip relaunching a second worker.
    do
        local dest_root = utils.ensure_temp_download_dir()
        local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")
        local st = _smart_inflight_status(state_file)
        local INFLIGHT = {
            downloading = true, extracting = true, extracted = true,
            collected = true, processing = true, queued = true,
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

        local dest_root = utils.ensure_temp_download_dir()
        local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")
        local candidates_file = fs.join(dest_root, tostring(appid) .. "_candidates.bin")
        local coverage_file = fs.join(dest_root, tostring(appid) .. "_coverage.tsv")
        m_utils.write_file(candidates_file, table.concat(records))
        os.execute('chmod 600 "' .. candidates_file .. '"')

        local home = m_utils.getenv("HOME") or os.getenv("HOME") or ""
        local appinfo_path = fs.join(home, ".config", "SLSsteam", "cache",
            "picsbuffer_" .. tostring(appid) .. ".bin")
        local gids = {}
        if fs.exists(appinfo_path) then
            gids = smart_merge.parse_appinfo_gids(m_utils.read_file(appinfo_path) or "")
        end
        local coverage_lines, depots = {}, {}
        for depot in pairs(gids) do depots[#depots + 1] = depot end
        table.sort(depots)
        for _, depot in ipairs(depots) do
            coverage_lines[#coverage_lines + 1] = tostring(depot) .. "\t" .. gids[depot]
        end
        m_utils.write_file(coverage_file,
            #coverage_lines > 0 and (table.concat(coverage_lines, "\n") .. "\n") or "")
        os.execute('chmod 600 "' .. coverage_file .. '"')
        m_utils.write_file(state_file, '{"status": "downloading"}')
        _launch_smart_download(appid, candidates_file, coverage_file, dest_root, state_file)
    end)

    if not ok then
        logger.warn("LuaTools: StartAddViaLuaToolsSmart crashed - " .. tostring(res))
        _set_download_state(appid, { status = "failed", error = tostring(res) })
        return { success = false, error = tostring(res) }
    end

    return { success = true }
end

return downloads
