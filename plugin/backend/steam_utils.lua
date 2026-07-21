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

function steam_utils.get_game_install_path_response(appid)
    appid = tostring(appid)
    local steam_path = steam_utils.detect_steam_install_path()
    if not steam_path or steam_path == "" then
        return { success = false, error = "Could not find Steam installation path" }
    end

    -- Steam keeps two copies of the library list: config/libraryfolders.vdf
    -- and steamapps/libraryfolders.vdf. The content system reads the
    -- steamapps copy and the two can drift, so a drive added later may be
    -- present in one but stale or absent in the other. Reading only the
    -- config copy made whole drives invisible here. Union BOTH files (plus
    -- the Steam root itself) and de-duplicate.
    local seen = {}
    local all_library_paths = {}
    local function add_lib(p)
        if not p or p == "" then return end
        p = p:gsub("\\\\", "\\"):gsub("/+$", "")
        if p == "" or seen[p] then return end
        seen[p] = true
        table.insert(all_library_paths, p)
    end

    add_lib(steam_path)
    local vdf_candidates = {
        fs.join(steam_path, "config", "libraryfolders.vdf"),
        fs.join(steam_path, "steamapps", "libraryfolders.vdf"),
    }
    for _, vdf_path in ipairs(vdf_candidates) do
        if fs.exists(vdf_path) then
            local vdf_content = m_utils.read_file(vdf_path)
            if vdf_content then
                for p in vdf_content:gmatch('"path"%s+"([^"]+)"') do
                    add_lib(p)
                end
            end
        end
    end

    if #all_library_paths == 0 then
        return { success = false, error = "Could not find libraryfolders.vdf" }
    end

    local library_path = nil
    local appmanifest_path = nil

    for _, lib_path in ipairs(all_library_paths) do
        local candidate = fs.join(lib_path, "steamapps", "appmanifest_" .. appid .. ".acf")
        if fs.exists(candidate) then
            library_path = lib_path
            appmanifest_path = candidate
            break
        end
    end

    if not library_path or not appmanifest_path then
        return { success = false, error = "menu.error.notInstalled" }
    end

    local manifest_content = m_utils.read_file(appmanifest_path)
    if not manifest_content then
        return { success = false, error = "Failed to parse appmanifest" }
    end

    local install_dir = manifest_content:match('"installdir"%s+"([^"]+)"')
    if not install_dir then
        return { success = false, error = "Install directory not found" }
    end

    local full_install_path = fs.join(library_path, "steamapps", "common", install_dir)
    if not fs.exists(full_install_path) then
        return { success = false, error = "Game directory not found" }
    end

    return {
        success = true,
        installPath = full_install_path,
        installDir = install_dir,
        libraryPath = library_path,
        path = full_install_path
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
