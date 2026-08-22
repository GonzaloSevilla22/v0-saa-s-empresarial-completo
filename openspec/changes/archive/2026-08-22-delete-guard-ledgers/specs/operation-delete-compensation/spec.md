## ADDED Requirements

### Requirement: Borrado atómico de una operación comercial
El sistema SHALL ejecutar el borrado de una operación de venta o de compra dentro de una única RPC `SECURITY DEFINER` (`rpc_delete_sale_operation` / `rpc_delete_purchase_operation`) que evalúe todos sus guards y aplique todas sus compensaciones y el `DELETE` en la misma transacción, de modo que ninguna combinación de fallos deje libros compensados sin operación borrada ni operación borrada sin libros compensados.

#### Scenario: Todo o nada ante un fallo de compensación
- **WHEN** el borrado de una operación falla al compensar cualquiera de los libros
- **THEN** la transacción completa se revierte
- **AND** la operación sigue existiendo
- **AND** ningún libro queda con contra-movimientos parciales

#### Scenario: El repositorio Python no orquesta pasos de negocio
- **WHEN** el backend borra una operación
- **THEN** emite una única llamada a la RPC correspondiente
- **AND** no evalúa guards ni compone secuencias de compensación del lado de la aplicación

### Requirement: Localización de movimientos bajo las dos convenciones de referencia
El sistema SHALL localizar los movimientos financieros de una operación consultando las dos convenciones de referencia que conviven en los libros — el `operation_id` de la operación (camino del formulario) y el `id` de la `sales_order` asociada (camino del POS) — usando el mismo predicado que ya emplean el guard `P0423` de la edición y su espejo de lectura en el listado.

#### Scenario: Operación creada por el formulario
- **WHEN** se borra una operación cuyos movimientos referencian su `operation_id`
- **THEN** el sistema los encuentra y los compensa

#### Scenario: Operación creada por el POS
- **WHEN** se borra una venta cuyos movimientos referencian el `id` de su `sales_order`
- **THEN** el sistema los encuentra y los compensa

#### Scenario: Operación editada antes de borrarse
- **WHEN** se borra una operación que fue editada, y la edición regeneró su `operation_id`
- **THEN** el sistema compensa los movimientos vigentes de la operación
- **AND** no deja movimientos sin compensar por referenciar un identificador anterior

### Requirement: Bloqueo del borrado de una operación con comprobante fiscal
El sistema SHALL rechazar con el código de error `P0423` el borrado de una venta que tenga un comprobante fiscal en estado `pending_cae` o `authorized`, aplicando el mismo predicado que bloquea su edición.

#### Scenario: Venta facturada
- **WHEN** un usuario intenta borrar una venta con comprobante `authorized`
- **THEN** el sistema rechaza la operación con `P0423`
- **AND** informa que el camino de corrección es la Nota de Crédito
- **AND** la venta, su comprobante y todos sus movimientos quedan intactos

#### Scenario: Venta sin comprobante
- **WHEN** un usuario borra una venta sin comprobante fiscal emitido
- **THEN** el borrado procede con sus compensaciones

### Requirement: Bloqueo cuando la compensación violaría un invariante de saldo
El sistema SHALL rechazar con el código de error `P0425` el borrado de una operación cuya reversión de cargo dejaría el saldo de la cuenta corriente del cliente o del proveedor por debajo de cero, indicando que debe registrarse primero la devolución del pago.

#### Scenario: El cliente ya canceló la venta
- **WHEN** se intenta borrar una venta a crédito cuyo cargo ya fue cancelado por el cliente
- **THEN** el sistema rechaza la operación con `P0425`
- **AND** el mensaje indica que debe registrarse la devolución del pago antes de borrar
- **AND** el saldo del cliente no se modifica

#### Scenario: El cliente todavía debe la venta
- **WHEN** se borra una venta a crédito cuyo cargo sigue impago
- **THEN** el borrado procede
- **AND** el saldo del cliente vuelve exactamente al valor previo a la venta

### Requirement: Cancelación de la orden de venta al borrar una venta del POS
El sistema SHALL cancelar la `sales_order` asociada en la misma transacción cuando se borra la venta que originó, en lugar de dejarla apuntando a una venta inexistente.

#### Scenario: Borrado de una venta del POS
- **WHEN** se borra una venta creada desde el POS
- **THEN** su `sales_order` queda en estado `canceled`
- **AND** no queda ninguna orden confirmada referenciando una operación de venta inexistente

### Requirement: Diálogo de borrado que enumera la compensación
La interfaz SHALL presentar, antes de confirmar el borrado de una operación, el detalle de qué se va a compensar en cada libro afectado, y SHALL deshabilitar el control de borrado indicando la razón cuando la operación no sea borrable.

#### Scenario: Operación con dinero posteado
- **WHEN** un usuario abre el diálogo de borrado de una operación con cargo en cuenta corriente y movimiento de caja
- **THEN** el diálogo enumera la reversión del cargo y la del movimiento de caja antes de pedir confirmación

#### Scenario: Operación facturada
- **WHEN** un usuario ve en el listado una operación con comprobante fiscal emitido
- **THEN** el control de borrado aparece deshabilitado
- **AND** la razón del bloqueo es visible, con el mismo patrón que el lock de edición

#### Scenario: Presentación responsive y por tema
- **WHEN** el diálogo de borrado se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
