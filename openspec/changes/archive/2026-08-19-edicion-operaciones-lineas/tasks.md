# Tasks — `edicion-operaciones-lineas`

> Strict TDD. Cada grupo de implementación arranca con su gate SQL en RED (grupo 1),
> pasa a GREEN con la migración, triangula y recién ahí se marca `[x]`.
> Governance MEDIUM: el enfoque de snapshot (design §D2) y el backfill (§D6) se
> exponen en el PR para revisión del PO. **El grupo 6 no se ejecuta sin sign-off.**

## 1. RED — Gates de comportamiento primero

- [x] 1.1 Crear `supabase/tests/test_operation_edit_lines.sql` siguiendo el patrón de `test_sale_items_rpc_v2_activation.sql`: anchors sintéticos vía `handle_new_user`, sesión simulada con `set_config` local a la transacción (NUNCA contra prod), fallos acumulados en `text[]` y un solo `RAISE EXCEPTION` final.
- [x] 1.2 Gate: editar **cantidad** de una operación de venta con línea → 1 sola fila en `sale_items`, cantidad nueva, `subtotal` = total del header, y `unit_cost_snapshot` **idéntico** al original **habiendo movido `products.cost` entre la creación y la edición** (control positivo del acarreo).
- [x] 1.3 Gate: editar **precio unitario** → `price`/`subtotal` nuevos, `unit_cost_snapshot` intacto.
- [x] 1.4 Gate: editar **producto** (A→B) → la línea referencia a B con `unit_cost_snapshot` = costo actual de B y `name_snapshot` de B; control negativo explícito: no conserva nada de A.
- [x] 1.5 Gate: editar una operación **sin línea previa** → la línea nace con snapshot fresco.
- [x] 1.6 Gate: **línea de servicio** (`product_id NULL`) → ninguna fila en `sale_items`, sin error.
- [x] 1.7 Gate: espejo completo de 1.2–1.6 para **compras**, más la verificación de que el header `purchases` queda con `name_snapshot`/`sku_snapshot`/`unit_cost_snapshot` poblados (acarreados o frescos según corresponda).
- [x] 1.8 Gate: **kill-switch** (`account_feature_flags.enabled = false` para `sale_items_rpc_v2`) → la edición no escribe línea; header y stock se comportan igual.
- [x] 1.9 Gate: **no regresión de stock y guards** → `branch_stock` neto correcto tras la edición y los códigos `P0400` (cantidad ≤ 0), `P0403` (producto ajeno), `P0409` (stock insuficiente) y `P0422` (producto con variantes) siguen disparando.
- [x] 1.10 Gate: **higiene referencial** → tras la edición no queda ninguna fila de `sale_items`/`purchase_items` cuyo padre no exista, ni más de una línea por fila de header.
- [x] 1.11 Gate: **doble submit** → segunda llamada con los ids ya borrados falla con `P0404` y no deja líneas duplicadas ni huérfanas.
- [x] 1.12 Ejecutar el archivo contra el stack local y **confirmar que falla** (RED real): dejar registrado qué aserción falla y por qué, antes de escribir una sola línea de la migración.

## 2. Safety net — línea base antes de tocar las RPCs

- [x] 2.1 Correr los gates SQL existentes contra el stack local y capturar la baseline: `test_kpis.sql`, `test_kpis_edge_cases.sql`, `test_sale_items_rpc_v2_activation.sql`, `test_idempotency.sql`, `test_function_acl_gate.sql`, `test_branch_stock.sql`. Cualquier fallo previo se reporta como pre-existente y NO se arregla acá.
- [x] 2.2 Correr `pytest` de `backend/tests/test_sales.py` y `test_purchases.py` (cubren `PUT /*/operation`) y registrar el conteo verde de partida.
- [x] 2.3 Verificar en prod (SOLO SELECT) que `MAX(version)` en `supabase_migrations.schema_migrations` sigue siendo `20260925000001`, y que la definición vigente de ambas RPCs coincide con la de `20260623000001_c21_checkpoint2_drop_products_stock.sql` (la migración sale de esa base, no de otra).

## 3. GREEN — Migración

- [x] 3.1 Crear `supabase/migrations/20260926000001_edicion_operaciones_lineas.sql` con cabecera que documente el hallazgo (CASCADE + DELETE = la edición destruye la línea) y la política de snapshot elegida.
- [x] 3.2 `CREATE OR REPLACE FUNCTION public.op_line_snapshot(p_prev jsonb, p_name text, p_sku text, p_cost numeric) RETURNS jsonb` — `IMMUTABLE`, `SECURITY INVOKER`, `SET search_path = public`, sin I/O; devuelve el snapshot acarreado si `p_prev` no es NULL, o el fresco en caso contrario. `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon, authenticated` en el mismo archivo.
- [x] 3.3 `CREATE OR REPLACE` de `rpc_atomic_update_sale_operation` con la **misma firma exacta** `(uuid[], uuid, date, text, jsonb)`: resolución del flag `sale_items_rpc_v2` con el patrón `COALESCE(..., true)`; captura `DISTINCT ON (product_id) ... ORDER BY product_id, id` de los snapshots viejos **antes** del `DELETE`; `INSERT` de `sale_items` dentro del bloque de producto, reutilizando el `SELECT ... FOR UPDATE` de `products` que ya existe (sin lecturas nuevas).
- [x] 3.4 `CREATE OR REPLACE` de `rpc_atomic_update_purchase_operation` `(uuid[], date, text, jsonb)` con la misma estructura, y además el poblado de `name_snapshot`/`sku_snapshot`/`unit_cost_snapshot` en el `INSERT` del header `purchases` (design §D5).
- [x] 3.5 Re-declarar al pie `GRANT EXECUTE ... TO authenticated` y `REVOKE ... FROM anon` para ambas RPCs (idempotente; preserva las ACLs vigentes y protege ante un futuro cambio de firma).
- [x] 3.6 Verificar que la migración es reejecutable: aplicarla dos veces sobre el stack local y comparar un fingerprint before/after (conteo de `sale_items`, `purchase_items`, y `pg_get_functiondef` de las dos RPCs), como hace el paso de idempotencia ya existente en `KPI_Validation.yml`.
- [x] 3.7 Confirmar que **no** se cambiaron guards, códigos de error, gate de stock ni tenancy respecto de la definición previa (diff dirigido contra `20260623000001`).

## 4. TRIANGULAR + REFACTOR

- [x] 4.1 Correr `test_operation_edit_lines.sql` → GREEN. Cada gate del grupo 1 pasa.
- [x] 4.2 Agregar el caso de colisión: dos líneas viejas con el mismo `product_id` → el acarreo es determinístico y la reejecución da el mismo resultado.
- [x] 4.3 Agregar el caso mixto: operación de 2 ítems donde uno conserva producto y el otro lo cambia → uno acarrea, el otro re-snapshotea, en la misma edición.
- [x] 4.4 Re-correr la baseline del grupo 2 completa → sin regresiones.
- [x] 4.5 Refactor: verificar que la decisión de snapshot vive en un solo lugar (`op_line_snapshot`) y no quedó duplicada entre venta y compra; tests verdes después de cada paso.

## 5. CI y verificación

- [x] 5.1 Registrar el paso nuevo en `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1` (sin él, un `RAISE EXCEPTION` sale en verde) y un comentario que explique qué invariante protege.
- [x] 5.2 Abrir PR desde rama propia (nunca commit directo a `main`) con el resumen del hallazgo, la política de snapshot y las OQ-A..G del design a la vista del PO.
- [x] 5.3 Con los checks verdes, mergear. El merge dispara build + deploy + aplicación automática de la migración.
- [x] 5.4 Verificación post-deploy en prod (SOLO SELECT): que `20260926000001` figure en `schema_migrations`, que `pg_get_functiondef` de ambas RPCs mencione `sale_items`/`purchase_items`, y que el conteo de operaciones sin línea **no crezca** en las horas siguientes.

## 6. Backfill histórico — GATEADO a sign-off del PO

> **No ejecutar sin aprobación explícita.** No es migración: el merge no debe mutar datos.

- [x] 6.1 Presentar al PO la recomendación del design §D6 con los números medidos: 119 ventas y 186 compras con producto sin línea; 179/186 compras con `unit_cost_snapshot` genuino en el header; costo histórico de las ventas incognoscible.
- [x] 6.2 Escribir `scripts/sql/backfill_operation_lines.sql`: idempotente (`WHERE NOT EXISTS`), con conteos dry-run impresos al inicio y al final, y transacción única.
- [x] 6.3 Compras: `unit_cost_snapshot`/`name_snapshot`/`sku_snapshot` **desde el header** cuando estén congelados → `snapshot_backfilled = false`; sin snapshot en el header → costo `NULL`, `snapshot_backfilled = true`.
- [x] 6.4 Ventas: `name_snapshot`/`sku_snapshot` desde el maestro actual, `unit_cost_snapshot = NULL`, `snapshot_backfilled = true`. Documentar el sesgo en la cabecera del script: el margen de esas ventas se calcula a costo corriente, no a costo congelado.
- [x] 6.5 Gate de reejecución del backfill en el stack local: correrlo dos veces y verificar cero filas afectadas en la segunda corrida.
- [x] 6.6 Verificar que ninguna KPI se mueve por el backfill (el margen sale igual por `COALESCE(unit_cost_snapshot, products.cost)`) y que las líneas de servicio (`product_id NULL`) siguen sin fila.
- [x] 6.7 Tras el sign-off: ejecutar contra prod con los conteos a la vista y registrar el antes/después.

## 7. Cierre

- [x] 7.1 Marcar en `CHANGES.md` la deuda OQ-1 de `deudas-menores-agosto` como cerrada, y OQ-2 según el resultado del grupo 6.
- [x] 7.2 Registrar las OQ-A..G del design como deudas con dueño en `CHANGES.md` (identidad de la operación, `stock_movements` en la edición, edición de lo facturado, `branch_id`/`canal`/`unit_id`/`cost_center_id` perdidos, cta cte, telemetría duplicada, `quantity integer`).
- [x] 7.3 `openspec validate "edicion-operaciones-lineas" --strict` en verde y archive del change.
