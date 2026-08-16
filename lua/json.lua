-- Minimal JSON encode/decode for scripted tools.
-- Used when the host has not installed wizard.json_encode / wizard.json_decode,
-- and as a reference implementation the Zig host mirrors.

local json = {}

local function is_array(t)
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        if k > n then
            n = k
        end
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return true
end

local function encode_string(s)
    local out = { '"' }
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == '"' then
            out[#out + 1] = '\\"'
        elseif c == '\\' then
            out[#out + 1] = '\\\\'
        elseif c == '\n' then
            out[#out + 1] = '\\n'
        elseif c == '\r' then
            out[#out + 1] = '\\r'
        elseif c == '\t' then
            out[#out + 1] = '\\t'
        else
            out[#out + 1] = c
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

function json.encode(v)
    local tv = type(v)
    if tv == "nil" then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        return tostring(v)
    elseif tv == "string" then
        return encode_string(v)
    elseif tv == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do
                parts[i] = json.encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. json.encode(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function skip_ws(s, i)
    while i <= #s and s:sub(i, i):match("%s") do
        i = i + 1
    end
    return i
end

local function parse_string(s, i)
    i = i + 1
    local out = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == '\\' then
            local n = s:sub(i + 1, i + 1)
            if n == 'n' then
                out[#out + 1] = '\n'
            elseif n == 'r' then
                out[#out + 1] = '\r'
            elseif n == 't' then
                out[#out + 1] = '\t'
            else
                out[#out + 1] = n
            end
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    error("unterminated string")
end

local parse_value

local function parse_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == '}' then
        return obj, i + 1
    end
    while true do
        i = skip_ws(s, i)
        if s:sub(i, i) ~= '"' then
            error("expected string key")
        end
        local key
        key, i = parse_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then
            error("expected ':'")
        end
        local val
        val, i = parse_value(s, i + 1)
        obj[key] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == '}' then
            return obj, i + 1
        elseif c ~= ',' then
            error("expected ',' or '}'")
        end
        i = i + 1
    end
end

local function parse_array(s, i)
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == ']' then
        return arr, i + 1
    end
    while true do
        local val
        val, i = parse_value(s, i)
        arr[#arr + 1] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ']' then
            return arr, i + 1
        elseif c ~= ',' then
            error("expected ',' or ']'")
        end
        i = i + 1
    end
end

parse_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return parse_string(s, i)
    elseif c == '{' then
        return parse_object(s, i)
    elseif c == '[' then
        return parse_array(s, i)
    elseif c == 't' and s:sub(i, i + 3) == 'true' then
        return true, i + 4
    elseif c == 'f' and s:sub(i, i + 4) == 'false' then
        return false, i + 5
    elseif c == 'n' and s:sub(i, i + 3) == 'null' then
        return nil, i + 4
    else
        local j = i
        while j <= #s and s:sub(j, j):match("[0-9eE+%.%-]") do
            j = j + 1
        end
        return tonumber(s:sub(i, j - 1)), j
    end
end

function json.decode(s)
    local v, i = parse_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then
        error("trailing junk at " .. i)
    end
    return v
end

return json
