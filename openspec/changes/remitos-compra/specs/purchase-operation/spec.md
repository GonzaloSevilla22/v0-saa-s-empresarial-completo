## ADDED Requirements

### Requirement: La compra nacida de un remito no vuelve a sumar stock
El sistema SHALL crear la compra nacida de un remito de compra con el mismo núcleo transaccional que la compra directa, de modo que caja, banco, cuenta corriente del proveedor, idempotencia, total, evento `PurchaseCreated` y asiento se comporten igual, y SHALL NOT sumar stock ni escribir movimientos de stock para sus líneas, porque el stock ya lo sumó el remito.

La decisión de no sumar stock SHALL tomarla el servidor: el núcleo de compra es interno (no ejecutable por los roles de aplicación), recibe el remito de origen sólo desde la conversión, lo revalida bajo bloqueo (misma cuenta, sentido compra, estado `issued`, mismo proveedor, misma sucursal y sin otra compra con ese origen), lee las líneas del propio remito y persiste el origen en `purchases.source_delivery_note_id` de cada fila. La operación pública de alta de compra SHALL conservar su firma y su comportamiento, y SHALL NOT aceptar ningún parámetro de origen. Las filas de la compra nacida de un remito SHALL tomar los snapshots de nombre, SKU, costo y alícuota de IVA de las líneas del remito.

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
El sistema SHALL impedir que los roles de aplicación (`anon`, `authenticated`) fijen, cambien o limpien `purchases.source_delivery_note_id`, inserten filas de compra con origen o borren filas con origen por fuera del borrado de la operación, porque esa columna decide que la compra no sumó stock, que no se edita, que su borrado no revierte stock y que reabre un remito. El rechazo SHALL ser `P0403 delivery_note_source_protected`, sin efectos. Las operaciones del servidor que crean y borran la compra nacida de un remito SHALL seguir pudiendo escribirla, y las escrituras sobre compras sin origen SHALL comportarse como hoy.

#### Scenario: Forjar el origen en una compra directa
- **GIVEN** una compra directa de 5 unidades de A, con su movimiento de stock
- **WHEN** un escritor de la cuenta actualiza por PostgREST su `source_delivery_note_id` con el id de un remito pendiente
- **THEN** la operación falla con `P0403 delivery_note_source_protected` y borrar esa compra después sigue restando las 5 unidades

#### Scenario: Limpiar el origen de una compra de remito
- **WHEN** un escritor de la cuenta pone en nulo por PostgREST el `source_delivery_note_id` de una compra nacida de un remito
- **THEN** la operación falla con `P0403 delivery_note_source_protected` y la compra sigue sin poder editarse

#### Scenario: Borrar por PostgREST las filas de una compra de remito
- **WHEN** un escritor de la cuenta borra por PostgREST una fila de una compra nacida de un remito
- **THEN** la operación falla con `P0403 delivery_note_source_protected` y el remito sigue `converted` con su compra
