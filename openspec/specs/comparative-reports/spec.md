## ADDED Requirements

### Requirement: RPC de comparación de métricas entre dos períodos

El sistema SHALL proveer el RPC `rpc_period_comparison(p_a_start DATE, p_a_end DATE, p_b_start DATE, p_b_end DATE)` que calcula para la cuenta activa, en cada período: `period_a_revenue`, `period_a_expenses`, `period_a_purchases`, `period_a_operations`, y los equivalentes `period_b_*`, más los deltas porcentuales `revenue_delta_pct`, `expenses_delta_pct`, `purchases_delta_pct`, `operations_delta_pct`. El RPC deriva el `account_id` internamente desde `current_account_ids()` — no acepta parámetros de identidad.

#### Scenario: RPC calcula totales correctos para dos períodos sin solapamiento

- **GIVEN** una cuenta con ventas de $1000 en enero y $1500 en febrero
- **WHEN** se llama a `rpc_period_comparison('2026-01-01','2026-01-31','2026-02-01','2026-02-28')`
- **THEN** retorna `period_a_revenue = 1000`, `period_b_revenue = 1500`, `revenue_delta_pct = 50.0`

#### Scenario: RPC retorna delta NULL cuando el período A tiene valor cero

- **GIVEN** una cuenta sin ventas en el período A y ventas en el período B
- **WHEN** se llama al RPC con esos rangos
- **THEN** `revenue_delta_pct` es NULL (no se divide por cero)

#### Scenario: Usuario sin cuenta activa no puede llamar al RPC

- **GIVEN** un usuario autenticado sin membership activa
- **WHEN** llama a `rpc_period_comparison(...)`
- **THEN** el RPC lanza excepción con ERRCODE = 'P403'

#### Scenario: Períodos solapados devuelven datos matemáticamente correctos

- **GIVEN** períodos A y B que comparten días
- **WHEN** se llama al RPC
- **THEN** cada período suma independientemente sus propias filas — no hay deduplicación ni error

### Requirement: Edge Function `ai-comparativo` genera análisis IA de variaciones

El sistema SHALL proveer la Edge Function `ai-comparativo` que: verifica cuota IA (counter `'queries'`), llama a `rpc_period_comparison` con los parámetros recibidos del body, construye un resumen de las métricas de ambos períodos, lo envía a GPT-4o-mini solicitando análisis narrativo en español con acciones concretas, inserta el resultado en `ai_insights` (type=`'comparativo'`, priority=`'alta'`), e incrementa el contador.

#### Scenario: Edge Function genera insight con análisis de variaciones

- **GIVEN** un usuario `avanzado` con cuota disponible y datos en ambos períodos
- **WHEN** llama a `ai-comparativo` con dos rangos de fechas válidos
- **THEN** se inserta un registro en `ai_insights` con `type = 'comparativo'` y un análisis de los cambios entre períodos

#### Scenario: Edge Function bloqueada cuando se agotó la cuota

- **GIVEN** un usuario con `ai_queries_used >= max_ai_queries_per_month`
- **WHEN** llama a `ai-comparativo`
- **THEN** retorna HTTP 429 `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: Edge Function retorna fallback si OpenAI no responde en 25 segundos

- **GIVEN** OpenAI no responde dentro del timeout
- **WHEN** llama a `ai-comparativo`
- **THEN** retorna `{ ok: true, fallback: true }` sin incrementar el contador ni insertar en `ai_insights`

### Requirement: Página `/reportes/comparativo` con KPIs, chart y análisis IA

El sistema SHALL proveer la página `/reportes/comparativo` con:
- Selectores de fecha para dos períodos (Período A y Período B); por defecto: Período A = mes actual, Período B = mes anterior; el rango máximo seleccionable respeta `historyDays` del plan.
- Cuatro cards de KPI (ventas, gastos, compras, operaciones): valor en Período A, valor en Período B, delta % con badge verde/rojo.
- BarChart agrupado (Recharts) con dos barras por métrica (una por período).
- Panel con el último insight IA (type=`'comparativo'`) y botón "Analizar con IA".
- Gating: solo accesible para `'avanzado'` y `'pro'`; para planes inferiores muestra `PlanGateFallback`.

#### Scenario: Usuario avanzado ve el reporte comparativo completo

- **GIVEN** un usuario con plan efectivo `'avanzado'`
- **WHEN** navega a `/reportes/comparativo`
- **THEN** ve los KPI cards con deltas, el BarChart agrupado y el panel de análisis IA

#### Scenario: Usuario gratis ve el componente de upgrade

- **GIVEN** un usuario con plan efectivo `'gratis'`
- **WHEN** navega a `/reportes/comparativo`
- **THEN** ve `PlanGateFallback` con CTA al plan Avanzado y no accede al contenido del reporte

#### Scenario: Delta positivo en ventas se muestra en verde, negativo en rojo

- **GIVEN** un usuario avanzado con período B con más ventas que período A
- **WHEN** carga la página
- **THEN** el badge de delta de ventas es verde con el valor `+X%`; si período B tiene menos ventas, el badge es rojo con `-X%`

#### Scenario: Delta NULL se muestra como "N/A"

- **GIVEN** el período A no tiene ventas (división por cero en el RPC)
- **WHEN** carga la página
- **THEN** el badge de delta de ventas muestra "N/A" en lugar de un porcentaje

#### Scenario: Selector de fechas respeta el historial máximo del plan

- **GIVEN** un usuario `'avanzado'` con `historyDays = 180`
- **WHEN** intenta seleccionar una fecha anterior a 180 días
- **THEN** el date picker deshabilita esas fechas y no permite seleccionarlas

#### Scenario: Advertencia cuando los períodos se solapan

- **GIVEN** el usuario selecciona períodos que comparten días
- **WHEN** carga los datos
- **THEN** se muestra un banner de advertencia indicando que los períodos se superponen
