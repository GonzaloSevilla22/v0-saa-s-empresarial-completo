## ADDED Requirements

### Requirement: La compra a crédito nacida de un remito postea su cargo como cualquier compra a crédito
El sistema SHALL postear el cargo en la cuenta corriente del proveedor del remito cuando un remito de compra se convierte con una forma de pago de cuenta corriente, con el helper compartido de cargo, el total de la compra, la fecha de la compra como fecha del cargo y el vencimiento resuelto por la cascada del plazo del proveedor (o el vencimiento indicado al convertir), en la misma transacción que la compra. Emitir, editar o anular el remito de compra SHALL NOT tocar la cuenta corriente del proveedor.

#### Scenario: Cargo al convertir, no al recibir
- **GIVEN** un proveedor con plazo de 15 días y un remito de compra pendiente de $10.000
- **WHEN** se convierte con forma de pago de cuenta corriente y fecha 2026-10-10
- **THEN** la cuenta corriente del proveedor recibe un cargo de $10.000 con vencimiento 2026-10-25, y antes de la conversión el saldo del proveedor no había cambiado

#### Scenario: Borrar la compra revierte el cargo
- **WHEN** se borra la compra a crédito nacida del remito
- **THEN** el cargo se compensa en la cuenta corriente del proveedor y el remito vuelve a pendiente
