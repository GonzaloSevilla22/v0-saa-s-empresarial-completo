# stock-transfer — Spec (stock-multisucursal)

## Purpose

Transferencia de stock entre sucursales de la misma cuenta. Exclusivo plan PRO. Mueve inventario de forma atómica mediante la RPC `rpc_transfer_stock` — desde C-26, cada transferencia es una entidad `StockTransfer` con identidad e historial propio — con trazabilidad completa vía `stock_movements`.
## Requirements
### Requirement: Transferencia de stock entre sucursales
El sistema SHALL registrar cada transferencia como una entidad `StockTransfer` (tabla `stock_transfers`: `id`, `account_id`, `product_id`, `from_branch_id`, `to_branch_id`, `quantity`, `status`, `created_by`, `created_at`) creada atómicamente por `rpc_transfer_stock` junto con los dos `stock_movements` (`transfer_out` en origen, `transfer_in` en destino), ambos vinculados vía `stock_movements.transfer_id`.

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

#### Scenario: No se puede transferir a la misma sucursal
- **GIVEN** producto X con stock en sucursal A
- **WHEN** se llama a `rpc_transfer_stock` con `from_branch_id = to_branch_id = A`
- **THEN** la RPC retorna error `P0400 same_branch_transfer_not_allowed`

#### Scenario: Member no puede realizar transferencias
- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** llama a `rpc_transfer_stock`
- **THEN** la RPC retorna error `P0401`

### Requirement: UI de transferencia desde /sucursales/:id/stock

El sistema SHALL proveer en la página `/sucursales/:id/stock` un botón "Transferir" por producto que abre un modal con campos: sucursal destino (dropdown de sucursales activas de la cuenta, excluyendo la actual) y cantidad.

#### Scenario: Owner inicia una transferencia desde la UI

- **GIVEN** el owner está en `/sucursales/A/stock` viendo el producto X con 10 unidades
- **WHEN** hace clic en "Transferir" para el producto X y selecciona la sucursal B con cantidad 3
- **THEN** se llama a `rpc_transfer_stock` y la tabla se refresca mostrando 7 unidades para X en la sucursal A

#### Scenario: Transferencia con cantidad inválida muestra error

- **GIVEN** el owner ingresa cantidad 0 o un número mayor al stock disponible
- **WHEN** intenta confirmar la transferencia
- **THEN** el modal muestra el mensaje de error de la RPC y no cierra

### Requirement: Historial de transferencias por sucursal
El sistema SHALL permitir consultar las transferencias de una sucursal (como origen o destino) ordenadas por fecha descendente, expuestas por el backend (`GET /branches/{id}/transfers`) y visibles en `/sucursales/:id`.

#### Scenario: Owner ve el historial de transferencias de una sucursal
- **GIVEN** una sucursal A con 2 transferencias salientes y 1 entrante
- **WHEN** el owner navega a `/sucursales/A`
- **THEN** ve 3 transferencias con producto, cantidad, dirección (entrada/salida), contraparte y fecha

#### Scenario: La RLS aísla el historial por cuenta
- **GIVEN** transferencias de las cuentas 1 y 2
- **WHEN** un miembro de la cuenta 1 consulta `stock_transfers`
- **THEN** solo ve filas con `account_id` de su cuenta

