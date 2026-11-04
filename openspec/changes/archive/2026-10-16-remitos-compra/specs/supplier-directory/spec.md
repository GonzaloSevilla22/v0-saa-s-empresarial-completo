## ADDED Requirements

### Requirement: El selector de proveedor con alta inline es un componente compartido
El sistema SHALL ofrecer el selector buscable de proveedor con alta en el lugar como un único componente compartido, que usan el formulario de compra y el formulario del remito de compra, de modo que el proveedor recién creado quede seleccionado sin perder lo cargado y que ninguna pantalla mantenga su propia copia del selector.

#### Scenario: Mismo selector en compra y en remito
- **WHEN** el usuario crea un proveedor desde el formulario de compra o desde el del remito de compra
- **THEN** el proveedor queda creado y seleccionado, con el mismo comportamiento en las dos pantallas

### Requirement: Acceso a los remitos de compra desde el proveedor
El sistema SHALL ofrecer en el listado de proveedores la acción "Nuevo remito de compra" con el proveedor preseleccionado, y en la cuenta corriente del proveedor las acciones "Nuevo remito" y "Ver remitos", que llevan a la pestaña de compra de `/remitos` filtrada por ese proveedor.

#### Scenario: Nuevo remito desde el proveedor
- **WHEN** el usuario elige "Nuevo remito de compra" en la fila de un proveedor
- **THEN** navega a `/remitos/nuevo?tipo=compra&proveedor=<id>` con el proveedor preseleccionado

#### Scenario: Ver remitos del proveedor
- **WHEN** el usuario elige "Ver remitos" en la cuenta corriente de un proveedor
- **THEN** navega a `/remitos?sentido=compra&proveedor=<id>` y ve sólo los remitos de compra de ese proveedor

### Requirement: Un proveedor con remitos de compra pendientes no se borra
El sistema SHALL rechazar el borrado de un proveedor que tenga remitos de compra pendientes en la cuenta con el mismo conflicto `409 P0409` que ya rechaza el borrado de un proveedor con saldo abierto, con un mensaje que diga cuántos remitos pendientes tiene y que hay que convertirlos o anularlos antes de borrarlo, porque el borrado lo sacaría de las listas y dejaría inalcanzables los remitos y la deuda futura con él. Los remitos convertidos o anulados, o los de otra cuenta, SHALL NOT impedir el borrado.

#### Scenario: Proveedor con un remito pendiente
- **GIVEN** un proveedor con un remito de compra `issued`
- **WHEN** un usuario intenta borrar el proveedor
- **THEN** la operación falla con `409 P0409`, el mensaje dice que tiene 1 remito de compra pendiente y el proveedor sigue vivo

#### Scenario: Proveedor con remitos ya cerrados
- **GIVEN** un proveedor sin saldo cuyos remitos de compra están convertidos o anulados
- **WHEN** un usuario lo borra
- **THEN** el proveedor se da de baja como hoy
