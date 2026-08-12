## MODIFIED Requirements

### Requirement: Cálculo mensual de los KPIs con scope por cuenta
El sistema SHALL calcular los KPIs del período activo (mes en curso por defecto) agregando únicamente datos de la cuenta del usuario (`account_id`), sumando el total de cada línea (`COALESCE(total, amount)`). Las notas de crédito del período (`customer_account_movements.movement_type = 'credit_note'`, imputadas por `created_at`) SHALL restarse del ingreso del período (RN-D1).

Cuando el Tablero tiene una sucursal seleccionada, el filtro SHALL aplicarse a todos los términos atribuibles: ventas, gastos, compras, notas de crédito (por la sucursal de su documento origen) y stock sin rotación. El stock sin rotación SHALL calcularse por sucursal sobre `branch_stock` —no sobre el stock agregado de todas las sucursales— valorizando `SUM(cantidad de la sucursal × costo)` y contando productos distintos, y SHALL excluir los productos soft-deleted además de los `untracked` y `variant_only`. Un producto cuenta como "sin rotación" en una sucursal cuando no tuvo ventas en el período en esa sucursal; las ventas legacy sin sucursal asignada cuentan como rotación en cualquier sucursal (fail-open), porque son evidencia real de movimiento y lo contrario marcaría como estancado a casi todo el catálogo.

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

#### Scenario: La nota de crédito de otra sucursal no afecta la seleccionada
- **GIVEN** una cuenta con sucursales A y B, donde A facturó $10.000 y B emitió una NC de $3.000
- **WHEN** se consultan los KPIs con filtro de sucursal A
- **THEN** el ingreso devengado de A es $10.000

#### Scenario: Aislamiento entre cuentas
- **WHEN** un usuario consulta los KPIs
- **THEN** el resultado NUNCA incluye datos de otra cuenta, aunque se manipulen los parámetros de la llamada

### Requirement: Métricas de ingreso devengado y percibido en el resumen KPI
El RPC `rpc_dashboard_kpi_summary` SHALL devolver, además de los KPIs existentes, cuatro columnas nuevas (RN-D3): `invoiced_revenue` y `prev_invoiced_revenue` (devengado = Σ `COALESCE(total, amount)` de ventas del período − Σ NC del período) y `collected_revenue` y `prev_collected_revenue` (percibido = devengado − Σ cargos a cta cte del período + Σ `payments_received` del período). Los parámetros de entrada del RPC NO cambian; la extensión de `RETURNS TABLE` se aplica vía `DROP FUNCTION` + `CREATE` en la misma migración (D4). La tarjeta Ganancia Neta del Tablero SHALL mostrar una línea secundaria "Cobrado: $X" únicamente cuando `collected_revenue ≠ invoiced_revenue`.

Con una sucursal seleccionada, el percibido no es computable (los cobros no son atribuibles a una sucursal, RN-D3): `collected_revenue` y `prev_collected_revenue` SHALL ser `NULL` y la línea secundaria "Cobrado" no SHALL mostrarse, sin que aparezca un cero falso en su lugar.

#### Scenario: Cuenta de contado — cobrado igual a facturado, sin línea secundaria
- **GIVEN** una cuenta sin movimientos de cuenta corriente en el período
- **WHEN** se renderiza la tarjeta Ganancia Neta
- **THEN** el RPC devuelve `collected_revenue = invoiced_revenue`
- **AND** la línea secundaria "Cobrado" no se muestra

#### Scenario: Venta a cuenta corriente separa cobrado de facturado
- **GIVEN** un período con $8.000 de ventas de contado y $2.000 vendidos a cuenta corriente (cargo en cta cte, sin cobro)
- **WHEN** se consulta el resumen KPI del período
- **THEN** `invoiced_revenue = 10000` y `collected_revenue = 8000`
- **AND** la tarjeta Ganancia Neta muestra "Cobrado: $8.000"

#### Scenario: Un cobro de cta cte suma al percibido del período del cobro
- **GIVEN** un `payment_received` de $2.000 registrado en el período por una venta del período anterior
- **WHEN** se consulta el resumen KPI del período
- **THEN** `collected_revenue` incluye los $2.000 y `invoiced_revenue` no los incluye

#### Scenario: Con sucursal seleccionada no se muestra la línea Cobrado
- **GIVEN** una cuenta con movimientos de cuenta corriente en el período
- **WHEN** se consulta el resumen KPI con filtro de sucursal
- **THEN** `collected_revenue` es `NULL`
- **AND** la tarjeta Ganancia Neta no muestra la línea secundaria "Cobrado"

#### Scenario: Los callers existentes no se rompen con las columnas nuevas
- **GIVEN** un frontend desplegado antes de esta migración
- **WHEN** llama a `rpc_dashboard_kpi_summary` con los mismos parámetros de siempre
- **THEN** recibe las columnas previas intactas (las nuevas se ignoran sin error)
