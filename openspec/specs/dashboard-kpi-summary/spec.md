# dashboard-kpi-summary Specification

## Purpose

Bloque "Resumen KPI" del Tablero: 5 tarjetas (Ganancia Neta, Margen por Canal, Stock sin Rotación, Costo por Venta, Ticket Promedio) calculadas por `rpc_dashboard_kpi_summary` con scope por cuenta, selector de período y badge de variación contra el mes anterior. Extendido con las invariantes RN-D1/D3 del Modelo V3 (§8): resta de notas de crédito del período y desglose de ingreso devengado vs percibido (`invoiced_revenue`/`collected_revenue`) — ver capability `reporting-invariants`. Debajo del bloque, la fila de tarjetas financieras del mes del período seleccionado (Ventas, Gastos y Ganancia neta del mes), calculadas por `get_dashboard_financials`.

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
El Tablero SHALL ofrecer un selector de período (mes en curso por defecto) que afecta el bloque KPI y las tres tarjetas financieras del mes (requirement "Tarjetas financieras del período seleccionado"); la selección se refleja en la URL y convive con el filtro de sucursal existente.

#### Scenario: Mes en curso por defecto
- **WHEN** el usuario entra al Tablero sin período seleccionado
- **THEN** el bloque muestra los KPIs del mes en curso

#### Scenario: Cambiar de período recalcula el bloque
- **WHEN** el usuario selecciona otro período
- **THEN** las 5 tarjetas y sus badges se recalculan para ese período y su mes anterior

#### Scenario: Período sin datos
- **WHEN** no hay datos para el período seleccionado
- **THEN** las 5 tarjetas del bloque muestran `—` en lugar del valor
- **AND** las tres tarjetas financieras del mes muestran `$0` (su propio escenario "Período sin datos"): la diferencia es deliberada — el bloque no informa un KPI sin actividad, la fila informa un total que es cero

### Requirement: Tarjetas financieras del período seleccionado
El Tablero SHALL mostrar, debajo del Bloque Resumen KPI, tres tarjetas financieras con los títulos "Ventas del mes", "Gastos del mes" y "Ganancia neta del mes", calculadas por `get_dashboard_financials` sobre la ventana del mes calendario del selector de período (mes en curso por defecto) y la sucursal del filtro de sucursal activo. Las tarjetas NOT SHALL presentarse como valores del día ("hoy"): el pedido del producto es que un negocio vea cómo va su mes, no cómo va su última hora. La ventana del mes SHALL materializarse con el mismo helper de rangos que el Bloque Resumen (`utcMonthRange`, anclado al día argentino), y las tres tarjetas SHALL mostrar lo que devuelve el read-model —en particular "Ganancia neta del mes" es el `net_profit` del RPC, que resta también las compras— sin recomputarlo en el cliente.

La regla de notas de crédito NOT SHALL reimplementarse en esta superficie: `get_dashboard_financials` la resuelve con el mismo helper de base de datos que `rpc_dashboard_kpi_summary` (capability `reporting-invariants`), de modo que ambas superficies informan el mismo resultado sobre la misma ventana, cuenta y sucursal.

#### Scenario: Mes en curso por defecto
- **WHEN** el usuario entra al Tablero sin período seleccionado
- **THEN** las tres tarjetas muestran ventas, gastos y ganancia neta del mes calendario en curso (hora argentina), no del día
- **AND** ninguna tarjeta de la fila conserva un título con "hoy"

#### Scenario: Cambiar de período recalcula las tarjetas
- **WHEN** el usuario selecciona otro período (`?period=YYYY-MM`)
- **THEN** las tres tarjetas se recalculan para el mes seleccionado, igual que el Bloque Resumen

#### Scenario: La sucursal seleccionada acota las tarjetas
- **WHEN** el Tablero tiene una sucursal seleccionada (`?branch=`)
- **THEN** las tres tarjetas se calculan sólo para esa sucursal

#### Scenario: La ganancia neta del mes coincide con la del Bloque Resumen
- **GIVEN** un usuario con una única membresía de cuenta y un mes con ventas, gastos, compras y una nota de crédito emitida dentro del mes
- **WHEN** se renderizan el Bloque Resumen KPI y la tarjeta "Ganancia neta del mes" con el mismo período y el mismo filtro de sucursal
- **THEN** el importe de "Ganancia neta del mes" (el `net_profit` de `get_dashboard_financials`) es igual al de la tarjeta "Ganancia Neta" del bloque (el `net_profit` de `rpc_dashboard_kpi_summary`)
- **AND** la igualdad es del importe, no del texto: la fila presenta el valor con el formato de siempre de esas tarjetas (`toLocaleString` del navegador, con decimales si los hay) y el bloque con `formatKpiCurrency` (redondeado, signo antes del `$`)

#### Scenario: Volver al Tablero trae los totales vigentes
- **WHEN** el usuario opera en otra pantalla (por ejemplo, vende por el POS o carga un gasto) y vuelve al Tablero
- **THEN** las tres tarjetas del mes, las ventas de hoy que recibe el Resumen AI del día y las cuatro tarjetas del Bloque Resumen que calcula `rpc_dashboard_kpi_summary` (Ganancia Neta, Stock sin Rotación, Costo por Venta y Ticket Promedio) se vuelven a consultar al montar la página, aunque la lectura anterior sea reciente
- **AND** mientras llega la lectura nueva se sigue viendo la anterior (sin volver a `—`), y la celebración de meta alcanzada no toma esa lectura anterior como punto de partida

#### Scenario: Período sin datos
- **WHEN** no hay ventas, gastos ni compras en el período seleccionado
- **THEN** las tres tarjetas muestran `$0`

#### Scenario: Mientras carga
- **WHEN** el read-model todavía no respondió
- **THEN** las tres tarjetas muestran `—`

#### Scenario: Falla del read-model
- **WHEN** el read-model falla
- **THEN** las tres tarjetas muestran `$0` y el error queda registrado con el mensaje que devolvió el read-model
- **AND** también cuando había una lectura anterior visible (falla el refresco al volver al Tablero): la fila no sigue mostrando un total que no se pudo confirmar
- **AND** el resto del Tablero sigue renderizando

#### Scenario: Lo que sigue siendo del día
- **WHEN** el Tablero se renderiza
- **THEN** el Resumen AI del día recibe las ventas de HOY (ventana del día argentino, sucursal activa) y NO cambia con el selector de período
- **AND** la celebración de meta alcanzada se evalúa contra las ventas de HOY

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
