## ADDED Requirements

### Requirement: Borrado atómico de un gasto con compensación de libros

El sistema SHALL ejecutar el borrado de un gasto dentro de una única RPC `SECURITY DEFINER` que evalúe todos sus guards, aplique las compensaciones de los libros afectados y ejecute la eliminación en la misma transacción, de modo que ninguna combinación de fallos deje libros compensados sin gasto borrado ni gasto borrado sin libros compensados.

El borrado SHALL compensar dos libros —caja y banco— y ninguno más: un gasto no tiene cuenta corriente asociada, no mueve stock y no emite eventos al outbox.

El repositorio de la aplicación SHALL emitir una única llamada y SHALL NOT componer la secuencia de compensación del lado de la aplicación. El borrado directo por sentencia SQL SHALL desaparecer del camino de la aplicación, porque un borrado sin compensación deja los movimientos apuntando a un gasto inexistente.

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

#### Scenario: El repositorio no orquesta la compensación

- **WHEN** el backend borra un gasto
- **THEN** emite una única llamada a la RPC de borrado
- **AND** no ejecuta ninguna sentencia de borrado directa sobre la tabla de gastos

### Requirement: Bloqueo del borrado de un gasto en efectivo sin sesión de caja abierta

El sistema SHALL rechazar con el código de error `P0426` el borrado de un gasto que descontó de la caja cuando no exista una sesión abierta en esa misma caja, indicando que hay que abrir la caja para poder borrarlo.

El motivo SHALL ser que el ledger de caja es append-only por sesión: el contra-movimiento va a la sesión abierta actual y jamás altera la sesión original ni su arqueo. Es el mismo criterio y el mismo código de error que ya rige para el borrado de una venta en efectivo.

#### Scenario: Caja cerrada

- **GIVEN** un gasto que descontó de la caja y ninguna sesión abierta en esa caja
- **WHEN** un usuario intenta borrarlo
- **THEN** la operación es rechazada con `P0426`
- **AND** el gasto y todos sus movimientos quedan intactos

#### Scenario: Caja abierta

- **GIVEN** un gasto que descontó de la caja y una sesión abierta en esa caja
- **WHEN** un usuario lo borra
- **THEN** el borrado procede con su contra-movimiento en la sesión abierta

#### Scenario: La superficie anticipa el bloqueo

- **WHEN** un usuario ve en el listado un gasto en efectivo mientras la caja está cerrada
- **THEN** el control de borrado aparece deshabilitado
- **AND** la razón del bloqueo es visible antes de intentar la acción
