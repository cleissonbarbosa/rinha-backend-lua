local cjson = require "cjson"
local utils = require "utils"
local queue_manager = require "queue_manager"

-- Read and validate request
ngx.req.read_body()
local body = ngx.req.get_body_data()

if not body then
    ngx.status = 400
    ngx.say(cjson.encode({
        error = "Missing request body"
    }))
    return
end

local ok, payment_data = pcall(cjson.decode, body)
if not ok then
    ngx.status = 400
    ngx.say(cjson.encode({
        error = "Invalid JSON"
    }))
    return
end

-- Validate required fields
if not payment_data.correlationId or not payment_data.amount then
    ngx.status = 400
    ngx.say(cjson.encode({
        error = "Missing required fields: correlationId, amount"
    }))
    return
end

-- Validate UUID format
if not utils.is_valid_uuid(payment_data.correlationId) then
    ngx.status = 400
    ngx.say(cjson.encode({
        error = "Invalid correlationId format"
    }))
    return
end

-- Validate amount
if type(payment_data.amount) ~= "number" or payment_data.amount <= 0 then
    ngx.status = 400
    ngx.say(cjson.encode({
        error = "Invalid amount"
    }))
    return
end

-- Add timestamp and queue the payment
payment_data.requestedAt = utils.get_iso_timestamp()
payment_data.receivedAt = ngx.now()

local success, err = queue_manager.enqueue_payment(payment_data)
if not success then
    ngx.log(ngx.ERR, "Failed to queue payment (will retry async): " .. (err or "unknown error"))
    -- Best-effort async retry without blocking the client; reduces client-side failures.
    local function retry_enqueue(premature)
        if premature then
            return
        end
        local ok2 = queue_manager.enqueue_payment(payment_data)
        if not ok2 then
            -- One more delayed attempt
            ngx.timer.at(0.02, function()
                queue_manager.enqueue_payment(payment_data)
            end)
        end
    end
    ngx.timer.at(0, retry_enqueue)
end

-- Return immediate success response (no body for lower latency)
ngx.header.content_length = 0
return ngx.exit(202)
