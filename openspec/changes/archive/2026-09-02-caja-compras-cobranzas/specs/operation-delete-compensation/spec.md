## ADDED Requirements

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
