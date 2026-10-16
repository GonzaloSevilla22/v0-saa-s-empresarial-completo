# delivery-note Specification

## Purpose
Remito interno ("X"), documento comercial **no fiscal** (sin ARCA ni CAI) que documenta mercadería que cambia de manos antes de que se registre la venta o la compra. El remito de venta es lo que entrega el comercio al cliente: **emitirlo descuenta stock** de su sucursal de origen con la misma normalización de unidad y el mismo control de faltante que la venta, y se lo puede editar (con par espejo en el ledger), anular con motivo (repone el stock; sólo administrador y dueño) o convertir en una venta con el botón "Venta". Lo que el remito **no** hace: no es una venta, así que no registra importe cobrado ni deuda, no toca caja, banco ni cuenta corriente y no emite ningún evento de venta (por lo tanto, tampoco asiento contable ni cuenta en los KPI de ventas); todo eso ocurre recién al convertirlo, y la conversión **no vuelve a mover stock** (el origen persistido de la orden decide, nunca un parámetro del cliente). La venta nacida de un remito es inmutable, su borrado compensa el dinero sin tocar el stock y devuelve el remito a pendiente. La tabla aloja los dos sentidos (`direction`). El **remito de compra** (`RC-00000001`) es el espejo: es lo que recibe el comercio de su proveedor, **emitirlo suma stock** en la sucursal de destino, se lo puede editar (con control de faltante sobre el neto si se baja una cantidad ya consumida), anular (bloqueado si la mercadería ya se consumió) o convertir en una compra con el botón "Compra", que **no vuelve a sumar stock**, postea el cargo en la cuenta corriente del proveedor si se paga a crédito y es inmutable; borrar esa compra compensa el dinero sin tocar el stock y reabre el remito. Define el modelo (`delivery_notes` + `delivery_note_items`, numeración `R-00000001` / `RC-00000001` por cuenta y sentido, máquinas de estados `delivery_note_sale` y `delivery_note_purchase`: `issued` → `converted` | `canceled` con vuelta a `issued`), las reglas de escritura sólo por RPCs con guard de tenencia y rol por sentido, el PDF sin precios por defecto y su envío por descarga y WhatsApp, las pantallas de `/remitos` (una pestaña por sentido) y los permisos por rol.

## Requirements

### Requirement: Remito de venta interno con cliente, sucursal y líneas con producto
El sistema SHALL modelar el remito como documento interno ("X"), no fiscal, en `delivery_notes` + `delivery_note_items`, con un sentido (`direction`) que admite `'sale'` y `'purchase'`. El sentido `'sale'` es el remito de venta (descuenta stock) y el sentido `'purchase'` es el remito de compra (suma stock), con sus requirements propios en esta capability.

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

1. tomar con bloqueo los productos involucrados, en orden ascendente de id, **antes** de validarlos, de modo que la validación (producto vivo, de la cuenta, no padre) se haga sobre filas ya bloqueadas y una baja concurrente del producto no pueda colarse entre el chequeo y el descuento;
2. normalizar la cantidad de cada línea a la unidad base efectiva del producto con la definición única de normalización (después del bloqueo) y guardarla en la línea, en el mismo alta de la línea, como la cantidad base que la línea retiene;
3. agrupar por producto y sucursal;
4. exigir que el stock de la sucursal cubra lo requerido.

Si el stock no cubre lo requerido, SHALL fallar con `P0409` y el mismo literal de stock insuficiente que la venta, sin dejar ningún efecto: ni remito, ni número consumido, ni stock, ni movimiento.

Por cada par producto-sucursal SHALL registrar en el ledger un movimiento con `type = 'sale'`, `reference_type = 'delivery_note'`, `reference_id` = id del remito, el delta negativo normalizado, las cantidades antes y después, la sucursal, el nombre del producto, el usuario y el costo unitario congelado de la línea.

La emisión SHALL ser idempotente: exige una clave de idempotencia (header `Idempotency-Key` en la API) y, ante la misma clave del mismo usuario, SHALL devolver el remito original marcado como repetido, sin crear otro remito ni volver a descontar stock. Dos envíos concurrentes con la misma clave SHALL resolverse igual (el segundo recibe el remito del primero marcado como repetido), nunca con un error interno.

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

#### Scenario: Baja concurrente del producto
- **WHEN** se emite un remito de un producto mientras otro usuario lo da de baja
- **THEN** o la emisión se rechaza con `P0404 product_not_found` sin efectos, o el remito se emite con el producto vivo al momento del bloqueo; nunca se emite un remito con un producto que ya estaba dado de baja al validarlo

#### Scenario: Crear un remito no toca caja, banco ni cuenta corriente
- **WHEN** se emite un remito
- **THEN** no se escribe ningún movimiento de caja, de banco ni de cuenta corriente, ni ningún evento de venta

### Requirement: Edición del remito mientras no esté convertido, con par espejo en el ledger
El sistema SHALL permitir editar un remito `issued` (líneas, cantidades, precios, cliente, sucursal, domicilio y notas) como un reemplazo completo y atómico, tomando el remito con bloqueo y exigiendo la versión que el usuario vio.

Si la versión no coincide, SHALL fallar con `P0409 delivery_note_changed` sin cambiar nada. Si la sucursal vigente del remito está desactivada o cerrada, SHALL fallar con `P0422 delivery_note_branch_inactive` sin cambiar nada. Un remito `converted` SHALL rechazar la edición con `P0423 delivery_note_locked_converted`, y uno `canceled` con `P0409 delivery_note_invalid_state`.

Para cada par producto-sucursal SHALL calcular lo que el remito retiene hoy (a partir de sus líneas vigentes, antes de reemplazarlas) y lo que requieren las líneas nuevas, normalizado y con los productos ya bloqueados. Lo retenido SHALL ser la suma de las cantidades base guardadas en las líneas vigentes del remito para ese producto, en la sucursal vigente del remito (cero en cualquier otra), y NO SHALL calcularse sumando movimientos del ledger, que los roles de aplicación pueden insertar. Si los dos valores difieren, SHALL registrar:
- una pata de reversa: `type = 'sale_return'`, `reference_type = 'delivery_note_update'`, con lo retenido;
- después, una pata de aplicación: `type = 'sale'`, `reference_type = 'delivery_note'`, con lo requerido.

El control de faltante SHALL evaluarse sobre el stock con la reversa ya aplicada. Los pares sin cambio SHALL NOT escribir movimientos ni volver a descontar stock, aunque otro producto del mismo remito sí cambie. Editar SHALL incrementar la versión, NO SHALL cambiar el estado y NO SHALL registrar historial de estados.

Los snapshots SHALL seguir la política canónica de operaciones: la línea cuyo producto ya estaba en el remito conserva nombre, SKU, costo y alícuota de IVA de la línea vieja; un producto nuevo los toma del maestro vigente de la cuenta.

Un producto que ya estaba en el remito y fue dado de baja después de emitirlo SHALL aceptarse en la edición sin revalidar el catálogo vivo, conservando su snapshot, siempre que su cantidad base requerida total no supere la que el remito ya retiene de él en total, sumando todas sus sucursales: conservarla o reducirla SHALL funcionar, cambiar la sucursal del remito conservando la cantidad SHALL funcionar y trasladar su stock, y aumentarla SHALL rechazarse con `P0400 delivery_note_product_unavailable`. Un producto dado de baja que no estaba en el remito SHALL rechazarse como en el alta.

#### Scenario: Cambiar sólo un precio no mueve el ledger
- **GIVEN** un remito `issued` con 2 unidades de A
- **WHEN** se edita sólo el precio de la línea
- **THEN** el total cambia, la versión aumenta en 1 y no se escribe ningún movimiento de stock

#### Scenario: Aumentar la cantidad deja el par espejo
- **GIVEN** un remito con 2 unidades de A y stock de A en `5`
- **WHEN** se edita a 4 unidades
- **THEN** el ledger suma `sale_return` / `delivery_note_update` de `+2` y `sale` / `delivery_note` de `-4`, y el stock de A queda en `3`

#### Scenario: Un producto sin cambios no recibe movimientos
- **GIVEN** un remito con 2 unidades de A y 1 de B, con stock suficiente de B
- **WHEN** se edita B a 3 unidades sin tocar A
- **THEN** el ledger suma un solo par espejo, sobre B, ningún movimiento sobre A, y el stock de A no cambia

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

#### Scenario: Cambiar la sucursal de un remito con un producto dado de baja
- **GIVEN** un remito `issued` desde la sucursal X con 2 unidades de A, A dado de baja después de emitirlo, y stock de A en la sucursal Y
- **WHEN** se edita la sucursal a Y sin cambiar la cantidad de A
- **THEN** la edición se acepta, X recibe una pata de reversa de `+2` y Y una de aplicación de `-2`

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
- un rol sin permiso: `P0403 insufficient_role`;
- un remito cuya sucursal está desactivada o cerrada: `P0422 delivery_note_branch_inactive`, sin reponer stock.

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

#### Scenario: Una fila forjada en el ledger es rechazada y no devuelve stock
- **GIVEN** un remito `issued` que retiene 3 unidades de A
- **WHEN** un miembro de la cuenta intenta insertar por PostgREST un movimiento de `-1000` con la referencia de ese remito
- **THEN** la inserción falla con `42501` *permission denied* (capa de privilegio) y no queda ninguna fila
- **AND** al anular el remito un administrador, el stock de A en su sucursal aumenta exactamente en 3, no en 1003

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

- **Borrarla**: SHALL compensar dinero y orden como cualquier venta, NO SHALL tocar el stock y SHALL devolver el remito a `issued`, registrando la transición `converted → issued` con el motivo del borrado en la misma transacción. El remito SHALL poder volver a convertirse después. Si la sucursal del remito fue desactivada o cerrada después de la conversión, el borrado SHALL rechazarse con `P0422 delivery_note_branch_inactive` antes de cualquier efecto, para no reabrir un remito en una sucursal que no opera.
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

#### Scenario: Borrar la venta con la sucursal del remito desactivada
- **GIVEN** una venta a crédito nacida de un remito, y la sucursal del remito vaciada y desactivada después de la conversión
- **WHEN** se intenta borrar la venta
- **THEN** la operación falla con `P0422 delivery_note_branch_inactive`, la cuenta corriente no cambia, la orden sigue `confirmed` y el remito sigue `converted`

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
- **`/remitos`**: listado paginado con filtros por estado y búsqueda por cliente o número, más un resumen de los pendientes (cantidad y total). La página SHALL leer de la URL un único contrato de filtros (estado, sucursal y cliente), que usan todos los enlaces que llegan filtrados.
- **`/remitos/nuevo`**: alta con el editor de líneas compartido, mostrando y haciendo cumplir el stock de la sucursal elegida (nunca el stock agregado de todas las sucursales). La sucursal SHALL ser obligatoria y visible en todos los planes, sin opción "sin sucursal", y SHALL avisar que emitir descuenta stock de esa sucursal.
- **`/remitos/[id]`**: detalle con las acciones según estado y rol. El diálogo "Venta" SHALL avisar que el stock ya se descontó al emitir el remito y que la venta no lo vuelve a descontar.
- **`/remitos/[id]/editar`**: edición. Todas las líneas cuentan contra un mismo disponible: el stock de la sucursal elegida más lo que el remito ya retiene en ella (cero si se cambia de sucursal). Antes de guardar SHALL mostrar qué stock vuelve y qué stock sale. Una línea de un producto dado de baja SHALL conservarse sin bloquear el guardado. Si el cliente del remito fue dado de baja, el formulario SHALL mostrarlo congelado con un aviso y exigir elegir un cliente vigente para guardar, y el detalle SHALL deshabilitar "Venta" con ese motivo.
- **Estados de página**: sin permiso, cargando, error o no encontrado, y no editable (convertido o anulado, con su explicación).
- **Ficha del cliente**: acción "Nuevo remito" con el cliente preseleccionado.
- **`/ventas`**: badge "Desde remito R-…" con enlace.
- **Panel de movimientos de stock**: rotula los movimientos del remito como "Remito", "Edición de remito" o "Anulación de remito", con su número formateado según el sentido del remito. La exportación CSV del panel SHALL usar el mismo rótulo que la fila.

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

#### Scenario: Enlace a los remitos pendientes de una sucursal
- **WHEN** el usuario sigue "Ver remitos pendientes" desde el diálogo de baja de una sucursal
- **THEN** `/remitos` abre en la pestaña Pendientes, filtrado por esa sucursal, con el filtro visible y removible

#### Scenario: Exportación del kardex
- **GIVEN** el panel de movimientos de un producto con un movimiento de emisión de remito
- **WHEN** el usuario exporta el CSV
- **THEN** la columna de tipo de esa fila dice "Remito" con su número, no "Venta"

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

### Requirement: Remito de compra interno con proveedor, sucursal de destino y líneas con producto
El sistema SHALL modelar el remito de compra como un remito interno ("X"), no fiscal, en las mismas tablas que el remito de venta, con `direction = 'purchase'`, sin tablas nuevas.

Un remito de compra SHALL tener:
- un proveedor vivo de su cuenta;
- una sucursal de destino (a la que entra la mercadería) de su cuenta, activa y no cerrada;
- al menos una línea;
- opcionalmente, el número del remito del proveedor (texto de hasta 100 caracteres) y notas (hasta 2.000);
- ningún cliente ni domicilio de entrega.

Cada línea SHALL tener un producto vivo de la cuenta que no sea padre con variantes ni `variant_only`, una cantidad mayor que cero y un precio de compra por unidad de la línea no negativo. El precio SHALL poder ser cero al emitir, porque la factura del proveedor puede llegar después. El subtotal de cada línea SHALL calcularlo el servidor como el precio por la cantidad, redondeado a 2 decimales, y el total del remito SHALL ser el redondeo a 2 decimales de la suma de precio por cantidad, ignorando cualquier subtotal o total que envíe el cliente; por eso los subtotales pueden diferir del total en un centavo, y toda pantalla y el PDF SHALL mostrar el total del servidor sin recalcularlo sumando subtotales. El costo congelado de cada línea SHALL ser el costo de catálogo del producto, igual que en una compra directa. La fecha del remito SHALL ser el día argentino de la emisión y no se edita.

Una línea sin producto SHALL rechazarse con `P0400 delivery_note_product_required`, y un remito sin proveedor con `P0400 delivery_note_supplier_required`.

#### Scenario: Recepción válida con un precio pendiente
- **GIVEN** un proveedor vivo, una sucursal activa de la cuenta y dos productos
- **WHEN** un usuario con rol `stock` emite un remito de compra con dos líneas, una de ellas con precio `0`, y el número de remito del proveedor `0001-00004567`
- **THEN** existe un remito de compra `issued` con fecha de hoy (ART), las dos líneas, el número del proveedor y el total calculado por el servidor

#### Scenario: Subtotal del cliente ignorado
- **WHEN** se emite un remito de compra con una línea de 3 unidades a $100 y subtotal `1`
- **THEN** la línea guarda subtotal `300` y el remito total `300`

#### Scenario: Subtotales redondeados y total de la compra
- **WHEN** se emite un remito de compra con dos líneas de `0.333` Kilogramo a $999
- **THEN** cada línea guarda subtotal `332.67` y el remito total `665.33`, el mismo total que tendrá la compra convertida

#### Scenario: Proveedor o sucursal inválidos
- **WHEN** se emite un remito de compra sin proveedor, con un proveedor de otra cuenta, con un proveedor dado de baja, sin sucursal, con una sucursal de otra cuenta o con una sucursal cerrada
- **THEN** la operación falla con `P0400 delivery_note_supplier_required`, `P0404 supplier_not_found`, `P0400 delivery_note_branch_required`, `P0404` o `P0422 branch_closed`, según el caso, sin escribir nada

### Requirement: Emitir el remito de compra suma stock en la sucursal de destino
El sistema SHALL sumar al stock de la sucursal de destino, en la misma transacción en que emite un remito de compra, la cantidad de cada línea normalizada a la unidad base efectiva del producto con la definición única de normalización, calculada después de bloquear los productos en orden ascendente de id y guardada en la línea como la cantidad base que el remito aporta.

Por cada par producto-sucursal SHALL registrar en el ledger un movimiento con `type = 'purchase'`, `reference_type = 'delivery_note'`, `reference_id` = id del remito, el delta positivo normalizado, las cantidades antes y después, la sucursal, el nombre del producto, el usuario y el costo congelado de la línea.

Antes de sumar stock, la emisión SHALL bloquear en modo compartido la sucursal de destino, y la edición que mueve el remito a otra sucursal SHALL hacer lo mismo con la nueva, de modo que una baja concurrente de la sucursal y la recepción se serialicen: o la recepción rechaza con `P0422`, o la baja rechaza porque la sucursal tiene un remito pendiente; nunca queda stock ni un remito pendiente en una sucursal desactivada.

La emisión SHALL ser idempotente: exige una clave de idempotencia y, ante la misma clave del mismo usuario, SHALL devolver el remito original marcado como repetido, sin crear otro remito ni volver a sumar stock. La emisión SHALL NOT tocar caja, banco ni cuenta corriente, ni emitir eventos de compra, y SHALL NOT actualizar el costo del producto.

#### Scenario: Recepción en gramos de un producto en kilogramos
- **GIVEN** un producto con unidad base Kilogramo y stock `1` en la sucursal
- **WHEN** se emite un remito de compra con una línea de `450` Gramo
- **THEN** el stock queda en `1.45` y existe un movimiento `purchase` / `delivery_note` con `quantity_delta = 0.45` que apunta al remito

#### Scenario: Doble envío de la emisión
- **GIVEN** un producto con stock `5`
- **WHEN** el mismo usuario envía dos veces la emisión de un remito de compra de `2` unidades con la misma clave de idempotencia
- **THEN** existe un solo remito, el stock queda en `7` y la segunda respuesta devuelve el mismo remito marcado como repetido

#### Scenario: Recepción contra la baja de una sucursal vacía
- **GIVEN** una sucursal activa sin existencias ni remitos pendientes
- **WHEN** un usuario emite un remito de compra a esa sucursal mientras otro la da de baja
- **THEN** o la emisión falla con `P0422` y la sucursal queda dada de baja sin stock, o la baja falla con `P0428 branch_has_stock` (la recepción ya sumó stock; el remito pendiente también la bloquearía con `branch_has_pending_delivery_notes`) y el remito queda emitido en una sucursal activa

#### Scenario: Recibir no mueve dinero ni el costo
- **WHEN** se emite un remito de compra con precio $500 para un producto de costo de catálogo $300
- **THEN** no existe ningún movimiento de caja, de banco ni de cuenta corriente, ningún evento `PurchaseCreated`, y el costo del producto sigue en $300

### Requirement: Edición del remito de compra con control de faltante sobre el neto
El sistema SHALL permitir editar un remito de compra `issued` (líneas, cantidades, precios, proveedor, número del proveedor, sucursal de destino y notas) como un reemplazo completo y atómico, con el remito bloqueado y la versión que el usuario vio, usando la misma definición de pares que cambian que el remito de venta.

Para cada par producto-sucursal que cambia, SHALL registrar una pata de aplicación (`type = 'purchase'`, `reference_type = 'delivery_note'`, con lo nuevo) y una pata de reversa (`type = 'purchase_return'`, `reference_type = 'delivery_note_update'`, con lo que el remito aportaba), aplicando primero las patas que suman stock y después las que restan, de modo que el control de faltante se evalúe sobre el neto. Lo que el remito aporta SHALL calcularse desde las cantidades base de sus líneas vigentes, nunca sumando el ledger.

La edición SHALL fijar la sucursal nueva del remito antes de calcular lo que aportan las líneas nuevas, de modo que un cambio de sucursal mueva el stock aunque las cantidades no cambien. Antes de escribir cualquier pata, SHALL verificar el neto de cada par producto-sucursal: si el neto resta más de lo que la sucursal tiene, la edición SHALL fallar con `P0409 delivery_note_stock_consumed`, nombrando el producto, el stock de la sucursal antes de la edición y lo que el usuario resta (el neto), sin cambiar nada. Los pares sin cambio SHALL NOT escribir movimientos. Un remito `converted` SHALL rechazar la edición con `P0423 delivery_note_locked_converted`, uno `canceled` con `P0409 delivery_note_invalid_state`, una versión vieja con `P0409 delivery_note_changed` y una sucursal vigente desactivada o cerrada con `P0422 delivery_note_branch_inactive`.

#### Scenario: Bajar una cantidad ya vendida en parte
- **GIVEN** un remito de compra que aportó 10 unidades de A a la sucursal X, de las que se vendieron 7 (stock de A en X: `3`)
- **WHEN** se edita la línea a 8 unidades
- **THEN** la edición se acepta, el ledger suma `purchase` de `+8` y `purchase_return` de `-10`, y el stock de A en X queda en `1`

#### Scenario: Bajar por debajo de lo que ya salió
- **GIVEN** el mismo remito, con stock de A en X en `3`
- **WHEN** se edita la línea a 5 unidades
- **THEN** la operación falla con `P0409 delivery_note_stock_consumed`, el mensaje dice que en la sucursal quedan 3 y el remito necesita restar 5 (sin atribuir la diferencia a ventas ni transferencias), el stock sigue en `3` y el remito conserva sus 10 unidades

#### Scenario: Cargar los precios no mueve el ledger
- **GIVEN** un remito de compra `issued` con una línea de precio `0`
- **WHEN** se edita sólo el precio de la línea a $450
- **THEN** el total cambia, la versión aumenta en 1 y no se escribe ningún movimiento de stock

#### Scenario: Cambiar la sucursal de destino
- **GIVEN** un remito de compra que aportó 4 unidades de A a la sucursal X, con stock de A en X en `4`
- **WHEN** se edita la sucursal a Y
- **THEN** Y recibe una pata de aplicación de `+4`, X una de reversa de `-4`, el stock queda en `0` en X y en `+4` en Y, y el remito queda con la sucursal Y

#### Scenario: Cambiar la sucursal sin toda la mercadería en la vieja
- **GIVEN** un remito de compra que aportó 4 unidades de A a la sucursal X, con stock de A en X en `1`
- **WHEN** se edita la sucursal a Y
- **THEN** la operación falla con `P0409 delivery_note_stock_consumed`, nada se mueve y el remito sigue en X

### Requirement: Anulación del remito de compra bloqueada si la mercadería se consumió
El sistema SHALL permitir anular un remito de compra `issued` sólo a administradores y dueños, con un motivo no vacío y la versión vigente, usando la misma operación de anulación que el remito de venta.

La anulación SHALL bloquear los productos del remito antes de leer el stock y SHALL restar, por cada par producto-sucursal, todo lo que el remito aportó (desde las cantidades base de sus líneas vigentes), con un movimiento `type = 'purchase_return'`, `reference_type = 'delivery_note_reversal'`, y registrar la transición `issued → canceled` con el motivo y el actor, en la misma transacción.

Si algún par no tiene en la sucursal la cantidad a restar, la anulación SHALL fallar con `P0409 delivery_note_stock_consumed` sin efectos: ningún par queda restado, el remito sigue `issued` y el stock no queda negativo. Las demás anulaciones rechazadas SHALL responder como en el remito de venta: `converted` → `P0423 delivery_note_locked_converted`; `canceled` → `P0409 delivery_note_invalid_state`; sin motivo → `P0400 delivery_note_cancel_reason_required`; rol sin permiso → `P0403 insufficient_role`; sucursal desactivada o cerrada → `P0422 delivery_note_branch_inactive`.

#### Scenario: Anular con la mercadería en el depósito
- **GIVEN** un remito de compra `issued` que aportó 3 unidades de A a la sucursal X, con stock de A en X en `5`
- **WHEN** un administrador lo anula con el motivo "el proveedor se llevó la mercadería"
- **THEN** el stock de A en X queda en `2`, existe un movimiento `purchase_return` / `delivery_note_reversal` de `-3`, el remito queda `canceled` y el historial registra el motivo

#### Scenario: Anular con parte vendida
- **GIVEN** un remito de compra que aportó 10 unidades de A, con stock de A en su sucursal en `4`
- **WHEN** un administrador intenta anularlo
- **THEN** la operación falla con `P0409 delivery_note_stock_consumed`, el stock sigue en `4` y el remito sigue `issued`

#### Scenario: El rol de depósito no anula
- **WHEN** un usuario con rol `stock` intenta anular un remito de compra
- **THEN** la operación falla con `P0403 insufficient_role` y el remito sigue `issued`

#### Scenario: El ledger del remito de compra anulado cierra en cero
- **GIVEN** un remito de compra emitido, editado y anulado
- **WHEN** se suman las `quantity_delta` de sus movimientos por par producto-sucursal
- **THEN** cada suma es `0` e iguala al cambio neto del stock de ese par

### Requirement: Conversión atómica del remito de compra en compra sin volver a sumar stock
El sistema SHALL convertir un remito de compra `issued` en una compra en una sola transacción, con estos pasos:

1. bloquear el remito antes que cualquier otra cosa;
2. leer la idempotencia bajo ese bloqueo;
3. exigir estado `issued`, la versión vista, una forma de pago del catálogo, un proveedor vivo, que la sucursal del remito esté activa y no cerrada, que todas las líneas tengan precio mayor que cero y que la fecha de la compra no sea anterior a la del remito;
4. crear la compra con el núcleo de compra, en la sucursal y con el proveedor del remito, con todas sus líneas leídas del propio remito (producto, unidad, cantidad, precio y snapshots, sin releer el maestro), con el origen persistido en cada fila;
5. pasar el remito a `converted`, con historial, dentro del núcleo de compra y en la misma transacción que crea la compra, de modo que no exista una compra con origen sin su remito convertido.

La compra SHALL manejar caja (con las tres condiciones), banco, cuenta corriente del proveedor (con vencimiento por la cascada desde la fecha de la compra), evento y asiento como cualquier compra, y SHALL NOT sumar stock. La decisión de no sumar stock SHALL tomarla el servidor desde el remito validado bajo bloqueo; ninguna operación pública SHALL aceptar un parámetro que la pida. El total de la compra SHALL ser igual al total del remito. Un producto dado de baja después de recibir SHALL NOT impedir la conversión.

Las conversiones rechazadas responden así, sin efectos: precio cero en alguna línea → `P0400 delivery_note_price_required`; proveedor dado de baja → `P0404 delivery_note_supplier_unavailable`; sucursal desactivada o cerrada → `P0422 branch_closed`; fecha anterior al remito → `P0400 delivery_note_purchase_date_before_receipt`; remito no pendiente → `P0409 delivery_note_invalid_state`; versión vieja → `P0409 delivery_note_changed`; clave usada para otra operación → `P0409 idempotency_key_conflict`.

#### Scenario: Conversión a crédito sin doble suma
- **GIVEN** un remito de compra `issued` que aportó 10 unidades de A, con todos sus precios cargados, de un proveedor con plazo de 30 días
- **WHEN** un usuario con rol `purchases` lo convierte con una forma de pago de cuenta corriente y fecha de hoy
- **THEN** existe una compra con las líneas del remito y su origen, el stock de A no cambia, no existe ningún movimiento de stock que apunte a las filas de la compra, la cuenta corriente del proveedor tiene un cargo por el total con vencimiento a 30 días, y el remito queda `converted`

#### Scenario: Conversión en efectivo con caja abierta
- **GIVEN** un remito de compra `issued` y una sesión de caja abierta en su sucursal
- **WHEN** se convierte con una forma de pago en efectivo, la sesión de caja y fecha de hoy
- **THEN** la caja registra el egreso de la compra y el stock no cambia

#### Scenario: Precio faltante
- **GIVEN** un remito de compra con una línea de precio `0`
- **WHEN** se intenta convertirlo
- **THEN** la operación falla con `P0400 delivery_note_price_required` y no se crea ninguna compra

#### Scenario: Dos conversiones concurrentes
- **WHEN** dos usuarios convierten el mismo remito de compra al mismo tiempo, con claves distintas
- **THEN** existe una sola compra con ese origen y el segundo recibe `P0409 delivery_note_invalid_state`

#### Scenario: Núcleo con un origen inválido
- **WHEN** el núcleo de compra recibe como origen un remito de otra cuenta, de venta, anulado, ya convertido, de otro proveedor, de otra sucursal, con líneas enviadas en el request o con una compra ya existente
- **THEN** rechaza con `P0409 delivery_note_purchase_mismatch` o `P0400`, sin crear la compra, sin mover stock ni dinero y sin emitir eventos

### Requirement: Vida posterior de la compra nacida de un remito
El sistema SHALL tratar la compra nacida de un remito de compra así:
- su edición SHALL rechazarse con `P0423 delivery_note_purchase_locked` antes de cualquier escritura, porque volvería a mover stock;
- su borrado SHALL compensar el dinero como el de cualquier compra, SHALL NOT tocar el stock y SHALL devolver el remito a `issued`, con la transición `converted → issued` registrada con el motivo y el usuario que borró;
- su borrado SHALL bloquear el remito de origen, leído con la cuenta del usuario y el sentido compra, antes de cualquier compensación; bajo ese bloqueo SHALL volver a leer las filas de la compra (si ya no existen, termina sin efectos) y exigir que el remito siga `converted`, de modo que dos borrados de la misma compra, o un borrado que esperó contra una reconversión, nunca reabran el remito dos veces ni lo reabran con otra compra viva;
- su borrado SHALL exigir el rol de anular remitos de compra (administrador o dueño, `P0403 delivery_note_purchase_delete_forbidden`) y que la sucursal del remito esté activa y no cerrada (`P0422 delivery_note_branch_inactive`), antes de cualquier efecto;
- un origen que apunta a un remito de otra cuenta o de venta SHALL NOT reabrirse: el borrado rechaza con `P0409 delivery_note_purchase_mismatch`;
- el remito convertido SHALL NOT poder anularse ni editarse (`P0423 delivery_note_locked_converted`) mientras la compra exista.

Un remito que vuelve a `issued` SHALL poder convertirse de nuevo.

#### Scenario: Borrar la compra devuelve el remito a pendiente
- **GIVEN** una compra a crédito nacida de un remito de compra que aportó 10 unidades de A
- **WHEN** un administrador borra la compra
- **THEN** el cargo en la cuenta corriente del proveedor se compensa, el stock de A no cambia, el remito vuelve a `issued` con historial `converted → issued` y se puede volver a convertir

#### Scenario: El rol de compras no reabre el remito
- **WHEN** un usuario con rol `purchases` intenta borrar una compra nacida de un remito
- **THEN** la operación falla con `P0403 delivery_note_purchase_delete_forbidden` y no se compensa nada

#### Scenario: Dos borrados concurrentes de la misma compra
- **GIVEN** una compra nacida de un remito de compra
- **WHEN** dos administradores la borran al mismo tiempo
- **THEN** el dinero se compensa una sola vez, el historial registra una sola transición `converted → issued` y el segundo borrado termina sin efectos

#### Scenario: Borrado viejo contra reconversión
- **GIVEN** un borrado de la compra de un remito que quedó esperando detrás de otro borrado de la misma compra, y una reconversión del remito que se confirma en el medio
- **WHEN** el borrado que esperaba continúa
- **THEN** termina sin efectos y el remito sigue `converted`, con la compra de la reconversión viva

### Requirement: PDF del remito de compra
El sistema SHALL generar el PDF del remito de compra con el mismo constructor y el mismo endpoint por id con tenencia que el remito de venta, con el título "REMITO DE COMPRA", el número `RC-…`, el bloque "Recibido de" con el proveedor y el número de su remito si existe, la sucursal a la que ingresa la mercadería, las cantidades con su unidad, el bloque de firma de quien recibe y la leyenda "Remito — documento no válido como factura". Los precios y el total SHALL aparecer sólo si se pide mostrarlos, y un remito anulado SHALL llevar el sello "ANULADO".

#### Scenario: PDF por defecto sin precios
- **WHEN** un miembro de la cuenta descarga el PDF de un remito de compra sin pedir precios
- **THEN** el PDF dice "REMITO DE COMPRA", muestra el número `RC-…`, el proveedor, el número de su remito, la sucursal de destino, las cantidades y el bloque de firma, y no muestra precios ni total

#### Scenario: Remito de compra de otra cuenta
- **WHEN** un usuario pide el PDF de un remito de compra de otra cuenta
- **THEN** recibe 404 con el mismo cuerpo que para un remito inexistente

### Requirement: Envío del remito de compra al proveedor
El sistema SHALL ofrecer en el detalle del remito de compra el menú compartido para ver, descargar y enviar el PDF por WhatsApp, con el teléfono del proveedor como destinatario si lo tiene, o el selector de contactos de WhatsApp si no lo tiene, y un texto que nombra el número del remito interno y, si existe, el número del remito del proveedor. El archivo que se descarga o se comparte desde la pantalla SHALL llamarse `remito-compra-RC-<número>.pdf` (con `-con-precios` si los muestra), igual que el del endpoint. Si el proveedor no tiene teléfono, el detalle SHALL avisarlo junto al menú, con un enlace para cargarlo. Enviar SHALL NOT cambiar el estado del remito.

#### Scenario: Proveedor sin teléfono
- **GIVEN** un remito de compra de un proveedor sin teléfono
- **WHEN** el usuario elige enviarlo por WhatsApp en escritorio
- **THEN** se descarga el PDF `remito-compra-RC-…pdf` y se abre WhatsApp sin destinatario, con el texto del remito, y el detalle sugiere cargar el teléfono del proveedor

### Requirement: Pantallas del remito de compra
El sistema SHALL exponer el remito de compra en `/remitos` con una pestaña "De compra" junto a "De venta" (`?sentido=venta|compra`, por defecto venta), con filtros de estado, búsqueda por proveedor, número `RC-…` o número del proveedor, y el resumen de remitos de compra pendientes. SHALL ofrecer el alta en `/remitos/nuevo?tipo=compra` (con `?proveedor=` opcional), la edición en `/remitos/[id]/editar` y el detalle en `/remitos/[id]`, con el formulario del remito parametrizado por sentido: proveedor obligatorio con alta en el lugar (con teléfono opcional), número del remito del proveedor, sucursal de destino obligatoria y visible en todos los planes, precio de compra precargado desde el **costo** de catálogo del producto (nunca desde su precio de venta) que puede quedar vacío con aviso, y avisos de cuándo y cuánto stock entra o sale. En la edición, el mínimo de cada línea SHALL calcularse sobre el neto (lo aportado menos el stock vigente de la sucursal, nunca menos de cero) con un texto que no atribuya el origen del stock. Todos los textos que dependen del sentido (estado convertido, sucursal, avisos de stock, validación de contraparte, anulación, baja de sucursal, nombre del archivo) SHALL salir de una única definición por sentido. El listado SHALL marcar con "Sin precio" los remitos pendientes con alguna línea en precio cero y contarlos en el resumen. El detalle SHALL mostrar las acciones Compartir, Editar, Compra y Anular según el estado y el rol, deshabilitando "Compra" con su motivo si falta un precio o el proveedor fue dado de baja, y volver a la pestaña de compra del listado. Las pantallas SHALL verificarse en escritorio y en móvil, con tema claro y oscuro.

#### Scenario: Entrar a la pestaña de compra
- **WHEN** el usuario abre `/remitos?sentido=compra&estado=pendientes`
- **THEN** ve sólo los remitos de compra pendientes, con proveedor, número del proveedor, sucursal de destino y total

#### Scenario: Alta inline del proveedor
- **WHEN** en el alta de un remito de compra el usuario crea un proveedor desde el selector
- **THEN** el proveedor queda creado y seleccionado sin perder las líneas cargadas

#### Scenario: Compra deshabilitada sin precios
- **GIVEN** un remito de compra pendiente con una línea sin precio
- **WHEN** un usuario con rol `purchases` abre el detalle
- **THEN** la acción "Compra" está deshabilitada con el motivo "Cargá el precio de compra de todas las líneas"

#### Scenario: La línea de compra precarga el costo
- **GIVEN** un producto con precio de venta $1.000 y costo de catálogo $600
- **WHEN** el usuario lo agrega a un remito de compra, a mano o escaneando
- **THEN** la línea propone $600 como precio de compra

#### Scenario: Remito de compra convertido en el listado
- **WHEN** el usuario ve en la pestaña De compra un remito convertido
- **THEN** su estado dice "Convertido en compra"

### Requirement: Permisos sobre remitos de compra
El sistema SHALL permitir emitir y editar remitos de compra a los roles `stock`, `admin` y `owner`; anularlos a `admin` y `owner`; y convertirlos en compra a `purchases`, `stock`, `admin` y `owner` (quien recibe la mercadería puede cerrar el ciclo sin recurrir a una compra directa, que volvería a sumar el stock). Los permisos SHALL vivir en el catálogo de transiciones del tipo `delivery_note_purchase` y las capacidades del backend y del frontend SHALL coincidir con él. Cualquier miembro de la cuenta SHALL poder leer los remitos de compra y descargar su PDF.

#### Scenario: El vendedor no recibe mercadería
- **WHEN** un usuario con rol `seller` intenta emitir un remito de compra
- **THEN** la operación falla con `P0403 insufficient_role`

#### Scenario: El vendedor no convierte en compra
- **WHEN** un usuario con rol `seller` intenta convertir un remito de compra
- **THEN** la operación falla con `P0403 insufficient_role` y el remito sigue `issued`

#### Scenario: El depósito convierte en compra
- **WHEN** un usuario con rol `stock` convierte un remito de compra con todos sus precios cargados
- **THEN** la compra se crea y el remito queda `converted`

