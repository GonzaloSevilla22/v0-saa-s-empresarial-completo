# quote

> Synced from change `v21-quote-salesorder` (C-29) — 2026-06-17
> Actualizado por el change `presupuestos-modulo` — 2026-10-02

## Purpose

Agregado `Quote` que representa un presupuesto/cotización. Permite generar una propuesta comercial sin comprometer stock ni caja, y convertirla en un `SalesOrder` cuando el cliente la acepta. Parte del hot path V2.1 junto a `sales-order`.
## Requirements
### Requirement: Agregado Quote con ciclo de vida
El sistema SHALL proveer un agregado `Quote` (tabla `quotes`) que representa un presupuesto/cotización con un estado de un conjunto cerrado: `draft`, `sent`, `accepted`, `expired`, `rejected`. La tabla SHALL tener:

- `id` y `account_id` (tenancy);
- `number` (número interno correlativo por cuenta, asignado según la capability `internal-document-numbering`, único por cuenta);
- `branch_id` (FK→`branches`, nullable) y `client_id` (FK→`clients`);
- `status` (CHECK sobre el enum) y `valid_until` (date);
- `total numeric(15,2)` y `notes` (texto opcional, hasta 2.000 caracteres);
- `sent_at` (primera vez que pasó a `sent`);
- `updated_at` y `updated_by` (última edición);
- `revision` (versión del contenido: empieza en 1 y cada edición la incrementa);
- `created_by` y `created_at`.

Las transiciones válidas SHALL ser exactamente las del catálogo `document_status_transitions` para `quote`: `draft → sent`, `draft | sent → accepted`, `draft | sent → rejected`, `draft | sent → expired` y `expired | rejected → draft`. Un Quote en `accepted` es terminal y MUST NOT volver a ningún otro estado; es el único estado terminal de `quote` en el catálogo, y `expired` y `rejected` NOT SHALL estar marcados como terminales. Un Quote en `expired` o `rejected` SHALL volver a `draft` sólo cuando se lo edita (reapertura), y ninguna otra operación SHALL reabrirlo. Editar un presupuesto en `draft` o `sent` NOT SHALL cambiar su estado. En la interfaz, `accepted` SHALL significar "convertido en venta".

#### Scenario: crear un presupuesto en draft
- **WHEN** un usuario con rol de vendedor, administrador o dueño crea un presupuesto con ítems para un cliente de su cuenta
- **THEN** se persiste una fila en `quotes` con `status = 'draft'`, su `account_id` igual a la cuenta del usuario y un `number` asignado

#### Scenario: transición a sent
- **WHEN** se envía un presupuesto en `draft`
- **THEN** su `status` pasa a `sent` y `sent_at` queda con el momento del envío

#### Scenario: rechazar una transición inválida
- **WHEN** se intenta aceptar un presupuesto ya en estado `rejected`
- **THEN** la operación falla con un error de estado inválido y el `status` no cambia

#### Scenario: un borrador puede aceptarse o rechazarse sin haberse enviado
- **WHEN** un presupuesto en `draft` se rechaza, o se convierte en venta
- **THEN** la transición se registra, porque `draft → rejected` y `draft → accepted` están en el catálogo

#### Scenario: editar no cambia el estado
- **GIVEN** un presupuesto en `sent`
- **WHEN** se editan sus líneas
- **THEN** su `status` sigue siendo `sent` y `updated_at` queda posterior a `sent_at`

#### Scenario: editar un presupuesto rechazado lo reabre
- **GIVEN** un presupuesto en `rejected`
- **WHEN** se lo edita con una fecha de validez igual o posterior a hoy (ART)
- **THEN** su `status` pasa a `draft` y el historial registra `rejected → draft` con el usuario que lo editó

### Requirement: Líneas de presupuesto en quote_items
El sistema SHALL almacenar las líneas del presupuesto en `quote_items` con los campos:

- `quote_id` (FK→`quotes`) y `account_id`;
- `product_id` (FK→`products`, nullable para líneas de servicio);
- `quantity numeric(15,4)` y `unit_id` (FK→`units_of_measure`, nullable);
- `price` (unitario, por unidad de la línea, sin redondear, RN-24-bis) y `subtotal`.

Una línea sin producto SHALL llevar una descripción, que se guarda en `name_snapshot`.

La creación y la edición de un presupuesto NO SHALL tener ningún efecto sobre `branch_stock`, sobre la caja, sobre las cuentas corrientes ni sobre los movimientos bancarios. La falta de stock NO SHALL impedir crear ni editar un presupuesto.

#### Scenario: el presupuesto no compromete stock
- **WHEN** se crea un presupuesto de 5 unidades de un producto con `branch_stock = 3`
- **THEN** el presupuesto se crea correctamente y `branch_stock` permanece en 3 (el presupuesto no valida ni descuenta stock)

#### Scenario: línea de servicio sin producto
- **WHEN** se agrega una línea con `product_id = NULL` y la descripción "Instalación"
- **THEN** la fila en `quote_items` se acepta con `product_id` nulo y `name_snapshot = 'Instalación'`

#### Scenario: línea de servicio sin descripción
- **WHEN** se agrega una línea con `product_id = NULL` y sin descripción
- **THEN** la operación falla con un error de payload inválido y no se persiste nada

#### Scenario: editar el presupuesto no toca stock ni caja
- **WHEN** se edita un presupuesto duplicando la cantidad de una línea
- **THEN** `branch_stock` y los movimientos de caja de la cuenta no cambian

### Requirement: Quote.accept() crea un SalesOrder con los mismos ítems
El sistema SHALL proveer la operación `accept()` (RPC `rpc_accept_quote`, `SECURITY DEFINER`, firma `(p_quote_id uuid)`) que, en una sola transacción atómica, bloquea el presupuesto (`FOR UPDATE`), lo transiciona a `accepted` y crea un `SalesOrder` en `draft` (con sus `sales_order_items`). Las líneas del `SalesOrder` SHALL ser copia de las de `quote_items` (producto, cantidad, unidad, precio, subtotal y snapshots) y SHALL preservar `client_id` y `total`; la sucursal de la orden se resuelve con la precedencia del párrafo siguiente, que en `accept()` (sin sucursal indicada) equivale a preservar la del presupuesto. El `SalesOrder` resultante SHALL referenciar el Quote de origen (`source_quote_id`). `accept()` NO SHALL descontar stock ni registrar caja: sólo materializa la orden.

La lógica de aceptación SHALL vivir en un único núcleo interno, sin permiso de ejecución para los roles de aplicación, que comparten `accept()` y la conversión a venta, de modo que las dos no puedan divergir. La sucursal de la orden SHALL ser, en este orden de precedencia, la indicada por la conversión, la del presupuesto o la sucursal por defecto de la cuenta. Ni la interfaz ni la API HTTP SHALL exponer `accept()` por sí sola: fuera de la base de datos, el único camino hacia `accepted` es la conversión a venta. `rpc_accept_quote` se conserva sin endpoint y sin permiso de ejecución para los roles de aplicación, de modo que tampoco sea invocable por la API de datos, por compatibilidad y como regresión del núcleo.

#### Scenario: accept no es invocable por la API de datos
- **WHEN** un usuario autenticado invoca `rpc_accept_quote` por la API de datos sobre un presupuesto de su cuenta
- **THEN** la invocación se rechaza por permisos, el presupuesto conserva su estado y no se crea ninguna orden

#### Scenario: accept genera la orden espejo
- **WHEN** se acepta un presupuesto con dos líneas
- **THEN** se crea un `SalesOrder` con dos `sales_order_items` idénticos en producto, cantidad y precio, y `source_quote_id` igual al id del presupuesto

#### Scenario: accept es atómico
- **WHEN** la creación del `SalesOrder` falla durante `accept()`
- **THEN** el Quote permanece en su estado previo (no queda en `accepted` sin orden asociada)

#### Scenario: accept respeta la tenencia
- **WHEN** un usuario intenta aceptar un presupuesto de otra cuenta
- **THEN** la operación es denegada (RLS / guard de cuenta) y no se crea ningún `SalesOrder`

#### Scenario: dos aceptaciones concurrentes producen una sola orden
- **WHEN** dos sesiones aceptan el mismo presupuesto al mismo tiempo
- **THEN** exactamente una crea el `SalesOrder` y la otra falla con un error de estado inválido

#### Scenario: accept conserva su contrato tras la extracción del núcleo
- **WHEN** se acepta un presupuesto por `rpc_accept_quote` después de este cambio
- **THEN** el resultado, la orden `draft` creada y el historial registrado son los mismos que antes del cambio

### Requirement: Expiración de presupuesto
El sistema SHALL vencer automáticamente los presupuestos abiertos (`draft` o `sent`) cuyo `valid_until` sea anterior al día de negocio argentino, mediante un barrido diario programado que registra la transición a `expired` como transición de sistema (con el actor de sistema, el uuid cero, porque el historial exige un actor, y con el motivo "vencimiento automático"), en la misma transacción que el cambio de estado.

El barrido SHALL:

- ser idempotente;
- no tocar presupuestos en estado terminal;
- no esperar a un presupuesto bloqueado por una conversión en curso.

Además, el sistema SHALL tratar como no aceptable, y la API SHALL informar como vencido (`is_expired`), cualquier presupuesto cuyo `valid_until` sea anterior al día de negocio argentino aunque su `status` materializado siga en `draft` o `sent` (cómputo defensivo al leer).

#### Scenario: el barrido vence un presupuesto
- **GIVEN** un presupuesto en `sent` con `valid_until` = ayer (ART)
- **WHEN** corre el barrido diario
- **THEN** su `status` pasa a `expired` y el historial registra la transición con el actor de sistema (uuid cero) y el motivo "vencimiento automático"

#### Scenario: el barrido es idempotente
- **WHEN** el barrido corre dos veces el mismo día
- **THEN** la segunda corrida no vence nada y no agrega historial

#### Scenario: el barrido no toca un presupuesto aceptado
- **GIVEN** un presupuesto en `accepted` con `valid_until` en el pasado
- **WHEN** corre el barrido
- **THEN** su estado sigue siendo `accepted`

#### Scenario: no se acepta un presupuesto vencido
- **WHEN** se intenta aceptar o convertir un presupuesto con `valid_until` anterior a hoy (ART)
- **THEN** la operación falla indicando que el presupuesto está vencido

#### Scenario: vencido antes de que corra el barrido
- **GIVEN** un presupuesto en `sent` con `valid_until` = ayer y el barrido todavía sin correr
- **WHEN** se lo lista o se lo consulta
- **THEN** la respuesta lo informa con `is_expired = true`

### Requirement: Snapshot congelado en las líneas de presupuesto

El sistema SHALL agregar a `quote_items`, de forma aditiva y NULLABLE, las columnas `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)` e `iva_rate_snapshot NUMERIC(5,2)`, más `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false`. La ruta de creación del presupuesto SHALL congelar el nombre, SKU, costo y alícuota de IVA del maestro en la misma transacción en que persiste la línea, de modo que un presupuesto aceptado días después honre los valores cotizados y no los remarcados. Al aceptar el presupuesto (`Quote.accept()` que crea la `SalesOrder`), los snapshots de las líneas SHALL propagarse a `sales_order_items` sin re-leer el maestro.

#### Scenario: El presupuesto congela el precio cotizado

- **GIVEN** un producto con precio y costo vigentes al cotizar
- **WHEN** se crea un presupuesto con ese producto
- **THEN** la fila `quote_items` queda con `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` congelados en la transacción de creación

#### Scenario: Aceptar el presupuesto propaga el snapshot a la orden

- **GIVEN** un presupuesto con líneas que congelaron `unit_cost_snapshot`
- **WHEN** el presupuesto se acepta y se crea la `SalesOrder`
- **THEN** las `sales_order_items` resultantes heredan los mismos valores snapshot del `quote_items`, sin re-leer `products`

#### Scenario: Remarcar el maestro tras cotizar no cambia el presupuesto

- **GIVEN** un presupuesto que congeló el precio y costo al momento de emitirse
- **WHEN** el maestro se remarca antes de aceptar el presupuesto
- **THEN** el presupuesto conserva los valores cotizados originales en sus columnas snapshot

### Requirement: El presupuesto registra sus transiciones de estado en el historial

El sistema SHALL registrar en `document_status_history` (con `document_type = 'quote'`), en la misma transacción que la operación de negocio, todas las transiciones de estado del presupuesto:

- la creación (`from_status = NULL`, `to_status = 'draft'`);
- el envío (`sent`);
- el rechazo (`rejected`, con el motivo si se informó);
- la aceptación (`accepted`, durante la aceptación o la conversión a venta);
- el vencimiento (`expired`, con el actor de sistema);
- la reapertura por edición (`expired | rejected → draft`, con el usuario que editó).

Ningún camino de escritura SHALL cambiar el estado de un presupuesto sin registrar su historial.

#### Scenario: Crear un presupuesto registra su estado inicial
- **WHEN** se crea un presupuesto en estado `draft`
- **THEN** el sistema inserta una fila de historial con `document_type = 'quote'`, `from_status = NULL`, `to_status = 'draft'` y `performed_by` = el usuario que lo creó

#### Scenario: Aceptar un presupuesto registra la transición
- **WHEN** la aceptación transiciona el presupuesto a `accepted`
- **THEN** el sistema inserta una fila de historial con `from_status` = estado previo (`draft` o `sent`) y `to_status = 'accepted'` en la misma transacción, y la aceptación no se confirma si el registro falla

#### Scenario: Enviar y rechazar registran historial
- **WHEN** un presupuesto pasa de `draft` a `sent` y luego a `rejected` con el motivo "eligió otro proveedor"
- **THEN** el historial contiene las dos transiciones, la segunda con ese motivo

#### Scenario: Reenviar un presupuesto ya enviado no duplica el historial
- **GIVEN** un presupuesto en `sent`
- **WHEN** se lo vuelve a marcar como enviado
- **THEN** la operación responde con éxito y no se inserta una fila de historial nueva

### Requirement: Número visible del presupuesto
El sistema SHALL identificar cada presupuesto ante el usuario y ante el cliente por un número interno correlativo por cuenta, asignado según la capability `internal-document-numbering` con el tipo `quote` y mostrado con el prefijo `P-` y 8 dígitos (`P-00000012`), único para todas las sucursales de la cuenta. El número SHALL aparecer en el listado, en el detalle, en el PDF, en el nombre del archivo, en el texto de WhatsApp y en la venta que se genere a partir del presupuesto.

#### Scenario: numeración correlativa por cuenta
- **GIVEN** una cuenta cuyo último presupuesto es el 7
- **WHEN** se crea un presupuesto nuevo
- **THEN** recibe el número 8 y se muestra como `P-00000008`

#### Scenario: cuentas independientes
- **WHEN** dos cuentas distintas crean su primer presupuesto
- **THEN** los dos reciben el número 1

#### Scenario: búsqueda por número
- **WHEN** en el listado se busca "P-8", "8" o "00000008"
- **THEN** aparece el presupuesto número 8 de la cuenta

### Requirement: Validez por defecto configurable por cuenta
El sistema SHALL guardar por cuenta una validez por defecto de los presupuestos en días (`accounts.default_quote_validity_days`, entero de 1 a 365, 15 por defecto), escribible sólo mediante una operación con guard de dueño o administrador. Un presupuesto creado sin fecha de validez SHALL nacer con `valid_until` = día de negocio argentino + la validez por defecto de su cuenta. El sistema NOT SHALL aceptar en el alta ni en la edición un `valid_until` anterior al día de negocio argentino. La validez por defecto SHALL poder configurarse desde la pestaña Cobranzas de `/configuracion`.

#### Scenario: validez por defecto al crear
- **GIVEN** una cuenta con validez por defecto de 15 días y hoy (ART) = 2026-10-01
- **WHEN** se crea un presupuesto sin fecha de validez
- **THEN** su `valid_until` es 2026-10-16

#### Scenario: validez fuera de rango
- **WHEN** un administrador intenta fijar la validez por defecto en 0 o en 400 días
- **THEN** la operación se rechaza con un error de payload inválido y el valor no cambia

#### Scenario: un vendedor no cambia la validez por defecto
- **WHEN** un usuario cuyo único rol es vendedor intenta cambiar la validez por defecto
- **THEN** la operación se rechaza por permisos insuficientes

#### Scenario: validez en el pasado
- **WHEN** se crea o edita un presupuesto con `valid_until` = ayer (ART)
- **THEN** la operación falla con un error de payload inválido

### Requirement: Escritura del presupuesto sólo por operaciones con guard de tenencia
El sistema SHALL permitir crear, editar, transicionar y borrar presupuestos únicamente a través de operaciones `SECURITY DEFINER` de la base de datos, y NOT SHALL permitir `INSERT`, `UPDATE` ni `DELETE` directos sobre `quotes` ni `quote_items` por la API de datos. Esas operaciones SHALL:

- exigir un cliente vivo de la cuenta del presupuesto;
- exigir que cada producto de línea exista, pertenezca a esa cuenta, esté vivo y no sea un padre con variantes;
- validar que la unidad de cada línea sea compatible con su producto (RN-24) y que sea del sistema o de la cuenta, también en una línea de servicio;
- validar que la sucursal indicada pertenezca a la cuenta y no esté cerrada;
- congelar los snapshots de línea leyendo el maestro **filtrado por la cuenta del presupuesto**;
- calcular el total en el servidor como la suma de los subtotales de línea, redondeada al centavo una sola vez.

Un cliente, producto o sucursal de otra cuenta SHALL rechazarse con el mismo error que uno inexistente.

#### Scenario: presupuesto sin cliente
- **WHEN** se intenta crear un presupuesto sin cliente
- **THEN** la operación falla con un error de payload inválido y no se persiste nada

#### Scenario: cliente de otra cuenta
- **WHEN** se intenta crear un presupuesto para un cliente de otra cuenta
- **THEN** la operación falla con `client_not_found`, igual que con un id inexistente

#### Scenario: producto de otra cuenta
- **WHEN** se intenta crear un presupuesto con una línea cuyo producto pertenece a otra cuenta
- **THEN** la operación falla con `product_not_found` y ningún dato de ese producto queda copiado en un snapshot

#### Scenario: unidad incompatible
- **WHEN** se intenta presupuestar en gramos un producto cuya unidad base es la unidad
- **THEN** la operación falla con el error de unidad incompatible

#### Scenario: unidad de otra cuenta en una línea de servicio
- **WHEN** se intenta crear un presupuesto con una línea de servicio cuya unidad pertenece a otra cuenta
- **THEN** la operación falla con el mismo error que una unidad inexistente y no se persiste nada

#### Scenario: el total lo calcula el servidor
- **WHEN** se crea un presupuesto con dos líneas de subtotal 100,00 y 50,50 y el cliente informa un total de 1,00
- **THEN** el presupuesto queda con `total = 150,50`

#### Scenario: escritura directa rechazada
- **WHEN** un usuario autenticado intenta un `INSERT` o un `UPDATE` directo sobre `quotes` o `quote_items` por la API de datos
- **THEN** la escritura es rechazada por las políticas de fila

### Requirement: Edición del presupuesto mientras no esté convertido
El sistema SHALL permitir editar un presupuesto en cualquier estado salvo `accepted`: su cliente, su sucursal, su fecha de validez, sus notas y sus líneas. La edición SHALL reemplazar las líneas de forma atómica, volviendo a congelar los snapshots desde el maestro, y SHALL registrar `updated_at` y `updated_by`. La fecha de validez SHALL ser obligatoria en la edición e igual o posterior al día de negocio argentino. Editar un presupuesto en `expired` o `rejected` SHALL reabrirlo a `draft`, registrando la transición en el historial en la misma transacción. Un presupuesto en `accepted` (convertido en venta) SHALL ser inmutable: toda edición SHALL rechazarse con `P0423` y el motivo "ya convertido en venta", sin modificar nada.

La edición SHALL indicar la versión (`revision`) del presupuesto sobre la que se hizo; si no coincide con la vigente, SHALL rechazarse con `quote_changed` sin modificar nada, de modo que dos editores simultáneos no se pisen en silencio. Cada edición aceptada SHALL incrementar la versión.

La edición de un presupuesto SHALL volver a congelar los snapshots de **todas** sus líneas desde el maestro vigente, aunque el producto de la línea no cambie. La política de preservación de snapshots al editar de `document-snapshots` rige para las operaciones de venta y compra, NOT para el presupuesto: un documento todavía no confirmado no tiene costo histórico que proteger, y el precio prometido viaja en la propia línea.

#### Scenario: editar un presupuesto enviado
- **GIVEN** un presupuesto en `sent` con dos líneas
- **WHEN** se edita quitando una línea y cambiando la cantidad de la otra
- **THEN** el presupuesto queda con una sola línea, el total recalculado, `updated_at` actualizado y el estado `sent`

#### Scenario: la edición re-toma los snapshots
- **GIVEN** un presupuesto cuyo producto cambió de nombre en el catálogo después de cotizarlo
- **WHEN** se edita el presupuesto
- **THEN** las líneas quedan con el nombre vigente del producto en `name_snapshot`

#### Scenario: un presupuesto convertido no se edita
- **GIVEN** un presupuesto en `accepted` (convertido en venta)
- **WHEN** se intenta editarlo
- **THEN** la operación falla con `P0423` indicando que ya se convirtió en venta, y sus líneas no cambian

#### Scenario: editar un presupuesto vencido lo reabre
- **GIVEN** un presupuesto en `expired`
- **WHEN** se lo edita fijando `valid_until` = hoy + 10 días
- **THEN** la edición se acepta, el presupuesto queda en `draft` y el historial registra `expired → draft`

#### Scenario: la edición exige fecha de validez
- **WHEN** se edita un presupuesto sin fecha de validez
- **THEN** la operación falla con un error de payload inválido y el presupuesto no cambia

#### Scenario: ampliar la validez de un presupuesto abierto vencido
- **GIVEN** un presupuesto en `sent` con `valid_until` = ayer y el barrido todavía sin correr
- **WHEN** se lo edita fijando `valid_until` = hoy + 10 días
- **THEN** la edición se acepta y el presupuesto deja de informarse como vencido

#### Scenario: la edición re-congela aunque el producto no cambie
- **GIVEN** un presupuesto con una línea de un producto cuyo costo al cotizar era $500 y hoy es $600
- **WHEN** se edita el presupuesto cambiando sólo la cantidad de esa línea
- **THEN** la línea queda con `unit_cost_snapshot = 600`

#### Scenario: dos editores simultáneos
- **GIVEN** dos usuarios que abrieron la edición del mismo presupuesto en la versión 3
- **WHEN** el primero guarda y después guarda el segundo
- **THEN** la edición del primero se acepta y deja la versión 4, y la del segundo falla con `quote_changed` sin modificar nada

#### Scenario: edición atómica
- **WHEN** la edición falla en la validación de la tercera línea
- **THEN** el presupuesto conserva todas sus líneas y datos anteriores

### Requirement: Enviar, rechazar y eliminar un presupuesto
El sistema SHALL permitir, en un presupuesto abierto (`draft` o `sent`):

- marcarlo como **enviado** (`draft → sent`); en un presupuesto que ya está en `sent`, la operación SHALL ser un no-op idempotente;
- **rechazarlo** (`→ rejected`), con un motivo opcional.

La interfaz SHALL marcar automáticamente como enviado un presupuesto en `draft` cuando el usuario lo descarga o lo envía por WhatsApp; verlo o imprimirlo NOT SHALL cambiar su estado, ni tampoco cancelar el menú de compartir del dispositivo. La marca automática SHALL aplicarse sólo si el usuario tiene permiso para enviar presupuestos: la descarga de un rol de sólo lectura no cambia el estado. El sistema SHALL permitir **eliminar** sólo un presupuesto en `draft` que nunca se envió (borrado físico de sus líneas y de la cabecera; el historial de estados se conserva). El borrado SHALL decidirse bajo bloqueo del presupuesto y con el estado como condición de la propia eliminación, de modo que nunca borre un presupuesto que otra operación concurrente convirtió en venta. Un presupuesto en cualquier otro estado SHALL rechazar el borrado con `quote_not_deletable`. La API NOT SHALL exponer la transición a `accepted` fuera de la conversión a venta, ni la transición a `expired`, que es exclusiva del barrido.

#### Scenario: descargar marca como enviado
- **GIVEN** un presupuesto en `draft`
- **WHEN** el usuario descarga su PDF desde el detalle
- **THEN** el presupuesto pasa a `sent`

#### Scenario: ver no marca como enviado
- **GIVEN** un presupuesto en `draft`
- **WHEN** el usuario elige "Ver / Imprimir"
- **THEN** el presupuesto sigue en `draft`

#### Scenario: rechazar con motivo
- **WHEN** se rechaza un presupuesto en `sent` con el motivo "precio alto"
- **THEN** el presupuesto queda `rejected` y el historial guarda el motivo

#### Scenario: eliminar un borrador
- **WHEN** se elimina un presupuesto en `draft`
- **THEN** el presupuesto y sus líneas dejan de existir

#### Scenario: no se elimina un presupuesto enviado
- **WHEN** se intenta eliminar un presupuesto en `sent`
- **THEN** la operación falla con `quote_not_deletable` y el presupuesto no cambia

#### Scenario: cancelar el envío no marca enviado
- **GIVEN** un presupuesto en `draft`, en un dispositivo con share nativo
- **WHEN** el usuario elige "Enviar por WhatsApp" y cancela el menú de compartir
- **THEN** el presupuesto sigue en `draft`

#### Scenario: no se elimina un borrador reabierto que ya se envió
- **GIVEN** un presupuesto que se envió, se rechazó y se reabrió a `draft` al editarlo
- **WHEN** se intenta eliminarlo
- **THEN** la operación falla con `quote_not_deletable`

#### Scenario: borrado concurrente con la conversión
- **WHEN** una sesión elimina un presupuesto en `draft` nunca enviado mientras otra lo convierte en venta
- **THEN** gana una sola: o la venta queda con el presupuesto `accepted` y enlazado, y el borrado falla con `quote_not_deletable`, o el presupuesto se elimina y la conversión falla con `quote_not_found`; nunca queda una venta sin su presupuesto de origen

#### Scenario: la API no expone expirar
- **WHEN** se pide por la API transicionar un presupuesto a `expired` o a `accepted`
- **THEN** la API responde con un error de payload inválido

### Requirement: Conversión atómica del presupuesto en venta
El sistema SHALL proveer la operación `rpc_convert_quote_to_sale` (`SECURITY DEFINER`, expuesta como `POST /quotes/{id}/convert` con `Idempotency-Key` por header) que, en **una sola transacción**, ejecuta estos pasos:

- acepta el presupuesto con el núcleo de aceptación compartido con `accept()`;
- confirma la orden de venta resultante con el mismo núcleo que usa la venta rápida del POS, con la forma de pago del catálogo, la sucursal, la sesión de caja, la cuenta bancaria y el canal indicados.

La venta resultante SHALL:

- descontar stock por sucursal en la unidad base;
- registrar caja, banco o cuenta corriente según la forma de pago, con el vencimiento resuelto por la cascada vigente;
- emitir `SaleConfirmed`;
- quedar como una orden `confirmed` facturable por las acciones vigentes.

Las líneas SHALL ser las del presupuesto y nunca las del request: producto, cantidad, unidad, precio y subtotal vienen del presupuesto, y las líneas de la orden (`sales_order_items`) heredan sus snapshots sin volver a leer el maestro. Las filas legacy de la venta (`sales`/`sale_items`) y el costo de los movimientos de stock SHALL congelarse al confirmar desde el maestro vigente, igual que en una venta del POS: el costo de la venta es el del momento de la venta. Una línea de servicio SHALL convertirse con su descripción, y la venta SHALL mostrarla.

La operación SHALL:

- bloquear el presupuesto antes de cualquier otra lectura o escritura;
- validar sobre el presupuesto bloqueado, antes de los guards de convertibilidad, que esté abierto (`quote_invalid_state`), que no esté vencido (`quote_expired`) y que su versión sea la que el usuario confirmó (`quote_changed`), para no cobrar líneas o un total distintos de los que se mostraron;
- exigir una forma de pago del catálogo;
- rechazar con `quote_product_unavailable` una línea cuyo producto fue dado de baja o no pertenece a la cuenta, antes de escribir;
- rechazar con `product_is_parent` una línea cuyo producto pasó a tener variantes;
- rechazar con `quote_client_unavailable` un presupuesto cuyo cliente fue dado de baja, antes de escribir;
- exigir, con una forma de pago de `kind = 'cash'`, una sesión de caja abierta de la sucursal (`cash_requires_session`), igual que el POS.

Ante cualquier fallo —stock insuficiente (`P0409`), presupuesto vencido o no abierto, caja inválida, forma de pago inválida— NO SHALL quedar ningún efecto: ni presupuesto aceptado, ni orden, ni stock, ni caja, ni cuenta corriente, ni banco, ni eventos.

Idempotencia:

- una reinvocación con la misma clave SHALL devolver la venta original con `replayed = true` sin efectos nuevos;
- una clave ya usada por otra operación SHALL rechazarse con `idempotency_key_conflict`, también cuando dos conversiones con la misma clave sobre presupuestos distintos corren en paralelo.

La conversión SHALL estar permitida a los roles vendedor, administrador y dueño.

#### Scenario: presupuesto aceptado se convierte en venta en efectivo
- **GIVEN** un presupuesto en `sent` con 2 unidades de un producto con `branch_stock = 5` y una caja abierta en la sucursal
- **WHEN** se lo convierte con una forma de pago de `kind = 'cash'` y esa sesión de caja
- **THEN** en la misma transacción el presupuesto queda `accepted`, se crea una orden `confirmed` con `source_quote_id`, `branch_stock` queda en 3, existe un movimiento de caja por el total, un evento `SaleConfirmed` y el historial de ambos documentos

#### Scenario: conversión a crédito
- **WHEN** se convierte un presupuesto con una forma de pago de `kind = 'credit'`
- **THEN** se postea el cargo en la cuenta corriente del cliente, con el vencimiento de la cascada, y no se crea movimiento de caja

#### Scenario: la venta usa el precio del presupuesto
- **GIVEN** un presupuesto con una línea a $1.000 y el producto remarcado a $1.200 después de cotizar
- **WHEN** se convierte el presupuesto
- **THEN** la venta registra la línea a $1.000

#### Scenario: stock insuficiente no deja nada
- **GIVEN** un presupuesto de 5 unidades de un producto con `branch_stock = 3` en la sucursal elegida
- **WHEN** se intenta convertirlo
- **THEN** la operación falla con `P0409`, el presupuesto conserva su estado, no se crea ninguna orden y `branch_stock` sigue en 3

#### Scenario: producto dado de baja
- **GIVEN** un presupuesto con una línea de un producto dado de baja después de cotizar
- **WHEN** se intenta convertirlo
- **THEN** la operación falla con `quote_product_unavailable` nombrando el producto, sin efectos

#### Scenario: presupuesto vencido
- **WHEN** se intenta convertir un presupuesto con `valid_until` anterior a hoy (ART)
- **THEN** la operación falla indicando que está vencido, sin efectos

#### Scenario: presupuesto de otra cuenta
- **WHEN** un usuario intenta convertir un presupuesto de otra cuenta
- **THEN** la operación falla con `quote_not_found`, igual que con un id inexistente

#### Scenario: doble clic con la misma clave
- **WHEN** la conversión se invoca dos veces con la misma `Idempotency-Key`
- **THEN** se crea una sola venta y la segunda respuesta devuelve la misma venta con `replayed = true`

#### Scenario: clave reutilizada en otro presupuesto
- **GIVEN** una clave ya usada para convertir el presupuesto A
- **WHEN** se la usa para convertir el presupuesto B
- **THEN** la operación falla con `idempotency_key_conflict` y B no cambia

#### Scenario: conversiones concurrentes con claves distintas
- **WHEN** dos sesiones convierten el mismo presupuesto al mismo tiempo con claves distintas
- **THEN** exactamente una crea la venta y la otra falla con un error de estado inválido

#### Scenario: misma clave en paralelo sobre dos presupuestos
- **WHEN** dos sesiones convierten al mismo tiempo los presupuestos A y B con la misma `Idempotency-Key`
- **THEN** exactamente una crea su venta, la otra falla con `idempotency_key_conflict`, su presupuesto conserva el estado y no queda ninguna orden `draft`

#### Scenario: el presupuesto cambió mientras se confirmaba la venta
- **GIVEN** un usuario que abrió "Convertir en venta" sobre la versión 2 de un presupuesto, y otro usuario que después le agregó una línea (versión 3)
- **WHEN** el primero confirma la conversión
- **THEN** la operación falla con `quote_changed` y no queda ningún efecto

#### Scenario: el estado se informa antes que un producto dado de baja
- **GIVEN** un presupuesto ya convertido cuyo producto se dio de baja después
- **WHEN** se intenta convertirlo otra vez con otra clave
- **THEN** la operación falla con el error de estado inválido y no con `quote_product_unavailable`

#### Scenario: efectivo sin caja abierta
- **WHEN** se convierte un presupuesto con una forma de pago de `kind = 'cash'` sin sesión de caja
- **THEN** la operación falla con `cash_requires_session` y no queda ningún efecto

#### Scenario: cliente dado de baja
- **GIVEN** un presupuesto cuyo cliente se dio de baja después de cotizar
- **WHEN** se intenta convertirlo a crédito
- **THEN** la operación falla con `quote_client_unavailable` y no se postea ningún cargo en la cuenta corriente

#### Scenario: el costo de la venta es el del día
- **GIVEN** un presupuesto cotizado cuando el costo del producto era $500, y el costo actual es $600
- **WHEN** se lo convierte
- **THEN** la venta registra el precio del presupuesto y congela el costo en $600, y las líneas de la orden conservan los snapshots del presupuesto

#### Scenario: línea de servicio en la venta
- **GIVEN** un presupuesto con la línea de servicio "Instalación"
- **WHEN** se lo convierte
- **THEN** la venta incluye esa línea con su importe y la muestra con la descripción "Instalación"

#### Scenario: la venta generada es facturable
- **GIVEN** una venta generada por la conversión de un presupuesto
- **WHEN** el usuario elige "Facturar"
- **THEN** la emisión del comprobante procede exactamente igual que para una venta del POS

#### Scenario: un cajero no convierte presupuestos
- **WHEN** un usuario cuyo único rol es cajero intenta convertir un presupuesto
- **THEN** la operación se rechaza por permisos insuficientes y no hay efectos

### Requirement: Permisos sobre presupuestos
El sistema SHALL permitir leer presupuestos, su historial y su PDF a cualquier miembro de la cuenta. Crear, editar, enviar, rechazar, eliminar y convertir presupuestos SHALL estar permitido sólo a los roles vendedor, administrador y dueño —el mismo conjunto que el catálogo de transiciones declara para `quote`—, verificado en el backend y en la base de datos. La interfaz SHALL ocultar las acciones que el rol del usuario no permite, decidiendo sobre el conjunto completo de sus roles activos. Un rechazo por rol SHALL usar el código `P0403` (403 en la API).

#### Scenario: un cajero consulta pero no crea
- **GIVEN** un usuario cuyo único rol es cajero
- **WHEN** abre `/presupuestos` e intenta crear un presupuesto por la API
- **THEN** ve el listado, no ve el botón "Nuevo presupuesto", y la API responde 403

#### Scenario: un vendedor crea y convierte
- **GIVEN** un usuario cuyo único rol es vendedor
- **WHEN** crea un presupuesto y lo convierte en venta
- **THEN** las dos operaciones se completan

#### Scenario: un cajero descarga sin cambiar el estado
- **GIVEN** un usuario cuyo único rol es cajero y un presupuesto en `draft`
- **WHEN** descarga su PDF
- **THEN** recibe el archivo y el presupuesto sigue en `draft`

### Requirement: PDF y envío del presupuesto
El sistema SHALL generar el PDF del presupuesto según la capability `commercial-document-pdf`, desde `GET /quotes/{id}/pdf`, para un presupuesto de la cuenta del usuario en cualquier estado. El PDF SHALL contener:

- el título "PRESUPUESTO" y el número visible;
- las fechas de emisión y de validez;
- el cliente;
- las líneas con su cantidad, unidad, precio unitario y subtotal;
- el total y las notas;
- la leyenda "Presupuesto — documento no válido como factura. Precios válidos hasta el dd/mm/aaaa.";
- un sello "VENCIDO", "RECHAZADO" o "ACEPTADO" según el estado.

El archivo SHALL llamarse `presupuesto-P-NNNNNNNN.pdf`. Desde el detalle, el usuario SHALL poder verlo o imprimirlo, descargarlo y enviarlo por WhatsApp al teléfono del cliente mediante el menú de compartir de esa capability, con un texto corto que nombra el presupuesto, el total y la validez.

#### Scenario: descargar el PDF de un presupuesto
- **WHEN** el dueño del presupuesto P-00000012 lo descarga
- **THEN** recibe `presupuesto-P-00000012.pdf` con el número, el cliente, las líneas, el total y la leyenda de no válido como factura

#### Scenario: PDF de un presupuesto vencido
- **WHEN** se descarga el PDF de un presupuesto vencido
- **THEN** el PDF lleva el sello "VENCIDO"

#### Scenario: WhatsApp al cliente con teléfono
- **GIVEN** un presupuesto de un cliente con teléfono válido, en un dispositivo sin share de archivos
- **WHEN** el usuario elige "Enviar por WhatsApp"
- **THEN** se descarga el PDF y se abre WhatsApp dirigido a ese número con el texto corto del presupuesto

#### Scenario: WhatsApp en el celular
- **GIVEN** un dispositivo con share nativo de archivos
- **WHEN** el usuario elige "Enviar por WhatsApp"
- **THEN** se comparte el archivo PDF del presupuesto junto con el texto corto

### Requirement: Pantallas de presupuestos
El sistema SHALL exponer el módulo de presupuestos en `/presupuestos`, con entrada "Presupuestos" en el grupo *Operaciones* del sidebar (entre "POS — Venta Rápida" y "Compras") y sin gate de plan. Incluye:

- **Listado** paginado, con filtros por estado, búsqueda por cliente o número, fecha, validez con el indicador "Vencido" y total.
- **Alta** (`/presupuestos/nuevo`, con cliente preseleccionable por `?cliente=` y duplicado por `?duplicar=`) y **edición** (`/presupuestos/[id]/editar`), con el mismo editor de líneas de la venta:
  - buscador de productos, lector de códigos y etiquetas de balanza, unidades, descuento por línea y líneas de servicio;
  - cliente obligatorio, con alta en el lugar;
  - validez y notas;
  - el stock disponible sólo informado, sin bloquear.
- **Detalle** (`/presupuestos/[id]`): cabecera, líneas, total, notas, historial y las acciones permitidas por su estado y el rol del usuario (editar, compartir, Venta, rechazar, duplicar, eliminar). "Editar" SHALL estar disponible en todo estado salvo `accepted`.
- **Diálogo "Convertir en venta"**: sucursal, forma de pago del catálogo, cuenta bancaria cuando corresponde, la sesión de caja abierta de la sucursal cuando el pago es en efectivo (obligatoria, como en el POS: sin caja abierta, la acción se deshabilita con el motivo y un acceso a Caja) y, si es a crédito, saldo del cliente. Al completarse ofrece "Facturar" y "Ver venta".

La ficha del cliente SHALL ofrecer "Nuevo presupuesto" con el cliente preseleccionado, visible en todas sus pestañas, y una pestaña "Presupuestos" con sus últimos presupuestos. Todas estas pantallas SHALL verse correctamente en escritorio y en móvil (375 px, sin desborde horizontal) y en tema claro y oscuro.

#### Scenario: llegar al módulo
- **WHEN** un usuario abre el sidebar
- **THEN** ve "Presupuestos" en el grupo Operaciones y lo lleva a `/presupuestos`

#### Scenario: presupuesto desde la ficha del cliente
- **WHEN** el usuario toca "Nuevo presupuesto" en la ficha de un cliente
- **THEN** se abre `/presupuestos/nuevo` con ese cliente seleccionado

#### Scenario: duplicar con precios de hoy
- **GIVEN** un presupuesto vencido con una línea a $1.000 de un producto que hoy vale $1.200
- **WHEN** el usuario elige "Duplicar"
- **THEN** se abre el alta con las mismas líneas, esa línea a $1.200 y un aviso de que el precio cambió

#### Scenario: la acción Venta de un vencido está deshabilitada
- **GIVEN** un presupuesto abierto informado como vencido
- **WHEN** el usuario abre su detalle
- **THEN** "Venta" está deshabilitada con la explicación "ampliá la validez o duplicalo"

#### Scenario: error de stock al convertir
- **WHEN** la conversión falla por stock insuficiente
- **THEN** el diálogo muestra qué producto no alcanza y el presupuesto sigue abierto

#### Scenario: efectivo sin caja abierta en el diálogo
- **GIVEN** una sucursal sin sesión de caja abierta
- **WHEN** el usuario elige una forma de pago en efectivo en el diálogo de conversión
- **THEN** "Venta" queda deshabilitada con el motivo y un acceso a Caja

#### Scenario: venta generada visible desde el presupuesto
- **GIVEN** un presupuesto convertido
- **WHEN** el usuario abre su detalle
- **THEN** ve el enlace a la venta generada y el estado de su comprobante

## Implementation Notes

- **Tablas**: `quotes` + `quote_items` (migración `20260702000001_c29_quote_salesorder.sql`); el módulo de presupuestos las extiende con `number`, `notes`, `sent_at`, `updated_at`, `updated_by`, `revision`, `valid_until` y `quote_items.line_no`, más `accounts.default_quote_validity_days` y la tabla `internal_document_sequences` (migración `20261067000001_presupuestos_modulo.sql`; `sales_orders.source_quote_id` en `20261068000001_presupuestos_conversion_venta.sql`).
- **Escritura sólo por RPC**: `quotes` y `quote_items` **no tienen políticas de escritura** (`quotes_insert`, `quotes_update`, `quote_items_insert` y `quote_items_update` se eliminaron) y `authenticated` no tiene privilegios INSERT/UPDATE/DELETE sobre ellas; la escritura directa por PostgREST ya no existe. La lectura se mantiene con SELECT bajo `account_id IN (SELECT current_account_ids())`.
- **RPCs** (todas `SECURITY DEFINER`, sin `EXECUTE` para `anon`): `rpc_create_quote`, `rpc_update_quote`, `rpc_transition_quote`, `rpc_delete_quote`, `rpc_set_default_quote_validity` y `rpc_convert_quote_to_sale` con `EXECUTE` para `authenticated`; `rpc_accept_quote(p_quote_id)` y su núcleo `_quote_accept_core(p_quote_id, p_branch_id)` son **internos**, sin `EXECUTE` para `authenticated` (los invoca sólo la conversión). Helpers internos `_next_internal_document_number`, `_quote_assert_can_write`, `_quote_validate_items`, `_quote_insert_items`, `_quote_payload`, `rpc_commercial_issuer` y `_expire_overdue_quotes`.
- **Vencimiento**: job `pg_cron` `quotes-expire-sweep` (`5 3 * * *`) que ejecuta `_expire_overdue_quotes()` con el actor de sistema (uuid cero).
- **Backend**: `backend/schemas/quotes.py`, `backend/repositories/quote_repository.py`, `backend/services/quotes.py`, `backend/routers/quotes.py` (`GET/POST /quotes`, `GET/PUT/DELETE /quotes/{id}`, `POST /quotes/{id}/transition`, `POST /quotes/{id}/convert`, `GET /quotes/{id}/pdf`; **no existe endpoint `accept`**) y `backend/services/commercial_documents/` (numeración, vista resuelta, emisor y constructor compartido del PDF).
- **Frontend**: rutas `/presupuestos`, `/presupuestos/nuevo`, `/presupuestos/[id]`, `/presupuestos/[id]/editar` y `/clientes/[id]/presupuestos`; `hooks/data/use-quotes.ts` (React Query: listado paginado, alta, edición, transición, borrado y conversión; la conversión invalida además todo lo que toca una venta vía `invalidateAfterSale`), `components/quotes/` (`QuoteForm`, `ConvertQuoteDialog`, `QuoteStatusBadge`, `QuoteSettingsCard`), `components/shared/DocumentShareMenu.tsx` y `StagedProductLine.tsx`.
