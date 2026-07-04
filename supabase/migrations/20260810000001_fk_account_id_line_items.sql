-- =============================================================================
-- MIGRATION: 20260810000001_fk_account_id_line_items.sql
-- FIX: FKs faltantes en sale_items.account_id / purchase_items.account_id
--
-- GAP: 20260616000001_v20_sale_items_schema.sql (líneas 30 y 66) agregó
-- account_id uuid en sale_items/purchase_items SOLO con índice de soporte
-- (idx_sale_items_account_id / idx_purchase_items_account_id) — nunca se le
-- agregó REFERENCES. Confirmado en catálogo de prod (pg_constraint):
-- sale_items tiene sale_id_fkey/product_id_fkey/unit_id_fkey/variant_id_fkey
-- pero NO account_id_fkey (ídem purchase_items). Gap de integridad en un
-- SaaS multi-tenant con RLS org-based: nada impide un account_id que no
-- exista en accounts.
--
-- VERIFICACIÓN DE DATOS EN PROD (read-only, 2026-07-04, antes de escribir
-- esta migración):
--   sale_items:     287 filas totales, 23 con account_id IS NULL, 0 huérfanas
--   purchase_items: 244 filas totales, 18 con account_id IS NULL, 0 huérfanas
-- Las filas NULL son 100% legacy: todas datadas (via JOIN a sales/purchases
-- .created_at) entre 2026-03-07 y 2026-04-25 — ANTES de que esta misma
-- columna existiera (creada recién en 20260616000001) y antes de que
-- sale_items_rpc_v2 (C-29, 20260721000001) empezara a poblarla de forma
-- confiable. 0 filas huérfanas → VALIDATE es instantáneo, sin riesgo.
--
-- DECISIÓN — NOT NULL: NO se agrega. Hay 23+18 filas legacy reales con
-- account_id NULL (ver arriba); forzar NOT NULL exigiría backfill o borrado
-- de datos de usuarios reales, decisión que le corresponde al PO y está
-- fuera de alcance de este fix (que es puro gap de integridad referencial,
-- no un saneamiento de datos). Todos los write-paths vigentes
-- (rpc_create_sale_operation[_v2], rpc_create_purchase_operation,
-- confirm_sales_order, etc. — ver 20260806000001_v3_snapshot_pattern.sql y
-- 20260807000001_v3_document_status_history.sql) ya setean account_id
-- siempre en el INSERT; el NULL solo puede volver a aparecer si algún path
-- legacy no listado lo permite, cosa que esta migración no cambia.
--
-- DECISIÓN — ON DELETE: NO ACTION (default, sin cláusula explícita), igual
-- que sus tablas padre directas sales.account_id / purchases.account_id
-- (agregadas en 20260606000003_account_id_columns.sql SIN ON DELETE — NO
-- ACTION implícito). account_id en las líneas es una copia denormalizada
-- del mismo account_id de la fila padre (sales/purchases), misma
-- generación del retrofit — no un dato "nuevo" que deba seguir la
-- convención CASCADE de las tablas post-C-26 (bank_reconciliation,
-- cost_center, document_status_history, etc., que sí son diseño nuevo).
-- En la práctica esta FK NUNCA es la que bloquea un DELETE FROM accounts:
-- sales.account_id / purchases.account_id (NO ACTION) ya lo bloquean
-- primero, porque toda fila de sale_items/purchase_items con account_id
-- poblado tiene necesariamente una fila padre en sales/purchases con el
-- mismo account_id. sale_items/purchase_items SÍ cascadean, pero de forma
-- transitiva vía sale_id/purchase_id → sales/purchases (ON DELETE CASCADE
-- ahí) — no vía esta nueva FK a accounts. NO ACTION es la opción coherente
-- con ese linaje y no cambia ningún comportamiento observable hoy.
--
-- PATRÓN NOT VALID + VALIDATE: con 0 filas huérfanas confirmadas y volumen
-- bajo (287 y 244 filas), el VALIDATE es instantáneo — el split NOT VALID/
-- VALIDATE no aporta beneficio real acá (la migración corre en una sola
-- tx de todos modos), pero se mantiene como patrón correcto para tablas
-- calientes (evita un ACCESS EXCLUSIVE lock largo si el volumen creciera
-- antes de que esta migración corra).
--
-- Rollback (si fuera necesario):
--   ALTER TABLE public.sale_items     DROP CONSTRAINT IF EXISTS sale_items_account_id_fkey;
--   ALTER TABLE public.purchase_items DROP CONSTRAINT IF EXISTS purchase_items_account_id_fkey;
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. sale_items.account_id → accounts(id)
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sale_items_account_id_fkey'
      AND conrelid = 'public.sale_items'::regclass
  ) THEN
    ALTER TABLE public.sale_items
      ADD CONSTRAINT sale_items_account_id_fkey
      FOREIGN KEY (account_id) REFERENCES public.accounts(id) NOT VALID;
  END IF;
END $$;

ALTER TABLE public.sale_items
  VALIDATE CONSTRAINT sale_items_account_id_fkey;

COMMENT ON CONSTRAINT sale_items_account_id_fkey ON public.sale_items IS
  'ON DELETE NO ACTION (default), igual que sales.account_id (su fila padre) — '
  'copia denormalizada del mismo account_id, misma generación del retrofit '
  '20260606000003. sales.account_id ya bloquea el DELETE FROM accounts antes '
  'que esta FK entre en juego.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. purchase_items.account_id → accounts(id)
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchase_items_account_id_fkey'
      AND conrelid = 'public.purchase_items'::regclass
  ) THEN
    ALTER TABLE public.purchase_items
      ADD CONSTRAINT purchase_items_account_id_fkey
      FOREIGN KEY (account_id) REFERENCES public.accounts(id) NOT VALID;
  END IF;
END $$;

ALTER TABLE public.purchase_items
  VALIDATE CONSTRAINT purchase_items_account_id_fkey;

COMMENT ON CONSTRAINT purchase_items_account_id_fkey ON public.purchase_items IS
  'ON DELETE NO ACTION (default), igual que purchases.account_id (su fila padre) — '
  'copia denormalizada del mismo account_id, misma generación del retrofit '
  '20260606000003. purchases.account_id ya bloquea el DELETE FROM accounts antes '
  'que esta FK entre en juego.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. sales_orders.branch_id — NO se toca (documentado, no es un gap)
-- ─────────────────────────────────────────────────────────────────────────────
-- sales_orders.branch_id es NOT NULL REFERENCES branches(id) SIN ON DELETE
-- (NO ACTION/RESTRICT implícito) — a diferencia de sales/purchases/quotes/
-- stock_movements.branch_id que sí permiten SET NULL. Esto NO es un gap a
-- "unificar": branch_id es NOT NULL por diseño (DEC-19, C-29 — Branch como
-- Aggregate Root de primer nivel; ver knowledge-base/09_decisiones_y_supuestos.md
-- DEC-19), así que SET NULL violaría esa invariante directamente. Además las
-- branches se cierran (lifecycle C-26), no se borran — el RESTRICT nunca
-- bloqueó nada en operación real; su única consecuencia práctica fue en los
-- cleanups de gates de CI (PR #269, 20260806000002_fix_v3_snapshot_gate_cleanup.sql),
-- ya resuelto ahí. Se documenta acá para que quede explícito en el catálogo
-- y no se reabra como "inconsistencia" en una futura auditoría de FKs.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sales_orders_branch_id_fkey'
      AND conrelid = 'public.sales_orders'::regclass
  ) THEN
    COMMENT ON CONSTRAINT sales_orders_branch_id_fkey ON public.sales_orders IS
      'ON DELETE NO ACTION (default) intencional — branch_id es NOT NULL por '
      'diseño (DEC-19: Branch como Aggregate Root). NO unificar a SET NULL '
      'como sales/purchases/quotes/stock_movements.branch_id: violaría la '
      'invariante NOT NULL. Las branches se cierran, no se borran (C-26 '
      'lifecycle) — el RESTRICT no tiene consecuencia práctica en operación '
      'real. Ver knowledge-base/09_decisiones_y_supuestos.md DEC-19 y '
      '20260806000002_fix_v3_snapshot_gate_cleanup.sql (única fricción '
      'observada, ya resuelta en el cleanup de gates de CI).';
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. GATE — ambas FKs existen y están VALIDATED
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_gate_a boolean := false; -- sale_items_account_id_fkey existe y validated
  v_gate_b boolean := false; -- purchase_items_account_id_fkey existe y validated
BEGIN
  -- ── (a) sale_items_account_id_fkey ────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sale_items_account_id_fkey'
      AND conrelid = 'public.sale_items'::regclass
      AND confrelid = 'public.accounts'::regclass
      AND contype = 'f'
      AND convalidated = true
  ) THEN
    v_gate_a := true;
  ELSE
    RAISE EXCEPTION 'GATE (a) FAILED: sale_items_account_id_fkey ausente o no validated';
  END IF;

  -- ── (b) purchase_items_account_id_fkey ────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchase_items_account_id_fkey'
      AND conrelid = 'public.purchase_items'::regclass
      AND confrelid = 'public.accounts'::regclass
      AND contype = 'f'
      AND convalidated = true
  ) THEN
    v_gate_b := true;
  ELSE
    RAISE EXCEPTION 'GATE (b) FAILED: purchase_items_account_id_fkey ausente o no validated';
  END IF;

  RAISE NOTICE 'fk-account-id-line-items: GATES OK (a=%, b=%)', v_gate_a, v_gate_b;
END $$;
