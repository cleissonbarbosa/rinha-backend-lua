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
    local res, err = http.request_uri(processor.url .. "/payments", {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
        },
        body = payload,
    })
    
    if not res then
        return false, "Request failed: " .. (err or "unknown")
    end
    
    if res.status ~= 200 then
        return false, "HTTP " .. res.status .. " from " .. processor_type
    end
    
    -- Update statistics in Redis
    local red, err = get_redis()
    if red then
        local key_requests = "stats:" .. processor_type .. "_total_requests"
        local key_amount = "stats:" .. processor_type .. "_total_amount"
        
        red:incr(key_requests)
        red:incrbyfloat(key_amount, payment_data.amount)
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
        return  -- Only run on worker 0
    end
    
    local function worker(premature)
        if premature then
            return
        end
        
        local red, err = get_redis()
        if not red then
            ngx.log(ngx.ERR, "Failed to connect to Redis: " .. (err or "unknown"))
            -- Schedule next iteration
            ngx.timer.at(1, worker)
            return
        end
        
        -- Block and wait for payment from queue
        local res, err = red:blpop(_G.config.queue.name, 1)
        red:set_keepalive(10000, 50)
        
        if res and res ~= ngx.null then
            local payment_json = res[2]
            local ok, payment_data = pcall(cjson.decode, payment_json)
            if ok then
                -- Process the payment
                local success, result = process_payment(payment_data)
                if not success then
                    -- Retry logic
                    local retry_count = (payment_data.retry_count or 0) + 1
                    if retry_count <= _G.config.queue.max_retries then
                        payment_data.retry_count = retry_count
                        local red2, _ = get_redis()
                        if red2 then
                            red2:rpush(_G.config.queue.name, cjson.encode(payment_data))
                            red2:set_keepalive(10000, 50)
                            ngx.log(ngx.ERR, "Payment retry " .. retry_count .. " for " .. payment_data.correlationId)
                        end
                    else
                        ngx.log(ngx.ERR, "Payment failed permanently: " .. payment_data.correlationId .. " - " .. result)
                    end
                else
                    ngx.log(ngx.INFO, "Payment processed successfully with " .. result .. ": " .. payment_data.correlationId)
                end
            else
                ngx.log(ngx.ERR, "Failed to decode payment data: " .. payment_json)
            end
        end
        
        -- Schedule next iteration
        ngx.timer.at(0, worker)
    end
    
    -- Start worker in a timer
    local ok, err = ngx.timer.at(0, worker)
    if not ok then
        ngx.log(ngx.ERR, "Failed to start payment processor worker: " .. err)
    end
end

return _M
