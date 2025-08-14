local cjson = require "cjson"
local redis = require "resty.redis"

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

-- Enqueue a payment for processing
function _M.enqueue_payment(payment_data)
    local red, err = get_redis()
    if not red then
        return false, "Redis connection failed: " .. (err or "unknown")
    end
    
    local payment_json = cjson.encode(payment_data)
    local res, err = red:rpush(_G.config.queue.name, payment_json)
    
    red:set_keepalive(10000, 50)
    
    if not res then
        return false, "Queue push failed: " .. (err or "unknown")
    end
    
    return true
end

-- Get queue length for monitoring
function _M.get_queue_length()
    local red, err = get_redis()
    if not red then
        return 0
    end
    
    local length = red:llen(_G.config.queue.name) or 0
    red:set_keepalive(10000, 50)
    
    return length
end

return _M
