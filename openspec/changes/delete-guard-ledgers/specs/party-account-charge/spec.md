## ADDED Requirements

### Requirement: Contraparte de reversión del cargo de tercero
El helper compartido de cargo en cuenta de tercero SHALL exponer una contraparte de reversión que atienda por igual a clientes y proveedores, de modo que el borrado de una venta y el de una compra reviertan su cargo por el mismo camino, sin lógica duplicada por dominio.

#### Scenario: Reversión de un cargo de cliente
- **WHEN** el borrado de una venta revierte su cargo de cuenta corriente
- **THEN** la reversión se resuelve por el helper compartido
- **AND** registra el movimiento negativo en la cuenta del cliente

#### Scenario: Reversión de un cargo de proveedor
- **WHEN** el borrado de una compra revierte su cargo de cuenta corriente
- **THEN** la reversión se resuelve por el mismo helper compartido
- **AND** registra el movimiento negativo en la cuenta del proveedor

#### Scenario: Tipo de tercero inválido
- **WHEN** se invoca la reversión con un tipo de tercero distinto de cliente o proveedor
- **THEN** el helper falla con el código de error `P0400`

### Requirement: Emisión del evento de reversión de cargo
El helper de reversión SHALL emitir el evento de dominio correspondiente a la reversión del cargo, para que los consumidores posteriores puedan reaccionar por el mismo mecanismo con que reaccionan al cargo original.

#### Scenario: Reversión de cargo de cliente
- **WHEN** se revierte el cargo de cuenta corriente de un cliente
- **THEN** se emite un evento de reversión con la cuenta, el cliente, la operación y el importe revertido

#### Scenario: Atribución del movimiento de reversión
- **WHEN** se registra un movimiento de reversión desde una sesión de usuario
- **THEN** el movimiento queda atribuido al usuario que ejecuta el borrado
