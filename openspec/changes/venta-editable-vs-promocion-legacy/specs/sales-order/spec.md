## MODIFIED Requirements

### Requirement: Promoción de una venta legacy a SalesOrder facturable

El sistema SHALL proveer una RPC `SECURITY DEFINER` `rpc_promote_legacy_sale_to_order(p_operation_id uuid)` que materialice una `SalesOrder` con `status = 'confirmed'` a partir de una venta legacy ya existente (filas `sales` con `operation_id = p_operation_id`), de modo que esa venta cargada a mano pueda facturarse reusando el flujo `emit-invoice` (capability `afip-fiscal-document`). La RPC SHALL ser **side-effect-free respecto de stock, caja, cuenta corriente, banco y outbox**: por tratarse de la materialización fiscal de una venta que **ya ocurrió** (su stock ya fue descontado al crearse), la promoción NO SHALL descontar `branch_stock`, NO SHALL registrar `cash_movement`, NO SHALL emitir el evento `SaleConfirmed` en el outbox (`events`), y NO SHALL invocar el helper interno `_c29_confirm_order_core`.

La RPC SHALL:
- (a) Validar autenticación (`auth.uid()`), tomar **primero** las filas de `sales` de la operación que pertenecen a cuentas del usuario (`FOR UPDATE`, en orden ascendente de `id` — ver "Exclusión de la promoción contra la edición y el borrado"), y validar la **tenencia**: si no hay ninguna fila del usuario (operación inexistente, ajena o `p_operation_id NULL`) SHALL fallar con `P0404 operation_not_found` **sin tomar locks sobre filas de otra cuenta**; si alguna fila de la operación pertenece a OTRA cuenta SHALL fallar con `P0404` (fail-closed); si no hay permiso de escritura (`is_account_writer(account_id)` falso) SHALL fallar con `P0401`.
- (b) Tomar la cabecera (`account_id`, `branch_id`, `client_id`) de la **primera fila por `id`** — determinístico. NO SHALL agregar a ciegas identificadores (`MIN(uuid)` no existe en Postgres y, aunque existiera, elegiría un cliente arbitrario). El cliente y la sucursal SHALL ser **homogéneos** entre TODAS las filas (`NULL` cuenta como valor): si no lo son SHALL fallar con `P0422 operation_inconsistent`, sin crear la orden.
- (c) Resolver la branch efectiva como `COALESCE(branch_id de la cabecera, c26_default_branch(account_id))`; si no hay branch resoluble SHALL fallar con `P0422 no_branch_found`.
- (d) Insertar una fila en `sales_orders` con `account_id`, `branch_id`, `client_id`, `status = 'confirmed'`, `sale_operation_id = p_operation_id`, `fiscal_document_id = NULL`, `created_by = auth.uid()`. La orden SHALL nacer **sin forma de pago imputada** (`payment_method_id = NULL`): la forma de pago de una venta legacy cargada a mano es genuinamente desconocida y NO SHALL inventarse una etiqueta por defecto.
- (e) Fijar el importe por la **cabecera**: `total = round(Σ COALESCE(sales.total, sales.amount × sales.quantity), 2)` y **una línea de `sales_order_items` por fila de `sales`** (`quantity`, `price = amount`, `subtotal = total` de la fila), de modo que `Σ subtotales = total` siempre. De `sale_items` SHALL tomarse sólo producto, unidad y snapshots, de UNA fila por venta (la del producto de la fila si existe): el importe NO SHALL salir de un `JOIN` a `sale_items`, que duplica filas cuando hay `sale_items` repetidos. Las líneas de servicio (`product_id IS NULL`) SHALL promoverse sin error. El cálculo de total, cliente, sucursal y líneas SHALL vivir en un único helper interno (`_sales_order_sync_from_operation`), compartido con la edición.
- (f) Devolver `{sales_order_id, sale_operation_id, replayed}`.

La RPC SHALL ser idempotente por `sale_operation_id` (ver requisito "Idempotencia de la promoción legacy"). Toda la escritura de `sales_orders` / `sales_order_items` SHALL ocurrir vía la RPC `SECURITY DEFINER` (la RLS de esas tablas no admite INSERT directo del rol `authenticated`); el helper interno SHALL ser `SECURITY INVOKER` y NO SHALL ser ejecutable por `anon` ni `authenticated`.

#### Scenario: promoción exitosa materializa una SalesOrder confirmada

- **GIVEN** una venta legacy con `operation_id = OP`, `branch_id = B` y dos filas: un producto 500 × 2 y un servicio sin producto 150 × 1
- **WHEN** se invoca `rpc_promote_legacy_sale_to_order(OP)`
- **THEN** se crea exactamente una fila en `sales_orders` con `status = 'confirmed'`, `sale_operation_id = OP`, `branch_id = B`, `payment_method_id = NULL`, `fiscal_document_id = NULL` y `total = 1150.00`
- **AND** existen 2 filas en `sales_order_items`, una por fila de `sales`, cuya suma de subtotales es `1150.00`, y la de servicio con `product_id NULL`
- **AND** no cambió `branch_stock`, `stock_movements`, `cash_movements`, `events`, `customer_account_movements` ni `document_status_history` de la cuenta

#### Scenario: la promoción no inventa una forma de pago

- **GIVEN** una venta legacy cargada a mano sin forma de pago conocida
- **WHEN** se la promueve a `SalesOrder`
- **THEN** la orden resultante queda con `payment_method_id = NULL` y se muestra como "Sin especificar", en vez de aparecer imputada a una forma de pago que el usuario nunca eligió

#### Scenario: la promoción ejecuta de verdad (sin min(uuid))

- **WHEN** se invoca `rpc_promote_legacy_sale_to_order` sobre cualquier venta legacy propia
- **THEN** la RPC NO aborta con `42883 function min(uuid) does not exist` y devuelve una orden

#### Scenario: filas con distinto cliente o sucursal se rechazan

- **GIVEN** una operación cuyas filas tienen distinto `client_id` (o mezclan un cliente con `NULL`), o distinta sucursal
- **WHEN** se la promueve
- **THEN** la RPC falla con `P0422 operation_inconsistent` y no queda ninguna `sales_orders` para esa operación

#### Scenario: una fila de otra cuenta en la operación es fail-closed

- **GIVEN** una operación con una fila del usuario y otra fila de OTRA cuenta con el mismo `operation_id`
- **WHEN** el usuario la promueve
- **THEN** la RPC falla con `P0404` y no crea ninguna orden

#### Scenario: sale_items duplicados no duplican el importe

- **GIVEN** una fila de `sales` de 500 × 2 con dos `sale_items` asociados
- **WHEN** se la promueve
- **THEN** la orden queda con `total = 1000.00` (no 2000) y una sola línea, con los snapshots del `sale_item` del producto

<!--
NOTA (corrección al archivar): este delta originalmente traía una sección
"## REMOVED Requirements" para "payment_method credit es aceptado por el
CHECK", pero esa entrada no correspondía a un Requirement propio del spec
principal — era un `#### Scenario` dentro de "Agregado SalesOrder con
líneas" (ver openspec/specs/sales-order/spec.md). El openspec CLI abortó el
archive ("REMOVED failed... not found") porque REMOVED exige matchear un
header de Requirement real. El propio "Reason" original ya lo decía: "Era
un escenario del agregado SalesOrder". Se retira esta sección — el
escenario desaparece igual, de forma implícita, porque el MODIFIED de
arriba reemplaza el texto COMPLETO de "Agregado SalesOrder con líneas" y
ya no lo incluye. Contenido del Reason/Migration originales preservado acá
para que no se pierda el razonamiento:
  Reason: Era un escenario del agregado SalesOrder que gateaba el dominio
  del CHECK sales_orders_payment_method_check. Ese CHECK desaparece junto
  con la columna sales_orders.payment_method, por lo que el escenario ya
  no describe ningún comportamiento observable. El invariante equivalente
  que sigue vivo —que credit es un kind admitido— lo cubre
  payment_methods_kind_check en la capability payment-method.
  Migration: Una venta a cuenta corriente se expresa imputando una forma
  de pago de kind='credit' del catálogo (payment_method_id), no
  escribiendo el literal 'credit' en la orden. El comportamiento de
  negocio asociado (cargo en CustomerAccount, exigencia de client_id)
  sigue especificado en "SalesOrder.confirm() es transaccional y atómico".
-->

### Requirement: Idempotencia de la promoción legacy

El sistema SHALL garantizar la unicidad de la `SalesOrder` materializada por operación legacy mediante un índice único parcial `CREATE UNIQUE INDEX ... ON public.sales_orders (sale_operation_id) WHERE sale_operation_id IS NOT NULL`. La RPC `rpc_promote_legacy_sale_to_order` SHALL, **bajo el lock de las filas de `sales` de la operación**, buscar una `sales_orders` existente con ese `sale_operation_id` **y de la cuenta del caller** (tomándola `FOR UPDATE`) y, si existe, devolverla con `replayed = true` sin crear una nueva. Una orden de OTRA cuenta para esa operación (el índice único es global) SHALL responderse con `P0404 operation_not_found`, sin devolver, nombrar ni tocar esa orden. En ese *replay* SHALL **re-sincronizar** la orden (total, cliente, sucursal y líneas, con el mismo helper que la creación) sólo si NO tiene comprobante vivo: ALLOW-LIST cerrada — sin comprobante, o comprobante `rejected` o `voided`; cualquier otro estado (incluido uno desconocido o una FK colgada) SHALL dejar la orden intacta. El índice parcial SHALL además impedir que el hot path POS (que también persiste `sale_operation_id`) y la promoción colisionen sobre la misma operación legacy; el manejo de `unique_violation` SHALL conservarse como red y devolver la orden existente **de la cuenta del caller** (si la que choca es de otra cuenta, `P0404`).

#### Scenario: tres promociones de la misma operación devuelven la misma orden

- **WHEN** se invoca `rpc_promote_legacy_sale_to_order(OP)` tres veces
- **THEN** existe una sola `sales_orders` con `sale_operation_id = OP`, la segunda y la tercera llamada devuelven el mismo `sales_order_id` con `replayed = true`, y las líneas no se duplican

#### Scenario: el replay re-sincroniza una orden desactualizada sin comprobante vivo

- **GIVEN** una orden promovida sin comprobante cuyo total ya no coincide con Σ `sales.total` de su operación
- **WHEN** el usuario vuelve a tocar "Facturar" (replay de la promoción)
- **THEN** la orden queda con el total, cliente y líneas de su venta y la emisión posterior funciona

#### Scenario: el replay no toca una orden con comprobante vivo

- **GIVEN** una orden cuyo comprobante está `pending_cae` o `authorized`
- **WHEN** se promueve otra vez la operación
- **THEN** la RPC devuelve la orden con `replayed = true` y su total, líneas y `fiscal_document_id` quedan sin cambios

#### Scenario: el replay no devuelve ni nombra la orden de otra cuenta

- **GIVEN** una operación de la cuenta A con su orden (facturada o no) y una fila de la cuenta B con el mismo `operation_id`
- **WHEN** un usuario de B promueve esa operación
- **THEN** la RPC falla con `P0404 operation_not_found`, el mensaje no contiene el id de la orden de A, la orden de A queda intacta y no se crea ninguna orden de B

#### Scenario: las líneas suman el total también con filas de más de 2 decimales

- **GIVEN** una operación con tres filas de `sales.total = 0,335`
- **WHEN** se promueve
- **THEN** la orden queda con `total = 1,01` y sus líneas en 0,34 + 0,34 + 0,33 (cada una a 2 decimales, el residuo del redondeo en la última fila por `id`), de modo que `Σ subtotales = total`

#### Scenario: el índice único parcial impide dos órdenes para la misma operación

- **GIVEN** una `sales_orders` con `sale_operation_id = OP`
- **WHEN** se intenta insertar una segunda `sales_orders` con `sale_operation_id = OP`
- **THEN** la base rechaza el INSERT por violación de unicidad (la RPC absorbe ese caso devolviendo la orden existente)

#### Scenario: las órdenes sin operación legacy no se ven afectadas por el índice

- **GIVEN** múltiples `sales_orders` con `sale_operation_id IS NULL` (p.ej. órdenes en `draft` desde `Quote.accept()`)
- **WHEN** coexisten en la cuenta
- **THEN** el índice parcial las permite todas (solo indexa filas con `sale_operation_id IS NOT NULL`)

## ADDED Requirements

### Requirement: Exclusión de la promoción contra la edición y el borrado

El sistema SHALL excluir entre sí la promoción de una venta legacy, su edición y su borrado anclando la exclusión en las **filas de `sales` de la operación** — lo único que existe antes de la orden —, tomadas `FOR UPDATE` en orden ascendente de `id` como PRIMER lock de las tres rutas. El orden global de locks SHALL ser único: `sales` (id ascendente) → `sales_orders` → `fiscal_documents` → resto. La emisión (`rpc_emit_sale_invoice`) NO SHALL tomar locks sobre `sales` (sólo leerla): tomarla después de `sales_orders` invertiría el orden y abriría un deadlock con la edición. Ningún interleaving de promoción, edición, borrado y emisión SHALL dejar un comprobante `pending_cae` cuyo total difiera de Σ `sales.total` de la operación de su orden, o cuya orden apunte a una operación sin filas, ni SHALL terminar en `40P01`.

#### Scenario: la edición espera a una promoción en curso y ve la orden

- **GIVEN** una promoción que ya tomó las filas de la operación y creó la orden sin commitear
- **WHEN** el usuario edita esa venta
- **THEN** la edición espera, ve la orden commiteada, la re-apunta y la recalcula, y la emisión posterior sale por el importe editado

#### Scenario: el borrado espera a una promoción en curso y cancela la orden

- **GIVEN** una promoción en curso sobre la operación
- **WHEN** el usuario borra la venta
- **THEN** el borrado espera, cancela la orden (`canceled`, `sale_operation_id NULL`) y la emisión posterior falla con `P0400 order_not_confirmed`, sin comprobantes

#### Scenario: la promoción espera a una edición o borrado en curso

- **GIVEN** una edición o un borrado que ya tomó las filas de la operación
- **WHEN** se promueve la operación
- **THEN** la promoción espera y, al commitear el otro, no encuentra filas y falla con `P0404`, sin crear ninguna orden ni comprobante

#### Scenario: una promoción en replay frenada en la orden no se cruza con la edición

- **GIVEN** una orden promovida que una emisión en curso tiene tomada
- **WHEN** se vuelve a promover la operación y, a la vez, se edita la venta
- **THEN** la promoción toma primero las filas de `sales` y espera la orden, la edición espera las filas, ninguna termina en `40P01`, y al final la orden queda re-apuntada y recalculada por la edición

#### Scenario: el orden de locks está candado en cada PR

- **WHEN** una migración futura reescribe la promoción, la edición, el borrado o la emisión
- **THEN** el gate SQL de CI (no sólo el chequeo embebido en la migración, que corre una vez) verifica sobre el cuerpo vivo que las tres rutas toman las filas de `sales` antes de mencionar `sales_orders`/`fiscal_documents`, que la edición y el borrado recuentan bajo el lock, y que la emisión y el helper nunca toman `sales`

#### Scenario: una promoción de otra cuenta no bloquea filas ajenas

- **WHEN** un usuario de otra cuenta promueve la operación
- **THEN** la RPC falla con `P0404` y ninguna fila de la cuenta dueña queda bloqueada

### Requirement: Facturar una venta cargada a mano desde el listado de ventas

El listado de `/ventas` SHALL permitir facturar una venta cargada a mano sin comprobante en dos pasos visibles desde la fila expandida: **"Facturar"** prepara la venta (`POST /sales/{operation_id}/promote-to-order`) y el segundo paso se llama **"Emitir comprobante"** (`POST /sales-orders/{id}/emit-invoice`). La fila SHALL pasar sola, sin recargar, a "En trámite (esperando CAE)" con el número del comprobante y, cuando el relay lo autoriza, a "Autorizado por AFIP" (Realtime) con el texto lateral "Comprobante enviado a ARCA". Si la emisión falla, la fila SHALL volver a "Facturar". Los errores SHALL mostrarse con textos accionables en castellano rioplatense y el texto crudo de Postgres NO SHALL llegar nunca al usuario. El endpoint de promoción SHALL rechazar con `422` un `operation_id` que no sea un uuid, sin tocar la base, y un error de base sin mapear SHALL responder un `500` genérico problem+json.

#### Scenario: de punta a punta hasta Autorizado

- **GIVEN** una venta cargada a mano de $2469 sin comprobante, en una cuenta monotributista en homologación con un punto de venta activo
- **WHEN** el usuario toca "Facturar" y después "Emitir comprobante", y corre el relay del CAE
- **THEN** la fila muestra "En trámite (esperando CAE)" con un número `PPPP-NNNNNNNN` y después "Autorizado por AFIP" con el mismo número, y el comprobante queda `authorized` por $2469

#### Scenario: la emisión rechazada por una orden desactualizada devuelve la fila a Facturar

- **WHEN** la emisión responde `409 sales_order_out_of_sync`
- **THEN** el toast dice "La venta cambió después de prepararla para facturar. Tocá «Facturar» de nuevo para actualizarla." y la fila vuelve a mostrar "Facturar"

#### Scenario: la preparación rechazada por filas heterogéneas se explica

- **WHEN** la promoción responde `409 operation_inconsistent`
- **THEN** el toast dice "Esta venta tiene ítems con distinto cliente o sucursal. Editala para unificarlos y después facturala." y no aparece "Emitir comprobante"

#### Scenario: el texto de Postgres no llega al usuario

- **WHEN** la base levanta un error sin mapear durante la promoción
- **THEN** el backend responde 500 problem+json genérico con `code = internal_error` y el toast muestra "No pudimos preparar la venta para facturar. Probá de nuevo en unos minutos."

#### Scenario: el texto de Postgres tampoco llega al usuario al emitir

- **WHEN** la emisión responde un 500 cuyo detalle es el texto del motor ("Error de base de datos: …") o el 500 genérico
- **THEN** el toast muestra "No pudimos emitir el comprobante. Probá de nuevo en unos minutos." y nunca el texto del motor
