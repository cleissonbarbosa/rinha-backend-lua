local cjson = require "cjson"
local http = require "simple_http"

local _M = {}

-- Check health of a payment processor using HTTP library
local function check_processor_health(processor_type)
    local processor = _G.config.payment_processors[processor_type]
    local health_cache = ngx.shared.health_cache

    -- Make health check request
    local res, err = http.request_uri(processor.url .. "/payments/service-health", {
        method = "GET",
        headers = {
            ["Content-Type"] = "application/json"
        }
    })
    if not res or res.status ~= 200 then
        health_cache:set(processor_type .. "_healthy", false, 60)
        health_cache:set(processor_type .. "_min_response_time", 5000, 60)
        return false
    end
    local ok, health_data = pcall(cjson.decode, res.body)
    if not ok then
        health_cache:set(processor_type .. "_healthy", false, 60)
        return false
    end

    -- Update health status
    local is_healthy = not health_data.failing
    local min_response_time = health_data.minResponseTime or 1000

    health_cache:set(processor_type .. "_healthy", is_healthy, 60)
    health_cache:set(processor_type .. "_min_response_time", min_response_time, 60)

    return is_healthy
end

-- Health monitoring worker
function _M.start_monitor()
    if ngx.worker.id() ~= 0 then
        return -- Only run on worker 0
    end

    local check_count = 0

    local function monitor(premature)
        if premature then
            return
        end

        local processor_type = (check_count % 2 == 0) and "default" or "fallback"
        check_processor_health(processor_type)
        check_count = check_count + 1

        -- Log health status every 10 checks (50 seconds)
        if check_count % 10 == 0 then
            local health_cache = ngx.shared.health_cache
            local default_healthy = health_cache:get("default_healthy")
            local fallback_healthy = health_cache:get("fallback_healthy")

            ngx.log(ngx.INFO, "Health status - Default: " .. tostring(default_healthy) .. ", Fallback: " ..
                tostring(fallback_healthy))
        end

        -- Schedule next check in 5 seconds
        ngx.timer.at(5, monitor)
    end

    -- Start monitor in a timer
    local ok, err = ngx.timer.at(0, monitor)
    if not ok then
        ngx.log(ngx.ERR, "Failed to start health monitor: " .. err)
    end
end

return _M
