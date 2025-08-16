local cjson = require "cjson"
local redis = require "resty.redis"

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

-- Clear all payment data
local function purge_all_data()
    local red, err = get_redis()

    if not red then
        ngx.log(ngx.ERR, "Failed to connect to Redis: " .. (err or "unknown"))
        return false, "Redis connection failed"
    end

    -- Clear Redis queue
    red:del(_G.config.queue.name)

    -- Clear statistics in Redis
    red:del("stats:default_total_requests")
    red:del("stats:default_total_amount")
    red:del("stats:fallback_total_requests")
    red:del("stats:fallback_total_amount")

    -- Clear payments sorted set
    red:del("payments_by_time")
    red:del("payments_by_time_ms")

    -- Clear per-second aggregation buckets
    local sec_keys = red:keys("stats_sec:*")
    if sec_keys and #sec_keys > 0 then
        for i = 1, #sec_keys do
            red:del(sec_keys[i])
        end
    end

    -- Clear any payment-related keys in Redis
    local keys = red:keys("payment:*")
    if keys and #keys > 0 then
        -- Delete keys in batches to avoid "too many results to unpack" error
        for i = 1, #keys do
            red:del(keys[i])
        end
    end

    red:set_keepalive(10000, 50)

    return true, nil
end

-- Execute purge
local success, err = purge_all_data()

if not success then
    ngx.status = 500
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        error = "Failed to purge payments",
        details = err
    }))
    return
end

-- Return success response
ngx.status = 200
ngx.header.content_type = "application/json"
ngx.say(cjson.encode({
    message = "All payments purged successfully"
}))
