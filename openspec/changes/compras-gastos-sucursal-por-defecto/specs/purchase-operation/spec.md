## MODIFIED Requirements

### Requirement: La compra persiste su sucursal

El sistema SHALL registrar en una sucursal toda compra que se cree o se edite por el formulario, la API o sus funciones de base: la que el usuario eligió o, si no eligió ninguna, la sucursal principal de la cuenta (`c26_default_branch`), propagándola a todas las filas de la operación. Esa sucursal SHALL ser **la misma** en la que entra el stock, la que se escribe en el movimiento de stock y en el movimiento bancario, y la que se compara con la caja del opt-in de efectivo.

La sucursal es obligatoria en los documentos operativos (RN-93) y es además el **ancla de la verificación de sucursal del descuento de caja**: sin ella, la compra y el cajón que recibió el efectivo pueden quedar atribuidos a lugares distintos sin que nada lo advierta.

Una sucursal elegida SHALL rechazarse si es inexistente, inactiva o de otra cuenta (`P0404`) o si está cerrada (`P0422 branch_closed`), igual que en la venta y el gasto.

Si no se eligió sucursal y la cuenta no tiene ninguna sucursal **operativa** a la cual resolver (no tiene sucursales, o todas están inactivas o cerradas), el alta SHALL rechazarse con `P0422 no_branch_found` sin persistir nada: sin compra, sin stock, sin movimientos. El sistema NO SHALL registrar una compra, ni ingresar su stock, en una sucursal inactiva o cerrada por resolución implícita, ni crear una sucursal como efecto lateral de una compra.

Las compras registradas sin sucursal antes de este cambio SHALL conservar su sucursal nula, sin relleno retroactivo en masa. Una compra histórica toma sucursal sólo cuando un usuario la edita, por la regla de la edición (capability `operation-edit-context`).

Este requirement cumple RN-93 y DEC-19 para la compra.

#### Scenario: La sucursal elegida llega a la compra

- **GIVEN** una cuenta con dos sucursales activas
- **WHEN** el usuario registra una compra eligiendo la segunda sucursal
- **THEN** todas las filas de esa operación quedan con esa sucursal

#### Scenario: La compra sin sucursal elegida queda en la principal

- **GIVEN** una cuenta con la sucursal principal A y otra sucursal B, y una compra de dos líneas (una con producto y una sin producto)
- **WHEN** se registra la compra sin elegir sucursal
- **THEN** las dos filas de `purchases` quedan con `branch_id = A`, el stock del producto entra en A y no en B, y su movimiento de stock queda con `branch_id = A`

#### Scenario: La compra bancaria sin sucursal elegida deja su movimiento bancario en la principal

- **GIVEN** una forma de pago bancaria con cuenta destino resuelta
- **WHEN** se registra una compra sin elegir sucursal imputada a esa forma de pago
- **THEN** el movimiento bancario de egreso queda con la misma sucursal que la compra, la principal

#### Scenario: La principal cerrada no recibe compras sin sucursal elegida

- **GIVEN** una cuenta cuya sucursal más antigua está cerrada y una segunda sucursal operativa
- **WHEN** se registra una compra sin elegir sucursal
- **THEN** la compra, su stock y su movimiento de stock quedan en la segunda sucursal

#### Scenario: Cuenta sin sucursal operativa

- **GIVEN** una cuenta cuyas sucursales están todas inactivas o cerradas, o que no tiene ninguna sucursal
- **WHEN** se registra una compra sin elegir sucursal, con producto o sin producto
- **THEN** la operación falla con `P0422 no_branch_found` y no se crean filas de compra, de idempotencia ni de movimientos, `branch_stock` queda sin cambios y no se crea ninguna sucursal

#### Scenario: Una sucursal ajena o inactiva es rechazada

- **WHEN** se registra una compra informando una sucursal de otra cuenta, inexistente o inactiva
- **THEN** la operación es rechazada con `P0404` y no se crea ninguna fila de compra

#### Scenario: Una sucursal elegida cerrada es rechazada

- **GIVEN** una sucursal activa con `status = 'closed'`
- **WHEN** se registra una compra eligiendo esa sucursal
- **THEN** la operación falla con `P0422 branch_closed`, no se crea ninguna fila de compra y el stock de esa sucursal no cambia

#### Scenario: Las compras históricas no se rellenan

- **WHEN** se aplica este cambio y se recorren las compras registradas antes, sin sucursal
- **THEN** su sucursal sigue siendo nula
- **AND** ninguna fila histórica fue reescrita por el sistema

#### Scenario: El reporte por sucursal ve las compras nuevas

- **GIVEN** una compra registrada después de este cambio, con o sin sucursal elegida
- **WHEN** se consulta el Tablero filtrado por la sucursal en la que quedó
- **THEN** la compra aparece atribuida a esa sucursal

### Requirement: La compra en efectivo descuenta de la caja mediante opt-in con tres condiciones verificadas en el servidor

El sistema SHALL registrar un movimiento de egreso de caja por el total de una compra imputada a una forma de pago de `kind = 'cash'` **únicamente** cuando el usuario lo afirme explícitamente y se cumplan **simultáneamente** las tres condiciones siguientes, todas verificadas en el servidor: la forma de pago imputada tiene `kind = 'cash'`, existe una sesión de caja abierta cuya caja pertenece a la sucursal efectiva de la compra, y la fecha de la compra es el día de hoy en `America/Argentina/Mendoza`.

La **sucursal efectiva** de la compra SHALL ser la misma que se persiste en la operación (requirement «La compra persiste su sucursal»): la elegida o, si no se eligió ninguna, la sucursal principal de la cuenta. NO SHALL compararse la sesión contra la sucursal **recibida** sin resolver: una compra sin sucursal elegida se registra en la principal, y su opt-in SHALL aceptar la sesión abierta de la caja de la principal.

Las tres condiciones SHALL ser **las mismas** que ya rigen para la venta desde el formulario y para el gasto, con los mismos códigos y los mismos tokens de error, y SHALL NOT delegarse en la interfaz: una solicitud que informe una sesión de caja sin cumplirlas SHALL fallar entera —sin compra, sin stock movido y sin movimiento de caja— en vez de registrar el movimiento o de ignorarlo en silencio.

La ausencia del dato de sesión SHALL ser un **no-op**: la compra se registra normalmente sin tocar la caja. La falta de una caja abierta NO SHALL impedir registrar una compra.

La verificación de la fecha SHALL comparar la **fecha** de la compra contra el día local argentino, y SHALL NOT derivarla de un instante con zona horaria: la conversión implícita usaría la zona del servidor y rechazaría por "no es hoy" una compra cargada al final de la tarde argentina.

El efecto SHALL producirse delegando en el helper intra-transaccional de caja que ya existe, sin abrir una segunda puerta de escritura, de modo que la compra herede sus invariantes: sesión abierta, pertenencia de la sesión a la cuenta, sucursal operativa, saldo posterior calculado bajo lock y autoría.

#### Scenario: Compra en efectivo con las tres condiciones cumplidas

- **GIVEN** una sesión de caja abierta en la sucursal de la compra, con saldo de apertura conocido
- **WHEN** se registra hoy una compra de 8000 imputada a una forma de pago de `kind = 'cash'` afirmando el descuento de caja
- **THEN** se registra un movimiento de caja de egreso por 8000 referenciando la operación de compra, en el mismo commit que el ingreso de stock
- **AND** el saldo esperado de la sesión baja en 8000

#### Scenario: Compra en efectivo sin sucursal elegida descuenta de la caja de la principal

- **GIVEN** una cuenta cuya sucursal principal A tiene una sesión de caja abierta
- **WHEN** se registra hoy, sin elegir sucursal, una compra imputada a `kind = 'cash'` informando la sesión de A
- **THEN** la compra se registra en A con su movimiento de caja de egreso en la sesión de A, sin error

#### Scenario: Compra en efectivo sin afirmación no toca la caja

- **GIVEN** una sesión de caja abierta en la sucursal de la compra
- **WHEN** se registra una compra imputada a `kind = 'cash'` sin afirmar el descuento de caja
- **THEN** la compra se registra normalmente y no se crea ningún movimiento de caja
- **AND** el arqueo de la sesión no se ve afectado

#### Scenario: La afirmación con una forma de pago que no es efectivo es rechazada

- **WHEN** se registra una compra imputada a una forma de pago bancaria o de cuenta corriente informando una sesión de caja
- **THEN** la operación falla con el token de "el descuento de caja exige efectivo" y no se crea ni la compra ni el movimiento

#### Scenario: La afirmación sin sesión abierta en la sucursal es rechazada

- **GIVEN** dos sucursales, cada una con su caja, y una sesión abierta sólo en la segunda
- **WHEN** se registra hoy una compra en la primera sucursal imputada a `kind = 'cash'` informando la sesión de la segunda
- **THEN** la operación falla con el token de "el descuento de caja exige una sesión abierta" y el arqueo de la segunda sucursal no se altera

#### Scenario: Sin sucursal elegida, la sesión de otra sucursal que no es la principal es rechazada

- **GIVEN** la sucursal principal A y otra sucursal B con una sesión de caja abierta
- **WHEN** se registra hoy, sin elegir sucursal, una compra imputada a `kind = 'cash'` informando la sesión de B
- **THEN** la operación falla con el token de "el descuento de caja exige una sesión abierta" y no se crea ni la compra ni el movimiento

#### Scenario: La afirmación con fecha anterior a hoy es rechazada

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se registra una compra fechada ayer, imputada a `kind = 'cash'`, informando la sesión de caja
- **THEN** la operación falla con el token de "sólo se puede registrar en caja una compra fechada hoy" y no se crea ni la compra ni el movimiento

#### Scenario: Una compra cargada al final de la tarde argentina no se rechaza por fecha

- **GIVEN** una sesión de caja abierta y el instante actual dentro del último tramo del día local argentino que ya cayó en el día siguiente en tiempo universal
- **WHEN** se registra una compra fechada hoy en día local argentino, imputada a `kind = 'cash'`, afirmando el descuento de caja
- **THEN** la compra se registra con su movimiento de caja

#### Scenario: Sin caja abierta la compra se registra igual

- **GIVEN** una cuenta sin ninguna sesión de caja abierta
- **WHEN** se registra una compra imputada a `kind = 'cash'` sin informar sesión
- **THEN** la compra se registra normalmente, sin movimiento de caja y sin error

#### Scenario: La sesión de otra cuenta es rechazada

- **GIVEN** una sesión de caja abierta perteneciente a otra cuenta
- **WHEN** se registra una compra informando esa sesión
- **THEN** la operación es rechazada y la cantidad de movimientos de la sesión ajena queda sin cambios
