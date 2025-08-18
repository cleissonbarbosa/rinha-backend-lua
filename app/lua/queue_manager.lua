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
    local payment_json = cjson.encode(payment_data)
    local attempts = 0
    while attempts < 3 do
        local red, err = get_redis()
        if red then
            local ok, rerr
            ok, rerr = red:rpush(_G.config.queue.name, payment_json)
            red:set_keepalive(10000, 500)
            if ok then
                return true
            else
                ngx.log(ngx.ERR, "Queue push failed: " .. tostring(rerr))
            end
        else
            ngx.log(ngx.ERR, "Redis connection failed: " .. tostring(err))
        end
        attempts = attempts + 1
        if attempts < 3 then
            ngx.sleep(0.005)
        end
    end
    return false, "enqueue_payment exhausted retries"
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
