#!/usr/bin/env luajit

package.loaded.json = {}
package.loaded.http_client = {}
package.loaded.lua_tools_auth = {}

local fixes = dofile("plugin/backend/lua_tools_fixes.lua")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local payload = {
  appid = "3321460",
  name = "Crimson Desert",
  header_image = "https://cdn.example/header.jpg",
  fixes = {
    { id = "11111111-1111-4111-8111-111111111111", title = "Denuvo build",
      tags = { { name = "DenuvOwO", slug = "denuvowo" } },
      hasManifest = true, hasFix = true, manifestFilename = "3321460_old.lua",
      fixFilename = "3321460.zip", createdAt = "2026-08-01T00:00:00Z" },
    { id = "22222222-2222-4222-8222-222222222222", title = "Bypass",
      tags = { { name = "Bypass", slug = "bypass" } }, hasFix = true },
    { id = "33333333-3333-4333-8333-333333333333", title = "Recommended build",
      tags = { { name = "voices38 (crack)", slug = "voices38-crack" } },
      hasManifest = true, hasFix = true, manifestFilename = "3321460.lua" },
  },
}
local request
local game = fixes.get_game(3321460, {
  get = function(url, options)
    request = { url = url, options = options }
    return { status = 200, body = "game" }
  end,
  decode = function() return payload end,
  auth_status = function() return { success = true, configured = false } end,
})
check("F1 game fixes use the official public lua.tools endpoint",
  request.url == "https://lua.tools/api/denuvo/fixes?appid=3321460")
check("F2 every official category remains present", #game.fixes == 3)
check("F3 voices38 is recommended before bypass and DenuvOwO",
  game.fixes[1].category == "voices38" and game.fixes[2].category == "bypass"
    and game.fixes[3].category == "denuvowo")
check("F4 DenuvOwO remains supported but is readiness gated",
  game.fixes[3].requiresPreparation == true)
check("F5 public catalogue stays visible but reports login requirement",
  game.requiresAuth == true and game.authConfigured == false)
check("F6 manifest metadata is preserved for the recommended-version prompt",
  game.fixes[1].hasManifest == true
    and game.fixes[1].manifestFilename == "3321460.lua")

check("F7 online-fix and FreeTP categories are recognized",
  fixes.classify({ tags = { { slug = "online-fix" } } }) == "online_fix"
    and fixes.classify({ tags = { { slug = "freetp" } } }) == "freetp")

local signed_request
local signed = fixes.resolve_download(
  "33333333-3333-4333-8333-333333333333", "fix", {
    get_token = function() return "access-secret" end,
    get = function(url, options)
      signed_request = { url = url, options = options }
      return { status = 200, body = "signed" }
    end,
    decode = function() return { url = "https://signed.example/fix.zip?private=1" } end,
  })
check("F8 download URL is resolved only through the authenticated official endpoint",
  signed_request.url:find("https://lua.tools/api/denuvo/download?", 1, true) == 1
    and signed_request.options.headers.Authorization == "Bearer access-secret")
check("F9 signed artifact URL is returned only to backend callers",
  signed.url == "https://signed.example/fix.zip?private=1")
check("F10 invalid IDs and slots cannot alter the official request",
  fixes.resolve_download("../bad", "fix", { get_token = function() return "x" end }) == nil
    and fixes.resolve_download("33333333-3333-4333-8333-333333333333", "other",
      { get_token = function() return "x" end }) == nil)

local listing = fixes.list_games({
  get = function() return { status = 200, body = "listing" } end,
  decode = function() return { games = { { appid = "10", name = "Ten", fixCount = 2 } } } end,
})
check("F11 settings catalogue normalizes the public games list",
  listing.success == true and listing.games[1].appid == 10
    and listing.games[1].name == "Ten")

local same_category = fixes.get_game(10, {
  get = function() return { status = 200, body = "same-category" } end,
  decode = function()
    return { fixes = {
      { id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", title = "Official first",
        tags = { { slug = "voices38-crack" } }, hasFix = true },
      { id = "11111111-1111-4111-8111-111111111111", title = "Official second",
        tags = { { slug = "voices38-crack" } }, hasFix = true },
    } }
  end,
  auth_status = function() return { configured = true } end,
})
check("F12 equal-category candidates preserve the official API order",
  same_category.fixes[1].title == "Official first"
    and same_category.fixes[2].title == "Official second")

local gang_beasts_payload = {
  appid = "285900",
  name = "Gang Beasts",
  header_image = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/285900/header.jpg",
  fixes = {
    {
      id = "online-fix:6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf",
      title = "Gang Beasts online",
      description = "Online multiplayer fix.",
      tags = { { id = "afae0064-4bb0-4735-93f2-8c5c4e7e3287",
        name = "Online Fix", slug = "online-fix", color = "#3b82f6" } },
      hasManifest = false,
      hasFix = true,
      manifestFilename = nil,
      fixFilename = "Gang Beasts online.zip",
      createdAt = "1970-01-01T00:00:00.000Z",
    },
  },
}
local gang_beasts = fixes.get_game(285900, {
  get = function() return { status = 200, body = "gang-beasts" } end,
  decode = function() return gang_beasts_payload end,
  auth_status = function() return { success = true, configured = true } end,
})
check("F13 namespaced official Online Fix IDs remain visible",
  gang_beasts.available == true and #gang_beasts.fixes == 1
    and gang_beasts.fixes[1].category == "online_fix"
    and gang_beasts.fixes[1].id == "online-fix:6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf")

local namespaced_request
local namespaced_download = fixes.resolve_download(
  "online-fix:6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf", "fix", {
    get_token = function() return "access-secret" end,
    get = function(url, options)
      namespaced_request = { url = url, options = options }
      return { status = 200, body = "namespaced-signed" }
    end,
    decode = function()
      return { url = "https://signed.example/gang-beasts.zip?private=1" }
    end,
  })
check("F14 namespaced ID is preserved and URL-encoded for signed download",
  namespaced_download and namespaced_download.url:find("gang-beasts.zip", 1, true)
    and namespaced_request.url:find(
      "fix=online-fix%3A6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf", 1, true))
check("F15 malformed namespaces remain rejected",
  fixes.resolve_download("../online-fix:6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf", "fix",
    { get_token = function() return "x" end }) == nil
    and fixes.resolve_download("online-fix?:6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf", "fix",
      { get_token = function() return "x" end }) == nil)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS FIXES CHECKS PASSED")
