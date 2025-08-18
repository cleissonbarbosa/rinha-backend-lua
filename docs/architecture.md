# Rinha de Backend 2025 — Arquitetura em Lua

Este diretório contém um diagrama da arquitetura do projeto:

- `architecture.svg` — Versão estática para visualização rápida.

## Visão geral

Fluxo principal:
1) Cliente HTTP -> Nginx Gateway (`nginx/nginx.conf`, exposto em 9999) -> `app1`/`app2` (OpenResty/Lua)
2) Handler `/payments` (202 Accepted) enfileira no Redis (LPUSH). Workers (timers) fazem BLPOP.
3) Worker chama Payment Processor Default (`http://payment-processor-default:8080`) com failover para Fallback (`http://payment-processor-fallback:8080`). Health checks periódicos atualizam circuit breaker simples.
4) Estatísticas/counters no Redis: totais, buckets por segundo (`stats_sec:*`) e timeline (`payments_by_time_ms`).
5) `/payments-summary` lê counters rápidos ou agrega janela [from, to) via ZSET millisecond-precision.
6) `/purge-payments` limpa fila, counters, buckets e chaves `payment:*` no Redis.

Componentes:
- Nginx Gateway (container nginx) balanceia para `app1` e `app2` via upstream keepalive.
- `app1`/`app2` (OpenResty + Lua): handlers, fila, workers, health monitor, HTTP client simples TCP.
- Redis: fila `payment_queue`, chaves `stats:*`, `stats_sec:*`, ZSET `payments_by_time_ms`, registros `payment:*`.
- Payment Processors externos: Default e Fallback.
