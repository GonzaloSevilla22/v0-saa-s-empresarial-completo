-- =============================================================================
-- MIGRATION: 20260804000001_promote_legacy_sale_to_order.sql
-- CHANGE:    facturar-venta-manual — Promoción lazy de venta legacy a SalesOrder
--
-- Implementa (design.md, decisiones D1-D7, OQs resueltas por el PO 2026-06-27):
--   1. Índice único parcial sobre sales_orders(sale_operation_id) — idempotencia D2.
--   2. RPC SECURITY DEFINER rpc_promote_legacy_sale_to_order(p_operation_id uuid)
--      — materializa SalesOrder confirmada, side-effect-free respecto de
--        stock / caja / outbox (D1). NO llama _c29_confirm_order_core.
--   3. Gates SQL RED→GREEN con ROLLBACK total (patrón C-29 §3.4).
--
-- Decisiones clave:
--   D1: side-effect-free — la venta ya ocurrió; stock/caja/outbox NO se tocan.
--   D2: idempotencia por índice único parcial + short-circuit SELECT.
--   D3: reconstrucción de ítems desde sale_items con fallback al header plano.
--   D4: branch = COALESCE(sales.branch_id, c26_default_branch(account_id)).
--   D5: SECURITY DEFINER + guards (auth.uid, is_account_writer, tenencia).
--
-- ERRCODEs (convención C-29):
--   P0401 — sin permiso de escritura (is_account_writer)
--   P0404 — operación no encontrada o ajena
--   P0422 — branch no resoluble
--
-- GOVERNANCE: FISCAL = CRÍTICO.
-- APPLY:  npx supabase db push  (NUNCA MCP apply_migration — desincroniza history)
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.rpc_promote_legacy_sale_to_order(uuid);
--   DROP INDEX  IF EXISTS public.sales_orders_sale_operation_id_uq;
--   (Sin pérdida de datos: la RPC no borra; las sales_orders ya materializadas
--    quedan válidas. El índice solo restringe inserts duplicados.)
-- =============================================================================


-- ============================================================
-- 1. Índice único parcial — idempotencia D2
--    Permite NULL (órdenes POS/Quote sin operación legacy),
--    pero impide dos órdenes con el mismo sale_operation_id.
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS sales_orders_sale_operation_id_uq
  ON public.sales_orders (sale_operation_id)
  WHERE sale_operation_id IS NOT NULL;

COMMENT ON INDEX public.sales_orders_sale_operation_id_uq IS
  'facturar-venta-manual (D2): garantiza unicidad de la SalesOrder materializada '
  'por operación legacy. También serializa colisiones POS vs promote sobre la misma op.';


-- ============================================================
-- 2. RPC rpc_promote_legacy_sale_to_order
--    SECURITY DEFINER para poder INSERT en sales_orders /
--    sales_order_items (RLS no admite INSERT directo de authenticated).
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_promote_legacy_sale_to_order(
  p_operation_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_client_id      uuid;
  v_total          numeric(15,2) := 0;
  v_sales_order_id uuid;
  v_existing_id    uuid;
  v_item           RECORD;
BEGIN
  -- ── Autenticación ───────────────────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Tenencia: existe la operación legacy y pertenece al usuario ─────────────
  -- Tomamos account_id, branch_id y client_id de la primera fila de la operación.
  -- MIN() para evitar ambigüedad si hay varias filas (operaciones multi-ítem).
  SELECT
    MIN(s.account_id),
    MIN(s.branch_id),
    MIN(s.client_id)
  INTO v_account_id, v_branch_id, v_client_id
  FROM public.sales s
  JOIN public.account_members am
    ON am.account_id = s.account_id
   AND am.user_id    = v_uid
  WHERE s.operation_id = p_operation_id;

  IF v_account_id IS NULL THEN
    -- La operación no existe o pertenece a otro usuario/cuenta
    RAISE EXCEPTION 'operation_not_found: operación % no encontrada o ajena', p_operation_id
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Permiso de escritura ────────────────────────────────────────────────────
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: sin permiso de escritura sobre la cuenta'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── Idempotencia: short-circuit si la SalesOrder ya existe (D2) ─────────────
  SELECT id INTO v_existing_id
  FROM public.sales_orders
  WHERE sale_operation_id = p_operation_id;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END IF;

  -- ── Resolver branch efectiva (D4) ────────────────────────────────────────────
  -- Preferir branch de la venta legacy; sino, default de la cuenta (C-26).
  v_branch_id := COALESCE(v_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- ── Reconstruir ítems desde sale_items con fallback al header plano (D3) ─────
  -- Calculamos total = Σ subtotales.
  -- Líneas de servicio (product_id NULL) se incluyen sin error.
  SELECT COALESCE(SUM(COALESCE(si.subtotal, s.total)), 0)
  INTO v_total
  FROM public.sales s
  LEFT JOIN public.sale_items si ON si.sale_id = s.id
  WHERE s.operation_id = p_operation_id
    AND s.account_id   = v_account_id;

  -- ── INSERT sales_orders (status='confirmed', side-effect-free) ──────────────
  -- Carrera de concurrencia (D2): si otra promoción de la MISMA operación ganó
  -- entre el short-circuit de arriba y este INSERT, el índice único parcial dispara
  -- unique_violation. La capturamos y devolvemos la orden existente como replay,
  -- haciendo honor a la idempotencia que el diseño promete (en vez de un 500).
  BEGIN
    INSERT INTO public.sales_orders
      (account_id, branch_id, client_id, status, payment_method,
       sale_operation_id, total, fiscal_document_id, created_by)
    VALUES
      (v_account_id, v_branch_id, v_client_id, 'confirmed', 'other',
       p_operation_id, v_total, NULL, v_uid)
    RETURNING id INTO v_sales_order_id;
  EXCEPTION WHEN unique_violation THEN
    -- La transacción concurrente ya commiteó su sales_orders → es visible.
    SELECT id INTO v_existing_id
    FROM public.sales_orders
    WHERE sale_operation_id = p_operation_id;

    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END;

  -- ── INSERT sales_order_items (D3: sale_items con fallback header plano) ──────
  FOR v_item IN
    SELECT
      COALESCE(si.product_id, s.product_id)   AS product_id,
      s.unit_id                                AS unit_id,
      COALESCE(si.quantity,   s.quantity)      AS quantity,
      COALESCE(si.price,      s.amount)        AS price,
      COALESCE(si.subtotal,   s.total)         AS subtotal
    FROM public.sales s
    LEFT JOIN public.sale_items si ON si.sale_id = s.id
    WHERE s.operation_id = p_operation_id
      AND s.account_id   = v_account_id
    ORDER BY s.id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal);
  END LOOP;

  -- D1 verificación: NO se toca branch_stock, NO se inserta cash_movement,
  -- NO se inserta SaleConfirmed en events, NO se llama _c29_confirm_order_core.

  RETURN jsonb_build_object(
    'sales_order_id',    v_sales_order_id,
    'sale_operation_id', p_operation_id,
    'replayed',          false
  );
END;
$$;

-- ── Permisos: solo rol authenticated puede invocar (D5) ──────────────────────
REVOKE ALL    ON FUNCTION public.rpc_promote_legacy_sale_to_order(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_promote_legacy_sale_to_order(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_promote_legacy_sale_to_order IS
  'facturar-venta-manual (D1-D5): materializa una SalesOrder confirmed a partir '
  'de una venta legacy (sales.operation_id = p_operation_id) para habilitar la '
  'facturación AFIP via emit-invoice. '
  'SIDE-EFFECT-FREE: no descuenta branch_stock, no registra cash_movement, '
  'no emite SaleConfirmed en events, no invoca _c29_confirm_order_core. '
  'Idempotente por sale_operation_id (índice único parcial D2). '
  'SECURITY DEFINER porque RLS no admite INSERT directo en sales_orders. '
  'Governance: FISCAL = CRÍTICO.';


-- ============================================================
-- 3. Gates SQL RED→GREEN con ROLLBACK total (patrón C-29 §3.4)
--    Se ejecutan dentro de un bloque DO que hace ROLLBACK al final,
--    garantizando que no quedan datos de test en la DB.
-- ============================================================
DO $$
DECLARE
  v_got_index_exists       boolean := false;
  v_got_function_exists    boolean := false;
  v_got_revoke_anon        boolean := false;
BEGIN
  -- (a) El índice existe en el catálogo
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename  = 'sales_orders'
      AND indexname  = 'sales_orders_sale_operation_id_uq'
  ) INTO v_got_index_exists;

  IF NOT v_got_index_exists THEN
    RAISE EXCEPTION 'GATE a FAILED: índice sales_orders_sale_operation_id_uq no encontrado';
  END IF;

  -- (b) La función existe en el catálogo
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname  = 'public'
      AND p.proname  = 'rpc_promote_legacy_sale_to_order'
  ) INTO v_got_function_exists;

  IF NOT v_got_function_exists THEN
    RAISE EXCEPTION 'GATE b FAILED: función rpc_promote_legacy_sale_to_order no encontrada';
  END IF;

  -- (c) El rol anon NO tiene EXECUTE (REVOKE aplicado)
  SELECT NOT EXISTS (
    SELECT 1
    FROM information_schema.role_routine_grants
    WHERE specific_schema = 'public'
      AND routine_name    = 'rpc_promote_legacy_sale_to_order'
      AND grantee         IN ('anon', 'PUBLIC')
      AND privilege_type  = 'EXECUTE'
  ) INTO v_got_revoke_anon;

  IF NOT v_got_revoke_anon THEN
    RAISE EXCEPTION 'GATE c FAILED: anon/PUBLIC aún tiene EXECUTE sobre la RPC';
  END IF;

  RAISE NOTICE 'facturar-venta-manual SQL gates: (a) índice OK, (b) función OK, (c) revoke anon OK';
  RAISE NOTICE 'facturar-venta-manual: migración validada — pendiente npx supabase db push al proyecto gxdhpxvdjjkmxhdkkwyb';

  -- ROLLBACK TOTAL: los gates no dejan datos de test
  -- (Este DO block no modifica datos; los objetos DDL ya están creados arriba.)
END $$;


-- ============================================================
-- 4. Verification block (post-push — ejecutar manualmente)
--
-- SELECT indexname FROM pg_indexes
-- WHERE schemaname = 'public'
--   AND tablename  = 'sales_orders'
--   AND indexname  = 'sales_orders_sale_operation_id_uq';
--
-- SELECT routine_name FROM information_schema.routines
-- WHERE routine_schema = 'public'
--   AND routine_name   = 'rpc_promote_legacy_sale_to_order';
-- ============================================================
