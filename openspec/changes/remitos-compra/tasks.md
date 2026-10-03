> **Governance MEDIA con un tramo ALTO.**
> - La **tanda A** (grupos 1–5) crea el remito de compra, **escribe el ledger de stock** en tres caminos nuevos (recepción, edición y anulación) y reescribe helpers y RPCs que `remitos-venta` acaba de mergear.
> - La **tanda B** (grupos 6–7) **extrae el núcleo de la compra** (caja, banco, cuenta corriente del proveedor), reescribe el borrado y la edición de compras y suma la conversión.
> - Cada tanda lleva checkpoint de cuerpo vivo, gate con matriz de evasión y revisión adversarial antes del merge.
>
> **Dos PRs**, A y luego B, cada uno con CI verde (incluido `validate-kpis`). La tanda A **no empieza** hasta que `remitos-venta` tanda A (PR #612, `20261069000001`) esté mergeada y en prod (lo está desde el 2026-10-03; se re-confirma en 0.2).
>
> **TDD estricto**: cada grupo abre con su RED (un test que falla por la razón correcta) antes de escribir producción, con evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR; nunca a `main`. Nunca `--no-verify`.
> - Toda función se reescribe desde su `pg_get_functiondef` **vivo** (comparado por líneas sin `\r`), conservando el `COMMENT` (o su ausencia) y re-asertando la ACL.
> - Se prefiere `CREATE OR REPLACE` con la misma firma; `DROP`+`CREATE` resetea las ACLs y deja overloads vivos con la reaplicación de CI (`42725`).
> - Todo repositorio filtra por `account_id` de forma explícita.
> - Números de migración: **el siguiente libre** al momento de cada apply.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [ ] 0.1 **[PO]** Sign-off de OQ-RC1..OQ-RC10 (`design.md` §Open Questions). R1–R8 ya están firmadas (§"Sign-off del PO").
  - Registrar la respuesta textual en `design.md` antes de escribir producción.
  - Sin respuesta, el apply adopta la recomendación de cada OQ (default declarado).
  - Si el PO elige una alternativa, actualizar en el mismo PR la decisión, las specs y estas tareas.
- [ ] 0.2 Re-confirmar que `remitos-venta` tanda A sigue aplicada en prod (en la ronda 1: `MAX(version) = 20261069000001`, `delivery_notes` existe, catálogo con 24 filas). Anotar si la tanda B de venta y el PR #607 ya mergearon (coordinación de D15).
- [ ] 0.3 Elegir el número de migración de la tanda A: `ls supabase/migrations`, `gh pr list --state open` y `MAX(version)` de prod. Tomar el siguiente libre y anotarlo acá. Repetir para la tanda B en 6.0.
- [ ] 0.4 **Checkpoint de cuerpo vivo, tanda A.** Leer de prod `pg_get_functiondef`, `obj_description` y ACL de:
  - `_delivery_note_assert_role(uuid, text)`, `_delivery_note_apply_stock`, `_delivery_note_reverse_held`, `_delivery_note_payload`;
  - `rpc_update_delivery_note`, `rpc_cancel_delivery_note`;
  - los `CHECK` vivos `internal_document_sequences_document_type_check`, `document_status_history_document_type_check`, `document_status_transitions_document_type_check` y `operation_idempotency_operation_kind_check`.

  Comparar por líneas, sin `\r`, contra `20261069000001` y contra la última migración que los haya redefinido (la tanda B de venta reescribe `_delivery_note_payload`). Si difieren, partir del vivo y anotar el desvío. Guardar los cuerpos previos en `evidence/` para el rollback.
- [ ] 0.5 Re-medir en prod (SELECT) lo que afirma `design.md` §"Medido en prod": compras con y sin proveedor y sucursal, formas de pago, proveedores con teléfono, `CHECK (quantity >= 0)` de `branch_stock`, disparadores de `purchases`, filas `delivery_note_purchase` (0). Grep de **lectores** de `stock_movements.type = 'purchase'` en `backend/`, `frontend/`, `supabase/functions/` y `pg_proc.prosrc` de prod: confirmar que ninguno asume "`type = 'purchase'` ⇒ fila en `purchases`" (D4; la ronda 1 hizo el grep de código, falta `pg_proc.prosrc`). Si algo cambió, actualizar el design en el mismo PR.
- [ ] 0.6 **Safety net**: correr y registrar el baseline de:
  - backend `-m "not integration"` + integración;
  - vitest completo y `tsc`;
  - los gates SQL de `KPI_Validation.yml` sobre `db reset` limpio, en especial `test_remitos_venta.sql`, `test_purchase_cash_optin.sql`, `test_purchase_delete_cash_compensation.sql`, `test_compras_proveedor_cuenta_corriente.sql`, `test_stock_movements_edicion.sql`, `test_delete_guard_ledgers.sql`, `test_edicion_preserva_contexto.sql`, `test_document_status_transition_role_matrix.sql` y `test_function_acl_gate.sql`.

  Un pre-existente en rojo se reporta y no se corrige acá.

## 1. DB tanda A: remito de compra, stock y helpers por sentido + gate

- [ ] 1.1 **RED**: `supabase/tests/test_remitos_compra.sql` con fixtures propios (dos cuentas; owner, admin, stock, purchases, seller y cashier reales), cleanup asertado y los bloques de emisión de §D16. Debe fallar con `42883 rpc_create_purchase_delivery_note does not exist`.
- [ ] 1.2 Migración, parte de **modelo y catálogo**:
  - `CHECK` ampliados **por agregado al vivo** (bloque `DO` que lee `pg_get_constraintdef` y sólo hace `DROP` + `ADD` si falta el valor, con la lista viva más el nuevo; nunca una lista fija, D16): `internal_document_sequences` (`delivery_note_purchase`), los dos de FSM (`delivery_note_purchase`) y `operation_idempotency.operation_kind` (`delivery_note_purchase`);
  - filas `NULL → issued` (`{stock, admin, owner}`) e `issued → canceled` (`{admin, owner}`, con motivo, terminal) de `delivery_note_purchase`, idempotentes;
  - disparadores gemelos con `WHEN (… direction = 'purchase')`: número (`trg_assign_internal_document_number('delivery_note_purchase')`), creación (`trg_delivery_note_record_creation('delivery_note_purchase')`) y enforcement (`trg_enforce_status_transition('delivery_note_purchase')`). Los de venta no se tocan.
- [ ] 1.3 **Helpers por sentido desde el cuerpo vivo** (D4, D7), con la misma firma:
  - RED primero en el gate: con un remito de compra insertado como `postgres`, `_delivery_note_apply_stock` resta (hoy) en lugar de sumar;
  - `_delivery_note_apply_stock` y `_delivery_note_reverse_held` leen `direction` del remito: en compra, la aplicación suma sin gate (`purchase`) y la reversa resta con gate `P0409 delivery_note_stock_consumed` (`purchase_return`); en venta, sin cambios;
  - `_delivery_note_assert_role_dir(uuid, text, text)` nueva, **con nombre propio** (sin overload, D7), parametrizada por sentido; `_delivery_note_assert_role(uuid, text)` delega con `'sale'`;
  - `_delivery_note_payload` suma `supplier_name`, `supplier_phone`, `supplier_deleted` y `missing_price_count`.
- [ ] 1.4 **Núcleo de edición** (D5): RED primero, el **cambio de sucursal con cantidades iguales** en los dos sentidos (stock por sucursal y remito en Y). Extraer `_delivery_note_replace_content(p_dn_id, p_branch_id, p_items) RETURNS jsonb` desde el cuerpo vivo de `rpc_update_delivery_note`, **en el orden vivo**: el helper fija `delivery_notes.branch_id` entre el `DELETE` y el `INSERT` de las líneas, antes de recalcular lo retenido nuevo, y devuelve `v_valid`; en compra, chequeo del neto por par antes de cualquier pata (mensaje con el stock previo y lo que se resta); patas que suman primero. Cada RPC hace después su `UPDATE` de cabecera, total y `revision`. Reescribir `rpc_update_delivery_note` desde su cuerpo vivo para llamarlo; diff adjunto en `evidence/` (el único cambio de forma es el `UPDATE` partido en dos). `test_remitos_venta.sql` tiene que seguir verde **sin tocarlo**.
- [ ] 1.5 RPCs públicas (`SECURITY DEFINER`, `REVOKE … FROM PUBLIC, anon`, `GRANT EXECUTE … TO authenticated`, `COMMENT`):
  - `rpc_create_purchase_delivery_note` (D4: DEC-06 con `delivery_note_purchase`, cuenta del proveedor, rol, proveedor y sucursal, subtotales y total del servidor, lock de productos antes de validar, inserción, aplicación);
  - `rpc_update_purchase_delivery_note` (D5: lock con `direction = 'purchase'`, rol, estado, versión, proveedor vivo, sucursal vigente y nueva, subtotales del servidor, núcleo de edición);
  - `rpc_cancel_delivery_note` desde el cuerpo vivo, para los dos sentidos (D6): rol, historial y textos por sentido; la reversa con gate en compra.
- [ ] 1.6 GREEN emisión → **TRIANGULATE** hasta cubrir cada bloque del gate de la tanda A (§D16): rechazos con cero efectos, precio 0 admitido, subtotal falso ignorado, idempotencia, roles, edición (sólo precio, un solo producto que cambia, **bajar con mercadería vendida por el POS: a 8 funciona y a 5 da `P0409 delivery_note_stock_consumed`**, subir, cambio de producto, cambio de sucursal con cantidades iguales (stock por sucursal en los dos sentidos) y con la vieja sin toda la mercadería, texto del error de faltante sobre el neto, snapshot acarreado, producto dado de baja, sucursal desactivada, versión vieja, anulado, remito de venta por la RPC de compra), anulación (motivo, roles, con mercadería, **con parte vendida → `P0409` sin efectos**, segunda anulación, sucursal desactivada), invariante Σ delta = Δ stock, fila forjada en el ledger, PostgREST sin escritura directa, baja de sucursal con remito de compra pendiente (`P0428`) y guards de unidad.
- [ ] 1.7 Bloque `DO` de introspección al final de la migración (§D16): `CHECK` con el valor nuevo **y** todos los previos, disparadores gemelos y de venta intactos, catálogo `delivery_note_purchase` validado **por presencia** de las dos filas de la tanda A con sus atributos (nunca por conteo), una definición por función reescrita o nueva, ACLs, cuerpos (helpers leen `direction`, `rpc_update_delivery_note` llama al núcleo, `rpc_cancel_delivery_note` sin el filtro de venta, `_delivery_note_assert_role` delega en `_delivery_note_assert_role_dir`). Reaplicar la migración dos veces sin error, y una vez más sobre un estado con un valor extra agregado a los `CHECK` (no lo borra).
- [ ] 1.8 Actualizar `test_document_status_transition_role_matrix.sql` (catálogo, llamadores, pares producidos) y `test_function_acl_gate.sql` (funciones nuevas; helpers `_*` en el chequeo (4)). Parametrizar `test_internal_document_numbering_race.sh` con `delivery_note_purchase` (N sesiones → 1..N sin huecos), extendiéndolo sin duplicarlo.
- [ ] 1.9 **CI** (D16): re-medir el paso de reaplicación de `20261069000001` en el workflow vivo (en `main` está en `KPI_Validation.yml:1209-1252`).
  - Retirarlo en este mismo PR (sus `CHECK` de lista fija abortan con `23514` ante las filas `delivery_note_purchase` y su introspección es incompatible con esta tanda), dejando en su lugar: `supabase db reset` de reconvergencia después de los reapply de `20261062000001`…`20261068000001`, reaplicación de la migración de compra sin tolerancia, chequeo `RV_BODIES` heredado más los cuerpos de 1.7, y diff de schema. Comentario con la regla para el PR siguiente.
  - Medir el costo del `db reset` extra; si es inaceptable, documentar y usar la alternativa (migración de reconvergencia de los cuatro cuerpos).
  - Si la tanda B de venta ya cambió ese paso, re-evaluar contra lo vivo y anotarlo.
  - Cablear `test_remitos_compra.sql` en el orden real del workflow. Re-ejecutar `test_remitos_venta.sql` y los gates de compras de 0.6 sin tocarlos.

## 2. Backend tanda A (3 capas)

- [ ] 2.1 **RED**: `backend/tests/test_delivery_notes_module.py` (unit) y `..._integration.py` (Postgres real) con casos de compra: unión discriminada por `direction` (`PurchaseDeliveryNoteCreateIn`, topes, `supplier_reference` ≤ 100), `POST /delivery-notes` de compra con y sin `Idempotency-Key`, `PUT` con el sentido equivocado → `409 delivery_note_direction_mismatch`, cancelación de un remito de compra, mapeo RFC 7807 de cada literal nuevo, 404 cross-tenant idéntico al inexistente, capacidades por rol.
- [ ] 2.2 `core/rbac.py`: `CAN_RECEIVE_PURCHASE = {owner, admin, stock}` (con el comentario de por qué va con nombre propio aunque coincida con `CAN_STOCK`, D12) y `CAN_CONVERT_PURCHASE_DELIVERY_NOTE = {owner, admin, purchases, stock}` (OQ-RC6), más el test que lee las migraciones y falla si `CAN_RECEIVE_PURCHASE`, `CAN_VOID_DELIVERY_NOTE` y `CAN_CONVERT_PURCHASE_DELIVERY_NOTE` divergen de los `allowed_role` de `delivery_note_purchase` (molde de `TestCanQuote`). El caso de conversión entra en la tanda B, cuando existe su fila.
- [ ] 2.3 Schemas, repositorio (búsqueda por nombre del proveedor y `supplier_reference`, filtro `supplier_id`, `account_id` explícito), service (guards por sentido) y router (despacho por `direction`).
- [ ] 2.4 Listado con `direction=purchase`: búsqueda `RC-…`, resumen de pendientes de compra (cantidad, total y cuántos tienen alguna línea sin precio), `missing_price_count` por ítem. `DeliveryNoteOut` reutiliza `supplier_id`, `supplier_reference` y `converted_operation_id` (ya existen) y suma sólo `supplier_name`, `supplier_phone`, `supplier_deleted` y `missing_price_count`.
- [ ] 2.5 TRIANGULATE: ≥ 2 casos por comportamiento (rol × operación, cada error tipado, cada formato de búsqueda). Cobertura ≥ 87 % sin bajar la global.

## 3. PDF y numeración (tanda A)

- [ ] 3.1 **RED**: `backend/tests/test_commercial_document_pdf.py` suma casos de remito de compra leídos con `pypdf`: "REMITO DE COMPRA", `RC-…`, "Recibido de" con el proveedor y su número de remito, "Ingresa a", cantidades con unidad, bloque de firma, "no válido como factura", sin precios por defecto y con ellos con `show_prices`, sello "ANULADO". Los casos de presupuesto y de remito de venta siguen verdes sin tocarlos.
- [ ] 3.2 `build_delivery_note_view` parametrizada por `direction` y nombre de archivo `remito-compra-RC-….pdf` (`-con-precios`).
- [ ] 3.3 Prefijo `RC` en `services/commercial_documents/numbering.py` y en `frontend/lib/internal-document-number.ts` (`PREFIX_BY_TYPE`, `QUERY_PATTERN_BY_TYPE`, `formatDeliveryNoteNumber` deja de devolver el número sin prefijo), con casos nuevos en el fixture compartido `internal_document_number_cases.json` (pytest y vitest leen el mismo).

## 4. Frontend tanda A: datos, componentes compartidos y helpers

- [ ] 4.1 **RED**: tests de hooks de remitos de compra (`useDeliveryNotes({ direction: "purchase" })`, alta con `useIdempotencyKey("delivery-note-purchase-create")`, edición, anulación; invalidación de `deliveryNotes.*`, `branchStock` y `products`).
- [ ] 4.2 Tipos del contrato de compra en `lib/delivery-note-types.ts` y hooks en `hooks/data/use-delivery-notes.ts` (extendidos, sin gemelos).
- [ ] 4.3 **`components/suppliers/SupplierSelect.tsx`** extraído de `purchase-form.tsx` (selector buscable + alta inline que queda seleccionada), con la prop `askPhone` (default `false`) que suma un teléfono opcional al alta inline. RED: test del componente (con y sin `askPhone`); `purchase-form.tsx` pasa a usarlo sin la prop y su test sigue verde sin tocarlo.
- [ ] 4.4 `lib/rbac-capabilities.ts`: `CAN_RECEIVE_PURCHASE` y `CAN_CONVERT_PURCHASE_DELIVERY_NOTE`, con el test de contrato contra el backend y la FSM.
- [ ] 4.5 `lib/operation-errors.ts`: traducciones accionables de los literales de D11 (un caso por literal), incluido `delivery_note_locked_converted` según el sentido y `supplier_not_found` en contexto remito (los del borrado de compra y del puente se suman en 7.7).
- [ ] 4.6 Funciones puras con tests (D11):
  - `lib/delivery-note-share.ts`: texto de compra con número del proveedor y `deliveryNoteFileName(direction, numberLabel, showPrices)` → `remito-compra-RC-…(-con-precios).pdf` en compra (hoy `remito-RC-…`), referenciado por el detalle;
  - `lib/delivery-note-status.ts`: acciones por estado, rol y sentido (incluido el motivo de "Compra" deshabilitada por precio faltante o proveedor dado de baja) y `DELIVERY_NOTE_STATUS_LABELS[direction]` ("Convertido en compra");
  - **tabla de textos por sentido** de D11 (detalle, avisos, `describeEmitNotice`, `describeRemovalReturn`/`describeHeldReturn`, `validateDeliveryNoteDraft`, anulación, `DeactivateBranchDialog`), un caso por texto;
  - `lib/delivery-note-stock.ts`: mínimo por producto en la edición de compra `max(0, aportado − stock vigente)`, con texto que no atribuye origen, casos con stock mayor que lo aportado y con cambio de sucursal (la vieja con menos que todo lo aportado); resumen del ajuste ("Entran … · Salen …");
  - `deliveryNoteListHref(direction)` para el regreso al listado.

## 5. Pantallas tanda A

- [ ] 5.1 **RED**: `__tests__/components/DeliveryNoteForm.test.tsx` suma casos de compra: proveedor obligatorio con alta inline (con teléfono opcional), número del proveedor, sin domicilio, sucursal "Ingresa a" visible en todos los planes, **alta manual y escaneo que precargan el costo y no el precio de venta** (costo nulo → 0 con aviso "Sin precio", "Cat." contra el costo, sin descuento), precio vacío con aviso, sin control de faltante en el alta, mínimo por producto en la edición, resumen del ajuste, proveedor dado de baja congelado. Los casos de venta siguen verdes sin tocarlos.
- [ ] 5.2 `DeliveryNoteForm` gana la prop `direction` (default `"sale"`); en compra compone `SupplierSelect` con `askPhone` (4.3). `StagedProductLine`, `addManualLineToCart` y `applyScanToCart` ganan `priceSource: "price" | "cost"` (default `"price"`, retrocompatible; sus tests de venta siguen verdes sin tocarlos). Si algo se repite entre sentidos, se extrae a `components/shared/` o `lib/`.
- [ ] 5.3 `CancelDeliveryNoteDialog` por sentido: en compra enumera lo que sale del stock, toast y placeholder propios, y, ante `delivery_note_stock_consumed`, muestra el disponible con "Editar el remito" y "Ajustar stock". `DeliveryNoteStatusBadge` recibe `direction`.
- [ ] 5.4 `/remitos`: pestañas **De venta** / **De compra** (`?sentido=`), columnas de compra, badge "Sin precio" por fila o tarjeta, búsqueda por proveedor, `RC-…` y número del proveedor, resumen de pendientes de compra (con "N sin precio"), CTA por `CAN_RECEIVE_PURCHASE`, estado vacío propio, `?proveedor=` como chip removible. Test de página que entra con `?sentido=compra&estado=pendientes&proveedor=<id>`.
- [ ] 5.5 `/remitos/nuevo?tipo=compra` (`?proveedor=`) y `/remitos/[id]/editar` de compra, con los estados de página de `DocumentPageStates` (sin `CAN_RECEIVE_PURCHASE`, no encontrado, convertido con enlace a la compra, anulado con motivo) y regreso a `/remitos?sentido=compra` con `deliveryNoteListHref`.
- [ ] 5.6 `/remitos/[id]` de compra: cabecera con proveedor y número del proveedor (rótulo "Ingresa a"), textos de estado por sentido, matriz estado × rol de D11, `DocumentShareMenu` con "Mostrar precios" al teléfono del proveedor y archivo `remito-compra-RC-…`, aviso "Agregá el teléfono del proveedor…" con enlace a `/proveedores` si no tiene, "Volver al listado" a `/remitos?sentido=compra`, historial con motivo. En la tanda A, "Compra" no se muestra.
- [ ] 5.7 Proveedores: acción "Nuevo remito de compra" por fila en `/proveedores` y botones "Nuevo remito" / "Ver remitos" en `/proveedores/[id]/cuenta`, con test y verificación a 375 px (sin desborde, `aria-label` distintos en botones de ícono).
- [ ] 5.8 `DeactivateBranchDialog`: un enlace por sentido con remitos pendientes (`&sentido=venta` / `&sentido=compra`) y el texto de cada sentido, con test con pendientes de venta, de compra y de ambos.
- [ ] 5.9 Panel de `/stock`: casos de test de filas y CSV con `type = 'purchase'`/`'purchase_return'` y `reference_type` `delivery_note*` que rotulan "Remito RC-…", "Edición de remito RC-…" y "Anulación de remito RC-…" con el ícono de entrada o salida. La lógica no cambia (el formato por sentido ya existe).

## 6. Tanda B: DB — núcleo de compra, conversión, borrado y edición

- [ ] 6.0 Número de migración de la tanda B (siguiente libre). `grep -n "REGLA PARA EL PR SIGUIENTE" .github/workflows/KPI_Validation.yml`: anotar si el bloque de reaplicación de `20261062000001` sigue en el workflow (la tanda B de venta o el #607 pueden haberlo retirado).
- [ ] 6.1 **Checkpoint de cuerpo vivo, tanda B**, inmediatamente antes de escribir. Leer de prod `pg_get_functiondef`, `obj_description` y ACL de `rpc_create_purchase_operation` (11 parámetros, hoy sin `COMMENT`), `rpc_delete_purchase_operation(uuid, uuid, text)`, `rpc_atomic_update_purchase_operation(...)` (12 parámetros) y `_delivery_note_payload`. Comparar `md5(prosrc)` sin `\r` contra los del propose (`0366977251522a469d123c4d143f42f9`, `368120a0d7c5453b32fbd39f095bc9c3`, `23558c073cf71d08ea4a0dfb15079555`, medidos el 2026-10-03). Si difieren, partir del vivo y anotar el desvío. Guardar los cuerpos previos en `evidence/`.
- [ ] 6.2 **RED**: `supabase/tests/test_remito_a_compra.sql` con la matriz de evasión de §D16 (debe fallar con `42883 rpc_convert_delivery_note_to_purchase does not exist`). Incluye:
  - el **control negativo**: aplicada la columna (6.3) pero **antes** de extraer el núcleo (6.4), el bloque "compra con origen de remito no suma" tiene que fallar, porque la compra viva suma igual. Es la prueba de que el gate detecta la doble suma;
  - la **integridad del puente** por PostgREST con un `seller` real (forjar, limpiar, cambiar el origen; `INSERT` con origen; `DELETE` de una fila con origen) → `P0403 delivery_note_source_protected`, con su control positivo sobre una compra directa; y un origen apuntado como `postgres` a un remito de otra cuenta, que el borrado rechaza sin reabrirlo;
  - la **equivalencia de la compra directa**: una compra registrada antes y después de la extracción produce las mismas filas, movimientos, caja, banco, cargo y evento.
- [ ] 6.3 `purchases.source_delivery_note_id` (FK `NO ACTION`) + índice parcial + **`trg_purchases_guard_delivery_note_source`** (D9: rechaza para `anon`/`authenticated` el `INSERT` con origen, el `UPDATE` que cambia la columna y el `DELETE` de filas con origen; verificar que las cascadas de FK y las RPC definer no lo disparan) + las filas `issued → converted` (`{purchases, stock, admin, owner}`, OQ-RC6) y `converted → issued` (sistema) de `delivery_note_purchase`.
- [ ] 6.4 **`_purchase_operation_core`** extraído del cuerpo vivo (D8), sin `EXECUTE` para `anon`/`authenticated`, con el modo remito (revalidación del origen, `p_items` nulo, líneas leídas del remito, salto del bloque de producto y de stock, snapshots del remito, origen persistido). `rpc_create_purchase_operation` queda como wrapper con la misma firma y ACL. **El diff contra el cuerpo vivo tiene que ser sólo la extracción y la rama de origen**: adjuntarlo en `evidence/`.
- [ ] 6.5 `rpc_convert_delivery_note_to_purchase` (D8): lock del origen, rol `convert`, idempotencia bajo lock, estado, versión, proveedor vivo, sucursal activa, precios > 0, fecha no anterior al remito, núcleo, `RAISE` ante replay ajeno, transición `issued → converted`.
- [ ] 6.6 `rpc_delete_purchase_operation` desde el cuerpo vivo (D9): con origen, **antes** de cualquier compensación, lock del remito (`account_id` + `direction = 'purchase'`, `FOR UPDATE`), re-lectura de las filas de la operación bajo ese lock (si ya no existen, termina sin efectos) y `status = 'converted'` exigido; rol `void` del remito de compra (`P0403 delivery_note_purchase_delete_forbidden`) y sucursal del remito viva (`FOR SHARE`, `P0422`); salto explícito de la reversa de stock; vuelta del remito a `issued` con el lock tomado desde el principio (historial con motivo). `COMMENT` vivo re-declarado y ACL idéntica.
- [ ] 6.7 `rpc_atomic_update_purchase_operation` desde el cuerpo vivo (D9): `P0423 delivery_note_purchase_locked` después del chequeo de existencia y **antes** de los tres `P0423` de dinero.
- [ ] 6.8 `_delivery_note_payload` desde el cuerpo vivo: completa el campo genérico existente `converted_operation_id` en compra (derivado de `purchases.source_delivery_note_id` con `account_id`); sin campo paralelo.
- [ ] 6.9 GREEN → **TRIANGULATE** hasta cubrir toda la matriz de la tanda B: `cash`/`credit`/`transfer`; stock idéntico; 0 movimientos propios; snapshots del remito con producto renombrado; total igual; precio 0; proveedor dado de baja; sucursal desactivada o cerrada; fecha anterior; replay; conflicto de clave; segunda conversión; versión vieja; roles (`stock` y `purchases` convierten, `seller`/`cashier` no); caja sin sesión o con otra fecha; los orígenes inválidos contra el núcleo; borrado (dinero, stock, remito, reconversión, rol con su literal, sucursal desactivada, origen de otra cuenta); integridad del puente; edición bloqueada sin efectos; anulación de un convertido; regresión del `P0423` de dinero de una compra directa y de los gates de compras.
- [ ] 6.10 `supabase/tests/test_remitos_compra_race.sh` (molde de `test_presupuesto_a_venta_race.sh`) con las carreras de §D16, incluidas **anulación contra una venta del POS** que consume la última unidad recibida (nunca stock negativo ni `23514`), **dos borrados concurrentes de la misma compra de remito** y **borrado viejo contra reconversión** (también a crédito, sin `40P01`). Las que no dependen de la conversión se pueden adelantar a la tanda A.
- [ ] 6.11 Introspección de la tanda B (una definición por función, ACL igual a la previa en las tres reescritas, núcleo sin `authenticated`, cuerpos con la rama, el salto, el lock del remito antes de las compensaciones, el guard y el `P0423`; disparador del puente presente; las dos filas de la tanda B por presencia) + reaplicación doble, con su paso propio en la cadena **después** del de la tanda A y del último de `remitos-venta`. Actualizar `test_document_status_transition_role_matrix.sql` y `test_function_acl_gate.sql` (núcleo en el chequeo (4)). Cablear en `KPI_Validation.yml`. **Si el bloque de reaplicación de `20261062000001` sigue en el workflow (6.0), retirarlo en este mismo PR** y anotar que su control pasa a `test_remito_a_compra.sql` + la introspección; si ya lo retiró otro PR, anotarlo acá.

## 7. Tanda B: backend y frontend de la conversión

- [ ] 7.1 **RED** backend: `POST /delivery-notes/{id}/convert-to-purchase` con `require_idempotency_key`, `PurchaseDeliveryNoteConvertIn`/`Out`, mapeo de errores (incluidos `delivery_note_purchase_delete_forbidden` y `delivery_note_source_protected`), read model de compras con `source_delivery_note_id`/`source_delivery_note_number`/`source_delivery_note_branch_active` (`JOIN` con `account_id`, mismo predicado de sucursal que el borrado) y el motivo de no edición; capacidad de conversión con `stock`; integración contra Postgres real.
- [ ] 7.2 Implementación backend.
- [ ] 7.3 **`components/compras/PurchaseCheckoutFields.tsx`** extraído de `purchase-form.tsx` (forma de pago, cuenta bancaria, opt-in de caja con `useCashOptin`, fecha, centro de costo, saldo del proveedor) con las props `showDueDate` y `paymentRequired` (D11). El vencimiento sale de la cascada del plazo **extraída** de `sale-form.tsx` a un hook compartido (`useDueDateCascade`), sin copiarla; `sale-form` pasa a usarlo y su test sigue verde. RED: test del componente (vencimiento con crédito, sin "Sin especificar" y "Convertir" deshabilitado sin forma de pago con `paymentRequired`); `purchase-form.tsx` pasa a usarlo sin las props y su test sigue verde sin tocarlo.
- [ ] 7.4 **RED** frontend: `__tests__/components/ConvertPurchaseDeliveryNoteDialog.test.tsx` (proveedor y sucursal fijos, forma de pago con banco, efectivo con y sin caja, crédito con saldo, fecha anterior al remito, éxito y replay, `delivery_note_changed` que recarga sin cerrar, errores accionables, foco al título de éxito).
- [ ] 7.5 `ConvertPurchaseDeliveryNoteDialog` compone `PurchaseCheckoutFields` (`showDueDate`, `paymentRequired`) + `useConvertPurchaseDeliveryNote` (`useIdempotencyKey("delivery-note-purchase-convert:" + id)`, reset en cada éxito, invalidación con `invalidateAfterPurchaseCreate` extraída en `lib/query-invalidation.ts` desde el conjunto vigente de `addPurchaseOperation` —compras, productos, cuentas corrientes de proveedores, **`payables`**, caja— más banco y `deliveryNotes.*`; el alta de compra pasa a usarla; test de hook que asserta `payables`), con la línea fija "El stock ya se sumó al recibir el remito RC-…". **Cáscara compartida**: si `ConvertDeliveryNoteDialog` (venta) ya existe en `main`, extraer `components/shared/ConvertDocumentDialogShell.tsx` con los tres consumidores (Regla de Tres); si no, dejarlo anotado para la tanda B de venta.
- [ ] 7.6 Detalle del remito de compra: acción "Compra" (`CAN_CONVERT_PURCHASE_DELIVERY_NOTE`, sólo `issued`, deshabilitada con motivo si falta un precio o el proveedor fue dado de baja). Estado `converted` con "Ver compra".
- [ ] 7.7 `/compras` (D11), con tests de lista:
  - badge "Desde remito RC-…" con `SourceDocumentBadge` (si la tanda B de venta no lo generalizó todavía, generalizar acá `SourceQuoteBadge`, sin gemelo);
  - "Editar" deshabilitado con el motivo de remito, con precedencia sobre `PAYMENT_LOCKED_REASON`;
  - diálogo de borrado con `reversesStock: !op.source_delivery_note_id` y la línea de D9 sólo con origen (caso: con origen no aparece la frase de reversa de stock);
  - "Eliminar" deshabilitado con su motivo si el usuario no tiene `CAN_VOID_DELIVERY_NOTE` o si `source_delivery_note_branch_active = false`;
  - traducciones de `delivery_note_purchase_delete_forbidden`, `delivery_note_branch_inactive` (contexto compra) y `delivery_note_source_protected`.
- [ ] 7.8 Invalidación tras borrar una compra: `invalidateAfterPurchaseDelete` en `lib/query-invalidation.ts` (el conjunto vigente del borrado, `payables` incluido, más `deliveryNotes.all()`), usada por las mutaciones de borrado de compras. RED: test de hook que asserta la invalidación de remitos y de `payables`.
- [ ] 7.9 **Aviso contra la doble suma** (D11): en `purchase-form.tsx`, al elegir un proveedor con remitos de compra pendientes, el aviso con enlace a `/remitos?sentido=compra&estado=pendientes&proveedor=<id>`; en el flujo de Factura IA (`InvoiceAIButton`), si la cuenta tiene remitos de compra pendientes, el mismo aviso antes de confirmar. Reutiliza `useDeliveryNotes({ direction: "purchase", status: "issued" })` (sin hook gemelo). RED: un test por camino (con y sin pendientes); no bloquea el guardado.

## 8. Verificación

- [ ] 8.1 Suites completas por tanda: backend `-m "not integration"` con cobertura ≥ 87 % + integración; vitest completo; `tsc` sin errores nuevos contra el baseline; todos los gates de `KPI_Validation.yml` sobre `db reset` limpio, en el orden real del workflow. Explicar cualquier diferencia contra el baseline de 0.6.
- [ ] 8.2 **Verificación visual, 4 combinaciones** (desktop y 375 px × claro y oscuro) de `/remitos` (pestaña De compra), `/remitos/nuevo?tipo=compra`, `/remitos/[id]` de compra (los 3 estados), `/remitos/[id]/editar` de compra, `CancelDeliveryNoteDialog` de compra (con y sin rechazo por mercadería consumida), las acciones de `/proveedores` y de su cuenta corriente, `DeactivateBranchDialog` con pendientes de los dos sentidos, las filas `RC-…` del panel de `/stock` y, en B, `ConvertPurchaseDeliveryNoteDialog`, el badge y el diálogo de borrado de `/compras`, y `purchase-form.tsx` (sin cambios visibles tras las dos extracciones). Medir desbordes horizontales (0 propios), contraste (gate `token-contrast-aa`) y CTA visible en móvil. Capturas en `evidence/visual/`.
- [ ] 8.3 **Humo local** con el stack completo, leyendo el stock **en la base** después de cada paso:
  - **A**: recibir → el stock sube en `/stock` con el rótulo `RC-…` → editar (subir, bajar, cargar precios, cambiar sucursal) → PDF con y sin precios → WhatsApp (escritorio y emulación móvil) → vender parte por el POS → intentar anular (rechazo explicado) → reducir a lo vendido y anular el resto; baja de sucursal bloqueada con un remito de compra pendiente;
  - **B**: convertir en efectivo y a crédito → el stock no cambia → badge en `/compras` → cargo en la cuenta corriente del proveedor → borrar la compra → el remito vuelve a pendiente y el stock no cambia → reconvertir; una compra directa en paralelo sigue sumando stock.
- [ ] 8.4 **Red-team** contra el stack local (GoTrue + PostgREST + FastAPI + Postgres), molde de `presupuestos-modulo/evidence/redteam/`:
  - escritura directa por PostgREST sobre las tablas, los helpers y `_purchase_operation_core`;
  - `rpc_create_purchase_operation` con cualquier intento de pasar un origen (no hay parámetro: control de que la firma no lo admite);
  - fila forjada en `stock_movements` contra un remito de compra pendiente, seguida de anulación y de edición: lo restado es sólo lo aportado por las líneas;
  - doble `POST /delivery-notes` de compra con la misma clave;
  - remito ajeno por cada endpoint; remito de venta por las rutas de compra;
  - `seller` convirtiendo y recibiendo, `purchases` anulando y borrando la compra de un remito (control: `stock` y `purchases` convierten);
  - `purchases.source_delivery_note_id` por PostgREST: forjar el origen en una compra directa, limpiarlo en una compra de remito, apuntarlo a otro remito, `INSERT` con origen y `DELETE` directo de las filas con origen;
  - conversión con clave reutilizada; edición de una compra de remito por la API.

  Cada ataque con su control positivo. Script versionado.
- [ ] 8.5 **Revisión adversarial** (un juez por ronda, regla de presupuesto de agentes) antes de cada merge. Foco: doble suma, stock negativo, reversa indebida en el borrado, autoridad del borrado que reabre el remito, regresión del remito de venta por los helpers compartidos, equivalencia de la compra directa tras la extracción, orden de locks, y el diff de cada función contra su cuerpo vivo. Corregir y re-verificar.

## 9. Documentación

- [ ] 9.1 `CHANGES.md`:
  - ficha del change, con los hallazgos;
  - el orden de locks (`delivery_notes` primero en la conversión a compra, al final en el borrado de la compra) junto a la regla global;
  - candidatos que deja, cada uno con su motivo:
    - `CAN_PURCHASE` definido y no exigido en `/compras` (cualquier escritor registra compras);
    - el chequeo por usuario del producto en la compra directa y en su edición (`v_product.user_id <> v_uid`), que rompería las compras en cuentas con varios miembros;
    - `rpc_delete_purchase_operation` sin guard de rol ni lock de filas;
    - actualización de `products.cost` y costeo por compra o por lote;
    - devoluciones a proveedor como documento propio;
    - orden de compra formal (pedido → recepción);
    - remitos de compra parciales y varios remitos → una compra;
    - KPI de mercadería recibida sin comprar en el Tablero;
    - las alternativas de OQ-RC que el PO no eligió;
    - OCR del remito del proveedor desde la foto, partiendo de la Edge Function `invoice-ocr` existente (sin duplicarla), y la conversión "factura OCR → remito pendiente";
    - vencimiento en el formulario de compra directa (la RPC lo acepta y el hook de cascada ya queda extraído);
    - remito legal "R" con CAI o remito electrónico de ARCA (R1);
    - link público y envío por email del remito;
    - importador CSV de remitos;
  - la coordinación con `remitos-venta` tanda B y con #607.
- [ ] 9.2 KB: `knowledge-base/04_modelo_de_datos.md` (`purchases.source_delivery_note_id`, sentido compra de `delivery_notes`), `05_reglas_de_negocio.md` (regla del remito de compra: suma al recibir, edición con faltante sobre el neto, anulación bloqueada si se consumió, conversión sin doble suma, compra inmutable, borrado que reabre), `06_funcionalidades.md` y `07_flujos_principales.md` (flujo de recepción → compra).
- [ ] 9.3 Puntero del `CLAUDE.md`: **no se edita en este change** (instrucción del workflow). Se anota en `CHANGES.md` que el ítem del roadmap se actualiza en el archive, con `python scripts/ci/check_docs_sync.py --fix` en ese PR.

## 10. Post-merge (por tanda)

- [ ] 10.1 **Tanda A**: verificar `GET /deploys` de Render (disparar si falta) y el deploy de Vercel; SELECT en prod: `MAX(version)`, `CHECK` con `delivery_note_purchase` (secuencia, dos de FSM, `operation_idempotency`), disparadores gemelos, las dos filas de la tanda A de `delivery_note_purchase` presentes, ACLs, una definición de cada función reescrita, cuerpos de los helpers por sentido.
- [ ] 10.2 **Tanda A**, humo del PO en prod: recibir, editar (cargar precios, bajar una cantidad), compartir con y sin precios, anular; stock en `/stock`.
- [ ] 10.3 **Tanda B**: SELECT en prod: columna, índice y disparador del puente, catálogo `delivery_note_purchase` con 4 filas, núcleo sin `authenticated`, wrapper con la ACL previa, cuerpos con la rama de origen, el salto y el `P0423`; control: las compras directas de las últimas horas siguen teniendo su movimiento `purchase/purchase`.
- [ ] 10.4 **Tanda B**, humo del PO en prod: remito → Compra (efectivo y crédito) → el stock no vuelve a subir → badge → cuenta corriente del proveedor → borrar la compra → remito pendiente → reconvertir.
- [ ] 10.5 Archive: `openspec archive remitos-compra` **después** de `remitos-venta` (crea la capability `delivery-note`, a la que este change le suma requirements). Commitear entre archives si comparten capability; verificar en **HEAD** que los requirements de las 10 capabilities quedaron (gotchas de archive: CRLF, líneas en blanco, dos deltas sobre la misma capability). Los `MODIFIED` de `inventory-single-ledger`, `operation-delete-compensation` y `delivery-note` parten del texto que deja `remitos-venta`: **diffear** el resultado contra los dos deltas (el segundo archive pisa al primero sin que el conteo lo delate).

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| | | | | | | | |
