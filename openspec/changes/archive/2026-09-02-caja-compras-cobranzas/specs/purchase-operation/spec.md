## ADDED Requirements

### Requirement: La compra persiste su sucursal

El sistema SHALL persistir en la operación de compra la sucursal informada por el usuario, propagándola a todas las filas de la operación, y SHALL rechazar una sucursal inexistente, inactiva o de otra cuenta.

La sucursal es obligatoria en los documentos operativos (RN-93) y es además el **ancla de la verificación de sucursal del descuento de caja**: sin ella, la compra y el cajón que recibió el efectivo pueden quedar atribuidos a lugares distintos sin que nada lo advierta. El comando de alta ya recibe y valida el parámetro de sucursal; lo que falta es que la cadena que va de la interfaz al comando deje de descartarlo.

Las compras registradas antes de este cambio SHALL conservar su sucursal nula, sin relleno retroactivo: la sucursal correcta de una compra histórica no es derivable de ningún dato guardado, y una atribución inventada sería peor que la ausencia.

#### Scenario: La sucursal elegida llega a la compra

- **GIVEN** una cuenta con dos sucursales activas
- **WHEN** el usuario registra una compra eligiendo la segunda sucursal
- **THEN** todas las filas de esa operación quedan con esa sucursal

#### Scenario: La compra sin sucursal elegida se registra igual

- **WHEN** el usuario registra una compra sin elegir sucursal
- **THEN** la compra se registra con sucursal nula y sin error

#### Scenario: Una sucursal ajena o inactiva es rechazada

- **WHEN** se registra una compra informando una sucursal de otra cuenta, inexistente o inactiva
- **THEN** la operación es rechazada y no se crea ninguna fila de compra

#### Scenario: Las compras históricas no se rellenan

- **WHEN** se recorren las compras registradas antes de este cambio
- **THEN** su sucursal sigue siendo nula
- **AND** ninguna fila histórica fue reescrita

#### Scenario: El reporte por sucursal empieza a ver las compras

- **GIVEN** una compra registrada con sucursal después de este cambio
- **WHEN** se consulta el reporte por sucursal
- **THEN** la compra aparece atribuida a su sucursal

### Requirement: La compra en efectivo descuenta de la caja mediante opt-in con tres condiciones verificadas en el servidor

El sistema SHALL registrar un movimiento de egreso de caja por el total de una compra imputada a una forma de pago de `kind = 'cash'` **únicamente** cuando el usuario lo afirme explícitamente y se cumplan **simultáneamente** las tres condiciones siguientes, todas verificadas en el servidor: la forma de pago imputada tiene `kind = 'cash'`, existe una sesión de caja abierta cuya caja pertenece a la sucursal efectiva de la compra, y la fecha de la compra es el día de hoy en `America/Argentina/Mendoza`.

Las tres condiciones SHALL ser **las mismas** que ya rigen para la venta desde el formulario y para el gasto, con los mismos códigos y los mismos tokens de error, y SHALL NOT delegarse en la interfaz: una solicitud que informe una sesión de caja sin cumplirlas SHALL fallar entera —sin compra, sin stock movido y sin movimiento de caja— en vez de registrar el movimiento o de ignorarlo en silencio.

La ausencia del dato de sesión SHALL ser un **no-op**: la compra se registra normalmente sin tocar la caja. La falta de una caja abierta NO SHALL impedir registrar una compra.

La verificación de la fecha SHALL comparar la **fecha** de la compra contra el día local argentino, y SHALL NOT derivarla de un instante con zona horaria: la conversión implícita usaría la zona del servidor y rechazaría por "no es hoy" una compra cargada al final de la tarde argentina.

El efecto SHALL producirse delegando en el helper intra-transaccional de caja que ya existe, sin abrir una segunda puerta de escritura, de modo que la compra herede sus invariantes: sesión abierta, pertenencia de la sesión a la cuenta, sucursal operativa, saldo posterior calculado bajo lock y autoría.

#### Scenario: Compra en efectivo con las tres condiciones cumplidas

- **GIVEN** una sesión de caja abierta en la sucursal de la compra, con saldo de apertura conocido
- **WHEN** se registra hoy una compra de 8000 imputada a una forma de pago de `kind = 'cash'` afirmando el descuento de caja
- **THEN** se registra un movimiento de caja de egreso por 8000 referenciando la operación de compra, en el mismo commit que el ingreso de stock
- **AND** el saldo esperado de la sesión baja en 8000

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

### Requirement: La superficie de compra ofrece el descuento de caja pre-marcado y explica cuándo no aplica

La interfaz de alta de compra SHALL ofrecer la afirmación del descuento de caja **pre-marcada** cuando las tres condiciones se cumplen, y SHALL mostrar el motivo concreto cuando no se cumplen, sin ocultar el bloque en silencio.

El valor inicial marcado es deliberado y SHALL alinearse con el del gasto y no con el de la venta: la venta arranca sin marcar porque su formulario se usa masivamente para carga retroactiva de administración, mientras que una compra imputada a efectivo y fechada hoy describe casi siempre plata que salió del cajón. Con la verificación de fecha ya filtrando lo retroactivo, un valor inicial sin marcar reproduciría el estado previo al cambio —la caja sigue sin ver la plata salvo que alguien se acuerde de marcarlo.

La afirmación SHALL ofrecerse **sólo en el alta**: la compra con movimiento de caja posteado es inmutable, de modo que no existe un camino de edición en el que la afirmación tenga sentido.

La interfaz SHALL reutilizar la resolución de condiciones compartida que ya emplean el formulario de venta y el de gasto, en vez de reimplementarla; la autoridad sobre la decisión SHALL seguir siendo el servidor.

#### Scenario: Condiciones cumplidas

- **GIVEN** una compra en efectivo fechada hoy con una sesión de caja abierta en su sucursal
- **WHEN** el usuario ve el formulario de compra
- **THEN** la afirmación de descuento de caja aparece marcada, nombrando la sesión

#### Scenario: Condiciones no cumplidas

- **GIVEN** una compra en efectivo fechada hoy sin sesión de caja abierta en su sucursal
- **WHEN** el usuario ve el formulario de compra
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** una compra en efectivo con las tres condiciones cumplidas
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** la compra se registra sin movimiento de caja

#### Scenario: La edición no ofrece la afirmación

- **WHEN** el usuario edita una compra existente
- **THEN** el formulario no ofrece la afirmación de descuento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el bloque de descuento de caja se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
