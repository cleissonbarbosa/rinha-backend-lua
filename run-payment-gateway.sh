#!/bin/bash

# Create working directories
mkdir -p app1_tmp/logs app2_tmp/logs nginx_tmp/logs

# Start mock payment processors
echo "Starting mock payment processors..."
node mock-payment-processor.js default &
DEFAULT_PROC_PID=$!

node mock-payment-processor.js fallback &
FALLBACK_PROC_PID=$!

sleep 2

# Start Redis server
echo "Starting Redis server..."
redis-server redis/redis.conf --daemonize yes --pidfile /tmp/redis.pid

# Wait for Redis to start
sleep 2

# Check if Redis is running
if redis-cli ping > /dev/null 2>&1; then
    echo "Redis started successfully"
else
    echo "Failed to start Redis"
    exit 1
fi

# Start OpenResty app instances
echo "Starting OpenResty app instances..."

# Start app1 on port 8001
REDIS_HOST=127.0.0.1 REDIS_PORT=6379 INSTANCE_ID=app1 openresty -p $(pwd)/app1_tmp -c $(pwd)/app1-nginx.conf &
APP1_PID=$!

# Start app2 on port 8002  
REDIS_HOST=127.0.0.1 REDIS_PORT=6379 INSTANCE_ID=app2 openresty -p $(pwd)/app2_tmp -c $(pwd)/app2-nginx.conf &
APP2_PID=$!

# Wait for apps to start
sleep 3

# Start nginx load balancer on port 9999
echo "Starting nginx load balancer..."
nginx -p $(pwd)/nginx_tmp -c $(pwd)/nginx-native.conf &
NGINX_PID=$!

echo "Payment Gateway started successfully!"
echo "- Default Payment Processor PID: $DEFAULT_PROC_PID (port 8080)"
echo "- Fallback Payment Processor PID: $FALLBACK_PROC_PID (port 8081)"
echo "- Redis PID: $(cat /tmp/redis.pid)"
echo "- App1 PID: $APP1_PID (port 8001)"
echo "- App2 PID: $APP2_PID (port 8002)" 
echo "- Nginx PID: $NGINX_PID (port 9999)"
echo "- Gateway available at http://localhost:9999"

# Save PIDs for cleanup
echo "$DEFAULT_PROC_PID" > /tmp/default_proc.pid
echo "$FALLBACK_PROC_PID" > /tmp/fallback_proc.pid
echo "$APP1_PID" > /tmp/app1.pid
echo "$APP2_PID" > /tmp/app2.pid
echo "$NGINX_PID" > /tmp/nginx.pid

# Wait for any process to exit
wait