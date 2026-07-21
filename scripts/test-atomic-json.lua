#!/usr/bin/env luajit
-- Persistent JSON writes must either replace the catalog completely or keep
-- the last valid file available for recovery.

local path = "/tmp/luatools-atomic-json-" .. tostring(os.time()) .. ".json"
local temp_path = path .. ".tmp"
local backup_path = path .. ".bak"
local corrupt_write = false
local active_missing_during_replace = false

local function read_file(file_path)
    local file = io.open(file_path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function write_file(file_path, content)
    local file = assert(io.open(file_path, "wb"))
    file:write(corrupt_write and "INVALID" or content)
    file:close()
    return true
end

package.loaded.utils = {
    read_file = read_file,
    write_file = write_file,
}
package.loaded.fs = {
    exists = function(file_path) return read_file(file_path) ~= nil end,
    join = function(...) return table.concat({ ... }, "/") end,
}
package.loaded.json = {
    encode = function(data) return tostring(data.value) end,
    decode = function(content)
        if content == "INVALID" then error("invalid JSON") end
        return { value = content }
    end,
}
package.loaded.paths = {
    get_plugin_dir = function() return "/tmp" end,
    backend_path = function(name) return "/tmp/" .. name end,
}
package.loaded.plugin_logger = {
    warn = function() end,
}

local utils = dofile("plugin/backend/plugin_utils.lua")
local failures = 0
local function check(condition, message)
    if condition then print("ok   " .. message)
    else print("FAIL " .. message); failures = failures + 1 end
end

write_file(path, "old")
check(utils.write_json_atomic(path, { value = "new" }) == true,
    "valid atomic write succeeds")
check(read_file(path) == "new", "new JSON becomes active")
check(read_file(backup_path) == "old", "previous JSON remains as a backup")

corrupt_write = true
check(utils.write_json_atomic(path, { value = "broken" }) == false,
    "unverifiable temporary JSON is rejected")
check(read_file(path) == "new", "failed encoding write keeps the active JSON")
corrupt_write = false

local real_rename = os.rename
os.rename = function(from, to)
    if from == temp_path and to == path then
        active_missing_during_replace = read_file(path) == nil
        return nil, "simulated failure"
    end
    return real_rename(from, to)
end
check(utils.write_json_atomic(path, { value = "newer" }) == false,
    "failed final rename is reported")
os.rename = real_rename
check(not active_missing_during_replace,
    "active JSON remains available until the atomic replacement")
check(read_file(path) == "new", "failed final rename keeps the active JSON")
check(read_file(backup_path) == "new", "failed final rename keeps a recovery backup")

os.remove(path)
os.remove(temp_path)
os.remove(backup_path)

if failures > 0 then
    print("\n" .. failures .. " CHECK(S) FAILED")
    os.exit(1)
end
print("\nALL ATOMIC JSON CHECKS PASSED")
