# reporting-invariants Specification

## Purpose

Invariantes transversales RN-D1..D5 del Modelo V3 (§8) que todo read-model financiero SHALL cumplir: exclusión de documentos cancelados y resta de notas de crédito (RN-D1), revenue de línea consistente (`COALESCE(total, amount)`), ingresos percibidos vs devengados (RN-D3), dinero siempre `NUMERIC` (RN-D4), y bordes de período en fecha local del tenant (RN-D5). Auditado y corregido en `rpc_dashboard_kpi_summary`, `rpc_product_profitability`, `rpc_period_comparison` y `rpc_branch_report` (migración `20260814000001`, 2026-07-06/07). Incluye la especificación de `rpc_branch_report`, que no tenía capability propia.

## Requirements

### Requirement: RN-D1 — Documentos cancelados jamás suman; las notas de crédito restan
Ningún read-model financiero SHALL incluir documentos cancelados/anulados en ingresos, costos ni cantidades. Las ventas legacy se anulan por DELETE físico con reposición de stock (quedan fuera por construcción); las `sales_orders` en estado `canceled` nunca escriben filas en `sales`. Las notas de crédito (registradas en `customer_account_movements` con `movement_type = 'credit_note'`) SHALL restarse del revenue del período en el que fueron emitidas (`created_at`) en los read-models de ingresos (`rpc_dashboard_kpi_summary`, `rpc_period_comparison`, `get_dashboard_financials`). Excepción documentada: `rpc_dashboard_channel_margin` no resta NC hasta que exista una regla de atribución por canal (las NC no tienen canal — decisión D6).

Cuando el read-model se consulta con filtro de sucursal, la nota de crédito SHALL atribuirse a la sucursal de su documento origen (`customer_account_movements.reference_id` → `sales_orders.branch_id`, que es NOT NULL): la NC es el contra-documento de una venta que sí está filtrada por sucursal, y dejarla a nivel cuenta restaría las NC de toda la cuenta del revenue de una sola sucursal. Una NC cuya referencia no resuelva a una orden de venta no resta en ninguna sucursal bajo filtro (fail-closed), y sí resta en la vista sin filtro.

#### Scenario: Una nota de crédito resta del revenue del período de su emisión
- **GIVEN** una cuenta con $10.000 facturados en julio y una NC de $1.000 emitida en julio
- **WHEN** se calcula el revenue de julio en el dashboard o el comparativo
- **THEN** el revenue del período es $9.000 (la NC resta)
- **AND** el revenue de junio no cambia (la NC se imputa al período de emisión, no al de la venta original)

#### Scenario: Una orden cancelada no aporta a ningún KPI
- **GIVEN** una `sales_order` en estado `canceled` (nunca confirmada)
- **WHEN** se calcula cualquier KPI de ingresos, costos u operaciones
- **THEN** la orden no aporta filas a `sales` y por lo tanto no suma en ningún read-model

#### Scenario: La nota de crédito resta en la sucursal de su venta original
- **GIVEN** una NC de $1.000 sobre una orden de venta de la sucursal A, en una cuenta con sucursales A y B
- **WHEN** se consulta el revenue del período con filtro de sucursal A
- **THEN** el revenue de A se reduce en $1.000
- **AND** al consultar con filtro de sucursal B el revenue de B no se reduce
- **AND** al consultar sin filtro de sucursal la NC resta una sola vez

### Requirement: El filtro de sucursal se aplica uniformemente a todos los términos de un read-model
Todo read-model financiero que acepte un parámetro de sucursal SHALL aplicarlo a **todos** los términos de sus fórmulas, o SHALL declarar explícitamente —en esta spec y devolviendo `NULL` en vez de un valor mezclado— cuál término no es atribuible a una sucursal y por qué. Está prohibido que un término quede sin filtrar de forma silenciosa: un agregado de cuenta combinado con agregados de sucursal produce una cifra que no corresponde a ningún universo real, y el usuario no tiene manera de detectarlo.

La atribución de sucursal de un movimiento que no la lleva en su propia fila SHALL derivarse del documento origen cuando la referencia lo permita, y SHALL ser fail-closed cuando no resuelva: un movimiento sin sucursal atribuible no se imputa a ninguna sucursal bajo filtro, y sí se cuenta en la vista sin filtro — el mismo comportamiento que ya tienen las ventas legacy con `branch_id NULL`.

#### Scenario: Un término no filtrado sesga el resultado de la sucursal
- **GIVEN** una cuenta con dos sucursales, donde la sucursal A facturó $10.000 y la sucursal B emitió una nota de crédito de $3.000
- **WHEN** se consulta el read-model con filtro de sucursal A
- **THEN** el ingreso devengado de A es $10.000 (la NC de B no lo reduce)

#### Scenario: Un movimiento sin sucursal atribuible no se imputa a ninguna
- **GIVEN** un movimiento financiero cuya referencia al documento origen no resuelve
- **WHEN** se consulta el read-model con filtro de cualquier sucursal
- **THEN** el movimiento no aporta a esa sucursal
- **AND** sí aporta cuando el read-model se consulta sin filtro de sucursal

#### Scenario: Un término no atribuible se declara en vez de mezclarse
- **GIVEN** una métrica cuya fórmula incluye un término que no puede atribuirse a una sucursal
- **WHEN** el read-model se consulta con filtro de sucursal
- **THEN** la métrica devuelve `NULL` y la excepción está documentada en la spec de su capability

### Requirement: La regla de notas de crédito existe una sola vez y los read-models diario y mensual coinciden
Los read-models diario (`get_dashboard_financials`) y mensual (`rpc_dashboard_kpi_summary`) SHALL informar el mismo ingreso devengado y la misma ganancia neta cuando se los consulta sobre la misma ventana, la misma cuenta y el mismo filtro de sucursal. Para garantizarlo, la regla de notas de crédito (tipo de movimiento, imputación por `created_at`, signo, y atribución de sucursal) SHALL estar implementada en un único helper de base de datos consumido por ambos, nunca replicada en cada RPC.

Este requirement nace de una divergencia real: el mensual restaba las NC y el diario no, así que dos tarjetas del mismo Tablero informaban ganancias distintas de la misma ventana sin que nada lo detectara.

#### Scenario: Diario y mensual informan la misma ganancia neta
- **GIVEN** una ventana con ventas, gastos, compras y al menos una nota de crédito
- **WHEN** se consultan el read-model diario y el mensual sobre esa misma ventana y cuenta
- **THEN** ambos devuelven la misma ganancia neta
- **AND** ambos devuelven el mismo ingreso devengado

#### Scenario: La coincidencia se sostiene con filtro de sucursal
- **GIVEN** la misma ventana consultada con un filtro de sucursal
- **WHEN** se comparan el read-model diario y el mensual
- **THEN** ambos devuelven la misma ganancia neta y el mismo ingreso devengado

#### Scenario: Un cambio en la regla de NC no puede desalinearlos
- **GIVEN** una modificación de la regla de notas de crédito
- **WHEN** se implementa
- **THEN** se aplica en el helper único que ambos read-models consumen, y un gate automatizado verifica que sigan coincidiendo

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

El par cargos + cobros es una métrica de **nivel cuenta** y no se filtra por sucursal: los cargos son atribuibles vía el documento origen, pero los cobros no lo son (`payments_received` no tiene sucursal y su `reference_sale_id` es opcional y en la práctica nulo), y `percibido = devengado − cargos + cobros` es una identidad cuyos tres términos deben vivir en el mismo universo. En consecuencia, cuando el read-model se consulta con filtro de sucursal, `collected_revenue` y `prev_collected_revenue` SHALL devolverse como `NULL` —métrica no computable por sucursal— en lugar de un valor que mezcle un devengado de sucursal con movimientos de toda la cuenta. Esta excepción queda documentada acá conforme al requirement de filtro uniforme.

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

#### Scenario: El percibido no es computable por sucursal
- **GIVEN** una cuenta con movimientos de cuenta corriente y más de una sucursal
- **WHEN** se consulta el resumen del período con filtro de sucursal
- **THEN** `collected_revenue` y `prev_collected_revenue` son `NULL`
- **AND** `invoiced_revenue` sí se calcula, filtrado por esa sucursal

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

### Requirement: Enforcement de consumo — los invariantes obligan también a los consumidores
Ningún consumidor de negocio que exponga ingresos o ganancia neta a un usuario final SHALL recalcular esas cifras por fuera del read-model canónico que ya las resuelve (`rpc_dashboard_kpi_summary` para el dashboard y los caminos de IA, `rpc_period_comparison` para comparativos, `rpc_product_profitability` para rentabilidad por producto, `rpc_branch_report` para el reporte por sucursal, `rpc_cost_center_report` para costos por centro). Cuando un consumidor necesite un desglose que ningún read-model expone y deba agregar líneas localmente, SHALL sumar el revenue de línea con `COALESCE(total, amount)` a través de un helper canónico compartido de su runtime, nunca con una expresión escrita en el punto de uso. Toda excepción a esta regla SHALL quedar documentada en la spec de la capability que la introduce, con su motivo — como ya lo están el margen por canal sin NC y el margen de catálogo con costo actual.

Este requirement existe porque los invariantes RN-D describían lo que los read-models cumplen, y por lo tanto un consumidor podía violarlos sin violar la spec: fue exactamente lo que pasó con los cinco caminos de IA, que sumaban `amount` (precio unitario) y definían la ganancia como `ventas − gastos`, ignorando compras y notas de crédito.

#### Scenario: Un consumidor nuevo no reimplementa la ganancia neta
- **GIVEN** una pantalla o servicio nuevo que necesita mostrar la ganancia neta de un período
- **WHEN** se implementa
- **THEN** consume el read-model canónico que ya la calcula, en lugar de agregar ventas, gastos y compras por su cuenta

#### Scenario: Un desglose no cubierto por ningún read-model usa el helper canónico
- **GIVEN** un consumidor que necesita revenue por producto sobre una ventana que ningún RPC expone
- **WHEN** agrega las líneas localmente
- **THEN** suma `COALESCE(total, amount)` a través del helper canónico compartido de su runtime

#### Scenario: Consumidor y read-model no pueden disentir sobre el mismo período
- **GIVEN** dos superficies distintas que muestran los ingresos de la misma cuenta y el mismo período
- **WHEN** un usuario compara ambas
- **THEN** informan el mismo número, porque ambas derivan de la misma fila del mismo read-model

#### Scenario: Una excepción sin documentar es una violación
- **GIVEN** un consumidor que calcula una métrica financiera con una fórmula propia
- **WHEN** esa desviación no está documentada como excepción en la spec de su capability
- **THEN** incumple este requirement
