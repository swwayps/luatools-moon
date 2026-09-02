-- LuaTools self-update must still discover a newer Stable release when GitHub
-- is unavailable. The external HTTP boundary is replaced; the real updater
-- parses the manifest, validates the host, compares versions, and builds the
-- download command.
package.path = "plugin/backend/?.lua;" .. package.path

local executed
local mode = "mirror-only"

package.preload["utils"] = function()
  return {
    getenv = function() return nil end,
    exec = function(command) executed = command; return 0 end,
    write_file = function() return true end,
    read_file = function() return "" end,
  }
end
package.preload["fs"] = function()
  return {
    join = function(...) return table.concat({...}, "/") end,
    exists = function() return false end,
    remove = function() return true end,
  }
end
package.preload["http_client"] = function()
  return {
    get = function(url)
      if url:find("api.github.com", 1, true) then
        if mode == "github-primary" then
          return { status = 200, body = "github-fixture" }
        end
        return nil, "offline"
      end
      if url:find("cdn.jsdelivr.net", 1, true) then
        return {
          status = 200,
          body = "mirror-fixture",
        }
      end
      return nil, "unexpected URL"
    end,
  }
end
package.preload["config"] = function()
  return { UPDATE_CONFIG_FILE = "update.json", UPDATE_PENDING_ZIP = "pending.zip" }
end
package.preload["plugin_logger"] = function()
  return { log = function() end, warn = function() end }
end
package.preload["paths"] = function()
  return {
    backend_path = function(name) return "/tmp/" .. name end,
    get_plugin_dir = function() return "/plugin" end,
    get_backend_dir = function() return "/plugin/backend" end,
  }
end
package.preload["plugin_utils"] = function()
  return {
    read_json = function()
      return { github = { owner = "swwayps", repo = "luatools-moon", asset_name = "luatools-linux.zip" } }
    end,
    decode_json = function(body)
      if body == "github-fixture" then
        return {
          tag_name = "v2.9",
          assets = {{
            name = "luatools-linux.zip",
            browser_download_url =
              "https://github.com/swwayps/luatools-moon/releases/download/v2.9/luatools-linux.zip",
          }},
        }
      end
      if body == "mirror-fixture" then
        return {
          schema = 1,
          components = {
            plugin = {
              tag = "v2.9",
              id = 29,
              size = 290,
              sha256 = string.rep("a", 64),
              url = "https://cdn.jsdelivr.net/gh/swwayps/jsdelivr@"
                .. "0123456789012345678901234567890123456789"
                .. "/releases/plugin/v2.9/hash/luatools-linux.zip",
            },
          },
        }
      end
      return {}
    end,
    parse_version = function(value)
      local out = {}
      for part in tostring(value):gmatch("%d+") do out[#out + 1] = tonumber(part) end
      return out
    end,
    get_plugin_version = function() return "2.8" end,
  }
end
package.preload["steam_utils"] = function() return {} end
package.preload["guard"] = function()
  return {
    repo_segment = function(value) return value end,
    tag_name = function(value) return value end,
    https_url = function(value, opts)
      local host = value:match("^https://([^/]+)")
      return opts.hosts[host] and value or nil
    end,
    shell_quote = function(value) return "'" .. value .. "'" end,
  }
end

local auto_update = dofile("plugin/backend/auto_update.lua")
local result = auto_update.check_for_updates_now()

local failures = 0
local function check(name, condition)
  if condition then
    print("ok:   " .. name)
  else
    failures = failures + 1
    print("FAIL: " .. name)
  end
end

check("GitHub outage falls back to the jsDelivr manifest", result.success == true)
check("mirror exposes the new v2.9 release", result.message
  and result.message:find("2.9", 1, true) ~= nil)
check("updater downloads from the commit-pinned mirror URL", executed
  and executed:find("cdn.jsdelivr.net/gh/swwayps/jsdelivr@", 1, true) ~= nil)
check("mirror download is checked against the manifest digest", executed
  and executed:find("sha256sum", 1, true) ~= nil
  and executed:find(string.rep("a", 64), 1, true) ~= nil)
check("cdn.jsdelivr.net is an allowed update host",
  auto_update.ALLOWED_UPDATE_HOSTS["cdn.jsdelivr.net"] == true)

mode = "github-primary"
executed = nil
result = auto_update.check_for_updates_now()
check("GitHub asset download keeps the mirror as a transfer fallback",
  result.success == true and executed
    and executed:find("github.com/swwayps/luatools%-moon/releases", 1) ~= nil
    and executed:find("cdn.jsdelivr.net/gh/swwayps/jsdelivr@", 1, true) ~= nil
    and executed:find(" || ", 1, true) ~= nil)
check("transfer fallback verifies the mirrored archive",
  executed and executed:find("sha256sum", 1, true) ~= nil
    and executed:find(string.rep("a", 64), 1, true) ~= nil)

os.exit(failures == 0 and 0 or 1)
