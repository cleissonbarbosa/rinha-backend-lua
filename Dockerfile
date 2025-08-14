FROM openresty/openresty:1.27.1.2-alpine

# Install required packages
RUN apk add --no-cache \
    redis \
    curl

# Create necessary directories
RUN mkdir -p /usr/local/openresty/nginx/lua

# Copy application files
COPY app/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY app/lua/ /usr/local/openresty/nginx/lua/

# Set working directory
WORKDIR /usr/local/openresty

# Expose port
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Start OpenResty
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
