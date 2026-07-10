# dashboard-kpi-summary Specification

## Purpose

Bloque "Resumen KPI" del Tablero: 5 tarjetas (Ganancia Neta, Margen por Canal, Stock sin Rotación, Costo por Venta, Ticket Promedio) calculadas por `rpc_dashboard_kpi_summary` con scope por cuenta, selector de período y badge de variación contra el mes anterior. Extendido con las invariantes RN-D1/D3 del Modelo V3 (§8): resta de notas de crédito del período y desglose de ingreso devengado vs percibido (`invoiced_revenue`/`collected_revenue`) — ver capability `reporting-invariants`.

## Requirements

### Requirement: Bloque Resumen KPI en el tope del Tablero
El Tablero SHALL mostrar un bloque "Resumen KPI" con 5 tarjetas (Ganancia Neta, Margen por Canal, Stock sin Rotación, Costo por Venta, Ticket Promedio) ubicado encima de la sección "Consejos IA", sin eliminar ni reordenar el contenido existente.

#### Scenario: El bloque aparece arriba de Consejos IA
- **WHEN** el usuario abre el Tablero
- **THEN** las 5 tarjetas KPI se renderizan por encima de la sección "Consejos IA" (AiSummaryCard)
- **AND** las secciones existentes del Tablero permanecen presentes y en su orden previo

#### Scenario: Valores calculados desde datos reales
- **WHEN** el bloque se renderiza para un período con datos
- **THEN** cada tarjeta muestra un valor calculado por el backend (RPC), no un valor estático

### Requirement: Cálculo mensual de los KPIs con scope por cuenta
El sistema SHALL calcular los KPIs del período activo (mes en curso por defecto) agregando únicamente datos de la cuenta del usuario (`account_id`), sumando el total de cada línea (`COALESCE(total, amount)`). Las notas de crédito del período (`customer_account_movements.movement_type = 'credit_note'`, imputadas por `created_at`) SHALL restarse del ingreso del período (RN-D1).

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
- **THEN** cuenta y valoriza (`SUM(stock * cost)`) los productos de la cuenta sin ventas en el período, excluyendo productos `untracked` y `variant_only`

#### Scenario: Aislamiento entre cuentas
- **WHEN** un usuario consulta los KPIs
- **THEN** el resultado NUNCA incluye datos de otra cuenta, aunque se manipulen los parámetros de la llamada

### Requirement: Métricas de ingreso devengado y percibido en el resumen KPI
El RPC `rpc_dashboard_kpi_summary` SHALL devolver, además de los KPIs existentes, cuatro columnas nuevas (RN-D3): `invoiced_revenue` y `prev_invoiced_revenue` (devengado = Σ `COALESCE(total, amount)` de ventas del período − Σ NC del período) y `collected_revenue` y `prev_collected_revenue` (percibido = devengado − Σ cargos a cta cte del período + Σ `payments_received` del período). Los parámetros de entrada del RPC NO cambian; la extensión de `RETURNS TABLE` se aplica vía `DROP FUNCTION` + `CREATE` en la misma migración (D4). La tarjeta Ganancia Neta del Tablero SHALL mostrar una línea secundaria "Cobrado: $X" únicamente cuando `collected_revenue ≠ invoiced_revenue`.

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

#### Scenario: Los callers existentes no se rompen con las columnas nuevas
- **GIVEN** un frontend desplegado antes de esta migración
- **WHEN** llama a `rpc_dashboard_kpi_summary` con los mismos parámetros de siempre
- **THEN** recibe las columnas previas intactas (las nuevas se ignoran sin error)

### Requirement: Badge de variación contra el mes anterior
Cada tarjeta SHALL mostrar un badge de variación comparando el valor del período contra el mismo KPI del mes anterior, con color según la polaridad del KPI.

#### Scenario: Variación favorable
- **WHEN** un KPI con polaridad "subir es bueno" (Ganancia, Margen, Ticket) sube respecto al mes anterior
- **THEN** el badge se muestra en verde (#34D399)

#### Scenario: Variación desfavorable por polaridad invertida
- **WHEN** un KPI con polaridad "subir es malo" (Costo por Venta, Stock sin Rotación) sube respecto al mes anterior
- **THEN** el badge se muestra en rojo (#F87171)

#### Scenario: Sin variación significativa o sin baseline
- **WHEN** la variación es menor al umbral significativo, o no hay valor del mes anterior (baseline 0/nulo)
- **THEN** el badge se muestra en amarillo (#FBBF24)

### Requirement: Selector de período en el Tablero
El Tablero SHALL ofrecer un selector de período (mes en curso por defecto) que afecta el bloque KPI; la selección se refleja en la URL y convive con el filtro de sucursal existente.

#### Scenario: Mes en curso por defecto
- **WHEN** el usuario entra al Tablero sin período seleccionado
- **THEN** el bloque muestra los KPIs del mes en curso

#### Scenario: Cambiar de período recalcula el bloque
- **WHEN** el usuario selecciona otro período
- **THEN** las 5 tarjetas y sus badges se recalculan para ese período y su mes anterior

#### Scenario: Período sin datos
- **WHEN** no hay datos para el período seleccionado
- **THEN** las tarjetas muestran `—` en lugar del valor

### Requirement: Comportamiento responsive del bloque
El bloque SHALL adaptar la grilla por breakpoint sin truncamiento ni scroll horizontal.

#### Scenario: Mobile
- **WHEN** el ancho es menor a 768px
- **THEN** se muestran 2 columnas y la 5ta tarjeta ocupa el ancho completo

#### Scenario: Tablet
- **WHEN** el ancho está entre 768px y 1024px
- **THEN** se muestran 3 columnas

#### Scenario: Web
- **WHEN** el ancho es mayor a 1024px
- **THEN** las 5 tarjetas se muestran en una sola fila (5 columnas)
