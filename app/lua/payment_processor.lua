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
    -- IMPORTANT: set a stable processing-time per payment as close as possible to the POST moment
    if not payment_data.processingRequestedAt then
        payment_data.processingRequestedAt = utils.get_iso_timestamp()
    end
    local processing_iso = payment_data.processingRequestedAt
    local payload = cjson.encode({
        correlationId = payment_data.correlationId,
        amount = payment_data.amount,
        requestedAt = processing_iso
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
    if not res then
        return false, "HTTP 0 from " .. processor_type
    end

    -- Successful processing
    if res.status == 200 then
        -- Use the stable processing_iso already set; no extra calls to PP
    elseif res.status == 409 then
        -- Duplicate correlationId: previously processed. Align with PP's authoritative requestedAt
        local details_res = http.request_uri(processor.url .. "/payments/" .. payment_data.correlationId, {
            method = "GET",
            headers = {
                ["Content-Type"] = "application/json"
            }
        })
        if not details_res or details_res.status ~= 200 then
            return false, "HTTP " .. (details_res and details_res.status or 0) .. " on details from " .. processor_type
        end
        local okd, data = pcall(cjson.decode, details_res.body or "")
        if not okd or not data or not data.requestedAt then
            return false, "invalid details payload from " .. processor_type
        end
        processing_iso = data.requestedAt
        payment_data.processingRequestedAt = processing_iso
    else
        return false, "HTTP " .. tostring(res.status) .. " from " .. processor_type
    end

    -- Update statistics in Redis with timestamp (robustly)
    local red, err
    do
        local attempts = 0
        while attempts < 3 do
            red, err = get_redis()
            if red then
                break
            end
            ngx.log(ngx.ERR,
                "Recording: Redis connect failed (" .. tostring(err) .. ") attempt " .. tostring(attempts + 1))
            ngx.sleep(0.005)
            attempts = attempts + 1
        end
    end
    if red then
        -- Use the same timestamp we sent to the PP (processing time)
        local ts_ms = utils.iso_to_epoch_ms(processing_iso) or (math.floor((ngx.now() or os.time()) * 1000))
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
            requestedAt = processing_iso
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

        local piped = red:commit_pipeline()
        if not piped or type(piped) ~= "table" then
            red:set_keepalive(10000, 500)
            return false, "recording redis pipeline failed"
        end
        red:set_keepalive(10000, 500)
    else
        -- If we couldn't record now, signal failure so the worker retries; next try will 409
        return false, "recording redis connect failed"
    end

    return true, nil
end

-- Process a single payment with failover logic
local function process_payment(payment_data)
    local health_cache = ngx.shared.health_cache

    -- Check which processor to use first
    local default_healthy = health_cache:get("default_healthy")
    local fallback_healthy = health_cache:get("fallback_healthy")
    local now = ngx.now()
    local default_last_err = health_cache:get("default_last_error") or -1
    local fallback_last_err = health_cache:get("fallback_last_error") or -1
    local recent_err_window = 0.5 -- seconds

    local processors_to_try = {}

    -- Build order with fast circuit breaker heuristic
    if default_healthy and fallback_healthy then
        local default_recent_bad = (default_last_err >= 0) and ((now - default_last_err) < recent_err_window)
        local fallback_recent_bad = (fallback_last_err >= 0) and ((now - fallback_last_err) < recent_err_window)

        if default_recent_bad and not fallback_recent_bad then
            -- Default falhou há instantes, tente fallback primeiro
            processors_to_try = {"fallback", "default"}
        elseif fallback_recent_bad and not default_recent_bad then
            processors_to_try = {"default", "fallback"}
        else
            -- Sem erro recente, prioridade normal (default tem menor taxa)
            processors_to_try = {"default", "fallback"}
        end
    else
        -- Apenas um saudável
        if default_healthy then
            table.insert(processors_to_try, "default")
        end
        if fallback_healthy then
            table.insert(processors_to_try, "fallback")
        end
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
        -- Record last error timestamp for fast circuit breaker
        health_cache:set(processor_type .. "_last_error", now, 1)
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
        red:set_keepalive(10000, 500)

        if res and res ~= ngx.null then
            local payment_json = res[2]
            local ok, payment_data = pcall(cjson.decode, payment_json)
            if ok and type(payment_data) == "table" then
                local success, result = process_payment(payment_data)
                if not success then
                    local retry_count = (payment_data.retry_count or 0) + 1
                    if retry_count <= _G.config.queue.max_retries then
                        payment_data.retry_count = retry_count
                        -- Persist stable processing timestamp across retries
                        if not payment_data.processingRequestedAt then
                            payment_data.processingRequestedAt = utils.get_iso_timestamp()
                        end
                        -- Backoff com jitter para evitar ondas no limite da janela [from, to)
                        local base_ms = _G.config.queue.retry_delay or 200
                        -- semente por worker (executa apenas uma vez
                        if not _G.__seeded then
                            math.randomseed((ngx.now() * 1000) % 2 ^ 31)
                            _G.__seeded = true
                        end
                        local jitter_ms = math.random(0, base_ms)
                        local delay_s = (base_ms + jitter_ms) / 1000

                        local function requeue_cb(premature)
                            if premature then
                                return
                            end
                            local red2 = get_redis()
                            if red2 then
                                red2:rpush(_G.config.queue.name, cjson.encode(payment_data))
                                red2:set_keepalive(10000, 500)
                            end
                        end
                        local ok_t, err_t = ngx.timer.at(delay_s, requeue_cb)
                        if not ok_t then
                            -- Fallback: re-enfileira imediatamente
                            local red2 = get_redis()
                            if red2 then
                                red2:rpush(_G.config.queue.name, cjson.encode(payment_data))
                                red2:set_keepalive(10000, 500)
                            end
                        end
                        ngx.log(ngx.WARN,
                            string.format("Payment retry %d for %s scheduled in %.0fms (jitter %.0fms)", retry_count,
                                tostring(payment_data.correlationId), delay_s * 1000, jitter_ms))
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
