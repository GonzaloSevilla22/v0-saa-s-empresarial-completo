## ADDED Requirements

### Requirement: RPC de cálculo de rentabilidad por SKU

El sistema SHALL proveer el RPC `rpc_product_profitability(p_period_days INT DEFAULT 30)` que calcula para cada producto de la cuenta activa: `total_revenue`, `total_cost`, `gross_margin`, `gross_margin_pct`, `units_sold`, `last_sale_date`. El RPC deriva el `account_id` internamente desde `current_account_ids()` — no acepta parámetros de identidad. El costo SHALL derivarse del snapshot de costo congelado en la línea (`unit_cost_snapshot`), no del maestro actual (RN-D2), con una cascada de fallback: (1) `unit_cost_snapshot` de la línea cuando está presente; (2) `products.cost` actual sólo cuando el snapshot es NULL (líneas muy antiguas no backfilleadas). Las líneas con `snapshot_backfilled = true` SHALL usar su snapshot aunque sea aproximado, en lugar del maestro actual.

#### Scenario: RPC calcula margen desde el snapshot de costo de la línea

- **GIVEN** un producto vendido cuya línea congeló `unit_cost_snapshot = 600` y `SUM(revenue) = 1000` en los últimos 30 días
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el producto aparece con `total_revenue = 1000`, `total_cost` derivado de `unit_cost_snapshot` (no de `products.cost` actual), `gross_margin = 400` y `gross_margin_pct = 40.0`

#### Scenario: Remarcar el maestro no altera el margen histórico

- **GIVEN** una venta cuya línea congeló `unit_cost_snapshot = 600`
- **WHEN** `products.cost` sube a `900` y luego se llama a `rpc_product_profitability(30)`
- **THEN** el `total_cost` del período que contiene esa venta sigue basado en `600`, no en `900`

#### Scenario: Fallback a costo de catálogo cuando la línea no tiene snapshot

- **GIVEN** una venta antigua cuya línea tiene `unit_cost_snapshot = NULL` (no backfilleada), con `products.cost = 50` y `units_sold = 10`
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el `total_cost` de esa línea usa `products.cost` como último recurso (50 × 10 = 500)

#### Scenario: Solo se incluyen productos con al menos una venta en el período

- **GIVEN** la cuenta tiene 20 productos pero solo 12 tuvieron ventas en los últimos 30 días
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el resultado contiene exactamente 12 productos

#### Scenario: Usuario sin cuenta activa no puede llamar al RPC

- **GIVEN** un usuario autenticado sin membership activa
- **WHEN** llama a `rpc_product_profitability(30)`
- **THEN** el RPC lanza excepción con ERRCODE = 'P403'

### Requirement: Edge Function `ai-rentabilidad` genera análisis IA de margen

El sistema SHALL proveer la Edge Function `ai-rentabilidad` que: verifica cuota IA (counter `'queries'`), llama al RPC de profitability, envía los top 5 / bottom 5 productos por margen a OpenAI, inserta el insight generado en `ai_insights` (type=`'margen'`) e incrementa el contador.

#### Scenario: Edge Function genera insight con top y bottom performers

- **GIVEN** un usuario `avanzado` con cuota disponible y datos de profitability
- **WHEN** llama a `ai-rentabilidad`
- **THEN** se inserta un registro en `ai_insights` con `type = 'margen'` y el análisis de los productos más y menos rentables

#### Scenario: Edge Function bloqueada cuando se agotó la cuota

- **GIVEN** un usuario `avanzado` con `ai_queries_used >= max_ai_queries_per_month`
- **WHEN** llama a `ai-rentabilidad`
- **THEN** retorna HTTP 429 `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: Edge Function retorna fallback si OpenAI no responde

- **GIVEN** OpenAI no responde en 25 segundos
- **WHEN** llama a `ai-rentabilidad`
- **THEN** retorna `{ ok: true, fallback: true }` sin incrementar el contador ni insertar en `ai_insights`

### Requirement: Página `/rentabilidad` con tabla, gráfico y análisis IA

El sistema SHALL proveer la página `/rentabilidad` con:
- Tabla de productos ordenada por `gross_margin_pct` (desc), mostrando nombre, revenue, costo, margen %, unidades vendidas
- Bar chart horizontal (Recharts) con los top 10 productos por margen
- Panel con el último insight IA (type=`'margen'`) y botón "Analizar con IA"
- **Botón "Sugerir precio IA" en cada fila de la tabla**, que abre el `PriceSuggestionModal` para ese producto
- Gating: solo accesible para `'avanzado'` y `'pro'`; para planes inferiores muestra `<PlanGate requiredPlan="avanzado" />`

#### Scenario: Usuario avanzado ve la tabla de rentabilidad completa con botón de precio

- **GIVEN** un usuario con plan efectivo `'avanzado'`
- **WHEN** navega a `/rentabilidad`
- **THEN** ve la tabla con sus productos ordenados por margen, el gráfico de barras, el panel de análisis IA y el botón "Sugerir precio IA" en cada fila

#### Scenario: Usuario gratis ve el componente de upgrade en lugar del contenido

- **GIVEN** un usuario con plan efectivo `'gratis'`
- **WHEN** navega a `/rentabilidad`
- **THEN** ve el componente `PlanGate` con el mensaje de upgrade y un CTA al plan Avanzado; el contenido real no se renderiza

#### Scenario: Botón "Analizar con IA" llama a la Edge Function y muestra el insight

- **GIVEN** un usuario avanzado con cuota disponible en la página `/rentabilidad`
- **WHEN** hace clic en "Analizar con IA"
- **THEN** se llama a `ai-rentabilidad`, el botón muestra estado de carga, y al completarse aparece el análisis en el panel

#### Scenario: Período de análisis respeta el historial máximo del plan

- **GIVEN** un usuario con plan `'inicial'` (12 meses de historial)
- **WHEN** carga `/rentabilidad` con el período por defecto
- **THEN** el RPC solo incluye ventas dentro del rango permitido por el plan

#### Scenario: Botón "Sugerir precio IA" abre el modal con el producto correcto

- **GIVEN** un usuario avanzado en la tabla de `/rentabilidad`
- **WHEN** hace clic en "Sugerir precio IA" en la fila del producto "Medialunas"
- **THEN** se abre el `PriceSuggestionModal` con `productName = "Medialunas"` y comienza a cargar la sugerencia
