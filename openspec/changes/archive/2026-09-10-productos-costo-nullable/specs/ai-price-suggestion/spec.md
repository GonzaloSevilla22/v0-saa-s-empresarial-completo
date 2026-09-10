## MODIFIED Requirements

### Requirement: Edge Function `ai-precio` sugiere precio óptimo para un producto

El sistema SHALL proveer la Edge Function `ai-precio` que: recibe `{ product_id: string }` en el body, verifica cuota IA (`ai_queries_used`), consulta las ventas del producto en los últimos 90 días desde `sales` + `sale_items`, calcula la elasticidad implícita (variación de cantidad vendida en función del precio unitario promedio por semana), construye un prompt con ese análisis + costo del catálogo (`products.cost`) + precio actual, llama a `gpt-4o-mini` (RN-32) para obtener precio sugerido y argumento narrativo, inserta el resultado en `ai_insights` con `type = 'oportunidad'` y `metadata.product_id`, e incrementa `ai_queries_used` en 1.

El gate de plan de esta función SHALL evaluarse contra el **plan efectivo de la cuenta** resuelto según la definición normativa de la base de datos, y SHALL determinar la habilitación leyendo el flag `plan_limits.has_price_suggestion` de ese plan. La función NOT SHALL comparar contra una lista de planes hardcodeada ni derivar el plan de `public.profiles`.

El costo del catálogo es un dato **opcional** (capability `product-cost`). Cuando el producto no tiene costo, la función SHALL **omitir del prompt** la línea de costo y toda instrucción derivada de él (incluida la de no proponer un margen negativo), y NOT SHALL enviar al modelo un costo cero ni una estimación propia: un costo inventado convierte la sugerencia en una recomendación de precio calculada sobre una premisa falsa, que es peor que una sugerencia sin margen.

En ese caso la función SHALL igualmente producir una sugerencia apoyada en la elasticidad y el historial de ventas, SHALL informar el margen proyectado como **ausente** —nunca como 100 %— y SHALL declarar en su respuesta que la sugerencia no considera el margen porque el producto no tiene costo cargado. Negarle el servicio a un producto por un dato que el usuario puede completar después gasta una consulta de su cuota sin devolverle nada.

#### Scenario: Edge Function retorna sugerencia de precio con argumento narrativo

- **GIVEN** un usuario `avanzado` con cuota disponible y un producto con al menos 3 ventas en los últimos 90 días
- **WHEN** se llama a `POST /functions/v1/ai-precio` con `{ product_id }`
- **THEN** retorna `{ ok: true, suggested_price: number, margin_pct: number, argument: string }` y se inserta un registro en `ai_insights` con `type = 'oportunidad'`

#### Scenario: Producto sin costo de catálogo obtiene sugerencia sin margen

- **GIVEN** un usuario `avanzado` con cuota disponible y un producto con historial suficiente y **sin costo cargado**
- **WHEN** se llama a `POST /functions/v1/ai-precio` con `{ product_id }`
- **THEN** retorna una sugerencia de precio con el margen proyectado ausente y una advertencia de que no se consideró el margen por falta de costo
- **AND** NO retorna un margen del 100 %

#### Scenario: El prompt de un producto sin costo no contiene un costo cero

- **GIVEN** un producto sin costo cargado
- **WHEN** la función arma el prompt que envía al modelo
- **THEN** el prompt no contiene ninguna línea de costo del catálogo ni la instrucción de mantener el margen no negativo
- **AND** no contiene un costo `0` ni ningún valor de costo estimado por la función

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

### Requirement: Modal `PriceSuggestionModal` muestra el resultado de la sugerencia

El sistema SHALL proveer el componente `PriceSuggestionModal` que acepta `{ productId, productName, isOpen, onClose }`, llama a la Edge Function `ai-precio` al montarse (cuando `isOpen = true`), y muestra: precio sugerido (en ARS formateado), margen proyectado con ese precio, argumento narrativo de la IA, y mensaje de disclaimer ("Esta es una sugerencia basada en tu historial. La decisión final es tuya.").

Cuando la respuesta trae el margen proyectado **ausente** (producto sin costo de catálogo), el modal SHALL mostrar el precio sugerido y el argumento igual, SHALL mostrar el margen como ausente ("—") y SHALL explicar en una línea que la sugerencia no considera el margen porque el producto no tiene costo cargado. NOT SHALL fallar al formatear el margen ausente ni presentarlo como cero o como 100 %.

#### Scenario: Modal muestra sugerencia de precio exitosa

- **GIVEN** el modal se abre para un producto con historial suficiente
- **WHEN** la Edge Function retorna una sugerencia
- **THEN** el modal muestra el precio sugerido en ARS, el margen proyectado en %, el argumento narrativo y el disclaimer

#### Scenario: Modal muestra la sugerencia de un producto sin costo sin romperse

- **GIVEN** el modal se abre para un producto sin costo cargado
- **WHEN** la Edge Function retorna la sugerencia con el margen proyectado ausente
- **THEN** el modal se renderiza completo, con el precio sugerido y el argumento
- **AND** muestra el margen como "—" junto a la explicación de que falta el costo del producto

#### Scenario: Modal muestra mensaje de datos insuficientes

- **GIVEN** el modal se abre para un producto con menos de 3 ventas en 90 días
- **WHEN** la Edge Function retorna `fallback: true, reason: 'insufficient_data'`
- **THEN** el modal muestra "No hay suficiente historial de ventas para sugerir un precio. Registrá al menos 3 ventas en los últimos 90 días."

#### Scenario: Modal muestra estado de carga mientras espera la respuesta

- **GIVEN** el modal se abre y la Edge Function está procesando
- **WHEN** la llamada está en vuelo
- **THEN** el modal muestra un spinner de carga y deshabilita el botón de cierre hasta recibir respuesta
