## MODIFIED Requirements

### Requirement: El borrado de una compra compensa cuatro libros, no tres

El sistema SHALL incorporar la caja al contrato transversal de compensación del borrado de una compra, de modo que los libros compensables de esa operación pasen a ser **cuatro** —cuenta corriente del proveedor, caja, banco y stock— y todos se evalúen y compensen en la misma transacción que la eliminación.

**Excepción — compra nacida de un remito de compra**: cuando las filas de la compra tienen origen en un remito de compra (`purchases.source_delivery_note_id`), el stock de esa mercadería pertenece al remito: el libro de stock SHALL NOT compensarse (la reversa se saltea de forma explícita) y los libros compensables son tres —cuenta corriente del proveedor, caja y banco—, con las mismas reglas de orden y de todo o nada. El remito vuelve a pendiente (ver "Borrar una compra nacida de un remito compensa el dinero, no toca el stock y devuelve el remito a pendiente").

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

#### Scenario: Compra nacida de un remito con impacto en caja

- **GIVEN** una compra en efectivo nacida de un remito de compra, que descontó de la caja
- **WHEN** se borra con la caja abierta
- **THEN** la caja recibe su compensación en la misma transacción
- **AND** el stock no cambia y no se registra ningún contramovimiento de stock

### Requirement: El diálogo de borrado de una compra enumera las cuatro compensaciones

La interfaz SHALL enumerar, antes de confirmar el borrado de una compra, cada uno de los libros que la operación va a compensar —cargo en la cuenta corriente del proveedor, movimiento de caja, movimiento bancario y reposición de stock— y SHALL deshabilitar el control de borrado indicando la razón cuando la compra no sea borrable porque falta una sesión de caja abierta.

Para una compra nacida de un remito de compra, el diálogo SHALL NOT enumerar la reposición de stock y SHALL decir en su lugar que el stock no vuelve, que el remito vuelve a quedar pendiente y que, para sacar la mercadería del stock, hay que anular el remito.

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

#### Scenario: Compra nacida de un remito en el diálogo

- **WHEN** un usuario abre el diálogo de borrado de una compra nacida del remito `RC-00000012`
- **THEN** el diálogo no menciona la reversión del ingreso de stock
- **AND** dice que el stock no vuelve y que el remito `RC-00000012` vuelve a quedar pendiente

## ADDED Requirements

### Requirement: Borrar una compra nacida de un remito compensa el dinero, no toca el stock y devuelve el remito a pendiente
El sistema SHALL borrar una compra nacida de un remito de compra compensando cuenta corriente del proveedor, caja y banco igual que cualquier compra, SHALL NOT revertir stock (la reversa se saltea de forma explícita, no por ausencia de movimientos) y SHALL devolver el remito a `issued` con la transición `converted → issued`, el usuario que borró y el motivo, en la misma transacción.

Antes de cualquier compensación, el borrado SHALL bloquear el remito de origen (leído con la cuenta del usuario y el sentido compra) y revalidar bajo ese bloqueo que las filas de la compra siguen existiendo y que el remito sigue `converted`; SHALL exigir el rol de anular remitos de compra (administrador o dueño, `P0403 delivery_note_purchase_delete_forbidden`) y que la sucursal del remito esté activa y no cerrada (`P0422 delivery_note_branch_inactive`). El diálogo de borrado SHALL explicar que el stock no vuelve y que, para sacar la mercadería del stock, hay que anular el remito.

#### Scenario: Borrado de una compra en efectivo nacida de un remito
- **GIVEN** una compra en efectivo nacida de un remito de compra, con la caja abierta
- **WHEN** un administrador la borra
- **THEN** la caja registra el contra-movimiento, el stock no cambia, la compra deja de existir y el remito vuelve a `issued`

#### Scenario: Sucursal del remito desactivada
- **GIVEN** una compra nacida de un remito cuya sucursal se desactivó después de convertir
- **WHEN** se intenta borrar la compra
- **THEN** la operación falla con `P0422 delivery_note_branch_inactive`, sin compensar dinero, y el remito sigue `converted`

#### Scenario: El diálogo explica el stock
- **WHEN** el usuario abre el diálogo de borrado de una compra nacida del remito `RC-00000012`
- **THEN** el diálogo dice que el stock no vuelve, que el remito `RC-00000012` vuelve a quedar pendiente y que para sacar la mercadería del stock hay que anularlo
