## ADDED Requirements

### Requirement: El borrado de un gasto se incorpora al contrato transversal de compensación de libros

El sistema SHALL ejecutar el borrado de un gasto bajo el mismo contrato transversal que ya rige para el borrado de una venta: los guards se evalúan y las compensaciones se aplican en la misma transacción que la eliminación, de modo que ninguna combinación de fallos deje libros compensados sin operación borrada ni operación borrada sin libros compensados.

Para el gasto los libros compensables SHALL ser exactamente dos —caja y banco— y ninguno más: un gasto no tiene contraparte con cuenta corriente, no mueve stock y no emite eventos al outbox.

El detalle normativo de cada compensación SHALL vivir en la capability del libro que la recibe —`cash-movement` para el contra-movimiento de caja y su bloqueo cuando no hay sesión abierta, `bank-movement` para el movimiento espejo—, y el contrato de RPC única y de no orquestación desde la aplicación SHALL vivir en `expense-operation`. SHALL NOT duplicarse ninguno de los dos en esta capability.

#### Scenario: Todo o nada ante un fallo de compensación

- **WHEN** el borrado de un gasto falla al compensar cualquiera de los dos libros
- **THEN** la transacción completa se revierte
- **AND** el gasto sigue existiendo
- **AND** ningún libro queda con contra-movimientos parciales

#### Scenario: Gasto con impacto en los dos libros

- **GIVEN** un gasto que descontó de la caja y otro que registró un egreso bancario
- **WHEN** se borra cada uno
- **THEN** cada libro recibe su contra-movimiento en la misma transacción del borrado
- **AND** los saldos vuelven a los valores previos al gasto

#### Scenario: Gasto sin impacto en libros

- **WHEN** se borra un gasto sin forma de pago imputada
- **THEN** el borrado procede sin ninguna compensación
- **AND** no se exige ninguna precondición de caja ni de banco
