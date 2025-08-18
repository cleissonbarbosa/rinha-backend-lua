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
    sock:settimeouts(500, 2000, 3000) -- connect 0.5s, send 2s, read 3s

    local ok, err = sock:connect(host, port)
    if not ok then
        return nil, "failed to connect to " .. host .. ":" .. port .. ": " .. (err or "unknown")
    end

    -- Build HTTP request
    local method = (options and options.method) or "GET"
    local headers = (options and options.headers) or {}
    local body = (options and options.body) or ""

    local request_lines = {method .. " " .. path .. " HTTP/1.1", "Host: " .. host .. ":" .. port,
                           "Connection: keep-alive", "Keep-Alive: timeout=30"}

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
    local is_chunked = false
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
        -- Check for Transfer-Encoding: chunked (case-insensitive)
        local lower = header_line:lower()
        local te = lower:match("^transfer%-encoding:%s*(.-)$")
        if te and te:find("chunked", 1, true) then
            is_chunked = true
        end
    end

    -- Read body
    local response_body = ""
    if is_chunked then
        -- Read chunked response per RFC 7230
        while true do
            local size_line, err = sock:receive("*l")
            if not size_line then
                sock:close()
                return nil, "failed to read chunk size: " .. (err or "unknown")
            end
            local chunk_size = tonumber(size_line, 16)
            if not chunk_size then
                sock:close()
                return nil, "invalid chunk size line: " .. tostring(size_line)
            end
            if chunk_size == 0 then
                -- Read trailing CRLF and possible trailer headers until empty line
                -- Consume possible trailer headers
                while true do
                    local trailer, err = sock:receive("*l")
                    if not trailer then
                        sock:close()
                        return nil, "failed to read chunk trailer: " .. (err or "unknown")
                    end
                    if trailer == "" then
                        break
                    end
                end
                break
            end
            local chunk, err = sock:receive(chunk_size)
            if not chunk then
                sock:close()
                return nil, "failed to read chunk data: " .. (err or "unknown")
            end
            response_body = response_body .. chunk
            -- Read the trailing CRLF for this chunk
            local crlf, err = sock:receive(2)
            if not crlf then
                sock:close()
                return nil, "failed to read chunk CRLF: " .. (err or "unknown")
            end
        end
    elseif content_length > 0 then
        response_body, err = sock:receive(content_length)
        if not response_body then
            sock:close()
            return nil, "failed to read body: " .. (err or "unknown")
        end
    else
        -- Unknown length and not chunked: close connection to finish read
        -- Override keep-alive in this rare case to avoid indefinite waits
        sock:close()
        return {
            status = status,
            body = response_body
        }
    end

    -- Put socket back to pool for reuse
    local ok_keep = sock:setkeepalive(10000, 512)
    if not ok_keep then
        sock:close()
    end

    return {
        status = status,
        body = response_body
    }
end

-- Create a new HTTP client instance (for compatibility)
function _M.new()
    return {
        request_uri = _M.request_uri,
        set_timeouts = function()
        end, -- no-op for compatibility
        close = function()
        end -- no-op for compatibility
    }
end

return _M
