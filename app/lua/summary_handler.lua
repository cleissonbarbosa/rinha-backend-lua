local cjson = require "cjson"
local utils = require "utils"

-- Get query parameters
local args = ngx.req.get_uri_args()
local from_time = args["from"]
local to_time = args["to"]

-- For this implementation, we'll return totals from shared memory
-- In a production system, you'd filter by timestamp stored in Redis
local stats = ngx.shared.stats

local default_requests = stats:get("default_total_requests") or 0
local default_amount = stats:get("default_total_amount") or 0
local fallback_requests = stats:get("fallback_total_requests") or 0
local fallback_amount = stats:get("fallback_total_amount") or 0

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
