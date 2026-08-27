local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local logger = require("plugin_logger")
local utils = require("plugin_utils")
local paths = require("paths")
local cjson = require("json")
local ryuu_auth = require("ryuu_auth")
local guard = require("guard")

local fixes = {}

-- steam_utils pulls in the millennium shim, which is not available in every
-- context that loads this module (and not needed unless a fix is applied), so it
-- is resolved on first use rather than at load time.
local function default_install_state(appid)
    return require("steam_utils").get_game_install_state(appid)
end

local shell_quote = guard.shell_quote

-- Mirrors a fix archive may come from when the FRONTEND supplies the URL. Every
-- such URL was produced by one of this backend's own RPCs (check_for_fixes ->
-- files.luatools.work, onlinefix.resolve -> the online-fix mirror, and the
-- authenticated Ryuu generator), so that set is closed. Without it the endpoint
-- accepted any URL and wrote its contents into a directory the caller also chose
-- — a file write to anywhere the user can write.
--
-- One producer is deliberately NOT in this set: lua.tools answers
-- /api/denuvo/download with a short-lived presigned link on its own storage host,
-- which cannot be enumerated. That path passes deps.trusted_source instead, and
-- provenance vouches for it (see validate_apply_target).
fixes.ALLOWED_FIX_HOSTS = {
    ["files.luatools.work"] = true,
    ["index.luatools.work"] = true,
    ["generator.ryuu.lol"] = true,
    ["api.perondepot.xyz"] = true,
}

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

-- validate_apply_target(appid, download_url, install_path, deps)
--   -> url, path   or   nil, error table
-- Both values arrive from the frontend bridge and neither used to be checked.
-- The download URL must be an https mirror we published ourselves; the
-- destination must be exactly the install directory the backend derives for that
-- AppID from libraryfolders.vdf + appmanifest_<appid>.acf, so the caller cannot
-- redirect the extraction to an autostart directory, a shell rc file, or the
-- plugin's own backend/ (which is loaded at the next boot).
-- validate_apply_target(...) -> url, nil, path   or   nil, error_table
--
-- `deps.trusted_source` marks a URL this backend resolved itself through an
-- authenticated API rather than one the frontend chose. lua.tools answers
-- /api/denuvo/download with a short-lived PRESIGNED link on its own storage host,
-- which by design is not a host we can enumerate — so provenance, not a host
-- allowlist, is what vouches for it. Everything else still applies: https only,
-- no userinfo, no control characters, and the destination check below.
function fixes.validate_apply_target(appid, download_url, install_path, deps)
    deps = deps or {}
    local url_opts = {}
    if not deps.trusted_source then
        url_opts.hosts = fixes.ALLOWED_FIX_HOSTS
    end
    local url = guard.https_url(tostring(download_url or ""), url_opts)
    if not url then
        return nil, { success = false, errorCode = "invalid_source",
            error = "This fix download source is not allowed." }
    end
    local install_state = deps.install_state or default_install_state
    local ok_state, state = pcall(install_state, appid)
    if not ok_state or type(state) ~= "table" or not state.found
        or type(state.installPath) ~= "string" then
        return nil, { success = false, errorCode = "not_installed",
            error = "menu.error.notInstalled" }
    end
    if not guard.same_path(install_path, state.installPath) then
        return nil, { success = false, errorCode = "invalid_destination",
            error = "The install path does not belong to this game." }
    end
    -- The derived path is not trusted blindly either. `installdir` is scraped out
    -- of appmanifest_<appid>.acf with a pattern that permits "..", which
    -- normalize_path would happily collapse into a clean path OUTSIDE the library.
    -- Require it to sit inside a Steam library's steamapps/common, and require the
    -- directory to exist so a fix is never unpacked into a path we just invented.
    local contained = deps.library_path
        or function(path) return require("steam_utils").game_library_path(path) end
    local ok_contained, canonical = pcall(contained, state.installPath)
    if not ok_contained or type(canonical) ~= "string" then
        return nil, { success = false, errorCode = "invalid_destination",
            error = "The install path is outside the Steam libraries." }
    end
    if state.directoryExists == false then
        return nil, { success = false, errorCode = "not_installed",
            error = "menu.error.notInstalled" }
    end
    return url, nil, canonical
end

function fixes.apply_game_fix(appid, download_url, install_path, fix_type, game_name, deps)
    local checked_url, reject, checked_path =
        fixes.validate_apply_target(appid, download_url, install_path, deps)
    if not checked_url then
        logger.warn("LuaTools: refused fix apply for " .. tostring(appid)
            .. ": " .. tostring(reject and reject.errorCode))
        return reject
    end
    download_url, install_path = checked_url, checked_path

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
        m_utils.exec("chmod 600 -- " .. shell_quote(header_file))
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
        m_utils.exec("chmod +x -- " .. shell_quote(sh_path))
-- SPEED_LIMIT/SPEED_TIME: the shared downloader defaults (20 KB/s over 5s) are
        -- tuned for small manifest fetches and kill a fix archive on a slow link
        -- (measured: the same 11 MB file took 2s on one connection and had not
        -- finished after 5 minutes on another). Here only a transfer that is
        -- effectively dead should abort, so the floor is 1 KB/s over 45s.
        local cmd = string.format(
            "nohup env MAX_TIME=1800 SPEED_LIMIT=1024 SPEED_TIME=45 EXTRACT_NESTED=1 bash %s %s %s %s %s '' %s >> \"${HOME:-/tmp}/.lumen.log\" 2>&1 &",
            shell_quote(sh_path), shell_quote(download_url), shell_quote(dest_zip),
            shell_quote(install_path), shell_quote(state_file), shell_quote(header_file)
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

-- Manifest-only official entries still use the same poll/finalize path as an
-- archive apply. Writing the worker state atomically makes the frontend observe
-- one terminal extraction event without inventing a second progress protocol.
function fixes.mark_apply_ready(appid)
    local dest_root = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_state.json")
    local temp_file = state_file .. ".tmp"
    local ok, wrote = pcall(m_utils.write_file, temp_file,
        '{"status":"extracted","bytesRead":0,"totalBytes":0}')
    if not ok or wrote == false or not os.rename(temp_file, state_file) then
        pcall(os.remove, temp_file)
        return { success = false, error = "Could not prepare the manifest apply." }
    end
    return { success = true }
end

return fixes
