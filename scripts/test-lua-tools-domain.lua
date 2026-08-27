#!/usr/bin/env luajit

package.path = "plugin/backend/?.lua;" .. package.path

local domain = require("lua_tools_domain")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

check("positive numeric AppIDs are normalized",
  domain.positive_appid(238320) == 238320)
check("decimal AppID strings are normalized",
  domain.positive_appid("00238320") == 238320)
check("non-decimal AppID aliases are rejected",
  domain.positive_appid("1e3") == nil
    and domain.positive_appid("238320.0") == nil
    and domain.positive_appid("../238320") == nil)
check("non-positive and fractional AppIDs are rejected",
  domain.positive_appid(0) == nil
    and domain.positive_appid(-1) == nil
    and domain.positive_appid(1.5) == nil)

local uuid = "6FE77C52-0BA3-4DCF-A296-2FF3E54A53CF"
check("plain fix IDs are normalized", domain.fix_id(uuid)
  == "6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf")
check("namespaced fix IDs preserve their namespace",
  domain.fix_id("online-fix:" .. uuid)
    == "online-fix:6fe77c52-0ba3-4dcf-a296-2ff3e54a53cf")
check("malformed fix IDs are rejected",
  domain.fix_id("../online-fix:" .. uuid) == nil
    and domain.fix_id("not-a-uuid") == nil)

check("known categories expose their shared rank",
  domain.category("voices38") == "voices38"
    and domain.category_rank("voices38") == 10
    and domain.category_rank("denuvowo") == 90)
check("unknown categories are rejected",
  domain.category("unknown") == nil
    and domain.category_rank("unknown") == nil)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS DOMAIN CHECKS PASSED")
