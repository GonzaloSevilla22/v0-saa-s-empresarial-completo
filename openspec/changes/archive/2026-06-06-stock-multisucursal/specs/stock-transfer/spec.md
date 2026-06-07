## ADDED Requirements

### Requirement: Transferencia de stock entre sucursales

El sistema SHALL permitir transferir stock de un producto entre dos sucursales de la misma cuenta mediante la RPC `rpc_transfer_stock`, que genera dos `stock_movements` atómicos (`transfer_out` en origen y `transfer_in` en destino).

#### Scenario: Transferencia exitosa entre dos sucursales

- **GIVEN** producto X con 10 unidades en `branch_stock` de sucursal A y 5 en sucursal B
- **WHEN** el owner llama a `rpc_transfer_stock(product_id=X, from_branch_id=A, to_branch_id=B, quantity=3)`
- **THEN** `branch_stock` de A pasa a 7, `branch_stock` de B pasa a 8, y se insertan dos `stock_movements`: tipo `transfer_out` (delta=-3, branch_id=A) y tipo `transfer_in` (delta=+3, branch_id=B)

#### Scenario: Transferencia falla si stock insuficiente en origen

- **GIVEN** producto X con 2 unidades en `branch_stock` de sucursal A
- **WHEN** se intenta transferir 5 unidades de A a B
- **THEN** la RPC retorna error `insufficient_branch_stock` y NO modifica ninguna fila

#### Scenario: Transferencia desde sucursal sin stock falla

- **GIVEN** producto X sin fila en `branch_stock` para la sucursal A (stock = 0)
- **WHEN** se intenta transferir 1 unidad de A a B
- **THEN** la RPC retorna error `insufficient_branch_stock`

#### Scenario: No se puede transferir entre sucursales de distinta cuenta

- **GIVEN** sucursal A pertenece a cuenta 1, sucursal B pertenece a cuenta 2
- **WHEN** un miembro de cuenta 1 llama a `rpc_transfer_stock` con `from_branch_id=A, to_branch_id=B`
- **THEN** la RPC retorna error `branch_not_found` (la RLS no expone sucursales de otras cuentas)

#### Scenario: No se puede transferir a la misma sucursal

- **GIVEN** producto X con stock en sucursal A
- **WHEN** se llama a `rpc_transfer_stock` con `from_branch_id = to_branch_id = A`
- **THEN** la RPC retorna error `same_branch_transfer_not_allowed`

#### Scenario: Member no puede realizar transferencias

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** llama a `rpc_transfer_stock`
- **THEN** la RPC retorna error `insufficient_privilege`

---

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
