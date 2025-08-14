local _M = {}

-- Simple HTTP client using TCP sockets
function _M.request_uri(url, options)
    local cjson = require "cjson"
    
    -- Parse URL
    local host, port, path = url:match("http://([^:]+):([^/]+)(/.*)$")
    if not host then
        host, path = url:match("http://([^/]+)(/.*)$")
        port = 80
    else
        port = tonumber(port)
    end
    
    if not path then
        path = "/"
    end
    
    -- Create socket
    local sock = ngx.socket.tcp()
    sock:settimeouts(3000, 3000, 3000) -- 3 second timeouts
    
    local ok, err = sock:connect(host, port)
    if not ok then
        return nil, "failed to connect to " .. host .. ":" .. port .. ": " .. (err or "unknown")
    end
    
    -- Build HTTP request
    local method = (options and options.method) or "GET"
    local headers = (options and options.headers) or {}
    local body = (options and options.body) or ""
    
    local request_lines = {
        method .. " " .. path .. " HTTP/1.1",
        "Host: " .. host .. ":" .. port,
        "Connection: close"
    }
    
    -- Add custom headers
    for key, value in pairs(headers) do
        table.insert(request_lines, key .. ": " .. value)
    end
    
    -- Add content length if there's a body
    if body and body ~= "" then
        table.insert(request_lines, "Content-Length: " .. #body)
    end
    
    -- Empty line to end headers
    table.insert(request_lines, "")
    
    local request = table.concat(request_lines, "\r\n") .. "\r\n"
    if body and body ~= "" then
        request = request .. body
    end
    
    -- Send request
    local bytes, err = sock:send(request)
    if not bytes then
        sock:close()
        return nil, "failed to send request: " .. (err or "unknown")
    end
    
    -- Read response line by line to handle HTTP properly
    local status_line, err = sock:receive("*l")
    if not status_line then
        sock:close()
        return nil, "failed to read status line: " .. (err or "unknown")
    end
    
    -- Parse status code
    local status = tonumber(status_line:match("HTTP/1%.[01] (%d+)"))
    if not status then
        sock:close()
        return nil, "could not parse status code from: " .. status_line
    end
    
    -- Read headers until empty line
    local content_length = 0
    while true do
        local header_line, err = sock:receive("*l")
        if not header_line then
            sock:close()
            return nil, "failed to read headers: " .. (err or "unknown")
        end
        
        if header_line == "" then
            break -- End of headers
        end
        
        -- Check for Content-Length
        local length = header_line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if length then
            content_length = tonumber(length)
        end
    end
    
    -- Read body
    local response_body = ""
    if content_length > 0 then
        response_body, err = sock:receive(content_length)
        if not response_body then
            sock:close()
            return nil, "failed to read body: " .. (err or "unknown")
        end
    else
        -- Read until connection closes for chunked/unknown length
        while true do
            local data, err = sock:receive(1024)
            if not data then
                break
            end
            response_body = response_body .. data
        end
    end
    
    sock:close()
    
    return {
        status = status,
        body = response_body
    }
end

-- Create a new HTTP client instance (for compatibility)
function _M.new()
    return {
        request_uri = _M.request_uri,
        set_timeouts = function() end, -- no-op for compatibility
        close = function() end -- no-op for compatibility
    }
end

return _M