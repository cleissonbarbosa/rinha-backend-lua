#!/bin/bash

echo "=== Teste de Carga - Gateway de Pagamentos ==="
echo "Iniciando teste com múltiplas requisições simultâneas..."

# Function to generate UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$(shuf -i 1000-9999 -n 1)-4$(shuf -i 1000-9999 -n 1)-$(shuf -i 8000-9999 -n 1)-$(shuf -i 100000000000-999999999999 -n 1)"
}

# Function to send payment
send_payment() {
    local id=$1
    local amount=$(shuf -i 10-500 -n 1)
    local uuid=$(generate_uuid)
    
    local start_time=$(date +%s%3N)
    local response=$(curl -s -w "%{http_code}" -X POST http://localhost:9999/payments \
        -H "Content-Type: application/json" \
        -d "{\"correlationId\":\"$uuid\",\"amount\":$amount}")
    local end_time=$(date +%s%3N)
    
    local http_code="${response: -3}"
    local response_time=$(( end_time - start_time ))
    
    echo "Payment $id: HTTP $http_code, ${response_time}ms, \$${amount}"
    
    if [ "$http_code" = "202" ]; then
        echo 1 > /tmp/success_$id
    else
        echo 0 > /tmp/success_$id
    fi
    echo "$response_time" > /tmp/time_$id
}

# Clean up previous test files
rm -f /tmp/success_* /tmp/time_*

echo "Fase 1: Teste de carga moderada (50 requisições simultâneas)"
for i in {1..50}; do
    send_payment $i &
done
wait

echo "Aguardando processamento assíncrono..."
sleep 5

echo "Verificando estatísticas intermediárias..."
curl -s "http://localhost:9999/payments-summary" | jq . 2>/dev/null || curl -s "http://localhost:9999/payments-summary"

echo ""
echo "Fase 2: Teste de carga alta (100 requisições simultâneas)"
for i in {51..150}; do
    send_payment $i &
done
wait

echo "Aguardando processamento assíncrono..."
sleep 8

echo ""
echo "Fase 3: Teste de carga extrema (200 requisições simultâneas)"
for i in {151..350}; do
    send_payment $i &
done
wait

echo "Aguardando processamento final..."
sleep 10

echo ""
echo "=== RESULTADOS DO TESTE DE CARGA ==="

# Count successes and calculate statistics
total_requests=350
successes=$(find /tmp -name "success_*" -exec cat {} \; | awk '{sum+=$1} END {print sum+0}')
failures=$((total_requests - successes))

echo "Total de requisições: $total_requests"
echo "Sucessos: $successes"
echo "Falhas: $failures"
echo "Taxa de sucesso: $((successes * 100 / total_requests))%"

# Calculate response time statistics
if [ -f /tmp/time_1 ]; then
    echo ""
    echo "Estatísticas de tempo de resposta:"
    find /tmp -name "time_*" -exec cat {} \; | sort -n > /tmp/all_times.txt
    
    min_time=$(head -1 /tmp/all_times.txt)
    max_time=$(tail -1 /tmp/all_times.txt)
    avg_time=$(awk '{sum+=$1; count++} END {print int(sum/count)}' /tmp/all_times.txt)
    
    echo "Tempo mínimo: ${min_time}ms"
    echo "Tempo máximo: ${max_time}ms"
    echo "Tempo médio: ${avg_time}ms"
    
    # Calculate percentiles
    total_lines=$(wc -l < /tmp/all_times.txt)
    p95_line=$((total_lines * 95 / 100))
    p99_line=$((total_lines * 99 / 100))
    
    p95_time=$(sed -n "${p95_line}p" /tmp/all_times.txt)
    p99_time=$(sed -n "${p99_line}p" /tmp/all_times.txt)
    
    echo "P95: ${p95_time}ms"
    echo "P99: ${p99_time}ms"
fi

echo ""
echo "Estatísticas finais dos processadores:"
curl -s "http://localhost:9999/payments-summary" | jq . 2>/dev/null || curl -s "http://localhost:9999/payments-summary"

echo ""
echo "Verificando tamanho da fila Redis:"
docker exec $(docker ps -q --filter "name=redis") redis-cli llen payment_queue 2>/dev/null || echo "Redis não acessível ou fila não encontrada"

echo ""
echo "=== Teste de carga concluído ==="