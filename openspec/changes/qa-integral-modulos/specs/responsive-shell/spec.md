# responsive-shell — Delta

## ADDED Requirements

### Requirement: El shell del dashboard nunca desborda horizontalmente el viewport

El sistema SHALL contener el ancho de todo el contenido del dashboard dentro del viewport en cualquier ancho desde 390 px: el `<main>` del shell (`SidebarInset`) y el contenedor de contenido del layout SHALL romper la cadena `min-width:auto` de flexbox (`min-w-0`), de modo que ningún contenido de pantalla pueda estirar el documento más allá del viewport. El contenido intrínsecamente ancho (tablas, paneles de movimientos, historiales) SHALL scrollear dentro de su propio contenedor con `overflow-x-auto`, nunca desbordando la página. Los controles primarios de cada pantalla (CTAs, acciones de fila, paginación) SHALL ser visibles y operables sin panear la ventana visual del navegador.

#### Scenario: Pantalla con tabla ancha en móvil

- **GIVEN** una pantalla del dashboard cuyo contenido mínimo intrínseco excede 390 px
- **WHEN** se abre en un viewport de 390 px
- **THEN** `document.documentElement.scrollWidth` no supera el ancho del viewport
- **AND** la zona ancha scrollea dentro de su propio contenedor

#### Scenario: Los CTAs primarios quedan dentro del viewport

- **WHEN** se abren `/compras`, `/productos`, `/stock`, `/sucursales`, `/caja` o `/banco` en 390 px
- **THEN** el CTA primario de la pantalla y las acciones de fila (incluido el borrado de producto) caen dentro del viewport sin panear

#### Scenario: El desktop no cambia

- **WHEN** el shell se renderiza a 1440 px
- **THEN** el layout del sidebar y del contenido conserva las dimensiones previas al fix

### Requirement: Los desplegables dentro de un modal son desplazables

El sistema SHALL permitir desplazar (rueda del mouse y gesto táctil) el contenido de todo popover o desplegable abierto dentro de un Dialog o Sheet: el nodo del popover SHALL quedar dentro del subárbol exceptuado del bloqueo de scroll del modal (el shard de `react-remove-scroll`), de modo que ningún gesto sobre la lista sea cancelado. Los popovers abiertos fuera de un modal SHALL conservar su comportamiento actual sin ningún cambio (portal a `document.body`, cierre por click afuera y por Escape).

#### Scenario: Selector de producto dentro del formulario de venta

- **GIVEN** el formulario de venta abierto como modal con un catálogo más alto que el desplegable
- **WHEN** el usuario abre "Seleccionar producto" y arrastra con el dedo o gira la rueda
- **THEN** la lista se desplaza (`scrollTop > 0`) y el último ítem es alcanzable

#### Scenario: Mismo contrato en compras y ajuste de stock

- **WHEN** se abre el selector de producto en "Nueva compra" o en "Ajustar" de `/stock`
- **THEN** la lista se desplaza con el mismo gesto

#### Scenario: El popover fuera de un modal no cambia

- **GIVEN** el mismo componente selector usado en una página sin modal (POS)
- **WHEN** se abre y se desplaza
- **THEN** sigue funcionando como hasta ahora, portalizado a `document.body`, y cierra por click afuera y por Escape

### Requirement: Los paneles de overlay con listas largas scrollean hasta el último ítem

El sistema SHALL hacer desplazable todo panel de overlay (dropdown, popover de campana de notificaciones) cuyo contenido exceda su alto máximo: el límite de alto SHALL aplicarse al viewport interno del área de scroll, no a un contenedor con `overflow: hidden` que recorte. Todo ítem del panel SHALL ser alcanzable por rueda y por gesto táctil.

#### Scenario: Campana con más notificaciones que el alto del panel

- **GIVEN** 15 notificaciones y un panel con alto máximo menor al contenido
- **WHEN** el usuario abre la campana y desplaza
- **THEN** llega hasta la notificación 15

### Requirement: Objetivos táctiles mínimos en móvil

El sistema SHALL garantizar en viewport móvil un objetivo táctil de al menos 24x24 px CSS (piso WCAG 2.5.8) en todo control interactivo, con 44x44 px como objetivo de diseño para controles primarios y de fila. En el tablero de conciliación bancaria, la fila completa de una línea del extracto SHALL ser clickeable para alternar su selección, no solo el checkbox.

#### Scenario: Checkbox de conciliación

- **WHEN** el usuario toca cualquier punto de la fila de una línea del extracto en móvil
- **THEN** la selección de esa línea se alterna

#### Scenario: Botones de ícono de fila

- **WHEN** se miden los botones de editar/desactivar de las filas y el botón de menú del encabezado en móvil
- **THEN** su área de toque efectiva es de al menos 24x24 px CSS

### Requirement: El menú lateral móvil se cierra por las vías estándar

El sistema SHALL cerrar el drawer del menú lateral móvil por las tres vías estándar de la app: tecla Escape, botón de cierre visible dentro del panel, y toque sobre el overlay.

#### Scenario: Escape cierra el drawer

- **GIVEN** el menú lateral móvil abierto
- **WHEN** el usuario presiona Escape
- **THEN** el drawer se cierra y el foco vuelve al disparador

#### Scenario: Botón de cierre visible

- **WHEN** el usuario abre el menú lateral móvil
- **THEN** existe un control de cierre visible y operable dentro del panel

### Requirement: El breadcrumb nombra la pantalla actual en toda ruta del dashboard

El sistema SHALL mostrar en el breadcrumb de la barra superior el nombre de la pantalla actual para toda ruta del dashboard; el literal de marca solo SHALL aparecer como raíz, nunca como único contenido en una ruta interna.

#### Scenario: Rutas de uso diario nombradas

- **WHEN** el usuario navega a `/caja`, `/banco`, `/sucursales`, `/ventas/pos`, `/reportes/formas-pago`, `/reportes/centros-costo`, `/rentabilidad`, `/planes`, `/facturacion`, `/exportaciones` o `/configuracion/fiscal`
- **THEN** el breadcrumb muestra el nombre de esa pantalla

#### Scenario: Ruta nueva sin nombre mapeado

- **WHEN** una ruta del dashboard no tiene nombre en el mapa del breadcrumb
- **THEN** se deriva un nombre legible del último segmento de la ruta en lugar de mostrar solo la marca
