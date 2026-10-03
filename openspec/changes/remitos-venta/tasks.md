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

- [x] 0.1 **[PO]** Sign-off de OQ-RV1..OQ-RV13 (`design.md` §Open Questions). R1–R8 ya están firmadas (§"Sign-off del PO").
  - Registrar la respuesta textual en `design.md` antes de escribir producción.
  - Sin respuesta, el apply adopta la recomendación de cada OQ (default declarado).
  - Si el PO elige una alternativa, actualizar en el mismo PR la decisión, las specs y estas tareas.
- [x] 0.2 Elegir el número de migración de la tanda A: `ls supabase/migrations`, `gh pr list --state open` (incluidos #607 y la tanda B de presupuestos) y `MAX(version)` de prod. Tomar el siguiente libre ≥ `20261069000001` y anotarlo acá. Repetir para la tanda B en 6.0.
- [x] 0.3 **Checkpoint de cuerpo vivo, tanda A.** Leer de prod `pg_get_functiondef`, `obj_description` y ACL de:
  - `fn_product_base_unit_guard()`;
  - `fn_uom_in_use_guard()`;
  - `_branch_assert_empty(uuid)` (el punto de decisión de la baja de sucursal) y, sólo como referencia, la firma y el `RETURNS TABLE` de `_branch_blocking_content(uuid)`, que **no** se reescribe (D10); `fn_guard_branch_decommission` no se toca;
  - `_quote_validate_items(uuid, jsonb)`;
  - el `CHECK` vivo `operation_idempotency_operation_kind_check`.
  
  Compararlos por líneas, sin `\r`, contra `20261062000001` (los dos de unidades), `20261014000001` (los dos de sucursal), `20261067000001` y `20261044000001` (el `CHECK`). Si difieren, partir del vivo y anotar el desvío acá. Guardar los cuerpos previos en `evidence/` para el rollback.
- [x] 0.4 Re-medir en prod (SELECT):
  - los `CHECK` de `stock_movements.type`/`reference_type`, `document_status_*.document_type` e `internal_document_sequences.document_type`;
  - que siguen en 0 las tablas, funciones y columnas `delivery`/`remito`;
  - el tamaño del catálogo de transiciones (filas totales, con rol, llamadores);
  - productos `untracked` (hoy 0).
  
  Comparar con `design.md` §"Medido en prod". Si algo cambió, actualizar el design en el mismo PR.
- [x] 0.5 Grep de **lectores** de `stock_movements.type` y de `reference_type` en `backend/`, `frontend/`, `supabase/functions/` y las funciones vivas (`pg_proc.prosrc`). Confirmar que ninguno asume "`type = 'sale'` ⇒ fila en `sales`" y anotar la lista. Si apareciera uno, rediseñar con `type` propios antes de seguir (D4).
- [x] 0.6 **Safety net**: correr y registrar el baseline de:
  - backend: `-m "not integration"` + integración;
  - vitest completo y `tsc`;
  - los gates SQL de `KPI_Validation.yml` sobre `db reset` limpio, en especial `test_presupuestos_modulo.sql`, `test_ventas_unidades_conversion.sql`, `test_sucursal_guard_vaciado.sql`, `test_document_status_transition_role_matrix.sql` y `test_function_acl_gate.sql`.
  
  Un pre-existente en rojo se reporta y no se corrige acá.
  **Resultado del grupo 0 (apply tanda A, 2026-10-02, `main` `dad7852a`)**:
  - **0.1**: sign-off registrado en `design.md` §Sign-off del PO. R1-R8 firmadas el 2026-09-29; OQ-RV1..RV13 adoptadas por su recomendación (default declarado, informado al PO el 2026-10-02).
  - **0.2 — migración de la tanda A: `20261069000001`**. La tanda B de presupuestos (`20261068000001`) YA está en `main` y aplicada en prod (`MAX(version) = 20261068000001`, 315 migraciones). El único PR abierto (#607) no trae migraciones. Libre desde `20261069000001`.
  - **0.3**: se compararon los hashes md5 de `pg_get_functiondef` sin `
` de 20 funciones (las 6 pedidas, más `_branch_blocking_content`, `fn_guard_branch_decommission`, `_uom_normalize_quantity`, `c21_apply_branch_stock_delta`, `record_status_transition`, `trg_*`, las tres de la tanda B y `rpc_reverse_stock_movement`): **prod = base local tras `db reset`, las 20 coinciden, sin desvío**. Cuerpos previos guardados (sin `
`) en `C:/Users/Usuario/Desktop/EIE/scratchpad-remitos/prod-live/` (fuera del repo, para el rollback). ACLs vivas: helpers y `_branch_assert_empty` sin `authenticated`; `_c29_confirm_order_core`, `rpc_delete_sale_operation`, `rpc_atomic_update_sale_operation` y `rpc_reverse_stock_movement` con `authenticated`. `_assert_document_product` todavía no existe (nace en 1.4). CHECK vivo de `operation_idempotency.operation_kind`: 13 tipos, sin remito.
  - **0.4**: coincide con `design.md` §Medido en prod. CHECK de `stock_movements.type`/`reference_type`, FSM (6 tipos) y `internal_document_sequences` (`'quote'`) sin cambios. 0 tablas/funciones con `delivery`/`remito`. Catálogo de transiciones: 22 filas, 16 con rol. Productos `untracked`: 0.
  - **0.5**: ningún lector asume `type='sale'` ⇒ fila en `sales`. Código de aplicación: sólo `stock-movements-panel.tsx` (rotula por `type`, tarea 5.9), `stock_repository.list_movements` (genérico) y `product_repository._GROUP_HAS_MOVEMENTS_SQL` (existencia). Funciones vivas que leen `stock_movements`: `fn_product_base_unit_guard`, `rpc_atomic_update_purchase_operation` (compras), `rpc_atomic_update_sale_operation` y `rpc_reverse_stock_movement` (ambas por `reference_id` de `sales`, no alcanzan a un id de remito). Se confirma D4: `type` existentes, `reference_type` nuevos.
  - **0.6 safety net** (baseline focalizado de la tanda A; las suites completas van en 8.1): backend `-m "not integration"` sobre quotes, commercial documents/PDF, products, stock, rbac y unidades: **332 passed**. Frontend vitest (QuoteForm, DocumentShareMenu, CartItemList, ConvertQuoteDialog, AppSidebarGroups, nav-groups, cart-utils-lines, document-share, ClientesPage, ClienteDetailPage): **10 archivos, 285 passed**. Gates SQL sobre `db reset` limpio, todos PASS: `test_ventas_unidades_conversion` (24 avisos), `test_function_acl_gate`, `test_document_status_transition_role_matrix` (22 triples, 16 llamadores), `test_is_account_writer_pivot` (45 policies, 18 tablas), `test_presupuestos_modulo` (27 avisos), `test_sucursal_guard_vaciado` (25 avisos). Sin pre-existentes en rojo.

## 1. DB tanda A: migración del documento, stock y guards + gate

- [x] 1.1 **RED**: `supabase/tests/test_remitos_venta.sql` con:
  - fixtures propios: dos cuentas y los roles owner, admin, seller, stock y cashier reales (molde de `test_document_status_transition_role_matrix.sql`);
  - cleanup asertado;
  - los bloques de emisión del design §D16.
  
  Debe fallar con `42883 rpc_create_sale_delivery_note does not exist`.
- [x] 1.2 Migración, parte de **modelo**:
  - `delivery_notes` (incluidos `supplier_reference` con sus dos `CHECK` y el índice parcial por `supplier_id`) y `delivery_note_items` (`quantity_base NOT NULL`) con sus `CHECK`, índices, `UNIQUE (account_id, direction, number)` y RLS sólo de `SELECT` (sin `anon`) (D1);
  - `CHECK` ampliados de forma aditiva e idempotente: `internal_document_sequences` (`delivery_note_sale`), los dos de FSM (`delivery_note_sale`), `stock_movements.reference_type` (`delivery_note`, `delivery_note_update`, `delivery_note_reversal`) y `operation_idempotency.operation_kind` (`delivery_note_sale`, desde el `CHECK` vivo de 0.3).
- [x] 1.3 Migración, parte de **FSM y numeración**:
  - las filas `NULL → issued` y `issued → canceled` de `delivery_note_sale` en el catálogo (D3), idempotentes;
  - disparadores, los tres con `WHEN (NEW.direction = 'sale')`: `delivery_notes_assign_number_sale` (genérico, D2), de creación (`trg_delivery_note_record_creation`, registra `delivery_note_sale`) y de enforcement (`trg_enforce_status_transition('delivery_note_sale')`).
- [x] 1.4 Extraer `_assert_document_product(uuid, uuid)` y reescribir `_quote_validate_items` **desde el cuerpo vivo de 0.3** para que lo llame, sin otro cambio (D12). `test_presupuestos_modulo.sql` tiene que seguir verde **sin tocarlo**.
- [x] 1.5 Helpers internos (sin `authenticated`):
  - `_delivery_note_assert_role(uuid, text)` con los modos `issue`/`void`/`convert`;
  - `_delivery_note_lock_products` (`FOR UPDATE` en orden ascendente de `id`, filtrado por `account_id`; único helper de lock, lo usan emisión, edición y anulación, siempre **antes** de validar los productos, D4/D5);
  - `_delivery_note_validate_items(account, items, held)` sobre las filas ya bloqueadas: normaliza con `_uom_normalize_quantity` y devuelve las líneas con `quantity_base` y los pares requeridos. En la edición, un producto ya presente y hoy dado de baja se acepta sin revalidar el catálogo si su cantidad base requerida **total** no supera su retenido **total** (por producto, sin importar la sucursal); si lo supera, `P0400 delivery_note_product_unavailable` (D5);
  - `_delivery_note_insert_items` (snapshots filtrados por cuenta, acarreo de las **cuatro** columnas por producto en edición, D6, y el `quantity_base` ya normalizado escrito en el mismo `INSERT`, D4);
  - `_delivery_note_held_pairs(dn)`: la **única** definición de lo retenido (`Σ quantity_base` de las líneas vigentes, por producto, en la sucursal vigente), **nunca** sumando `stock_movements` (D4);
  - `_delivery_note_apply_stock(account, dn, op_group, pairs)`: **recibe** el conjunto de pares a aplicar (no lee las líneas); gate por par con el literal `stock_insuficiente`, delta + movimiento `sale`/`delivery_note`. La emisión le pasa todos los pares; la edición, sólo los que cambian;
  - `_delivery_note_reverse_held(account, dn, op_group, pairs, reference_type, reverses)`: **recibe** los pares a revertir; delta + movimiento `sale_return` con `delivery_note_update` (edición, sólo pares que cambian) o `delivery_note_reversal` (anulación, todos);
  - `_delivery_note_payload`.
- [x] 1.6 RPCs públicas (`SECURITY DEFINER`, `REVOKE … FROM PUBLIC, anon`, `GRANT EXECUTE … TO authenticated`, `COMMENT`): `rpc_create_sale_delivery_note` (D4: `p_idempotency_key` con el molde DEC-06 **exacto** de `_c29_confirm_order_core`, `20261062000001:1350-1358`: `INSERT … ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING` + `GET DIAGNOSTICS`, replay si `ROW_COUNT = 0` y el `operation_id` es un remito de venta de las cuentas del usuario, si no `P0409 idempotency_key_conflict`; orden lock de productos → validar → normalizar → insertar remito y líneas → gate → delta), `rpc_update_delivery_note` (D5: sucursal vigente y nueva vivas, lock → retenido de las líneas vigentes → validar y normalizar → pares que cambian → reversas → aplicaciones → reemplazo de líneas; faltante sobre el neto, revisión) y `rpc_cancel_delivery_note` (D16: rol `void`, motivo, sucursal viva con `P0422 delivery_note_branch_inactive`, **lock de productos antes de leer el stock**, contramovimiento `delivery_note_reversal` sobre todos los pares, historial).
- [x] 1.7 GREEN emisión → **TRIANGULATE** hasta cubrir cada bloque del gate de la tanda A (§D16):
  - rechazos con su código y cero efectos;
  - idempotencia de la emisión (misma clave → un remito y un descuento, `replayed = true`);
  - edición (sólo precio sin movimientos, **A=2/B=1 → A=2/B=3 con un solo par espejo sobre B y cero movimientos sobre A**, aumento, faltante sobre el neto, reducción con 0, cambio de producto, cambio de sucursal, snapshot acarreado con `iva_rate_snapshot`, producto dado de baja conservado/reducido/aumentado/trasladado de sucursal, sucursal vigente desactivada → `P0422`, versión vieja, anulado);
  - fila forjada en `stock_movements` por PostgREST: la anulación y la edición devuelven sólo lo que retienen las líneas;
  - anulación (motivo, roles, reposición, segunda anulación, sucursal desactivada o cerrada → `P0422 delivery_note_branch_inactive`);
  - invariante Σ delta = Δ stock y neto 0 tras anular;
  - PostgREST sin escritura directa;
  - roles (cashier no emite; stock emite y edita pero no anula).
- [x] 1.8 Guards de unidad **desde el cuerpo vivo** (D14): `fn_product_base_unit_guard` suma `delivery_note_items` a su `UNION` de líneas y `fn_uom_in_use_guard` a su `OR EXISTS`. RED antes, con fixtures creadas por la RPC real: un producto sin unidad base, con stock y una única línea de remito en **Unidad**, **no** traba asignar Kilogramo (debe fallar); una unidad de la cuenta usada sólo en un remito admite cambiar el factor (debe fallar). Después, `P0409 base_unit_locked` (y Unidad sí se asigna) y `P0409 unit_in_use`.
- [x] 1.9 Baja de sucursal **desde el cuerpo vivo** (D10), en el punto de decisión y no en el disparador:
  - `_branch_blocking_content` **no se toca** (cambiarle el `RETURNS TABLE` rompería el reapply de `20261014000001` en CI con `42P13`);
  - función nueva `_branch_pending_delivery_notes(uuid) RETURNS bigint` (interna, `STABLE`, sin `EXECUTE` para roles de aplicación): única definición del predicado, `status = 'issued'` **sin** filtrar `direction`;
  - `_branch_assert_empty` (`CREATE OR REPLACE`, misma firma, `COMMENT` y ACL conservados) suma el cuarto `IF`, después de transferencias, con el token `branch_has_pending_delivery_notes` y el mensaje neutro que nombra cantidad y acción ("convertilos o anulalos");
  - `fn_guard_branch_decommission`, `rpc_deactivate_branch` y `rpc_close_branch` no se tocan;
  - RED en el gate: la baja con un remito pendiente hoy se acepta (por el disparador y por los dos comandos). Después, `P0428` con el token; anulado el remito, la baja procede.
  - Re-ejecutar `test_sucursal_guard_vaciado.sql` sin cambios (los tres tokens previos no se mueven). `frontend/lib/database.types.ts` no cambia.
- [x] 1.10 Bloque `DO` de introspección al final de la migración:
  - tablas, `CHECK`, índice único y disparadores;
  - acciones de las FK (`account_id` `CASCADE` en las dos tablas, D1);
  - cero políticas de escritura;
  - ACLs;
  - una definición por función reescrita;
  - el cuerpo de `_quote_validate_items` llama al helper;
  - los guards nombran `delivery_note_items`;
  - `_branch_assert_empty` contiene `branch_has_pending_delivery_notes` y llama a `_branch_pending_delivery_notes`, una sola definición de cada una, `_branch_blocking_content` con su firma y su `RETURNS TABLE` de 5 columnas, y el disparador sigue apuntando a `fn_guard_branch_decommission`;
  - catálogo `delivery_note_sale` con 2 filas.
  
  Reaplicar la migración dos veces sin error (idempotencia del auto-apply).
- [x] 1.11 Actualizar `test_document_status_transition_role_matrix.sql` (tamaño del catálogo, filas con rol, llamadores de `record_status_transition` y pares producidos) y `test_function_acl_gate.sql` (clasificación de las funciones nuevas; helpers `_*` cubiertos por el chequeo (4)).
- [x] 1.12 Reutilizar `test_internal_document_numbering_race.sh` parametrizado por tipo para `delivery_note_sale` (N sesiones emiten el primer remito de una cuenta → 1..N sin huecos). Si el script no admite parámetro, extenderlo sin duplicarlo.
- [x] 1.13 Cablear `test_remitos_venta.sql` y la carrera en `KPI_Validation.yml`, en el orden real del workflow, y sumar la migración a la cadena de reaplicación **después** de los reapply de `20261014000001`, `20261062000001` y `20261067000001` (los tres vuelven a dejar el cuerpo viejo de `_branch_assert_empty`, de los dos guards de unidad y de `_quote_validate_items`). Después de reaplicarla, assertar que `_branch_assert_empty` contiene `branch_has_pending_delivery_notes`, que `fn_product_base_unit_guard`/`fn_uom_in_use_guard` nombran `delivery_note_items` y que `_quote_validate_items` llama a `_assert_document_product`. Verificar en local que el reapply de `20261014000001` y el de `20261062000001` (con su preflight de 10 funciones y su gate embebido) siguen pasando con la migración de A aplicada.

  **Resultado del grupo 1 (apply tanda A, 2026-10-02)** — migración `20261069000001_remitos_venta.sql`:
  - **RED** (1.1): `test_remitos_venta.sql` falló con `42883 function public.rpc_create_sale_delivery_note(text, uuid, uuid, text, text, jsonb) does not exist` (commit `63abcd93`). **RED de los guards** (1.8/1.9), con la migración sin las reescrituras de guard: el gate dio `FAIL (j)` asignar Kilogramo con una línea de remito en Unidad → `OK` (debía `base_unit_locked`), `FAIL (j)` cambiar el factor de una unidad usada sólo en un remito → `OK` (debía `unit_in_use`), y `FAIL (k)` la baja con un remito pendiente → `OK` por el disparador, por `rpc_deactivate_branch` y con un remito de compra pendiente (la carrera del bloque siguiente abortó por eso con `P0422`). GREEN después de las reescrituras.
  - **GREEN/TRIANGULATE** (1.7): el gate cubre 15 bloques (a)-(o) con 7 usuarios reales y huella de cero efectos por rechazo (18 rechazos de emisión con su código); todos PASS, residuo cero.
  - **Idempotencia** (1.10): la migración se aplicó dos veces seguidas sin error, con el OK de su introspección. Además en la cadena de reaplicación de CI (ver 1.13).
  - **Desvíos menores, todos aditivos y declarados en los comentarios de la migración**:
    - `_delivery_note_validate_items(account, branch, items, held)` suma `p_branch_id` (el design la listaba `(account, items, held)`): los pares requeridos se arman en la sucursal nueva y la función no puede inferirla.
    - Los pares (`_delivery_note_held_pairs`, `_apply_stock`, `_reverse_held`) usan una sola clave `quantity` para "retenido" y "requerido", más `unit_cost`, `product_name` e `item_ids`. Los requeridos de la edición se leen con `_delivery_note_held_pairs` de las líneas **nuevas** ya insertadas (misma definición única de lo retenido), y las patas se aplican después del reemplazo de líneas: reversa → aplicación, faltante sobre el neto, un `P0409` revierte todo igual.
    - `trg_delivery_note_record_creation()` toma el tipo de documento de `TG_ARGV[0]` (como el disparador genérico de numeración), para que `remitos-compra` enganche su gemelo sin otra función.
    - `_delivery_note_assert_role` lee los roles de la fila del catálogo que corresponde al modo (una sola fuente con `record_status_transition`): el modo `convert` responde `P0409 delivery_note_role_mode_unavailable` hasta que la tanda B siembre `issued → converted`.
    - Literales nuevos que la tanda A suma además de los de D11 (para 4.5): `idempotency_key_required`, `delivery_note_client_required`, `delivery_note_items_required`, `delivery_note_too_many_items`, `delivery_note_line_invalid_quantity|price|subtotal`, `delivery_note_revision_required`, `delivery_note_address_too_long`, `delivery_note_notes_too_long`, `delivery_note_cancel_reason_too_long`. La sucursal ajena o inactiva responde `P0404 branch_not_found …` (mismo literal que el presupuesto).
    - `rpc_get_delivery_note(uuid)` es `SECURITY DEFINER` con filtro explícito por `current_account_ids()` (ajeno = inexistente, `P0404 delivery_note_not_found`).
  - **Gates existentes** (1.11): `test_document_status_transition_role_matrix.sql` pasa de 22/16 a 24/18 filas, suma las triples `delivery_note_sale:NULL->issued` / `issued->canceled` y los llamadores 17.º-18.º (`trg_delivery_note_record_creation`, `rpc_cancel_delivery_note`). `test_function_acl_gate.sql` suma los 10 helpers internos del remito al chequeo (3) (son `SECURITY INVOKER`, así que el (4) no los alcanza); control negativo ejecutado: con `GRANT EXECUTE … _delivery_note_apply_stock … TO authenticated` el gate falla en (3).
  - **CI local** (1.13, `db reset` limpio desde el worktree + los 105 pasos `run:` de `KPI_Validation.yml` en su orden real, 2026-10-02): **102 PASS** en la primera pasada completa, incluidos el reapply de la cadena (`20261014000001` temprano, reconvergencia, `20261062000001` con su preflight 10/10 y gate embebido, `20261067000001`, `20261068000001` y el nuevo eslabón `20261069000001`: introspección OK, los cuatro cuerpos reescritos reconvergidos y schema idéntico), `test_remitos_venta.sql`, `test_remitos_venta_race.sh` y la numeración con `DOC_TYPE=delivery_note_sale`. Las 3 diferencias son artefactos locales conocidos, ninguno de este change: `check_backend_table_refs.py`/`check_frontend_table_refs.py` no encuentran `psql` en el `PATH` de Python en Windows (re-ejecutados con un shim: OK, 161 y 608 archivos); `test_punto_venta_predeterminado_race.sh` dio `INCONCLUSO` en la iteración 6 por la latencia de `docker exec` y pasó 10/10 al re-ejecutarlo.
  - **Carreras** (1.12 y adelanto de 6.9): `test_internal_document_numbering_race.sh` parametrizado con `DOC_TYPE` (default `quote` sin cambios; `delivery_note_sale` → R 1..20 sin huecos). `test_remitos_venta_race.sh` nuevo con 6 carreras de bloqueo verificado: última unidad, misma clave (replay, nunca 23505), edición vs anulación en los dos órdenes y emisión vs baja del producto en los dos órdenes. Las carreras que dependen de la conversión quedan para la tanda B.

## 2. Backend tanda A (3 capas)

- [x] 2.1 **RED**: `backend/tests/test_delivery_notes_module.py` (unit con dobles) + `test_delivery_notes_module_integration.py` (Postgres real) con:
  - schemas (`direction: Literal["sale"]`, topes, `product_id` obligatorio);
  - endpoints `GET/POST /delivery-notes`, `GET/PUT /delivery-notes/{id}` y `POST /delivery-notes/{id}/cancel`;
  - `POST /delivery-notes` sin `Idempotency-Key` rechazado por `require_idempotency_key`; misma clave dos veces → un remito (integración);
  - mapeo RFC 7807 de cada literal SQL;
  - 404 cross-tenant idéntico al inexistente;
  - capacidades por rol.
- [x] 2.2 `core/rbac.py`: `CAN_DELIVER_SALE` y `CAN_VOID_DELIVERY_NOTE` (D13), más el test que lee las migraciones y falla si divergen de los `allowed_role` de `delivery_note` (molde de `TestCanQuote`). Verificar que `is_sensitive_capability(CAN_VOID_DELIVERY_NOTE)` es verdadero y documentarlo en el comentario.
- [x] 2.3 `schemas/delivery_notes.py`, `repositories/delivery_note_repository.py` (todo por RPC o `SELECT` con `account_id` explícito), `services/delivery_notes.py` y `routers/delivery_notes.py`. Registrar el router.
- [x] 2.4 Listado paginado `{items,total,page,pages}` con filtros `status`, `q` (cliente o número `R-…`), `client_id`, `branch_id` (lo usa el diálogo de baja de sucursal, D10) y `direction=sale`, más el resumen de pendientes (cantidad y total).
- [x] 2.5 `product_repository._GROUP_HAS_LINES_IN_OTHER_UNIT_SQL` suma `delivery_note_items` (D14), con un caso de test que hoy pasa en falso (RED) y después traba.
- [x] 2.6 `services/delivery_notes.py`: `asyncpg.DeadlockDetectedError` (`40P01`) → `409 concurrent_update_retry` RFC 7807, con test (D4). (El número del remito en el kardex **no** pasa por el backend: el panel de `/stock` lee `stock_movements` directo y lo resuelve él, tarea 5.9.)
- [x] 2.7 TRIANGULATE: ≥ 2 casos por comportamiento (cada rol × cada operación, cada error tipado, cada formato de búsqueda). Cobertura ≥ 87 % sin bajar la global.
  **Resultado del grupo 2 (apply tanda A, 2026-10-02)**:
  - **RED**: `test_delivery_notes_module.py` (240 casos con las parametrizaciones) falló en la colección con `ModuleNotFoundError: backend.schemas.delivery_notes` (los cuatro módulos nuevos no existían). Para 2.5, el caso (k) de `test_ventas_unidades_conversion_base_unit_lock.py` actualizado a SIETE tablas y el caso nuevo de `delivery_note_items` fallaron antes de tocar la consulta.
  - **GREEN**: `core/rbac.py` (`CAN_DELIVER_SALE`, `CAN_VOID_DELIVERY_NOTE`), `schemas/delivery_notes.py`, `repositories/delivery_note_repository.py`, `services/delivery_notes.py`, `routers/delivery_notes.py` (registrado en `main.py`) y `product_repository._GROUP_HAS_LINES_IN_OTHER_UNIT_SQL` con la séptima tabla. Integración (`-m integration`, Postgres local con la migración aplicada): 18 casos contra la base real, residuo cero.
  - **Contrato HTTP** (lo consume el frontend):
    - `GET /delivery-notes?direction=&status=issued|converted|canceled&client_id=&branch_id=&q=&page=&page_size=`: envelope `{items, total, page, pages}` **más** `summary: {pending_count, pending_total}`. El resumen cuenta los `issued` del mismo recorte (sentido, cliente, sucursal, búsqueda) **sin** importar `status`. Cada fila trae `number_label`, `branch_name`, `client_name`, `item_count`.
    - `POST /delivery-notes`: `Idempotency-Key` obligatoria por header (sin la clave → 422 `idempotency_key_required`; el cuerpo no la acepta). Cuerpo `{direction?: "sale", client_id, branch_id, delivery_address?, notes?, items[{product_id, unit_id?, quantity, price, subtotal}]}`. Respuesta **201** con el remito completo y `replayed: false`; un reintento con la misma clave responde **200** con el mismo remito y `replayed: true`.
    - `GET /delivery-notes/{id}`: remito completo (`items` con `unit_symbol`, `quantity_base`, `product_deleted` y snapshots; `history`; `client_deleted`; `branch_name`; `number_label`; `converted_sales_order_id`/`converted_operation_id` = null en A; `issuer_name`).
    - `PUT /delivery-notes/{id}`: reemplazo completo `{revision, client_id, branch_id, delivery_address|null, notes|null, items[]}`; sin clave de idempotencia (la protege `revision`).
    - `POST /delivery-notes/{id}/cancel`: `{revision, reason (3-500)}`; sólo admin/owner.
    - `GET /delivery-notes/{id}/pdf?disposition=inline|attachment&show_prices=false`.
    - Errores RFC 7807 con `code` = literal del RAISE. Un `40P01` sale como 409 `concurrent_update_retry`.
  - **Desvíos declarados**:
    - La clave de búsqueda del listado acepta cualquier prefijo conocido (`P-12` y `R-12` dan 12), igual que la definición de TypeScript; qué documento se busca lo decide el listado.
    - Se extrajo `repositories/commercial_document_support.py` (`jsonb_value`, `like_pattern`, `CommercialIssuerMixin`) para no duplicar con `QuoteRepository`, que pasó a usarlo (sin cambio de comportamiento: sus 224 casos siguen verdes).
    - El caso (k) preexistente de `test_ventas_unidades_conversion_base_unit_lock.py` contaba SEIS tablas: se actualizó a siete (es el contrato que 2.5 cambia a propósito).
    - Anular es capacidad sensible (`is_sensitive_capability(CAN_VOID_DELIVERY_NOTE)` verdadero): el guard consulta la base aunque el claim traiga los roles; un claim `owner` desactualizado no autoriza una anulación (caso propio).
  - **Cobertura**: suite completa `-m "not integration"` como en `Backend_Tests.yml`: **3326 passed, 1 skipped, cobertura 95,00 %** (piso 87 %). Los módulos nuevos quedan en 97-100 %. `check_backend_table_refs.py` contra el schema real: OK (166 archivos).

## 3. PDF del remito (tanda A)

- [x] 3.1 **RED**: `backend/tests/test_commercial_document_pdf.py` suma casos de remito leídos con `pypdf`:
  - "REMITO", el número, la sucursal de origen, las cantidades con su unidad, el bloque de firma y "no válido como factura";
  - **sin** precios ni total por defecto, y **con** ellos con `show_prices`;
  - sello "ANULADO";
  - 80 líneas con la firma sin partirse.
- [x] 3.2 `CommercialDocumentView` suma `signature_block` y `origin_label` con defaults retrocompatibles. El render los dibuja. `build_delivery_note_view` es pura, en `services/commercial_documents/view.py`. Los casos de presupuesto existentes tienen que seguir verdes sin tocarlos.
- [x] 3.3 `GET /delivery-notes/{id}/pdf?disposition=&show_prices=`: 200 en todo estado, 404 ajeno o inexistente, 422 en parámetros inválidos, 401 sin sesión, nombre `remito-R-….pdf`. El emisor sale de `rpc_commercial_issuer` (sin cambios).
- [x] 3.4 Numeración visible (backend en el grupo 3, frontend en el grupo 4: `delivery_note_sale` -> `R` en `frontend/lib/internal-document-number.ts`, verificado por el fixture compartido en pytest y vitest): prefijo `R` en `numbering.py` y en `frontend/lib/internal-document-number.ts`, con casos nuevos en el fixture compartido `internal_document_number_cases.json` (pytest y vitest leen el mismo).
  **Resultado del grupo 3 (apply tanda A, 2026-10-02)**:
  - **RED**: las clases de remito agregadas a `test_commercial_document_pdf.py` fallaron (`build_delivery_note_view` inexistente, `signature_block`/`origin_label` ausentes de la vista); el control negativo del presupuesto (sin firma ni origen) pasaba de entrada.
  - **GREEN/TRIANGULATE**: 32 casos nuevos leídos con `pypdf` (91 en el archivo), entre ellos el bloque de firma parametrizado con 13 cantidades de líneas (1 a 80) que verifica que "Recibí conforme", "Firma", "Aclaración" y "DNI" quedan en la misma página, una sola vez, y que la leyenda está en todas las páginas. Los 59 casos de presupuesto y recibos previos siguen verdes sin tocarlos.
  - `view.py`: `build_delivery_note_view` pura; `numbering.py`: prefijo `R` por tipo de secuencia `delivery_note_sale` y búsqueda con cualquier prefijo conocido; fixture compartido con 3 casos de formato y 6 de búsqueda de remito.
  - **Pendiente de la otra mitad de 3.4 (frontend, fuera de este agente)**: `frontend/lib/internal-document-number.ts` tiene que sumar el tipo `delivery_note_sale` con prefijo `R` (el vitest que lee el fixture compartido falla hasta entonces: `formatInternalDocumentNumber("delivery_note_sale", …)`).

## 4. Frontend tanda A: datos, helpers y hooks

- [x] 4.1 **RED**: `__tests__/hooks/use-delivery-notes.test.tsx` con `useDeliveryNotes(filters)`, `useDeliveryNote(id)`, `useCreateDeliveryNote` (manda `Idempotency-Key` de `useIdempotencyKey("delivery-note-create")`, reseteada en cada éxito), `useUpdateDeliveryNote` y `useCancelDeliveryNote`. Las mutaciones invalidan `deliveryNotes.*`, `branchStock` y `products` (el panel de movimientos no usa React Query y se recarga al abrirse: no hay clave de kardex que invalidar).
- [x] 4.2 `hooks/data/use-delivery-notes.ts` + tipos del contrato en `lib/delivery-note-types.ts` + claves en `lib/query-keys.ts`.
- [x] 4.3 `lib/delivery-note-share.ts` (`buildDeliveryNoteShareText`) y `lib/delivery-note-status.ts` (rótulos y acciones por estado y rol, funciones puras), con tests.
- [x] 4.4 `lib/rbac-capabilities.ts`: `CAN_DELIVER_SALE`, `CAN_VOID_DELIVERY_NOTE` y `CAN_SELL`, más el test de contrato contra el backend y la FSM.
- [x] 4.5 `lib/operation-errors.ts`: traducciones accionables de los literales de D11 (incluido `delivery_note_branch_inactive`, y `client_not_found` en contexto remito con "Cliente dado de baja — elegí uno vigente"), un caso por literal; `humanizeOperationError` suma el contexto `documentLabel: "venta" | "remito"` (default `"venta"`), con un caso de `stock_insuficiente` para el remito que no diga "la venta".
- [x] 4.6 **Disponible por sucursal en la capa canónica** (decisión de D11, no checkpoint): `CartStockOptions` de `lib/cart-utils.ts` suma `availableFor?: (productId) => number`, que `addManualLineToCart`, `applyScanToCart` y la validación de cantidad usan en lugar de `product.stock`. RED primero: con stock 2 en la sucursal y 10 en el agregado, agregar 3 se rechaza sólo si se pasa `availableFor`. Los tests de venta y de presupuesto (que no la pasan) siguen verdes sin tocarlos.
- [x] 4.7 `BranchSelect`: props aditivas `required` (sin "Sin sucursal") y `alwaysVisible` (visible aunque el plan no tenga módulo de sucursales), con test de que los usos actuales no cambian. Precarga del remito: `lib/default-branch.ts` si #607 ya mergeó; si no, la sucursal activa y no cerrada más antigua (mismo criterio que `c26_default_branch`).
- [x] 4.8 `hooks/data/use-client-addresses.ts` (`GET /clients/{id}/addresses`, que ya existe en el backend): grep previo por un hook equivalente; si no hay, nace acá con su test. Lo usa el domicilio de entrega precargado (5.2).
- [x] 4.9 `components/shared/DocumentPageStates.tsx`: generalizar `QuotePageStates` con textos parametrizados por documento (sin permiso, cargando, error/no encontrado, no editable). `QuotePageStates` pasa a usarlo y su test sigue verde sin tocarlo.
- [x] 4.10 `use-branches.ts::translateRpcError`: token `branch_has_pending_delivery_notes`, con su caso de test (D10).

  **Resultado del grupo 4 (apply tanda A, frontend, 2026-10-02)** — rama `opsx/remitos-venta-apply-a-fe`, 9 commits, sólo `frontend/` (más esta marca):
  - **Hooks y contrato** (4.1/4.2): `lib/delivery-note-types.ts`, `hooks/data/use-delivery-notes.ts` (`useDeliveryNotes`, `useDeliveryNote`, `useCreateDeliveryNote` con `Idempotency-Key` por header desde `useIdempotencyKey("delivery-note-create")` reseteada en cada éxito, también en un replay, `useUpdateDeliveryNote`, `useCancelDeliveryNote`, `fetchDeliveryNotePdf` con `show_prices=false` por defecto) y `queryKeys.deliveryNotes`. Toda mutación invalida `deliveryNotes.*` + `branchStock` + `products`. Sin `useConvertDeliveryNote` (tanda B).
  - **Número** (tarea "formato de número con el fixture compartido"): `delivery_note_sale` -> `R` en `lib/internal-document-number.ts` y `formatDeliveryNoteNumber(direction, n)`, nunca con una `R` fija (el sentido compra no hereda la `R`).
  - **Helpers** (4.3, 4.5, 4.6): `lib/delivery-note-status.ts` (rótulos, pestañas, contrato `?estado=`, matriz estado × rol de D11), `lib/delivery-note-share.ts`, `lib/operation-errors.ts` (13 literales de D11 + 10 de los que sumó la tanda A (`idempotency_key_required` no: el cliente siempre manda la clave), contexto `documentLabel`), `CartStockOptions.availableFor` + `maxQuantityPerLine` + `linesExceedingAvailable` en `lib/cart-utils.ts`, `lib/delivery-note-stock.ts` (retenido desde las líneas, disponible por sucursal, ajuste de la edición sólo en los pares que cambian, textos del aviso).
  - **Capacidades** (4.4): `CAN_DELIVER_SALE`, `CAN_VOID_DELIVERY_NOTE`, `CAN_SELL` en `lib/rbac-capabilities.ts`, atadas a la migración (siempre) y a `core/rbac.py` (`it.runIf`: corren cuando la tarea 2.2 deje las dos constantes; hoy 2 casos saltados).
  - **Componentes** (4.7, 4.9): `BranchSelect` con `required`/`alwaysVisible` (usos actuales sin cambios), `components/shared/DocumentPageStates.tsx` con `QuotePageStates` delegando. **Datos** (4.8, 4.10): `hooks/data/use-client-addresses.ts` + `lib/client-address.ts`; `translateRpcError` con `branch_has_pending_delivery_notes`.
  - **Verificación**: vitest completo en 6 shards (la corrida única excede los 30 min con el stack de Docker en paralelo): **489 archivos, 5.017 tests pasados, 2 saltados (los `runIf` de `core/rbac.py`), 0 fallos**. `tsc --noEmit`: 8 errores, todos preexistentes en 5 archivos de test ajenos (`LedgerMovementsPanel`, `purchase-operations-list-payment-lock`, `use-critical-stock`, `pos-payment-methods`, `revenue-canon`); **0 nuevos**.
  - **Desvíos declarados**: (1) los casos `delivery_note_sale` del fixture compartido `backend/tests/fixtures/internal_document_number_cases.json` NO se sumaron acá (es `backend/` y es de la tarea 3.4, que los agrega junto con `numbering.py` para que pytest no vea un tipo sin prefijo): `internal-document-number.test.ts` recorre cualquier `document_type` del fixture, así que corren solos; mientras tanto `delivery-note-number.test.ts` fija los mismos valores. (2) `BranchSelect required` además de ocultar "Sin sucursal" deja afuera las sucursales cerradas (el servidor las rechaza con `branch_closed`). (3) El hook del resumen de pendientes del listado (cantidad y total, tarea 2.4) no se escribió: su contrato lo define el backend (2.4); queda para el grupo 5 junto con `/remitos`. (4) Sin `lib/default-branch.ts` (el PR #607 sigue abierto): `lib/branch-selection.ts` aplica el criterio de `c26_default_branch`.

## 5. Pantallas tanda A

- [x] 5.1 **RED**: `__tests__/components/DeliveryNoteForm.test.tsx`. Casos:
  - alta con stock suficiente; bloqueo al superar el stock **de la sucursal elegida** (con el de otra sucursal mayor), con el disponible y el enlace "Transferir stock";
  - cuenta sin módulo de sucursales: la sucursal se precarga y se ve; sin sucursal no se agregan líneas;
  - cambio de sucursal que recalcula el disponible y re-valida todas las líneas;
  - edición con una sola contabilidad: retenido 3 con la sucursal en 0, una línea nueva de 2 se rechaza; al cambiar de sucursal, lo retenido deja de sumar; el input de cantidad no supera el disponible (`maxQtyMap`);
  - avisos: "Al emitir, se descuenta del stock de {sucursal}" y el resumen del ajuste antes de guardar una edición ("Este cambio no mueve stock" si no hay ajuste);
  - sin "Agregar concepto";
  - balanza y código de barras;
  - cliente nuevo en el lugar;
  - domicilio precargado (desde `use-client-addresses`);
  - `delivery_note_changed` con recarga;
  - **cliente dado de baja** en la edición: se muestra el cliente congelado con el aviso "Cliente dado de baja — elegí uno vigente para guardar", el guardado queda bloqueado hasta elegir otro, y en el detalle "Venta" queda deshabilitado con ese motivo (D11);
  - producto dado de baja: se muestra "se conserva lo entregado", **no** bloquea el guardado, no admite aumentar, y quitarlo pide confirmación con lo que vuelve al stock.
- [x] 5.2 `components/delivery-notes/DeliveryNoteForm.tsx`, compuesto con `StagedProductLine` (que encapsula `ProductPicker`), `CartItemList` (con `maxQtyMap`), `ScrollableCartShell`, `BarcodeScannerInput`, `BranchSelect` (`required` + `alwaysVisible`, 4.7) y `lib/cart-utils` (`enforceStock: true` + `availableFor`, 4.6). Las líneas rehidratadas no llevan `source: "persisted"` (D11). Sin copiar lógica de `QuoteForm`: si algo se repite, se extrae a `components/shared/` o `lib/`.
- [x] 5.3 `DeliveryNoteStatusBadge` (tokens semánticos, sin literales de paleta) y `CancelDeliveryNoteDialog` (motivo obligatorio, enumera lo que vuelve al stock, manda `revision`, foco y teclado).
- [x] 5.4 `/remitos`: listado con pestañas de estado, búsqueda con debounce, paginado, tarjetas en móvil, resumen de pendientes, CTA por rol y estado vacío. Lee de la URL el contrato único de D11 (`?estado=`, `?sucursal=`, `?cliente=`): `estado` preselecciona la pestaña y `sucursal`/`cliente` se aplican como chips removibles. Test de página que entra con los tres parámetros. **Sin pestañas de sentido** (D11).
- [x] 5.5 `/remitos/nuevo` (`?cliente=`) y `/remitos/[id]/editar`, con los estados de página de `DocumentPageStates` (4.9): sin `CAN_DELIVER_SALE`, error o no encontrado (ajeno = inexistente), y no editable (convertido: enlace a la venta e instrucción de eliminarla; anulado: motivo).
- [x] 5.6 `/remitos/[id]`:
  - detalle con la matriz estado × rol de D11 y `DocumentShareMenu` con el switch "Mostrar precios" (apagado por defecto) **fuera del desplegable**, con `Label`, y el menú montado con `key={showPrices}` para descartar la precarga; test "cambiar el switch y enviar comparte la variante elegida";
  - remito convertido cuya venta tiene comprobante autorizado: leyenda de nota de crédito (D9);
  - historial con motivo;
  - leyenda de "convertido";
  - en la tanda A, "Venta" no se muestra.
- [x] 5.7 Sidebar: "Remitos" (`PackageCheck`) en *Operaciones*, después de "Presupuestos". Breadcrumb de las 4 rutas. Ajustar los tests de estructura del sidebar y del breadcrumb.
- [x] 5.8 Ficha del cliente: "Nuevo remito" (`/remitos/nuevo?cliente=<id>`) y "Ver remitos" (`/remitos?cliente=<id>`, contrato de D11) en `ClientDetailHeader`.
- [x] 5.9 Panel de movimientos de `/stock`: rótulos "Remito R-…", "Edición de remito R-…" y "Anulación de remito R-…" por `reference_type`, con enlace a `/remitos/<reference_id>`. El sentido y el ícono siguen saliendo del `type`. El número se resuelve **en el panel**, con una segunda consulta `delivery_notes.select("id, number, direction").in("id", refIds)` por página (RLS de `SELECT`), formateado según `direction` con `lib/internal-document-number.ts` (D2); si falla, la fila dice "Remito" sin número. El rótulo se extrae a un helper del panel (`movementLabel`) que usan `MovementRow` **y `exportCsv`**. Tests: fila, fallo de la segunda consulta y CSV con una fila `delivery_note` cuya columna "Tipo" dice "Remito R-…".
- [x] 5.10 `DeactivateBranchDialog`: además de las existencias, consulta los remitos `issued` de la sucursal (`GET /delivery-notes?status=issued&branch_id=…`, sin filtro de `direction`) y, si hay, en lugar de "Desactivar" muestra el aviso con "Ver remitos pendientes" (`/remitos?estado=pendientes&sucursal=<id>`, contrato de D11). Test con y sin remitos pendientes.

  **Resultado del grupo 5 (apply tanda A, frontend, 2026-10-02)** — rama `opsx/remitos-venta-apply-a` (fusionada la del grupo 4), sólo `frontend/`:
  - **Contrato real cotejado** contra `backend/schemas/delivery_notes.py` antes de las pantallas: el listado manda `item_count` (el tipo decía `items_count`), `number_label`, y el sobre trae `summary: {pending_count, pending_total}` (nuevo `DeliveryNotePage`, lo que devuelve `useDeliveryNotes`); `performed_by` del historial y `created_by` pueden ser `null`; el detalle trae `number_label`, `client_tax_id` e `issuer_name`. Corregidos en `lib/delivery-note-types.ts`.
  - **Pantallas**: `/remitos` (pestañas Todos/Pendientes/Convertidos/Anulados que resuelve el servidor, búsqueda con debounce, paginado, tabla y tarjetas, resumen "N remitos pendientes por $ X", contrato `?estado=`/`?sucursal=`/`?cliente=` con chips removibles y la URL en sintonía por `router.replace`), `/remitos/nuevo` y `/remitos/[id]/editar` sobre `DeliveryNoteForm`, `/remitos/[id]` (matriz estado x rol de `deliveryNoteActions`; **"Venta" no se muestra en la tanda A**; `DocumentShareMenu` con el switch "Mostrar precios" fuera del menú y `key={showPrices}`; historial con motivo; leyendas de convertido y de nota de crédito). Componentes: `DeliveryNoteForm`, `DeliveryNoteStatusBadge`, `CancelDeliveryNoteDialog`.
  - **Piezas canónicas nuevas** (sin duplicar): `lib/delivery-note-form.ts` (rehidratación sin `source: "persisted"`, payload, reglas), `lib/stock-movement-label.ts` (rótulo del kardex, compartido por la fila y el CSV), `canceledReason` y `deliveryNoteHistoryLabel` en `lib/delivery-note-status.ts`, `deliveryNoteFileName` en `lib/delivery-note-share.ts`. Sin "Agregar concepto".
  - **Menú, ficha, kardex, baja**: "Remitos" (`PackageCheck`) en *Operaciones* después de "Presupuestos" y nombres de las 4 rutas en el breadcrumb; "Nuevo remito" (`CAN_DELIVER_SALE`) y "Ver remitos" (todo miembro) en `ClientDetailHeader`, de sólo ícono en móvil con `aria-label` distintos; `StockMovementsPanel` rotula `delivery_note*` con el número resuelto por una segunda consulta y lo exporta con el mismo rótulo; `DeactivateBranchDialog` consulta los remitos `issued` de la sucursal (sin filtro de sentido) y ofrece "Ver remitos pendientes".
  - **Verificación**: vitest completo en 6 shards: **500 archivos, 5.280 tests**; 2 de ellos (`banco-conciliacion-import-warnings`, `expense-import-dialog-review-findings`, ajenos al change) dieron timeout sólo bajo la carga de la corrida completa y pasan solos (12/12). `tsc --noEmit`: los mismos 8 errores preexistentes de 5 archivos de test ajenos, **0 nuevos**. Sin literales de paleta de Tailwind en los archivos nuevos (grep) y el badge lo fija por test.
  - **Desvíos declarados**: (1) **la verificación visual en escritorio y 375 px, claro y oscuro (D11) NO se hizo en esta corrida**: no había un stack local con sesión para esta tarea; queda abierta para 8.x / el humo del PO. Lo que sí queda fijado por test es la estructura: tokens semánticos, `aria-label` de los controles de sólo ícono, `min-w-0`/`truncate` del título de la ficha, tarjetas en móvil. (2) La fila de un movimiento de remito lleva el número dentro del mismo badge del tipo (que ahora puede partirse en dos líneas); si la pasada visual muestra desborde a 375 px, se ajusta el ancho de la columna. (3) `DeactivateBranchDialog` no bloquea si la consulta de remitos falla: el guard real es `P0428` y ya está traducido. (4) El chip de sucursal del listado dice "Sucursal: seleccionada" si la sucursal no está entre las activas (p. ej. dada de baja), en lugar de un nombre.

## 6. Tanda B: DB — núcleo, conversión, borrado y edición

- [ ] 6.0 Número de migración de la tanda B (siguiente libre). Confirmar que la tanda B de presupuestos está mergeada y en prod. `grep -n "REGLA PARA EL PR SIGUIENTE" .github/workflows/KPI_Validation.yml`: anotar si el bloque de reaplicación de `20261062000001` sigue en el workflow (si el #607 ya mergeó, puede haberlo retirado él).
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
  - sólo la rama `v_from_delivery_note` de D7: revalidación del remito y de las líneas con `P0409 delivery_note_order_mismatch`; salto del `FOR UPDATE` del producto, la normalización, el gate, el delta y el movimiento; `sale_items` con los **cuatro** snapshots de `sales_order_items` (nombre, SKU, costo, IVA) en lugar de `v_product.*`;
  - `COMMENT` vivo re-declarado y ACL idéntica a la previa (el allowlist del chequeo (4) sigue igual);
  - **el diff contra el cuerpo vivo tiene que ser sólo esa rama**: adjuntarlo en `evidence/`.
- [ ] 6.5 `rpc_convert_delivery_note_to_sale` (D7), con el molde de `rpc_convert_quote_to_sale`: lock del origen, idempotencia bajo lock, estado, versión, cliente vivo, sucursal activa y no cerrada (`P0422`), orden + líneas copiadas, núcleo, `RAISE` ante replay ajeno y transición `issued → converted` (`delivery_note_sale`).
- [ ] 6.6 `rpc_delete_sale_operation` desde el cuerpo vivo (D9): con origen de remito, **antes** del guard fiscal y de cualquier compensación, la sucursal del remito leída con `FOR SHARE` tiene que estar activa y no cerrada (si no, `P0422 delivery_note_branch_inactive` y cero efectos); salto explícito de la reversa de stock; y vuelta del remito a `issued` (lock después de `fiscal_documents`, historial con motivo).
- [ ] 6.7 `rpc_atomic_update_sale_operation` desde el cuerpo vivo (D9): `P0423 delivery_note_sale_locked` inmediatamente después del lock de `sales` y del guard de cliente, **antes** de la anulación fiscal.
- [ ] 6.8 GREEN → **TRIANGULATE** hasta cubrir toda la matriz del gate de la tanda B:
  - `cash`/`credit`/`transfer`;
  - stock idéntico; 0 movimientos propios; los cuatro snapshots del remito, incluido un producto renombrado después de emitir;
  - baja de producto que convierte; cliente de baja; sucursal desactivada o cerrada (`P0422`); replay; conflicto de clave; segunda conversión; versión vieja;
  - roles; `cash` sin sesión;
  - los 7 orígenes inválidos;
  - borrado (dinero, stock, orden, remito, reconversión) y borrado con la sucursal del remito desactivada después de convertir → `P0422 delivery_note_branch_inactive` sin efectos;
  - edición bloqueada sin anular el comprobante pendiente, con `branch_stock` y `stock_movements` (`sale_update`/`sale`) del par sin cambios;
  - anulación de un convertido;
  - regresiones del POS y de `rpc_convert_quote_to_sale`.
- [ ] 6.9 `supabase/tests/test_remitos_venta_race.sh` (molde de `test_presupuesto_a_venta_race.sh`) con las 9 carreras de §D16, incluidas emisión con la misma clave (la segunda con `replayed = true`, nunca un 500), emisión contra baja del producto, borrado de la venta contra anulación del remito y edición contra anulación. (Las carreras que no dependen de la conversión se pueden adelantar a la tanda A.)
- [ ] 6.10 Introspección de la tanda B (una definición por función, ACL igual a la previa en las tres reescritas, cuerpos con la rama, el salto y el `P0423`) + reaplicación doble. Actualizar `test_document_status_transition_role_matrix.sql` y `test_function_acl_gate.sql`, re-ejecutar `test_presupuesto_a_venta.sql`, `test_operacion_party_guard.sql` y los gates de venta. Cablear en `KPI_Validation.yml`. **Si el bloque de reaplicación de `20261062000001` sigue en el workflow (6.0), retirarlo en este mismo PR** (su "REGLA PARA EL PR SIGUIENTE": esta tanda redefine `_c29_confirm_order_core` y `rpc_atomic_update_sale_operation`, dos de sus diez funciones, y con el bloque puesto `validate-kpis` queda en rojo); su control pasa a `test_remito_a_venta.sql` + la introspección de la tanda B. Si ya lo retiró el #607, anotarlo acá.

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
- [ ] 7.4 `SaleCheckoutFields`: prop aditiva `branchReadOnly` (muestra el nombre de la sucursal aunque el plan no tenga módulo de sucursales), con test de que el presupuesto sigue igual. `ConvertDeliveryNoteDialog` compone `SaleCheckoutFields` + `SaleCheckoutSuccess` + `useSaleCheckout({ paymentMethodId, branchId: dn.branch_id, clientId })` (la semántica de caja y forma de pago, sin copiarla) + `useConvertDeliveryNote` (`useIdempotencyKey("delivery-note-convert:" + id)`, reset en cada éxito, `invalidateAfterSale` + `deliveryNotes.*`), con la línea fija "El stock ya se descontó al emitir el remito R-…: esta venta no lo vuelve a descontar".
- [ ] 7.5 Detalle del remito: acción "Venta" (`CAN_SELL`, sólo `issued`). Estado `converted` con "Ver venta" y el comprobante.
- [ ] 7.6 `/ventas`: badge "Desde remito R-…" en el listado y el detalle (en su propia línea, como el de presupuesto), generalizando `SourceQuoteBadge` a `SourceDocumentBadge` (tipo + número + `href`) que usan los dos orígenes. "Editar" deshabilitado con el motivo. Diálogo de borrado con la línea de D9.
- [ ] 7.7 Invalidación tras borrar una venta: `invalidateAfterSaleDelete` en `lib/query-invalidation.ts` (incluye `deliveryNotes.all()`), usada por `deleteSaleMutation`, `deleteSalesByOperationMutation` y el borrado de orden. RED: test de hook que asserta la invalidación de remitos.

## 8. Verificación

- [ ] 8.1 Suites completas por tanda:
  - backend `-m "not integration"` con cobertura ≥ 87 % + integración;
  - vitest completo; `tsc` sin errores nuevos contra el baseline;
  - todos los gates de `KPI_Validation.yml` sobre `db reset` limpio, en el orden real del workflow.
  
  Explicar cualquier diferencia contra el baseline de 0.6.
- [ ] 8.2 **Verificación visual, 4 combinaciones** (desktop y 375 px × claro y oscuro) de `/remitos`, `/remitos/nuevo`, `/remitos/[id]` (los 3 estados), `/remitos/[id]/editar`, `CancelDeliveryNoteDialog`, la cabecera de la ficha del cliente (`ClientDetailHeader` a 375 px: sin desborde y `aria-label` distintos en los botones de ícono), las filas de remito del panel de `/stock`, `DeactivateBranchDialog` con remitos pendientes y, en B, `ConvertDeliveryNoteDialog`, el badge y el diálogo de borrado de `/ventas`. Medir:
  - desbordes horizontales: 0 propios;
  - contraste (gate `token-contrast-aa`);
  - CTA visible en móvil.
  
  Capturas en `evidence/visual/`.
- [ ] 8.3 **Humo local** con el stack completo:
  - **A**: emitir → stock baja en `/stock` con el rótulo → editar (subir, bajar, precio, sucursal) → PDF con y sin precios → WhatsApp (escritorio y emulación móvil) → anular con motivo → stock vuelve; baja de sucursal bloqueada con un remito pendiente;
  - **B**: convertir en efectivo y a crédito → el stock no cambia → badge en `/ventas` → Facturar → borrar la venta → el remito vuelve a pendiente y el stock no cambia → reconvertir.
- [ ] 8.4 **Red-team** contra el stack local (GoTrue + PostgREST + FastAPI + Postgres), molde de `presupuestos-modulo/evidence/redteam/`:
  - escritura directa por PostgREST sobre las tablas, helpers y `sales_orders`;
  - fila forjada en `stock_movements` contra un remito pendiente, seguida de anulación y de edición: el stock devuelto es sólo lo retenido; y la misma fila **no** se puede revertir por `rpc_reverse_stock_movement` (no admite `delivery_note*`), con el control positivo de que una fila forjada `reference_type='sale'` sí se revierte hoy por esa función (preexistente, candidato de 9.1);
  - doble `POST /delivery-notes` con la misma `Idempotency-Key`;
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
  - candidatos que deja, cada uno con su motivo:
    - la RLS preexistente de `stock_movements` (`INSERT` para cualquier miembro) y `branch_stock` (`INSERT`/`UPDATE` para escritores);
    - **`rpc_reverse_stock_movement`** (`SECURITY DEFINER`, `EXECUTE` para `authenticated`, sin `is_account_writer` ni rol): combinada con la RLS de arriba, convierte hoy una fila forjada en stock. Revocarla de `authenticated` (sus llamadores legítimos son RPCs definer) o exigirle `is_account_writer` + rol; revisar igual `rpc_apply_product_stock_delta`, que deja a cualquier miembro mover stock directo;
    - el remito legal "R" (CAI o remito electrónico de ARCA), descartado por R1;
    - remitos parciales y varios remitos → una venta (R8);
    - presupuesto → remito y venta → remito;
    - link público y envío por email;
    - devolución parcial como documento propio;
    - devolución de mercadería de un remito cuya venta ya tiene CAE autorizado (nota de crédito con reingreso de stock): hoy el remito queda cerrado (D9);
    - reintento automático ante `40P01` y migrar el panel de movimientos a React Query;
    - KPI de remitos pendientes en el Tablero (OQ-RV12);
    - las alternativas de OQ-RV que el PO no eligió;
  - la coordinación con #607.
- [ ] 9.2 KB:
  - `knowledge-base/04_modelo_de_datos.md`: tablas y columna nuevas;
  - `05_reglas_de_negocio.md`: regla del remito (stock al emitir, edición con espejo, anulación con motivo, conversión sin doble descuento, venta inmutable, borrado que reabre);
  - `06_funcionalidades.md` y `07_flujos_principales.md`: flujo del remito.
- [ ] 9.3 Puntero del `CLAUDE.md`: **no se edita en este change** (instrucción del workflow). Se anota en `CHANGES.md` que el ítem del roadmap se actualiza en el archive, con `python scripts/ci/check_docs_sync.py --fix` en ese PR.

## 10. Post-merge (por tanda)

- [ ] 10.1 **Tanda A**:
  - verificar `GET /deploys` de Render (disparar si falta) y el deploy de Vercel;
  - SELECT en prod: `MAX(version)`, tablas, `CHECK` (los tres `reference_type`, `delivery_note_sale` en la secuencia, en los dos de FSM y en `operation_idempotency`), disparadores, 0 políticas de escritura, ACLs (sin `anon`; helpers sin `authenticated`), una definición de cada función reescrita, catálogo `delivery_note_sale` con 2 filas, guards que nombran `delivery_note_items`, `_branch_assert_empty` con `branch_has_pending_delivery_notes`.
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
| 0 (grupo 0) | backend/tests (332), frontend/__tests__ (285), 6 gates SQL | Safety net | 332 + 285 + 6/6 PASS | n/a | n/a | n/a | n/a |
| 1.1/1.7 (DB emisión/edición/anulación) | supabase/tests/test_remitos_venta.sql | SQL gate (Postgres real) | 6 gates del 0.6 PASS | 42883 rpc_create_sale_delivery_note | (a)-(i), (l)-(o) PASS | 18 rechazos con huella + 14 escenarios de edición + fila forjada + invariante | helpers únicos (held_pairs) reutilizados por emisión/edición/anulación |
| 1.8 (guards de unidad) | test_remitos_venta.sql (j) | SQL gate | test_ventas_unidades_conversion PASS | base_unit_locked y unit_in_use salían OK | P0409 en los dos | asignar la unidad de la línea sí funciona | desde el cuerpo vivo, COMMENT intacto |
| 1.9 (baja de sucursal) | test_remitos_venta.sql (k) | SQL gate | test_sucursal_guard_vaciado PASS | baja con remito pendiente OK por disparador/rpc_deactivate_branch | P0428 branch_has_pending_delivery_notes x3 caminos | remito de compra también bloquea; anulado + vaciado, procede | predicado único _branch_pending_delivery_notes |
| 1.11 (gates existentes) | test_document_status_transition_role_matrix.sql, test_function_acl_gate.sql | SQL gate | 22/16 PASS antes de la migración | 24/18 vs 22/16 | PASS | control negativo GRANT -> ACL GATE (3) FAILED | — |
| 1.12 (carreras) | test_internal_document_numbering_race.sh, test_remitos_venta_race.sh | 2+ conexiones reales | quote 1..20 PASS | — (script nuevo) | delivery_note_sale 1..20; 6 carreras PASS | quote sigue PASS con el parámetro | — |
| 2.1-2.7 (backend 3 capas) | backend/tests/test_delivery_notes_module.py, test_delivery_notes_module_integration.py | Unit con dobles + integración (Postgres real) | 332 backend focalizados PASS (0.6) | ModuleNotFoundError backend.schemas.delivery_notes | 240 unit + 18 integración PASS | cada rol x operación, 29 literales SQL, 6 formatos de búsqueda, 40P01, 404 cross-tenant, replay 200/201 | mixin `commercial_document_support` compartido con `QuoteRepository` (224 casos PASS) |
| 2.5 (guard de unidad en el repo) | test_ventas_unidades_conversion_base_unit_lock.py | Unit | 18/18 PASS | (k) actualizado a 7 tablas + caso nuevo de `delivery_note_items`: FAIL | 18/18 PASS | tenencia (`account_id = $2` x7) | — |
| 3.1-3.4 (PDF y numeración) | backend/tests/test_commercial_document_pdf.py, fixtures/internal_document_number_cases.json | Unit (pypdf) | 59 casos de presupuesto/recibos PASS | build_delivery_note_view inexistente, vista sin `signature_block` (31 en rojo) | 91 PASS | con/sin precios, ANULADO, 13 largos de tabla para el bloque de firma, prefijo `R`, búsqueda `R-12` | — |
| 4.1/4.2 (hooks de datos) | frontend/__tests__/hooks/use-delivery-notes.test.tsx | Unit (React Query) | use-quotes 9 archivos/184 PASS | módulo `use-delivery-notes` inexistente | 31 PASS | filtros (5), invalidación por dominio × 3 mutaciones, clave igual en reintento / distinta tras éxito y replay / sin reset si falla | — |
| número R- | frontend/__tests__/lib/delivery-note-number.test.ts | Unit | internal-document-number 27 PASS | 16 de 27 fallaban (tipo y formateador inexistentes) | 54 PASS con el fixture compartido | R-1/12/8 y 9 dígitos, parse de R-12/r-12/12/RC-12, ida y vuelta, compra sin R | — |
| 4.3 (estado y share) | frontend/__tests__/lib/delivery-note-status.test.ts, delivery-note-share.test.ts | Unit | — | módulos inexistentes | 31 PASS | matriz issued/converted/canceled × roles, ?estado= válidos e inválidos, cliente de baja, venta facturada, texto con/sin nombre, negocio y número | — |
| 4.4 (capacidades) | frontend/__tests__/lib/rbac-capabilities-delivery-notes.test.ts | Contrato | rbac-capabilities 14 PASS | 11 de 14 fallaban (constantes inexistentes) | 12 PASS + 2 saltados (runIf Python hasta 2.2) | cada conjunto contra el catálogo `delivery_note_sale` de la migración y contra `rbac.py` | — |
| 4.5 (operation-errors) | frontend/__tests__/operation-errors-delivery-notes.test.ts | Unit | quotes + units + POS 72 PASS | 21 de 34 fallaban | 34 PASS | un caso por literal, producto de baja con/sin nombre, `documentLabel` remito vs venta (stock, cliente, rol) | regex de líneas con la línea opcional |
| 4.6 (availableFor) | frontend/__tests__/lib/cart-utils-available-for.test.ts | Unit | cart-utils 78 PASS | 16 de 18 fallaban | 18 PASS | stock 2 en la sucursal y 10 en el agregado: sólo se rechaza con `availableFor`; acumulativo, unidades, balanza; tope por línea y líneas que no alcanzan | — |
| 4.6 (neto de stock) | frontend/__tests__/lib/delivery-note-stock.test.ts | Unit | — | módulo inexistente | 28 PASS | A=2/B=1→A=2/B=3 un solo par espejo, reducción, quitar, producto/sucursal nuevos, tolerancia de 4 decimales, textos | — |
| 4.7 (BranchSelect) | frontend/__tests__/components/BranchSelect.test.tsx, __tests__/lib/branch-selection.test.ts | Componente + unit | ConvertQuoteDialog/QuoteForm/gastos 93 PASS | 6 de 16 fallaban (los 10 de usos actuales ya pasaban) | 16 + 8 PASS | required y alwaysVisible por separado y juntos; sin módulo, cerradas, centinela; branch-selection verificado por mutación (3 de 8 fallan al romper el criterio) | — |
| 4.8 (direcciones) | frontend/__tests__/hooks/use-client-addresses.test.tsx, __tests__/lib/client-address.test.ts | Unit | — | módulos inexistentes | 15 PASS | mapeo, sin cliente, id escapado, vacío, clave; principal / primero con datos / vacío | — |
| 4.9 (DocumentPageStates) | frontend/__tests__/components/DocumentPageStates.test.tsx | Componente | Quote pages 115 PASS | módulo inexistente | 8 + 115 PASS sin tocar los tests del presupuesto | cuatro estados × documento remito; QuotePageStates muestra lo de siempre | QuotePageStates delega |
| 4.10 (translateRpcError) | frontend/__tests__/hooks/use-branches-translate-error-remitos.test.ts | Unit | branches 22 PASS | 2 de 5 fallaban | 5 + 22 PASS | token nuevo, no se confunde con los otros tres, desconocido tal cual | — |
| 5.3 (badge y anulación) | frontend/__tests__/components/DeliveryNoteStatusBadge.test.tsx, CancelDeliveryNoteDialog.test.tsx | Componente | — | módulos inexistentes | 16 PASS | tres estados con clases distintas y sin paleta; motivo vacío / de 2 / sólo espacios; revision 4 y 9 viajan tal cual; `delivery_note_changed` deja abierto con el motivo escrito; `insufficient_role` habla del remito | — |
| 5.1/5.2 (lib del formulario) | frontend/__tests__/lib/delivery-note-form.test.ts | Unit | — | módulo inexistente | 18 PASS | rehidratación sin `source`, `quantityBase` guardado, orden por `line_no`, producto dado de baja; payload con descuento adentro; 8 reglas de validación | — |
| 5.1/5.2 (DeliveryNoteForm) | frontend/__tests__/components/DeliveryNoteForm.test.tsx | Componente | — | módulo inexistente | 46 PASS | stock 2 en la sucursal y 12 en el agregado; acumulativo; cambio de sucursal re-valida sin borrar; retenido 3 con sucursal en 0 y línea nueva de 2 rechazada; resumen vuelven/salen y "no mueve stock"; balanza y código de barras contra la sucursal; domicilio tocado/no tocado; cliente de baja; producto de baja (tope, confirmación); `stock_insuficiente` del servidor con enlace | — |
| 5.4 (/remitos) | frontend/__tests__/DeliveryNotesPage.test.tsx | Página | — | módulo inexistente | 40 PASS | los tres parámetros de URL, chips removibles que reescriben la URL, `?estado=` válido e inválido, resumen singular/plural/vacío, CTA por 8 conjuntos de roles | — |
| 5.5 (nuevo y editar) | frontend/__tests__/DeliveryNoteFormPages.test.tsx, lib/delivery-note-status.test.ts (`canceledReason`) | Página + unit | — | módulos inexistentes; `canceledReason is not a function` | 24 + 35 PASS | espera de productos, unidades y sucursales; remonta sólo con otra `revision`; convertido (con y sin orden) y anulado (con y sin motivo) | — |
| 5.6 (/remitos/[id]) | frontend/__tests__/DeliveryNoteDetailPage.test.tsx, lib/delivery-note-share.test.ts, lib/delivery-note-status.test.ts | Página + unit | — | módulos inexistentes; `deliveryNoteFileName is not a function` | 31 + 8 + 35 PASS | matriz de roles x estados; switch fuera del menú; mutación (quitar `key`) hace fallar 2 casos; nota de crédito si la venta está autorizada | — |
| 5.7 (sidebar y breadcrumb) | frontend/__tests__/components/app-sidebar-nav-groups.test.ts, AppSidebarGroups.test.tsx, breadcrumb-nav-page-names.test.tsx | Estructura | 6 archivos de sidebar y breadcrumb PASS antes | 13 casos en rojo (32 rutas, 9 módulos, nombres) | 219 PASS | posición exacta tras Presupuestos, sin gate de plan, `/remitos/nuevo` no cae en la regla del detalle | — |
| 5.8 (ficha del cliente) | frontend/__tests__/components/ClientDetailHeaderDeliveryNotes.test.tsx | Componente | ClienteDetailLayout y Page 22 PASS | 13 de 15 en rojo | 15 PASS | 8 conjuntos de roles, id escapado, `aria-label` distintos, `min-w-0` y `truncate`, sin pestaña nueva | — |
| 5.9 (kardex) | frontend/__tests__/lib/stock-movement-label.test.ts, components/StockMovementsPanelDeliveryNotes.test.tsx | Unit + componente | stock-units-display PASS | módulo inexistente; 8 en rojo | 23 + 10 PASS | emisión / edición / anulación, sentido compra sin la R, sin número, segunda consulta con error o excepción, sin segunda consulta si no hay remitos, CSV con y sin número | — |
| 5.10 (baja de sucursal) | frontend/__tests__/components/DeactivateBranchDialog.test.tsx | Componente | BranchList-autoria PASS | 6 de 9 en rojo | 9 PASS | sin existencias / con remitos / con ambos / consulta cargando / consulta con error; singular | — |
