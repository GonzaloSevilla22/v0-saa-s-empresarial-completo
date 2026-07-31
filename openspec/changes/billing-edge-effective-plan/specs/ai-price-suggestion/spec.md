## MODIFIED Requirements

### Requirement: Edge Function `ai-precio` sugiere precio óptimo para un producto

El sistema SHALL proveer la Edge Function `ai-precio` que: recibe `{ product_id: string }` en el body, verifica cuota IA (`ai_queries_used`), consulta las ventas del producto en los últimos 90 días desde `sales` + `sale_items`, calcula la elasticidad implícita (variación de cantidad vendida en función del precio unitario promedio por semana), construye un prompt con ese análisis + costo del catálogo (`products.cost`) + precio actual, llama a `gpt-4o-mini` (RN-32) para obtener precio sugerido y argumento narrativo, inserta el resultado en `ai_insights` con `type = 'oportunidad'` y `metadata.product_id`, e incrementa `ai_queries_used` en 1.

El gate de plan de esta función SHALL evaluarse contra el **plan efectivo de la cuenta** resuelto según la definición normativa de la base de datos, y SHALL determinar la habilitación leyendo el flag `plan_limits.has_price_suggestion` de ese plan. La función NOT SHALL comparar contra una lista de planes hardcodeada ni derivar el plan de `public.profiles`.

#### Scenario: Edge Function retorna sugerencia de precio con argumento narrativo

- **GIVEN** un usuario `avanzado` con cuota disponible y un producto con al menos 3 ventas en los últimos 90 días
- **WHEN** se llama a `POST /functions/v1/ai-precio` con `{ product_id }`
- **THEN** retorna `{ ok: true, suggested_price: number, margin_pct: number, argument: string }` y se inserta un registro en `ai_insights` con `type = 'oportunidad'`

#### Scenario: Edge Function retorna fallback gracioso cuando no hay suficiente historial

- **GIVEN** un usuario `avanzado` con cuota disponible y un producto con menos de 3 ventas en los últimos 90 días
- **WHEN** se llama a `POST /functions/v1/ai-precio`
- **THEN** retorna `{ ok: true, fallback: true, reason: 'insufficient_data' }` sin insertar en `ai_insights` ni incrementar el contador

#### Scenario: Edge Function bloqueada cuando se agotó la cuota mensual

- **GIVEN** un usuario `avanzado` con `ai_queries_used >= max_ai_queries_per_month` (120 para avanzado)
- **WHEN** se llama a `POST /functions/v1/ai-precio`
- **THEN** retorna HTTP 429 `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: Edge Function retorna fallback gracioso si OpenAI no responde en 25s

- **GIVEN** OpenAI no responde dentro del timeout de 25 segundos (RN-31)
- **WHEN** se llama a `POST /functions/v1/ai-precio`
- **THEN** retorna `{ ok: true, fallback: true, reason: 'timeout' }` sin incrementar el contador ni insertar en `ai_insights`

#### Scenario: Edge Function rechaza llamada de usuario sin plan suficiente

- **GIVEN** un usuario cuyo plan efectivo tiene `plan_limits.has_price_suggestion = false` (`'gratis'` o `'inicial'`)
- **WHEN** se llama a `POST /functions/v1/ai-precio`
- **THEN** retorna HTTP 403 `{ ok: false, error: 'plan_required', required_plan: 'avanzado' }`

#### Scenario: La cuenta que pagó accede a la sugerencia de precio

- **GIVEN** una cuenta con `accounts.billing_plan = 'pro'` cuyo registro en `profiles` conserva el valor por defecto `'gratis'`
- **WHEN** un miembro llama a `POST /functions/v1/ai-precio`
- **THEN** la llamada es aceptada, porque el plan efectivo `'pro'` tiene `has_price_suggestion = true`

#### Scenario: La habilitación proviene de la tabla de límites, no del código

- **GIVEN** que el flag `plan_limits.has_price_suggestion` de un plan cambia de valor en la base de datos
- **WHEN** un usuario de ese plan llama a `POST /functions/v1/ai-precio`
- **THEN** la decisión de gating refleja el nuevo valor sin requerir un redeploy de la Edge Function
