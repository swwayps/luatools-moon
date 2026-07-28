local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local logger = require("plugin_logger")
local utils = require("plugin_utils")
local paths = require("paths")
local cjson = require("json")
local ryuu_auth = require("ryuu_auth")

local fixes = {}

function fixes.check_for_fixes(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    local result = {
        success = true,
        appid = appid,
        gameName = "Unknown Game (" .. tostring(appid) .. ")",
        genericFix = { status = 0, available = false },
        onlineFix = { status = 0, available = false }
    }

    local FIXES_INDEX_URL = "https://index.luatools.work/fixes-index.json"
    local resp = http_client.get(FIXES_INDEX_URL, { timeout = 10 })
    if resp and resp.status == 200 and resp.body then
        local data = utils.decode_json(resp.body)
        if type(data) == "table" then
            local generic_url = "https://files.luatools.work/GameBypasses/" .. tostring(appid) .. ".zip"
            local online_url = "https://files.luatools.work/OnlineFix1/" .. tostring(appid) .. ".zip"

            local has_generic = false
            for _, v in ipairs(data.genericFixes or {}) do if tonumber(v) == appid then has_generic = true break end end
            if has_generic then
                result.genericFix.status = 200
                result.genericFix.available = true
                result.genericFix.url = generic_url
            else
                result.genericFix.status = 404
            end

            local has_online = false
            for _, v in ipairs(data.onlineFixes or {}) do if tonumber(v) == appid then has_online = true break end end
            if has_online then
                result.onlineFix.status = 200
                result.onlineFix.available = true
                result.onlineFix.url = online_url
            else
                result.onlineFix.status = 404
            end
        end
    end

    return result
end

function fixes.apply_game_fix(appid, download_url, install_path, fix_type, game_name)
    local dest_root = utils.ensure_temp_download_dir()
    local dest_zip = fs.join(dest_root, "fix_" .. tostring(appid) .. ".zip")
    local state_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_state.json")
    local header_file = ""

    if tostring(download_url):match("^https://generator%.ryuu%.lol/fixes/") then
        local auth_header = ryuu_auth.get_header_line()
        if not auth_header then
            return {
                success = false,
                errorCode = "authentication",
                error = "Ryuu authentication is required. Add a current session cookie or auth key.",
            }
        end
        header_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_headers.txt")
        if m_utils.write_file(header_file, auth_header) == false then
            return { success = false, error = "Could not prepare Ryuu authentication." }
        end
        m_utils.exec('chmod 600 "' .. header_file .. '"')
    end

    logger.log("LuaTools: Applying fix to " .. tostring(install_path))
    m_utils.write_file(state_file, '{"status": "downloading"}')

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    if is_windows then
        local ps1_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.ps1")
        local cmd = string.format(
            'powershell -WindowStyle Hidden -Command "Start-Process -FilePath powershell -WindowStyle Hidden -ArgumentList \'-ExecutionPolicy Bypass -File \\"%s\\" -Url \\"%s\\" -DestPath \\"%s\\" -ExtractDir \\"%s\\" -StateFile \\"%s\\"\'"',
            ps1_path, download_url, dest_zip, install_path, state_file
        )
        m_utils.exec(cmd)
    else
        local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.sh")
        m_utils.exec('chmod +x "' .. sh_path .. '"')
-- SPEED_LIMIT/SPEED_TIME: the shared downloader defaults (20 KB/s over 5s) are
        -- tuned for small manifest fetches and kill a fix archive on a slow link
        -- (measured: the same 11 MB file took 2s on one connection and had not
        -- finished after 5 minutes on another). Here only a transfer that is
        -- effectively dead should abort, so the floor is 1 KB/s over 45s.
        local cmd = string.format(
            'nohup env MAX_TIME=0 SPEED_LIMIT=1024 SPEED_TIME=45 EXTRACT_NESTED=1 bash "%s" "%s" "%s" "%s" "%s" "" "%s" >> "${HOME:-/tmp}/.lumen.log" 2>&1 &',
            sh_path, download_url, dest_zip, install_path, state_file, header_file
        )
        m_utils.exec(cmd)
    end

    return { success = true }
end

function fixes.get_apply_status(appid)
    local dest_root = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_state.json")
    local dest_zip = fs.join(dest_root, "fix_" .. tostring(appid) .. ".zip")
    local header_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_headers.txt")

    if not fs.exists(state_file) then
        return { success = true, state = { status = "done" } }
    end

    local content = m_utils.read_file(state_file)
    if content and content ~= "" then
        local success, data = pcall(cjson.decode, content)
        if success and type(data) == "table" and data.status then
            if data.status == "extracted" then
                data.status = "done"
                pcall(fs.remove, state_file)
                pcall(fs.remove, dest_zip)
                pcall(fs.remove, header_file)
            elseif data.status == "failed" then
                pcall(fs.remove, state_file)
                pcall(fs.remove, header_file)
                if data.errorCode == "authentication" then
                    -- A rejected session is no longer useful. Clear it so the
                    -- next card click opens the guided authentication modal.
                    pcall(ryuu_auth.clear)
                end
            end
            return { success = true, state = data }
        end
    end

    return { success = true, state = { status = "downloading" } }
end

return fixes
