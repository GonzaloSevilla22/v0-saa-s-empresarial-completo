-- =============================================================================
-- backfill_stock_movements_operaciones.sql
--
-- stock-movements-edicion (Grupo 5) — sign-off PO 2026-08-19 (204 operaciones
-- delete-inseguras: 112 ventas + 92 compras). Política de design.md §D6.
--
-- SOLO INSERT. NUNCA toca branch_stock: el saldo YA ES CORRECTO (la edición
-- sí movió branch_stock — el hueco es solo el asiento en el ledger). Un
-- backfill que "reponga" stock corrompería el saldo de toda cuenta editada.
-- Si lo estás leyendo antes de ejecutar: esto es lo primero que hay que
-- entender.
--
-- NO ES UNA MIGRACIÓN. NO debe copiarse a supabase/migrations/ — el merge a
-- main aplica migraciones automáticamente y un backfill de datos gateado a
-- sign-off no puede viajar en ese tren. Se ejecuta a mano UNA sola vez, con
-- los conteos dry-run a la vista, contra el proyecto prod real
-- (gxdhpxvdjjkmxhdkkwyb) vía MCP execute_sql, o localmente con:
--   psql "$DATABASE_URL" -f scripts/sql/backfill_stock_movements_operaciones.sql
--
-- ── Alcance A — cero movimientos (99 ventas + N compras, ver conteo dry-run) ──
-- Filas vivas con product_id y NINGÚN movimiento (`NOT EXISTS (... WHERE
-- reference_id = <fila>.id)`). Se les inserta el movimiento que la creación
-- (o una edición correcta) habría dejado: type='sale'|'purchase',
-- reference_type='sale'|'purchase' — el contrato que rpc_reverse_stock_
-- movement necesita para reponer stock al eliminar. quantity_before/after
-- quedan NULL (no se puede reconstruir el instante histórico exacto, y no se
-- va a inventar). unit_cost_snapshot: de sale_items/purchase_items si la fila
-- ya tiene línea (edicion-operaciones-lineas la pudo haber creado), si no
-- NULL — nunca se congela el costo ACTUAL como si fuera el histórico.
--
-- ── Alcance B — 13 ventas (+ N compras, ver conteo) con el bug de mayo ────────
-- 20260527000002_wire_movements_to_rpcs.sql usó reference_type='sale_update'/
-- 'purchase_update' en AMBAS patas (REVERSE y APPLY) — así que estas filas SÍ
-- tienen un movimiento, pero con reference_type='sale_update' en vez de
-- 'sale' (el que el delete path filtra). Re-apuntar ese reference_type sería
-- un UPDATE, prohibido por RN-21 (ledger append-only, policies UPDATE/DELETE
-- con qual=false). Alternativa append-only, elegida por el PO: par sintético
-- de NETO CERO sobre el ledger —
--   (a) CANCELA el movimiento viejo: mismo reference_id, reference_type
--       'sale_update'/'purchase_update' (queda igual de "cerrado" que
--       cualquier *_update), quantity_delta invertido.
--   (b) INSERTA el correcto: mismo reference_id, reference_type
--       'sale'/'purchase', mismo quantity_delta que el viejo.
-- Los dos movimientos originales de mayo (REVERSE + APPLY) NO se tocan —
-- permanecen como evidencia histórica; el par sintético convive con ellos.
--
-- ── Idempotente ──────────────────────────────────────────────────────────────
-- Cada INSERT filtra por NOT EXISTS sobre la condición que el propio INSERT
-- resuelve (movimiento reference_type='sale'|'purchase' presente) — re-
-- ejecutar el script completo afecta 0 filas la segunda vez. Verificado
-- localmente con datos sintéticos antes de tocar prod (ver PR).
--
-- ── Transacción única ─────────────────────────────────────────────────────────
-- BEGIN/COMMIT envuelve los 4 INSERT. Si se pega el bloque en el MCP
-- execute_sql (que ya envuelve su propia transacción), el BEGIN interno
-- emite un WARNING inocuo y sigue en la misma transacción — el COMMIT cierra
-- ahí; el efecto de los 4 INSERT sigue siendo atómico.
-- =============================================================================

-- ── Conteos ANTES (dry-run) ──────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM public.sales s
     WHERE s.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = s.id))
    AS ventas_alcance_a_cero_movimientos,
  (SELECT count(*) FROM public.purchases p
     WHERE p.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = p.id))
    AS compras_alcance_a_cero_movimientos,
  (SELECT count(*) FROM public.sales s
     JOIN public.stock_movements sm ON sm.reference_id = s.id
     WHERE s.product_id IS NOT NULL AND sm.reference_type = 'sale_update' AND sm.type = 'sale'
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm2 WHERE sm2.reference_id = s.id AND sm2.reference_type = 'sale'))
    AS ventas_alcance_b_bug_mayo,
  (SELECT count(*) FROM public.purchases p
     JOIN public.stock_movements sm ON sm.reference_id = p.id
     WHERE p.product_id IS NOT NULL AND sm.reference_type = 'purchase_update' AND sm.type = 'purchase'
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm2 WHERE sm2.reference_id = p.id AND sm2.reference_type = 'purchase'))
    AS compras_alcance_b_bug_mayo,
  (SELECT count(*) FROM public.sales s
     WHERE s.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = s.id AND sm.reference_type = 'sale'))
    AS ventas_delete_inseguras_total,
  (SELECT count(*) FROM public.purchases p
     WHERE p.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = p.id AND sm.reference_type = 'purchase'))
    AS compras_delete_inseguras_total;

BEGIN;

-- ── 1) Alcance A — ventas sin ningún movimiento ──────────────────────────────
INSERT INTO public.stock_movements (
  user_id, account_id, product_id, product_name, type,
  quantity_delta, quantity_before, quantity_after,
  reference_id, reference_type, performed_by,
  operation_group_id, branch_id, unit_cost_snapshot,
  reason, metadata
)
SELECT
  s.user_id, s.account_id, s.product_id, pr.name, 'sale',
  -s.quantity, NULL, NULL,
  s.id, 'sale', s.user_id,
  s.operation_id, COALESCE(s.branch_id, public.c26_default_branch(s.account_id)), si.unit_cost_snapshot,
  'backfill_edicion_sin_movimiento',
  jsonb_build_object('backfilled', true, 'change', 'stock-movements-edicion')
FROM public.sales s
JOIN public.products pr ON pr.id = s.product_id
LEFT JOIN public.sale_items si ON si.sale_id = s.id
WHERE s.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = s.id);

-- ── 2) Alcance A — compras sin ningún movimiento ─────────────────────────────
INSERT INTO public.stock_movements (
  user_id, account_id, product_id, product_name, type,
  quantity_delta, quantity_before, quantity_after,
  reference_id, reference_type, performed_by,
  operation_group_id, branch_id, unit_cost_snapshot,
  reason, metadata
)
SELECT
  p.user_id, p.account_id, p.product_id, COALESCE(p.name_snapshot, pr.name), 'purchase',
  p.quantity, NULL, NULL,
  p.id, 'purchase', p.user_id,
  p.operation_id, COALESCE(p.branch_id, public.c26_default_branch(p.account_id)), p.unit_cost_snapshot,
  'backfill_edicion_sin_movimiento',
  jsonb_build_object('backfilled', true, 'change', 'stock-movements-edicion')
FROM public.purchases p
JOIN public.products pr ON pr.id = p.product_id
WHERE p.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = p.id);

-- ── 3) Alcance B — ventas con el bug de mayo (par sintético, neto cero) ──────
-- Cancela el viejo (mismo reference_type sale_update — queda igual de
-- "cerrado" que cualquier *_update) e inserta el correcto (reference_type
-- 'sale'), leyendo TODO desde el movimiento viejo (mismo producto, sucursal,
-- costo congelado, grupo de operación) — no se inventa nada nuevo.
INSERT INTO public.stock_movements (
  user_id, account_id, product_id, product_name, type,
  quantity_delta, quantity_before, quantity_after,
  reference_id, reference_type, performed_by,
  operation_group_id, branch_id, unit_cost_snapshot,
  reason, metadata
)
SELECT
  old.user_id, old.account_id, old.product_id, old.product_name, 'sale_return',
  -old.quantity_delta, NULL, NULL,
  old.reference_id, 'sale_update', old.user_id,
  old.operation_group_id, old.branch_id, old.unit_cost_snapshot,
  'backfill_edicion_cierre_bug_mayo',
  jsonb_build_object('backfilled', true, 'change', 'stock-movements-edicion', 'closes_movement_id', old.id)
FROM public.stock_movements old
JOIN public.sales s ON s.id = old.reference_id
WHERE old.reference_type = 'sale_update' AND old.type = 'sale' AND s.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm2 WHERE sm2.reference_id = old.reference_id AND sm2.reference_type = 'sale');

INSERT INTO public.stock_movements (
  user_id, account_id, product_id, product_name, type,
  quantity_delta, quantity_before, quantity_after,
  reference_id, reference_type, performed_by,
  operation_group_id, branch_id, unit_cost_snapshot,
  reason, metadata
)
SELECT
  old.user_id, old.account_id, old.product_id, old.product_name, 'sale',
  old.quantity_delta, NULL, NULL,
  old.reference_id, 'sale', old.user_id,
  old.operation_group_id, old.branch_id, old.unit_cost_snapshot,
  'backfill_edicion_reapunte_bug_mayo',
  jsonb_build_object('backfilled', true, 'change', 'stock-movements-edicion', 'supersedes_movement_id', old.id)
FROM public.stock_movements old
JOIN public.sales s ON s.id = old.reference_id
WHERE old.reference_type = 'sale_update' AND old.type = 'sale' AND s.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm2 WHERE sm2.reference_id = old.reference_id AND sm2.reference_type = 'sale');

-- ── 4) Alcance B — compras con el mismo bug (si el conteo dry-run > 0) ───────
INSERT INTO public.stock_movements (
  user_id, account_id, product_id, product_name, type,
  quantity_delta, quantity_before, quantity_after,
  reference_id, reference_type, performed_by,
  operation_group_id, branch_id, unit_cost_snapshot,
  reason, metadata
)
SELECT
  old.user_id, old.account_id, old.product_id, old.product_name, 'purchase_return',
  -old.quantity_delta, NULL, NULL,
  old.reference_id, 'purchase_update', old.user_id,
  old.operation_group_id, old.branch_id, old.unit_cost_snapshot,
  'backfill_edicion_cierre_bug_mayo',
  jsonb_build_object('backfilled', true, 'change', 'stock-movements-edicion', 'closes_movement_id', old.id)
FROM public.stock_movements old
JOIN public.purchases p ON p.id = old.reference_id
WHERE old.reference_type = 'purchase_update' AND old.type = 'purchase' AND p.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm2 WHERE sm2.reference_id = old.reference_id AND sm2.reference_type = 'purchase');

INSERT INTO public.stock_movements (
  user_id, account_id, product_id, product_name, type,
  quantity_delta, quantity_before, quantity_after,
  reference_id, reference_type, performed_by,
  operation_group_id, branch_id, unit_cost_snapshot,
  reason, metadata
)
SELECT
  old.user_id, old.account_id, old.product_id, old.product_name, 'purchase',
  old.quantity_delta, NULL, NULL,
  old.reference_id, 'purchase', old.user_id,
  old.operation_group_id, old.branch_id, old.unit_cost_snapshot,
  'backfill_edicion_reapunte_bug_mayo',
  jsonb_build_object('backfilled', true, 'change', 'stock-movements-edicion', 'supersedes_movement_id', old.id)
FROM public.stock_movements old
JOIN public.purchases p ON p.id = old.reference_id
WHERE old.reference_type = 'purchase_update' AND old.type = 'purchase' AND p.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm2 WHERE sm2.reference_id = old.reference_id AND sm2.reference_type = 'purchase');

COMMIT;

-- ── Conteos DESPUÉS (esperado: 0 en ventas/compras delete-inseguras) ────────
SELECT
  (SELECT count(*) FROM public.sales s
     WHERE s.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = s.id AND sm.reference_type = 'sale'))
    AS ventas_delete_inseguras_total,
  (SELECT count(*) FROM public.purchases p
     WHERE p.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.reference_id = p.id AND sm.reference_type = 'purchase'))
    AS compras_delete_inseguras_total;
