# operation-delete-compensation Specification

## Purpose
TBD - created by archiving change delete-guard-ledgers. Update Purpose after archive.
## Requirements
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

### Requirement: El borrado de un gasto se incorpora al contrato transversal de compensación de libros

El sistema SHALL ejecutar el borrado de un gasto bajo el mismo contrato transversal que ya rige para el borrado de una venta: los guards se evalúan y las compensaciones se aplican en la misma transacción que la eliminación, de modo que ninguna combinación de fallos deje libros compensados sin operación borrada ni operación borrada sin libros compensados.

Para el gasto los libros compensables SHALL ser exactamente dos —caja y banco— y ninguno más: un gasto no tiene contraparte con cuenta corriente, no mueve stock y no emite eventos al outbox.

El detalle normativo de cada compensación SHALL vivir en la capability del libro que la recibe —`cash-movement` para el contra-movimiento de caja y su bloqueo cuando no hay sesión abierta, `bank-movement` para el movimiento espejo—, y el contrato de RPC única y de no orquestación desde la aplicación SHALL vivir en `expense-operation`. SHALL NOT duplicarse ninguno de los dos en esta capability.

#### Scenario: Todo o nada ante un fallo de compensación

- **WHEN** el borrado de un gasto falla al compensar cualquiera de los dos libros
- **THEN** la transacción completa se revierte
- **AND** el gasto sigue existiendo
- **AND** ningún libro queda con contra-movimientos parciales

#### Scenario: Gasto con impacto en los dos libros

- **GIVEN** un gasto que descontó de la caja y otro que registró un egreso bancario
- **WHEN** se borra cada uno
- **THEN** cada libro recibe su contra-movimiento en la misma transacción del borrado
- **AND** los saldos vuelven a los valores previos al gasto

#### Scenario: Gasto sin impacto en libros

- **WHEN** se borra un gasto sin forma de pago imputada
- **THEN** el borrado procede sin ninguna compensación
- **AND** no se exige ninguna precondición de caja ni de banco

### Requirement: El borrado de una compra compensa cuatro libros, no tres

El sistema SHALL incorporar la caja al contrato transversal de compensación del borrado de una compra, de modo que los libros compensables de esa operación pasen a ser **cuatro** —cuenta corriente del proveedor, caja, banco y stock— y todos se evalúen y compensen en la misma transacción que la eliminación.

La pata de caja SHALL evaluarse **antes** que la bancaria y la de stock, para que el rechazo por falta de sesión de caja abierta ocurra antes de haber tocado los libros más baratos de deshacer y no deje trabajo a medias que la transacción tenga que revertir.

El detalle normativo del contra-movimiento de caja —su tipo, su signo, su destino cuando la sesión original ya cerró, su bloqueo por falta de sesión abierta y su disparo por existencia y no por signo— SHALL vivir en la capability `cash-movement` y SHALL NOT duplicarse acá, para que la regla tenga una sola fuente de verdad.

#### Scenario: Todo o nada ante un fallo de compensación de caja

- **WHEN** el borrado de una compra falla al compensar la caja
- **THEN** la transacción completa se revierte
- **AND** la compra sigue existiendo
- **AND** ni la cuenta corriente, ni el banco, ni el stock quedan con contra-movimientos parciales

#### Scenario: Compra con impacto en los cuatro libros

- **GIVEN** una compra que cargó la cuenta corriente de un proveedor, descontó de la caja, registró un egreso bancario e ingresó stock
- **WHEN** se borra
- **THEN** cada libro recibe su compensación en la misma transacción del borrado
- **AND** los cuatro saldos vuelven a los valores previos a la compra

#### Scenario: El rechazo por caja cerrada precede a la compensación bancaria y de stock

- **GIVEN** una compra con movimiento de caja posteado y sin sesión abierta en esa caja
- **WHEN** se intenta borrarla
- **THEN** la operación se rechaza
- **AND** no se registró ningún contra-movimiento bancario ni ninguna reversión de stock

#### Scenario: Compra sin impacto en caja

- **WHEN** se borra una compra que nunca descontó de la caja
- **THEN** el borrado procede con las compensaciones que correspondan
- **AND** no se exige ninguna sesión de caja abierta

### Requirement: El diálogo de borrado de una compra enumera las cuatro compensaciones

La interfaz SHALL enumerar, antes de confirmar el borrado de una compra, cada uno de los libros que la operación va a compensar —cargo en la cuenta corriente del proveedor, movimiento de caja, movimiento bancario y reposición de stock— y SHALL deshabilitar el control de borrado indicando la razón cuando la compra no sea borrable porque falta una sesión de caja abierta.

Los indicadores que alimentan esa enumeración SHALL derivarse en el servidor con los **mismos predicados** que evalúa el comando de borrado, y SHALL NOT reconstruirse en el cliente: el estado de las sesiones de caja no está disponible en el listado y derivarlo ahí obligaría a traer las sesiones de todas las cajas para pintar una lista de compras.

#### Scenario: Compra con movimiento de caja posteado

- **WHEN** un usuario abre el diálogo de borrado de una compra que descontó de la caja
- **THEN** el diálogo enumera la reversión del movimiento de caja junto con las demás compensaciones antes de pedir confirmación

#### Scenario: Compra bloqueada por caja cerrada

- **GIVEN** una compra con movimiento de caja y sin sesión abierta en esa caja
- **WHEN** el usuario ve el listado de compras
- **THEN** el control de borrado aparece deshabilitado
- **AND** la razón visible indica que hay que abrir la caja para poder borrarla

#### Scenario: Presentación responsive y por tema

- **WHEN** el diálogo de borrado de una compra se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones

### Requirement: La anulación de un cobro o de un pago se incorpora al contrato transversal de compensación de libros

El contrato transversal de compensación SHALL alcanzar también a la anulación de un cobro de cuenta corriente y de un pago a proveedor, que SHALL seguir las mismas reglas que ya rigen para el borrado de una venta, de una compra y de un gasto:

1. **Atomicidad**: todas las compensaciones y el borrado del documento ocurren en una sola transacción, o ninguna ocurre.
2. **Orden**: primero se compensan los libros, después se borra el documento. Nunca al revés.
3. **Disparo por existencia**: cada pata se dispara si existe el movimiento correspondiente, evaluado con un predicado distinto de cero, y **nunca** por un signo esperado ni por una etiqueta declarada en el documento.
4. **Append-only**: ningún movimiento original se modifica ni se borra; la compensación se expresa siempre como un movimiento nuevo de tipo propio.
5. **Sesiones cerradas intocables**: el contra-movimiento de caja va a la sesión abierta actual de la misma caja, y su ausencia bloquea la operación entera con `P0426`.

La anulación de un pago SHALL ser el primer documento del sistema cuya compensación incluye el **libro diario** en el mismo cambio que la introduce, en lugar de diferirla: sus ramas contables ya existen y están vivas.

#### Scenario: Atomicidad de la anulación

- **WHEN** falla cualquier compensación durante la anulación de un cobro
- **THEN** ningún libro queda modificado y el documento del cobro sigue existiendo

#### Scenario: El documento se borra después de compensar

- **WHEN** se anula un cobro que movió cuenta corriente, caja y banco
- **THEN** los tres contra-movimientos existen y el documento del cobro ya no
- **AND** el orden es observable: ninguna compensación pudo fallar por ausencia del documento

#### Scenario: Los movimientos originales sobreviven a la anulación

- **WHEN** se anula un cobro
- **THEN** su movimiento de cuenta corriente, su movimiento de caja y su movimiento bancario originales siguen existiendo sin modificarse
- **AND** cada uno tiene su contra-movimiento propio junto a él

### Requirement: El diálogo de anulación enumera las compensaciones que aplican y respeta el sentido del movimiento

La interfaz SHALL enumerar, antes de confirmar una anulación, únicamente las compensaciones que ese pago va a producir, y SHALL NOT enumerar patas que no apliquen. La redacción del efecto sobre la caja SHALL respetar el sentido real del movimiento: anular un cobro **saca** dinero del cajón, anular un pago a proveedor lo **repone**.

Cuando la anulación está bloqueada, el control SHALL aparecer deshabilitado con el motivo visible, derivado del servidor.

#### Scenario: Anulación de un cobro bancario

- **WHEN** se pide anular un cobro por transferencia con asiento posteado
- **THEN** el diálogo enumera la reposición de la deuda del cliente, el movimiento bancario inverso y la reversión del asiento
- **AND** no menciona la caja

#### Scenario: Anulación de un cobro en efectivo

- **WHEN** se pide anular un cobro en efectivo
- **THEN** el diálogo dice que se registrará la **salida** correspondiente en la caja abierta actual
- **AND** no dice "ingreso", que sería mentir sobre el arqueo

#### Scenario: Anulación de un pago a proveedor en efectivo

- **WHEN** se pide anular un pago a proveedor en efectivo
- **THEN** el diálogo dice que se registrará el **ingreso** correspondiente en la caja abierta actual

#### Scenario: Anulación bloqueada por caja cerrada

- **GIVEN** un cobro con movimiento de caja y ninguna sesión abierta en esa caja
- **WHEN** se muestra su fila en el historial de cuenta corriente
- **THEN** el control de anulación aparece deshabilitado, con el motivo indicando que hay que abrir la caja
- **AND** el usuario no descubre el bloqueo recién al recibir el error del servidor

