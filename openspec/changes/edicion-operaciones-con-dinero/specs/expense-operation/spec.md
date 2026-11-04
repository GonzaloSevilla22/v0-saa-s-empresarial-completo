## MODIFIED Requirements

### Requirement: El estado de bloqueo del gasto es visible antes de intentar la acción

La interfaz SHALL exponer, para cada gasto del listado:

- si su edición está bloqueada y por qué, como un motivo calculado por el servidor;
- si su borrado está bloqueado por no haber sesión de caja abierta donde compensar;
- qué libros tiene afectados según su huella neta.

Estos estados SHALL derivarse de los **mismos predicados** que evalúan los guards del servidor. La interfaz SHALL deshabilitar cada control mostrando la razón, en lugar de dejar que el usuario descubra el bloqueo recién al recibir el error.

El dinero registrado SHALL NOT bloquear la edición del gasto (capability `operation-money-edit`). El plan de la edición, con sus posibles bloqueos (caja sin sesión abierta, período bancario conciliado, permiso), se presenta antes de confirmar.

Estos estados SHALL viajar como **campos derivados de la lectura del gasto**, calculados en el servidor con la misma huella neta que usan la edición y el borrado, con el mismo mecanismo con el que ya viajan los estados de una venta. El predicado SHALL NOT reimplementarse en el cliente ni derivarse de consultas sueltas por fila.

Para que esos derivados lleguen a la pantalla, el listado de gastos SHALL leerse por el camino de lectura del servidor de la aplicación, paginado y con sus filtros resueltos en el servidor, con el mismo contrato de paginación que ya usa el listado de ventas. El estado SHALL NOT depender de una lectura directa de la tabla de gastos, que sólo expone sus propias columnas y por lo tanto no puede exponer un derivado de los libros.

El diálogo de borrado SHALL enumerar qué se va a compensar en cada libro antes de pedir confirmación, usando esos mismos derivados.

#### Scenario: Gasto con movimiento de caja en el listado

- **WHEN** un usuario ve en el listado un gasto que descontó de la caja
- **THEN** el control de edición está habilitado
- **AND** el listado indica que el gasto tiene dinero registrado en la caja

#### Scenario: Gasto sin dinero registrado en el listado

- **WHEN** un usuario ve en el listado un gasto sin forma de pago imputada
- **THEN** el control de edición está habilitado

#### Scenario: El listado recibe el estado del servidor

- **WHEN** se lista una página de gastos
- **THEN** cada fila llega con su motivo de bloqueo de edición (si lo hay), su estado de bloqueo de borrado y la indicación de qué libros tiene afectados
- **AND** esos valores provienen de la misma huella neta que evalúan la edición y el borrado

#### Scenario: Borrado deshabilitado con la caja cerrada

- **WHEN** un usuario ve en el listado un gasto con huella neta de caja mientras no hay ninguna sesión abierta en esa caja
- **THEN** el control de borrado aparece deshabilitado
- **AND** la razón del bloqueo es visible antes de intentar la acción

#### Scenario: Diálogo de borrado de un gasto con dinero registrado

- **WHEN** un usuario abre el diálogo de borrado de un gasto que descontó de la caja y registró un egreso bancario
- **THEN** el diálogo enumera la reversión del movimiento de caja y la del movimiento bancario antes de pedir confirmación

## ADDED Requirements

### Requirement: La edición de un gasto con dinero ajusta caja y banco
El sistema SHALL editar un gasto con movimiento de caja o bancario aplicando el contrato de la capability `operation-money-edit` sobre sus dos libros —caja y banco— y ningún otro: un gasto no tiene cuenta corriente.

- El gasto conserva su identificador, que es la referencia de su huella.
- La edición SHALL bloquear la fila del gasto antes de calcular el plan.
- La edición SHALL seguir rechazando una forma de pago de cuenta corriente.
- Cambiar sólo la categoría, la descripción o el centro de costo SHALL NOT escribir en ningún libro.
- Cambiar el importe, la forma de pago, la caja o la cuenta bancaria SHALL compensar la huella y registrar el efecto nuevo en la misma transacción que el `UPDATE` del gasto.

#### Scenario: Corregir el importe de un gasto en efectivo del día
- **GIVEN** un gasto en efectivo de 500 registrado hoy en la sesión abierta
- **WHEN** se edita a 300
- **THEN** la sesión recibe un `expense_reversal` de +500 y un `expense` de −300

#### Scenario: Pasar un gasto de efectivo a transferencia
- **GIVEN** un gasto en efectivo con movimiento de caja, una sesión abierta en esa caja y una cuenta bancaria activa
- **WHEN** se edita a transferencia con esa cuenta bancaria
- **THEN** la caja recibe el `expense_reversal` y el banco el egreso nuevo, y el asiento de la edición acredita banco

#### Scenario: Corregir la categoría de un gasto con caja cerrada
- **GIVEN** un gasto en efectivo cuya sesión de caja ya cerró y ninguna sesión abierta
- **WHEN** se edita sólo su categoría
- **THEN** la edición se aplica sin movimientos de caja y sin exigir sesión abierta

## REMOVED Requirements

### Requirement: El gasto con dinero posteado es inmutable
**Reason**: El PO pidió (2026-10-14) poder editar todo gasto aunque tenga dinero registrado. La edición ajusta caja y banco en lugar de rechazarse.
**Migration**: Ver "La edición de un gasto con dinero ajusta caja y banco" y la capability `operation-money-edit`. Se retiran de `rpc_update_expense` los dos `P0423` (`expense_has_cash_movement_immutable` y `expense_has_bank_movement_immutable`) y el indicador `is_payment_locked` del listado. La existencia de un asiento sigue sin bloquear la edición.
