## ADDED Requirements

### Requirement: Remito de venta interno con cliente, sucursal y líneas con producto
El sistema SHALL modelar el remito como documento interno ("X"), no fiscal, en `delivery_notes` + `delivery_note_items`, con un sentido (`direction`) que admite `'sale'` y `'purchase'`. Sólo `'sale'` tiene operaciones de escritura en este change.

Un remito de venta SHALL tener:
- un cliente vivo de su cuenta;
- una sucursal de origen de su cuenta, activa y no cerrada;
- al menos una línea.

Cada línea SHALL tener un producto vivo de la cuenta que no sea padre con variantes ni `variant_only`, una cantidad mayor que cero, un precio por unidad de la línea no negativo guardado sin redondear y un subtotal no negativo. Los precios SHALL guardarse siempre, aunque el PDF no los muestre. El total SHALL calcularlo el servidor como el redondeo a 2 decimales de la suma de subtotales, ignorando cualquier total que envíe el cliente.

Una línea sin producto SHALL rechazarse con `P0400 delivery_note_product_required`. El remito admite además domicilio de entrega (hasta 500 caracteres) y notas (hasta 2.000), opcionales. La fecha del remito SHALL ser el día argentino de la emisión y no se edita.

#### Scenario: Alta válida
- **GIVEN** un cliente vivo, una sucursal activa de la cuenta y dos productos con stock suficiente
- **WHEN** un vendedor emite un remito con dos líneas
- **THEN** existe un remito `issued` con fecha de hoy (ART), las dos líneas y el total calculado por el servidor

#### Scenario: Línea sin producto rechazada
- **WHEN** se emite un remito con una línea sin `product_id`
- **THEN** la operación falla con `P0400 delivery_note_product_required` y no se escribe nada

#### Scenario: Contraparte y sucursal ajenas o inválidas
- **WHEN** se emite un remito con un cliente de otra cuenta, un cliente dado de baja, sin sucursal, con una sucursal de otra cuenta o con una sucursal cerrada
- **THEN** la operación falla con `P0404 client_not_found`, `P0400 delivery_note_branch_required`, `P0404` o `P0422 branch_closed`, según el caso, sin escribir nada

#### Scenario: Producto inválido
- **WHEN** una línea referencia un producto de otra cuenta, dado de baja, o un padre con variantes
- **THEN** la operación falla con `P0404 product_not_found` o `P0400 product_is_parent` y no se escribe nada

### Requirement: Escritura del remito sólo por operaciones con guard de tenencia y rol
El sistema SHALL permitir escribir `delivery_notes` y `delivery_note_items` únicamente por las operaciones del remito (emitir, editar, anular y convertir), que verifican tenencia, rol, estado y versión antes de escribir. Ninguna política de base de datos SHALL permitir `INSERT`, `UPDATE` ni `DELETE` directos a los roles de aplicación, y los helpers internos SHALL NOT ser ejecutables por `anon` ni `authenticated`.

La cuenta del remito SHALL resolverse desde la contraparte entre las cuentas del usuario, nunca desde un parámetro libre. Un remito inexistente y uno de otra cuenta SHALL responder igual (`P0404 delivery_note_not_found`).

#### Scenario: Escritura directa rechazada
- **WHEN** un usuario autenticado intenta un `INSERT` o un `UPDATE` directo sobre `delivery_notes` o `delivery_note_items`
- **THEN** la base lo rechaza y no cambia ninguna fila

#### Scenario: Remito de otra cuenta
- **WHEN** un usuario intenta editar, anular, convertir o descargar el PDF de un remito de otra cuenta
- **THEN** recibe `P0404 delivery_note_not_found` (404 en la API), con el mismo cuerpo que para un remito inexistente

### Requirement: Emitir el remito descuenta stock con la misma regla que la venta
El sistema SHALL descontar el stock de la sucursal de origen en la misma transacción en que emite un remito de venta. Para eso SHALL:

1. tomar con bloqueo los productos involucrados, en orden ascendente de id;
2. normalizar la cantidad de cada línea a la unidad base efectiva del producto con la definición única de normalización (después del bloqueo) y guardarla en la línea, en el mismo alta de la línea, como la cantidad base que la línea retiene;
3. agrupar por producto y sucursal;
4. exigir que el stock de la sucursal cubra lo requerido.

Si el stock no cubre lo requerido, SHALL fallar con `P0409` y el mismo literal de stock insuficiente que la venta, sin dejar ningún efecto: ni remito, ni número consumido, ni stock, ni movimiento.

Por cada par producto-sucursal SHALL registrar en el ledger un movimiento con `type = 'sale'`, `reference_type = 'delivery_note'`, `reference_id` = id del remito, el delta negativo normalizado, las cantidades antes y después, la sucursal, el nombre del producto, el usuario y el costo unitario congelado de la línea.

La emisión SHALL ser idempotente: exige una clave de idempotencia (header `Idempotency-Key` en la API) y, ante la misma clave del mismo usuario, SHALL devolver el remito original marcado como repetido, sin crear otro remito ni volver a descontar stock.

#### Scenario: Remito en gramos de un producto en kilogramos
- **GIVEN** un producto con unidad base Kilogramo y stock `1` en la sucursal
- **WHEN** se emite un remito con una línea de `450` Gramo
- **THEN** el stock queda en `0.55` y existe un movimiento `sale` / `delivery_note` con `quantity_delta = -0.45` que apunta al remito

#### Scenario: Stock insuficiente sin efectos
- **GIVEN** un producto con stock `2` en la sucursal
- **WHEN** se emite un remito con `3` unidades de ese producto
- **THEN** la operación falla con `P0409` y el literal de stock insuficiente
- **AND** no existe el remito, el próximo remito toma el número que habría tomado éste y el stock sigue en `2`

#### Scenario: Dos líneas del mismo producto se controlan juntas
- **GIVEN** un producto con stock `3`
- **WHEN** se emite un remito con dos líneas de `2` unidades de ese producto
- **THEN** la operación falla con `P0409`, porque lo requerido para el par es `4`

#### Scenario: Doble envío de la emisión
- **GIVEN** un producto con stock `5`
- **WHEN** el mismo usuario envía dos veces la emisión de un remito de `2` unidades con la misma clave de idempotencia
- **THEN** existe un solo remito, el stock queda en `3` y la segunda respuesta devuelve el mismo remito marcado como repetido

#### Scenario: Crear un remito no toca caja, banco ni cuenta corriente
- **WHEN** se emite un remito
- **THEN** no se escribe ningún movimiento de caja, de banco ni de cuenta corriente, ni ningún evento de venta

### Requirement: Edición del remito mientras no esté convertido, con par espejo en el ledger
El sistema SHALL permitir editar un remito `issued` (líneas, cantidades, precios, cliente, sucursal, domicilio y notas) como un reemplazo completo y atómico, tomando el remito con bloqueo y exigiendo la versión que el usuario vio.

Si la versión no coincide, SHALL fallar con `P0409 delivery_note_changed` sin cambiar nada. Un remito `converted` SHALL rechazar la edición con `P0423 delivery_note_locked_converted`, y uno `canceled` con `P0409 delivery_note_invalid_state`.

Para cada par producto-sucursal SHALL calcular lo que el remito retiene hoy y lo que requieren las líneas nuevas, normalizado. Lo retenido SHALL ser la suma de las cantidades base guardadas en las líneas vigentes del remito para ese producto, en la sucursal vigente del remito (cero en cualquier otra), y NO SHALL calcularse sumando movimientos del ledger, que los roles de aplicación pueden insertar. Si los dos valores difieren, SHALL registrar:
- una pata de reversa: `type = 'sale_return'`, `reference_type = 'delivery_note_update'`, con lo retenido;
- después, una pata de aplicación: `type = 'sale'`, `reference_type = 'delivery_note'`, con lo requerido.

El control de faltante SHALL evaluarse sobre el stock con la reversa ya aplicada. Los pares sin cambio SHALL NOT escribir movimientos. Editar SHALL incrementar la versión, NO SHALL cambiar el estado y NO SHALL registrar historial de estados.

Los snapshots SHALL seguir la política canónica de operaciones: la línea cuyo producto ya estaba en el remito conserva nombre, SKU, costo y alícuota de IVA de la línea vieja; un producto nuevo los toma del maestro vigente de la cuenta.

Un producto que ya estaba en el remito y fue dado de baja después de emitirlo SHALL aceptarse en la edición sin revalidar el catálogo vivo, conservando su snapshot, siempre que su cantidad base no supere la que el remito ya retiene de él: conservarla o reducirla SHALL funcionar, y aumentarla SHALL rechazarse con `P0400 delivery_note_product_unavailable`. Un producto dado de baja que no estaba en el remito SHALL rechazarse como en el alta.

#### Scenario: Cambiar sólo un precio no mueve el ledger
- **GIVEN** un remito `issued` con 2 unidades de A
- **WHEN** se edita sólo el precio de la línea
- **THEN** el total cambia, la versión aumenta en 1 y no se escribe ningún movimiento de stock

#### Scenario: Aumentar la cantidad deja el par espejo
- **GIVEN** un remito con 2 unidades de A y stock de A en `5`
- **WHEN** se edita a 4 unidades
- **THEN** el ledger suma `sale_return` / `delivery_note_update` de `+2` y `sale` / `delivery_note` de `-4`, y el stock de A queda en `3`

#### Scenario: Faltante sobre el neto
- **GIVEN** un remito con 2 unidades de A y stock de A en `1`
- **WHEN** se edita a 4 unidades
- **THEN** la operación falla con `P0409` porque el disponible tras la reversa es `3`, y nada cambia

#### Scenario: Reducir funciona aunque la sucursal esté en cero
- **GIVEN** un remito con 3 unidades de A y stock de A en `0`
- **WHEN** se edita a 1 unidad
- **THEN** la edición se acepta y el stock de A queda en `2`

#### Scenario: Cambiar la sucursal traslada el stock
- **GIVEN** un remito con 2 unidades de A desde la sucursal X, y stock de A en Y
- **WHEN** se edita la sucursal a Y
- **THEN** X recibe una pata de reversa de `+2` e Y una de aplicación de `-2`

#### Scenario: Producto dado de baja después de emitir no traba la edición
- **GIVEN** un remito `issued` con 2 unidades de A y 1 de B, y A dado de baja después de emitirlo
- **WHEN** se edita el precio de B sin tocar la línea de A
- **THEN** la edición se acepta, la línea de A se conserva con su nombre congelado y no se escribe ningún movimiento de stock para A

#### Scenario: No se aumenta un producto dado de baja
- **GIVEN** el mismo remito
- **WHEN** se edita la línea de A a 3 unidades
- **THEN** la operación falla con `P0400 delivery_note_product_unavailable` y nada cambia

#### Scenario: Remito convertido inmutable
- **GIVEN** un remito `converted`
- **WHEN** se intenta editarlo
- **THEN** la operación falla con `P0423 delivery_note_locked_converted` y nada cambia

#### Scenario: Edición concurrente
- **GIVEN** dos usuarios abrieron la misma versión de un remito
- **WHEN** el segundo guarda después de que el primero guardó
- **THEN** el segundo recibe `P0409 delivery_note_changed` y el remito conserva la edición del primero

### Requirement: Anulación del remito con motivo que repone el stock
El sistema SHALL permitir anular un remito `issued` sólo a administradores y dueños, exigiendo un motivo no vacío y la versión vigente.

La anulación SHALL tomar con bloqueo los productos del remito, en orden ascendente de id, antes de leer el stock, y SHALL reponer, por cada par producto-sucursal con stock retenido, la cantidad retenida (la suma de las cantidades base de sus líneas vigentes, nunca un cálculo sobre el ledger), con un movimiento `type = 'sale_return'`, `reference_type = 'delivery_note_reversal'` y el costo congelado de las líneas. SHALL registrar la transición `issued → canceled` con el motivo y el actor, en la misma transacción.

Las anulaciones rechazadas responden así:
- un remito `converted`: `P0423 delivery_note_locked_converted` (primero se borra la venta);
- uno ya `canceled`: `P0409 delivery_note_invalid_state`;
- sin motivo: `P0400 delivery_note_cancel_reason_required`;
- un rol sin permiso: `P0403 insufficient_role`.

#### Scenario: Anular repone el stock
- **GIVEN** un remito `issued` que retiene 3 unidades de A en la sucursal X
- **WHEN** un administrador lo anula con el motivo "cliente rechazó la entrega"
- **THEN** el stock de A en X aumenta en 3, existe un movimiento `sale_return` / `delivery_note_reversal` de `+3`, el remito queda `canceled` y el historial registra el motivo y el administrador

#### Scenario: El vendedor no anula
- **WHEN** un usuario con rol `seller` o `stock` intenta anular un remito
- **THEN** la operación falla con `P0403 insufficient_role` y el remito sigue `issued`

#### Scenario: El ledger del remito anulado cierra en cero
- **GIVEN** un remito emitido, editado dos veces y anulado
- **WHEN** se suman las `quantity_delta` de sus movimientos por par producto-sucursal
- **THEN** cada suma es `0` e iguala al cambio neto del stock de ese par

#### Scenario: Una fila forjada en el ledger no devuelve stock
- **GIVEN** un remito `issued` que retiene 3 unidades de A, y un movimiento de `-1000` insertado por PostgREST con la referencia de ese remito
- **WHEN** un administrador anula el remito
- **THEN** el stock de A en su sucursal aumenta exactamente en 3, no en 1003

### Requirement: Conversión atómica del remito en venta sin volver a mover stock
El sistema SHALL convertir un remito `issued` en una venta confirmada en una sola transacción, con estos pasos:

1. tomar el remito con bloqueo antes que cualquier otra cosa;
2. leer la idempotencia bajo ese bloqueo;
3. exigir estado `issued`, la versión vista por el usuario, una forma de pago del catálogo, un cliente vivo y que la sucursal del remito esté activa y no cerrada (`P0422 branch_closed`);
4. crear una orden de venta en la sucursal del remito, con su cliente y con todas sus líneas (producto, unidad, cantidad, precio, subtotal y snapshots copiados del remito, sin releer el maestro), con el origen `source_delivery_note_id`;
5. confirmarla con el núcleo de la venta, que en las líneas de la venta SHALL usar los snapshots de nombre, SKU, costo y alícuota de IVA del remito, sin releer ni bloquear el maestro de productos;
6. pasar el remito a `converted`, con historial.

La venta SHALL manejar caja, banco, cuenta corriente y outbox como cualquier venta confirmada, SHALL ser facturable con la acción existente y SHALL NOT mover stock. Un producto dado de baja después de emitir el remito SHALL NOT impedir la conversión.

Cualquier fallo SHALL revertir todo: el remito sigue `issued` y no queda ninguna orden.

Los rechazos responden así:
- un remito `converted` o `canceled`: `P0409 delivery_note_invalid_state`;
- una versión vieja: `P0409 delivery_note_changed`;
- un cliente dado de baja: `P0404 delivery_note_client_unavailable`;
- la misma clave de idempotencia sobre otro documento: `P0409 idempotency_key_conflict`;
- la misma clave sobre el mismo remito: devuelve el resultado original marcado como repetido, sin efectos nuevos.

La conversión SHALL estar permitida a vendedores, cajeros, administradores y dueños, y rechazada al rol `stock` con `P0403`.

#### Scenario: Convertir no vuelve a descontar
- **GIVEN** un remito `issued` de 3 unidades de A, emitido cuando el stock de A pasó de `10` a `7`
- **WHEN** se lo convierte en venta en efectivo con la caja de su sucursal abierta
- **THEN** el stock de A sigue en `7`, existe una venta confirmada con las 3 unidades y su movimiento de caja, el remito queda `converted` y ninguna fila de la venta tiene movimiento de stock propio

#### Scenario: Venta a crédito desde un remito
- **WHEN** se convierte un remito con una forma de pago `credit`
- **THEN** se postea el cargo en la cuenta corriente del cliente, con el vencimiento por cascada, sin movimiento de caja

#### Scenario: Doble clic
- **WHEN** se envía dos veces la conversión del mismo remito con la misma clave de idempotencia
- **THEN** existe una sola venta y la segunda respuesta indica `replayed = true`

#### Scenario: Segunda conversión con otra clave
- **GIVEN** un remito ya convertido
- **WHEN** se intenta convertirlo otra vez con otra clave
- **THEN** la operación falla con `P0409 delivery_note_invalid_state`

#### Scenario: Cliente dado de baja
- **GIVEN** un remito cuyo cliente fue dado de baja después de emitirlo
- **WHEN** se intenta convertirlo
- **THEN** la operación falla con `P0404 delivery_note_client_unavailable`, sin orden ni cargo en cuenta corriente

#### Scenario: Producto dado de baja después de emitir
- **GIVEN** un remito con una línea de un producto que se dio de baja después de emitirlo
- **WHEN** se lo convierte
- **THEN** la venta se crea con esa línea y su nombre congelado

#### Scenario: Producto renombrado después de emitir
- **GIVEN** un remito con una línea del producto "Cemento 50 kg", renombrado después a "Cemento Loma Negra 50 kg"
- **WHEN** se lo convierte
- **THEN** la línea de la venta conserva el nombre y el SKU del remito

#### Scenario: Efectivo sin caja abierta
- **WHEN** se convierte un remito con una forma de pago `cash` sin sesión de caja abierta en su sucursal
- **THEN** la operación falla con `P0400 cash_requires_session` y el remito sigue `issued`

### Requirement: Vida posterior de la venta nacida de un remito
El sistema SHALL tratar la venta nacida de un remito así:

- **Borrarla**: SHALL compensar dinero y orden como cualquier venta, NO SHALL tocar el stock y SHALL devolver el remito a `issued`, registrando la transición `converted → issued` con el motivo del borrado en la misma transacción. El remito SHALL poder volver a convertirse después.
- **Editarla**: SHALL rechazarse con `P0423 delivery_note_sale_locked` antes de cualquier efecto.
- **Anular el remito mientras la venta exista**: SHALL rechazarse con `P0423 delivery_note_locked_converted`.
- **Venta con comprobante fiscal autorizado**: como esa venta no se puede borrar, el remito queda cerrado; la interfaz SHALL explicarlo e indicar que la devolución de mercadería requiere una nota de crédito.

#### Scenario: Borrar la venta devuelve el remito a pendiente
- **GIVEN** una venta en efectivo nacida de un remito de 3 unidades de A, con el stock de A en `7`
- **WHEN** se borra la venta con la caja abierta
- **THEN** la caja registra la compensación, la orden queda `canceled`, el stock de A sigue en `7` y el remito vuelve a `issued` con el historial `converted → issued`

#### Scenario: Reconvertir tras el borrado
- **GIVEN** un remito que volvió a `issued` porque se borró su venta
- **WHEN** se lo convierte otra vez
- **THEN** se crea una venta nueva y el remito vuelve a `converted`

#### Scenario: Editar la venta está bloqueado
- **WHEN** se intenta editar una venta nacida de un remito
- **THEN** la operación falla con `P0423 delivery_note_sale_locked`, sin anular su comprobante pendiente ni mover stock

### Requirement: PDF del remito sin precios por defecto
El sistema SHALL generar el PDF del remito por id y con tenencia, para cualquier estado y para cualquier miembro de la cuenta. El PDF SHALL incluir:
- el título "REMITO" y el número `R-…`;
- los datos del emisor (sin bloquear si faltan);
- el cliente y el domicilio de entrega;
- la sucursal de origen y la fecha;
- las líneas con cantidad y unidad;
- las notas;
- un bloque de firma de recepción (firma, aclaración, DNI, fecha);
- la leyenda "Remito — documento no válido como factura".

Por defecto el PDF SHALL omitir precios, subtotales y total, y SHALL incluirlos sólo cuando se pida explícitamente mostrar precios. Un remito anulado SHALL llevar el sello "ANULADO".

#### Scenario: PDF por defecto sin precios
- **WHEN** se descarga el PDF de un remito sin pedir precios
- **THEN** el documento contiene "REMITO", el número, las cantidades, el bloque de firma y "no válido como factura", y no contiene precios ni total

#### Scenario: PDF con precios
- **WHEN** se descarga el PDF pidiendo mostrar precios
- **THEN** el documento incluye el precio, el subtotal de cada línea y el total

#### Scenario: Remito anulado
- **WHEN** se descarga el PDF de un remito `canceled`
- **THEN** el documento lleva el sello "ANULADO"

### Requirement: Envío del remito por descarga y WhatsApp
El sistema SHALL ofrecer en el detalle del remito el menú compartido de documentos (ver o imprimir, descargar y enviar por WhatsApp), con un control "Mostrar precios" apagado por defecto, fuera del menú, que define el PDF que se ve, se descarga o se envía: cambiarlo SHALL descartar cualquier PDF ya preparado, de modo que lo compartido sea siempre la variante elegida. Enviar por WhatsApp SHALL usar el teléfono del cliente si es válido, y si no, abrir el selector de contactos con un aviso. Compartir un remito NO SHALL cambiar su estado. No SHALL existir link público ni envío por email.

#### Scenario: Envío con precios ocultos por defecto
- **WHEN** el usuario elige "Enviar por WhatsApp" sin tocar "Mostrar precios"
- **THEN** el PDF compartido no contiene precios y el texto menciona el número del remito

#### Scenario: Cambiar "Mostrar precios" cambia lo que se envía
- **GIVEN** el menú de compartir ya abierto una vez sin precios
- **WHEN** el usuario enciende "Mostrar precios" y elige "Enviar por WhatsApp"
- **THEN** el PDF compartido incluye precios y total

#### Scenario: Cliente sin teléfono
- **WHEN** el cliente no tiene un teléfono válido
- **THEN** se abre WhatsApp sin destinatario y se avisa que no hay número registrado

### Requirement: Pantallas de remitos
El sistema SHALL exponer los remitos de venta en estas superficies:

- **Sidebar**: entrada "Remitos" en el grupo *Operaciones*, después de "Presupuestos", sin gate de plan.
- **`/remitos`**: listado paginado con filtros por estado y búsqueda por cliente o número, más un resumen de los pendientes (cantidad y total).
- **`/remitos/nuevo`**: alta con el editor de líneas compartido, mostrando y haciendo cumplir el stock de la sucursal elegida (nunca el stock agregado de todas las sucursales). La sucursal SHALL ser obligatoria y visible en todos los planes, sin opción "sin sucursal", y SHALL avisar que emitir descuenta stock de esa sucursal.
- **`/remitos/[id]`**: detalle con las acciones según estado y rol. El diálogo "Venta" SHALL avisar que el stock ya se descontó al emitir el remito y que la venta no lo vuelve a descontar.
- **`/remitos/[id]/editar`**: edición. Todas las líneas cuentan contra un mismo disponible: el stock de la sucursal elegida más lo que el remito ya retiene en ella (cero si se cambia de sucursal). Antes de guardar SHALL mostrar qué stock vuelve y qué stock sale. Una línea de un producto dado de baja SHALL conservarse sin bloquear el guardado.
- **Estados de página**: sin permiso, cargando, error o no encontrado, y no editable (convertido o anulado, con su explicación).
- **Ficha del cliente**: acción "Nuevo remito" con el cliente preseleccionado.
- **`/ventas`**: badge "Desde remito R-…" con enlace.
- **Panel de movimientos de stock**: rotula los movimientos del remito como "Remito", "Edición de remito" o "Anulación de remito", con su número.

Mientras no exista el remito de compra, la pantalla NO SHALL mostrar pestañas de sentido. Las pantallas SHALL verificarse en escritorio y en 375 px, en tema claro y oscuro.

#### Scenario: Acciones de un remito pendiente
- **GIVEN** un remito `issued` y un usuario administrador
- **WHEN** abre el detalle
- **THEN** ve Compartir, Editar, Venta y Anular

#### Scenario: Acciones de un remito convertido
- **GIVEN** un remito `converted`
- **WHEN** se abre el detalle
- **THEN** ve Compartir y Ver venta, sin Editar ni Anular, y la explicación de que para corregirlo hay que eliminar la venta

#### Scenario: El editor impide superar el stock de la sucursal
- **GIVEN** un producto con 2 unidades en la sucursal elegida y 10 en otra
- **WHEN** el usuario intenta cargar 3 unidades en el remito
- **THEN** el editor lo impide y muestra el disponible de la sucursal elegida, con la acción de transferir stock

#### Scenario: Línea nueva en la edición contra lo retenido
- **GIVEN** un remito que retiene 3 unidades de A en una sucursal que hoy tiene 0 de A
- **WHEN** en la edición se agrega otra línea de 2 unidades de A
- **THEN** el editor lo impide, porque el disponible de A es 3 y lo requerido 5

#### Scenario: Cuenta sin módulo de sucursales
- **GIVEN** una cuenta cuyo plan no tiene módulo de sucursales y una sola sucursal activa
- **WHEN** abre `/remitos/nuevo`
- **THEN** ve la sucursal de origen precargada y puede emitir el remito

#### Scenario: Badge en ventas
- **WHEN** el listado de ventas incluye una venta nacida de un remito
- **THEN** muestra "Desde remito R-…" con enlace al remito, y "Editar" deshabilitado con el motivo

### Requirement: Permisos sobre remitos de venta
El sistema SHALL aplicar estos permisos sobre remitos de venta:

| Acción | Roles |
|---|---|
| Ver, listar y descargar el PDF | Cualquier miembro de la cuenta |
| Emitir y editar | `seller`, `stock`, `admin`, `owner` |
| Anular | `admin`, `owner` |
| Convertir en venta | `seller`, `cashier`, `admin`, `owner` |

La verificación SHALL hacerse en la base (las operaciones y el catálogo de transiciones) y en el backend, con capacidades nombradas que un test ata al catálogo. El frontend SHALL ocultar las acciones no permitidas a partir del conjunto de roles del usuario. El remito NO SHALL tener gate de plan.

#### Scenario: El cajero convierte pero no emite
- **GIVEN** un usuario con único rol `cashier`
- **WHEN** intenta emitir un remito y después convertir uno pendiente
- **THEN** la emisión falla con `P0403` y la conversión se acepta

#### Scenario: Capacidades atadas al catálogo
- **WHEN** se compara la capacidad de emitir del backend con los roles de la transición `NULL → issued` de `delivery_note_sale` del catálogo
- **THEN** son el mismo conjunto, y el test falla si divergen
