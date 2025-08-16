local cjson = require "cjson"
local redis = require "resty.redis"
local http = require "simple_http"
local utils = require "utils"
local health_monitor = require "health_monitor"

local _M = {}

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

-- Process payment with specific processor using HTTP library
local function process_with_processor(payment_data, processor_type)
    local processor = _G.config.payment_processors[processor_type]

    -- Prepare the JSON payload
    local payload = cjson.encode({
        correlationId = payment_data.correlationId,
        amount = payment_data.amount,
        requestedAt = payment_data.requestedAt
    })

    -- Make HTTP request
    -- Use TCP client (allowed in timer context)
    local res, err = http.request_uri(processor.url .. "/payments", {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json"
        },
        body = payload
    })
    if not res or res.status ~= 200 then
        return false, "HTTP " .. (res and res.status or 0) .. " from " .. processor_type
    end

    -- Update statistics in Redis with timestamp
    local red, err = get_redis()
    if red then
        -- Prefer requestedAt (what PP likely uses to account windows); fallback to now
        local ts_ms = nil
        if payment_data.requestedAt then
            ts_ms = utils.iso_to_epoch_ms(payment_data.requestedAt)
        end
        local now_sec = ngx.now() or os.time()
        if not ts_ms then
            ts_ms = math.floor(now_sec * 1000)
        end
        local timestamp = math.floor(ts_ms / 1000)

        local payment_key = "payment:" .. payment_data.correlationId

        -- Store and aggregate using a single pipeline to reduce Redis RTTs
        red:init_pipeline()

        -- Store payment details with timestamp
        local payment_record = cjson.encode({
            correlationId = payment_data.correlationId,
            amount = payment_data.amount,
            processor = processor_type,
            timestamp = timestamp,
            requestedAt = payment_data.requestedAt
        })
        red:setex(payment_key, 3600, payment_record) -- TTL 1 hour

        -- Add to a sorted set for time-based diagnostics (kept for compatibility)
        red:zadd("payments_by_time", timestamp, payment_data.correlationId)
        -- Millisecond-precision timeline for accurate window queries (based on requestedAt)
        -- Store enriched member to eliminate subsequent GETs during summary aggregation
        local z_member_ms = tostring(payment_data.correlationId) .. "|" .. tostring(processor_type) .. "|" ..
                                tostring(payment_data.amount)
        red:zadd("payments_by_time_ms", ts_ms, z_member_ms)

        -- Update total counters
        local key_requests = "stats:" .. processor_type .. "_total_requests"
        local key_amount = "stats:" .. processor_type .. "_total_amount"
        red:incr(key_requests)
        red:incrbyfloat(key_amount, payment_data.amount)

        -- Update per-second aggregation bucket for faster /payments-summary queries
        local bucket = "stats_sec:" .. tostring(timestamp)
        if processor_type == "default" then
            red:hincrby(bucket, "default_requests", 1)
            red:hincrbyfloat(bucket, "default_amount", payment_data.amount)
        else
            red:hincrby(bucket, "fallback_requests", 1)
            red:hincrbyfloat(bucket, "fallback_amount", payment_data.amount)
        end
        -- Optionally expire buckets after 2 hours to limit memory
        red:expire(bucket, 2 * 60 * 60)

        red:commit_pipeline()
        red:set_keepalive(10000, 50)
    end

    return true, nil
end

-- Process a single payment with failover logic
local function process_payment(payment_data)
    local health_cache = ngx.shared.health_cache

    -- Check which processor to use first
    local default_healthy = health_cache:get("default_healthy")
    local fallback_healthy = health_cache:get("fallback_healthy")

    local processors_to_try = {}

    -- Prioritize default processor if healthy (lower fees)
    if default_healthy then
        table.insert(processors_to_try, "default")
    end

    if fallback_healthy then
        table.insert(processors_to_try, "fallback")
    end

    -- If both are unhealthy, still try both in order
    if #processors_to_try == 0 then
        processors_to_try = {"default", "fallback"}
    end

    -- Try processors in order
    for _, processor_type in ipairs(processors_to_try) do
        local success, err = process_with_processor(payment_data, processor_type)
        if success then
            return true, processor_type
        end

        ngx.log(ngx.ERR, "Payment processing failed with " .. processor_type .. ": " .. (err or "unknown"))

        -- Mark processor as unhealthy on failure
        health_cache:set(processor_type .. "_healthy", false, 30)
    end

    return false, "All processors failed"
end

-- Worker function to process queued payments
function _M.start_worker()
    if ngx.worker.id() ~= 0 then
        return -- Only run spawner on worker 0
    end

    local function loop_worker(premature)
        if premature then
            return
        end

        -- Get one Redis connection for this blocking pop
        local red, err = get_redis()
        if not red then
            ngx.log(ngx.ERR, "Worker: Redis connect failed: " .. (err or "unknown"))
            ngx.timer.at(0.5, loop_worker)
            return
        end

        -- Use long read timeout for blocking pop to avoid 1s timeouts
        if red.set_timeouts then
            red:set_timeouts(1000, 1000, 65000)
        end
        -- Block until there is an item; 0 means block indefinitely in Redis lib
        local res, err = red:blpop(_G.config.queue.name, 0)
        red:set_keepalive(10000, 100)

        if res and res ~= ngx.null then
            local payment_json = res[2]
            local ok, payment_data = pcall(cjson.decode, payment_json)
            if ok and type(payment_data) == "table" then
                local success, result = process_payment(payment_data)
                if not success then
                    local retry_count = (payment_data.retry_count or 0) + 1
                    if retry_count <= _G.config.queue.max_retries then
                        payment_data.retry_count = retry_count
                        local red2 = get_redis()
                        if red2 then
                            red2:rpush(_G.config.queue.name, cjson.encode(payment_data))
                            red2:set_keepalive(10000, 100)
                        end
                        ngx.log(ngx.WARN,
                            "Payment retry " .. retry_count .. " for " .. tostring(payment_data.correlationId))
                    else
                        ngx.log(ngx.ERR,
                            "Payment failed permanently: " .. tostring(payment_data.correlationId) .. " - " ..
                                tostring(result))
                    end
                end
            else
                ngx.log(ngx.ERR, "Worker: decode failed: " .. tostring(payment_json))
            end
        elseif err then
            if tostring(err) ~= "timeout" then
                ngx.log(ngx.ERR, "BLPOP error: " .. tostring(err))
            end
        end

        -- Immediately schedule next blocking wait
        local ok, terr = ngx.timer.at(0, loop_worker)
        if not ok then
            ngx.log(ngx.ERR, "Failed to reschedule worker: " .. tostring(terr))
        end
    end

    -- Spawn N concurrent workers
    local n = _G.config.queue.concurrency or 16
    for i = 1, n do
        local ok, err = ngx.timer.at(0, loop_worker)
        if not ok then
            ngx.log(ngx.ERR, "Failed to start worker #" .. i .. ": " .. tostring(err))
        end
    end
end

return _M
