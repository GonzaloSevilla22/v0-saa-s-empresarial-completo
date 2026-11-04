# purchase-operation Specification

## Purpose

Comportamiento operativo propio de la compra que no encaja en ninguna capability compartida: la persistencia de su sucursal y el descuento de caja en efectivo por opt-in explícito, con las mismas tres condiciones verificadas en servidor que ya rigen para la venta y el gasto (forma de pago `cash`, sesión de caja abierta en la sucursal efectiva de la operación, fecha de hoy en `America/Argentina/Mendoza`). Nace de `caja-compras-cobranzas` (2026-09-02): pese a que el tipo `purchase_payment` del `CHECK` de `cash_movements`, la meta de presentación en `/caja` y el helper compartido de opt-in ya existían, ninguna de las RPCs de compra los usaba, así que una compra en efectivo no dejaba rastro alguno en el libro de caja. De paso cierra un hallazgo lateral load-bearing para esa misma verificación de sucursal: el 100% de las compras históricas tenía `branch_id` nulo por un descarte silencioso en cuatro eslabones de la cadena (formulario, hook, schema del payload y repository).

## Requirements
### Requirement: La compra persiste su sucursal

El sistema SHALL registrar en una sucursal toda compra que se cree o se edite por el formulario, la API o sus funciones de base: la que el usuario eligió o, si no eligió ninguna, la sucursal principal de la cuenta (`c26_default_branch`), propagándola a todas las filas de la operación. Esa sucursal SHALL ser **la misma** en la que entra el stock, la que se escribe en el movimiento de stock y en el movimiento bancario, y la que se compara con la caja del opt-in de efectivo.

La sucursal es obligatoria en los documentos operativos (RN-93) y es además el **ancla de la verificación de sucursal del descuento de caja**: sin ella, la compra y el cajón que recibió el efectivo pueden quedar atribuidos a lugares distintos sin que nada lo advierta.

Una sucursal elegida SHALL rechazarse si es inexistente, inactiva o de otra cuenta (`P0404`) o si está cerrada (`P0422 branch_closed`), igual que en la venta y el gasto.

Si no se eligió sucursal y la cuenta no tiene ninguna sucursal **operativa** a la cual resolver (no tiene sucursales, o todas están inactivas o cerradas), el alta SHALL rechazarse con `P0422 no_branch_found` sin persistir nada: sin compra, sin stock, sin movimientos. El sistema NO SHALL registrar una compra, ni ingresar su stock, en una sucursal inactiva o cerrada por resolución implícita, ni crear una sucursal como efecto lateral de una compra.

Las compras registradas sin sucursal antes de este cambio SHALL conservar su sucursal nula, sin relleno retroactivo en masa. Una compra histórica toma sucursal sólo cuando un usuario la edita, por la regla de la edición (capability `operation-edit-context`).

Este requirement cumple RN-93 y DEC-19 para la compra.

#### Scenario: La sucursal elegida llega a la compra

- **GIVEN** una cuenta con dos sucursales activas
- **WHEN** el usuario registra una compra eligiendo la segunda sucursal
- **THEN** todas las filas de esa operación quedan con esa sucursal

#### Scenario: La compra sin sucursal elegida queda en la principal

- **GIVEN** una cuenta con la sucursal principal A y otra sucursal B, y una compra de dos líneas (una con producto y una sin producto)
- **WHEN** se registra la compra sin elegir sucursal
- **THEN** las dos filas de `purchases` quedan con `branch_id = A`, el stock del producto entra en A y no en B, y su movimiento de stock queda con `branch_id = A`

#### Scenario: La compra bancaria sin sucursal elegida deja su movimiento bancario en la principal

- **GIVEN** una forma de pago bancaria con cuenta destino resuelta
- **WHEN** se registra una compra sin elegir sucursal imputada a esa forma de pago
- **THEN** el movimiento bancario de egreso queda con la misma sucursal que la compra, la principal

#### Scenario: La principal cerrada no recibe compras sin sucursal elegida

- **GIVEN** una cuenta cuya sucursal más antigua está cerrada y una segunda sucursal operativa
- **WHEN** se registra una compra sin elegir sucursal
- **THEN** la compra, su stock y su movimiento de stock quedan en la segunda sucursal

#### Scenario: Cuenta sin sucursal operativa

- **GIVEN** una cuenta cuyas sucursales están todas inactivas o cerradas, o que no tiene ninguna sucursal
- **WHEN** se registra una compra sin elegir sucursal, con producto o sin producto
- **THEN** la operación falla con `P0422 no_branch_found` y no se crean filas de compra, de idempotencia ni de movimientos, `branch_stock` queda sin cambios y no se crea ninguna sucursal

#### Scenario: Una sucursal ajena o inactiva es rechazada

- **WHEN** se registra una compra informando una sucursal de otra cuenta, inexistente o inactiva
- **THEN** la operación es rechazada con `P0404` y no se crea ninguna fila de compra

#### Scenario: Una sucursal elegida cerrada es rechazada

- **GIVEN** una sucursal activa con `status = 'closed'`
- **WHEN** se registra una compra eligiendo esa sucursal
- **THEN** la operación falla con `P0422 branch_closed`, no se crea ninguna fila de compra y el stock de esa sucursal no cambia

#### Scenario: Las compras históricas no se rellenan

- **WHEN** se aplica este cambio y se recorren las compras registradas antes, sin sucursal
- **THEN** su sucursal sigue siendo nula
- **AND** ninguna fila histórica fue reescrita por el sistema

#### Scenario: El reporte por sucursal ve las compras nuevas

- **GIVEN** una compra registrada después de este cambio, con o sin sucursal elegida
- **WHEN** se consulta el Tablero filtrado por la sucursal en la que quedó
- **THEN** la compra aparece atribuida a esa sucursal

### Requirement: La compra en efectivo descuenta de la caja mediante opt-in con tres condiciones verificadas en el servidor

El sistema SHALL registrar un movimiento de egreso de caja por el total de una compra imputada a una forma de pago de `kind = 'cash'` **únicamente** cuando el usuario lo afirme explícitamente y se cumplan **simultáneamente** las tres condiciones siguientes, todas verificadas en el servidor: la forma de pago imputada tiene `kind = 'cash'`, existe una sesión de caja abierta cuya caja pertenece a la sucursal efectiva de la compra, y la fecha de la compra es el día de hoy en `America/Argentina/Mendoza`.

La **sucursal efectiva** de la compra SHALL ser la misma que se persiste en la operación (requirement «La compra persiste su sucursal»): la elegida o, si no se eligió ninguna, la sucursal principal de la cuenta. NO SHALL compararse la sesión contra la sucursal **recibida** sin resolver: una compra sin sucursal elegida se registra en la principal, y su opt-in SHALL aceptar la sesión abierta de la caja de la principal.

Las tres condiciones SHALL ser **las mismas** que ya rigen para la venta desde el formulario y para el gasto, con los mismos códigos y los mismos tokens de error, y SHALL NOT delegarse en la interfaz: una solicitud que informe una sesión de caja sin cumplirlas SHALL fallar entera —sin compra, sin stock movido y sin movimiento de caja— en vez de registrar el movimiento o de ignorarlo en silencio.

La ausencia del dato de sesión SHALL ser un **no-op**: la compra se registra normalmente sin tocar la caja. La falta de una caja abierta NO SHALL impedir registrar una compra.

La verificación de la fecha SHALL comparar la **fecha** de la compra contra el día local argentino, y SHALL NOT derivarla de un instante con zona horaria: la conversión implícita usaría la zona del servidor y rechazaría por "no es hoy" una compra cargada al final de la tarde argentina.

El efecto SHALL producirse delegando en el helper intra-transaccional de caja que ya existe, sin abrir una segunda puerta de escritura, de modo que la compra herede sus invariantes: sesión abierta, pertenencia de la sesión a la cuenta, sucursal operativa, saldo posterior calculado bajo lock y autoría.

#### Scenario: Compra en efectivo con las tres condiciones cumplidas

- **GIVEN** una sesión de caja abierta en la sucursal de la compra, con saldo de apertura conocido
- **WHEN** se registra hoy una compra de 8000 imputada a una forma de pago de `kind = 'cash'` afirmando el descuento de caja
- **THEN** se registra un movimiento de caja de egreso por 8000 referenciando la operación de compra, en el mismo commit que el ingreso de stock
- **AND** el saldo esperado de la sesión baja en 8000

#### Scenario: Compra en efectivo sin sucursal elegida descuenta de la caja de la principal

- **GIVEN** una cuenta cuya sucursal principal A tiene una sesión de caja abierta
- **WHEN** se registra hoy, sin elegir sucursal, una compra imputada a `kind = 'cash'` informando la sesión de A
- **THEN** la compra se registra en A con su movimiento de caja de egreso en la sesión de A, sin error

#### Scenario: Compra en efectivo sin afirmación no toca la caja

- **GIVEN** una sesión de caja abierta en la sucursal de la compra
- **WHEN** se registra una compra imputada a `kind = 'cash'` sin afirmar el descuento de caja
- **THEN** la compra se registra normalmente y no se crea ningún movimiento de caja
- **AND** el arqueo de la sesión no se ve afectado

#### Scenario: La afirmación con una forma de pago que no es efectivo es rechazada

- **WHEN** se registra una compra imputada a una forma de pago bancaria o de cuenta corriente informando una sesión de caja
- **THEN** la operación falla con el token de "el descuento de caja exige efectivo" y no se crea ni la compra ni el movimiento

#### Scenario: La afirmación sin sesión abierta en la sucursal es rechazada

- **GIVEN** dos sucursales, cada una con su caja, y una sesión abierta sólo en la segunda
- **WHEN** se registra hoy una compra en la primera sucursal imputada a `kind = 'cash'` informando la sesión de la segunda
- **THEN** la operación falla con el token de "el descuento de caja exige una sesión abierta" y el arqueo de la segunda sucursal no se altera

#### Scenario: Sin sucursal elegida, la sesión de otra sucursal que no es la principal es rechazada

- **GIVEN** la sucursal principal A y otra sucursal B con una sesión de caja abierta
- **WHEN** se registra hoy, sin elegir sucursal, una compra imputada a `kind = 'cash'` informando la sesión de B
- **THEN** la operación falla con el token de "el descuento de caja exige una sesión abierta" y no se crea ni la compra ni el movimiento

#### Scenario: La afirmación con fecha anterior a hoy es rechazada

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se registra una compra fechada ayer, imputada a `kind = 'cash'`, informando la sesión de caja
- **THEN** la operación falla con el token de "sólo se puede registrar en caja una compra fechada hoy" y no se crea ni la compra ni el movimiento

#### Scenario: Una compra cargada al final de la tarde argentina no se rechaza por fecha

- **GIVEN** una sesión de caja abierta y el instante actual dentro del último tramo del día local argentino que ya cayó en el día siguiente en tiempo universal
- **WHEN** se registra una compra fechada hoy en día local argentino, imputada a `kind = 'cash'`, afirmando el descuento de caja
- **THEN** la compra se registra con su movimiento de caja

#### Scenario: Sin caja abierta la compra se registra igual

- **GIVEN** una cuenta sin ninguna sesión de caja abierta
- **WHEN** se registra una compra imputada a `kind = 'cash'` sin informar sesión
- **THEN** la compra se registra normalmente, sin movimiento de caja y sin error

#### Scenario: La sesión de otra cuenta es rechazada

- **GIVEN** una sesión de caja abierta perteneciente a otra cuenta
- **WHEN** se registra una compra informando esa sesión
- **THEN** la operación es rechazada y la cantidad de movimientos de la sesión ajena queda sin cambios

### Requirement: La superficie de compra ofrece el descuento de caja pre-marcado y explica cuándo no aplica

La interfaz de alta de compra SHALL ofrecer la afirmación del descuento de caja **pre-marcada** cuando las tres condiciones se cumplen, y SHALL mostrar el motivo concreto cuando no se cumplen, sin ocultar el bloque en silencio.

El valor inicial marcado es deliberado y SHALL alinearse con el del gasto y no con el de la venta: la venta arranca sin marcar porque su formulario se usa masivamente para carga retroactiva de administración, mientras que una compra imputada a efectivo y fechada hoy describe casi siempre plata que salió del cajón. Con la verificación de fecha ya filtrando lo retroactivo, un valor inicial sin marcar reproduciría el estado previo al cambio —la caja sigue sin ver la plata salvo que alguien se acuerde de marcarlo.

La afirmación SHALL ofrecerse **sólo en el alta**: la compra con movimiento de caja posteado es inmutable, de modo que no existe un camino de edición en el que la afirmación tenga sentido.

La interfaz SHALL reutilizar la resolución de condiciones compartida que ya emplean el formulario de venta y el de gasto, en vez de reimplementarla; la autoridad sobre la decisión SHALL seguir siendo el servidor.

#### Scenario: Condiciones cumplidas

- **GIVEN** una compra en efectivo fechada hoy con una sesión de caja abierta en su sucursal
- **WHEN** el usuario ve el formulario de compra
- **THEN** la afirmación de descuento de caja aparece marcada, nombrando la sesión

#### Scenario: Condiciones no cumplidas

- **GIVEN** una compra en efectivo fechada hoy sin sesión de caja abierta en su sucursal
- **WHEN** el usuario ve el formulario de compra
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** una compra en efectivo con las tres condiciones cumplidas
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** la compra se registra sin movimiento de caja

#### Scenario: La edición no ofrece la afirmación

- **WHEN** el usuario edita una compra existente
- **THEN** el formulario no ofrece la afirmación de descuento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el bloque de descuento de caja se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones

### Requirement: La compra nacida de un remito no vuelve a sumar stock
El sistema SHALL crear la compra nacida de un remito de compra con el mismo núcleo transaccional que la compra directa, de modo que caja, banco, cuenta corriente del proveedor, idempotencia, total, evento `PurchaseCreated` y asiento se comporten igual, y SHALL NOT sumar stock ni escribir movimientos de stock para sus líneas, porque el stock ya lo sumó el remito.

La decisión de no sumar stock SHALL tomarla el servidor: el núcleo de compra es interno (no ejecutable por los roles de aplicación), recibe el remito de origen sólo desde la conversión, lo revalida bajo bloqueo (misma cuenta, sentido compra, estado `issued`, mismo proveedor, misma sucursal y sin otra compra con ese origen), lee las líneas del propio remito y persiste el origen en `purchases.source_delivery_note_id` de cada fila y, en la misma transacción, pasa el remito a `converted` con su historial. La operación pública de alta de compra SHALL conservar su firma y su comportamiento, y SHALL NOT aceptar ningún parámetro de origen. Las filas de la compra nacida de un remito SHALL tomar los snapshots de nombre, SKU, costo y alícuota de IVA de las líneas del remito.

#### Scenario: La compra directa no cambia
- **WHEN** se registra una compra directa de 5 unidades de A
- **THEN** el stock de A sube en 5 y existe un movimiento `purchase` / `purchase` por la fila, igual que antes de este cambio

#### Scenario: Origen inválido
- **WHEN** el núcleo de compra recibe como origen un remito ya convertido o de otro proveedor
- **THEN** rechaza con `P0409 delivery_note_purchase_mismatch` y no crea la compra ni mueve stock o dinero

#### Scenario: Producto renombrado entre la recepción y la compra
- **GIVEN** un remito de compra de "Harina 000" y el producto renombrado después a "Harina 000 x 25 kg"
- **WHEN** se convierte el remito en compra
- **THEN** las filas de la compra conservan el nombre "Harina 000"

### Requirement: La compra expone su remito de origen
El sistema SHALL exponer en el listado de compras el remito de origen de cada operación (id y número `RC-…`), leído con el filtro de la cuenta, y SHALL mostrarlo como el badge "Desde remito RC-…" con enlace al remito.

#### Scenario: Badge en el listado de compras
- **GIVEN** una compra nacida del remito `RC-00000012`
- **WHEN** el usuario abre `/compras`
- **THEN** la fila muestra "Desde remito RC-00000012" con enlace al detalle del remito

### Requirement: El origen de remito de una compra no es escribible por los roles de aplicación
El sistema SHALL impedir que los roles de aplicación (`anon`, `authenticated`) fijen, cambien o limpien `purchases.source_delivery_note_id`, inserten filas de compra con origen, modifiquen cualquier columna de una fila con origen (incluido su `operation_id`), lleven filas a una operación que tiene filas con origen o borren filas con origen por fuera del borrado de la operación, porque esa columna decide que la compra no sumó stock, que no se edita, que su borrado no revierte stock y que reabre un remito. El rechazo SHALL ser `P0403 delivery_note_source_protected`, sin efectos. Las operaciones del servidor que crean y borran la compra nacida de un remito SHALL seguir pudiendo escribirla, y las escrituras sobre compras sin origen SHALL comportarse como hoy.

#### Scenario: Forjar el origen en una compra directa
- **GIVEN** una compra directa de 5 unidades de A, con su movimiento de stock
- **WHEN** un escritor de la cuenta actualiza por PostgREST su `source_delivery_note_id` con el id de un remito pendiente
- **THEN** la operación falla con `P0403 delivery_note_source_protected` y borrar esa compra después sigue restando las 5 unidades

#### Scenario: Limpiar el origen de una compra de remito
- **WHEN** un escritor de la cuenta pone en nulo por PostgREST el `source_delivery_note_id` de una compra nacida de un remito
- **THEN** la operación falla con `P0403 delivery_note_source_protected` y la compra sigue sin poder editarse

#### Scenario: Partir una compra de remito cambiando su operación
- **WHEN** un escritor de la cuenta cambia por PostgREST el `operation_id` de una fila de una compra nacida de un remito
- **THEN** la operación falla con `P0403 delivery_note_source_protected`, la compra sigue siendo una sola operación y su borrado devuelve el remito a pendiente

#### Scenario: Mezclar una compra directa con una compra de remito
- **WHEN** un escritor de la cuenta cambia por PostgREST el `operation_id` de una compra directa al de una compra nacida de un remito
- **THEN** la operación falla con `P0403 delivery_note_source_protected` y la misma escritura entre dos compras directas sigue funcionando como hoy

#### Scenario: Borrar por PostgREST las filas de una compra de remito
- **WHEN** un escritor de la cuenta borra por PostgREST una fila de una compra nacida de un remito
- **THEN** la operación falla con `P0403 delivery_note_source_protected` y el remito sigue `converted` con su compra

