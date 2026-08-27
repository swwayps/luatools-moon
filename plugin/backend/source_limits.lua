local source_limits = {}

local function normalized_body(body)
  return tostring(body or ""):lower()
    :gsub("[_%-%./]+", " ")
    :gsub("%s+", " ")
end

local function has_exhaustion_word(text)
  return text:find("reached", 1, true)
    or text:find("exceeded", 1, true)
    or text:find("exhausted", 1, true)
    or text:find("used up", 1, true)
end

function source_limits.classify(status, body)
  status = tonumber(status)
  -- HTTP 429 has precise protocol semantics: the caller is sending requests
  -- too quickly. Never relabel it as a daily quota based on an error body.
  if status == 429 then return "rate_limited" end

  local raw = tostring(body or ""):lower()
  local daily_usage = tonumber(raw:match(
    "[\"']?daily[_%s%-]*usage[\"']?%s*:%s*(%d+)"))
  local daily_limit = tonumber(raw:match(
    "[\"']?daily[_%s%-]*limit[\"']?%s*:%s*(%d+)"))
  if daily_usage and daily_limit and daily_limit > 0
      and daily_usage >= daily_limit then
    return "daily_limit"
  end

  local text = normalized_body(body)
  local daily_phrase = text:find("daily limit", 1, true)
    or text:find("daily download limit", 1, true)
    or text:find("daily quota", 1, true)
  if daily_phrase and has_exhaustion_word(text) then return "daily_limit" end

  if text:find("too many requests", 1, true)
      or (text:find("rate limit", 1, true) and has_exhaustion_word(text)) then
    return "rate_limited"
  end
  if text:find("quota", 1, true) and has_exhaustion_word(text) then
    return "quota_exhausted"
  end
  return nil
end

function source_limits.message(code, source_name)
  local source = tostring(source_name or ""):match("^%s*(.-)%s*$")
  if source == "" then source = "this source" end
  if code == "daily_limit" then
    return "Daily download limit reached for " .. source
      .. ". Try again tomorrow or choose another source."
  end
  if code == "rate_limited" then
    return "Too many requests to " .. source
      .. ". Wait a moment and try again."
  end
  if code == "quota_exhausted" then
    return "The quota for " .. source
      .. " has been exhausted. Try again later or choose another source."
  end
  return nil
end

return source_limits
