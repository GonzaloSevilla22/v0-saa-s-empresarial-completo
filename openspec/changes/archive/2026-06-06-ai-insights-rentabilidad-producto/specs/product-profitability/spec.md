## ADDED Requirements

### Requirement: RPC de cálculo de rentabilidad por SKU

El sistema SHALL proveer el RPC `rpc_product_profitability(p_period_days INT DEFAULT 30)` que calcula para cada producto de la cuenta activa: `total_revenue`, `total_cost`, `gross_margin`, `gross_margin_pct`, `units_sold`, `last_sale_date`. El RPC deriva el `account_id` internamente desde `current_account_ids()` — no acepta parámetros de identidad.

#### Scenario: RPC calcula margen para productos con compras y ventas registradas

- **GIVEN** un producto con `SUM(sales.total) = 1000` y `SUM(purchases.total) = 600` en los últimos 30 días
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el producto aparece con `total_revenue = 1000`, `total_cost = 600`, `gross_margin = 400`, `gross_margin_pct = 40.0`

#### Scenario: RPC usa costo de catálogo como fallback cuando no hay compras

- **GIVEN** un producto con ventas pero sin registros en `purchases` — `products.cost = 50`, `units_sold = 10`
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el producto aparece con `total_cost = 500` (50 × 10) y el margen calculado desde ese costo

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
- Gating: solo accesible para `'avanzado'` y `'pro'`; para planes inferiores muestra `<PlanGate requiredPlan="avanzado" />`

#### Scenario: Usuario avanzado ve la tabla de rentabilidad completa

- **GIVEN** un usuario con plan efectivo `'avanzado'`
- **WHEN** navega a `/rentabilidad`
- **THEN** ve la tabla con sus productos ordenados por margen, el gráfico de barras y el panel de análisis IA

#### Scenario: Usuario gratis ve el componente de upgrade en lugar del contenido

- **GIVEN** un usuario con plan efectivo `'gratis'`
- **WHEN** navega a `/rentabilidad`
- **THEN** ve el componente `PlanGate` con el mensaje de upgrade y un CTA al plan Avanzado; el contenido real no se renderiza

#### Scenario: Botón "Analizar con IA" llama a la Edge Function y muestra el insight

- **GIVEN** un usuario avanzado con cuota disponible en la página `/rentabilidad`
- **WHEN** hace clic en "Analizar con IA"
- **THEN** se llama a `ai-rentabilidad`, el botón muestra estado de carga, y al completarse aparece el análisis en el panel

#### Scenario: Período de análisis respeta el historial máximo del plan

- **GIVEN** un usuario `'gratis'` con `historyDays = 30`
- **WHEN** navega a la página (aunque esté gateada, si fuera accesible)
- **THEN** el RPC recibe `p_period_days = 30` (el máximo de su plan)
