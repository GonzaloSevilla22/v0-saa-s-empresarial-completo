## MODIFIED Requirements

### Requirement: La edición de un gasto ajusta su asiento en lugar de invalidarlo

Editar un gasto que ya tiene asiento SHALL producir un **par contra-asiento más asiento nuevo**: el asiento vigente se revierte con una entrada de lados invertidos y queda marcado como revertido, y se postea uno nuevo con los valores resultantes de la edición.

Ni el asiento posteado ni el dinero registrado SHALL volver inmutable al gasto: la edición ajusta sus libros de dinero según la capability `operation-money-edit`, y su asiento según este requirement.

La contrapartida del asiento nuevo SHALL derivarse del libro que **efectivamente** queda movido **después** de la edición: la huella bancaria neta del gasto distinta de cero acredita banco, y en otro caso la cuenta de caja. SHALL NOT derivarse de la mera existencia de un movimiento bancario, que también existe cuando la edición acaba de compensarlo.

El contra-asiento SHALL fecharse en el momento de la corrección y no en la fecha del gasto original: la corrección data la corrección.

Si al procesar el evento de edición no se encuentra el asiento vigente del gasto, el consumidor SHALL fallar de forma recuperable, dejando el evento pendiente para reintento, y SHALL NOT postear un asiento nuevo huérfano.

#### Scenario: Editar el importe de un gasto asentado

- **GIVEN** un gasto con su asiento posteado
- **WHEN** se edita su importe y el relay procesa el evento
- **THEN** el asiento original queda marcado como revertido, existe un contra-asiento que lo referencia, y existe un asiento nuevo por el importe editado
- **AND** los tres asientos balancean

#### Scenario: Editar un gasto no lo bloquea por tener asiento

- **GIVEN** un gasto con asiento posteado
- **WHEN** se edita su categoría
- **THEN** la edición procede normalmente

#### Scenario: Pasar un gasto de transferencia a efectivo cambia la contrapartida

- **GIVEN** un gasto por transferencia con su movimiento bancario y su asiento que acredita banco
- **WHEN** se edita a efectivo y la edición compensa el movimiento bancario
- **THEN** el asiento nuevo acredita la cuenta de caja, porque la huella bancaria neta quedó en cero

#### Scenario: El contra-asiento de edición se fecha en la corrección

- **WHEN** se postea el par de una edición
- **THEN** el contra-asiento queda fechado en el momento de la corrección, mientras el asiento nuevo conserva la fecha de negocio del gasto

#### Scenario: Edición procesada antes que el alta

- **GIVEN** un evento de edición cuyo evento de alta todavía no se procesó
- **WHEN** el relay intenta procesar la edición
- **THEN** falla de forma recuperable, el evento queda pendiente, el lote continúa, y en la corrida siguiente —ya posteada el alta— el par se postea correctamente
