# payment-reversal Specification

## Purpose
Anulación total de un cobro de cuenta corriente de cliente o de un pago a proveedor ya registrado, alcanzable desde `/clientes/[id]/cuenta` y `/proveedores/[id]/cuenta`. Expresa que el movimiento de dinero nunca ocurrió: repone la deuda de la parte al valor previo y compensa, en una sola transacción, todos los libros que el pago haya movido —cuenta corriente, caja y banco—, además de disparar la reversión del asiento contable vía el outbox; el documento del pago se borra al final, después de las cuatro compensaciones. Cada pata se dispara por la existencia del movimiento correspondiente, nunca por su signo ni por la forma de pago declarada, para no repetir el modo de falla silenciosa que motivó este diseño. Entregado en `cobranzas-reverso` (2026-09-02) para cerrar el hueco que `caja-compras-cobranzas` dejó documentado como OQ-4: hasta entonces un cobro o un pago mal cargado no se podía deshacer por ningún camino.
## Requirements
### Requirement: Un cobro y un pago de cuenta corriente se pueden anular desde la aplicación

El sistema SHALL proveer un camino de anulación para un cobro de cuenta corriente de cliente y para un pago a proveedor ya registrados, alcanzable desde la interfaz, sin intervención manual sobre la base de datos.

La anulación SHALL expresar que el movimiento de dinero **nunca ocurrió**: repone la deuda de la parte al valor que tenía antes del pago y deshace todo efecto que el pago haya producido sobre los libros de dinero y sobre el libro diario. No es un documento comercial nuevo ni el reconocimiento de un crédito: es la corrección de un registro equivocado.

La anulación SHALL ser **total**: un pago se anula entero. El sistema SHALL NOT ofrecer anular una parte del importe.

#### Scenario: Anular un cobro repone la deuda del cliente

- **GIVEN** un cliente con deuda 1000 sobre el que se registró un cobro de 400, quedando en 600
- **WHEN** se anula ese cobro
- **THEN** la deuda del cliente vuelve a 1000
- **AND** el ledger conserva el movimiento del cobro original y suma un movimiento de reversa por el importe opuesto
- **AND** ya no existe el documento del cobro

#### Scenario: Anular un pago a proveedor repone la deuda con el proveedor

- **GIVEN** una deuda de 1000 con un proveedor sobre la que se registró un pago de 400, quedando en 600
- **WHEN** se anula ese pago
- **THEN** la deuda con el proveedor vuelve a 1000, con el mismo tratamiento de ledger y de documento que el cobro

#### Scenario: No se ofrece anulación parcial

- **WHEN** un usuario intenta anular parte del importe de un cobro
- **THEN** el sistema no expone ningún camino para hacerlo: la anulación es del pago completo

### Requirement: La anulación compensa los cuatro libros o se rechaza entera

El sistema SHALL compensar, en una sola transacción de base de datos, todos los libros que el pago haya movido —cuenta corriente, caja y banco— y SHALL emitir el evento que produce la reversión del libro diario. Si cualquiera de las compensaciones falla, la anulación entera SHALL revertirse: no SHALL quedar un libro compensado y otro no.

El borrado del documento del pago SHALL ocurrir **después** de todas las compensaciones, dentro de la misma transacción.

#### Scenario: Anulación de un cobro que movió los cuatro libros

- **GIVEN** un cobro en efectivo con movimiento de cuenta corriente, movimiento de caja y asiento contable posteado
- **WHEN** se anula
- **THEN** existen el contra-movimiento de cuenta corriente y el contra-movimiento de caja, el documento del cobro ya no existe, y se emitió el evento de anulación, todo en un solo commit

#### Scenario: Una compensación fallida revierte la anulación entera

- **WHEN** una de las compensaciones falla durante la anulación
- **THEN** ningún libro queda modificado
- **AND** el documento del pago sigue existiendo
- **AND** no se emite ningún evento de anulación

### Requirement: Cada pata de compensación se dispara por la existencia del movimiento, nunca por su signo ni por la forma de pago declarada

El sistema SHALL decidir qué libro compensar consultando **si existe** el movimiento correspondiente al pago, y SHALL NOT condicionar la compensación a que ese movimiento tenga un signo determinado ni a la forma de pago registrada en el documento.

Condicionar al signo dejaría pasar sin compensar —y **sin levantar ningún error**— todo movimiento cuyo signo no fuera el esperado, que es precisamente el modo de falla silenciosa que el sistema ya sufrió. Condicionar a la forma de pago declarada no compensaría nada para los pagos registrados antes de que esa columna existiera, que son los únicos que hoy hay en el sistema, también sin error.

El predicado de existencia SHALL filtrar por el tipo de movimiento del **registro original** del pago, no por el de su reversa, de modo que una reversa no pueda auto-compensarse.

#### Scenario: Pago sin forma de pago registrada compensa igual

- **GIVEN** un pago anterior a la persistencia de la forma de pago, con movimiento bancario asociado
- **WHEN** se anula
- **THEN** el movimiento bancario se compensa igual, porque el disparo depende de la existencia del movimiento y no de la etiqueta del documento

#### Scenario: Un movimiento de caja con signo inesperado se compensa igual

- **GIVEN** un pago cuyo movimiento de caja quedó registrado con un signo distinto del esperado para su tipo
- **WHEN** se anula
- **THEN** la compensación de caja se ejecuta igual, con el importe exactamente opuesto al registrado
- **AND** la anulación no procede jamás dejando el movimiento sin compensar

#### Scenario: Un pago sin movimiento de caja no exige caja

- **GIVEN** un pago bancario, o un pago en efectivo registrado sin impacto en caja
- **WHEN** se anula
- **THEN** la pata de caja no se dispara y la anulación no exige ninguna sesión de caja

### Requirement: La compensación de caja va a la sesión abierta actual y exige que exista

El sistema SHALL registrar el contra-movimiento de caja contra la **sesión abierta actual de la misma caja** que recibió el movimiento original, y SHALL NOT modificar jamás la sesión original, esté abierta o cerrada: el ledger de caja es append-only por sesión y un arqueo cerrado es intocable.

Cuando el pago tiene movimiento de caja y **no** existe una sesión abierta en esa caja, el sistema SHALL rechazar la anulación entera con el código de error `P0426`, con un mensaje que indique que hay que abrir la caja.

El sistema SHALL NOT imponer ninguna otra restricción temporal a la anulación: un pago **sin** movimiento de caja SHALL ser anulable con cualquier antigüedad.

#### Scenario: Anulación con caja abierta

- **GIVEN** un cobro en efectivo registrado en una sesión ya cerrada, y una sesión abierta hoy en la misma caja
- **WHEN** se anula
- **THEN** el contra-movimiento se registra en la sesión abierta de hoy
- **AND** la sesión original no es modificada en absoluto

#### Scenario: Anulación sin caja abierta es rechazada

- **GIVEN** un cobro con movimiento de caja y ninguna sesión abierta en esa caja
- **WHEN** se intenta anular
- **THEN** la operación falla con `P0426`
- **AND** ningún libro es modificado y el documento del cobro sigue existiendo

#### Scenario: Un cobro antiguo sin caja se anula sin restricción de fecha

- **GIVEN** un cobro bancario registrado hace meses
- **WHEN** se anula
- **THEN** la anulación procede normalmente, sin ninguna verificación de antigüedad

### Requirement: La anulación exige que el pago pertenezca al tenant

El sistema SHALL resolver el pago a anular filtrando explícitamente por la cuenta del solicitante, **antes** de tocar cualquier libro, y SHALL rechazar con el código de error `P0404` cuando el pago no exista o pertenezca a otra cuenta. El mensaje SHALL NOT revelar si el identificador existe en otro tenant.

El filtro SHALL ser explícito en la consulta y SHALL NOT delegarse únicamente en la seguridad a nivel de fila, que es una red y no el guard único.

#### Scenario: Anular un pago de otro tenant

- **GIVEN** un usuario con permiso de escritura en una cuenta y un pago que pertenece a otra
- **WHEN** intenta anularlo
- **THEN** la operación falla con `P0404`
- **AND** ningún libro de ninguna de las dos cuentas es modificado

#### Scenario: Un identificador inexistente se rechaza igual que uno ajeno

- **WHEN** se intenta anular un identificador de pago que no existe en ninguna cuenta
- **THEN** la operación falla con `P0404` y el mensaje no distingue ambos casos

#### Scenario: El rechazo llega al usuario como "no encontrado"

- **WHEN** el guard rechaza la anulación
- **THEN** la API responde `404` con el cuerpo de error estándar de la plataforma

### Requirement: La anulación es idempotente por ausencia del documento

El sistema SHALL tratar el segundo intento de anular el mismo pago como un pago inexistente, rechazándolo con `P0404`, porque su documento ya fue borrado. La anulación SHALL NOT requerir una clave de idempotencia propia.

#### Scenario: Anular dos veces el mismo cobro

- **WHEN** se anula un cobro y luego se intenta anularlo de nuevo
- **THEN** el segundo intento falla con `P0404`
- **AND** no se registra un segundo contra-movimiento en ningún libro

### Requirement: La anulación admite un motivo y lo hace viajar

El sistema SHALL aceptar un motivo textual opcional para la anulación y SHALL hacerlo llegar al `description` del contra-movimiento de caja, cuando esa pata se dispara, y al payload del evento de anulación en todos los casos.

El motivo SHALL ser opcional: exigirlo más adelante es aditivo, mientras que relajarlo después de haberlo exigido rompería a los llamadores.

#### Scenario: Motivo informado llega al historial de caja

- **WHEN** se anula un cobro en efectivo indicando un motivo
- **THEN** el contra-movimiento de caja lleva ese motivo como descripción, visible en el historial de la caja

#### Scenario: Anulación sin motivo

- **WHEN** se anula un cobro sin indicar motivo
- **THEN** la anulación procede normalmente

### Requirement: La superficie de cuenta corriente ofrece la anulación en la fila del pago, con lo que va a pasar enumerado antes de confirmar

La interfaz de cuenta corriente de cliente y de proveedor SHALL ofrecer la acción de anular **en la fila del movimiento del pago**, y SHALL ofrecerla únicamente cuando el movimiento corresponde a un pago cuyo documento sigue vivo. Un movimiento de cargo, de nota de crédito, de ajuste o de reversa SHALL NOT ofrecer la acción.

Antes de ejecutarla, la interfaz SHALL mostrar una confirmación que **enumere los libros que se van a compensar**, incluyendo únicamente las patas que apliquen a ese pago, y que nombre el efecto sobre la deuda de la parte. La redacción del efecto sobre la caja SHALL respetar el sentido real del movimiento: anular un cobro **saca** dinero del cajón y anular un pago lo **repone**.

Cuando la anulación está bloqueada por falta de sesión de caja abierta, la acción SHALL aparecer deshabilitada con el motivo visible **antes** de intentarla, derivado del mismo predicado que evalúa el servidor y no de una regla reimplementada en el cliente.

La superficie SHALL usar los tokens semánticos del design system y SHALL ser legible y operable en escritorio y en móvil, en tema claro y en tema oscuro.

#### Scenario: La acción aparece sólo en las filas de pago

- **WHEN** se muestra el historial de una cuenta corriente con un cargo, un cobro y una reversa de cobro
- **THEN** sólo la fila del cobro ofrece la acción de anular

#### Scenario: La confirmación enumera las compensaciones

- **WHEN** el usuario pide anular un cobro en efectivo con asiento contable posteado
- **THEN** la confirmación enumera la reposición de la deuda del cliente, la salida de la caja abierta y la reversión del asiento contable
- **AND** no enumera el movimiento bancario, que ese cobro no tuvo

#### Scenario: La acción bloqueada muestra el motivo sin intentar

- **GIVEN** un cobro con movimiento de caja y ninguna sesión abierta en esa caja
- **WHEN** se muestra su fila en el historial
- **THEN** la acción de anular aparece deshabilitada, con el motivo indicando que hay que abrir la caja

#### Scenario: El error del servidor llega legible

- **WHEN** la anulación falla con `P0426`, `P0404` o `P0451`
- **THEN** el usuario ve un mensaje en lenguaje natural que explica qué pasó y qué hacer, no un código crudo

#### Scenario: Presentación responsive y por tema

- **WHEN** el historial de cuenta corriente y el diálogo de anulación se muestran en escritorio o en móvil, en tema claro u oscuro
- **THEN** usan los tokens semánticos del design system y son legibles y operables en las cuatro combinaciones

### Requirement: Las funciones de anulación no son alcanzables desde el rol de aplicación

Las funciones de anulación SHALL ser `SECURITY DEFINER`, SHALL tener `search_path` fijado, y sus permisos de ejecución SHALL revocarse explícitamente de `PUBLIC`, de `anon` y de `authenticated` en la misma migración que las crea, otorgándose después sólo a quien las necesite. Una función que mueve dinero en cuatro libros SHALL NOT quedar invocable directamente desde el cliente.

#### Scenario: El rol anónimo no puede invocarlas

- **WHEN** se inspeccionan los permisos de ejecución de las funciones de anulación tras la migración
- **THEN** ni `anon` ni `PUBLIC` tienen `EXECUTE`

#### Scenario: El barrido de permisos las incluye

- **WHEN** corre el gate de permisos de funciones del proyecto
- **THEN** las dos funciones de anulación están dentro de su alcance y lo pasan

