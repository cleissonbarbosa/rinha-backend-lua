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

local default_requests = tonumber(red:get("stats:default_total_requests")) or 0
local default_amount = tonumber(red:get("stats:default_total_amount")) or 0
local fallback_requests = tonumber(red:get("stats:fallback_total_requests")) or 0
local fallback_amount = tonumber(red:get("stats:fallback_total_amount")) or 0

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
