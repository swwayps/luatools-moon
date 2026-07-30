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
    local maximum = "18446744073709551615"
    if #text > #maximum or (#text == #maximum and text > maximum) then return nil end
    return text
end

local function lua_long_open(line, pos)
    local equals = line:sub(pos):match("^%[(=*)%[")
    if equals == nil then return nil end
    return "]" .. equals .. "]", #equals + 2
end

local function strip_non_code(line, long_close)
    local out, pos = {}, 1
    while pos <= #line do
        if long_close then
            local first, last = line:find(long_close, pos, true)
            if not first then return table.concat(out), long_close end
            out[#out + 1] = " "
            pos, long_close = last + 1, nil
        else
            local ch = line:sub(pos, pos)
            if ch == '"' or ch == "'" then
                local quote, escaped = ch, false
                out[#out + 1] = ch
                pos = pos + 1
                while pos <= #line do
                    ch = line:sub(pos, pos)
                    out[#out + 1] = ch
                    pos = pos + 1
                    if escaped then escaped = false
                    elseif ch == "\\" then escaped = true
                    elseif ch == quote then break end
                end
            elseif line:sub(pos, pos + 1) == "--" then
                local close, width = lua_long_open(line, pos + 2)
                if not close then break end
                out[#out + 1] = " "
                long_close, pos = close, pos + 2 + width
            else
                local close, width = lua_long_open(line, pos)
                if close then
                    out[#out + 1] = " "
                    long_close, pos = close, pos + width
                else
                    out[#out + 1] = ch
                    pos = pos + 1
                end
            end
        end
    end
    return table.concat(out), long_close
end

function smart_merge.parse_lua(text)
    local parsed = { bare = {}, keys = {}, manifests = {} }
    local normalized = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local long_close = nil
    for raw in (normalized .. "\n"):gmatch("([^\n]*)\n") do
        local cleaned
        cleaned, long_close = strip_non_code(raw, long_close)
        local line = cleaned:match("^%s*(.-)%s*$")
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

local function parse_appinfo_body(text)
    local tokens = lex_vdf(tostring(text or ""))
    local root, pos = {}, 1
    while pos <= #tokens do
        local key = tokens[pos]; pos = pos + 1
        if tokens[pos] == "{" then root[key], pos = parse_vdf_map(tokens, pos + 1)
        else pos = pos + 1 end
    end
    return root.appinfo or root
end

local function depot_is_relevant(oslist)
    oslist = tostring(oslist or ""):lower()
    if oslist == "" then return true end
    for item in oslist:gmatch("[^,%s]+") do
        if item == "linux" or item == "windows" or item == "win" then return true end
    end
    return false
end

function smart_merge.parse_appinfo_depots(text)
    local body = parse_appinfo_body(text)
    local result = {}
    for depot, node in pairs(type(body.depots) == "table" and body.depots or {}) do
        local id = positive_integer(depot)
        local public = type(node) == "table" and type(node.manifests) == "table"
            and node.manifests.public or nil
        local gid = type(public) == "table" and normalize_decimal(public.gid) or nil
        local dlcappid = type(node) == "table" and positive_integer(node.dlcappid) or nil
        if id then
            local kind = gid and (dlcappid and "dlc" or "base")
                or (dlcappid and "virtual_dlc" or "unknown")
            local config = type(node) == "table" and node.config or nil
            local oslist = type(config) == "table" and tostring(config.oslist or "") or ""
            result[id] = {
                id = id, gid = gid, dlcappid = dlcappid, kind = kind,
                oslist = oslist,
                relevant = kind == "virtual_dlc" or depot_is_relevant(oslist),
            }
        end
    end
    return result
end

function smart_merge.parse_appinfo_dlc_appids(text)
    local body = parse_appinfo_body(text)
    local result = {}
    for _, info in pairs(smart_merge.parse_appinfo_depots(text)) do
        if info.dlcappid then result[info.dlcappid] = true end
    end
    local extended = type(body.extended) == "table" and body.extended or {}
    for value in tostring(extended.listofdlc or ""):gmatch("%d+") do
        local id = positive_integer(value)
        if id then result[id] = true end
    end
    return result
end

function smart_merge.parse_appinfo_gids(text)
    local result = {}
    for depot, info in pairs(smart_merge.parse_appinfo_depots(text)) do
        if info.gid then result[depot] = info.gid end
    end
    return result
end

function smart_merge.evaluate_sources(appid, sources, appinfo_text)
    appid = positive_integer(appid)
    if not appid then return nil, "invalid appid" end

    local prepared, has_app_declaration = {}, false
    for _, source in ipairs(sources or {}) do
        local parsed = source.parsed or smart_merge.parse_lua(source.lua_text)
        if next(parsed.bare) ~= nil or next(parsed.keys) ~= nil
            or next(parsed.manifests) ~= nil then
            local item = {}
            for key, value in pairs(source) do item[key] = value end
            item.parsed = parsed
            prepared[#prepared + 1] = item
            if parsed.bare[appid] or parsed.keys[appid] then
                has_app_declaration = true
            end
        end
    end

    local depots = smart_merge.parse_appinfo_depots(appinfo_text or "")
    local current_gids = {}
    local known_base_count = 0
    for depot, info in pairs(depots) do
        if info.gid then current_gids[depot] = info.gid end
        if info.kind == "base" then known_base_count = known_base_count + 1 end
    end
    local merged = smart_merge.merge_sources(appid, prepared, current_gids)
    local base_key_count, dlc_key_count, other_key_count = 0, 0, 0
    for depot in pairs(merged.keys or {}) do
        local info = depots[depot]
        if info and info.kind == "base" and info.relevant then
            base_key_count = base_key_count + 1
        elseif info and info.kind == "dlc" then
            dlc_key_count = dlc_key_count + 1
        else
            other_key_count = other_key_count + 1
        end
    end

    local has_fallback_key = next(merged.keys or {}) ~= nil
    local usable = has_app_declaration and
        ((known_base_count > 0 and base_key_count > 0)
          or (known_base_count == 0 and has_fallback_key))
    local reason
    if #prepared == 0 then reason = "no_usable_game_lua"
    elseif not has_app_declaration then reason = "wrong_app"
    elseif not usable then reason = "no_usable_base_key" end

    return {
        usable = usable, reason = reason, result = merged, sources = prepared,
        depots = depots, current_gids = current_gids,
        base_key_count = base_key_count, dlc_key_count = dlc_key_count,
        other_key_count = other_key_count,
    }
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

function smart_merge.select_preferred_items(manifests, current_gids)
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
            local created = item.creation_time or -1
            local best_created = best and (best.creation_time or -1) or -1
            local same_time = best and created == best_created
            local same_exact = same_time and exact == best_exact
            local priority = item.priority or math.huge
            local best_priority = best and (best.priority or math.huge) or math.huge
            local source_index = item.source_index or math.huge
            local best_source_index = best and (best.source_index or math.huge) or math.huge
            local gid = tostring(item.gid or "")
            local best_gid = best and tostring(best.gid or "") or ""
            local gid_before = #gid ~= #best_gid and #gid < #best_gid or gid < best_gid
            if not best or created > best_created
                or (same_time and exact ~= best_exact and exact)
                or (same_exact and priority < best_priority)
                or (same_exact and priority == best_priority and source_index < best_source_index)
                or (same_exact and priority == best_priority and source_index == best_source_index
                    and gid_before) then
                best = item
            end
        end
        if best then selected[depot] = best end
    end
    return selected
end

function smart_merge.select_preferred(manifests, current_gids)
    local selected = {}
    for depot, item in pairs(smart_merge.select_preferred_items(manifests, current_gids)) do
        selected[depot] = item.gid
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

local JOURNAL_HEADER = "LUATOOLS-PUBLISH-1"

local function journal_path(opts)
    if opts.journal_path then return opts.journal_path end
    local home = opts.home or os.getenv("HOME") or ""
    if home == "" then return nil end
    return home .. "/.config/SLSsteam/.luatools-publish.journal"
end

local function encode_journal(publications, snapshots, staged)
    local out = { JOURNAL_HEADER, "\n", tostring(#publications), "\n" }
    for index, publication in ipairs(publications) do
        local prior = snapshots[index]
        local path = tostring(publication.path)
        local content = prior.existed and tostring(prior.content or "") or ""
        local temp = tostring(staged[index] or "")
        out[#out + 1] = table.concat({
            tostring(#path), prior.existed and "1" or "0",
            tostring(#content), tostring(#temp),
        }, ":") .. "\n"
        out[#out + 1] = path
        out[#out + 1] = content
        out[#out + 1] = temp
    end
    return table.concat(out)
end

local function decode_journal(raw)
    if type(raw) ~= "string" then return nil, "invalid recovery journal" end
    local pos = 1
    local function line()
        local last = raw:find("\n", pos, true)
        if not last then return nil end
        local value = raw:sub(pos, last - 1)
        pos = last + 1
        return value
    end
    if line() ~= JOURNAL_HEADER then return nil, "invalid recovery journal" end
    local count = tonumber(line() or "")
    if not count or count < 0 or count > 4096 or count ~= math.floor(count) then
        return nil, "invalid recovery journal"
    end
    local records = {}
    for _ = 1, count do
        local path_len, existed, content_len, staged_len = (line() or ""):match(
            "^(%d+):([01]):(%d+):(%d+)$")
        path_len, content_len, staged_len = tonumber(path_len), tonumber(content_len), tonumber(staged_len)
        if not path_len or not content_len or not staged_len
            or path_len < 1 or path_len + content_len + staged_len > #raw - pos + 1 then
            return nil, "invalid recovery journal"
        end
        local path = raw:sub(pos, pos + path_len - 1); pos = pos + path_len
        local content = raw:sub(pos, pos + content_len - 1); pos = pos + content_len
        local temp = raw:sub(pos, pos + staged_len - 1); pos = pos + staged_len
        records[#records + 1] = {
            path = path, existed = existed == "1", content = content, staged = temp,
        }
    end
    if pos ~= #raw + 1 then return nil, "invalid recovery journal" end
    return records
end

-- A publication is intentionally considered committed only after this journal
-- disappears. If the sidecar dies between destination renames, the next
-- preview/commit restores every original byte before doing any new work.
function smart_merge.recover_pending(supplied_opts)
    local opts = default_options(supplied_opts)
    local path = journal_path(opts)
    if not path or not opts.exists(path) then return true end
    local records, decode_error = decode_journal(opts.read_file(path))
    if not records then return nil, decode_error end
    for _, record in ipairs(records) do
        if record.existed then
            if not opts.write_file(record.path, record.content)
                or opts.read_file(record.path) ~= record.content then
                return nil, "failed to recover " .. record.path
            end
            if opts.protect_file and not opts.protect_file(record.path) then
                return nil, "failed to protect recovered " .. record.path
            end
        else
            opts.remove(record.path)
            if opts.exists(record.path) then return nil, "failed to recover " .. record.path end
        end
        if record.staged ~= "" then opts.remove(record.staged) end
    end
    opts.remove(path)
    if opts.exists(path) then
        return nil, "failed to clear recovery journal"
    end
    return true
end

function smart_merge.preview(appid, collection_dir, supplied_opts)
    appid = positive_integer(appid)
    if not appid then return nil, "invalid appid" end
    local opts = default_options(supplied_opts)
    local recovered, recovery_error = smart_merge.recover_pending(opts)
    if not recovered then return nil, recovery_error end
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

    local source_candidates, manifests = {}, {}
    for _, source in pairs(by_root) do
        if source.lua_text then
            source_candidates[#source_candidates + 1] = source
        end
    end
    local evaluation, evaluation_error = smart_merge.evaluate_sources(
        appid, source_candidates, opts.appinfo_text or "")
    if not evaluation then return nil, evaluation_error end
    if not evaluation.usable then return nil, evaluation.reason end
    local sources, result = evaluation.sources, evaluation.result
    table.sort(sources, function(a, b) return a.index < b.index end)
    for _, item in pairs(manifest_by_name) do manifests[#manifests + 1] = item end

    local lua_text = smart_merge.emit_lua(appid, result)
    local preferred_items = smart_merge.select_preferred_items(manifests, current_gids)
    local preferred = {}
    for depot, item in pairs(preferred_items) do preferred[depot] = item.gid end

    local dlc_set = smart_merge.parse_appinfo_dlc_appids(opts.appinfo_text or "")
    for _, id in ipairs(sorted_numeric_keys(result.bare)) do
        if id ~= appid then dlc_set[id] = true end
    end
    local dlc_appids = sorted_numeric_keys(dlc_set)
    local depot_ids, depot_seen = {}, {}
    for depot in pairs(result.keys or {}) do depot_seen[depot] = true end
    for _, item in ipairs(manifests) do depot_seen[item.depot] = true end
    for depot, info in pairs(evaluation.depots or {}) do
        if info.kind == "virtual_dlc" then depot_seen[depot] = true end
    end
    for depot in pairs(depot_seen) do depot_ids[#depot_ids + 1] = depot end
    table.sort(depot_ids)
    local depots = {}
    local base_depots, base_depot_set = {}, {}
    for depot, info in pairs(evaluation.depots or {}) do
        if info.kind == "base" and info.relevant then
            base_depots[#base_depots + 1] = depot
            base_depot_set[depot] = true
        end
    end
    table.sort(base_depots)
    for _, depot in ipairs(depot_ids) do
        local selected = preferred_items[depot]
        local gid = selected and selected.gid or nil
        local info = evaluation.depots[depot] or {}
        depots[#depots + 1] = {
            depot = depot,
            key = result.keys[depot] or "",
            gid = gid or "",
            has_manifest = gid ~= nil,
            base_depot = base_depot_set[depot] == true,
            kind = info.kind or "unknown",
            dlc_appid = info.dlcappid,
            requires_key = info.kind ~= "virtual_dlc",
            manifest_source = selected and selected.source_name or nil,
        }
    end

    result.appid = appid
    result.lua_text = lua_text
    result.dlc_appids = dlc_appids
    result.depots = depots
    result.base_depots = base_depots
    result.manifests = manifests
    result.preferred = preferred
    result.manifest_count = #manifests
    return result
end

function smart_merge.build_edited_lua(appid, edits, preview)
    appid = positive_integer(appid)
    if not appid then return nil, "invalid appid" end
    if edits == nil then return preview and preview.lua_text or nil end
    if type(edits) ~= "table" then return nil, "invalid draft" end

    local dlcs = {}
    for _, value in ipairs(type(edits.dlc_appids) == "table" and edits.dlc_appids or {}) do
        local id = positive_integer(value)
        if not id then return nil, "invalid DLC appid" end
        if id ~= appid then dlcs[id] = true end
    end

    local depots, key_count = {}, 0
    for _, row in ipairs(type(edits.depots) == "table" and edits.depots or {}) do
        if type(row) ~= "table" then return nil, "invalid depot row" end
        local depot = positive_integer(row.depot)
        if not depot then return nil, "invalid depot id" end
        if depots[depot] then return nil, "duplicate depot " .. tostring(depot) end
        local key = tostring(row.key or ""):match("^%s*(.-)%s*$"):lower()
        if key ~= "" and (#key ~= 64 or not key:match("^[0-9a-f]+$")) then
            return nil, "invalid key for depot " .. tostring(depot)
        end
        local raw_gid = tostring(row.gid or ""):match("^%s*(.-)%s*$")
        local gid = raw_gid ~= "" and normalize_decimal(raw_gid) or nil
        if raw_gid ~= "" and not gid then
            return nil, "invalid manifest gid for depot " .. tostring(depot)
        end
        if key ~= "" then key_count = key_count + 1 end
        depots[depot] = { key = key, gid = gid }
    end
    local base_depots = type(preview) == "table" and preview.base_depots or nil
    if type(base_depots) == "table" and #base_depots > 0 then
        local has_base_key = false
        for _, depot in ipairs(base_depots) do
            local row = depots[positive_integer(depot)]
            if row and row.key ~= "" then has_base_key = true; break end
        end
        if not has_base_key then return nil, "no_usable_base_key" end
    elseif key_count == 0 then
        return nil, "at least one depot key is required"
    end

    local lines = { "addappid(" .. tostring(appid) .. ")" }
    for _, id in ipairs(sorted_numeric_keys(dlcs)) do
        lines[#lines + 1] = "addappid(" .. tostring(id) .. ")"
    end
    for _, depot in ipairs(sorted_numeric_keys(depots)) do
        local row = depots[depot]
        if row.key ~= "" then
            lines[#lines + 1] = string.format('addappid(%d, 1, "%s")', depot, row.key)
        end
    end
    for _, depot in ipairs(sorted_numeric_keys(depots)) do
        local gid = depots[depot].gid
        if gid then lines[#lines + 1] = string.format('setManifestid(%d, "%s")', depot, gid) end
    end
    return table.concat(lines, "\n") .. "\n"
end

local function split_lines(text)
    local lines = {}
    text = tostring(text or "")
    local trailing = text:sub(-1) == "\n"
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if trailing then lines[#lines] = nil end
    return lines, trailing
end

local function join_lines(lines, trailing)
    local text = table.concat(lines, "\n")
    return trailing and (text .. "\n") or text
end

local function manifest_block_end(lines, header)
    local last = #lines
    for index = header + 1, #lines do
        if lines[index]:match("^%S") then last = index - 1; break end
    end
    return last
end

local function sync_manifest_pins(config, appid, lua_text)
    if type(config) ~= "string" or config == "" then return nil, "config.yaml not found" end
    local parsed = smart_merge.parse_lua(lua_text)
    local gids = parsed.manifests or {}
    local lines, trailing = split_lines(config)
    local header
    for index, line in ipairs(lines) do
        local after = line:match("^ManifestPins%s*:%s*(.-)%s*$")
        if after ~= nil then
            local code = after:gsub("#.*$", ""):match("^%s*(.-)%s*$")
            if code ~= "" then return nil, "ManifestPins has an inline value" end
            header = index; break
        end
    end

    local app_start, app_end
    if header then
        local block_end = manifest_block_end(lines, header)
        for index = header + 1, block_end do
            local id = lines[index]:match("^  (%d+)%s*:%s*$")
            if id and tonumber(id) == appid then
                app_start, app_end = index, block_end
                for cursor = index + 1, block_end do
                    if lines[cursor]:match("^  %S") then app_end = cursor - 1; break end
                end
                break
            end
        end
    end

    if app_start then
        for index = app_end, app_start, -1 do table.remove(lines, index) end
    end

    local depot_ids = sorted_numeric_keys(gids)
    if #depot_ids > 0 then
        if not header then
            if #lines > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
            lines[#lines + 1] = "ManifestPins:"
            header = #lines
        end
        local insert_at = manifest_block_end(lines, header) + 1
        local block = {
            "  " .. tostring(appid) .. ":",
            "    locked: true",
            "    depots:",
        }
        for _, depot in ipairs(depot_ids) do
            block[#block + 1] = string.format('      %d: "%s"', depot, gids[depot])
        end
        for offset, line in ipairs(block) do table.insert(lines, insert_at + offset - 1, line) end
    elseif header then
        local block_end = manifest_block_end(lines, header)
        local any_app = false
        for index = header + 1, block_end do
            if lines[index]:match("^  %d+%s*:%s*$") then any_app = true; break end
        end
        if not any_app then table.remove(lines, header) end
    end
    return join_lines(lines, trailing)
end

local function mark_import(text, appid)
    local ids = { [appid] = true }
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local id = positive_integer(line:match("^%s*(%d+)%s*$"))
        if id then ids[id] = true end
    end
    local lines = {}
    for _, id in ipairs(sorted_numeric_keys(ids)) do lines[#lines + 1] = tostring(id) end
    return table.concat(lines, "\n") .. "\n"
end

local function publish_preview(appid, preview, lua_text, supplied_opts)
    local opts = default_options(supplied_opts)
    local manifests = preview.manifests or {}
    local preferred = preview.preferred or {}

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
    if opts.sync_pins then
        local config_path = opts.config_path or (home .. "/.config/SLSsteam/config.yaml")
        local imports_path = opts.imports_path or (home .. "/.config/SLSsteam/lumen_lua_imports.txt")
        local config_text, config_error = sync_manifest_pins(
            opts.read_file(config_path), appid, lua_text)
        if not config_text then return nil, config_error end
        opts.mkdir(parent_path(config_path)); opts.mkdir(parent_path(imports_path))
        publications[#publications + 1] = { path = config_path, content = config_text }
        publications[#publications + 1] = {
            path = imports_path,
            content = mark_import(opts.read_file(imports_path), appid),
        }
    end

    local nonce = tostring(os.time()) .. "." .. tostring(math.random(100000, 999999))
    local staged, snapshots = {}, {}
    for index, publication in ipairs(publications) do
        local temp = publication.path .. ".tmp.luatools." .. nonce .. "." .. index
        opts.remove(temp)
        if not opts.write_file(temp, publication.content) or opts.read_file(temp) ~= publication.content then
            for _, path in ipairs(staged) do opts.remove(path) end
            return nil, "failed to stage " .. publication.path
        end
        if opts.protect_file and not opts.protect_file(temp) then
            opts.remove(temp)
            for _, path in ipairs(staged) do opts.remove(path) end
            return nil, "failed to protect " .. publication.path
        end
        staged[#staged + 1] = temp
        local existed = opts.exists(publication.path)
        local prior = existed and opts.read_file(publication.path) or nil
        if existed and prior == nil then
            for _, path in ipairs(staged) do opts.remove(path) end
            return nil, "failed to snapshot " .. publication.path
        end
        snapshots[index] = { existed = existed, content = prior }
    end

    local recovery_path = journal_path(opts)
    if not recovery_path then
        for _, path in ipairs(staged) do opts.remove(path) end
        return nil, "recovery path unavailable"
    end
    opts.mkdir(parent_path(recovery_path))
    local journal_temp = recovery_path .. ".tmp." .. nonce
    local journal = encode_journal(publications, snapshots, staged)
    opts.remove(journal_temp)
    if not opts.write_file(journal_temp, journal) or opts.read_file(journal_temp) ~= journal
        or (opts.protect_file and not opts.protect_file(journal_temp))
        or not opts.rename(journal_temp, recovery_path) then
        opts.remove(journal_temp)
        for _, path in ipairs(staged) do opts.remove(path) end
        return nil, "failed to create recovery journal"
    end

    for index, publication in ipairs(publications) do
        if not opts.rename(staged[index], publication.path) then
            local recovered, recovery_error = smart_merge.recover_pending(opts)
            if not recovered then return nil, recovery_error end
            return nil, "failed to publish " .. publication.path
        end
    end
    opts.remove(recovery_path)
    if opts.exists(recovery_path) then
        local recovered, recovery_error = smart_merge.recover_pending(opts)
        if not recovered then return nil, recovery_error end
        return nil, "failed to finalize publication"
    end
    preview.lua_text = lua_text
    preview.installed_path = target
    preview.preferred = preferred
    preview.manifest_count = #manifests
    preview.pins_synced = opts.sync_pins == true
    return preview
end

function smart_merge.commit(appid, collection_dir, edits, supplied_opts)
    local preview, err = smart_merge.preview(appid, collection_dir, supplied_opts)
    if not preview then return nil, err end
    local lua_text, lua_error = smart_merge.build_edited_lua(appid, edits, preview)
    if not lua_text then return nil, lua_error end
    return publish_preview(appid, preview, lua_text, supplied_opts)
end

function smart_merge.install(appid, collection_dir, supplied_opts)
    return smart_merge.commit(appid, collection_dir, nil, supplied_opts)
end

return smart_merge
