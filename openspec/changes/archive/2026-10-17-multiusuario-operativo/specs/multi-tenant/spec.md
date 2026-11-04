## MODIFIED Requirements

### Requirement: RPCs de operaciones sellan la cuenta

El sistema SHALL hacer que las RPCs de creación de operaciones (ventas, compras, gastos, movimientos de stock, cobros y pagos) sellen el `account_id` de la **cuenta activa** del caller, y que toda entidad que la operación referencia —producto, cliente, proveedor, sucursal, documento— pertenezca a esa misma cuenta.

#### Scenario: Una venta nueva queda asociada a la cuenta activa
- **GIVEN** un miembro de la cuenta A, con A como cuenta activa, creando una venta por el formulario o por el POS
- **WHEN** la RPC inserta las filas
- **THEN** las filas de `sales` y `stock_movements` tienen `account_id` de la cuenta A

#### Scenario: Un usuario de dos cuentas opera sobre la activa
- **GIVEN** un usuario miembro de su cuenta personal y de la cuenta del negocio, con el negocio como cuenta activa
- **WHEN** crea una venta, con o sin producto
- **THEN** las filas quedan en la cuenta del negocio, nunca en la personal

#### Scenario: La RPC rechaza una entidad de una cuenta ajena
- **WHEN** un caller referencia un producto, cliente, proveedor o documento de una cuenta que no es su cuenta activa
- **THEN** la RPC rechaza la operación sin registrar filas, con el mismo error que una entidad inexistente
