#!/usr/bin/env luajit

local ok_module, limits = pcall(dofile, "plugin/backend/source_limits.lua")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end
if not ok_module then limits = {} end

check("S1 source limit classifier module loads", ok_module)
check("S2 HTTP 429 is temporary rate limiting, not a daily quota",
  type(limits.classify) == "function"
    and limits.classify(429, '{"detail":"Daily limit reached"}') == "rate_limited")
check("S3 explicit daily response is a daily limit",
  type(limits.classify) == "function"
    and limits.classify(403, '{"detail":"Daily limit reached for this account"}') == "daily_limit")
check("S4 successful JSON can explicitly report the daily limit",
  type(limits.classify) == "function"
    and limits.classify(200, '{"error":"daily download limit exceeded"}') == "daily_limit")
check("S5 generic quota exhaustion is not mislabeled as daily",
  type(limits.classify) == "function"
    and limits.classify(403, '{"error":"quota exceeded"}') == "quota_exhausted")
check("S6 unrelated rejection has no source-limit classification",
  type(limits.classify) == "function"
    and limits.classify(403, '{"error":"forbidden"}') == nil)
check("S7 messages identify a custom source",
  type(limits.message) == "function"
    and limits.message("daily_limit", "My Custom API"):find("My Custom API", 1, true) ~= nil
    and limits.message("rate_limited", "My Custom API"):find("Too many requests", 1, true) ~= nil)
check("S8 explicit usage fields detect an exhausted daily allowance",
  type(limits.classify) == "function"
    and limits.classify(200, '{"daily_usage":25,"daily_limit":25}') == "daily_limit"
    and limits.classify(200, '{"daily_usage":24,"daily_limit":25}') == nil)

if failures > 0 then os.exit(1) end
print("ALL SOURCE LIMIT CHECKS PASSED")
