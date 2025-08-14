local _M = {}

-- Simple HTTP client using ngx.location.capture for internal requests
function _M.post_json(url, data)
    local cjson = require "cjson"
    
    -- Parse URL to extract host and port
    local host, port, path = url:match("http://([^:]+):([^/]+)(/.*)$")
    if not host then
        host, path = url:match("http://([^/]+)(/.*)$")
        port = "80"
    end
    
    -- Create capture location
    local capture_url = "/internal_http_proxy"
    
    -- Setup headers and body
    local headers = {
        ["Content-Type"] = "application/json",
        ["Host"] = host .. ":" .. port
    }
    
    local args = {
        method = ngx.HTTP_POST,
        body = cjson.encode(data),
        args = { 
            target_host = host,
            target_port = port,
            target_path = path
        }
    }
    
    -- Make internal capture request
    local res = ngx.location.capture(capture_url, args)
    
    if res.status == 200 then
        return { status = 200, body = res.body }
    else
        return { status = res.status or 500, body = res.body or "Request failed" }
    end
end

-- Simple GET request
function _M.get(url)
    local host, port, path = url:match("http://([^:]+):([^/]+)(/.*)$")
    if not host then
        host, path = url:match("http://([^/]+)(/.*)$")
        port = "80"
    end
    
    local capture_url = "/internal_http_proxy"
    
    local args = {
        method = ngx.HTTP_GET,
        args = { 
            target_host = host,
            target_port = port,
            target_path = path
        }
    }
    
    local res = ngx.location.capture(capture_url, args)
    
    return { status = res.status or 500, body = res.body or "Request failed" }
end

return _M