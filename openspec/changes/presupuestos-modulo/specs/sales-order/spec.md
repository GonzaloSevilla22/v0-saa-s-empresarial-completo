## ADDED Requirements

### Requirement: La orden nacida de la conversión de un presupuesto se confirma en la misma transacción
El sistema SHALL crear y confirmar en una única transacción la orden de venta que nace de convertir un presupuesto en venta, de modo que esa orden nunca quede observable en estado `draft`. La confirmación SHALL delegar en el mismo núcleo de confirmación que usan `confirm()` y `quickSale()`, sin una segunda implementación de sus efectos, y SHALL producir exactamente los mismos efectos que una venta rápida con la misma forma de pago:

- descuento de stock en la unidad base;
- caja, cuenta corriente o banco;
- filas legacy `sales`/`sale_items`;
- evento `SaleConfirmed`;
- historial `draft → confirmed`.

El orden de bloqueo de esa transacción SHALL empezar por el presupuesto de origen, antes de cualquier fila de productos o de venta.

#### Scenario: no queda una orden draft visible
- **WHEN** se convierte un presupuesto en venta
- **THEN** al terminar la transacción la orden creada está en `confirmed`, y ninguna otra transacción la observó en `draft`

#### Scenario: misma venta que el POS
- **WHEN** se cobra la misma mercadería con la misma forma de pago de `kind = 'cash'`, una vez por venta rápida y otra por conversión de un presupuesto, en cuentas equivalentes
- **THEN** las dos producen el mismo conjunto de efectos sobre stock, caja, filas legacy de `sales`, evento de outbox y transición de estado

#### Scenario: un fallo de confirmación revierte la aceptación
- **WHEN** la confirmación de la orden nacida de un presupuesto falla por stock insuficiente
- **THEN** tampoco queda la orden `draft` ni el presupuesto `accepted`

### Requirement: La venta expone su presupuesto de origen
El sistema SHALL exponer, en los read models de ventas y de órdenes de venta, el presupuesto que originó cada venta (`source_quote_id` y su número visible), derivado de `sales_orders.source_quote_id` sin columnas denormalizadas. La interfaz de `/ventas` SHALL mostrar en esas operaciones el indicador "Desde presupuesto P-NNNNNNNN", con enlace al detalle del presupuesto. Una venta que no nació de un presupuesto NOT SHALL mostrar el indicador.

#### Scenario: venta nacida de un presupuesto
- **GIVEN** una venta generada al convertir el presupuesto P-00000012
- **WHEN** el usuario abre `/ventas`
- **THEN** la operación muestra "Desde presupuesto P-00000012" y el enlace lleva a `/presupuestos/<id>`

#### Scenario: venta del POS sin presupuesto
- **WHEN** el usuario ve una venta hecha en el POS
- **THEN** no aparece ningún indicador de presupuesto de origen
