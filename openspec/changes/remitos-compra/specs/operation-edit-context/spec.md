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
