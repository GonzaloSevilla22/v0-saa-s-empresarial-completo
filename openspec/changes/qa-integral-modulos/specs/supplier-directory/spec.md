# supplier-directory — Delta

## MODIFIED Requirements

### Requirement: La baja de un proveedor es soft delete

El sistema SHALL borrar proveedores mediante soft delete (`deleted_at` + `deleted_by`), nunca con `DELETE` físico, aplicando la política única de maestros (RN-B1/RN-B2) a través del mismo helper centralizado que usan los demás maestros. Un proveedor borrado SHALL desaparecer de todas las lecturas por defecto, y las compras que lo referencian SHALL seguir siendo legibles.

La baja de un proveedor con saldo abierto en su cuenta corriente (`supplier_accounts.balance ≠ 0`) SHALL rechazarse con 409 (`P0409` / conflicto RFC 7807) informando el saldo pendiente, de modo que una deuda nunca quede inalcanzable desde la interfaz — la cuenta corriente de un proveedor solo se alcanza desde su fila del listado. El usuario SHALL poder saldar o ajustar la cuenta primero y borrar después. *(Resolución de OQ-1 por la opción recomendada; si el PO elige advertir en lugar de bloquear, este párrafo se reescribe antes del apply.)*

#### Scenario: Baja con deuda abierta es rechazada

- **GIVEN** un proveedor con saldo distinto de cero en su cuenta corriente
- **WHEN** se intenta darlo de baja
- **THEN** la operación responde 409 con el saldo pendiente en el detalle
- **AND** el proveedor sigue visible y su cuenta corriente sigue alcanzable

#### Scenario: La interfaz explica el bloqueo

- **WHEN** el usuario intenta borrar desde el listado un proveedor con deuda
- **THEN** ve el motivo traducido con el monto del saldo, no un error crudo

#### Scenario: Baja con saldo en cero procede

- **GIVEN** un proveedor con cuenta corriente saldada (o sin cuenta corriente)
- **WHEN** se lo da de baja
- **THEN** el soft delete procede como hasta ahora

#### Scenario: Borrar un proveedor lo saca de las lecturas

- **GIVEN** un proveedor existente sin saldo abierto
- **WHEN** se lo borra
- **THEN** la fila persiste con `deleted_at` y `deleted_by` seteados, y deja de aparecer en el listado y en el selector

#### Scenario: Las compras del proveedor borrado siguen siendo legibles

- **GIVEN** compras imputadas a un proveedor
- **WHEN** el proveedor se borra
- **THEN** las compras conservan su `supplier_id` y el nombre del proveedor sigue siendo resoluble para su lectura

#### Scenario: Borrar dos veces responde 404 sin modificar filas

- **WHEN** se borra un proveedor ya borrado
- **THEN** la operación responde 404 —el proveedor borrado ya no es visible para las lecturas— y no modifica ninguna fila: `deleted_at` y `deleted_by` conservan los valores del primer borrado. Es el mismo comportamiento que el borrado de un cliente

## ADDED Requirements

### Requirement: La pantalla de cuenta corriente identifica al proveedor y degrada la cuenta inexistente

El sistema SHALL mostrar en el encabezado de `/proveedores/{id}/cuenta` el nombre del proveedor (mismo patrón que la pantalla equivalente de cliente), de modo que el usuario sepa en qué cuenta está parado antes de registrar un pago. Cuando el proveedor aún no tiene fila en `supplier_accounts` (nunca tuvo una compra a crédito), la pantalla SHALL presentar el estado "sin cuenta aún" con saldo $0 — nunca un banner de error para un caso normal.

#### Scenario: El encabezado nombra al proveedor

- **WHEN** el usuario abre la cuenta corriente de un proveedor
- **THEN** el nombre del proveedor es visible en el encabezado de la página

#### Scenario: Cuenta inexistente no es un error

- **GIVEN** un proveedor sin ninguna compra a crédito
- **WHEN** el usuario abre su cuenta corriente y el GET de cuenta responde 404
- **THEN** la pantalla muestra el estado normal de saldo $0 sin ningún banner destructivo
