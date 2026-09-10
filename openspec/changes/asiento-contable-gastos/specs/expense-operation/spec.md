## MODIFIED Requirements

### Requirement: El alta, la edición y el borrado de un gasto son operaciones atómicas de servidor

El sistema SHALL ejecutar el alta, la edición y el borrado de un gasto dentro de una RPC `SECURITY DEFINER` propia por operación, con `search_path` fijo, que evalúe todos sus guards y aplique la escritura del gasto **y** todos sus efectos en libros en la misma transacción.

El rastro contable SHALL formar parte de esa unidad atómica: la emisión del evento contable del gasto hacia el outbox SHALL ocurrir dentro de la misma transacción que la escritura del gasto y que sus movimientos de caja y banco, como una inserción plana sin manejador de excepciones. No SHALL existir ninguna combinación de fallos que deje el dinero movido y el evento contable ausente, ni el evento contable emitido y el gasto revertido.

El repositorio de la aplicación SHALL NOT componer SQL ni orquestar pasos de negocio: SHALL emitir una única llamada por operación.

Ninguna combinación de fallos SHALL poder dejar un gasto sin sus movimientos ni movimientos sin su gasto.

El posteo del asiento propiamente dicho SHALL quedar **fuera** de esa transacción, a cargo del consumidor contable del relay: la operación de gasto produce el hecho contable, no lo registra. Esta asimetría es deliberada — el asiento es asincrónico por diseño y su fallo no puede tumbar el alta de un gasto.

#### Scenario: Fallo al postear el movimiento de caja

- **WHEN** el alta de un gasto en efectivo falla al registrar el movimiento de caja
- **THEN** la transacción completa se revierte
- **AND** no queda ninguna fila nueva en gastos
- **AND** no queda ningún evento contable de gasto

#### Scenario: Fallo al postear el movimiento bancario

- **WHEN** el alta de un gasto por transferencia falla al registrar el movimiento bancario
- **THEN** la transacción completa se revierte
- **AND** no queda ninguna fila nueva en gastos
- **AND** no queda ningún evento contable de gasto

#### Scenario: El repositorio no orquesta pasos de negocio

- **WHEN** el backend crea, edita o borra un gasto
- **THEN** emite una única llamada a la RPC correspondiente
- **AND** no evalúa guards ni compone secuencias de escritura del lado de la aplicación

#### Scenario: El evento contable viaja con la mutación

- **WHEN** un alta, una edición o un borrado de gasto commitea y corresponde emitir su evento
- **THEN** el evento existe en el outbox, escrito por la misma RPC y en la misma transacción que la mutación
- **AND** el asiento todavía no existe, porque lo postea el relay más tarde

### Requirement: El gasto con dinero posteado es inmutable

El sistema SHALL rechazar con el código de error `P0423` la edición de un gasto que tenga un movimiento de caja o un movimiento bancario asociado, evaluando los guards **antes** de cualquier escritura, con los mismos predicados de localización que usa el borrado y con el mismo criterio uniforme que ya rige para ventas y compras.

El mensaje de error SHALL distinguir cuál de los dos libros produjo el bloqueo.

El camino de corrección SHALL ser borrar y volver a cargar, que este mismo cambio vuelve seguro al dotar al borrado de compensación.

Un gasto sin movimientos asociados SHALL seguir siendo plenamente editable.

La existencia de un **asiento contable** SHALL NOT sumarse a los predicados de bloqueo. La inmutabilidad de un gasto la determinan sus movimientos de dinero, y sólo ellos: un gasto con asiento posteado pero sin movimiento de caja ni bancario SHALL seguir siendo plenamente editable, y su edición SHALL corregir el asiento por el par contra-asiento más asiento nuevo en lugar de impedirse. Es el mismo criterio ya vigente para la operación de venta, y lo contrario volvería inmutable a todo gasto en cuanto el rastro contable se ponga en marcha, rompiendo dos escenarios normativos de este mismo requirement.

#### Scenario: Editar un gasto con movimiento de caja

- **GIVEN** un gasto en efectivo que registró su egreso de caja
- **WHEN** un usuario intenta editar su importe
- **THEN** la operación es rechazada con `P0423`
- **AND** el mensaje indica que el bloqueo proviene del movimiento de caja
- **AND** ni el gasto ni el movimiento cambian

#### Scenario: Editar un gasto con movimiento bancario

- **GIVEN** un gasto por transferencia que registró su egreso bancario
- **WHEN** un usuario intenta editar su importe
- **THEN** la operación es rechazada con `P0423`
- **AND** el mensaje indica que el bloqueo proviene del movimiento bancario

#### Scenario: Editar un gasto sin dinero posteado

- **GIVEN** un gasto sin forma de pago imputada
- **WHEN** un usuario edita su importe, su categoría o su centro de costo
- **THEN** la edición procede normalmente

#### Scenario: Los gastos históricos siguen siendo editables

- **GIVEN** un gasto anterior a este cambio, sin forma de pago ni movimientos
- **WHEN** un usuario lo edita
- **THEN** la edición procede normalmente

#### Scenario: El asiento no bloquea la edición

- **GIVEN** un gasto sin movimiento de caja ni bancario cuyo asiento contable ya fue posteado
- **WHEN** un usuario edita su importe
- **THEN** la edición procede normalmente
- **AND** se emite el evento que corrige el asiento, sin ningún rechazo por `P0423`
