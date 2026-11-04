# account-invitation-flow Specification

## Purpose

Define la invitación a una cuenta de punta a punta: el email que se encola en la misma transacción que crea o renueva la invitación (destinatario y token tomados de la fila registrada), la pantalla pública de aceptación ligada a la identidad invitada y sin datos del negocio para quien no corresponde, la aceptación que crea la membresía y deja el negocio como cuenta activa del invitado, la gestión de pendientes (listar, reenviar con enlace nuevo, revocar) y los topes contra el abuso del envío. Introducido por `multiusuario-operativo` (2026-10-17); el cupo de usuarios por plan vive en la capability `multi-tenant`.

## Requirements

### Requirement: La invitación se envía por email al invitado
El sistema SHALL enviar un email al invitado cada vez que un dueño o administrador crea o reenvía una invitación, y SHALL encolarlo en la misma transacción que crea o renueva la invitación.

El destinatario y el token del enlace SHALL tomarse de la invitación registrada, NOT de un dato provisto por quien invita. El email SHALL nombrar al negocio y a quien invita, los roles con que se incorporará y la fecha de vencimiento, y SHALL llevar un enlace a la pantalla de aceptación.

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
El sistema SHALL mostrar, en la pantalla de invitación existente y sin cambiar su ruta ni sus accesos, la lista de invitaciones pendientes de la cuenta —con email, roles, fecha de envío y vencimiento— y las vencidas o revocadas recientes, a quien tiene autoridad para invitar.

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

### Requirement: El envío de invitaciones tiene topes contra el abuso
El sistema SHALL limitar el envío del email de invitación a un envío por invitación dentro de una ventana de enfriamiento y a un tope diario de envíos por cuenta, y SHALL rechazar con un error propio del dominio, traducido a "demasiadas solicitudes", el envío que exceda cualquiera de los dos.

#### Scenario: Reenviar enseguida se rechaza
- **GIVEN** una invitación cuyo email se envió hace menos que la ventana de enfriamiento
- **WHEN** se intenta reenviarla
- **THEN** el reenvío se rechaza con el error de demasiadas solicitudes y no se encola ningún email

#### Scenario: El tope diario de la cuenta se respeta
- **GIVEN** una cuenta que ya alcanzó el tope diario de emails de invitación
- **WHEN** intenta invitar a otra persona
- **THEN** el envío se rechaza con el error de demasiadas solicitudes

