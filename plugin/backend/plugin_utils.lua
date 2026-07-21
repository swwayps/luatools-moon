local m_utils = require("utils")
local fs = require("fs")
local cjson = require("json")
local paths = require("paths")
local logger = require("plugin_logger")

local utils = {}

function utils.read_text(path)
    return m_utils.read_file(path) or ""
end

function utils.write_text(path, text)
    m_utils.write_file(path, text)
end

function utils.read_json(path)
    local content = utils.read_text(path)
    if content == "" then return {} end
    local success, data = pcall(cjson.decode, content)
    if success then
        return data
    end
    return {}
end

function utils.decode_json(text)
    if not text or text == "" then return {} end
    local success, data = pcall(cjson.decode, text)
    if success then return data else return {} end
end

function utils.encode_json(data)
    -- If it's the api_manifest table structure, use a custom strict formatter
    if type(data) == "table" and data.api_list and type(data.api_list) == "table" then
        local lines = {}
        table.insert(lines, '{"api_list": [')
        
        for i, api in ipairs(data.api_list) do
            table.insert(lines, '        {')
            -- Ensure "name" is always first
            table.insert(lines, '            "name": ' .. cjson.encode(api.name or "") .. ',')
            table.insert(lines, '            "url": ' .. cjson.encode(api.url or ""):gsub("\\/", "/") .. ',')
            table.insert(lines, '            "success_code": ' .. tostring(api.success_code or 200) .. ',')
            table.insert(lines, '            "unavailable_code": ' .. tostring(api.unavailable_code or 404) .. ',')
            table.insert(lines, '            "enabled": ' .. tostring(api.enabled ~= false))
            
            if i == #data.api_list then
                table.insert(lines, '        }')
            else
                table.insert(lines, '        },')
            end
        end
        
        table.insert(lines, '    ]}')
        return table.concat(lines, "\n")
    end

    -- Fallback for all other normal JSON serializations
    local success, content = pcall(cjson.encode, data)
    if success then
        return content
    else 
        return "{}" 
    end
end

function utils.write_json(path, data)
    local success, content = pcall(cjson.encode, data)
    if not success then
        logger.warn("write_json failed to encode JSON for " .. tostring(path))
        return false
    end
    m_utils.write_file(path, content)
    return true
end

function utils.write_json_atomic(path, data)
    local success, content = pcall(cjson.encode, data)
    if not success then
        logger.warn("write_json_atomic failed to encode JSON for " .. tostring(path))
        return false
    end

    local temp_path = path .. ".tmp"
    local backup_path = path .. ".bak"
    local backup_temp_path = backup_path .. ".tmp"
    pcall(os.remove, temp_path)
    local write_ok, write_result = pcall(m_utils.write_file, temp_path, content)
    if not write_ok or write_result == false then
        pcall(os.remove, temp_path)
        logger.warn("write_json_atomic could not write " .. tostring(temp_path))
        return false
    end

    local written = m_utils.read_file(temp_path)
    local valid = written and pcall(cjson.decode, written)
    if not valid then
        pcall(os.remove, temp_path)
        logger.warn("write_json_atomic could not verify " .. tostring(temp_path))
        return false
    end

    local had_existing = fs.exists(path)
    if had_existing then
        local active_content = m_utils.read_file(path)
        if active_content == nil then
            pcall(os.remove, temp_path)
            logger.warn("write_json_atomic could not read " .. tostring(path))
            return false
        end

        pcall(os.remove, backup_temp_path)
        local backup_ok, backup_result =
            pcall(m_utils.write_file, backup_temp_path, active_content)
        if not backup_ok or backup_result == false
            or m_utils.read_file(backup_temp_path) ~= active_content then
            pcall(os.remove, backup_temp_path)
            pcall(os.remove, temp_path)
            logger.warn("write_json_atomic could not stage backup for " .. tostring(path))
            return false
        end

        pcall(os.remove, backup_path)
        if not os.rename(backup_temp_path, backup_path) then
            pcall(os.remove, backup_temp_path)
            pcall(os.remove, temp_path)
            logger.warn("write_json_atomic could not promote backup for " .. tostring(path))
            return false
        end
    end

    -- On Linux, rename over an existing file is one atomic replacement. The
    -- active JSON therefore remains readable until the verified temp is live.
    if not os.rename(temp_path, path) then
        pcall(os.remove, temp_path)
        logger.warn("write_json_atomic could not replace " .. tostring(path))
        return false
    end

    return true
end

function utils.count_apis(text)
    if not text or text == "" then return 0 end
    local success, data = pcall(cjson.decode, text)
    if success and type(data) == "table" and type(data.api_list) == "table" then
        local count = 0
        for _ in pairs(data.api_list) do count = count + 1 end
        return count
    end
    -- Fallback simple string match count for '"name"'
    local _, count = text:gsub('"name"', '"name"')
    return count
end

function utils.normalize_manifest_text(text)
    local content = text or ""
    -- remove whitespace
    content = content:match("^%s*(.-)%s*$")
    if content == "" then return content end

    content = content:gsub(",%s*%]", "]")
    content = content:gsub(",%s*}%s*$", "}")

    if content:sub(1, 10) == '"api_list"' or content:sub(1, 10) == "'api_list'" or content:sub(1, 8) == "api_list" then
        if content:sub(1, 1) ~= "{" then
            content = "{" .. content
        end
        if content:sub(-1) ~= "}" then
            -- remove trailing commas
            content = content:gsub(",$", "") .. "}"
        end
    end

    local success = pcall(cjson.decode, content)
    if success then
        return content
    end
    return text
end

function utils.parse_version(version)
    local parts = {}
    for part in string.gmatch(tostring(version), "%d+") do
        table.insert(parts, tonumber(part))
    end
    if #parts == 0 then return {0} end
    return parts
end

function utils.get_plugin_version()
    local plugin_json_path = fs.join(paths.get_plugin_dir(), "plugin.json")
    local data = utils.read_json(plugin_json_path)
    return tostring(data.version or "0")
end

function utils.ensure_temp_download_dir()
    local root = paths.backend_path("temp_dl")
    if not fs.exists(root) then
        fs.create_directories(root)
    end
    return root
end

return utils
