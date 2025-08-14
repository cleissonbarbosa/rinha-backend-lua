local cjson = require "cjson"

-- Set content type to HTML
ngx.header.content_type = "text/html"

-- Get current statistics
local stats = ngx.shared.stats
local health_cache = ngx.shared.health_cache

local default_requests = stats:get("default_total_requests") or 0
local default_amount = stats:get("default_total_amount") or 0
local fallback_requests = stats:get("fallback_total_requests") or 0
local fallback_amount = stats:get("fallback_total_amount") or 0

local default_healthy = health_cache:get("default_healthy") or false
local fallback_healthy = health_cache:get("fallback_healthy") or false

-- Generate a sample UUID for testing
local function generate_uuid()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function (c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

local sample_uuid = generate_uuid()

-- HTML page content
local html = string.format([[
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Payment Gateway - Rinha de Backend 2025</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background-color: #f5f5f5; }
        .container { max-width: 1000px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { text-align: center; margin-bottom: 40px; }
        .status { display: flex; justify-content: space-around; margin: 30px 0; }
        .status-card { background: #f8f9fa; padding: 20px; border-radius: 8px; text-align: center; min-width: 200px; }
        .healthy { border-left: 4px solid #28a745; }
        .unhealthy { border-left: 4px solid #dc3545; }
        .stats { display: flex; justify-content: space-around; margin: 30px 0; }
        .stat-card { background: #e3f2fd; padding: 20px; border-radius: 8px; text-align: center; min-width: 200px; }
        .test-section { margin: 30px 0; padding: 20px; background: #f8f9fa; border-radius: 8px; }
        .form-group { margin: 15px 0; }
        .form-group label { display: block; margin-bottom: 5px; font-weight: bold; }
        .form-group input { width: 100%%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; }
        .btn { background: #007bff; color: white; padding: 12px 24px; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; }
        .btn:hover { background: #0056b3; }
        .result { margin: 20px 0; padding: 15px; border-radius: 4px; }
        .success { background: #d4edda; border: 1px solid #c3e6cb; color: #155724; }
        .error { background: #f8d7da; border: 1px solid #f5c6cb; color: #721c24; }
        .endpoints { margin: 30px 0; }
        .endpoint { background: #f8f9fa; padding: 15px; margin: 10px 0; border-radius: 4px; border-left: 4px solid #007bff; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏦 Payment Gateway</h1>
            <h2>Rinha de Backend 2025 - Lua/OpenResty Implementation</h2>
            <p>High-performance payment processing with intelligent failover</p>
        </div>

        <div class="status">
            <div class="status-card %s">
                <h3>Default Processor</h3>
                <p><strong>Status:</strong> %s</p>
                <p><strong>Fee Rate:</strong> 5%%</p>
                <p>Lower fees, higher performance</p>
            </div>
            <div class="status-card %s">
                <h3>Fallback Processor</h3>
                <p><strong>Status:</strong> %s</p>
                <p><strong>Fee Rate:</strong> 10%%</p>
                <p>Higher fees, better reliability</p>
            </div>
        </div>

        <div class="stats">
            <div class="stat-card">
                <h3>Default Processor Stats</h3>
                <p><strong>Requests:</strong> %d</p>
                <p><strong>Total Amount:</strong> $%.2f</p>
            </div>
            <div class="stat-card">
                <h3>Fallback Processor Stats</h3>
                <p><strong>Requests:</strong> %d</p>
                <p><strong>Total Amount:</strong> $%.2f</p>
            </div>
        </div>

        <div class="endpoints">
            <h3>API Endpoints</h3>
            <div class="endpoint">
                <strong>POST /payments</strong> - Process payment requests
                <br><small>Accepts: {correlationId: string, amount: number}</small>
            </div>
            <div class="endpoint">
                <strong>GET /payments-summary</strong> - Get payment statistics
                <br><small>Optional params: ?from=ISO_DATE&to=ISO_DATE</small>
            </div>
        </div>

        <div class="test-section">
            <h3>Test Payment Processing</h3>
            <div class="form-group">
                <label for="correlationId">Correlation ID (UUID):</label>
                <input type="text" id="correlationId" value="%s">
            </div>
            <div class="form-group">
                <label for="amount">Amount ($):</label>
                <input type="number" id="amount" value="99.99" step="0.01" min="0.01">
            </div>
            <button class="btn" onclick="sendPayment()">Send Payment</button>
            <button class="btn" onclick="refreshStats()" style="background: #28a745;">Refresh Stats</button>
            
            <div id="result"></div>
        </div>
    </div>

    <script>
        function sendPayment() {
            const correlationId = document.getElementById('correlationId').value;
            const amount = parseFloat(document.getElementById('amount').value);
            
            if (!correlationId || !amount) {
                showResult('Please fill in all fields', 'error');
                return;
            }
            
            fetch('/payments', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    correlationId: correlationId,
                    amount: amount
                })
            })
            .then(response => response.json())
            .then(data => {
                showResult('Payment sent successfully: ' + JSON.stringify(data), 'success');
                // Generate new UUID for next test
                document.getElementById('correlationId').value = generateUUID();
            })
            .catch(error => {
                showResult('Error: ' + error.message, 'error');
            });
        }
        
        function refreshStats() {
            window.location.reload();
        }
        
        function showResult(message, type) {
            const resultDiv = document.getElementById('result');
            resultDiv.innerHTML = '<div class="result ' + type + '">' + message + '</div>';
        }
        
        function generateUUID() {
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });
        }
    </script>
</body>
</html>
]], 
default_healthy and "healthy" or "unhealthy",
default_healthy and "Healthy" or "Unhealthy",
fallback_healthy and "healthy" or "unhealthy", 
fallback_healthy and "Healthy" or "Unhealthy",
default_requests, default_amount,
fallback_requests, fallback_amount,
sample_uuid)

ngx.say(html)