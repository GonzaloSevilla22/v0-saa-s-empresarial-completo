## ADDED Requirements

### Requirement: Resolución del punto de venta preseleccionado al facturar

El frontend SHALL resolver el punto de venta que se ofrece al facturar con una única función pura en `lib/` (fuente canónica, sin copias por pantalla), considerando **sólo puntos de venta activos**, en este orden: (1) el último punto de venta con el que el usuario facturó en la sesión actual para esta cuenta, si sigue activo; (2) el punto de venta predeterminado de la cuenta (`is_default`), si existe; (3) el único punto de venta activo, si hay uno solo; (4) ninguno. Un punto de venta inactivo NUNCA SHALL ofrecerse ni preseleccionarse, aunque sea el de menor número o el último usado.

#### Scenario: Sin elección previa se preselecciona el predeterminado

- **GIVEN** una cuenta con los PV 3 y 9999 activos, el 9999 predeterminado, y ninguna factura emitida en la sesión
- **WHEN** se resuelve el PV preseleccionado
- **THEN** el resultado es el 9999

#### Scenario: La última elección de la sesión gana sobre el predeterminado

- **GIVEN** una cuenta con los PV 3 y 9999 activos, el 9999 predeterminado, y una factura emitida en esta sesión por el 3
- **WHEN** se resuelve el PV preseleccionado
- **THEN** el resultado es el 3

#### Scenario: Una última elección que ya no está activa se ignora

- **GIVEN** la última factura de la sesión se emitió por el PV 3, y después el PV 3 se desactivó; el 9999 está activo y predeterminado
- **WHEN** se resuelve el PV preseleccionado
- **THEN** el resultado es el 9999

#### Scenario: Varios activos sin predeterminado ni elección previa no preseleccionan nada

- **GIVEN** una cuenta con los PV 3 y 9999 activos, ninguno predeterminado, y sin facturas en la sesión
- **WHEN** se resuelve el PV preseleccionado
- **THEN** no hay preselección y el usuario debe elegir

#### Scenario: Un PV inactivo de menor número no se ofrece

- **GIVEN** una cuenta con el PV 1 inactivo y el PV 3 activo
- **WHEN** se resuelve el PV preseleccionado
- **THEN** el resultado es el 3 (el 1 nunca aparece)

---

### Requirement: Facturar una venta con un solo punto de venta no agrega pasos

El botón de facturación de una venta (`EmitInvoiceButton`) SHALL obtener por sí mismo los puntos de venta de la cuenta y, cuando la cuenta tiene **exactamente un** punto de venta activo, SHALL emitir el comprobante con ese punto de venta explícito al primer clic, sin abrir ningún diálogo — el mismo número de pasos que antes de este cambio. Las pantallas que lo usan NO SHALL calcular ni pasar un punto de venta.

#### Scenario: Cuenta con un solo PV factura en un clic

- **GIVEN** una venta confirmada sin comprobante y una cuenta con un único PV activo
- **WHEN** el usuario pulsa el botón de emitir
- **THEN** se envía `POST /sales-orders/{id}/emit-invoice` con el `point_of_sale_id` de ese PV y no se abre ningún diálogo

---

### Requirement: Con varios puntos de venta el usuario elige al facturar

Cuando la cuenta tiene **dos o más** puntos de venta activos, el botón de facturación SHALL abrir el diálogo de emisión (`EmitirComprobanteDialog`, el componente existente — no uno nuevo) con la lista de puntos de venta activos, el punto de venta resuelto por el requisito "Resolución del punto de venta preseleccionado al facturar" ya marcado, y el botón de confirmar habilitado sólo cuando hay un punto de venta elegido. Al confirmar, SHALL enviar el `point_of_sale_id` elegido de forma **explícita** (nunca `null`, aunque exista un predeterminado) y SHALL recordar esa elección para la sesión de esta cuenta. Cancelar el diálogo NO SHALL emitir nada ni cambiar la elección recordada. El diálogo SHALL mostrar el número de PV con el formato de ARCA y SHALL indicar cuál es el predeterminado.

#### Scenario: Elegir el PV 9999 al facturar

- **GIVEN** una cuenta con los PV 3 y 9999 activos, ninguno predeterminado
- **WHEN** el usuario pulsa emitir, elige el 9999 en el diálogo y confirma
- **THEN** se envía la emisión con el `point_of_sale_id` del 9999, el comprobante resultante tiene `punto_de_venta = 9999`, y el diálogo se cierra

#### Scenario: Con predeterminado se confirma en un clic

- **GIVEN** una cuenta con los PV 3 y 9999 activos y el 9999 predeterminado
- **WHEN** el usuario pulsa emitir
- **THEN** el diálogo se abre con el 9999 ya elegido y el botón de confirmar habilitado

#### Scenario: Sin elección el diálogo no deja confirmar

- **GIVEN** una cuenta con dos PV activos, ninguno predeterminado ni usado en la sesión
- **WHEN** el diálogo se abre
- **THEN** el botón de confirmar está deshabilitado hasta que el usuario elige un PV

#### Scenario: Cancelar no emite

- **WHEN** el usuario abre el diálogo y cancela
- **THEN** no se envía ninguna emisión y la venta sigue sin comprobante

#### Scenario: La elección se recuerda en la sesión

- **GIVEN** el usuario facturó una venta eligiendo el PV 3
- **WHEN** pulsa emitir sobre otra venta en la misma sesión
- **THEN** el diálogo se abre con el PV 3 ya elegido

---

### Requirement: Los dos caminos de facturación de ventas usan la misma selección

La selección de punto de venta SHALL aplicar igual en los dos caminos por los que se factura una venta: `/ventas` (venta cargada a mano, después de "Facturar") y `/ventas/ordenes` (órdenes de venta, que es donde se facturan las ventas del POS). Ninguno de los dos SHALL enviar a la emisión un punto de venta inactivo ni un `point_of_sale_id` nulo cuando la cuenta tiene dos o más puntos de venta activos. El POS NO SHALL emitir comprobantes inline (requisito vigente de `sales-order`); su aviso "Facturar esta venta" SHALL seguir llevando a `/ventas/ordenes`.

#### Scenario: Facturar una venta del POS con dos PV activos

- **GIVEN** una venta hecha en el POS (orden confirmada sin comprobante) y una cuenta con los PV 3 y 9999 activos
- **WHEN** el usuario la factura desde `/ventas/ordenes` y elige el 9999
- **THEN** el comprobante se emite por el 9999, sin el error "La cuenta tiene varios puntos de venta activos"

#### Scenario: `/ventas` no usa el PV de menor número a ciegas

- **GIVEN** una cuenta con los PV 3 y 9999 activos
- **WHEN** el usuario factura una venta cargada a mano desde `/ventas`
- **THEN** se le pide elegir (o se preselecciona según la resolución) en lugar de emitir por el 3 sin preguntar

---

### Requirement: Un solo selector de punto de venta en la app

El selector de punto de venta SHALL existir como un único componente reutilizable (`PointOfSaleSelect`) consumido por el diálogo de emisión de ventas y por el diálogo de emisión de comprobantes de suscripción (`EmitirSuscripcionDialog`, `/admin/pagos`), que hoy tienen cada uno su copia. El diálogo de suscripción SHALL conservar su regla de habilitación (exige elegir cuando hay varios activos) y SHALL ganar la preselección del predeterminado; NO SHALL cambiar su llamada al backend.

#### Scenario: `/admin/pagos` preselecciona el predeterminado

- **GIVEN** la cuenta de la plataforma con los PV 3 y 9999 activos y el 3 predeterminado
- **WHEN** el admin abre el diálogo de emisión de un pago de suscripción
- **THEN** el selector aparece con el 3 ya elegido y el admin puede cambiarlo

---

### Requirement: El diálogo de emisión respeta el design system y funciona en mobile

El diálogo de emisión y el selector SHALL usar tokens semánticos del design system (sin colores literales de paleta como `amber-*`), SHALL ser operables con teclado y lector de pantalla (el selector con etiqueta asociada), y SHALL verificarse en desktop y mobile (375 px, sin desborde horizontal, botón de confirmar visible) y en tema claro y oscuro antes del merge.

#### Scenario: El diálogo cabe en un teléfono

- **GIVEN** un viewport de 375 px de ancho
- **WHEN** se abre el diálogo de emisión con dos PV activos
- **THEN** el selector y el botón de confirmar son visibles y operables sin scroll horizontal
