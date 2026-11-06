## Context

Fuente de verdad del alcance: `openspec/explore/2026-11-05-productos-padre-variantes.md`, sección "Revisión 2 — decisiones del PO 2026-11-05". **Sign-off del PO 2026-11-05**: el PO aprobó el plan y firmó las tres preguntas abiertas con la opción recomendada (ver Open Questions).

Estado medido en prod (`gxdhpxvdjjkmxhdkkwyb`, 2026-11-05, sólo `SELECT`):

- 5.521 productos vivos; 644 padres `variant_only` (258 con hijos), 233 padres `tracked` con hijos (38 con stock propio), 2.507 variantes en 494 padres de 9 cuentas.
- Padres `variant_only` con precio ≠ 0 o costo: **17**, en 2 cuentas (16 en `3834e5d7…` sin ventas; 1 en `c4145451…` con 1 línea de venta histórica). Los 17 tienen hijos con precio propio.
- Padres `variant_only` con unidad: 0. Variantes con unidad propia: 47.
- `fn_product_base_unit_guard` traba hoy el cambio de unidad en 472/494 padres con hijos (algún hijo tiene stock o movimientos).
- **Medición nueva de este propose** (líneas `sale_items`/`purchase_items` con `unit_id` explícito, por grupo padre + variantes): de los 494 grupos, **344** no tienen ninguna línea con unidad explícita (relabel libre a cualquier unidad), **149** tienen líneas en exactamente una unidad (relabel sólo hacia esa unidad; hacia otra → `unit_relabel_conflict`) y **1** tiene líneas en dos unidades (siempre en conflicto). El apply re-mide sumando `sales`, `purchases`, `sales_order_items`, `quote_items` y `delivery_note_items` (el mismo UNION del trigger).
- Markup real precio/costo muy disperso (65 de 782 entre 1,3 y 1,7; exactamente 1,5: 4) → 1,5 sólo puede ser sugerencia. 5 de 3.610 precios tienen centavos → redondear a pesos enteros no altera el criterio del catálogo.

Código vivo relevante (líneas de `main` `4825eb8f`), **reutilizado** antes que reescrito:

- `backend/services/products.py`: `create_product` (hereda la categoría del padre en el servidor), `update_product` (tri-estado por `model_fields_set` para `sku`/`category_id`/`cost`/`base_unit_id`/`scale_plu`; `_guard_base_unit_change` → 409 `base_unit_locked`), `bulk_set_category`, `_guard_scale_plu_not_parent` + `_translate_check_violation` (molde del 422 tipado del padre y de la traducción del `23514`).
- `backend/repositories/product_repository.py`: `_BULK_SET_CATEGORY_SQL` (expansión raíz → variantes, `AND p.account_id = $2`), `has_stock_or_movements`, `has_lines_in_other_unit` (el UNION de líneas por grupo).
- `backend/core/errors.py`: `problem_from_pg_error` / `pg_stable_code` (literal estable al inicio del `RAISE` → `code` RFC 7807).
- `backend/core/rbac.py` + `frontend/lib/rbac-capabilities.ts`: `CAN_CONFIGURE = {owner, admin}` (con test de paridad).
- SQL: `_account_assert_capability(account_id, roles[], mensaje)` (última definición en `20261083000001_multiusuario_operaciones.sql`), molde de `audit_logs (account_id, user_id, action, entity_type, entity_id, metadata, created_at)` de `20261088000001_edicion_operaciones_cimientos.sql`.
- `fn_product_base_unit_guard`: última definición en `supabase/migrations/20261069000001_remitos_venta.sql` L1331 (antes `20261062000001`); introspectada por `supabase/tests/test_remitos_venta.sql`; ejercida por `test_ventas_unidades_conversion.sql` y `test_ventas_unidades_conversion_race.sh`.
- Importador: `rpc_bulk_upsert_products`, última definición en `20261086000001_importador_productos_stock_apertura.sql`.
- Frontend: `components/forms/product-form.tsx` (597 líneas, un solo form), `components/products/product-catalog.tsx` (selección múltiple L165-370, barra de acción L515+, `onBulkRecategorize`), `lib/product-bulk-category.ts` (`chunkIds`, `BULK_CATEGORY_CHUNK_SIZE = 500`, `bulkRecategorizeInChunks`), `hooks/data/use-products.ts` (mutación `PATCH /products/bulk-category`).

**Regla de reescritura**: toda función existente que este change reescriba (`fn_product_base_unit_guard`; `rpc_bulk_upsert_products` sólo si el checkpoint 1.3 lo exige) SHALL re-derivarse en el apply desde `pg_get_functiondef` **vivo de prod** (md5 comparado por líneas sin CR contra el último archivo de migración), nunca desde el archivo. Las funciones nuevas nacen con `CREATE FUNCTION`; si una firma cambia, `DROP FUNCTION` + `CREATE` (gotcha `42725`), nunca `CREATE OR REPLACE` con `DEFAULT` distintos.

## Goals / Non-Goals

**Goals:**

- El usuario elige qué crea (simple o con variantes) y cada formulario pide sólo lo que ese tipo usa.
- El padre `variant_only` no tiene precio, costo, stock, stock mínimo, SKU, código de barras nuevo ni PLU, por contrato de API y (precio/costo) por CHECK de la base.
- La unidad de una familia se corrige en el padre y llega a todas las variantes aunque haya historia, sin reinterpretar en silencio: confirmación con impacto, rol, auditoría.
- Cambiar precios de muchos productos a la vez con vista previa y redondeo predecible.
- Sugerir el precio a partir del costo sin pisar nunca lo que el usuario escribió.

**Non-Goals:**

- Herencia de precio/costo del padre a las variantes (rechazada por el PO).
- Conversión real de cantidades al cambiar de unidad (kg → g): candidato `v3-uom-conversion`.
- Conversión asistida de los 233 padres `tracked` legados y limpieza de los 386 padres `variant_only` sin hijos (OQ-3, candidato posterior).
- Factor de sugerencia configurable por cuenta o categoría: candidato `markup-por-cuenta`.
- Costo en lote (el costo lo carga la compra).
- Sugerencia de precio en el importador.
- Entrada nueva de menú: todo vive en `/productos` (menú "Productos", grupo Catálogo, ya existente).

## Decisions

**D1 — Contrato del padre en el servidor: rechazo tipado, compatible con el bundle anterior.** `create_product` con `stock_control_type = 'variant_only'` responde `422` `parent_field_not_allowed` (`field` = el campo) si informa `price ≠ 0`, `cost` no nulo, `stock ≠ 0`, `min_stock ≠ 0`, `sku` no vacío, `barcode` no vacío o `parent_id` (un padre no es variante; un solo nivel, `modelo-dominio-aliadata-v2.md` §2.2). El PLU conserva su 422 propio (`scale_plu_parent`). En `update_product` sobre un `variant_only` el mismo 422 aplica sólo si el campo viene **con un valor distinto del vigente y distinto del neutro** (0 / NULL / vacío): así el formulario actual, que manda los valores vigentes en cada guardado, sigue funcionando entre la tanda A y la B (mismo criterio de compatibilidad que D9 de `stock-ledger-solo-rpc` con el `stock`), y los 71 códigos de barras legados se conservan (OQ-2). Mandar el neutro (limpiar) se acepta. *Alternativa descartada*: descartar en silencio lo que mande el cliente — oculta errores de integración y contradice "el servidor los rechaza".

**D2 — `stock_control_type` hacia o desde `variant_only` no se cambia por la API.** El modo se elige al crear ("¿Qué querés crear?"); `update_product` responde `422` `stock_control_type_locked` si el tipo efectivo pasaría a, o dejaría de ser, `variant_only`. Mandar el mismo tipo se acepta (el form actual manda `stockControlType` en cada guardado y conserva `variant_only`, `product-form.tsx` L109-111 y L252-254). Convertir padres legados es OQ-3 (fuera). *Alternativa*: permitir la transición limpiando precio/costo — escribiría datos que el usuario no pidió borrar y abre el caso "padre con stock propio" (RN-25) sin diseño.

**D3 — Padre sin precio/costo en la base: backfill + CHECK en la misma migración.** `UPDATE products SET price = 0, cost = NULL WHERE stock_control_type = 'variant_only' AND (price <> 0 OR cost IS NOT NULL)` (idempotente; 17 filas hoy; incluye filas borradas para que el CHECK valide sin `NOT VALID`), con una fila de `audit_logs` `product.parent_price_cleared` por producto (precio y costo anteriores en `metadata`, `user_id` NULL = migración) y luego `ALTER TABLE products ADD CONSTRAINT products_variant_only_no_price_cost CHECK (stock_control_type IS DISTINCT FROM 'variant_only' OR (price = 0 AND cost IS NULL))`. La línea de venta histórica del padre en `c4145451…` conserva su precio de línea (no se reescribe ningún `sale_items`). El servidor traduce el `23514` de este CHECK al mismo 422 `parent_field_not_allowed` (extiende `_translate_check_violation`). Sin herencia: `v_products_with_stock` no cambia. *Alternativa P2 (sin backfill)* descartada: dejaría 17 precios que el formulario ya no muestra ni deja corregir.

**D4 — La variante hereda unidad y categoría, también al editar.** Alta de variante: el servidor fija `base_unit_id = NULL` (hereda por `COALESCE(propia, padre)`, ya vigente en `v_products_with_stock` y `_uom_normalize_quantity`) ignorando lo que mande el cliente, igual que hoy con la categoría. Edición de variante: `base_unit_id` informado se ignora (no se valida ni escribe), espejo del tratamiento de `category_id` (`update_product`, L390-392). Las 47 variantes con unidad propia la conservan hasta un relabel de su padre (D5), que las deja heredando.

**D5 — Relabel A2: `rpc_relabel_product_unit(p_product_id uuid, p_new_unit_id uuid, p_dry_run boolean DEFAULT false) RETURNS jsonb`, `SECURITY DEFINER`, `SET search_path = public`.**

1. Resuelve la cuenta del producto y exige `is_account_writer` (`P0401 unauthorized`) y `_account_assert_capability(v_account, ARRAY['owner','admin'], 'tu rol no permite corregir la unidad de medida (requiere administrador o dueño)')` (`P0403 insufficient_role`).
2. Normaliza a la raíz (`COALESCE(parent_id, id)`); producto inexistente, borrado o ajeno → `P0404 product_not_found` (no revela existencia). `p_new_unit_id` nulo → `P0400 unit_required`; unidad no visible para la cuenta → `P0404 base_unit_not_found` (mismo predicado que el trigger).
3. Bloquea `FOR UPDATE` la raíz y luego las variantes vivas **por orden de id** (mismo orden que el trigger y que las RPCs de venta/compra, que toman la fila del producto antes de normalizar).
4. Conflicto: si alguna línea del grupo (`sales`, `purchases`, `sale_items`, `purchase_items`, `sales_order_items`, `quote_items`, `delivery_note_items` — el mismo UNION de `fn_product_base_unit_guard` y de `has_lines_in_other_unit`) tiene `unit_id` no nulo y distinto de `p_new_unit_id` → `P0409 unit_relabel_conflict` con la unidad en conflicto en el mensaje. En dry-run el conflicto viaja en el resultado (`conflict_unit`) en vez de lanzar, para que el diálogo lo explique.
5. Sin cambio (la raíz ya tiene esa unidad y ninguna variante tiene unidad propia) → `changed = false` sin escribir ni auditar (idempotente).
6. Escritura: `set_config('products.unit_relabel_root', <raíz>, true)` (local a la transacción), `UPDATE` de la raíz a `p_new_unit_id`, `UPDATE` de las variantes con unidad propia a `NULL`, y el GUC vuelve a vacío al terminar.
7. `audit_logs` `product.unit_relabel` con `metadata` = unidad anterior y nueva (de la raíz y de cada variante que tenía propia), cantidad de variantes, productos con stock ≠ 0 y cantidad de movimientos; `user_id = auth.uid()`.
8. Resultado (igual en dry-run): `{changed, root_id, unit_before, unit_after, variants, variants_with_own_unit, products_with_stock, movements, conflict_unit}`.

ACL: `REVOKE ALL ... FROM PUBLIC, anon; GRANT EXECUTE ... TO authenticated`. El backend la llama con la conexión del request (JWT-passthrough, nunca `service_role`).

**D6 — Salida del guard por GUC local, atado a la raíz.** `fn_product_base_unit_guard` se re-deriva del cuerpo vivo y gana, en la rama UPDATE y **después** del chequeo de tenencia de la unidad, un único corte: si `current_setting('products.unit_relabel_root', true)` es igual a `COALESCE(NEW.parent_id, NEW.id)::text`, `NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id` y `NEW.account_id = OLD.account_id`, devuelve `NEW` sin los chequeos de stock/historia. El GUC lo escribe sólo la RPC (D5), vale sólo para esa transacción y sólo para filas del grupo que la RPC ya bloqueó; re-parentar, cambiar de cuenta o tocar otro producto en la misma transacción siguen pasando por el guard completo. `authenticated` no puede escribir ese GUC por PostgREST (`set_config` vive en `pg_catalog`, fuera de los esquemas expuestos), así que un `PATCH` directo sigue recibiendo `P0409 base_unit_locked` — el gate lo assert-a. El 409 `base_unit_locked` de `update_product` (camino ordinario) no cambia. Se conservan COMMENT, ACL y el disparador (`CREATE OR REPLACE` con la misma firma `()`, sin argumentos: no aplica el gotcha `42725`). `test_remitos_venta.sql` y `test_ventas_unidades_conversion*.{sql,sh}` se re-ejecutan y, si comparan el cuerpo, se actualizan. *Alternativas*: relajar el trigger (abre el bloqueo para todos los escritores) o escribir con `session_replication_role = replica` (saltea también el guard de soft delete y el de tenencia de categoría).

**D7 — Endpoint del relabel.** `POST /products/{id}/relabel-unit` con `ProductUnitRelabelIn {base_unit_id: UUID, dry_run: bool = False}` → `ProductUnitRelabelOut` (el jsonb de D5 tipado). Servicio: `require_role` de plataforma + `require_account_role(conn, auth, CAN_CONFIGURE)` (defensa en profundidad del rol que exige la RPC) y delega en el repositorio; los errores de la RPC salen por `problem_from_pg_error` (`unit_relabel_conflict` → 409, `insufficient_role` → 403, `product_not_found`/`base_unit_not_found` → 404). Se reutiliza `CAN_CONFIGURE` (owner/admin) en vez de crear una constante nueva: es una corrección del catálogo y la constante ya tiene paridad TS/Python.

**D8 — Precios en lote: `rpc_bulk_adjust_prices(p_product_ids uuid[], p_mode text, p_direction text, p_value numeric, p_dry_run boolean DEFAULT false) RETURNS jsonb`, `SECURITY DEFINER`.**

- Validación: `p_mode ∈ {percent, amount}`, `p_direction ∈ {increase, decrease}`, `p_value > 0`; porcentaje efectivo entre −90 y +1000 (`decrease` admite hasta 90, `increase` hasta 1000); `cardinality(p_product_ids)` entre 1 y 500 → si no, `P0400` con literal estable (`bulk_price_invalid_mode`, `bulk_price_out_of_range`, `bulk_price_too_many_ids`, …).
- Guard: cuenta activa por `current_account_ids()`, `is_account_writer` (`P0401`) y `_account_assert_capability(v_account, ARRAY['owner','admin'], …)` (`P0403`).
- Alcance: los ids se normalizan a su raíz (`COALESCE(parent_id, id)`) filtrando `account_id = v_account AND deleted_at IS NULL` (ids ajenos no producen error ni revelan existencia); se expanden a raíz + variantes vivas; **se excluyen las filas `variant_only`** (no tienen precio, D3) y se cuentan en `skipped_parents`.
- Cálculo con signo `s = ±1`: `percent` → `product_round_price(price * (1 + s * value / 100))`; `amount` → `GREATEST(0, product_round_price(price + s * value))`. Una fila cuyo precio nuevo es igual al actual no se escribe y se cuenta en `unchanged`; las que el piso 0 acotó se cuentan en `clamped`.
- Un único `UPDATE products ... FROM (cálculo) WHERE account_id = v_account AND price IS DISTINCT FROM new_price`.
- Resultado: `{requested, eligible, changed, unchanged, skipped_parents, clamped, sample}` con `sample` = hasta 10 filas `{id, name, price_before, price_after}` por nombre; `p_dry_run = true` devuelve lo mismo sin escribir (la misma función da vista previa y aplicación, molde de `edicion-operaciones-con-dinero`).
- `audit_logs` `product.bulk_price_adjusted`: una fila por llamada no-dry-run con `changed > 0` (`metadata`: modo, dirección, valor, `changed`, `clamped`, ids cambiados).
- ACL: `REVOKE ... FROM PUBLIC, anon; GRANT EXECUTE ... TO authenticated`.

*Alternativa*: SQL de repositorio como `_BULK_SET_CATEGORY_SQL`. Descartada: el PO pide RPC con guard de tenencia propio, y así la vista previa y la regla de redondeo quedan en un solo lugar de la base, ejecutable por el gate.

**D9 — Una sola definición del redondeo.** SQL: `public.product_round_price(numeric) RETURNS numeric LANGUAGE sql IMMUTABLE` = `round(x, 0)` en `numeric` (mitad hacia afuera del cero). TS: `roundToPesos(n)` en `frontend/lib/product-pricing.ts` = `Math.sign(n) * Math.round(Math.abs(n))` (misma semántica). La paridad la sostiene una tabla de casos compartida (`supabase/tests/fixtures/product_round_price_cases.json`: 0,5 → 1; 1234,5 → 1235; 1234,49 → 1234; 2,675 → 3; 0 → 0) que lee el test de vitest y que el gate SQL replica literal (assert del md5 del contenido). La previsualización del diálogo usa la respuesta del servidor (dry-run), nunca un cálculo propio del cliente; `roundToPesos` lo usa la sugerencia (D11).

**D10 — Endpoint y troceo del lote.** `PATCH /products/bulk-price` con `ProductBulkPriceIn {product_ids: list[UUID] (1..500), mode: Literal['percent','amount'], direction: Literal['increase','decrease'], value: Decimal > 0, dry_run: bool = False}` → `ProductBulkPriceOut`. Declarado antes de `/{product_id}` (mismo cuidado que `bulk-category`). Servicio: `require_role` + `require_account_role(conn, auth, CAN_CONFIGURE)`; el repositorio llama la RPC. Frontend: `lib/product-bulk-category.ts` generaliza el troceo (`chunkIds` + un `runInChunks` genérico que agrega resultados) y la recategorización pasa a usarlo sin cambio de comportamiento. El lote de precios trocea en 500, cada bloque atómico, el lote completo no (mismo criterio que la categoría); si un bloque falla, el diálogo informa cuántos se aplicaron. La vista previa con más de 500 ids suma los dry-run de cada bloque (la muestra se toma del primero).

**D11 — Sugerencia de precio.** `frontend/lib/product-pricing.ts` exporta `SUGGESTED_MARKUP_FACTOR = 1.5`, `roundToPesos` y `suggestPriceFromCost(cost, factor = SUGGESTED_MARKUP_FACTOR): number | null` (`null` si el costo es nulo, ≤ 0 o no finito; si no, `roundToPesos(cost * factor)`). Regla de pisado en el formulario de producto simple y de variante: al cambiar el costo, el precio se reemplaza por la sugerencia **sólo si** está vacío/0 o es igual a `lastSuggestedPrice` (estado local); editar el precio a mano pone `lastSuggestedPrice = null` y la sugerencia deja de aplicarse. En la edición de un producto que ya trae precio > 0 no se sugiere (arranca con `lastSuggestedPrice = null`). Ayuda visible junto al campo ("Sugerido: costo × 1,5; podés cambiarlo"). El importador no se toca. La regla de pisado es una función pura (`nextPriceOnCostChange`) con test propio; el form sólo la conecta.

**D12 — Alta diferenciada por composición, no un form con más `if`.** `product-form.tsx` se parte en `ProductKindStep` ("¿Qué querés crear?", dos tarjetas con `role="radiogroup"`), `ParentProductForm` (nombre, categoría, unidad de la familia), `SimpleProductForm` y `VariantProductForm` (padre fijo, categoría y unidad de sólo lectura), compartiendo los bloques de campos existentes (código de barras con escáner/EAN-13, PLU, SKU, costo/precio con margen) extraídos a componentes del mismo directorio. Crear un padre pasa a "Agregar la primera variante" con el padre fijo. "Nueva variante" sigue desde la fila del padre (`handleAddVariant` de `productos/page.tsx`). La edición elige el formulario por modo: `variant_only` → padre; `parentId` → variante; producto `tracked`/`untracked` con hijos (los 233 legados) → formulario simple con el aviso "Este producto tiene variantes: lo que se vende es cada variante" (OQ-3, sin conversión); el resto → simple. Unidad del padre en edición: si el grupo tiene stock o movimientos, el selector de unidad se reemplaza por "Corregir unidad" (dueño/administrador) que abre el diálogo del relabel (D13); sin historia, sigue el camino ordinario de `PUT`.

**D13 — Diálogos con vista previa del servidor.** "Corregir unidad": elige la unidad nueva, llama `relabel-unit` con `dry_run = true` y muestra variantes afectadas, productos con stock, movimientos y un ejemplo con una cantidad real ("12 u pasarán a leerse 12 kg; no se convierte ninguna cantidad"); si hay `conflict_unit` lo explica y deshabilita confirmar; confirmar repite la llamada sin dry-run. "Modificar precios": dirección, modo, valor, vista previa (cambian / sin cambio / padres omitidos / acotados a $0, muestra antes → después) y aviso de que deshacer con el porcentaje inverso no es exacto por el redondeo. Ambos visibles sólo con `CAN_CONFIGURE` (hook de capacidad existente de `lib/rbac-capabilities.ts`). Listado: el padre muestra "desde $X" (mínimo precio de sus variantes vivas, calculado en el cliente sobre la lista ya cargada) en vez de su precio 0.

**D14 — Superficie y estética.** Todo en `/productos` (menú "Productos" existente, grupo Catálogo). Tokens semánticos y componentes base (`Dialog`, `Button` vía cva, `RadioGroup`); verificación a 375 px y en desktop, tema claro y oscuro, antes del merge de la tanda B.

## Risks / Trade-offs

- [Relabel entre unidades convertibles (kg → g) deja cantidades 1000 veces mal] → confirmación con ejemplo real y aviso "no se convierte ninguna cantidad"; sólo dueño/administrador; auditoría con la unidad anterior para revertir con otro relabel. Conversión real fuera (`v3-uom-conversion`).
- [149 grupos sólo admiten relabel hacia la unidad de sus líneas; 1 nunca] → `unit_relabel_conflict` explicado en la vista previa; no se reescriben líneas.
- [Carrera relabel vs venta/compra concurrente] → mismo orden de locks (raíz, variantes por id) que el trigger; test `supabase/tests/test_productos_padre_variantes_race.sh` en ambos órdenes, molde de `test_ventas_unidades_conversion_race.sh`.
- [El GUC del relabel abre una puerta en el guard] → atado a la raíz, local a la transacción, inaccesible por PostgREST; gate que intenta el `PATCH` directo y espera `P0409`.
- [El CHECK rompe a un escritor que manda precio a un padre] → backfill antes del CHECK; el servidor rechaza antes con 422; checkpoint 1.3 sobre `rpc_bulk_upsert_products`; gate del importador re-ejecutado.
- [Aumento en lote mal tipeado (100 en vez de 10)] → vista previa obligatoria del servidor, topes −90/+1000, auditoría por lote.
- [Redondeo divergente SQL/TS] → una definición por lenguaje con tabla de casos compartida y assert de paridad.
- [Ventana entre tanda A y B con el formulario viejo] → D1/D2 aceptan los valores vigentes; el form viejo sólo manda un valor distinto en un padre si el usuario lo escribe, y entonces el 422 es el comportamiento buscado.
- [Introspección del guard en gates existentes] → re-ejecutar `test_remitos_venta.sql` y `test_ventas_unidades_conversion*` en el apply.

## Migration Plan

1. Migración `20261093000001_productos_padre_variantes.sql` (el último en `supabase/migrations/` es `20261091000001` y `20261092000001` está reservado por el propose mergeado de `mp-cuota-acreditacion-resiliente`, #677; re-verificar al aplicar), en orden: helper `product_round_price`; backfill auditado de los padres con precio/costo; CHECK; `fn_product_base_unit_guard` re-derivado del vivo con el corte del GUC; `rpc_relabel_product_unit`; `rpc_bulk_adjust_prices`; ACLs (`REVOKE` de `anon`/`PUBLIC`); bloque final de introspección que aborta la migración si el corte del guard, el CHECK o las ACLs no quedaron como se espera.
2. Deploy por el pipeline normal (merge → `supabase db push`); nunca MCP `apply_migration`.
3. Verificación post-merge en prod (sólo `SELECT`): `MAX(version) = 20261093000001`, 0 padres `variant_only` con precio/costo, CHECK presente y validado, ACLs sin `anon`, cuerpo vivo del guard con el corte.
4. Rollback: `DROP CONSTRAINT products_variant_only_no_price_cost`; `DROP FUNCTION` de las dos RPCs y del helper; restaurar el cuerpo previo del guard (guardado en el apply desde el `pg_get_functiondef` vivo). El backfill no se revierte (los valores anteriores quedan en `audit_logs`).
5. Tanda B (frontend) recién con la A en prod.

## Open Questions

Todas resueltas — **Sign-off del PO 2026-11-05** (opción recomendada en las tres):

- **OQ-1 — Unidad con historia**: se permite el relabel sin convertir cantidades, sólo dueño/administrador, con confirmación que muestra el impacto (variantes, stock, movimientos) y auditoría. Formaliza D-C: el bloqueo sigue siendo el default; el relabel es la excepción. → D5, D6, D13.
- **OQ-2 — 71 padres `variant_only` con código de barras**: lo conservan; no se limpia ni se vuelve a pedir en el formulario; el servidor sólo rechaza asignar uno distinto. → D1.
- **OQ-3 — 233 padres `tracked` con hijos (38 con stock propio)**: se muestran como padre sin conversión; la conversión asistida es candidato posterior. → D2, D12.
- Resueltas por el PO en la revisión 2: sin herencia de precio/costo; entran el modificador en lote (sólo precio) y la sugerencia × 1,5 (sin importador).

## Notas de implementación de la tanda A

Tanda A = grupos 1-7 (DB + backend, sin cambio visible). Migración **`20261093000001_productos_padre_variantes.sql`** (`20261092000001` ya estaba en `main` y en prod desde #678; `20261093000001` verificado libre). Lo que el apply midió, decidió o desvió respecto de este documento:

**Mediciones del checkpoint 1.1 (prod, 2026-11-05, sólo `SELECT`).** Padres `variant_only` con precio/costo: **18** (el propose midió 17: apareció uno entre medio; el backfill los limpia a todos y audita cada uno). Grupos padre + variantes vivos por conflicto de unidad, sumando las siete tablas de líneas: **341 libres / 149 con una unidad / 1 mixta** (491 grupos vivos; el propose contó 344/149/1 sobre 494: tres grupos se borraron o quedaron sin hijos vivos). `schema_migrations`: `max(version) = 20261092000001`.

**Checkpoint 1.2 — guard.** El `pg_get_functiondef` vivo de `fn_product_base_unit_guard` tiene md5 (sin CR) `89b462c5169f867da49610d84b4d4962`, **idéntico** al de la base local construida desde `20261069000001_remitos_venta.sql` L1331: sin divergencia. La migración parte del cuerpo vivo y agrega **un solo bloque** (D6): inmediatamente después del chequeo de tenencia de la unidad y antes del primer `RETURN NEW` de la rama UPDATE,

```sql
IF TG_OP = 'UPDATE' THEN
  IF NULLIF(current_setting('products.unit_relabel_root', true), '') = COALESCE(NEW.parent_id, NEW.id)::text THEN
    IF NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id AND NEW.account_id = OLD.account_id THEN
      RETURN NEW;
    END IF;
  END IF;
END IF;
```

Anidado y no con `AND`: `OLD` no existe en un `INSERT` y el orden de evaluación de un `AND` no está garantizado. COMMENT, ACL y disparador se conservan (`CREATE OR REPLACE`, misma firma `()`); el COMMENT vivo todavía dice «provisorio hasta el sign-off del PO» (D-C ya está firmado): queda como candidato de limpieza, no se tocó por la regla de conservar el COMMENT. Control negativo ejecutado: con el corte sin atar a la raíz (`<> ''` y sin la condición de padre/cuenta) fallan los tres casos de D7 del gate (GUC de otra raíz, re-parent, desenganche).

**Checkpoint 1.3 — importador: SÍ cambia.** `rpc_bulk_upsert_products` (md5 vivo `30730c94469dc0a5ad98f1905608af46`, igual al de `20261086000001`) dejaba un `variant_only` con precio/costo en dos ramas: el alta de la fila Padre (`price`/`cost` del archivo) y la edición por SKU de un producto existente que pasa a Padre (`COALESCE(price, price)`). Con el CHECK, ambas habrían dado un error de fila críptico. Se rederivó del vivo (misma firma, `CREATE OR REPLACE`, ACL intacta: sólo `service_role`) forzando `price = 0` y `cost = NULL` cuando el tipo **efectivo** de la fila es `variant_only` (el de la fila si viene; si no, el vigente). Un producto simple no cambia. Convertir por el importador un producto con precio en Padre le borra el precio (el CHECK no admite otra cosa; queda en la fila de audit del backfill sólo para el que ya estaba así).

**Checkpoint 1.4 — callers.** Ocho gates SQL insertaban padres `variant_only` con precio/costo (o costo 0) y dejaron de poder correr con el CHECK: `test_remitos_venta`, `test_remitos_compra`, `test_presupuestos_modulo`, `test_stock_ledger_solo_rpc`, `test_kpis_edge_cases`, `test_dashboard_critical_stock_items`, `test_ventas_unidades_conversion` (9 inserts) y `test_ventas_unidades_conversion_race.sh` (5 inserts): sus fixtures pasan a `price = 0, cost = NULL`. Los gates del importador (`test_bulk_upsert_products_categories`, `test_importador_stock_apertura`) y `test_balanza_etiquetas_pos` corren sin cambios. Un test del backend cambió de premisa a propósito: `test_convert_to_variant_only_clearing_plu_passes` (`test_products_scale_plu.py`) convertía un producto en padre por `PUT`, lo que D2 ahora prohíbe; pasó a probar que un padre que reenvía `variant_only` puede limpiar un PLU heredado.

**Desvíos respecto del design.**

- **DV-1 — `min_stock` en el alta de un padre se tolera (D1).** D1/tasks 3.1 piden rechazar `min_stock ≠ 0`. El formulario **anterior** (`product-form.tsx`, `minStock` con default 10) lo manda siempre al crear un padre: rechazarlo rompería el alta de padres desde la UI entre el deploy de la tanda A y el de la B, que es justo la ventana que D1 quiso proteger para la edición ("mismo criterio de compatibilidad"). El servidor lo acepta y lo **neutraliza a 0** (un padre no usa stock mínimo). Los demás campos (precio, costo, stock, SKU, código de barras, `parent_id`) se rechazan tal cual D1. En la **edición** no hay desvío: `min_stock` con un valor distinto del vigente es 422. Para volver a la letra del design basta quitar `min_stock` del `data.update(...)` de `create_product` y pasarlo al `_guard_parent_contract`.
- **DV-2 — el relabel sin efecto se evalúa antes del conflicto (D5 pasos 4-5).** D5 pone el chequeo de conflicto antes del «sin cambio»; una llamada idempotente sobre una familia que **ya** tiene esa unidad pero con líneas en otra unidad habría dado `unit_relabel_conflict` aunque nada fuera a cambiar. Se invirtió: primero `changed = false` (nada se escribe ni se audita), después el conflicto. No cambia ningún escenario del spec.
- **DV-3 — `requested` de `rpc_bulk_adjust_prices` cuenta ids distintos** (igual que `bulk_set_category`), y `clamped` cuenta sólo las filas que cambian y se acotaron (bajar lo que ya vale 0 no es «acotado»).
- **Relabel y la fila de la raíz borrada.** Un id de una variante cuya raíz está borrada responde `P0404 product_not_found` (la raíz no se puede tomar viva).

**Decisiones de implementación.**

- El gate SQL **reaplica el archivo de la migración con `\i`** dentro de su transacción (quita el CHECK, arma el estado viejo con un padre borrado, y la corre dos veces): así el backfill, la idempotencia y las funciones se ejercitan de verdad sin una función auxiliar permanente. Requiere correr desde la raíz del repo (el `\i` y el `\set` con backtick usan rutas relativas) y la migración no puede traer `BEGIN`/`COMMIT`.
- La tabla de casos del redondeo (`supabase/tests/fixtures/product_round_price_cases.json`) la lee el gate con `\set … `cat``; la tanda B la lee el vitest: una sola fuente.
- Reutilizado: `_account_assert_capability` (P0401/P0403 en las dos RPCs), `has_lines_in_other_unit` (su UNION de siete tablas, replicado en SQL con el mismo conjunto), `current_account_ids()`, `problem_from_pg_error`, `CAN_CONFIGURE`, `require_account_role`, el molde de `_translate_check_violation` / `_guard_scale_plu_not_parent` (el helper nuevo `_guard_parent_contract` sirve al alta y a la edición) y el molde de `test_ventas_unidades_conversion_race.sh`. **Extraído**: `require_account_capability` en `backend/core/guards.py` (el envoltorio «403 como RFC 7807 con `code=insufficient_role`» ya existía duplicado en `services/quotes.py` y `services/delivery_notes.py`; ésta es la tercera copia, así que nace en la capa canónica; migrar las otras dos queda como candidato).
- CI: el gate corre con el wrapper estricto (`run_gate_strict.py`) y por eso entra a `MONEY_GATES` de `backend/tests/test_gate_strict_detector.py` (35 → 36); la migración se suma al paso de reaplicación idempotente (`Verify G1/G4 migrations are idempotent on reapply`), con el diff de schema, 0 padres con precio/costo, CHECK validado y el corte del guard presente.
- Los `Decimal` de `ProductBulkPriceOut` / `ProductUnitRelabelOut` salen como **string** en el JSON (convención del proyecto): la tanda B los parsea.

**Ventana tanda A → tanda B (formulario anterior).** El formulario anterior sigue funcionando: edita padres reenviando los valores vigentes (D1), crea padres (precio 0, costo `null`, código `""`, `minStock` tolerado por DV-1) y no manda `baseUnitId` en una variante. Lo único que cambia para el usuario: un padre al que se le **escriba** precio, costo, SKU o código de barras nuevo ahora responde `422 parent_field_not_allowed` (el comportamiento buscado), y convertir un producto en padre por la API ya no se puede.
