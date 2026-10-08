## MODIFIED Requirements

### Requirement: Transferencia de stock entre sucursales
El sistema SHALL registrar cada transferencia como una entidad `StockTransfer` (tabla `stock_transfers`: `id`, `account_id`, `product_id`, `from_branch_id`, `to_branch_id`, `quantity`, `status`, `created_by`, `created_at`) creada atómicamente por `rpc_transfer_stock` junto con los dos `stock_movements` (`transfer_out` en origen, `transfer_in` en destino), ambos vinculados vía `stock_movements.transfer_id`.

`rpc_transfer_stock` SHALL validar que el **producto** pertenezca a la cuenta del usuario, además de las dos sucursales: un producto de otra cuenta SHALL rechazarse con `P0404` antes de leer o escribir ningún saldo. Una transferencia SHALL ser el único camino para registrar movimientos `transfer_out`/`transfer_in`: el ajuste manual de stock SHALL NOT aceptarlos como tipo.

#### Scenario: Transferencia exitosa crea la entidad y vincula ambos movimientos
- **GIVEN** producto X con 10 unidades en `branch_stock` de sucursal A y 5 en sucursal B
- **WHEN** el owner llama a `rpc_transfer_stock(product_id=X, from_branch_id=A, to_branch_id=B, quantity=3)`
- **THEN** `branch_stock` de A pasa a 7 y B a 8; se inserta una fila en `stock_transfers` con `status='completed'`; y los dos `stock_movements` (`transfer_out` delta=−3 / `transfer_in` delta=+3) llevan el mismo `transfer_id`

#### Scenario: Transferencia falla si stock insuficiente en origen
- **GIVEN** producto X con 2 unidades en `branch_stock` de sucursal A
- **WHEN** se intenta transferir 5 unidades de A a B
- **THEN** la RPC retorna error `P0409 insufficient_branch_stock` y NO inserta ninguna fila (ni transfer, ni movements, ni cambios de ledger)

#### Scenario: Transferencia desde sucursal sin stock falla
- **GIVEN** producto X sin fila en `branch_stock` para la sucursal A (stock = 0)
- **WHEN** se intenta transferir 1 unidad de A a B
- **THEN** la RPC retorna error `P0409 insufficient_branch_stock`

#### Scenario: No se puede transferir entre sucursales de distinta cuenta
- **GIVEN** sucursal A pertenece a cuenta 1, sucursal B pertenece a cuenta 2
- **WHEN** un miembro de cuenta 1 llama a `rpc_transfer_stock` con `from_branch_id=A, to_branch_id=B`
- **THEN** la RPC retorna error `P0404 branch_not_found`

#### Scenario: No se puede transferir un producto de otra cuenta
- **GIVEN** un producto que pertenece a la cuenta 2 y dos sucursales de la cuenta 1
- **WHEN** un miembro de la cuenta 1 llama a `rpc_transfer_stock` con ese producto
- **THEN** la RPC retorna `P0404` y no inserta transferencia, movimientos ni filas de `branch_stock`

#### Scenario: No se puede transferir a la misma sucursal
- **GIVEN** producto X con stock en sucursal A
- **WHEN** se llama a `rpc_transfer_stock` con `from_branch_id = to_branch_id = A`
- **THEN** la RPC retorna error `P0400 same_branch_transfer_not_allowed`

#### Scenario: Member no puede realizar transferencias
- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** llama a `rpc_transfer_stock`
- **THEN** la RPC retorna error `P0401`

#### Scenario: El ajuste manual no registra transferencias
- **WHEN** un usuario con permiso intenta un ajuste manual de tipo `transfer_in` o `transfer_out`
- **THEN** el ajuste es rechazado con `P0400 stock_adjustment_type_invalid` y el mensaje lo deriva a la transferencia entre sucursales
