## ADDED Requirements

### Requirement: Reset mensual automático de contadores IA

El sistema SHALL resetear `ai_queries_used = 0`, `ai_advice_used = 0`, y `usage_reset_at = now()` en todos los perfiles el primer día de cada mes a las 00:00 UTC, mediante un cron job de pg_cron llamado `reset-ai-counters`.

#### Scenario: Contadores se resetean el primer día del mes

- **WHEN** el cron job `reset-ai-counters` se ejecuta (1° del mes, 00:00 UTC)
- **THEN** todos los perfiles tienen `ai_queries_used = 0`, `ai_advice_used = 0`, `usage_reset_at = now()`

#### Scenario: Usuario que alcanzó el límite puede volver a consultar el mes siguiente

- **WHEN** un usuario `gratis` usó sus 5 consultas IA en enero y el cron corre el 1° de febrero
- **THEN** su `ai_queries_used = 0` y puede realizar nuevas consultas IA

### Requirement: Incremento atómico de contadores IA

El sistema SHALL proveer un RPC `rpc_increment_ai_usage(p_user_id UUID, p_counter TEXT)` que incremente el contador correspondiente en un único UPDATE atómico en la DB, sin necesidad de read-modify-write desde el cliente.

#### Scenario: Incremento de queries sin race condition

- **WHEN** `rpc_increment_ai_usage(userId, 'queries')` se llama
- **THEN** `ai_queries_used` se incrementa en exactamente 1, independientemente de llamadas concurrentes

#### Scenario: Incremento de advice

- **WHEN** `rpc_increment_ai_usage(userId, 'advice')` se llama
- **THEN** `ai_advice_used` se incrementa en exactamente 1

### Requirement: Hook frontend de uso IA

El sistema SHALL proveer un hook `useAiUsage()` en el frontend que exponga los contadores actuales del perfil del usuario y el tiempo hasta el próximo reset, para que los componentes de IA muestren cuota restante.

#### Scenario: Usuario ve cuántas consultas le quedan

- **WHEN** un usuario en plan `gratis` usó 3 de 5 consultas
- **THEN** `useAiUsage()` retorna `queriesUsed = 3`, `queriesRemaining = 2`, `adviceRemaining ≥ 0`

#### Scenario: Usuario agotó el límite

- **WHEN** `ai_queries_used >= maxAiQueriesPerMonth`
- **THEN** `queriesRemaining = 0` (no negativo)
