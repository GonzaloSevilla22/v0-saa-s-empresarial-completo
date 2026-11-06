# ai-usage-counters — Spec (ai-usage-counters-split)

## Purpose

Reset mensual automático de contadores IA, incremento atómico vía RPC, y hook frontend de uso IA.
## Requirements
### Requirement: Reset mensual automático de contadores IA

El sistema SHALL resetear `ai_queries_used = 0`, `ai_advice_used = 0`, `ai_ocr_used = 0`, `ai_ocr_window_count = 0`, `ai_ocr_window_started_at = NULL`, `ai_queries_window_count = 0`, `ai_queries_window_started_at = NULL` y `usage_reset_at = now()` en todos los perfiles el primer día de cada mes a las 00:00 UTC, mediante un cron job de pg_cron llamado `reset-ai-counters`.

#### Scenario: Contadores se resetean el primer día del mes

- **WHEN** el cron job `reset-ai-counters` se ejecuta (1° del mes, 00:00 UTC)
- **THEN** todos los perfiles tienen `ai_queries_used = 0`, `ai_advice_used = 0`, `ai_ocr_used = 0`, `ai_ocr_window_count = 0`, `ai_ocr_window_started_at = NULL`, `ai_queries_window_count = 0`, `ai_queries_window_started_at = NULL`, `usage_reset_at = now()`

#### Scenario: Usuario que alcanzó el límite puede volver a consultar el mes siguiente

- **WHEN** un usuario `gratis` usó sus 5 consultas IA en enero y el cron corre el 1° de febrero
- **THEN** su `ai_queries_used = 0` y puede realizar nuevas consultas IA

#### Scenario: Usuario que agotó sus lecturas de factura puede volver a leer el mes siguiente

- **WHEN** un usuario `gratis` usó sus 5 lecturas de factura en noviembre y el cron corre el 1° de diciembre
- **THEN** su `ai_ocr_used = 0` y puede leer facturas de nuevo

### Requirement: Incremento atómico de contadores IA

El sistema SHALL proveer un RPC `rpc_increment_ai_usage(p_user_id UUID, p_counter TEXT)` que incremente el contador correspondiente en un único UPDATE atómico en la DB, sin necesidad de read-modify-write desde el cliente.

#### Scenario: Incremento de queries sin race condition

- **WHEN** `rpc_increment_ai_usage(userId, 'queries')` se llama
- **THEN** `ai_queries_used` se incrementa en exactamente 1, independientemente de llamadas concurrentes

#### Scenario: Incremento de advice

- **WHEN** `rpc_increment_ai_usage(userId, 'advice')` se llama
- **THEN** `ai_advice_used` se incrementa en exactamente 1

### Requirement: Hook frontend de uso IA

El sistema SHALL proveer un hook `useAiUsage()` en el frontend que exponga los contadores actuales del perfil del usuario (consultas, consejos y lecturas de factura) y el tiempo hasta el próximo reset, para que los componentes de IA muestren cuota restante.

#### Scenario: Usuario ve cuántas consultas le quedan

- **WHEN** un usuario en plan `gratis` usó 3 de 5 consultas
- **THEN** `useAiUsage()` retorna `queriesUsed = 3`, `queriesRemaining = 2`, `adviceRemaining ≥ 0`

#### Scenario: Usuario agotó el límite

- **WHEN** `ai_queries_used >= maxAiQueriesPerMonth`
- **THEN** `queriesRemaining = 0` (no negativo)

#### Scenario: Usuario ve cuántas lecturas de factura le quedan

- **WHEN** un usuario en plan `inicial` usó 12 de 30 lecturas de factura
- **THEN** `useAiUsage()` retorna `ocrUsed = 12` y `ocrRemaining = 18`

#### Scenario: Lecturas de factura agotadas no dan saldo negativo

- **WHEN** `ai_ocr_used >= maxAiOcrPerMonth`
- **THEN** `ocrRemaining = 0`

### Requirement: Reserva atómica de consultas IA
El sistema SHALL aceptar el contador `'queries'` en `rpc_reserve_ai_usage(p_counter text)`: un único `UPDATE` condicional SHALL incrementar `ai_queries_used` sólo si es menor que `max_ai_queries_per_month` del plan efectivo y si la ventana de ráfaga propia (`ai_queries_window_count`, `ai_queries_window_started_at`) admite otra consulta (5 por 60 segundos). La respuesta SHALL tener la misma forma que la del contador `'ocr'` (`{allowed, used, limit, reset_at}` o `{allowed:false, reason:"quota_exceeded"|"rate_limited", …}`), con la misma precedencia (la cuota mensual gana sobre la ráfaga) y los mismos rechazos fail-closed (`P0401`, `22023`, `P0503`). La rama `'ocr'` NOT SHALL cambiar su comportamiento.

#### Scenario: Reservas concurrentes no superan el límite
- **GIVEN** un usuario `gratis` con `ai_queries_used = 4` (límite 5)
- **WHEN** llegan dos reservas `'queries'` concurrentes
- **THEN** exactamente una es concedida y `ai_queries_used` queda en 5

#### Scenario: Ráfaga de consultas
- **GIVEN** un usuario con 5 reservas `'queries'` concedidas en los últimos 60 segundos y cupo mensual disponible
- **WHEN** pide otra
- **THEN** recibe `{allowed:false, reason:"rate_limited", retry_after_seconds}` entre 1 y 60

#### Scenario: La rama del OCR no cambia
- **GIVEN** el mismo estado de `profiles` antes y después de la migración
- **WHEN** se llama `rpc_reserve_ai_usage('ocr')`
- **THEN** la respuesta y el efecto sobre `ai_ocr_*` son idénticos, y `ai_queries_*` no cambia

