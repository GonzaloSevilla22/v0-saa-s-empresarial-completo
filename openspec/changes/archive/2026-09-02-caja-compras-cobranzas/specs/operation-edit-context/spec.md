## MODIFIED Requirements

### Requirement: Exposición del estado de borrabilidad en el listado
El sistema SHALL exponer al listado de operaciones, derivado de lectura y nunca desde una columna denormalizada, si una operación es borrable y qué razón la bloquea cuando no lo es, y SHALL incluir entre esas razones la **falta de una sesión de caja abierta** cuando la operación tiene un movimiento de caja posteado que su borrado tendría que compensar.

Los derivados que alimentan esa exposición SHALL calcularse en el servidor con los **mismos predicados** que evalúa el comando de borrado. La razón es que uno de ellos —la existencia de una sesión abierta en la caja afectada— depende de un estado que el listado no tiene y que derivarlo en el cliente obligaría a traer las sesiones de todas las cajas para pintar una lista de operaciones.

El listado de compras SHALL exponer, además de los indicadores de cargo en cuenta corriente y de movimiento bancario que ya expone, el indicador de **movimiento de caja** y el de **borrado bloqueado**, que hasta ahora no calculaba porque la compra no tenía forma de tocar la caja.

#### Scenario: Operación facturada en el listado
- **WHEN** el listado incluye una operación con comprobante fiscal emitido
- **THEN** la operación se expone como no borrable
- **AND** la razón informada es el comprobante fiscal

#### Scenario: Operación borrable con compensación pendiente
- **WHEN** el listado incluye una operación con dinero posteado y sin comprobante
- **THEN** la operación se expone como borrable
- **AND** se exponen los libros que su borrado compensaría

#### Scenario: Compra con movimiento de caja y sesión abierta
- **WHEN** el listado incluye una compra que descontó de la caja y existe una sesión abierta en esa caja
- **THEN** la compra se expone como borrable
- **AND** entre los libros a compensar figura la caja

#### Scenario: Compra con movimiento de caja y sin sesión abierta
- **WHEN** el listado incluye una compra que descontó de la caja y no existe ninguna sesión abierta en esa caja
- **THEN** la compra se expone como no borrable
- **AND** la razón informada es que hay que abrir la caja

## ADDED Requirements

### Requirement: El bloqueo de edición de una compra alcanza su movimiento de caja

El sistema SHALL incluir el movimiento de caja de una compra entre los predicados que bloquean su edición, tanto en el comando de edición como en el derivado de lectura que el listado consume, usando **el mismo predicado en ambos lados**.

El requirement general de inmutabilidad por dinero posteado ya nombra al movimiento de caja como causa de bloqueo, pero para la compra ese caso era **inalcanzable**: ningún camino de alta de compra producía un movimiento de caja, y por eso ni el guard del comando de edición ni el derivado de lectura del listado lo consultaban. Este cambio lo vuelve alcanzable, de modo que ambos SHALL incorporarlo o el bloqueo quedaría declarado y no aplicado.

El derivado de lectura y el guard SHALL localizar el movimiento con la misma convención de referencia que ya usan los otros dos predicados de la compra —el identificador de operación—, para que no queden dos criterios capaces de divergir.

Ninguna compra existente cambia de comportamiento al aplicarse este requirement: al momento del cambio no hay ninguna compra con movimiento de caja posteado. El bloqueo alcanza únicamente a las que se registren con impacto en caja de aquí en adelante.

#### Scenario: Editar una compra con movimiento de caja es rechazado

- **GIVEN** una compra registrada con impacto en caja confirmado, que generó un movimiento de caja
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y el saldo esperado de la sesión no cambia
- **AND** el mensaje nombra el movimiento de caja como causa

#### Scenario: El listado anticipa el bloqueo de edición por caja

- **WHEN** el usuario abre el listado de compras y una de ellas tiene movimiento de caja posteado
- **THEN** la acción de editar aparece deshabilitada con la razón visible, en vez de fallar recién al confirmar

#### Scenario: Una compra sin impacto en caja sigue siendo editable

- **GIVEN** una compra en efectivo registrada sin confirmar el impacto en caja, sin cargo en cuenta corriente y sin movimiento bancario
- **WHEN** se edita esa operación
- **THEN** la edición procede normalmente con el acarreo de contexto ya establecido

#### Scenario: Las compras existentes no cambian de comportamiento

- **GIVEN** las compras registradas antes de este cambio
- **WHEN** se consulta cuáles quedan bloqueadas por movimiento de caja
- **THEN** ninguna lo está, porque ninguna tiene un movimiento de caja asociado
