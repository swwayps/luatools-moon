-- slsteammoon: smart source selection (speed-first, completeness-aware).
-- Inlined into upstream downloads.lua before `return downloads` by build.sh.
-- Builds the candidate list from the enabled APIs (reusing the same
-- <moapikey>/<apikey>/<appid> substitution and skip-if-key-missing rules as
-- start_add_via_luatools) and launches scripts/smart_download.sh, which races
-- all sources in parallel, scores completeness, picks the best of the fast
-- ones, and reports progress/errors through the <appid>_state.json contract
-- that get_add_status already polls.

local function _launch_smart_download(appid, candidates_file, dest_root, state_file)
    local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "smart_download.sh")
    m_utils.exec('chmod +x "' .. sh_path .. '"')
    local cmd = string.format(
        'nohup bash "%s" "%s" "%s" "%s" "%s" > /dev/null 2>&1 &',
        sh_path, tostring(appid), state_file, dest_root, candidates_file
    )
    m_utils.exec(cmd)
end

function downloads.start_add_via_luatools_smart(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

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

