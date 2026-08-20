# party-account-charge Specification

## Purpose
TBD - created by archiving change pagos-cableados-restantes. Update Purpose after archive.
## Requirements
### Requirement: Autoría única del cargo en cuenta corriente

El sistema SHALL concentrar en un **único helper transaccional** la operación de cargar el importe de una operación a la cuenta corriente de una parte, y todo camino que registre una venta o una compra a crédito SHALL invocar ese helper en lugar de reimplementar la secuencia. El helper SHALL recibir la cuenta (tenant), el tipo de parte (`customer` o `supplier`), el identificador de la parte, el importe, la referencia de la operación y el identificador de operación; SHALL resolver o crear la cuenta corriente de la parte y registrar el movimiento reutilizando los helpers C-30 existentes; y SHALL emitir el evento de dominio correspondiente en el mismo commit. Ningún camino de alta SHALL duplicar esa secuencia inline.

#### Scenario: La venta del mostrador y la del formulario producen el mismo cargo

- **GIVEN** un cliente sin cuenta corriente previa
- **WHEN** se registra una venta de 5000 a una forma de pago de `kind = 'credit'` desde el POS
- **AND** se registra otra venta de 5000 a `kind = 'credit'` desde el formulario de venta para el mismo cliente
- **THEN** ambos caminos producen un movimiento en `customer_account_movements` con el mismo signo, el mismo `type` y la misma semántica de `balance_after`, y el saldo del cliente queda en 10000

#### Scenario: El helper crea la cuenta corriente cuando no existe

- **GIVEN** un cliente sin fila en `customer_accounts`
- **WHEN** se postea un cargo por una venta a crédito de 3000
- **THEN** se crea la `customer_accounts` del cliente en el mismo commit y el movimiento queda asociado a ella con `balance_after = 3000`

#### Scenario: Un tipo de parte desconocido es rechazado

- **WHEN** se invoca el helper con un tipo de parte distinto de `customer` o `supplier`
- **THEN** la transacción falla con `invalid_party_kind` y no se registra ningún movimiento ni evento

### Requirement: El cargo y la operación comparten transacción

El sistema SHALL registrar el cargo en cuenta corriente en la **misma transacción** que la operación que lo origina, de modo que no exista un estado observable en el que la venta o la compra esté registrada y su cargo no, ni a la inversa. El evento de dominio del cargo SHALL insertarse en el outbox dentro de esa misma transacción.

#### Scenario: Un fallo posterior al cargo revierte el cargo

- **GIVEN** una venta a crédito en curso cuyo cargo ya fue posteado
- **WHEN** un paso posterior de la misma RPC falla
- **THEN** ni la venta, ni el movimiento en `customer_account_movements`, ni el evento quedan persistidos

#### Scenario: El evento del cargo viaja con la operación

- **WHEN** se registra una venta a crédito por cualquier camino
- **THEN** se inserta en `events` un evento del tipo correspondiente a la parte cargada, con el importe, el identificador de la cuenta corriente afectada y la referencia a la operación

### Requirement: El despacho por tipo de parte cubre cliente y proveedor

El sistema SHALL soportar en el mismo helper las dos partes del circuito —cliente (venta a crédito) y proveedor (compra a crédito)— resolviendo para cada una su par de helpers C-30 y su tipo de evento, sin que el llamador tenga que conocer qué tabla se toca. La incorporación de un camino de compra a crédito NO SHALL requerir un helper nuevo.

#### Scenario: El cargo a proveedor usa el mismo helper

- **GIVEN** un proveedor registrado en la cuenta
- **WHEN** se postea un cargo de 8000 con tipo de parte `supplier`
- **THEN** el movimiento se registra en `supplier_account_movements` sobre la `supplier_accounts` del proveedor y se emite el evento de cargo a proveedor

#### Scenario: La parte cliente no escribe en tablas de proveedor

- **WHEN** se postea un cargo con tipo de parte `customer`
- **THEN** no se inserta ninguna fila en `supplier_accounts` ni en `supplier_account_movements`

