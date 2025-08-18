local _M = {}

-- Fast UUID v4-ish validation without heavy regex
local function is_hex_digit(c)
    local b = string.byte(c)
    -- '0'-'9' or 'a'-'f' or 'A'-'F'
    return (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70)
end

function _M.is_valid_uuid(str)
    if type(str) ~= "string" or #str ~= 36 then
        return false
    end
    -- check dash positions
    if str:byte(9) ~= 45 or str:byte(14) ~= 45 or str:byte(19) ~= 45 or str:byte(24) ~= 45 then
        return false
    end
    -- check hex characters
    for i = 1, 36 do
        if i == 9 or i == 14 or i == 19 or i == 24 then
            -- '-'
        else
            if not is_hex_digit(str:sub(i, i)) then
                return false
            end
        end
    end
    return true
end

-- Get current timestamp in ISO format
function _M.get_iso_timestamp()
    -- Use high-resolution time to include real milliseconds
    local now = ngx.now and ngx.now() or (os.time())
    local sec = math.floor(now)
    local ms = math.floor((now - sec) * 1000)
    if ms < 0 then
        ms = 0
    end
    if ms > 999 then
        ms = 999
    end
    return os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", ms)
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

-- Convert ISO timestamp (with optional milliseconds) to epoch milliseconds (integer)
function _M.iso_to_epoch_ms(iso_string)
    if not iso_string or type(iso_string) ~= "string" then
        return nil
    end

    -- Capture milliseconds if present (e.g., 2025-07-15T12:34:56.123Z)
    local y, M, d, h, m, s, ms = iso_string:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)Z$")
    if not y then
        -- Try without trailing Z (robustness)
        y, M, d, h, m, s, ms = iso_string:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)$")
    end
    if not y then
        return nil
    end

    local base_sec = os.time({
        year = tonumber(y),
        month = tonumber(M),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(m),
        sec = tonumber(s)
    })

    -- Compute local timezone offset to get UTC epoch
    local now = os.time()
    local utc_now = os.time(os.date("!*t", now))
    local local_now = os.time(os.date("*t", now))
    local offset = local_now - utc_now

    local ms_num = 0
    if ms and #ms > 0 then
        -- Normalize to 3 digits
        if #ms == 1 then
            ms_num = tonumber(ms) * 100
        elseif #ms == 2 then
            ms_num = tonumber(ms) * 10
        else
            ms_num = tonumber(ms:sub(1, 3))
        end
    end

    local epoch_sec_utc = base_sec - offset
    return epoch_sec_utc * 1000 + ms_num
end

return _M
