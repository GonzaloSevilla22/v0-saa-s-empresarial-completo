## MODIFIED Requirements

### Requirement: Cálculo mensual de los KPIs con scope por cuenta
El sistema SHALL calcular los KPIs del período activo (mes en curso por defecto) agregando únicamente datos de la cuenta del usuario (`account_id`), sumando el total de cada línea (`COALESCE(total, amount)`). Las notas de crédito del período (`customer_account_movements.movement_type = 'credit_note'`, imputadas por `created_at`) SHALL restarse del ingreso del período (RN-D1).

Cuando el Tablero tiene una sucursal seleccionada, el filtro SHALL aplicarse a todos los términos atribuibles: ventas, gastos, compras, notas de crédito (por la sucursal de su documento origen) y stock sin rotación. El stock sin rotación SHALL calcularse por sucursal sobre `branch_stock` —no sobre el stock agregado de todas las sucursales— valorizando `SUM(cantidad de la sucursal × costo)` y contando productos distintos, y SHALL excluir los productos soft-deleted además de los `untracked` y `variant_only`. Un producto cuenta como "sin rotación" en una sucursal cuando no tuvo ventas en el período en esa sucursal; las ventas legacy sin sucursal asignada cuentan como rotación en cualquier sucursal (fail-open), porque son evidencia real de movimiento y lo contrario marcaría como estancado a casi todo el catálogo.

El costo del catálogo es un dato **opcional** (capability `product-cost`). Un producto sin costo NOT SHALL anular la valorización del stock sin rotación —dejaría el KPI en blanco para toda cuenta con un solo producto sin costo— y SHALL aportar cero a ese total. Junto al valor y al conteo de productos, el read-model SHALL informar **cuántos de esos productos no tienen costo cargado**, y la superficie SHALL mostrarlo: un total del que no se sabe qué proporción quedó sin valorizar no es auditable por quien lo lee.

#### Scenario: Ganancia Neta del mes
- **WHEN** se calcula la Ganancia Neta del período
- **THEN** es `(SUM(ventas.total) − SUM(NC del período)) − (SUM(gastos.amount) + SUM(compras.total))` del período, solo de la cuenta del usuario

#### Scenario: Una nota de crédito reduce la Ganancia Neta del período de su emisión
- **GIVEN** un período con $10.000 en ventas y una NC de $1.000 emitida dentro del período
- **WHEN** se calcula la Ganancia Neta
- **THEN** el ingreso considerado es $9.000

#### Scenario: Ticket Promedio del mes
- **WHEN** se calcula el Ticket Promedio
- **THEN** es `SUM(ventas.total) / COUNT(DISTINCT operación de venta)` del período

#### Scenario: Stock sin Rotación del mes
- **WHEN** se calcula Stock sin Rotación
- **THEN** cuenta y valoriza (`SUM(stock * cost)`) los productos de la cuenta sin ventas en el período, excluyendo productos `untracked`, `variant_only` y soft-deleted

#### Scenario: Stock sin Rotación con una sucursal seleccionada
- **GIVEN** un producto sin ventas en el período, con 10 unidades en la sucursal A y 40 en la sucursal B, a un costo de $100
- **WHEN** se consulta Stock sin Rotación con filtro de sucursal A
- **THEN** el valor informado es $1.000 (solo el stock de A)
- **AND** sin filtro de sucursal el valor es $5.000 y el producto cuenta una sola vez

#### Scenario: Stock sin Rotación declara los productos sin costo
- **GIVEN** un período con 5 productos sin rotación, de los cuales 2 no tienen costo cargado
- **WHEN** se consulta Stock sin Rotación
- **THEN** el valor informado suma únicamente los 3 productos con costo
- **AND** el read-model informa que 2 de los 5 productos no tienen costo, y la superficie lo muestra junto al conteo

#### Scenario: La nota de crédito de otra sucursal no afecta la seleccionada
- **GIVEN** una cuenta con sucursales A y B, donde A facturó $10.000 y B emitió una NC de $3.000
- **WHEN** se consultan los KPIs con filtro de sucursal A
- **THEN** el ingreso devengado de A es $10.000

#### Scenario: Aislamiento entre cuentas
- **WHEN** un usuario consulta los KPIs
- **THEN** el resultado NUNCA incluye datos de otra cuenta, aunque se manipulen los parámetros de la llamada
