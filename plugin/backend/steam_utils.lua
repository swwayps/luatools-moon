local m_utils = require("utils")
local millennium = require("millennium")
local fs = require("fs")
local logger = require("plugin_logger")
local paths = require("paths")

local steam_utils = {}

local STEAM_INSTALL_PATH = nil

function steam_utils.detect_steam_install_path()
    if STEAM_INSTALL_PATH then return STEAM_INSTALL_PATH end
    local success, path = pcall(millennium.steam_path)
    if success and path then
        STEAM_INSTALL_PATH = path
        logger.log("LuaTools: Steam install path set to " .. tostring(STEAM_INSTALL_PATH))
        return STEAM_INSTALL_PATH
    end
    return ""
end

function steam_utils.has_lua_for_app(appid)
    local base_path = steam_utils.detect_steam_install_path()
    if not base_path or base_path == "" then return false end

    local stplug_path = fs.join(base_path, "config", "stplug-in")
    local lua_file = fs.join(stplug_path, tostring(appid) .. ".lua")
    local disabled_file = fs.join(stplug_path, tostring(appid) .. ".lua.disabled")

    return fs.exists(lua_file) or fs.exists(disabled_file)
end

local function dependency_steam_path(deps)
    if deps and type(deps.steam_path) == "function" then
        local ok, value = pcall(deps.steam_path)
        return ok and tostring(value or "") or ""
    end
    if deps and type(deps.steam_path) == "string" then return deps.steam_path end
    return steam_utils.detect_steam_install_path()
end

local function library_paths(steam_path, deps)
    local exists = deps and deps.exists or fs.exists
    local read = deps and deps.read or m_utils.read_file
    local seen, result = {}, {}
    local function add(path)
        path = tostring(path or ""):gsub("\\\\", "\\"):gsub("/+$", "")
        if path == "" or seen[path] then return end
        seen[path] = true
        result[#result + 1] = path
    end
    add(steam_path)
    for _, candidate in ipairs({
        fs.join(steam_path, "config", "libraryfolders.vdf"),
        fs.join(steam_path, "steamapps", "libraryfolders.vdf"),
    }) do
        if exists(candidate) then
            local content = read(candidate)
            if type(content) == "string" then
                for path in content:gmatch('"path"%s+"([^"]+)"') do add(path) end
            end
        end
    end
    return result
end

function steam_utils.get_game_install_state(appid, deps)
    local number = tonumber(appid)
    if not number or number <= 0 or number ~= math.floor(number) then
        return { found = false, complete = false, error = "invalid appid" }
    end
    appid = tostring(math.floor(number))
    local steam_path = dependency_steam_path(deps)
    if steam_path == "" then
        return { found = false, complete = false,
            error = "Could not find Steam installation path" }
    end
    local exists = deps and deps.exists or fs.exists
    local read = deps and deps.read or m_utils.read_file

    for _, library_path in ipairs(library_paths(steam_path, deps)) do
        local manifest_path = fs.join(library_path, "steamapps",
            "appmanifest_" .. appid .. ".acf")
        if exists(manifest_path) then
            local content = read(manifest_path)
            if type(content) ~= "string" then
                return { found = true, complete = false,
                    libraryPath = library_path, appmanifestPath = manifest_path,
                    error = "Failed to parse appmanifest" }
            end
            local install_dir = content:match('"installdir"%s+"([^"]+)"')
            local game_name = content:match('"name"%s+"([^"]+)"')
            local state_flags = tonumber(content:match('"StateFlags"%s+"(%d+)"'))
            local bytes_downloaded = tonumber(
                content:match('"BytesDownloaded"%s+"(%d+)"'))
            local bytes_to_download = tonumber(
                content:match('"BytesToDownload"%s+"(%d+)"'))
            local install_path = install_dir and fs.join(library_path,
                "steamapps", "common", install_dir) or nil
            local directory_exists = type(install_path) == "string"
                and exists(install_path) or false
            local bytes_complete = bytes_to_download == nil
                or bytes_to_download == 0
                or (bytes_downloaded ~= nil and bytes_downloaded >= bytes_to_download)
            return {
                found = true,
                complete = state_flags == 4 and bytes_complete and directory_exists,
                steamPath = steam_path,
                libraryPath = library_path,
                appmanifestPath = manifest_path,
                gameName = game_name,
                installDir = install_dir,
                installPath = install_path,
                directoryExists = directory_exists,
                stateFlags = state_flags,
                bytesDownloaded = bytes_downloaded,
                bytesToDownload = bytes_to_download,
            }
        end
    end
    return { found = false, complete = false, steamPath = steam_path,
        error = "menu.error.notInstalled" }
end

function steam_utils.get_game_install_path_response(appid)
    local state = steam_utils.get_game_install_state(appid)
    if not state.found then return { success = false, error = state.error } end
    if not state.installDir then
        return { success = false, error = "Install directory not found" }
    end
    if not state.directoryExists then
        return { success = false, error = "Game directory not found" }
    end

    return {
        success = true,
        installPath = state.installPath,
        installDir = state.installDir,
        libraryPath = state.libraryPath,
        path = state.installPath
    }
end

function steam_utils.open_game_folder(path)
    if not path or path == "" or not fs.exists(path) then return false end

    local is_win = (m_utils.getenv("OS") or ""):find("Windows") ~= nil
    if is_win then
        -- In Windows, explorer accepts backslashes
        path = path:gsub("/", "\\")
        m_utils.exec('explorer "' .. path .. '"')
    else
        -- slsteammoon: open in the system file manager. Reset the Steam
        -- runtime env (LD_LIBRARY_PATH/LD_AUDIT/LD_PRELOAD point at the
        -- 32-bit Steam runtime and crash spawned GUI binaries) and
        -- detach via setsid so the manager uses system libs and outlives
        -- the Steam session.
        m_utils.exec(
            'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY; ' ..
            'setsid xdg-open "' .. path .. '" >/dev/null 2>&1 &')
    end
    return true
end

return steam_utils
