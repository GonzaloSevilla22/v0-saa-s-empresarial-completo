# Spec Delta — reporting-invariants

## ADDED Requirements

### Requirement: El reporting cuenta y costea la cantidad en la unidad base del producto

*(D13 de ventas-unidades-conversion.)* Todo read-model que cuente unidades vendidas o costee una línea de venta SHALL expresar la cantidad de la línea en la **unidad base del producto** — la misma en que están `unit_cost_snapshot` y `products.cost` — obteniéndola de la definición única de normalización de cantidad (capability `units-of-measure`) a través de su envoltorio de lectura. El importe de la línea NO cambia de regla: sigue siendo `COALESCE(total, amount)` (el precio es por unidad de la línea, contrato D-F). Rige para la definición canónica de "línea de venta del período" (`reporting_sales_lines_in_window`, y por ella ranking, evolución, desgloses, top clientes y rentabilidad) y para las dos lecturas del Tablero que no pasan por ella (`rpc_dashboard_kpi_summary`, `rpc_dashboard_channel_margin`).

Un reporte NO SHALL abortar por una línea histórica que la regla de escritura de hoy rechazaría (p. ej. una línea en mililitros sobre un producto sin unidad base): esa línea SHALL reportarse con la cantidad tal como se grabó. El resultado es el de una cantidad base persistida mientras las unidades no cambien de factor, tipo ni base — lo garantiza el requirement de `units-of-measure` que las congela en cuanto están en uso.

Consumidores pendientes, declarados y fuera de este requirement (candidatos en `CHANGES.md`): las Edge Functions `ai-precio` (promedia el precio y suma la cantidad cruda de `v_sales_flat`) y `fair-advisor` (suma la cantidad cruda) todavía no leen la cantidad en unidad base; son informativas y su sugerencia no se aplica sola. El export `generate-export` tampoco trae todavía la unidad de la línea.

#### Scenario: 100 g sobre un producto costeado por kilo

- **GIVEN** un producto con unidad base Kilogramo y costo `600`, y una venta de `100` con unidad Gramo a `1.8` por gramo (total `180`)
- **WHEN** se consulta el ranking de productos y la línea canónica del período
- **THEN** las unidades vendidas son `0.1`, el costo de lo vendido es `60` y el ingreso `180` — no `100` unidades ni un costo de `60000`

#### Scenario: El Tablero costea en unidad base

- **GIVEN** la misma venta como única operación de la cuenta en el período
- **WHEN** se consultan el costo por venta del resumen de KPIs y el margen por canal
- **THEN** el costo por venta es `60` y el margen del canal `66.7 %`

#### Scenario: Una línea histórica inconvertible no aborta el reporte

- **GIVEN** una línea grabada con `0.381` en Mililitro sobre un producto sin unidad base
- **WHEN** cualquier read-model de reporting la agrega
- **THEN** la consulta no falla y la línea aporta `0.381` tal como se grabó

### Requirement: La alerta de margen bajo compara el importe de la línea contra el costo en unidad base

La alerta de margen bajo de una venta (email `low_margin_alert`, disparado por el trigger `on_sale_insert_margin_check`) SHALL calcular el margen como `(importe de la línea − costo por unidad base × cantidad en unidad base) / importe de la línea`, con el importe de la línea según la regla de revenue de línea (`COALESCE(total, amount × quantity)`) y la cantidad en unidad base obtenida de la definición única de normalización. El email SHALL mostrar ese importe y ese costo. Un producto sin costo cargado NO SHALL disparar la alerta.

#### Scenario: Una venta en gramos con margen sano no dispara la alerta

- **GIVEN** un producto con unidad base Kilogramo y costo `1200`
- **WHEN** se venden `100` con unidad Gramo a `1.8` por gramo (importe `180`, costo `120`, margen 33,3 %), por el formulario o por el POS
- **THEN** no se registra ninguna alerta de margen para esa venta

#### Scenario: Una venta en gramos con margen negativo sí la dispara

- **GIVEN** el mismo producto
- **WHEN** se venden `100` con unidad Gramo a `1.0` por gramo
- **THEN** se registra una alerta con importe `100`, costo `120` y margen `-20`

#### Scenario: Cantidad mayor a uno en la unidad base

- **GIVEN** un producto con unidad base Unidad y costo `50`
- **WHEN** se venden `3` a `100` cada una (importe `300`, costo `150`)
- **THEN** no se registra ninguna alerta (antes comparaba el precio unitario `100` contra `150` y daba −50 %)
