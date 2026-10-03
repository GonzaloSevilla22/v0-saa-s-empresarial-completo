## MODIFIED Requirements

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

## ADDED Requirements

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
- **THEN** o la emisión falla con `P0422` y la sucursal queda dada de baja sin stock, o la baja falla con `P0428 branch_has_pending_delivery_notes` y el remito queda emitido en una sucursal activa

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
