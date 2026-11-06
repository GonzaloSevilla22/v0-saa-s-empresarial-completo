# account-invitation-flow Specification

## Purpose

Define la invitación a una cuenta de punta a punta: el email que se encola en la misma transacción que crea o renueva la invitación (destinatario y token tomados de la fila registrada), la pantalla pública de aceptación ligada a la identidad invitada y sin datos del negocio para quien no corresponde, la aceptación que crea la membresía y deja el negocio como cuenta activa del invitado, la gestión de pendientes (listar, reenviar con enlace nuevo, revocar) y los topes contra el abuso del envío. Introducido por `multiusuario-operativo` (2026-10-17); el cupo de usuarios por plan vive en la capability `multi-tenant`.
## Requirements
### Requirement: La invitación se envía por email al invitado
El sistema SHALL enviar un email al invitado cada vez que un dueño o administrador crea o reenvía una invitación, y SHALL encolarlo en la misma transacción que crea o renueva la invitación.

El destinatario SHALL tomarse de la invitación registrada y el token del enlace SHALL generarlo la base en ese mismo envío, NOT un dato provisto por quien invita. El email SHALL nombrar al negocio y a quien invita, los roles con que se incorporará y la fecha de vencimiento, y SHALL llevar un enlace a la pantalla de aceptación.

La creación, el reenvío, la revocación y el listado de invitaciones SHALL exponerse a través del backend propio, que SHALL traducir los errores del dominio a respuestas con su código HTTP correspondiente.

#### Scenario: Invitar encola el email al invitado
- **GIVEN** un dueño de una cuenta con cupo de usuarios disponible
- **WHEN** invita a una persona por su email con el rol de vendedor
- **THEN** queda registrada una invitación pendiente y se encola un email dirigido al email invitado, con el enlace de aceptación

#### Scenario: Un miembro sin autoridad no puede invitar ni reenviar
- **GIVEN** un miembro de la cuenta con rol de vendedor
- **WHEN** intenta invitar o reenviar una invitación
- **THEN** la operación se rechaza y no se encola ningún email

### Requirement: La pantalla de aceptación está ligada a la identidad invitada
El sistema SHALL ofrecer una pantalla pública de aceptación, a la que se llega por el enlace del email, que NOT SHALL enviar la dirección de la página a terceros como referencia ni SHALL ser indexable.

La pantalla SHALL enviar el token al backend en el cuerpo de la solicitud de vista previa y de aceptación, y el backend NOT SHALL recibirlo en la ruta ni en los parámetros de su dirección. El enlace de la pantalla SHALL poder abrirse desde cualquier dispositivo mientras la invitación esté vigente.

- **Visitante sin sesión**: la pantalla SHALL mostrar un mensaje genérico, sin el nombre del negocio ni el de quien invita, con accesos para ingresar o crear una cuenta que, al completarse, SHALL devolverlo a la misma invitación.
- **Usuario autenticado cuyo email coincide con el invitado**: la pantalla SHALL mostrar el negocio, quien invita, los roles y el vencimiento, y SHALL ofrecer aceptar.
- **Usuario autenticado cuyo email no coincide, o invitación vencida, revocada o ya utilizada**: la pantalla SHALL mostrar un único mensaje, indistinguible entre esos casos, con la opción de cerrar sesión e ingresar con otro email.

#### Scenario: Un visitante sin sesión no ve datos del negocio
- **WHEN** alguien sin sesión abre el enlace de una invitación vigente
- **THEN** ve un mensaje genérico con accesos para ingresar o registrarse, sin el nombre del negocio ni el de quien invita

#### Scenario: Registrarse desde la invitación vuelve a la invitación
- **GIVEN** un visitante sin cuenta que abrió el enlace de una invitación
- **WHEN** crea su cuenta con el email invitado y completa el acceso
- **THEN** vuelve a la pantalla de esa invitación con la vista previa y la opción de aceptar

#### Scenario: La identidad correcta ve la vista previa
- **GIVEN** una invitación vigente dirigida a un email
- **WHEN** el usuario autenticado con ese email abre el enlace
- **THEN** ve el nombre del negocio, quién lo invita, los roles y el vencimiento, y puede aceptar

#### Scenario: Otra identidad no distingue nada
- **GIVEN** una invitación vigente dirigida a un email
- **WHEN** un usuario autenticado con otro email abre el enlace
- **THEN** ve el mismo mensaje que vería con un enlace vencido o inexistente

#### Scenario: El token no viaja en la ruta de la API
- **WHEN** la pantalla pide la vista previa o acepta una invitación
- **THEN** la solicitud al backend lleva el token en su cuerpo, y ni la ruta ni los parámetros de la solicitud lo contienen

#### Scenario: Un token malformado responde igual que uno vencido
- **WHEN** el backend recibe una vista previa o una aceptación con un token sin forma de token
- **THEN** responde con el mismo código y el mismo mensaje que ante un token vencido

### Requirement: Aceptar una invitación deja al invitado trabajando en el negocio
Al aceptar una invitación, el sistema SHALL crear la membresía con el conjunto de roles declarado, SHALL dejar la cuenta del negocio como cuenta activa del invitado en la misma transacción, SHALL renovar su token y SHALL llevarlo al Tablero del negocio con un aviso de bienvenida que nombre el negocio y sus roles.

El invitado SHALL conservar la cuenta propia que se le creó al registrarse, y ambas cuentas SHALL aparecer en el selector de cuenta activa.

Si el invitado ya era miembro del negocio, la pantalla SHALL informarlo y ofrecer pasar a esa cuenta.

#### Scenario: El invitado entra al Tablero del negocio
- **GIVEN** un usuario con su cuenta propia que recibe una invitación al negocio con el rol de vendedor
- **WHEN** acepta la invitación
- **THEN** queda en el Tablero del negocio, con el negocio como cuenta activa, y el selector muestra su cuenta propia y el negocio

#### Scenario: Una venta posterior a la aceptación queda en el negocio
- **GIVEN** un invitado que acaba de aceptar
- **WHEN** registra una venta
- **THEN** la venta queda en la cuenta del negocio, no en su cuenta propia

#### Scenario: Aceptar dos veces informa que ya es miembro
- **GIVEN** un usuario que ya aceptó una invitación al negocio
- **WHEN** abre otra invitación vigente al mismo negocio y la acepta
- **THEN** se le informa que ya es miembro y se le ofrece pasar a esa cuenta, sin duplicar la membresía

### Requirement: Las invitaciones pendientes se gestionan desde la pantalla de invitación
El sistema SHALL mostrar, en la pantalla de invitación existente y sin cambiar su ruta ni sus accesos, la lista de invitaciones pendientes de la cuenta —con email, roles, fecha de envío, vencimiento y el estado de la última entrega del email— y las vencidas o revocadas recientes, a quien tiene autoridad para invitar.

El estado de la última entrega SHALL distinguir entregado, en cola, no se pudo enviar y sin confirmación (un envío que quedó en cola más que un plazo razonable), y NOT SHALL exponer el detalle técnico del proveedor de correo. Si la última entrega no se pudo enviar o quedó sin confirmación, la fila SHALL destacar la acción de reenviar con una explicación.

El sistema SHALL permitir:
- **reenviar** una invitación, lo que SHALL generar un enlace nuevo, invalidar los enlaces anteriores y renovar el vencimiento;
- **revocar** una invitación, lo que SHALL impedir su aceptación.

El listado NOT SHALL exponer el token.

La invitación rápida de la pantalla de configuración SHALL declarar el conjunto de roles del invitado, igual que la pantalla de invitación.

La superficie SHALL verificarse en escritorio y en móvil, y en tema claro y oscuro, antes de considerarse completa.

#### Scenario: Reenviar invalida el enlace anterior
- **GIVEN** una invitación pendiente cuyo email ya fue enviado
- **WHEN** el dueño la reenvía
- **THEN** se encola un email con un enlace nuevo, el enlace anterior deja de servir y el vencimiento se renueva

#### Scenario: Una invitación revocada no se puede aceptar
- **GIVEN** una invitación pendiente que el administrador revocó
- **WHEN** el invitado abre el enlace y acepta
- **THEN** la aceptación se rechaza con el mismo mensaje que una invitación vencida

#### Scenario: El administrador ve las pendientes
- **GIVEN** una cuenta con invitaciones pendientes y un miembro con rol de administrador
- **WHEN** el administrador abre la pantalla de invitación
- **THEN** ve la lista de invitaciones pendientes con sus acciones de reenviar y revocar

#### Scenario: Una entrega fallida se ve en la lista
- **GIVEN** una invitación pendiente cuyo último email el proveedor no pudo enviar
- **WHEN** el dueño abre la pantalla de invitación
- **THEN** la fila muestra que el email no se pudo enviar, sin el detalle técnico del proveedor, y destaca la acción de reenviar

#### Scenario: Una entrega aceptada por el proveedor se ve como enviada
- **GIVEN** una invitación pendiente cuyo último email el proveedor aceptó
- **WHEN** el dueño abre la pantalla de invitación
- **THEN** la fila muestra que el email se envió y cuándo

### Requirement: El envío de invitaciones tiene topes contra el abuso
El sistema SHALL limitar el envío del email de invitación a un envío por invitación dentro de una ventana de enfriamiento y a un tope diario de envíos por cuenta, y SHALL rechazar con un error propio del dominio, traducido a "demasiadas solicitudes", el envío que exceda cualquiera de los dos.

Un envío cuyo email no se pudo enviar NOT SHALL contar para la ventana de enfriamiento, y SHALL contar para el tope diario.

#### Scenario: Reenviar enseguida se rechaza
- **GIVEN** una invitación cuyo email se envió hace menos que la ventana de enfriamiento
- **WHEN** se intenta reenviarla
- **THEN** el reenvío se rechaza con el error de demasiadas solicitudes y no se encola ningún email

#### Scenario: Reenviar después de una entrega fallida no espera
- **GIVEN** una invitación cuyo último email, encolado hace menos que la ventana de enfriamiento, no se pudo enviar
- **WHEN** se reenvía
- **THEN** se encola un email nuevo con un enlace nuevo

#### Scenario: El tope diario de la cuenta se respeta
- **GIVEN** una cuenta que ya alcanzó el tope diario de emails de invitación
- **WHEN** intenta invitar a otra persona
- **THEN** el envío se rechaza con el error de demasiadas solicitudes

### Requirement: El token de invitación no se conserva en claro
El sistema SHALL guardar de cada invitación sólo un resumen criptográfico (hash) de su token, NOT el token en claro, y SHALL buscar la invitación por ese resumen al mostrar la vista previa y al aceptar.

El token SHALL generarse en cada envío del email de invitación, el primero incluido; SHALL entregarse una única vez a quien invita (para copiar el enlace) y a la plantilla del email; y SHALL retirarse del registro de envíos en cuanto el intento de entrega termina, cualquiera sea su resultado. Generar un token nuevo SHALL invalidar los enlaces anteriores de esa invitación.

#### Scenario: La fila de la invitación no contiene el token
- **GIVEN** un dueño que invita a una persona y el email queda encolado
- **WHEN** se inspecciona la fila de la invitación
- **THEN** la fila guarda el resumen del token y no el token, y el token devuelto a quien invita es aceptable por la persona invitada

#### Scenario: El registro del envío pierde el token al terminar el intento
- **GIVEN** un email de invitación encolado con el token para la plantilla
- **WHEN** el envío se marca como entregado, fallido o parcial
- **THEN** el registro de ese envío ya no contiene el token

#### Scenario: Cada envío emite un enlace nuevo
- **GIVEN** una invitación ya enviada una vez
- **WHEN** se reenvía
- **THEN** el enlace del primer envío deja de servir y sólo el del último envío permite aceptar

### Requirement: La tabla de invitaciones sólo se escribe por las funciones del dominio
El sistema SHALL impedir que los roles de aplicación lean o escriban las invitaciones directamente: NOT SHALL existir privilegios de tabla ni políticas de fila que permitan a un usuario autenticado o anónimo consultar, crear, modificar, borrar o vaciar invitaciones por fuera de las funciones del dominio (crear, enviar, listar, revocar, vista previa y aceptación), que SHALL seguir aplicando el cupo, el catálogo de roles, la validación del email y la autoridad.

Un gate permanente SHALL verificar la ausencia de esos privilegios y políticas y SHALL ejecutar las funciones del dominio de punta a punta.

#### Scenario: El dueño no puede crear una invitación salteando el cupo
- **GIVEN** el dueño autenticado de una cuenta sin cupo de usuarios disponible
- **WHEN** intenta insertar una invitación directamente en la tabla
- **THEN** la escritura se rechaza por falta de privilegios y no queda ninguna invitación nueva

#### Scenario: Nadie lee las invitaciones por la API de datos
- **GIVEN** un usuario autenticado dueño de una cuenta con invitaciones
- **WHEN** consulta la tabla de invitaciones directamente
- **THEN** la consulta se rechaza por falta de privilegios, y el listado sigue disponible por la función del dominio

