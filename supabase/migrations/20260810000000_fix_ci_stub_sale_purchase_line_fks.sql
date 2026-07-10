-- =============================================================================
-- MIGRATION: 20260810000000_fix_ci_stub_sale_purchase_line_fks.sql
-- FIX FOR:   20260517000000_ci_compat_stubs.sql (CI-only stub drift)
--
-- BUG (found 2026-07-04, mientras se armaba 20260810000001_fk_account_id_line_items.sql):
-- el stub 20260517000000_ci_compat_stubs.sql define sale_items/purchase_items
-- con CREATE TABLE IF NOT EXISTS — no-op en prod (la tabla real ya existe ahí,
-- creada por fuera de la cadena de migraciones versionada, con MÁS FKs de las
-- que el stub declara). En un reset limpio de CI (DB vacía, exactamente lo que
-- hace validate-kpis), el stub SÍ crea la tabla desde cero — y su definición
-- NUNCA incluyó sale_id_fkey / purchase_id_fkey / variant_id_fkey. Prod tiene
-- las 4 FKs (product_id, unit_id, sale_id/purchase_id, variant_id); CI/local
-- reset solo tenía 2 (product_id, unit_id — agregadas recién en
-- 20260616000001_v20_sale_items_schema.sql).
--
-- IMPACTO: sin sale_id_fkey/purchase_id_fkey (ON DELETE CASCADE en prod), las
-- funciones rpc_atomic_update_sale_operation / wire_movements_to_rpcs /
-- rpc_account_scoping / c21_hotfix / c21_checkpoint2 (todas con
-- `DELETE FROM public.sales WHERE id = ANY(p_sale_ids)` sin borrar sale_items
-- antes — confían en el CASCADE real de prod) dejan sale_items huérfanos
-- SOLO en CI/local cuando algún gate ejercita esas funciones. Confirmado con
-- `npx supabase db reset` local: 2 filas huérfanas en sale_items
-- (account_id apuntando a una cuenta ya borrada por el cleanup de un gate
-- posterior) — nunca detectado hasta ahora porque nada validaba esa relación.
--
-- Este fix agrega las 3 FKs faltantes para que el schema de CI/local
-- coincida con el de prod. No-op en prod (las FKs ya existen ahí con estos
-- mismos nombres — confirmado vía pg_constraint en gxdhpxvdjjkmxhdkkwyb).
--
-- Va ANTES (timestamp *000000, un segundo antes) de
-- 20260810000001_fk_account_id_line_items.sql para que su VALIDATE
-- CONSTRAINT sale_items_account_id_fkey no se tope con huérfanos que en
-- prod nunca existieron (ahí el CASCADE real ya los previno desde siempre).
--
-- Orden: limpieza de huérfanos preexistentes PRIMERO (best-effort, no afecta
-- prod donde nunca pudieron existir), después ADD CONSTRAINT ... NOT VALID +
-- VALIDATE (mismo patrón que 20260810000001) — así el ADD nunca falla por
-- datos huérfanos que la propia limpieza ya resolvió.
--
-- Rollback (si fuera necesario):
--   ALTER TABLE public.sale_items     DROP CONSTRAINT IF EXISTS sale_items_sale_id_fkey;
--   ALTER TABLE public.sale_items     DROP CONSTRAINT IF EXISTS sale_items_variant_id_fkey;
--   ALTER TABLE public.purchase_items DROP CONSTRAINT IF EXISTS purchase_items_purchase_id_fkey;
--   ALTER TABLE public.purchase_items DROP CONSTRAINT IF EXISTS purchase_items_variant_id_fkey;
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Limpieza de huérfanos preexistentes en CI/local (best-effort).
-- ─────────────────────────────────────────────────────────────────────────────

DELETE FROM public.sale_items
WHERE sale_id IS NOT NULL
  AND sale_id NOT IN (SELECT id FROM public.sales);

DELETE FROM public.purchase_items
WHERE purchase_id IS NOT NULL
  AND purchase_id NOT IN (SELECT id FROM public.purchases);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. sale_items.sale_id / variant_id
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sale_items_sale_id_fkey'
      AND conrelid = 'public.sale_items'::regclass
  ) THEN
    ALTER TABLE public.sale_items
      ADD CONSTRAINT sale_items_sale_id_fkey
      FOREIGN KEY (sale_id) REFERENCES public.sales(id) ON DELETE CASCADE NOT VALID;
  END IF;
END $$;

ALTER TABLE public.sale_items VALIDATE CONSTRAINT sale_items_sale_id_fkey;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sale_items_variant_id_fkey'
      AND conrelid = 'public.sale_items'::regclass
  ) THEN
    ALTER TABLE public.sale_items
      ADD CONSTRAINT sale_items_variant_id_fkey
      FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;

ALTER TABLE public.sale_items VALIDATE CONSTRAINT sale_items_variant_id_fkey;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. purchase_items.purchase_id / variant_id
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchase_items_purchase_id_fkey'
      AND conrelid = 'public.purchase_items'::regclass
  ) THEN
    ALTER TABLE public.purchase_items
      ADD CONSTRAINT purchase_items_purchase_id_fkey
      FOREIGN KEY (purchase_id) REFERENCES public.purchases(id) ON DELETE CASCADE NOT VALID;
  END IF;
END $$;

ALTER TABLE public.purchase_items VALIDATE CONSTRAINT purchase_items_purchase_id_fkey;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchase_items_variant_id_fkey'
      AND conrelid = 'public.purchase_items'::regclass
  ) THEN
    ALTER TABLE public.purchase_items
      ADD CONSTRAINT purchase_items_variant_id_fkey
      FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;

ALTER TABLE public.purchase_items VALIDATE CONSTRAINT purchase_items_variant_id_fkey;

-- ─────────────────────────────────────────────────────────────────────────────
-- GATE — las 4 FKs (incluidas las 2 preexistentes de 20260616000001) están
-- presentes y validated en ambas tablas.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM pg_constraint
  WHERE conrelid = 'public.sale_items'::regclass
    AND contype = 'f'
    AND convalidated = true;
  IF v_count < 4 THEN
    RAISE EXCEPTION 'GATE FAILED: sale_items tiene % FKs validated, se esperaban >= 4', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_constraint
  WHERE conrelid = 'public.purchase_items'::regclass
    AND contype = 'f'
    AND convalidated = true;
  IF v_count < 4 THEN
    RAISE EXCEPTION 'GATE FAILED: purchase_items tiene % FKs validated, se esperaban >= 4', v_count;
  END IF;

  RAISE NOTICE 'fix-ci-stub-sale-purchase-line-fks: GATE OK — sale_items y purchase_items con 4 FKs validated';
END $$;
