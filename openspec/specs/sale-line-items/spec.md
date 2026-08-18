# sale-line-items

## Purpose

`sale_items` / `purchase_items` son la fuente de verdad de la línea de venta/compra (C-20), reemplazando las columnas planas del header. Toda ruta de creación (RPC v2, legacy, y C-29 `confirm`/`quickSale`) escribe la línea en estas tablas; una vista de compatibilidad (`v_sales_flat`/`v_purchases_flat`) reconstruye el formato plano para consumidores legacy, hasta el retiro controlado del header.
## Requirements
### Requirement: Esquema canónico de la línea de venta/compra
El sistema SHALL almacenar la línea de venta en `sale_items` y la de compra en `purchase_items` como la fuente de verdad, con un esquema compatible con el modelo plano histórico. Cada tabla de ítems SHALL tener: `sale_id`/`purchase_id` (FK al header), `product_id` (FK→`products`, nullable), `variant_id` (FK→`product_variants`, **nullable**), `account_id` (tenancy), `quantity numeric(15,4)`, `unit_id` (FK→`units_of_measure`, nullable), `price` (precio unitario) y `subtotal`. La columna `variant_id` MUST ser nullable y `quantity` MUST ser `numeric` (no `integer`).

#### Scenario: variant_id admite NULL tras la migración
- **WHEN** se inserta una fila en `sale_items` con `product_id` no nulo y `variant_id = NULL`
- **THEN** la inserción es aceptada (la restricción `NOT NULL` previa sobre `variant_id` fue removida)

#### Scenario: quantity conserva cantidades fraccionales
- **WHEN** una venta histórica tiene `quantity = 2.5` en el header
- **THEN** su fila en `sale_items` tiene `quantity = 2.5` sin truncar a entero

### Requirement: Backfill idempotente de filas planas a ítems
El sistema SHALL crear exactamente una fila en `sale_items`/`purchase_items` por cada fila histórica de `sales`/`purchases` con `product_id NOT NULL`, copiando `product_id`, `quantity`, `unit_id`, `account_id`, `price` (desde `amount`) y `subtotal` (desde `total` o `amount*quantity`), con `variant_id = NULL`. El backfill MUST ser re-ejecutable sin crear duplicados. Las filas de ítems preexistentes (importador de variantes, `product_id IS NULL`) MUST NOT ser modificadas ni borradas.

#### Scenario: backfill 1:1 sin duplicar en re-ejecución
- **WHEN** la migración de backfill se ejecuta dos veces seguidas
- **THEN** el número de filas en `sale_items` con `product_id NOT NULL` es igual al número de filas de `sales` con `product_id NOT NULL`, sin importar cuántas veces corrió

#### Scenario: el backfill no toca las filas de variantes preexistentes
- **WHEN** corre el backfill
- **THEN** las 23 filas de `sale_items` y 18 de `purchase_items` con `variant_id NOT NULL` y `product_id IS NULL` permanecen inalteradas

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

### Requirement: Vista de compatibilidad plana con security_invoker
El sistema SHALL exponer una vista `v_sales_flat` (y `v_purchases_flat`) que reconstruye las columnas planas (`product_id`, `amount`, `quantity`, `total`) desde la tabla de ítems, para consumidores que aún leen el formato plano. La vista MUST declararse `WITH (security_invoker = true)` para no bypassar RLS.

#### Scenario: la vista respeta RLS por cuenta
- **WHEN** un usuario consulta `v_sales_flat`
- **THEN** solo ve las ventas de su propia cuenta (`account_id`), idéntico a consultar `sales` directamente

#### Scenario: la vista expone las columnas planas desde el ítem
- **WHEN** se consulta `v_sales_flat` para una venta backfilleada
- **THEN** `product_id`, `amount` (= `price`), `quantity` y `total` (= `subtotal`) provienen de la fila `sale_items` asociada

### Requirement: Lecturas migradas a la tabla de ítems
El sistema SHALL leer la línea de venta/compra desde `sale_items`/`purchase_items` (vía `JOIN` en los repositories del backend) o desde la vista de compatibilidad (Edge Functions), no desde las columnas planas del header. Las ventas legacy backfilleadas MUST seguir siendo accesibles a través de estas lecturas.

#### Scenario: el repositorio pagina leyendo del JOIN de ítems
- **WHEN** el backend lista ventas paginadas
- **THEN** `product_id`, `quantity` y `amount` provienen de `JOIN sale_items ON sale_items.sale_id = sales.id`, no de columnas del header

#### Scenario: el hook del frontend devuelve los ítems correctos
- **WHEN** `use-sales` carga una página de ventas
- **THEN** cada venta mapeada expone `productId`, `quantity` y `unitPrice` derivados de la fila de ítem

#### Scenario: venta legacy pre-backfill sigue accesible
- **WHEN** se consulta una venta creada antes del backfill
- **THEN** sus datos de línea (producto, cantidad, precio) se devuelven correctamente desde su fila `sale_items` backfilleada

#### Scenario: las compras espejan el comportamiento de las ventas
- **WHEN** se crea o lista una compra
- **THEN** la línea vive en `purchase_items` y se lee desde ahí, con la misma semántica que ventas

### Requirement: Retiro del header plano como paso final controlado
El sistema SHALL remover las columnas planas `product_id`, `amount`, `quantity`, `total` y `unit_id` del header `sales` (y equivalentes en `purchases`) únicamente como último paso, tras validar que ningún consumidor lee esas columnas y que la vista de compatibilidad está en uso. Esta remoción es un cambio **BREAKING** y MUST ejecutarse en una migración separada, sujeta a aprobación explícita.

#### Scenario: el DROP se bloquea si algo todavía lee el header plano
- **WHEN** se ejecuta la verificación previa al DROP y alguna función o vista (fuera de la lista esperada) referencia una columna a dropear
- **THEN** la verificación falla y el DROP no se aplica

#### Scenario: el ledger de stock no se ve afectado por el DROP
- **WHEN** se dropean las columnas planas del header
- **THEN** `stock_movements` sigue referenciando el header por `reference_id` sin cambios (relación 1:1 preservada)

### Requirement: SalesOrder.confirm() es una ruta de escritura adicional del ledger de ventas

El sistema SHALL permitir que `SalesOrder.confirm()`/`quickSale()` (capability `sales-order`) produzcan filas en `sales` + `sale_items` reusando la mecánica de doble escritura de `rpc_create_sale_operation_v2` (header `sales` + `sale_items` + `stock_movements` con `reference_type = 'sale'`), dentro de la misma transacción atómica que el descuento de `branch_stock`. Esta ruta MUST preservar la idempotencia compartida (`operation_idempotency`, `operation_kind = 'sale'`) y el comportamiento de stock/ledger ya definido para las ventas. Las columnas planas del header `sales` (`product_id`, `amount`, `quantity`, `total`) NO SHALL ser la fuente de verdad: la línea vive en `sale_items`.

#### Scenario: confirm escribe la línea en sale_items, no en el header plano
- **WHEN** se confirma un `SalesOrder` de un producto
- **THEN** existe una fila en `sale_items` con `product_id` del producto, `variant_id = NULL`, ligada a la fila `sales` generada, y el `stock_movements` registra `reference_type = 'sale'`

#### Scenario: idempotencia compartida con la ruta de venta directa
- **WHEN** una `quickSale` y una venta directa usaran la misma `idempotency_key` (mismo `operation_kind = 'sale'`)
- **THEN** la segunda invocación se trata como replay y no duplica filas en `sale_items` ni descuenta stock dos veces

#### Scenario: las lecturas de ventas existentes incluyen las órdenes confirmadas
- **WHEN** el repositorio del backend pagina ventas leyendo del `JOIN sale_items`
- **THEN** las ventas originadas por `SalesOrder.confirm()`/`quickSale()` aparecen con su `product_id`, `quantity` y `amount` derivados de `sale_items`, igual que cualquier otra venta

### Requirement: Invariante — toda venta con producto tiene su fila en sale_items, sin importar la ruta

El sistema SHALL garantizar que toda fila de `sales` con `product_id NOT NULL` tenga exactamente una fila asociada en `sale_items` (`sale_items.sale_id = sales.id`, `product_id` coincidente), **independiente de la ruta de creación**: `rpc_create_sale_operation_v2`, la ruta legacy, o la ruta C-29 `rpc_quick_sale` / `rpc_confirm_sales_order`. La ruta C-29 MUST insertar esa fila en la misma transacción que el header `sales`, espejando la doble escritura de `rpc_create_sale_operation_v2` (`variant_id = NULL`, `quantity`, `unit_id`, `price`, `subtotal` desde la línea de `sales_order_items`). Las líneas de servicio (`product_id IS NULL`) MUST NOT generar fila de ítem. Las ventas con producto creadas antes de este cambio que carezcan de `sale_items` SHALL ser backfilleadas desde las columnas planas de `sales`, de forma idempotente.

#### Scenario: quickSale (POS) escribe la línea en sale_items

- **WHEN** se ejecuta `rpc_quick_sale` con un ítem de producto
- **THEN** existe una fila en `sale_items` ligada a la fila `sales` generada, con `product_id` del producto, `variant_id = NULL`, y `quantity`/`price`/`subtotal` de la línea

#### Scenario: confirm de SalesOrder escribe la línea en sale_items

- **WHEN** se confirma un `SalesOrder` de un producto vía `rpc_confirm_sales_order`
- **THEN** existe una fila en `sale_items` con `sale_id` de la venta generada y `product_id` del producto

#### Scenario: no quedan ventas con producto sin sale_items

- **WHEN** se consulta el conjunto de filas `sales` con `product_id NOT NULL`
- **THEN** ninguna carece de fila en `sale_items` (gate de validación = 0 ventas sin ítem)

#### Scenario: el backfill de ventas sin ítem es idempotente

- **WHEN** la reconstrucción de `sale_items` para ventas con producto sin ítem se ejecuta dos veces seguidas
- **THEN** se crea exactamente una fila por venta afectada, sin duplicados, y las filas de variantes preexistentes (`variant_id NOT NULL`, `product_id IS NULL`) permanecen inalteradas

### Requirement: Columnas snapshot en la línea de venta/compra

El sistema SHALL agregar a `sale_items` y `purchase_items`, de forma aditiva y NULLABLE, las columnas `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)` e `iva_rate_snapshot NUMERIC(5,2)`, más `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false`. La versión vigente de `rpc_create_sale_operation` y `rpc_create_purchase_operation` SHALL congelar `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` (desde `products.cost`) e `iva_rate_snapshot` en la misma transacción que inserta la línea, sin alterar la idempotencia ni el comportamiento de stock/ledger ya especificados para estas RPC.

#### Scenario: El RPC de venta congela el costo del maestro en la línea

- **GIVEN** un producto con `products.cost = 600`, `products.name = 'Yerba 1kg'` y `products.sku = 'YRB-1000'`
- **WHEN** se crea una venta de ese producto vía `rpc_create_sale_operation`
- **THEN** la fila en `sale_items` queda con `unit_cost_snapshot = 600`, `name_snapshot = 'Yerba 1kg'`, `sku_snapshot = 'YRB-1000'` e `iva_rate_snapshot` de la alícuota vigente, todo en la transacción del header

#### Scenario: El RPC de compra congela el snapshot

- **WHEN** se crea una compra vía `rpc_create_purchase_operation`
- **THEN** la fila en `purchase_items` queda con `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` congelados desde el maestro

#### Scenario: La idempotencia y el stock se preservan con el snapshot

- **WHEN** se llama dos veces `rpc_create_sale_operation` con la misma `idempotency_key`
- **THEN** se crea una sola venta con una sola fila `sale_items` (con su snapshot), la segunda llamada devuelve el resultado original sin tocar stock, y el descuento de `branch_stock` es idéntico al comportamiento previo al snapshot

#### Scenario: Línea de servicio congela sólo el nombre

- **WHEN** el RPC inserta una línea con `product_id IS NULL` y un nombre en el payload
- **THEN** `name_snapshot` toma el nombre del payload y `sku_snapshot`/`unit_cost_snapshot`/`iva_rate_snapshot` quedan en NULL, desbloqueando la representación de línea de servicio (C-20 Grupo 10)

