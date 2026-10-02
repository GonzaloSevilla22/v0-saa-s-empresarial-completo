> **Governance MEDIA con un tramo ALTO.**
> - La **tanda A** (grupos 1–5) crea el documento y **escribe el ledger de stock** en tres caminos nuevos (emisión, edición y anulación). También reescribe tres guards vivos: unidad base, unidad en uso y baja de sucursal.
> - La **tanda B** (grupos 6–7) reescribe el **núcleo de confirmación de venta** (`_c29_confirm_order_core`, que comparten el POS y la conversión de presupuestos), el borrado y la edición de ventas, y suma la conversión.
> - Cada tanda lleva checkpoint de cuerpo vivo, gate con matriz de evasión y revisión adversarial antes del merge.
>
> **Dos PRs**, A y luego B, cada uno con CI verde (incluido `validate-kpis`). La tanda B espera a que esté mergeada la tanda B de `presupuestos-modulo` (`20261068000001`, `SaleCheckoutFields`/`SaleCheckoutSuccess`).
>
> **TDD estricto**: cada grupo abre con su RED (un test que falla por la razón correcta) antes de escribir producción, con evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR; nunca a `main`. Nunca `--no-verify`.
> - Toda función se reescribe desde su `pg_get_functiondef` **vivo** (comparado por líneas sin `\r`), conservando el `COMMENT`.
> - `DROP`+`CREATE` resetea las ACLs: se re-declaran en el mismo archivo. Se prefiere `CREATE OR REPLACE` con la misma firma.
> - Todo repositorio filtra por `account_id` de forma explícita.
> - Números de migración: **el siguiente libre ≥ `20261069000001`** al momento de cada apply.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [ ] 0.1 **[PO]** Sign-off de OQ-RV1..OQ-RV13 (`design.md` §Open Questions). R1–R8 ya están firmadas (§"Sign-off del PO").
  - Registrar la respuesta textual en `design.md` antes de escribir producción.
  - Sin respuesta, el apply adopta la recomendación de cada OQ (default declarado).
  - Si el PO elige una alternativa, actualizar en el mismo PR la decisión, las specs y estas tareas.
- [ ] 0.2 Elegir el número de migración de la tanda A: `ls supabase/migrations`, `gh pr list --state open` (incluidos #607 y la tanda B de presupuestos) y `MAX(version)` de prod. Tomar el siguiente libre ≥ `20261069000001` y anotarlo acá. Repetir para la tanda B en 6.0.
- [ ] 0.3 **Checkpoint de cuerpo vivo, tanda A.** Leer de prod `pg_get_functiondef`, `obj_description` y ACL de:
  - `fn_product_base_unit_guard()`;
  - `fn_uom_in_use_guard()`;
  - `fn_guard_branch_decommission()`;
  - `_quote_validate_items(uuid, jsonb)`.
  
  Compararlos por líneas, sin `\r`, contra `20261062000001` (los dos de unidades), `20261014000001` y `20261067000001`. Si difieren, partir del vivo y anotar el desvío acá. Guardar los cuerpos previos en `evidence/` para el rollback.
- [ ] 0.4 Re-medir en prod (SELECT):
  - los `CHECK` de `stock_movements.type`/`reference_type`, `document_status_*.document_type` e `internal_document_sequences.document_type`;
  - que siguen en 0 las tablas, funciones y columnas `delivery`/`remito`;
  - el tamaño del catálogo de transiciones (filas totales, con rol, llamadores);
  - productos `untracked` (hoy 0).
  
  Comparar con `design.md` §"Medido en prod". Si algo cambió, actualizar el design en el mismo PR.
- [ ] 0.5 Grep de **lectores** de `stock_movements.type` y de `reference_type` en `backend/`, `frontend/`, `supabase/functions/` y las funciones vivas (`pg_proc.prosrc`). Confirmar que ninguno asume "`type = 'sale'` ⇒ fila en `sales`" y anotar la lista. Si apareciera uno, rediseñar con `type` propios antes de seguir (D4).
- [ ] 0.6 **Safety net**: correr y registrar el baseline de:
  - backend: `-m "not integration"` + integración;
  - vitest completo y `tsc`;
  - los gates SQL de `KPI_Validation.yml` sobre `db reset` limpio, en especial `test_presupuestos_modulo.sql`, `test_ventas_unidades_conversion.sql`, `test_sucursal_guard_vaciado_auditoria.sql`, `test_document_status_transition_role_matrix.sql` y `test_function_acl_gate.sql`.
  
  Un pre-existente en rojo se reporta y no se corrige acá.

## 1. DB tanda A: migración del documento, stock y guards + gate

- [ ] 1.1 **RED**: `supabase/tests/test_remitos_venta.sql` con:
  - fixtures propios: dos cuentas y los roles owner, admin, seller, stock y cashier reales (molde de `test_document_status_transition_role_matrix.sql`);
  - cleanup asertado;
  - los bloques de emisión del design §D16.
  
  Debe fallar con `42883 rpc_create_sale_delivery_note does not exist`.
- [ ] 1.2 Migración, parte de **modelo**:
  - `delivery_notes` y `delivery_note_items` con sus `CHECK`, índices, `UNIQUE (account_id, direction, number)` y RLS sólo de `SELECT` (sin `anon`) (D1);
  - `CHECK` ampliados de forma aditiva e idempotente: `internal_document_sequences` (`delivery_note_sale`), los dos de FSM (`delivery_note`) y `stock_movements.reference_type` (`delivery_note`, `delivery_note_update`, `delivery_note_reversal`).
- [ ] 1.3 Migración, parte de **FSM y numeración**:
  - las filas `NULL → issued` y `issued → canceled` del catálogo (D3), idempotentes;
  - disparadores `delivery_notes_assign_number_sale` (genérico con `WHEN (NEW.direction = 'sale')`, D2), de creación (`trg_delivery_note_record_creation`) y de enforcement (`trg_enforce_status_transition('delivery_note')`).
- [ ] 1.4 Extraer `_assert_document_product(uuid, uuid)` y reescribir `_quote_validate_items` **desde el cuerpo vivo de 0.3** para que lo llame, sin otro cambio (D12). `test_presupuestos_modulo.sql` tiene que seguir verde **sin tocarlo**.
- [ ] 1.5 Helpers internos (sin `authenticated`):
  - `_delivery_note_assert_role(uuid, text)` con los modos `issue`/`void`/`convert`;
  - `_delivery_note_validate_items`;
  - `_delivery_note_insert_items` (snapshots filtrados por cuenta, acarreo por producto en edición, D6);
  - `_delivery_note_apply_stock` (lock de productos por id, normalización después del lock, gate por par con el literal `stock_insuficiente`, delta + movimiento `sale`/`delivery_note`);
  - `_delivery_note_reverse_held` (neto retenido leído del ledger);
  - `_delivery_note_payload`.
- [ ] 1.6 RPCs públicas (`SECURITY DEFINER`, `REVOKE … FROM PUBLIC, anon`, `GRANT EXECUTE … TO authenticated`, `COMMENT`): `rpc_create_sale_delivery_note`, `rpc_update_delivery_note` (D5: espejo sólo en los pares que cambian, faltante sobre el neto, revisión) y `rpc_cancel_delivery_note` (D16: rol `void`, motivo, contramovimiento `delivery_note_reversal`, historial).
- [ ] 1.7 GREEN emisión → **TRIANGULATE** hasta cubrir cada bloque del gate de la tanda A (§D16):
  - rechazos con su código y cero efectos;
  - edición (sólo precio sin movimientos, aumento, faltante sobre el neto, reducción con 0, cambio de producto, cambio de sucursal, snapshot acarreado, versión vieja, anulado);
  - anulación (motivo, roles, reposición, segunda anulación);
  - invariante Σ delta = Δ stock y neto 0 tras anular;
  - PostgREST sin escritura directa;
  - roles (cashier no emite; stock emite y edita pero no anula).
- [ ] 1.8 Guards de unidad **desde el cuerpo vivo** (D14): `fn_product_base_unit_guard` suma `delivery_note_items` a su `UNION` de líneas y `fn_uom_in_use_guard` a su `OR EXISTS`. RED antes: en el gate, una línea de remito en Gramo **no** traba asignar Kilogramo (debe fallar); después, `P0409 base_unit_locked` y `unit_in_use`.
- [ ] 1.9 `fn_guard_branch_decommission` **desde el cuerpo vivo** (D10): cuarta condición, remitos `issued` de la sucursal → `P0428`, con el mensaje que nombra cantidad y acción. RED en el gate: la baja con un remito pendiente hoy se acepta. Después, `P0428`; anulado el remito, la baja procede. Re-ejecutar `test_sucursal_guard_vaciado_auditoria.sql`.
- [ ] 1.10 Bloque `DO` de introspección al final de la migración:
  - tablas, `CHECK`, índice único y disparadores;
  - cero políticas de escritura;
  - ACLs;
  - una definición por función reescrita;
  - el cuerpo de `_quote_validate_items` llama al helper;
  - los guards nombran `delivery_note_items`;
  - catálogo `delivery_note` con 2 filas.
  
  Reaplicar la migración dos veces sin error (idempotencia del auto-apply).
- [ ] 1.11 Actualizar `test_document_status_transition_role_matrix.sql` (tamaño del catálogo, filas con rol, llamadores de `record_status_transition` y pares producidos) y `test_function_acl_gate.sql` (clasificación de las funciones nuevas; helpers `_*` cubiertos por el chequeo (4)).
- [ ] 1.12 Reutilizar `test_internal_document_numbering_race.sh` parametrizado por tipo para `delivery_note_sale` (N sesiones emiten el primer remito de una cuenta → 1..N sin huecos). Si el script no admite parámetro, extenderlo sin duplicarlo.
- [ ] 1.13 Cablear `test_remitos_venta.sql` y la carrera en `KPI_Validation.yml`, en el orden real del workflow, y sumar la migración a la cadena de reaplicación.

## 2. Backend tanda A (3 capas)

- [ ] 2.1 **RED**: `backend/tests/test_delivery_notes_module.py` (unit con dobles) + `test_delivery_notes_module_integration.py` (Postgres real) con:
  - schemas (`direction: Literal["sale"]`, topes, `product_id` obligatorio);
  - endpoints `GET/POST /delivery-notes`, `GET/PUT /delivery-notes/{id}` y `POST /delivery-notes/{id}/cancel`;
  - mapeo RFC 7807 de cada literal SQL;
  - 404 cross-tenant idéntico al inexistente;
  - capacidades por rol.
- [ ] 2.2 `core/rbac.py`: `CAN_DELIVER_SALE` y `CAN_VOID_DELIVERY_NOTE` (D13), más el test que lee las migraciones y falla si divergen de los `allowed_role` de `delivery_note` (molde de `TestCanQuote`). Verificar que `is_sensitive_capability(CAN_VOID_DELIVERY_NOTE)` es verdadero y documentarlo en el comentario.
- [ ] 2.3 `schemas/delivery_notes.py`, `repositories/delivery_note_repository.py` (todo por RPC o `SELECT` con `account_id` explícito), `services/delivery_notes.py` y `routers/delivery_notes.py`. Registrar el router.
- [ ] 2.4 Listado paginado `{items,total,page,pages}` con filtros `status`, `q` (cliente o número `R-…`), `client_id` y `direction=sale`, más el resumen de pendientes (cantidad y total).
- [ ] 2.5 `product_repository._GROUP_HAS_LINES_IN_OTHER_UNIT_SQL` suma `delivery_note_items` (D14), con un caso de test que hoy pasa en falso (RED) y después traba.
- [ ] 2.6 Read model del kardex (`stock_repository.list_movements` o el endpoint que alimenta el panel): devolver el número del remito para los movimientos `delivery_note*` (JOIN con `account_id`).
- [ ] 2.7 TRIANGULATE: ≥ 2 casos por comportamiento (cada rol × cada operación, cada error tipado, cada formato de búsqueda). Cobertura ≥ 87 % sin bajar la global.

## 3. PDF del remito (tanda A)

- [ ] 3.1 **RED**: `backend/tests/test_commercial_document_pdf.py` suma casos de remito leídos con `pypdf`:
  - "REMITO", el número, la sucursal de origen, las cantidades con su unidad, el bloque de firma y "no válido como factura";
  - **sin** precios ni total por defecto, y **con** ellos con `show_prices`;
  - sello "ANULADO";
  - 80 líneas con la firma sin partirse.
- [ ] 3.2 `CommercialDocumentView` suma `signature_block` y `origin_label` con defaults retrocompatibles. El render los dibuja. `build_delivery_note_view` es pura, en `services/commercial_documents/view.py`. Los casos de presupuesto existentes tienen que seguir verdes sin tocarlos.
- [ ] 3.3 `GET /delivery-notes/{id}/pdf?disposition=&show_prices=`: 200 en todo estado, 404 ajeno o inexistente, 422 en parámetros inválidos, 401 sin sesión, nombre `remito-R-….pdf`. El emisor sale de `rpc_commercial_issuer` (sin cambios).
- [ ] 3.4 Numeración visible: prefijo `R` en `numbering.py` y en `frontend/lib/internal-document-number.ts`, con casos nuevos en el fixture compartido `internal_document_number_cases.json` (pytest y vitest leen el mismo).

## 4. Frontend tanda A: datos, helpers y hooks

- [ ] 4.1 **RED**: `__tests__/hooks/use-delivery-notes.test.tsx` con `useDeliveryNotes(filters)`, `useDeliveryNote(id)`, `useCreateDeliveryNote`, `useUpdateDeliveryNote` y `useCancelDeliveryNote`. Las mutaciones invalidan `deliveryNotes.*`, `branchStock`, `products` y el kardex.
- [ ] 4.2 `hooks/data/use-delivery-notes.ts` + tipos del contrato en `lib/delivery-note-types.ts` + claves en `lib/query-keys.ts`.
- [ ] 4.3 `lib/delivery-note-share.ts` (`buildDeliveryNoteShareText`) y `lib/delivery-note-status.ts` (rótulos y acciones por estado y rol, funciones puras), con tests.
- [ ] 4.4 `lib/rbac-capabilities.ts`: `CAN_DELIVER_SALE`, `CAN_VOID_DELIVERY_NOTE` y `CAN_SELL`, más el test de contrato contra el backend y la FSM.
- [ ] 4.5 `lib/operation-errors.ts`: traducciones accionables de los literales de D11, un caso por literal.
- [ ] 4.6 Checkpoint de la fuente de stock por sucursal: leer qué usa hoy `sale-form.tsx` (después del #606) para el disponible de la sucursal elegida y reutilizarlo (`useBranchStock(branchId)` o el que corresponda). Anotar la decisión acá.

## 5. Pantallas tanda A

- [ ] 5.1 **RED**: `__tests__/components/DeliveryNoteForm.test.tsx`. Casos:
  - alta con stock suficiente; bloqueo al superar el stock **de la sucursal elegida** (con el de otra sucursal mayor);
  - cambio de sucursal que recalcula el disponible;
  - edición: las líneas `persisted` suman lo retenido y, al cambiar de sucursal, lo dejan de sumar;
  - sin "Agregar concepto";
  - balanza y código de barras;
  - cliente nuevo en el lugar;
  - domicilio precargado;
  - `delivery_note_changed` con recarga;
  - producto no disponible bloquea el guardado.
- [ ] 5.2 `components/delivery-notes/DeliveryNoteForm.tsx`, compuesto con `ProductPicker`, `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput`, `StagedProductLine` y `lib/cart-utils` (`enforceStock: true`). Sin copiar lógica de `QuoteForm`: si algo se repite, se extrae a `components/shared/` o `lib/`.
- [ ] 5.3 `DeliveryNoteStatusBadge` (tokens semánticos, sin literales de paleta) y `CancelDeliveryNoteDialog` (motivo obligatorio, enumera lo que vuelve al stock, manda `revision`, foco y teclado).
- [ ] 5.4 `/remitos`: listado con pestañas de estado, búsqueda con debounce, paginado, tarjetas en móvil, resumen de pendientes, CTA por rol, estado vacío y filtro `?cliente=`. **Sin pestañas de sentido** (D11).
- [ ] 5.5 `/remitos/nuevo` (`?cliente=`) y `/remitos/[id]/editar`.
- [ ] 5.6 `/remitos/[id]`:
  - detalle con la matriz estado × rol de D11 y `DocumentShareMenu` con el switch "Mostrar precios" (apagado por defecto);
  - historial con motivo;
  - leyenda de "convertido";
  - en la tanda A, "Venta" no se muestra.
- [ ] 5.7 Sidebar: "Remitos" (`PackageCheck`) en *Operaciones*, después de "Presupuestos". Breadcrumb de las 4 rutas. Ajustar los tests de estructura del sidebar y del breadcrumb.
- [ ] 5.8 Ficha del cliente: "Nuevo remito" y "Ver remitos" en `ClientDetailHeader`.
- [ ] 5.9 Panel de movimientos de `/stock`: rótulos "Remito R-…", "Edición de remito R-…" y "Anulación de remito R-…" por `reference_type`, con enlace. El sentido y el ícono siguen saliendo del `type`. Test de fila.

## 6. Tanda B: DB — núcleo, conversión, borrado y edición

- [ ] 6.0 Número de migración de la tanda B (siguiente libre). Confirmar que la tanda B de presupuestos está mergeada y en prod.
- [ ] 6.1 **Checkpoint de cuerpo vivo, tanda B**, inmediatamente antes de escribir. Leer de prod `pg_get_functiondef`, `obj_description` y ACL de:
  - `_c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid)`;
  - `rpc_delete_sale_operation(uuid, uuid, text)`;
  - `rpc_atomic_update_sale_operation(...)`.
  
  Comparar por líneas sin `\r` contra `20261062000001:1118`, `20261061000001:1078` y `20261062000001:1594`. **Si el PR #607 ya mergeó, `rpc_atomic_update_sale_operation` parte de su cuerpo**: anotar el hash y el desvío. Guardar los cuerpos previos en `evidence/` para el rollback.
- [ ] 6.2 **RED**: `supabase/tests/test_remito_a_venta.sql` con la matriz de evasión del design §D16 (debe fallar con `42883 rpc_convert_delivery_note_to_sale does not exist`). Incluye:
  - el **control negativo**: aplicada la columna (6.3) pero **antes** de reescribir el núcleo (6.4), el bloque "orden con origen de remito no descuenta" tiene que fallar porque el núcleo vivo descuenta igual. Es la prueba de que el gate detecta el doble descuento;
  - la regresión de `rpc_quick_sale` (sigue descontando).
- [ ] 6.3 `sales_orders.source_delivery_note_id` + índice único parcial + las filas `issued → converted` y `converted → issued` del catálogo.
- [ ] 6.4 `_c29_confirm_order_core` desde el cuerpo vivo:
  - sólo la rama `v_from_delivery_note` de D7: revalidación del remito y de las líneas con `P0409 delivery_note_order_mismatch`; salto de normalización, gate, delta y movimiento; costo desde `sales_order_items.unit_cost_snapshot`;
  - `COMMENT` vivo re-declarado y ACL idéntica a la previa (el allowlist del chequeo (4) sigue igual);
  - **el diff contra el cuerpo vivo tiene que ser sólo esa rama**: adjuntarlo en `evidence/`.
- [ ] 6.5 `rpc_convert_delivery_note_to_sale` (D7), con el molde de `rpc_convert_quote_to_sale`: lock del origen, idempotencia bajo lock, estado, versión, cliente vivo, orden + líneas copiadas, núcleo, `RAISE` ante replay ajeno y transición `issued → converted`.
- [ ] 6.6 `rpc_delete_sale_operation` desde el cuerpo vivo (D9): salto explícito de la reversa de stock cuando la orden tiene origen de remito, y vuelta del remito a `issued` (lock después de `fiscal_documents`, historial con motivo).
- [ ] 6.7 `rpc_atomic_update_sale_operation` desde el cuerpo vivo (D9): `P0423 delivery_note_sale_locked` inmediatamente después del lock de `sales` y del guard de cliente, **antes** de la anulación fiscal.
- [ ] 6.8 GREEN → **TRIANGULATE** hasta cubrir toda la matriz del gate de la tanda B:
  - `cash`/`credit`/`transfer`;
  - stock idéntico; 0 movimientos propios; costo del remito;
  - baja de producto que convierte; cliente de baja; replay; conflicto de clave; segunda conversión; versión vieja;
  - roles; `cash` sin sesión;
  - los 7 orígenes inválidos;
  - borrado (dinero, stock, orden, remito, reconversión);
  - edición bloqueada sin anular el comprobante pendiente;
  - anulación de un convertido;
  - regresiones del POS y de `rpc_convert_quote_to_sale`.
- [ ] 6.9 `supabase/tests/test_remitos_venta_race.sh` (molde de `test_presupuesto_a_venta_race.sh`) con las 5 carreras de §D16.
- [ ] 6.10 Introspección de la tanda B (una definición por función, ACL igual a la previa en las tres reescritas, cuerpos con la rama, el salto y el `P0423`) + reaplicación doble. Actualizar `test_document_status_transition_role_matrix.sql` y `test_function_acl_gate.sql`, re-ejecutar `test_presupuesto_a_venta.sql`, `test_operacion_party_guard.sql` y los gates de venta. Cablear en `KPI_Validation.yml`.

## 7. Tanda B: backend y frontend de la conversión

- [ ] 7.1 **RED** backend:
  - `POST /delivery-notes/{id}/convert` con `require_idempotency_key`, `DeliveryNoteConvertIn`/`Out` y mapeo de errores;
  - read model de ventas y órdenes con `source_delivery_note_id`/`source_delivery_note_number` (JOIN con `account_id`) y el motivo de no edición;
  - integración contra Postgres real.
- [ ] 7.2 Implementación backend.
- [ ] 7.3 **RED** frontend: `__tests__/components/ConvertDeliveryNoteDialog.test.tsx`. Casos:
  - sucursal fija;
  - forma de pago con banco;
  - efectivo con y sin caja abierta;
  - crédito con saldo;
  - éxito y replay;
  - `delivery_note_changed`, que recarga sin cerrar;
  - errores accionables;
  - foco al título de éxito.
- [ ] 7.4 `SaleCheckoutFields`: prop aditiva `branchReadOnly`, con test de que el presupuesto sigue igual. `ConvertDeliveryNoteDialog` compone `SaleCheckoutFields` + `SaleCheckoutSuccess` + `useConvertDeliveryNote` (`useIdempotencyKey("delivery-note-convert:" + id)`, reset en cada éxito, `invalidateAfterSale` + `deliveryNotes.*`).
- [ ] 7.5 Detalle del remito: acción "Venta" (`CAN_SELL`, sólo `issued`). Estado `converted` con "Ver venta" y el comprobante.
- [ ] 7.6 `/ventas`: badge "Desde remito R-…" en el listado y el detalle (en su propia línea, como el de presupuesto). "Editar" deshabilitado con el motivo. Diálogo de borrado con la línea de D9.

## 8. Verificación

- [ ] 8.1 Suites completas por tanda:
  - backend `-m "not integration"` con cobertura ≥ 87 % + integración;
  - vitest completo; `tsc` sin errores nuevos contra el baseline;
  - todos los gates de `KPI_Validation.yml` sobre `db reset` limpio, en el orden real del workflow.
  
  Explicar cualquier diferencia contra el baseline de 0.6.
- [ ] 8.2 **Verificación visual, 4 combinaciones** (desktop y 375 px × claro y oscuro) de `/remitos`, `/remitos/nuevo`, `/remitos/[id]` (los 3 estados), `/remitos/[id]/editar`, `CancelDeliveryNoteDialog` y, en B, `ConvertDeliveryNoteDialog`, el badge y el diálogo de borrado de `/ventas`. Medir:
  - desbordes horizontales: 0 propios;
  - contraste (gate `token-contrast-aa`);
  - CTA visible en móvil.
  
  Capturas en `evidence/visual/`.
- [ ] 8.3 **Humo local** con el stack completo:
  - **A**: emitir → stock baja en `/stock` con el rótulo → editar (subir, bajar, precio, sucursal) → PDF con y sin precios → WhatsApp (escritorio y emulación móvil) → anular con motivo → stock vuelve; baja de sucursal bloqueada con un remito pendiente;
  - **B**: convertir en efectivo y a crédito → el stock no cambia → badge en `/ventas` → Facturar → borrar la venta → el remito vuelve a pendiente y el stock no cambia → reconvertir.
- [ ] 8.4 **Red-team** contra el stack local (GoTrue + PostgREST + FastAPI + Postgres), molde de `presupuestos-modulo/evidence/redteam/`:
  - escritura directa por PostgREST sobre las tablas, helpers y `sales_orders`;
  - remito ajeno por cada endpoint;
  - rol `stock` convirtiendo y `seller` anulando;
  - conversión con clave reutilizada;
  - orden fabricada contra el núcleo;
  - edición de una venta de remito por la API.
  
  Cada ataque con su control positivo. Script versionado.
- [ ] 8.5 **Revisión adversarial** (un juez por ronda, regla de presupuesto de agentes) antes de cada merge. Foco: doble descuento, reversa indebida en el borrado, orden de locks, inmutabilidad, guards de unidad evadibles, `P0428`, y el diff del núcleo contra el cuerpo vivo. Corregir y re-verificar.

## 9. Documentación

- [ ] 9.1 `CHANGES.md`:
  - ficha del change, con los hallazgos;
  - el orden de locks nuevo (`delivery_notes` primero en la conversión, al final en el borrado de la venta) junto a la regla global;
  - candidatos que deja: la RLS preexistente de `stock_movements`/`branch_stock` con escritura para `authenticated`, las alternativas de OQ-RV que el PO no eligió, devolución parcial como documento, KPI de remitos pendientes;
  - la coordinación con #607.
- [ ] 9.2 KB:
  - `knowledge-base/04_modelo_de_datos.md`: tablas y columna nuevas;
  - `05_reglas_de_negocio.md`: regla del remito (stock al emitir, edición con espejo, anulación con motivo, conversión sin doble descuento, venta inmutable, borrado que reabre);
  - `06_funcionalidades.md` y `07_flujos_principales.md`: flujo del remito.
- [ ] 9.3 Puntero del `CLAUDE.md`: **no se edita en este change** (instrucción del workflow). Se anota en `CHANGES.md` que el ítem del roadmap se actualiza en el archive, con `python scripts/ci/check_docs_sync.py --fix` en ese PR.

## 10. Post-merge (por tanda)

- [ ] 10.1 **Tanda A**:
  - verificar `GET /deploys` de Render (disparar si falta) y el deploy de Vercel;
  - SELECT en prod: `MAX(version)`, tablas, `CHECK` (los tres `reference_type`, `delivery_note_sale`, `delivery_note`), disparadores, 0 políticas de escritura, ACLs (sin `anon`; helpers sin `authenticated`), una definición de cada función reescrita, catálogo `delivery_note` con 2 filas, guards que nombran `delivery_note_items`.
- [ ] 10.2 **Tanda A**, humo del PO en prod: crear, editar, compartir con y sin precios, anular; stock en `/stock`.
- [ ] 10.3 **Tanda B**:
  - SELECT en prod: columna e índice parcial, catálogo con 4 filas, cuerpos vivos con la rama de origen, el salto y el `P0423`, ACLs iguales a las previas;
  - control: las ventas del POS de las últimas horas siguen teniendo su movimiento `sale/sale`.
- [ ] 10.4 **Tanda B**, humo del PO en prod: remito → Venta (efectivo y crédito) → el stock no vuelve a bajar → badge → Facturar → borrar la venta → remito pendiente → reconvertir.
- [ ] 10.5 Archive: `openspec archive remitos-venta` después de que `presupuestos-modulo` esté archivado (sus capabilities `internal-document-numbering` y `commercial-document-pdf` tienen que existir en `openspec/specs/`).
  - Commitear entre archives si comparten capability.
  - Verificar en **HEAD** que los requirements de las 10 capabilities quedaron (gotchas de archive: CRLF, líneas en blanco, `## Purpose` de `delivery-note`).

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| | | | | | | | |
