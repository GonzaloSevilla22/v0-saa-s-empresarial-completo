## MODIFIED Requirements

### Requirement: Imputación opcional de la forma de pago en compras

El sistema SHALL permitir imputar opcionalmente una compra a una forma de pago mediante una columna nullable `payment_method_id` (FK a `payment_methods`, `ON DELETE SET NULL`) en `public.purchases`, con la misma semántica por operación que en ventas. El alta de compra (`rpc_create_purchase_operation`) SHALL aceptar un `payment_method_id` opcional, validar que pertenezca a la cuenta y persistirlo en todas las líneas, sin alterar la imputación a centro de costo ni el comportamiento de stock/ledger ya especificados.

El alta de compra SHALL aceptar además un `supplier_id` opcional como atributo **de operación**, validarlo contra la cuenta (existente y no borrado) y persistirlo en `public.purchases.supplier_id` en **todas** las líneas de la operación, incluidas las líneas sin producto. La forma de pago y el proveedor son ortogonales entre sí salvo en un caso: cuando el `kind` derivado de la forma de pago es `credit`, el proveedor pasa a ser obligatorio, según la capability `supplier-account`.

#### Scenario: Alta de compra con forma de pago y centro de costo

- **WHEN** se crea una compra informando `payment_method_id` y `cost_center_id`
- **THEN** todas las líneas de la operación quedan con ambos valores, cada uno en su columna

#### Scenario: Compra sin forma de pago

- **WHEN** se crea una compra sin informar forma de pago
- **THEN** la compra se persiste con `payment_method_id = NULL`

#### Scenario: Alta de compra con proveedor

- **WHEN** se crea una compra informando `supplier_id`
- **THEN** todas las líneas de la operación —con producto y sin producto— quedan con ese `supplier_id`

#### Scenario: Compra sin proveedor

- **WHEN** se crea una compra sin informar proveedor y sin una forma de pago de `kind = 'credit'`
- **THEN** la compra se persiste con `supplier_id = NULL`

## ADDED Requirements

### Requirement: La superficie de compra declara el efecto de la cuenta corriente antes de confirmar

El sistema SHALL declarar en el formulario de compra, antes de confirmar, qué va a ocurrir con la cuenta corriente del proveedor según la forma de pago elegida: al elegir una forma de pago de `kind = 'credit'` SHALL indicar que el importe se cargará a la cuenta del proveedor, exigir el proveedor y mostrar el saldo actual y el proyectado; al elegir cualquier otro `kind` NO SHALL prometer ningún efecto sobre la cuenta corriente. La ausencia de forma de pago imputada NO SHALL presentarse como equivalente a cuenta corriente, aunque el asiento contable la trate como tal por compatibilidad histórica.

#### Scenario: Elegir cuenta corriente explica el efecto

- **WHEN** el usuario elige en el formulario de compra una forma de pago de `kind = 'credit'`
- **THEN** la pantalla indica que la compra se cargará a la cuenta corriente del proveedor y muestra el saldo actual y el proyectado una vez elegido el proveedor

#### Scenario: Elegir cuenta corriente sin proveedor advierte y bloquea

- **WHEN** el usuario elige una forma de pago de `kind = 'credit'` sin proveedor seleccionado
- **THEN** la pantalla lo advierte y no permite confirmar la compra

#### Scenario: No elegir forma de pago no promete cuenta corriente

- **WHEN** el usuario no imputa ninguna forma de pago a la compra
- **THEN** la pantalla no anuncia ningún efecto sobre la cuenta corriente del proveedor, y la compra se registra sin cargo
