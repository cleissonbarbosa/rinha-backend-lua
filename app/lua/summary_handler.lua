local cjson = require "cjson"
local redis = require "resty.redis"
local utils = require "utils"

-- Get Redis connection
local function get_redis()
    local red = redis:new()
    red:set_timeouts(1000, 1000, 1000)
    
    local ok, err = red:connect(_G.config.redis.host, _G.config.redis.port)
    if not ok then
        return nil, err
    end
    
    return red
end

-- Get query parameters
local args = ngx.req.get_uri_args()
local from_time = args["from"]
local to_time = args["to"]

-- Get statistics from Redis
local red, err = get_redis()
if not red then
    ngx.log(ngx.ERR, "Failed to connect to Redis: " .. (err or "unknown"))
    ngx.status = 500
    ngx.say(cjson.encode({error = "Internal server error"}))
    return
end

local default_requests = 0
local default_amount = 0
local fallback_requests = 0
local fallback_amount = 0

-- If no time filter, use total counters for performance
if not from_time or not to_time then
    default_requests = tonumber(red:get("stats:default_total_requests")) or 0
    default_amount = tonumber(red:get("stats:default_total_amount")) or 0
    fallback_requests = tonumber(red:get("stats:fallback_total_requests")) or 0
    fallback_amount = tonumber(red:get("stats:fallback_total_amount")) or 0
else
    -- Convert ISO timestamps to Unix timestamps
    local function iso_to_timestamp(iso_string)
        if not iso_string then return nil end
        
        -- Parse ISO format: 2025-08-14T22:26:44.033Z
        local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
        local year, month, day, hour, min, sec = iso_string:match(pattern)
        if not year then return nil end
        
        -- Use os.time and adjust for UTC (simplified)
        local utc_time = os.time({
            year = tonumber(year),
            month = tonumber(month), 
            day = tonumber(day),
            hour = tonumber(hour),
            min = tonumber(min),
            sec = tonumber(sec)
        })
        
        -- Adjust for timezone - get current offset
        local now = os.time()
        local utc_now = os.time(os.date("!*t", now))
        local local_now = os.time(os.date("*t", now))
        local offset = local_now - utc_now
        
        return utc_time - offset
    end
    
    local from_timestamp = iso_to_timestamp(from_time)
    local to_timestamp = iso_to_timestamp(to_time)
    
    if from_timestamp and to_timestamp then
        -- Query payments within time range
        local payment_ids = red:zrangebyscore("payments_by_time", from_timestamp, to_timestamp)
        
        if payment_ids and #payment_ids > 0 then
            for _, payment_id in ipairs(payment_ids) do
                local payment_data = red:get("payment:" .. payment_id)
                if payment_data then
                    local ok, payment = pcall(cjson.decode, payment_data)
                    if ok then
                        if payment.processor == "default" then
                            default_requests = default_requests + 1
                            default_amount = default_amount + payment.amount
                        elseif payment.processor == "fallback" then
                            fallback_requests = fallback_requests + 1
                            fallback_amount = fallback_amount + payment.amount
                        end
                    end
                end
            end
        end
    else
        -- Fallback to total counters if timestamp parsing fails
        default_requests = tonumber(red:get("stats:default_total_requests")) or 0
        default_amount = tonumber(red:get("stats:default_total_amount")) or 0
        fallback_requests = tonumber(red:get("stats:fallback_total_requests")) or 0
        fallback_amount = tonumber(red:get("stats:fallback_total_amount")) or 0
    end
end

red:set_keepalive(10000, 50)

-- Build response
local response = {
    default = {
        totalRequests = default_requests,
        totalAmount = default_amount
    },
    fallback = {
        totalRequests = fallback_requests,
        totalAmount = fallback_amount
    }
}

ngx.header.content_type = "application/json"
ngx.say(cjson.encode(response))
