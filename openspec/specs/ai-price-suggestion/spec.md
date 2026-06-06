## ADDED Requirements

### Requirement: Edge Function `ai-precio` sugiere precio óptimo para un producto

El sistema SHALL proveer la Edge Function `ai-precio` que: recibe `{ product_id: string }` en el body, verifica cuota IA (`ai_queries_used`), consulta las ventas del producto en los últimos 90 días desde `sales` + `sale_items`, calcula la elasticidad implícita (variación de cantidad vendida en función del precio unitario promedio por semana), construye un prompt con ese análisis + costo del catálogo (`products.cost`) + precio actual, llama a `gpt-4o-mini` (RN-32) para obtener precio sugerido y argumento narrativo, inserta el resultado en `ai_insights` con `type = 'oportunidad'` y `metadata.product_id`, e incrementa `ai_queries_used` en 1.

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

- **GIVEN** un usuario con plan efectivo `'gratis'` o `'inicial'`
- **WHEN** se llama a `POST /functions/v1/ai-precio`
- **THEN** retorna HTTP 403 `{ ok: false, error: 'plan_required', required_plan: 'avanzado' }`

### Requirement: Modal `PriceSuggestionModal` muestra el resultado de la sugerencia

El sistema SHALL proveer el componente `PriceSuggestionModal` que acepta `{ productId, productName, isOpen, onClose }`, llama a la Edge Function `ai-precio` al montarse (cuando `isOpen = true`), y muestra: precio sugerido (en ARS formateado), margen proyectado con ese precio, argumento narrativo de la IA, y mensaje de disclaimer ("Esta es una sugerencia basada en tu historial. La decisión final es tuya.").

#### Scenario: Modal muestra sugerencia de precio exitosa

- **GIVEN** el modal se abre para un producto con historial suficiente
- **WHEN** la Edge Function retorna una sugerencia
- **THEN** el modal muestra el precio sugerido en ARS, el margen proyectado en %, el argumento narrativo y el disclaimer

#### Scenario: Modal muestra mensaje de datos insuficientes

- **GIVEN** el modal se abre para un producto con menos de 3 ventas en 90 días
- **WHEN** la Edge Function retorna `fallback: true, reason: 'insufficient_data'`
- **THEN** el modal muestra "No hay suficiente historial de ventas para sugerir un precio. Registrá al menos 3 ventas en los últimos 90 días."

#### Scenario: Modal muestra estado de carga mientras espera la respuesta

- **GIVEN** el modal se abre y la Edge Function está procesando
- **WHEN** la llamada está en vuelo
- **THEN** el modal muestra un spinner de carga y deshabilita el botón de cierre hasta recibir respuesta

### Requirement: Gating UI — feature visible solo para `avanzado` y `pro`

El sistema SHALL ocultar el botón "Sugerir precio IA" y el modal para usuarios con plan efectivo `'gratis'` o `'inicial'`. En su lugar mostrará el componente `<PlanGate requiredPlan="avanzado" />` con CTA de upgrade.

#### Scenario: Botón "Sugerir precio IA" visible para usuario avanzado

- **GIVEN** un usuario con plan efectivo `'avanzado'`
- **WHEN** navega a `/productos/[id]` o a `/rentabilidad`
- **THEN** el botón "Sugerir precio IA" está visible y habilitado

#### Scenario: Botón "Sugerir precio IA" no visible para usuario gratis

- **GIVEN** un usuario con plan efectivo `'gratis'`
- **WHEN** navega a `/productos/[id]`
- **THEN** el botón "Sugerir precio IA" no existe en el DOM o está reemplazado por el `PlanGate`
