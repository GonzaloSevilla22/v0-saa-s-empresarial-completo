# reporting-invariants Specification

## Purpose

Invariantes transversales RN-D1..D5 del Modelo V3 (§8) que todo read-model financiero SHALL cumplir: exclusión de documentos cancelados y resta de notas de crédito (RN-D1), revenue de línea consistente (`COALESCE(total, amount)`), ingresos percibidos vs devengados (RN-D3), dinero siempre `NUMERIC` (RN-D4), y bordes de período en fecha local del tenant (RN-D5). Auditado y corregido en `rpc_dashboard_kpi_summary`, `rpc_product_profitability`, `rpc_period_comparison` y `rpc_branch_report` (migración `20260814000001`, 2026-07-06/07). Incluye la especificación de `rpc_branch_report`, que no tenía capability propia.

## Requirements

### Requirement: RN-D1 — Documentos cancelados jamás suman; las notas de crédito restan
Ningún read-model financiero SHALL incluir documentos cancelados/anulados en ingresos, costos ni cantidades. Las ventas legacy se anulan por DELETE físico con reposición de stock (quedan fuera por construcción); las `sales_orders` en estado `canceled` nunca escriben filas en `sales`. Las notas de crédito (registradas en `customer_account_movements` con `movement_type = 'credit_note'`) SHALL restarse del revenue del período en el que fueron emitidas (`created_at`) en los read-models de ingresos (`rpc_dashboard_kpi_summary`, `rpc_period_comparison`). Excepción documentada: `rpc_dashboard_channel_margin` no resta NC hasta que exista una regla de atribución por canal (las NC no tienen canal — decisión D6).

#### Scenario: Una nota de crédito resta del revenue del período de su emisión
- **GIVEN** una cuenta con $10.000 facturados en julio y una NC de $1.000 emitida en julio
- **WHEN** se calcula el revenue de julio en el dashboard o el comparativo
- **THEN** el revenue del período es $9.000 (la NC resta)
- **AND** el revenue de junio no cambia (la NC se imputa al período de emisión, no al de la venta original)

#### Scenario: Una orden cancelada no aporta a ningún KPI
- **GIVEN** una `sales_order` en estado `canceled` (nunca confirmada)
- **WHEN** se calcula cualquier KPI de ingresos, costos u operaciones
- **THEN** la orden no aporta filas a `sales` y por lo tanto no suma en ningún read-model

### Requirement: Revenue de línea consistente en todos los read-models
Todo read-model financiero que agregue ingresos desde la tabla `sales` SHALL sumar el total de línea con `COALESCE(total, amount)` — nunca `amount` solo (que es precio unitario en filas modernas). La misma regla aplica a `purchases` para costos de compra agregados. Convención de fallback: en filas legacy sin `total`, `amount` representa el total de línea.

#### Scenario: Venta multi-unidad suma su total de línea, no el precio unitario
- **GIVEN** una venta de 2 unidades a precio unitario $1.000 (fila con `amount = 1000`, `quantity = 2`, `total = 2000`)
- **WHEN** cualquier RPC de reporting agrega el revenue del período
- **THEN** esa línea aporta $2.000 al revenue (no $1.000)

#### Scenario: Fila legacy sin total usa amount como total de línea
- **GIVEN** una fila de venta legacy con `total = NULL` y `amount = 500`
- **WHEN** se agrega el revenue del período
- **THEN** la línea aporta $500 (fallback documentado)

### Requirement: RN-D3 — Ingresos percibidos y devengados como métricas separadas
El sistema SHALL distinguir: **devengado** (`invoiced_revenue`) = Σ `COALESCE(total, amount)` de ventas del período − Σ NC del período; **percibido** (`collected_revenue`) = devengado − Σ cargos a cuenta corriente del período (`customer_account_movements.movement_type = 'charge'`) + Σ cobros del período (`payments_received.created_at` en el período). Semántica de caja: un cobro suma al percibido del período en que se registra, aunque la venta sea de un período anterior. La rama `mp_status = approved` de RN-D3 es N/A: no existe pasarela de cobro MercadoPago a clientes finales (MP procesa solo el billing de la plataforma).

#### Scenario: Venta a cuenta corriente devenga pero no percibe
- **GIVEN** una venta de $5.000 confirmada a cuenta corriente (cargo de $5.000 en `customer_account_movements`) en el período
- **WHEN** se calculan las métricas del período
- **THEN** `invoiced_revenue` incluye los $5.000 y `collected_revenue` no los incluye

#### Scenario: El cobro de cta cte percibe en el período del cobro
- **GIVEN** la venta anterior, cobrada con un `payment_received` de $5.000 el mes siguiente
- **WHEN** se calculan las métricas del mes siguiente
- **THEN** `collected_revenue` del mes siguiente incluye los $5.000 y `invoiced_revenue` de ese mes no los incluye

#### Scenario: Cuenta sin cuenta corriente percibe todo lo devengado
- **GIVEN** una cuenta cuyas ventas son todas de contado (sin movimientos de cta cte)
- **WHEN** se calculan las métricas de cualquier período
- **THEN** `collected_revenue = invoiced_revenue`

### Requirement: RN-D5 — Bordes de período con semántica de fecha local del tenant
Todo filtro de período en read-models SHALL interpretar los bordes como días calendario completos en la fecha local del tenant (constante de plataforma `America/Argentina/Mendoza` mientras no exista timezone por organización). Los rangos con parámetros `DATE` SHALL incluir el día final completo (comparación `< p_end + 1 día`, no `<= p_end` casteado a medianoche UTC). Las ventanas relativas ("últimos N días") SHALL anclarse a la fecha local del tenant vía el helper `reporting_local_today()`, no a `CURRENT_DATE` del servidor (UTC).

#### Scenario: Fila con hora real en el último día del rango queda incluida
- **GIVEN** una venta registrada el 2026-07-31 a las 15:00 UTC y un reporte con rango que termina el 2026-07-31
- **WHEN** se ejecuta el RPC con ese rango
- **THEN** la venta está incluida en los totales del período

#### Scenario: Ventana relativa anclada a la fecha local, no a UTC
- **GIVEN** son las 22:00 hora Argentina del 2026-07-15 (01:00 UTC del 2026-07-16)
- **WHEN** se calcula una ventana de "últimos 30 días"
- **THEN** la ventana se ancla al 2026-07-15 local (no al 2026-07-16 UTC)

### Requirement: RN-D4 — Dinero siempre NUMERIC en los read-models
Todo valor monetario devuelto por un read-model SHALL ser de tipo `NUMERIC` (nunca `float`/`real`/`double precision`), de punta a punta: columnas fuente, agregaciones y columnas de salida del RPC.

#### Scenario: Las columnas monetarias de salida son NUMERIC
- **WHEN** se inspecciona el tipo de retorno de cualquier RPC de reporting financiero
- **THEN** toda columna que represente dinero es `NUMERIC`

### Requirement: Reporte por sucursal con revenue y operaciones consistentes
El RPC `rpc_branch_report(p_account_id, p_start, p_end)` SHALL calcular por sucursal: `total_sales` = Σ `COALESCE(total, amount)` de ventas del rango, `total_expenses` = Σ gastos del rango, y `operation_count` = `COUNT(DISTINCT COALESCE(operation_id, id))` (las ventas legacy sin `operation_id` cuentan una operación cada una). El rango SHALL incluir el día final completo (RN-D5). La verificación de membership del caller sobre `p_account_id` se conserva sin cambios.

#### Scenario: Venta legacy sin operation_id cuenta como una operación
- **GIVEN** una sucursal con 3 ventas modernas de una misma operación y 2 ventas legacy con `operation_id = NULL`
- **WHEN** se ejecuta `rpc_branch_report` sobre el rango que las contiene
- **THEN** `operation_count = 3` (1 operación moderna + 2 legacy)

#### Scenario: El revenue por sucursal suma totales de línea
- **GIVEN** una sucursal con una única venta de 2 unidades a $1.000 (`total = 2000`)
- **WHEN** se ejecuta `rpc_branch_report`
- **THEN** `total_sales = 2000`

### Requirement: Conteo de operaciones unificado en read-models
Todo read-model que cuente "operaciones" sobre `sales` o `purchases` SHALL usar `COUNT(DISTINCT COALESCE(operation_id, id))` — una operación multi-línea cuenta una sola vez y las filas legacy sin `operation_id` cuentan una cada una. Para `expenses` (sin `operation_id`) se cuenta por fila.

#### Scenario: Venta multi-línea cuenta como una operación
- **GIVEN** una venta de 3 productos registrada en una sola operación (3 filas en `sales` con el mismo `operation_id`)
- **WHEN** cualquier RPC de reporting cuenta las operaciones del período
- **THEN** esa venta aporta exactamente 1 al conteo de operaciones
