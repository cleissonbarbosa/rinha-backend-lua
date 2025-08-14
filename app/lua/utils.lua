local _M = {}

-- Validate UUID format
function _M.is_valid_uuid(str)
    if type(str) ~= "string" then
        return false
    end
    
    local pattern = "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$"
    return string.match(str, pattern) ~= nil
end

-- Get current timestamp in ISO format
function _M.get_iso_timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
end

-- Convert timestamp to epoch for comparison
function _M.iso_to_epoch(iso_string)
    if not iso_string then
        return nil
    end
    
    local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
    local year, month, day, hour, min, sec = iso_string:match(pattern)
    if not year then
        return nil
    end
    
    -- Use os.time with UTC calculation
    -- os.time assumes local time, so we need to adjust for UTC
    local local_time = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec)
    })
    
    -- Get timezone offset to convert to UTC
    local now = os.time()
    local utc_time = os.time(os.date("!*t", now))
    local local_time_check = os.time(os.date("*t", now))
    local offset = local_time_check - utc_time
    
    return local_time - offset
end

return _M
