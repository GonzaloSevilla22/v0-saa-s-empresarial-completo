## ADDED Requirements

### Requirement: La compra nacida de un remito es inmutable
El sistema SHALL rechazar la edición de una compra nacida de un remito de compra con `P0423 delivery_note_purchase_locked`, antes de los bloqueos por dinero posteado y antes de cualquier reversa o escritura, sin anular nada ni mover stock. El listado de compras SHALL exponerlo y deshabilitar "Editar" con el motivo: para corregirla, se borra la compra, se edita el remito y se vuelve a convertir.

#### Scenario: Editar la compra de un remito
- **GIVEN** una compra a crédito nacida de un remito de compra
- **WHEN** se intenta editar su cabecera o sus líneas
- **THEN** la operación falla con `P0423 delivery_note_purchase_locked`, y ni el stock, ni el ledger, ni la cuenta corriente del proveedor cambian

#### Scenario: Editar deshabilitado en el listado
- **WHEN** el usuario ve una compra nacida de un remito en `/compras`
- **THEN** la acción "Editar" está deshabilitada con el motivo de que la compra nació del remito

### Requirement: El listado de compras expone la borrabilidad de la compra nacida de un remito
El listado de compras SHALL exponer, para cada compra nacida de un remito, su remito de origen y si la sucursal del remito está activa, derivado en el servidor con el mismo predicado que evalúa el borrado. La interfaz SHALL deshabilitar "Eliminar" con su motivo cuando el usuario no tiene el permiso de anular remitos de compra o cuando la sucursal del remito está inactiva, y el motivo de remito de "Editar" SHALL tener precedencia sobre el bloqueo por dinero posteado.

#### Scenario: Eliminar deshabilitado para el rol de compras
- **GIVEN** una compra nacida de un remito y un usuario con rol `purchases`
- **WHEN** abre `/compras`
- **THEN** "Eliminar" está deshabilitado con el motivo de que borrarla reabre el remito y requiere administrador o dueño

#### Scenario: Eliminar deshabilitado con la sucursal del remito inactiva
- **GIVEN** una compra nacida de un remito cuya sucursal se desactivó
- **WHEN** un administrador abre `/compras`
- **THEN** "Eliminar" está deshabilitado con el motivo de reactivar la sucursal del remito
