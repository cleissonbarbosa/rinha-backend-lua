-- Initialize required modules and configurations
local cjson = require "cjson"
local redis = require "resty.redis"

-- Global configuration
_G.config = {
    redis = {
        host = os.getenv("REDIS_HOST") or "redis",
        port = tonumber(os.getenv("REDIS_PORT")) or 6379,
        timeout = 1000,
        pool_size = 100,
        backlog = 50
    },
    payment_processors = {
        default = {
            url = "http://localhost:8080",
            fee_rate = 0.05  -- Will be updated from health check
        },
        fallback = {
            url = "http://localhost:8081", 
            fee_rate = 0.10  -- Will be updated from health check
        }
    },
    queue = {
        name = "payment_queue",
        max_retries = 3,
        retry_delay = 1000
    },
    instance_id = os.getenv("INSTANCE_ID") or "app1"
}

-- Initialize shared dictionaries
local stats = ngx.shared.stats
local health_cache = ngx.shared.health_cache

-- Initialize counters
stats:set("default_total_requests", 0)
stats:set("default_total_amount", 0)
stats:set("fallback_total_requests", 0)
stats:set("fallback_total_amount", 0)

-- Set initial health status
health_cache:set("default_healthy", true)
health_cache:set("fallback_healthy", true)
health_cache:set("default_min_response_time", 100)
health_cache:set("fallback_min_response_time", 200)

ngx.log(ngx.ERR, "Payment processor initialized for instance: " .. _G.config.instance_id)
