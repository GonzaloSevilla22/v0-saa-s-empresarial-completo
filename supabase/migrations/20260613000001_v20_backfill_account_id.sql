-- ============================================================
-- v20-tenancy-cleanup — Task 2.1 + 2.2
-- Backfill account_id NULLs en tablas ERP
--
-- Estado antes de esta migration (relevado 2026-06-09):
--   products:               4 NULLs / 2253 total
--   clients:                1 NULL  / 1102 total
--   stock_movements:        1 NULL  / 494  total
--   operation_idempotency:  5 NULLs / 24   total
--   sales, purchases, expenses: 0 NULLs (ya limpias)
--
-- Estrategia: account_id = (SELECT account_id FROM account_members
--             WHERE user_id = <tabla>.user_id LIMIT 1)
--
-- La función current_account_ids() y la tabla account_members
-- ya existen (C-05, migration 20260606000001).
-- ============================================================

-- 2.1a Backfill products
UPDATE public.products p
SET account_id = (
    SELECT am.account_id
    FROM public.account_members am
    WHERE am.user_id = p.user_id
    LIMIT 1
)
WHERE p.account_id IS NULL
  AND p.user_id IS NOT NULL;

-- 2.1b Backfill clients
UPDATE public.clients c
SET account_id = (
    SELECT am.account_id
    FROM public.account_members am
    WHERE am.user_id = c.user_id
    LIMIT 1
)
WHERE c.account_id IS NULL
  AND c.user_id IS NOT NULL;

-- 2.2 Backfill stock_movements
UPDATE public.stock_movements sm
SET account_id = (
    SELECT am.account_id
    FROM public.account_members am
    WHERE am.user_id = sm.user_id
    LIMIT 1
)
WHERE sm.account_id IS NULL
  AND sm.user_id IS NOT NULL;

-- 2.2b Backfill operation_idempotency
UPDATE public.operation_idempotency oi
SET account_id = (
    SELECT am.account_id
    FROM public.account_members am
    WHERE am.user_id = oi.user_id
    LIMIT 1
)
WHERE oi.account_id IS NULL
  AND oi.user_id IS NOT NULL;

-- Verificación post-backfill: no debe haber NULLs residuales resolvibles
DO $$
DECLARE
  v_products_nulls      INT;
  v_clients_nulls       INT;
  v_movements_nulls     INT;
  v_idempotency_nulls   INT;
BEGIN
  SELECT COUNT(*) INTO v_products_nulls    FROM public.products              WHERE account_id IS NULL;
  SELECT COUNT(*) INTO v_clients_nulls     FROM public.clients               WHERE account_id IS NULL;
  SELECT COUNT(*) INTO v_movements_nulls   FROM public.stock_movements       WHERE account_id IS NULL;
  SELECT COUNT(*) INTO v_idempotency_nulls FROM public.operation_idempotency WHERE account_id IS NULL;

  IF v_products_nulls > 0 THEN
    RAISE EXCEPTION 'products todavía tiene % filas con account_id NULL', v_products_nulls;
  END IF;
  IF v_clients_nulls > 0 THEN
    RAISE EXCEPTION 'clients todavía tiene % filas con account_id NULL', v_clients_nulls;
  END IF;
  IF v_movements_nulls > 0 THEN
    RAISE EXCEPTION 'stock_movements todavía tiene % filas con account_id NULL', v_movements_nulls;
  END IF;
  IF v_idempotency_nulls > 0 THEN
    RAISE EXCEPTION 'operation_idempotency todavía tiene % filas con account_id NULL', v_idempotency_nulls;
  END IF;

  RAISE NOTICE 'Backfill completado: 0 NULLs en products, clients, stock_movements, operation_idempotency';
END $$;
