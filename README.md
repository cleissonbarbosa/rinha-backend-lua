# Rinha de Backend 2025 - Payment Gateway

## Overview

This project is a backend system for the "Rinha de Backend 2025" competition. It acts as a payment gateway that intermediates payment requests to external payment processing services. The system must handle two payment processors - a primary service with lower fees and a fallback service with higher fees but better availability. The challenge involves maximizing profit by using the most cost-effective processor while maintaining system reliability and performance.

Key features:
- Payment processing intermediation with fee management
- Fallback mechanism for service resilience
- Payment summary reporting for auditing
- Health check monitoring for external services
- Performance optimization for competitive scoring

## Quick Start with Docker

### Prerequisites
- Docker
- Docker Compose

### Running the Application

1. Clone the repository:
```bash
git clone <repository-url>
cd rinha-backend-lua
```

2. Start all services:
```bash
docker-compose up --build
```

3. The application will be available at:
- **Main API**: http://localhost:9999
- **Health Check**: http://localhost:9999/health

### Available Endpoints
- `POST /payments` - Process payment requests
- `GET /payments-summary` - Get payment summary
- `POST /purge-payments` - Clear payment data
- `GET /health` - Health check

### Quick Build Script
For convenience, you can use the build script:
```bash
./build.sh
```

### Stopping Services
```bash
docker-compose down
```

For more detailed Docker usage instructions, see [DOCKER_USAGE.md](DOCKER_USAGE.md).

## User Preferences

Preferred communication style: Simple, everyday language.

## System Architecture

### Core Design Pattern
The system implements a **Circuit Breaker and Fallback Pattern** to handle external service instabilities:

**Problem**: External payment processors experience instability and downtime, requiring robust error handling
**Solution**: Primary-fallback architecture with health monitoring and automatic failover
**Benefits**: Maintains service availability while optimizing costs through intelligent routing

### Service Layer Architecture
- **Payment Gateway Service**: Main orchestrator handling payment requests
- **Health Monitor Service**: Tracks availability of external payment processors
- **Fee Calculator Service**: Manages fee calculations for different processors
- **Summary Service**: Aggregates payment data for reporting

### Data Flow Strategy
1. **Payment Request Processing**:
   - Validate incoming payment requests
   - Check primary processor health
   - Route to appropriate processor based on availability and cost
   - Handle failures with fallback mechanisms

2. **Health Monitoring**:
   - Periodic health checks on external services
   - Circuit breaker state management
   - Intelligent routing decisions based on service status

### Error Handling Strategy
- **Retry Logic**: Exponential backoff for transient failures
- **Circuit Breaker**: Automatic failover when services become unreliable
- **Graceful Degradation**: Fallback to higher-cost processor when primary fails

### Performance Optimization
**Target**: Achieve sub-11ms p99 response times for performance bonus
**Approach**: 
- Asynchronous processing where possible
- Connection pooling for external services
- Minimal serialization overhead
- Efficient data structures for summary calculations

## External Dependencies

### Payment Processors
- **Primary Payment Processor**: Lower fee rates, prone to instability
- **Fallback Payment Processor**: Higher fee rates, more reliable
- Both services provide:
  - `POST /payments` - Process payment requests
  - `GET /payments/service-health` - Health check endpoint

### Required Integrations
- **HTTP Client**: For communication with external payment processors
- **Health Monitoring**: Regular polling of service health endpoints
- **Error Tracking**: Monitor and log external service failures
- **Metrics Collection**: Track response times and success rates for performance optimization

### Data Storage
- **In-Memory Storage**: For payment summaries and health status caching
- **Persistent Storage**: May be required for audit trails and payment history (implementation dependent)

### API Endpoints to Implement
- `POST /payments` - Process payment requests with intelligent routing
- `GET /payments-summary` - Return aggregated payment data for auditing