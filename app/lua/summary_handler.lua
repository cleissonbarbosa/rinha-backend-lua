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
    -- Fast aggregation using per-second buckets stored in Redis hashes
    local from_timestamp = utils.iso_to_epoch(from_time)
    local to_timestamp = utils.iso_to_epoch(to_time)

    if from_timestamp and to_timestamp then
        if to_timestamp < from_timestamp then
            -- Invalid window, return zeros
        else
            -- Iterate per-second buckets to avoid per-payment scans (bounded loop ~seconds range)
            local start_sec = math.floor(from_timestamp)
            local end_sec = math.floor(to_timestamp)

            -- Pipeline HMGETs to reduce RTTs
            red:init_pipeline()
            local keys = {}
            for sec = start_sec, end_sec do
                local key = "stats_sec:" .. sec
                table.insert(keys, key)
                red:hmget(key, "default_requests", "default_amount", "fallback_requests", "fallback_amount")
            end
            local results, perr = red:commit_pipeline()
            if results then
                for _, vals in ipairs(results) do
                    if vals and vals ~= ngx.null then
                        local dreq = tonumber(vals[1]) or 0
                        local damt = tonumber(vals[2]) or 0
                        local freq = tonumber(vals[3]) or 0
                        local famt = tonumber(vals[4]) or 0
                        default_requests = default_requests + dreq
                        default_amount = default_amount + damt
                        fallback_requests = fallback_requests + freq
                        fallback_amount = fallback_amount + famt
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
