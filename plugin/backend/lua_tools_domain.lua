-- Shared validation and vocabulary for lua.tools-facing backend modules.

local domain = {}

local CATEGORY_RANK = {
  voices38 = 10,
  bypass = 20,
  online_fix = 30,
  freetp = 40,
  other = 50,
  denuvowo = 90,
}

local CATEGORY_NAMES = {
  "voices38", "bypass", "online_fix", "freetp", "other", "denuvowo",
}

function domain.positive_appid(value)
  if type(value) == "string" then
    if not value:match("^%d+$") then return nil end
  elseif type(value) ~= "number" then
    return nil
  end
  local number = tonumber(value)
  if not number or number <= 0 or number ~= math.floor(number) then return nil end
  return math.floor(number)
end

function domain.fix_id(value)
  value = tostring(value or "")
  local namespace, uuid = value:match("^([a-z0-9][a-z0-9_%-]*):(.+)$")
  if namespace then
    if #namespace > 32 then return nil end
    value = uuid
  end
  local a, b, c, d, e = value:match(
    "^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
  if not a or #a ~= 8 or #b ~= 4 or #c ~= 4 or #d ~= 4 or #e ~= 12 then
    return nil
  end
  local normalized = value:lower()
  return namespace and (namespace .. ":" .. normalized) or normalized
end

function domain.category(value)
  value = tostring(value or "")
  return CATEGORY_RANK[value] and value or nil
end

function domain.category_rank(value)
  return CATEGORY_RANK[tostring(value or "")]
end

function domain.category_names()
  local result = {}
  for index, name in ipairs(CATEGORY_NAMES) do result[index] = name end
  return result
end

return domain
