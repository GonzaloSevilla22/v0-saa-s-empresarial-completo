## MODIFIED Requirements

### Requirement: Reset mensual automático de contadores IA

El sistema SHALL resetear `ai_queries_used = 0`, `ai_advice_used = 0`, `ai_ocr_used = 0`, `ai_ocr_window_count = 0`, `ai_ocr_window_started_at = NULL` y `usage_reset_at = now()` en todos los perfiles el primer día de cada mes a las 00:00 UTC, mediante un cron job de pg_cron llamado `reset-ai-counters`.

#### Scenario: Contadores se resetean el primer día del mes

- **WHEN** el cron job `reset-ai-counters` se ejecuta (1° del mes, 00:00 UTC)
- **THEN** todos los perfiles tienen `ai_queries_used = 0`, `ai_advice_used = 0`, `ai_ocr_used = 0`, `ai_ocr_window_count = 0`, `ai_ocr_window_started_at = NULL`, `usage_reset_at = now()`

#### Scenario: Usuario que alcanzó el límite puede volver a consultar el mes siguiente

- **WHEN** un usuario `gratis` usó sus 5 consultas IA en enero y el cron corre el 1° de febrero
- **THEN** su `ai_queries_used = 0` y puede realizar nuevas consultas IA

#### Scenario: Usuario que agotó sus lecturas de factura puede volver a leer el mes siguiente

- **WHEN** un usuario `gratis` usó sus 5 lecturas de factura en noviembre y el cron corre el 1° de diciembre
- **THEN** su `ai_ocr_used = 0` y puede leer facturas de nuevo

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
