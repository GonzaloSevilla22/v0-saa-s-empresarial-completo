# sale-line-items

## ADDED Requirements

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
El sistema SHALL proveer una versión nueva de `rpc_create_sale_operation` y `rpc_create_purchase_operation` que, en la misma transacción que el header, inserta la fila correspondiente en `sale_items`/`purchase_items`. La versión legacy SHALL permanecer disponible como fallback. Un feature flag SHALL determinar cuál versión se ejecuta, conmutables sin redeploy de backend ni frontend. La nueva versión MUST preservar la idempotencia existente (clave `(user_id, operation_kind, idempotency_key)`) y el comportamiento de stock/ledger.

#### Scenario: venta creada con el RPC nuevo tiene fila en sale_items
- **WHEN** el feature flag está activo y se crea una venta de un producto vía `rpc_create_sale_operation`
- **THEN** existe una fila en `sale_items` con `sale_id` igual al id de la venta, `product_id` del producto y `variant_id = NULL`

#### Scenario: el flag conmuta sin redeploy
- **WHEN** un administrador cambia el feature flag a `off`
- **THEN** las siguientes llamadas a `rpc_create_sale_operation` ejecutan el camino legacy sin reiniciar ni redeployar backend ni frontend

#### Scenario: idempotencia preservada en el RPC nuevo
- **WHEN** se llama dos veces el RPC nuevo con la misma `idempotency_key`
- **THEN** se crea una sola venta con un solo `sale_items`, y la segunda llamada devuelve el resultado original sin tocar stock

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
