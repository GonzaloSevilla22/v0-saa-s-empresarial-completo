## MODIFIED Requirements

### Requirement: RPC versionado que escribe el ítem
El sistema SHALL escribir la fila de `sale_items`/`purchase_items` en la misma transacción que el header para **toda cuenta por defecto**, presente o futura, sin requerir habilitación previa por cuenta. `rpc_create_sale_operation` y `rpc_create_purchase_operation` SHALL despachar a su versión que inserta la línea siempre que no exista una desactivación explícita para esa cuenta. La versión legacy SHALL permanecer disponible como fallback y el feature flag SHALL conservarse como interruptor de apagado, conmutable sin redeploy de backend ni frontend. Un mismo flag SHALL gobernar ventas y compras. La versión nueva MUST preservar la idempotencia existente (clave `(user_id, operation_kind, idempotency_key)`) y el comportamiento de stock/ledger.

#### Scenario: cuenta sin configuración de flag escribe la línea
- **WHEN** una cuenta sin ninguna fila de configuración para el flag crea una venta de un producto vía `rpc_create_sale_operation`
- **THEN** existe una fila en `sale_items` con `sale_id` igual al id de la venta, `product_id` del producto y `variant_id = NULL`

#### Scenario: cuenta creada después del cutover escribe la línea
- **WHEN** se crea una cuenta nueva y su primera venta de un producto
- **THEN** la venta tiene su fila en `sale_items` sin que nadie haya habilitado el flag para esa cuenta

#### Scenario: la compra usa el mismo interruptor que la venta
- **WHEN** una cuenta sin desactivación explícita registra una compra de un producto vía `rpc_create_purchase_operation`
- **THEN** existe una fila en `purchase_items` ligada a la compra, sin requerir un flag separado de compras

#### Scenario: el apagado explícito devuelve el camino legacy sin redeploy
- **WHEN** un administrador registra la desactivación del flag para una cuenta
- **THEN** las siguientes llamadas a `rpc_create_sale_operation` y `rpc_create_purchase_operation` de esa cuenta ejecutan el camino legacy sin reiniciar ni redeployar backend ni frontend

#### Scenario: idempotencia preservada en el RPC nuevo
- **WHEN** se llama dos veces el RPC nuevo con la misma `idempotency_key`
- **THEN** se crea una sola venta con un solo `sale_items`, y la segunda llamada devuelve el resultado original sin tocar stock

## ADDED Requirements

### Requirement: Toda línea de venta o compra declara su cuenta
El sistema SHALL garantizar que toda fila de `sale_items` y `purchase_items` tenga `account_id` poblado con el `account_id` de su venta o compra padre.

Las filas históricas creadas antes de que la columna existiera SHALL ser backfilleadas de forma determinística e idempotente desde el header padre. El backfill NO SHALL inventar un `account_id` cuando el padre no lo tenga, y NO SHALL modificar filas que ya tengan uno.

#### Scenario: línea legacy sin cuenta hereda la de su header
- **WHEN** existe una fila de `sale_items` con `account_id` nulo cuya venta padre tiene `account_id`
- **THEN** tras el backfill la línea tiene exactamente el `account_id` de su venta padre

#### Scenario: el backfill es idempotente
- **WHEN** el backfill de `account_id` se ejecuta dos veces seguidas
- **THEN** la segunda ejecución no modifica ninguna fila

#### Scenario: línea ya atribuida no se toca
- **WHEN** una fila de `purchase_items` ya tiene `account_id`
- **THEN** el backfill la deja inalterada, incluso si difiere del header
