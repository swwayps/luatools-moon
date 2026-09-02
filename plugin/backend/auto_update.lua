local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local config = require("config")
local logger = require("plugin_logger")
local paths = require("paths")
local utils = require("plugin_utils")
local steam_utils = require("steam_utils")
local guard = require("guard")

local auto_update = {}

-- Hosts that may serve a plugin update archive: GitHub's release asset CDN and
-- the project's own redirect endpoint. Everything else is refused even if the
-- release API response asks for it.
auto_update.ALLOWED_UPDATE_HOSTS = {
    ["github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
    ["cdn.jsdelivr.net"] = true,
    ["luatools.vercel.app"] = true,
}

auto_update.MIRROR_MANIFEST_URL =
    "https://cdn.jsdelivr.net/gh/swwayps/jsdelivr@main/manifest.json"

function auto_update.check_for_updates_now()
    local cfg_path = paths.backend_path(config.UPDATE_CONFIG_FILE)
    local cfg = utils.read_json(cfg_path)

    local latest_version = ""
    local zip_url = ""
    local expected_sha = ""
    local fallback_url = ""
    local fallback_sha = ""
    local github_tag = ""
    local tag_prefix = ""
    local mirror_allowed = false

    local gh_cfg = cfg.github
    if gh_cfg then
        -- owner/repo/tag come from backend/update.json on disk. Anything that can
        -- write that file could otherwise point the self-update at its own
        -- repository, or inject path segments into the API endpoint.
        local owner = guard.repo_segment(gh_cfg.owner)
        local repo = guard.repo_segment(gh_cfg.repo)
        local asset_name = gh_cfg.asset_name or "ltsteamplugin.zip"
        local tag = gh_cfg.tag and guard.tag_name(gh_cfg.tag) or nil
        tag_prefix = gh_cfg.tag_prefix or ""
        if not owner or not repo then
            return { success = false, error = "Update source is misconfigured" }
        end
        if gh_cfg.tag and gh_cfg.tag ~= "" and not tag then
            return { success = false, error = "Update source tag is invalid" }
        end
        mirror_allowed = owner == "swwayps" and repo == "luatools-moon"
            and asset_name == "luatools-linux.zip" and tag == nil

        local endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/latest"
        if tag then
            endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/tags/" .. tag
        end

        local resp = http_client.get(endpoint, {
            headers = {
                ["Accept"] = "application/vnd.github+json",
                ["User-Agent"] = "LuaTools-Updater"
            },
            timeout = 10
        })
        if resp and resp.status == 200 and resp.body then
            local data = utils.decode_json(resp.body)
            local tag_name = data.tag_name or ""
            github_tag = tag_name
            latest_version = tag_name or data.name or ""
            if tag_prefix ~= "" and latest_version:sub(1, #tag_prefix) == tag_prefix then
                latest_version = latest_version:sub(#tag_prefix + 1)
            end

            for _, asset in ipairs(data.assets or {}) do
                if asset.name == asset_name then
                    zip_url = asset.browser_download_url
                    break
                end
            end
        end
    end

    -- Release assets are mirrored under commit-pinned jsDelivr URLs. This tiny
    -- manifest remains reachable when GitHub's API or asset CDN is unavailable.
    local mirror_entry
    if mirror_allowed then
        local mirror_resp = http_client.get(auto_update.MIRROR_MANIFEST_URL, {
            headers = { ["Accept"] = "application/json", ["User-Agent"] = "LuaTools-Updater" },
            timeout = 10
        })
        if mirror_resp and mirror_resp.status == 200 and mirror_resp.body then
            local mirror = utils.decode_json(mirror_resp.body)
            local entry = mirror and mirror.schema == 1
                and mirror.components and mirror.components.plugin or nil
            if entry and guard.tag_name(entry.tag)
                and type(entry.url) == "string"
                and entry.url:match(
                    "^https://cdn%.jsdelivr%.net/gh/swwayps/jsdelivr@[0-9a-f]+/")
                and type(entry.sha256) == "string"
                and entry.sha256:match("^[0-9a-f]+$")
                and #entry.sha256 == 64 then
                mirror_entry = entry
            end
        end
    end

    if (latest_version == "" or zip_url == "") and mirror_entry then
        latest_version = mirror_entry.tag
        zip_url = mirror_entry.url
        expected_sha = mirror_entry.sha256
        if tag_prefix ~= "" and latest_version:sub(1, #tag_prefix) == tag_prefix then
            latest_version = latest_version:sub(#tag_prefix + 1)
        end
    elseif mirror_entry and mirror_entry.tag == github_tag then
        fallback_url = mirror_entry.url
        fallback_sha = mirror_entry.sha256
    end

    -- Retain the historical redirect only when GitHub answered with a valid
    -- tag but neither release source provided the named archive.
    if zip_url == "" and guard.tag_name(github_tag) then
        zip_url = "https://luatools.vercel.app/api/get-plugin/" .. github_tag
    end

    if latest_version == "" or zip_url == "" then
        return { success = false, error = "Manifest missing version or zip_url" }
    end
    -- The download URL arrives in an API response body. Constrain it to the hosts
    -- that actually serve our releases: a compromised or redirected response must
    -- not be able to point the self-update at an arbitrary archive.
    local checked_zip_url = guard.https_url(zip_url,
        { hosts = auto_update.ALLOWED_UPDATE_HOSTS })
    if not checked_zip_url then
        logger.warn("LuaTools: refused self-update download URL " .. tostring(zip_url))
        return { success = false, error = "Update download source is not allowed" }
    end
    zip_url = checked_zip_url
    if fallback_url ~= "" then
        fallback_url = guard.https_url(fallback_url,
            { hosts = auto_update.ALLOWED_UPDATE_HOSTS }) or ""
        if fallback_url == "" then fallback_sha = "" end
    end

    local current_version = utils.get_plugin_version()

    -- Compare version tables component by component (can't use <= on tables in Lua)
    local function compare_versions(a, b)
        local ta = utils.parse_version(a)
        local tb = utils.parse_version(b)
        local len = math.max(#ta, #tb)
        for i = 1, len do
            local ai = ta[i] or 0
            local bi = tb[i] or 0
            if ai < bi then return -1
            elseif ai > bi then return 1
            end
        end
        return 0
    end

    if compare_versions(latest_version, current_version) <= 0 then
        return { success = true, message = "Up-to-date (current " .. current_version .. ")" }
    end

    local pending_zip = paths.backend_path(config.UPDATE_PENDING_ZIP)

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    if is_windows then
        local ps1_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.ps1")
        local temp_ps1 = fs.join(paths.get_backend_dir(), "temp_updater.ps1")
        m_utils.write_file(temp_ps1, m_utils.read_file(ps1_path))
        cmd = string.format('powershell -ExecutionPolicy Bypass -Command "& \'%s\' -Url \'%s\' -DestPath \'%s\' -ExtractDir \'%s\'"', temp_ps1, zip_url, pending_zip, paths.get_plugin_dir())
    else
        logger.log("LuaTools: self-update downloading " .. tostring(zip_url))
        -- Single-quoted, and curl is pinned to https for the request and for any
        -- redirect it follows, so a 302 cannot downgrade the update channel.
        local function download_command(url, sha)
            local command = string.format(
                "curl --proto '=https' --proto-redir '=https' -fL -o %s %s",
                guard.shell_quote(pending_zip), guard.shell_quote(url))
            if sha ~= "" then
                command = command .. string.format(
                    " && printf '%%s  %%s\\n' %s %s | sha256sum -c -",
                    guard.shell_quote(sha), guard.shell_quote(pending_zip))
            end
            return command
        end
        local download = download_command(zip_url, expected_sha)
        if fallback_url ~= "" and fallback_url ~= zip_url then
            download = "{ " .. download .. " || { rm -f "
                .. guard.shell_quote(pending_zip) .. "; "
                .. download_command(fallback_url, fallback_sha) .. "; }; }"
        end
        cmd = string.format(
            'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; '
            .. "{ %s && unzip -o -q %s -d %s; }"
            .. ' >> "${HOME:-/tmp}/.lumen.log" 2>&1',
            download,
            guard.shell_quote(pending_zip),
            guard.shell_quote(paths.get_plugin_dir()))
    end

    m_utils.exec(cmd)

    if fs.exists(pending_zip) then fs.remove(pending_zip) end
    if is_windows then
        local temp_ps1 = fs.join(paths.get_backend_dir(), "temp_updater.ps1")
        if fs.exists(temp_ps1) then fs.remove(temp_ps1) end
    end

    local msg = "LuaTools updated to " .. latest_version .. ". Please restart Steam."
    return { success = true, message = msg }
end

function auto_update.restart_steam()
    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    if is_windows then
        local script_path = paths.backend_path("restart_steam.cmd")
        if fs.exists(script_path) then
            m_utils.exec('start /b cmd /C "' .. script_path .. '"')
            return true
        end
    else
        -- slsteammoon: relaunch via restart_steam.sh, which kills Steam
        -- cleanly, waits, then starts the slsteam-moon wrapper so
        -- SLSsteam injection + provisioning happen on the next launch.
        local sh = fs.join(paths.get_plugin_dir(), "backend", "scripts", "restart_steam.sh")
        m_utils.exec('chmod +x "' .. sh .. '" 2>/dev/null')
        m_utils.exec('nohup bash "' .. sh .. '" > /dev/null 2>&1 &')
        return true
    end
    return false
end

function auto_update.apply_pending_update_if_any()
    return ""
end

return auto_update
