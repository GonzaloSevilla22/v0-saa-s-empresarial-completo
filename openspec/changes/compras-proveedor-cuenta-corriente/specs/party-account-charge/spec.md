## MODIFIED Requirements

### Requirement: El despacho por tipo de parte cubre cliente y proveedor

El sistema SHALL soportar en el mismo helper las dos partes del circuito —cliente (venta a crédito) y proveedor (compra a crédito)— resolviendo para cada una su par de helpers C-30 y su tipo de evento, sin que el llamador tenga que conocer qué tabla se toca. La incorporación de un camino de compra a crédito NO SHALL requerir un helper nuevo.

Ambas partes SHALL tener un **camino de producción real**: el alta de venta a crédito (mostrador y formulario) para la parte cliente, y el alta de compra a crédito (formulario de compra) para la parte proveedor. Ningún camino de alta SHALL reimplementar la resolución de la cuenta corriente, el registro del movimiento ni la emisión del evento; su única responsabilidad SHALL ser decidir **si** corresponde cargar y con qué importe, referencia y tipo de parte.

#### Scenario: El cargo a proveedor usa el mismo helper

- **GIVEN** un proveedor registrado en la cuenta
- **WHEN** se postea un cargo de 8000 con tipo de parte `supplier`
- **THEN** el movimiento se registra en `supplier_account_movements` sobre la `supplier_accounts` del proveedor y se emite el evento de cargo a proveedor

#### Scenario: La parte cliente no escribe en tablas de proveedor

- **WHEN** se postea un cargo con tipo de parte `customer`
- **THEN** no se inserta ninguna fila en `supplier_accounts` ni en `supplier_account_movements`

#### Scenario: El alta de compra a crédito despacha por el helper compartido

- **WHEN** se registra una compra imputada a una forma de pago de `kind = 'credit'` con proveedor
- **THEN** el cargo se resuelve invocando el helper compartido con tipo de parte `supplier`, y la RPC de alta de compra no contiene lógica propia de cuenta corriente

#### Scenario: Las dos partes producen la misma forma de movimiento

- **WHEN** se comparan el cargo producido por una venta a crédito y el producido por una compra a crédito del mismo importe
- **THEN** ambos son movimientos con signo positivo sobre la cuenta corriente de su parte, con `balance_after` calculado por el helper C-30 correspondiente y `reference_id` apuntando a la operación de origen
