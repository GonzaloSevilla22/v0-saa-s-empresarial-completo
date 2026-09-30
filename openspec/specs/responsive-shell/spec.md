# responsive-shell Specification

## Purpose
Define el contrato estructural del shell del dashboard (sidebar + contenedor de contenido) a través de los distintos tamaños de viewport: contención del ancho sin desborde horizontal, comportamiento de scroll de los overlays que viven dentro de un modal o de un panel acotado (popovers, desplegable de notificaciones), objetivos táctiles mínimos, las vías estándar de cierre del menú lateral móvil, la navegación agrupada del menú lateral (categorías plegables, riel colapsado y drawer móvil), y el nombrado de cada ruta en el breadcrumb. Nace de `qa-integral-modulos` (QA integral del 2026-08-30): dos componentes compartidos —el popover portalizado fuera del shard de scroll del modal, y el `<main>` de `SidebarInset` sin `min-w-0`— explicaban 17 de los 27 hallazgos de esa corrida, así que el shell pasa a tener su propia capability en vez de que cada pantalla repita la corrección por separado.
## Requirements
### Requirement: El shell del dashboard nunca desborda horizontalmente el viewport

El sistema SHALL contener el ancho de todo el contenido del dashboard dentro del viewport en cualquier ancho desde 390 px: el `<main>` del shell (`SidebarInset`) y el contenedor de contenido del layout SHALL romper la cadena `min-width:auto` de flexbox (`min-w-0`), de modo que ningún contenido de pantalla pueda estirar el documento más allá del viewport. El contenido que exceda el ancho disponible SHALL scrollear dentro de su propio contenedor con `overflow-x-auto`, nunca desbordando la página. **En viewport móvil (≤ 430 px) y en tablet con el riel expandido (768–1024 px)** los controles primarios de cada pantalla (CTAs, acciones de fila, paginación) SHALL además ser visibles y operables sin desplazamiento horizontal alguno: la barra de **filtros** de cada pantalla SHALL wrappear (nunca comprimir ni empujar la barra de acciones) para que el CTA primario quede dentro del viewport inicial.

> **Historia de la cláusula de tablet**: `qa-integral-modulos` había acotado esta cláusula a móvil porque la pasada responsive de tablet (768–1024 px) era su Non-Goal declarado. `tablet-filtros-cta` cerró el hueco que esa acotación dejaba: a 1024 px con el riel expandido, las barras de **filtros** de `/ventas`, `/gastos`, `/compras` y `/clientes` no wrappeaban y su CTA quedaba fuera del viewport inicial. Con `flex-wrap` en el contenedor de controles y en el grupo de filtros de las cuatro pantallas, el CTA ahora entra en el viewport inicial sin scroll — la cláusula deja de acotarse a móvil.

#### Scenario: Pantalla con tabla ancha en móvil

- **GIVEN** una pantalla del dashboard cuyo contenido mínimo intrínseco excede 390 px
- **WHEN** se abre en un viewport de 390 px
- **THEN** `document.documentElement.scrollWidth` no supera el ancho del viewport
- **AND** la zona ancha scrollea dentro de su propio contenedor

#### Scenario: Los CTAs primarios quedan dentro del viewport

- **WHEN** se abren `/compras`, `/productos`, `/stock`, `/sucursales`, `/caja` o `/banco` en 390 px
- **THEN** el CTA primario de la pantalla y las acciones de fila (incluido el borrado de producto) caen dentro del viewport sin panear

#### Scenario: Tablet no estira el documento

- **WHEN** se abren `/ventas`, `/gastos`, `/compras`, `/clientes` o `/productos` en 768 px y en 1024 px
- **THEN** `document.documentElement.scrollWidth` no supera el ancho del viewport
- **AND** lo que no entra scrollea dentro del contenedor de contenido, con barra visible

#### Scenario: El CTA de filtros entra en el viewport inicial en tablet

- **GIVEN** el riel del sidebar expandido
- **WHEN** se abren `/ventas`, `/gastos`, `/compras` o `/clientes` en 1024 px de ancho
- **THEN** la barra de filtros de la pantalla wrappea en vez de comprimir la barra de acciones
- **AND** el CTA primario (`Nueva venta`/`Nuevo gasto`/`Nueva compra`/`Nuevo cliente`) cae dentro del viewport inicial (0..1024 x 0..768) sin necesidad de scroll

#### Scenario: El desktop no cambia

- **WHEN** el shell se renderiza a 1440 px
- **THEN** el layout del sidebar y del contenido conserva las dimensiones previas al fix

### Requirement: Los desplegables dentro de un modal son desplazables

El sistema SHALL permitir desplazar (rueda del mouse y gesto táctil) el contenido de todo popover o desplegable abierto dentro de un Dialog o Sheet: ningún gesto de rueda ni táctil sobre la lista SHALL ser cancelado por el bloqueo de scroll del modal, y el último ítem SHALL ser alcanzable y quedar visible (sin recorte del desplegable). Mecanismo: al detectar que vive dentro de un modal, el popover SHALL activar su propio contexto modal de scroll —el bloqueo más reciente, que exime a su propio contenido— y SHALL permanecer portalizado a `document.body` (colgarlo del subárbol del `DialogContent` lo somete al `transform` y al `overflow-y-auto` de ese nodo, que recortan el popper; verificado en el arnés, R1). Los popovers abiertos fuera de un modal SHALL conservar su comportamiento actual sin ningún cambio (cierre por click afuera y por Escape, sin bloqueo de scroll propio).

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
- **THEN** sigue funcionando como hasta ahora —sin bloquear el scroll de la página— y cierra por click afuera y por Escape

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

El sistema SHALL cerrar el drawer del menú lateral móvil por las tres vías estándar de la app: tecla Escape, botón de cierre visible dentro del panel, y toque sobre el overlay. Para que Escape siga llegando al drawer, ninguna capa de overlay que no se muestre en ese estado (por ejemplo el tooltip de un ítem del menú, que solo se ve con el riel colapsado en escritorio) SHALL montarse por encima de él: una capa invisible pero viva se vuelve la capa más alta y se queda con la tecla.

#### Scenario: Escape cierra el drawer

- **GIVEN** el menú lateral móvil abierto, con el foco en cualquier ítem del menú (el estado normal tras abrirlo)
- **WHEN** el usuario presiona Escape
- **THEN** el drawer se cierra y el foco vuelve al disparador

#### Scenario: El tooltip del riel no monta contenido en móvil

- **GIVEN** el menú lateral móvil abierto
- **WHEN** un ítem del menú recibe el foco
- **THEN** no se monta el contenido de su tooltip (en móvil nunca se muestra)
- **AND** el tooltip sigue apareciendo en escritorio con el riel colapsado, que es cuando el nombre del ítem no se lee de otra forma

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

### Requirement: Navegación agrupada del menú lateral

El sistema SHALL presentar el menú lateral con el Tablero suelto arriba (sin rótulo de categoría) y el resto de las pantallas agrupadas en seis categorías plegables, en este orden: Operaciones, Catálogo, Inteligencia, Estadísticas, Ecosistema y Mi Cuenta. Cada categoría SHALL ser un único control que arranca CERRADO y despliega sus módulos al tocarlo; SHALL haber a lo sumo una categoría abierta a la vez, y tocar un módulo SHALL navegar y cerrar la categoría sola, devolviendo el foco al control de la categoría (igual que cualquier cambio de ruta: breadcrumb, atrás, adelante, cierra la categoría abierta). En el drawer móvil cada fila de la navegación agrupada (Tablero, disparador de categoría y módulo) SHALL medir al menos 44 px de alto. La categoría que contiene la pantalla actual SHALL verse marcada aun cerrada, y el módulo activo SHALL ser el de href coincidente más largo (`/ventas/pos` marca POS y no Ventas; `/estadisticas/productos/:id` marca Estadísticas). Con el riel colapsado de escritorio cada categoría SHALL abrir un desplegable con sus módulos —los sub-ítems plegados no se ven en el riel, así que sin él quedarían rutas inalcanzables—, y en el drawer móvil las categorías SHALL comportarse como en el riel expandido y volver a estar cerradas al reabrirlo. La reorganización SHALL NOT quitar, renombrar ni duplicar ninguna ruta del menú, ni alterar los gates de plan (corona `pro`, módulos `proOnly`) ni la visibilidad por rol (el admin no ve Operaciones ni Catálogo; la sección Administración no cambia).

#### Scenario: Tablero suelto y seis categorías en orden

- **WHEN** el usuario abre la aplicación
- **THEN** el menú muestra el Tablero como ítem suelto, sin rótulo "Principal", seguido de las categorías Operaciones, Catálogo, Inteligencia, Estadísticas, Ecosistema y Mi Cuenta, cada una con su ícono

#### Scenario: Composición de las categorías

- **WHEN** el usuario despliega cada categoría
- **THEN** Operaciones contiene Ventas, POS — Venta Rápida, Compras, Gastos, Caja, Banco y Cobranzas
- **AND** Catálogo contiene Productos, Stock, Clientes, Proveedores y Sucursales
- **AND** Inteligencia contiene Copiloto IA, Consejos AI, Feria AI y Simulador
- **AND** Estadísticas contiene Estadísticas, Rentabilidad, Comparativo, Por Sucursal, Centros de costo, Formas de pago y Libro diario
- **AND** Ecosistema contiene Comunidad, Cursos y Seguros
- **AND** Mi Cuenta contiene Planes, Facturación y Exportaciones

#### Scenario: Cerradas hasta que las tocan

- **WHEN** el usuario carga cualquier pantalla del dashboard
- **THEN** las seis categorías están cerradas y ningún módulo de categoría está en el DOM

#### Scenario: Tocar una categoría la abre y cierra las demás

- **GIVEN** la categoría Operaciones abierta
- **WHEN** el usuario toca Catálogo
- **THEN** Catálogo se abre con sus módulos y Operaciones se cierra

#### Scenario: Tocar un módulo navega y cierra la categoría

- **GIVEN** la categoría Operaciones abierta
- **WHEN** el usuario toca Ventas
- **THEN** navega a `/ventas` y la categoría Operaciones queda cerrada
- **AND** el foco queda en el control de Operaciones, no se pierde al desmontarse el módulo tocado

#### Scenario: Un cambio de ruta cierra la categoría abierta

- **GIVEN** una categoría abierta
- **WHEN** la ruta cambia por cualquier vía (breadcrumb, atrás, adelante)
- **THEN** la categoría se cierra

#### Scenario: La categoría activa se ve aun cerrada

- **GIVEN** el usuario en `/ventas/pos` con todas las categorías cerradas
- **THEN** el control de Operaciones se ve marcado como activo y ningún otro
- **AND** al abrir Operaciones, POS — Venta Rápida está marcado y Ventas no

#### Scenario: El Tablero no marca ninguna categoría

- **GIVEN** el usuario en `/dashboard`
- **THEN** el Tablero se ve marcado y ninguna categoría lo está

#### Scenario: Riel colapsado con desplegables

- **GIVEN** el menú lateral de escritorio colapsado al riel de íconos
- **WHEN** el usuario toca el ícono de una categoría
- **THEN** se abre a la derecha un desplegable con los módulos de esa categoría como enlaces
- **AND** entre los desplegables se alcanzan todos los módulos visibles de las categorías (el Tablero sigue siendo un ítem directo del riel)
- **AND** al pasar el mouse por el ícono de una categoría o del Tablero se ve su nombre en un tooltip
- **AND** al elegir un módulo del desplegable el foco vuelve al ícono de su categoría sin dejar abierto el tooltip con su nombre
- **AND** al volver a expandir el riel todas las categorías están cerradas
- **AND** alternar entre el riel y el menú expandido con el foco del teclado en una categoría (o, con el menú expandido, en uno de sus módulos abiertos) deja el foco en el control de esa categoría

#### Scenario: Drawer móvil

- **WHEN** el usuario abre el menú lateral en móvil
- **THEN** las categorías están cerradas y se despliegan en su lugar, sin desplegables de riel
- **AND** Escape cierra el drawer aunque el foco esté en una categoría
- **AND** al reabrirlo las categorías vuelven a estar cerradas
- **AND** cada fila del menú (Tablero, categoría y módulo) mide al menos 44 px de alto; en escritorio conservan sus 32 px

#### Scenario: Ninguna ruta se rompe

- **WHEN** se compara la configuración del menú lateral nuevo con la del anterior
- **THEN** las 30 rutas del menú anterior (`/dashboard` y los 29 módulos) siguen presentes exactamente una vez, y cada una tiene su página en `app/(dashboard)`

#### Scenario: Visibilidad por rol y plan conservada

- **WHEN** la cuenta no tiene módulo de sucursales
- **THEN** no aparecen Sucursales ni Por Sucursal
- **AND** los módulos `pro` siguen mostrando la corona mientras el plan efectivo esté por debajo de "avanzado"
- **AND** un usuario admin no ve Operaciones ni Catálogo y conserva la sección Administración plana
