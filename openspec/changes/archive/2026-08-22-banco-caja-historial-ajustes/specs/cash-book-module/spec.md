## ADDED Requirements

### Requirement: Caja es un módulo de primer nivel con ruta y entrada de menú propias
El sistema SHALL exponer la caja como un módulo propio en la ruta `/caja`, alcanzable desde una entrada de sidebar propia del grupo **Operaciones** titulada "Caja", a la par de Ventas, Compras, Gastos y Banco, sin requerir navegar por Sucursales. La pantalla SHALL resolver la sucursal y la caja **dentro de sí misma** mediante selectores, y NO SHALL exigir que el usuario elija una sucursal antes de llegar a ella.

#### Scenario: El cajero llega a la caja desde el menú
- **WHEN** un usuario con permiso abre el sidebar y hace clic en "Caja"
- **THEN** navega a `/caja` y ve la caja de su sucursal sin haber pasado por `/sucursales`

#### Scenario: La entrada de menú existe en el grupo Operaciones
- **WHEN** se inspecciona la configuración del sidebar
- **THEN** el grupo "Operaciones" contiene una entrada con `title = "Caja"` y `href = "/caja"`

### Requirement: La pantalla de caja selecciona sucursal y caja con preselección automática
El sistema SHALL ofrecer en `/caja` un selector de sucursal y un selector de caja, y SHALL preseleccionar automáticamente la sucursal cuando la cuenta tiene una sola sucursal operativa y la caja cuando la sucursal seleccionada tiene una sola caja activa. Cuando la sucursal tiene una única caja, el selector de caja SHALL ocultarse en vez de mostrar una única opción.

#### Scenario: Cuenta con una sola sucursal y una sola caja
- **GIVEN** una cuenta con una sucursal operativa que tiene exactamente una caja activa
- **WHEN** el usuario abre `/caja`
- **THEN** la sucursal y la caja quedan preseleccionadas, el selector de caja no se muestra y la pantalla carga el estado de esa caja

#### Scenario: Cuenta con varias sucursales
- **GIVEN** una cuenta con más de una sucursal operativa
- **WHEN** el usuario abre `/caja` sin parámetro de sucursal
- **THEN** el selector de sucursal se muestra y la pantalla pide elegir una antes de cargar el estado de caja

#### Scenario: Sucursal sin caja configurada
- **GIVEN** una sucursal seleccionada que no tiene ninguna caja activa
- **WHEN** el usuario abre `/caja` para esa sucursal
- **THEN** la pantalla ofrece crear la caja en el lugar, sin redirigir a otra sección

### Requirement: La pantalla de caja reúne estado de sesión, acciones e historial
El sistema SHALL presentar en `/caja`, para la caja seleccionada: el estado de la sesión actual con su saldo corriente, la barra de acciones (abrir sesión, cerrar con arqueo, registrar ajuste), el historial de movimientos de la caja y el historial de sesiones con su diferencia de arqueo. Las acciones que no son aplicables al estado actual SHALL presentarse deshabilitadas con el motivo visible, en lugar de ocultarse sin explicación.

#### Scenario: Caja sin sesión abierta
- **GIVEN** una caja seleccionada sin sesión `open`
- **WHEN** el usuario abre `/caja`
- **THEN** la pantalla ofrece abrir sesión, el historial de movimientos sigue siendo consultable, y las acciones de cierre y de ajuste aparecen deshabilitadas indicando que requieren una sesión abierta

#### Scenario: Caja con sesión abierta
- **GIVEN** una caja seleccionada con una sesión `open`
- **WHEN** el usuario abre `/caja`
- **THEN** la pantalla muestra el saldo corriente de la sesión y habilita cerrar con arqueo y registrar ajuste

### Requirement: La ruta de caja por sucursal se conserva como acceso contextual
El sistema SHALL conservar `/sucursales/:id/caja` como punto de entrada contextual desde el detalle de sucursal, redirigiendo del lado del servidor a `/caja` con la sucursal ya seleccionada, de modo que no queden enlaces ni marcadores rotos y exista una única pantalla de caja que mantener.

#### Scenario: Enlace viejo de caja por sucursal
- **WHEN** un usuario abre `/sucursales/<id>/caja`
- **THEN** el servidor lo redirige a `/caja` con la sucursal `<id>` preseleccionada, sin parpadeo de pantalla intermedia

#### Scenario: No existen dos implementaciones de la caja
- **WHEN** se inspecciona el árbol de rutas
- **THEN** la lógica de la pantalla de caja vive únicamente en `/caja`, y la ruta por sucursal contiene sólo la redirección

### Requirement: Banco es un módulo de primer nivel con la conciliación dentro
El sistema SHALL exponer el banco como un módulo propio en la ruta `/banco`, con la entrada de sidebar del grupo **Operaciones** apuntando a esa ruta, organizado en las pestañas **Movimientos** y **Conciliación**. La pestaña de conciliación SHALL montar las piezas de conciliación ya existentes sin reescribirlas, y la ruta previa `/finanzas/conciliacion` SHALL redirigir del lado del servidor a la pestaña de conciliación de `/banco`.

#### Scenario: El usuario llega al banco desde el menú
- **WHEN** un usuario con permiso hace clic en la entrada "Banco" del sidebar
- **THEN** navega a `/banco` y ve la pestaña de movimientos de la cuenta bancaria seleccionada

#### Scenario: Enlace viejo de conciliación
- **WHEN** un usuario abre `/finanzas/conciliacion`
- **THEN** el servidor lo redirige a `/banco` con la pestaña de conciliación activa

#### Scenario: La conciliación sigue funcionando igual
- **GIVEN** una cuenta bancaria con una sesión de conciliación abierta
- **WHEN** el usuario entra a la pestaña Conciliación de `/banco`
- **THEN** ve el mismo tablero de conciliación, el importador de extracto y el alta de cuenta bancaria, con el mismo comportamiento que antes del cambio de ruta

### Requirement: Las pantallas de caja y banco cumplen el sistema de diseño en ambos temas y tamaños
El sistema SHALL construir las pantallas `/caja` y `/banco` con los tokens semánticos del design system y componentes base vía `cva`, y SHALL verificarlas en **desktop y mobile** y en **tema claro y oscuro** antes del merge, sin colores literales que evadan el gate de contraste AA vigente.

#### Scenario: Contraste y tokens
- **WHEN** se ejecuta el gate de contraste de tokens sobre las superficies nuevas
- **THEN** ninguna superficie de `/caja` ni de `/banco` usa colores literales fuera del sistema de tokens y el gate pasa

#### Scenario: Responsive
- **WHEN** se abre `/caja` y `/banco` en viewport mobile
- **THEN** los selectores, la barra de acciones y el historial son operables sin scroll horizontal de la página
