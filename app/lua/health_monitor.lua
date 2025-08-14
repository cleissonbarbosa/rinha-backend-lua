local cjson = require "cjson"

local _M = {}

-- Check health of a payment processor using curl
local function check_processor_health(processor_type)
    local processor = _G.config.payment_processors[processor_type]
    local health_cache = ngx.shared.health_cache
    
    -- Create curl command for health check
    local cmd = string.format(
        "curl -s -X GET %s/payments/service-health -w '%%{http_code}' -o /tmp/health_response_%s.json",
        processor.url,
        processor_type
    )
    
    -- Execute curl command
    local handle = io.popen(cmd)
    local result = handle:read("*a")
    handle:close()
    
    -- Parse HTTP status code
    local status_code = tonumber(result:match("(%d+)$"))
    
    if not status_code or status_code ~= 200 then
        health_cache:set(processor_type .. "_healthy", false, 60)
        health_cache:set(processor_type .. "_min_response_time", 5000, 60)
        return false
    end
    
    -- Read response body
    local response_file = io.open("/tmp/health_response_" .. processor_type .. ".json", "r")
    if not response_file then
        health_cache:set(processor_type .. "_healthy", false, 60)
        return false
    end
    
    local response_body = response_file:read("*all")
    response_file:close()
    
    local ok, health_data = pcall(cjson.decode, response_body)
    if not ok then
        health_cache:set(processor_type .. "_healthy", false, 60)
        return false
    end
    
    -- Update health status
    local is_healthy = not health_data.isInFailure
    local min_response_time = health_data.minProcessingTimeMs or 1000
    
    health_cache:set(processor_type .. "_healthy", is_healthy, 60)
    health_cache:set(processor_type .. "_min_response_time", min_response_time, 60)
    
    return is_healthy
end

-- Health monitoring worker
function _M.start_monitor()
    if ngx.worker.id() ~= 0 then
        return  -- Only run on worker 0
    end
    
    local function monitor()
        -- Check health of both processors every 10 seconds
        -- (respecting the 5-second rate limit by alternating)
        
        local check_count = 0
        while true do
            ngx.sleep(5)  -- Wait 5 seconds between checks
            
            local processor_type = (check_count % 2 == 0) and "default" or "fallback"
            check_processor_health(processor_type)
            check_count = check_count + 1
            
            -- Log health status every 10 checks (50 seconds)
            if check_count % 10 == 0 then
                local health_cache = ngx.shared.health_cache
                local default_healthy = health_cache:get("default_healthy")
                local fallback_healthy = health_cache:get("fallback_healthy")
                
                ngx.log(ngx.INFO, "Health status - Default: " .. tostring(default_healthy) .. 
                                 ", Fallback: " .. tostring(fallback_healthy))
            end
        end
    end
    
    -- Start monitor in a timer
    local ok, err = ngx.timer.at(0, monitor)
    if not ok then
        ngx.log(ngx.ERR, "Failed to start health monitor: " .. err)
    end
end

return _M
