-- =============================================================================
-- backfill_operation_lines.sql
--
-- edicion-operaciones-lineas (Grupo 6) — sign-off PO 2026-08-19, política
-- recomendada en design.md §D6: compras copian el unit_cost_snapshot GENUINO
-- del header (snapshot_backfilled=false); ventas quedan con unit_cost_snapshot
-- NULL (snapshot_backfilled=true) — NUNCA se congela el costo actual como si
-- fuera el histórico.
--
-- NO ES UNA MIGRACIÓN. NO debe copiarse a supabase/migrations/ — el merge a
-- main aplica migraciones automáticamente y un backfill de datos gateado a
-- sign-off no puede viajar en ese tren (Impacto de proposal.md). Se ejecuta a
-- mano UNA sola vez, con los conteos dry-run a la vista, contra el proyecto
-- prod real (gxdhpxvdjjkmxhdkkwyb) vía MCP execute_sql, o localmente con:
--   psql "$DATABASE_URL" -f scripts/sql/backfill_operation_lines.sql
--
-- Alcance (medido en prod 2026-08-18, design.md): 119 ventas y 186 compras
-- con producto sin línea; 179/186 de esas compras tienen unit_cost_snapshot
-- ya congelado en el header purchases (las 7 restantes, no). Las líneas de
-- servicio (product_id IS NULL) nunca llevan línea, por diseño — no se tocan.
--
-- Reglas de reconstrucción (document-snapshots, requirement "Backfill
-- best-effort de líneas históricas"):
--   · Compras CON snapshot ya congelado en el header → se copia ese snapshot
--     genuino (name/sku/unit_cost/iva) a la línea nueva, snapshot_backfilled
--     = false (el valor NO es una aproximación: ya estaba congelado, solo
--     vivía en el lugar equivocado).
--   · Compras SIN snapshot en el header → name/sku desde products (maestro
--     actual, son etiquetas, no magnitudes monetarias), unit_cost_snapshot
--     NULL, snapshot_backfilled = true.
--   · Ventas (siempre incognoscible el costo histórico real) → name/sku desde
--     products actual, unit_cost_snapshot NULL, snapshot_backfilled = true.
--     El consumidor canónico ya resuelve COALESCE(unit_cost_snapshot,
--     products.cost): con NULL el margen de estas ventas se calcula EXACTO
--     igual que hoy — el backfill agrega la línea sin mover un solo número.
--
-- Idempotente: cada INSERT filtra WHERE NOT EXISTS (línea ya presente) —
-- reejecutar el script completo no duplica ni sobrescribe nada (task 6.5:
-- verificado localmente, segunda corrida afecta 0 filas).
--
-- Transacción única: BEGIN/COMMIT envuelve los 3 INSERT. Si se pega el
-- bloque BEGIN..COMMIT en el MCP execute_sql (que ya envuelve su propia
-- transacción), el BEGIN interno emite un WARNING inocuo ("ya hay una
-- transacción en curso") y sigue en la misma transacción — el COMMIT cierra
-- esa transacción ahí; el efecto de los 3 INSERT sigue siendo atómico.
-- =============================================================================

-- ── Conteos ANTES (dry-run) ──────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM public.sales s
     WHERE s.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.sale_items si WHERE si.sale_id = s.id))
    AS ventas_sin_linea,
  (SELECT count(*) FROM public.purchases p
     WHERE p.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id = p.id))
    AS compras_sin_linea,
  (SELECT count(*) FROM public.purchases p
     WHERE p.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id = p.id)
       AND p.unit_cost_snapshot IS NOT NULL)
    AS compras_sin_linea_con_snapshot_header;

BEGIN;

-- ── 1) Compras CON snapshot ya congelado en el header ────────────────────────
INSERT INTO public.purchase_items (
  purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
  name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
)
SELECT
  p.id, p.product_id, p.account_id, NULL, p.quantity, p.unit_id, p.amount,
  COALESCE(p.total, p.amount * p.quantity),
  p.name_snapshot, p.sku_snapshot, p.unit_cost_snapshot, p.iva_rate_snapshot, false
FROM public.purchases p
WHERE p.product_id IS NOT NULL
  AND p.unit_cost_snapshot IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id = p.id);

-- ── 2) Compras SIN snapshot en el header — costo incognoscible, NUNCA el actual ──
INSERT INTO public.purchase_items (
  purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
  name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
)
SELECT
  p.id, p.product_id, p.account_id, NULL, p.quantity, p.unit_id, p.amount,
  COALESCE(p.total, p.amount * p.quantity),
  pr.name, pr.sku, NULL, NULL, true
FROM public.purchases p
JOIN public.products pr ON pr.id = p.product_id
WHERE p.product_id IS NOT NULL
  AND p.unit_cost_snapshot IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id = p.id);

-- ── 3) Ventas — costo histórico incognoscible, NUNCA el actual ───────────────
INSERT INTO public.sale_items (
  sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
  name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
)
SELECT
  s.id, s.product_id, s.account_id, NULL, s.quantity, s.unit_id, s.amount,
  COALESCE(s.total, s.amount * s.quantity),
  pr.name, pr.sku, NULL, NULL, true
FROM public.sales s
JOIN public.products pr ON pr.id = s.product_id
WHERE s.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.sale_items si WHERE si.sale_id = s.id);

COMMIT;

-- ── Conteos DESPUÉS (esperado: 0 en las tres columnas) ───────────────────────
SELECT
  (SELECT count(*) FROM public.sales s
     WHERE s.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.sale_items si WHERE si.sale_id = s.id))
    AS ventas_sin_linea,
  (SELECT count(*) FROM public.purchases p
     WHERE p.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id = p.id))
    AS compras_sin_linea,
  (SELECT count(*) FROM public.purchases p
     WHERE p.product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id = p.id)
       AND p.unit_cost_snapshot IS NOT NULL)
    AS compras_sin_linea_con_snapshot_header;
