## ADDED Requirements

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
