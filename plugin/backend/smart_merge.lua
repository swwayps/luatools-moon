local smart_merge = {}

local function positive_integer(value)
    local n = tonumber(value)
    if not n or n <= 0 or n ~= math.floor(n) then return nil end
    return n
end

local function normalize_decimal(value)
    local text = tostring(value or "")
    if not text:match("^%d+$") then return nil end
    text = text:gsub("^0+", "")
    if text == "" then return nil end
    return text
end

local function strip_comment(line)
    local quote, escaped = nil, false
    for i = 1, #line do
        local ch = line:sub(i, i)
        if quote then
            if escaped then escaped = false
            elseif ch == "\\" then escaped = true
            elseif ch == quote then quote = nil end
        elseif ch == '"' or ch == "'" then
            quote = ch
        elseif ch == "-" and line:sub(i, i + 1) == "--" then
            return line:sub(1, i - 1)
        end
    end
    return line
end

function smart_merge.parse_lua(text)
    local parsed = { bare = {}, keys = {}, manifests = {} }
    for raw in tostring(text or ""):gmatch("[^\r\n]+") do
        local line = strip_comment(raw):match("^%s*(.-)%s*$")
        local id = line:match("^addappid%s*%(%s*(%d+)%s*%)%s*;?%s*$")
        if id then
            id = positive_integer(id)
            if id then parsed.bare[id] = true end
        else
            local key_id, _, key = line:match(
                "^addappid%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*['\"]([0-9A-Fa-f]+)['\"]%s*%)%s*;?%s*$")
            if key_id and #key == 64 then
                key_id = positive_integer(key_id)
                if key_id then parsed.keys[key_id] = key:lower() end
            else
                local depot, gid = line:match(
                    "^setManifestid%s*%(%s*(%d+)%s*,%s*['\"](%d+)['\"]%s*[,)]")
                depot, gid = positive_integer(depot), normalize_decimal(gid)
                if depot and gid then parsed.manifests[depot] = gid end
            end
        end
    end
    return parsed
end
local function sorted_numeric_keys(map)
    local out = {}
    for id in pairs(map or {}) do out[#out + 1] = id end
    table.sort(out)
    return out
end

local function candidate_better(a, b)
    if not b then return true end
    if a.exact ~= b.exact then return a.exact end
    if a.votes ~= b.votes then return a.votes > b.votes end
    if a.priority ~= b.priority then return a.priority < b.priority end
    return a.source_index < b.source_index
end

function smart_merge.merge_sources(appid, sources, current_gids)
    appid = positive_integer(appid)
    if not appid then return nil, "invalid appid" end
    local result = {
        bare = { [appid] = true }, keys = {}, manifest_refs = {},
        conflicts = {}, contributors = {},
    }
    local key_candidates, contributor_seen = {}, {}

    for _, source in ipairs(sources or {}) do
        local parsed = source.parsed or smart_merge.parse_lua(source.lua_text)
        local contributed = false
        for id in pairs(parsed.bare) do result.bare[id] = true; contributed = true end
        for depot, gid in pairs(parsed.manifests) do
            result.manifest_refs[depot] = result.manifest_refs[depot] or {}
            result.manifest_refs[depot][gid] = true
            contributed = true
        end
        for id, key in pairs(parsed.keys) do
            key_candidates[id] = key_candidates[id] or {}
            local group = key_candidates[id][key]
            if not group then
                group = { key = key, votes = 0, exact = false,
                    priority = tonumber(source.priority) or math.huge,
                    source_index = tonumber(source.index) or math.huge,
                    sources = {} }
                key_candidates[id][key] = group
            end
            group.votes = group.votes + 1
            group.sources[#group.sources + 1] = source.name or tostring(source.index or "unknown")
            if source.exact_current and source.exact_current[id] then group.exact = true end
            local priority = tonumber(source.priority) or math.huge
            local index = tonumber(source.index) or math.huge
            if priority < group.priority or (priority == group.priority and index < group.source_index) then
                group.priority, group.source_index = priority, index
            end
            contributed = true
        end
        if contributed and not contributor_seen[source.name or source.index] then
            local name = source.name or tostring(source.index or "Unknown")
            contributor_seen[name] = true
            result.contributors[#result.contributors + 1] = name
        end
    end

    for id, groups in pairs(key_candidates) do
        local best, count = nil, 0
        for _, candidate in pairs(groups) do
            count = count + 1
            if candidate_better(candidate, best) then best = candidate end
        end
        result.keys[id] = best.key
        if count > 1 then result.conflicts[#result.conflicts + 1] = { id = id, selected = best.key } end
    end
    table.sort(result.contributors)
    table.sort(result.conflicts, function(a, b) return a.id < b.id end)
    return result
end
function smart_merge.emit_lua(appid, result)
    appid = assert(positive_integer(appid), "invalid appid")
    local lines = { "addappid(" .. tostring(appid) .. ")" }
    for _, id in ipairs(sorted_numeric_keys(result.bare)) do
        if id ~= appid then lines[#lines + 1] = "addappid(" .. tostring(id) .. ")" end
    end
    for _, id in ipairs(sorted_numeric_keys(result.keys)) do
        lines[#lines + 1] = string.format('addappid(%d, 1, "%s")', id, result.keys[id])
    end
    return table.concat(lines, "\n") .. "\n"
end

local function lex_vdf(text)
    local tokens, i = {}, 1
    while i <= #text do
        local ch = text:sub(i, i)
        if ch:match("%s") then
            i = i + 1
        elseif ch == "{" or ch == "}" then
            tokens[#tokens + 1] = ch
            i = i + 1
        elseif ch == '"' then
            local out, escaped = {}, false
            i = i + 1
            while i <= #text do
                ch = text:sub(i, i)
                if escaped then out[#out + 1] = ch; escaped = false
                elseif ch == "\\" then escaped = true
                elseif ch == '"' then i = i + 1; break
                else out[#out + 1] = ch end
                i = i + 1
            end
            tokens[#tokens + 1] = table.concat(out)
        else
            i = i + 1
        end
    end
    return tokens
end

local function parse_vdf_map(tokens, pos)
    local out = {}
    while pos <= #tokens and tokens[pos] ~= "}" do
        local key = tokens[pos]; pos = pos + 1
        if tokens[pos] == "{" then
            out[key], pos = parse_vdf_map(tokens, pos + 1)
        elseif tokens[pos] and tokens[pos] ~= "}" then
            out[key] = tokens[pos]; pos = pos + 1
        else
            return nil, pos
        end
    end
    return out, pos + 1
end

function smart_merge.parse_appinfo_gids(text)
    local tokens = lex_vdf(tostring(text or ""))
    local root, pos = {}, 1
    while pos <= #tokens do
        local key = tokens[pos]; pos = pos + 1
        if tokens[pos] == "{" then root[key], pos = parse_vdf_map(tokens, pos + 1)
        else pos = pos + 1 end
    end
    local body = root.appinfo or root
    local result = {}
    for depot, node in pairs(type(body.depots) == "table" and body.depots or {}) do
        local id = positive_integer(depot)
        local public = type(node) == "table" and type(node.manifests) == "table"
            and node.manifests.public or nil
        local gid = type(public) == "table" and normalize_decimal(public.gid) or nil
        if id and gid then result[id] = gid end
    end
    return result
end

local function u32le(bytes, pos)
    local a, b, c, d = bytes:byte(pos, pos + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function decimal_mul_add(text, multiplier, addend)
    local out, carry = {}, addend
    for i = #text, 1, -1 do
        local value = tonumber(text:sub(i, i)) * multiplier + carry
        out[#out + 1] = tostring(value % 10)
        carry = math.floor(value / 10)
    end
    while carry > 0 do out[#out + 1] = tostring(carry % 10); carry = math.floor(carry / 10) end
    local forward = {}
    for i = #out, 1, -1 do forward[#forward + 1] = out[i] end
    return table.concat(forward):gsub("^0+", ""):gsub("^$", "0")
end

local function read_varint(bytes, pos, limit)
    local chunks = {}
    for _ = 1, 10 do
        if pos > limit then return nil, pos end
        local byte = bytes:byte(pos); pos = pos + 1
        chunks[#chunks + 1] = byte % 128
        if byte < 128 then
            local decimal = "0"
            for i = #chunks, 1, -1 do decimal = decimal_mul_add(decimal, 128, chunks[i]) end
            return decimal, pos
        end
    end
    return nil, pos
end

local function parse_metadata(bytes, first, last)
    local meta, pos = {}, first
    while pos <= last do
        local tag_text
        tag_text, pos = read_varint(bytes, pos, last)
        local tag = tonumber(tag_text)
        if not tag then return nil, "invalid protobuf tag" end
        local field, wire = math.floor(tag / 8), tag % 8
        if wire == 0 then
            local value
            value, pos = read_varint(bytes, pos, last)
            if not value then return nil, "truncated protobuf varint" end
            if field == 1 then meta.depot = positive_integer(value)
            elseif field == 2 then meta.gid = normalize_decimal(value)
            elseif field == 3 then meta.creation_time = tonumber(value) end
        elseif wire == 1 then pos = pos + 8
        elseif wire == 2 then
            local length
            length, pos = read_varint(bytes, pos, last)
            length = tonumber(length)
            if not length then return nil, "invalid protobuf length" end
            pos = pos + length
        elseif wire == 5 then pos = pos + 4
        else return nil, "unsupported protobuf wire type" end
        if pos > last + 1 then return nil, "truncated protobuf field" end
    end
    return meta
end

function smart_merge.parse_manifest(bytes, expected_depot, expected_gid)
    bytes = tostring(bytes or "")
    local pos, saw_payload, metadata = 1, false, nil
    while pos <= #bytes do
        local magic = u32le(bytes, pos)
        if not magic then return nil, "truncated manifest section" end
        if magic == 0x32C415AB then
            if pos + 3 ~= #bytes then return nil, "terminal marker is not final" end
            pos = pos + 4
            break
        end
        local length = u32le(bytes, pos + 4)
        if not length then return nil, "truncated manifest section" end
        local first, last = pos + 8, pos + 7 + length
        if last > #bytes then return nil, "manifest section exceeds file" end
        if magic == 0x71F617D0 then saw_payload = true
        elseif magic == 0x1F4812BE then
            local err
            metadata, err = parse_metadata(bytes, first, last)
            if not metadata then return nil, err end
        end
        pos = last + 1
    end
    if not saw_payload then return nil, "missing payload section" end
    if not metadata or not metadata.depot or not metadata.gid then return nil, "missing manifest metadata" end
    expected_depot = positive_integer(expected_depot)
    expected_gid = normalize_decimal(expected_gid)
    if expected_depot and metadata.depot ~= expected_depot then return nil, "depot mismatch" end
    if expected_gid and metadata.gid ~= expected_gid then return nil, "gid mismatch" end
    return metadata
end

function smart_merge.select_preferred(manifests, current_gids)
    local grouped, selected = {}, {}
    for _, item in ipairs(manifests or {}) do
        grouped[item.depot] = grouped[item.depot] or {}
        grouped[item.depot][#grouped[item.depot] + 1] = item
    end
    for depot, items in pairs(grouped) do
        local current, best = current_gids and current_gids[depot], nil
        for _, item in ipairs(items) do
            local exact = current and item.gid == current or false
            local best_exact = best and current and best.gid == current or false
            if not best or (exact ~= best_exact and exact)
                or (exact == best_exact and (item.creation_time or -1) > (best.creation_time or -1))
                or (exact == best_exact and (item.creation_time or -1) == (best.creation_time or -1)
                    and (item.priority or math.huge) < (best.priority or math.huge)) then
                best = item
            end
        end
        if best then selected[depot] = best.gid end
    end
    return selected
end

local function parent_path(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function source_root(path, collection_dir)
    local relative = path:sub(#collection_dir + 2)
    local first = relative:match("^([^/]+)")
    if first and first:match("^source_%d+$") then return collection_dir .. "/" .. first end
end

local function default_options(opts)
    opts = opts or {}
    opts.read_file = opts.read_file or function(path)
        local f = io.open(path, "rb"); if not f then return nil end
        local data = f:read("*a"); f:close(); return data
    end
    opts.write_file = opts.write_file or function(path, data)
        local f = io.open(path, "wb"); if not f then return false end
        local ok = f:write(data); f:close(); return ok and true or false
    end
    opts.exists = opts.exists or function(path) local f = io.open(path, "rb"); if f then f:close(); return true end return false end
    opts.mkdir = opts.mkdir or function(path) return os.execute('mkdir -p "' .. path .. '"') == 0 end
    opts.rename = opts.rename or os.rename
    opts.remove = opts.remove or os.remove
    return opts
end

function smart_merge.install(appid, collection_dir, supplied_opts)
    appid = positive_integer(appid)
    if not appid then return nil, "invalid appid" end
    local opts = default_options(supplied_opts)
    if type(opts.list_recursive) ~= "function" then return nil, "list_recursive unavailable" end
    local current_gids = smart_merge.parse_appinfo_gids(opts.appinfo_text or "")
    local by_root, manifest_by_name = {}, {}

    -- Collect paths first. Directory enumeration order is not stable across
    -- filesystems, so source metadata must be known before parsing manifests.
    for _, entry in ipairs(opts.list_recursive(collection_dir) or {}) do
        if not entry.is_directory then
            local root = source_root(entry.path, collection_dir)
            if root then
                local source = by_root[root]
                if not source then
                    source = { root = root, index = tonumber(root:match("source_(%d+)$")) or math.huge,
                        priority = math.huge, name = root:match("([^/]+)$"), exact_current = {},
                        manifests = {}, entries = {} }
                    by_root[root] = source
                end
                source.entries[#source.entries + 1] = entry
            end
        end
    end

    for _, source in pairs(by_root) do
        for _, entry in ipairs(source.entries) do
            if entry.name == ".source-name" then
                source.name = opts.read_file(entry.path) or source.name
            elseif entry.name == ".source-priority" then
                source.priority = tonumber(opts.read_file(entry.path)) or source.priority
            end
        end
        for _, entry in ipairs(source.entries) do
            if entry.name == tostring(appid) .. ".lua" then
                source.lua_text = opts.read_file(entry.path)
            else
                local depot_text, gid = entry.name:match("^(%d+)_(%d+)%.manifest$")
                local depot = positive_integer(depot_text); gid = normalize_decimal(gid)
                if depot and gid then
                    local content = opts.read_file(entry.path)
                    local metadata = content and smart_merge.parse_manifest(content, depot, gid) or nil
                    if metadata then
                        local item = { depot = depot, gid = gid, creation_time = metadata.creation_time,
                            priority = source.priority, source_index = source.index,
                            source_name = source.name, content = content }
                        source.manifests[#source.manifests + 1] = item
                        if current_gids[depot] == gid then source.exact_current[depot] = true end
                        local key = tostring(depot) .. "_" .. gid
                        local previous = manifest_by_name[key]
                        if not previous or item.priority < previous.priority
                            or (item.priority == previous.priority
                                and item.source_index < previous.source_index) then
                            manifest_by_name[key] = item
                        end
                    end
                end
            end
        end
        source.entries = nil
    end

    local sources, manifests = {}, {}
    local has_app_declaration, keyed_count = false, 0
    for _, source in pairs(by_root) do
        if source.lua_text then
            local parsed = smart_merge.parse_lua(source.lua_text)
            local recognized = next(parsed.bare) ~= nil or next(parsed.keys) ~= nil
                or next(parsed.manifests) ~= nil
            if recognized then
                source.parsed = parsed
                sources[#sources + 1] = source
                if parsed.bare[appid] or parsed.keys[appid] then has_app_declaration = true end
                for _ in pairs(parsed.keys) do keyed_count = keyed_count + 1 end
            end
        end
    end
    if #sources == 0 then return nil, "No usable game Lua was collected" end
    if not has_app_declaration then return nil, "Collected Lua does not declare the requested app" end
    if keyed_count == 0 then return nil, "Collected Lua contains no depot keys" end
    table.sort(sources, function(a, b) return a.index < b.index end)
    for _, item in pairs(manifest_by_name) do manifests[#manifests + 1] = item end
    local result, merge_error = smart_merge.merge_sources(appid, sources, current_gids)
    if not result then return nil, merge_error end

    local lua_text = smart_merge.emit_lua(appid, result)
    local preferred = smart_merge.select_preferred(manifests, current_gids)

    local home = opts.home or os.getenv("HOME") or ""
    local steam_root = opts.steam_root or ""
    if home == "" or steam_root == "" then return nil, "install paths unavailable" end
    local store_dir = home .. "/.config/SLSsteam/manifests"
    local target = steam_root .. "/config/stplug-in/" .. tostring(appid) .. ".lua"
    opts.mkdir(store_dir); opts.mkdir(parent_path(target))

    local publications = {}
    table.sort(manifests, function(a, b) if a.depot ~= b.depot then return a.depot < b.depot end return a.gid < b.gid end)
    for _, item in ipairs(manifests) do
        publications[#publications + 1] = { path = store_dir .. "/" .. item.depot .. "_" .. item.gid .. ".manifest", content = item.content }
    end
    for _, depot in ipairs(sorted_numeric_keys(preferred)) do
        publications[#publications + 1] = { path = store_dir .. "/.preferred_" .. depot, content = preferred[depot] .. "\n" }
    end
    publications[#publications + 1] = { path = target, content = lua_text }

    local nonce = tostring(os.time()) .. "." .. tostring(math.random(100000, 999999))
    local staged, snapshots = {}, {}
    for index, publication in ipairs(publications) do
        local temp = publication.path .. ".tmp.luatools." .. nonce .. "." .. index
        opts.remove(temp)
        if not opts.write_file(temp, publication.content) or opts.read_file(temp) ~= publication.content then
            for _, path in ipairs(staged) do opts.remove(path) end
            return nil, "failed to stage " .. publication.path
        end
        staged[#staged + 1] = temp
        snapshots[index] = { existed = opts.exists(publication.path), content = opts.read_file(publication.path) }
    end

    for index, publication in ipairs(publications) do
        if not opts.rename(staged[index], publication.path) then
            for _, path in ipairs(staged) do opts.remove(path) end
            for restore_index, prior in ipairs(snapshots) do
                local path = publications[restore_index].path
                if prior.existed then opts.write_file(path, prior.content) else opts.remove(path) end
            end
            return nil, "failed to publish " .. publication.path
        end
    end
    result.installed_path = target
    result.preferred = preferred
    result.manifest_count = #manifests
    return result
end

return smart_merge