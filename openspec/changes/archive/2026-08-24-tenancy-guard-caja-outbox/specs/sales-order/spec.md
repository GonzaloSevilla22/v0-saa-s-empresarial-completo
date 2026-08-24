## ADDED Requirements

### Requirement: La confirmación de una orden sólo puede imputar caja a la sesión de su propia sucursal

El sistema SHALL rechazar la confirmación de una orden de venta que informe una sesión de caja que no esté abierta o que no pertenezca a la sucursal efectiva de esa venta, sin dejar ningún efecto parcial.

El invariante ya rige en el camino del formulario de venta y SHALL regir de forma idéntica en el camino del mostrador, con el mismo código de error y el mismo mensaje, de modo que las dos superficies produzcan un resultado indistinguible ante el mismo input inválido. Hasta ahora el camino del mostrador sólo verificaba que la sesión **estuviera informada**, no de quién era: una orden podía imputar su ingreso de efectivo al arqueo de una caja de otra sucursal — incluso de otra cuenta — dejando el ingreso registrado en los libros de un tercero y ausente en los propios.

La verificación SHALL ocurrir junto al resto de las validaciones de datos de entrada, **antes** de la primera escritura de la confirmación, y SHALL ceder ante las validaciones de datos de entrada que ya existen: un pedido que es inválido por dos motivos a la vez SHALL reportar el motivo que se evalúa primero, para que el orden de las comprobaciones quede congelado y sea verificable.

La verificación SHALL ser autosuficiente: SHALL comprobar por sí misma tanto que la sesión corresponda a la sucursal efectiva de la venta como que esa sucursal pertenezca a la cuenta que confirma, sin delegar ninguna de las dos mitades en comprobaciones posteriores. La sucursal efectiva de una venta del mostrador la determina el pedido, así que una verificación que sólo comparase la caja contra la sucursal declarada quedaría satisfecha cuando el pedido declara la sucursal ajena junto con la caja ajena.

Los comandos públicos que envuelven la confirmación —la confirmación de una orden existente y la venta rápida del mostrador— SHALL heredar la verificación sin modificarse, porque delegan en el mismo núcleo, y SHALL no repetirla en su propio cuerpo: una segunda redacción del mismo invariante es la forma en que los dos caminos divergen.

#### Scenario: Confirmar contra la caja de otra cuenta es rechazado

- **GIVEN** dos cuentas A y B, cada una con su sucursal y su caja, y una sesión de caja abierta en la cuenta B
- **WHEN** un usuario de la cuenta A confirma una venta en efectivo informando la sesión de caja de B
- **THEN** la confirmación es rechazada, no se registra ningún movimiento en la caja de B, y la orden de A queda sin confirmar

#### Scenario: Confirmar contra la caja de otra sucursal de la misma cuenta es rechazado

- **GIVEN** una cuenta con dos sucursales operativas, cada una con su caja y una sesión abierta
- **WHEN** se confirma una venta cuya sucursal efectiva es la primera informando la sesión de caja de la segunda
- **THEN** la confirmación es rechazada con el mismo error que produce el camino del formulario ante el mismo input

#### Scenario: Declarar también la sucursal ajena no evade la verificación

- **GIVEN** dos cuentas A y B, y una sesión de caja abierta en la sucursal de la cuenta B
- **WHEN** un usuario de la cuenta A confirma una venta en efectivo declarando **a la vez** la sucursal de B y la sesión de caja de B
- **THEN** la confirmación es rechazada por la verificación de la caja —no por una comprobación posterior— y no se registra ningún movimiento en la caja de B
- **AND** el resultado es el mismo cuando la sucursal ajena ya venía guardada en la orden y no viaja en el pedido

#### Scenario: Confirmar contra una sesión cerrada de la propia sucursal es rechazado

- **GIVEN** una venta en efectivo cuya sucursal efectiva tiene su sesión de caja cerrada
- **WHEN** se intenta confirmar informando esa sesión
- **THEN** la confirmación es rechazada y no se registra ningún movimiento de caja

#### Scenario: La venta en efectivo con la caja correcta sigue funcionando

- **GIVEN** una venta en efectivo cuya sucursal efectiva tiene una sesión de caja abierta
- **WHEN** se confirma informando esa sesión
- **THEN** la confirmación tiene éxito y se registra exactamente un movimiento de caja de tipo venta, por el total de la orden, referenciando la orden confirmada

#### Scenario: La venta rápida hereda la verificación sin cambios propios

- **WHEN** la venta rápida del mostrador informa una sesión de caja ajena a la sucursal efectiva
- **THEN** es rechazada igual que la confirmación de una orden existente, porque ambas delegan en el mismo núcleo

#### Scenario: Las validaciones de datos de entrada preceden a la verificación de la caja

- **GIVEN** una confirmación con una sesión de caja ajena **y** una forma de pago en efectivo sin sesión informada
- **WHEN** se intenta confirmar
- **THEN** el error reportado es el de la validación de datos de entrada que ya existía, no el de la verificación nueva
