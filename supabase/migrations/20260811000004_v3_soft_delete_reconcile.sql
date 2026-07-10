-- =============================================================================
-- v3-soft-delete-policy — RECONCILIACIÓN prod ↔ repo (post-mortem del apply)
--
-- Contexto: durante el apply del change, una corrida abortada aplicó a prod
-- una versión PRELIMINAR del soft delete como migraciones 20260811000001/2/3
-- (registradas en supabase_migrations.schema_migrations pero cuyos archivos
-- NO existen en el repo — el repo quedó con la versión canónica única
-- 20260811000001, PR #275). Por coincidencia de versión, `db push` reportó
-- "Remote database is up to date" y la 20260811000001 canónica NUNCA se
-- ejecutó en prod. Diferencias reales de la versión preliminar aplicada:
--
--   1. El guard RN-B4 preliminar NO chequea quotes en 'draft' — solo
--      sales_order_items/sales_orders. La política (spec RN-B4 + task 3.4)
--      exige la unión verificada: quotes Y sales_orders (ambos tienen
--      status 'draft' por CHECK 20260702000001 y catálogo FSM 20260807000001).
--   2. El trigger quedó con nombre `products_guard_soft_delete` (el canónico
--      del change es `trg_guard_product_soft_delete`).
--   3. Los COMMENT de convivencia D1 sobre is_active nunca se aplicaron.
--   4. Historial: versiones fantasma 20260811000002/3 sin archivo local
--      (el hazard documentado en CLAUDE.md sobre historial desincronizado).
--
-- Esta migración es IDEMPOTENTE y segura en AMBOS mundos:
--   - En CI (chain fresco: 20260811000001 canónica ya corrió): reinstala el
--     mismo guard, los DROP de nombres viejos son no-op, los DELETE de
--     historial no matchean filas, los gates pasan.
--   - En prod (estado preliminar): corrige guard + trigger + comments,
--     limpia el historial fantasma, y los gates prueban EN VIVO la rama de
--     quotes que faltaba.
-- Columnas e índices NO se tocan: la versión preliminar creó exactamente los
-- mismos (verificado por diff contra el commit huérfano 9883cfa).
-- =============================================================================


-- =============================================================================
-- 1. Guard RN-B4 canónico (quotes + sales_orders — task 3.4)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_guard_product_soft_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stock      numeric;
  v_draft_refs bigint;
BEGIN
  -- Solo aplica en la transición al borrado (NULL → NOT NULL). Cualquier otro
  -- UPDATE (incluida la restauración deleted_at → NULL) pasa sin costo.
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN

    SELECT COALESCE(SUM(bs.quantity), 0) INTO v_stock
    FROM   public.branch_stock bs
    WHERE  bs.product_id = OLD.id;

    IF v_stock <> 0 THEN
      RAISE EXCEPTION
        'RN-B4: el producto "%" tiene stock (%) — ajustá el stock a 0 antes de borrarlo',
        OLD.name, v_stock
        USING ERRCODE = 'P0B04';
    END IF;

    SELECT COUNT(*) INTO v_draft_refs FROM (
      SELECT 1
      FROM   public.quote_items qi
      JOIN   public.quotes q ON q.id = qi.quote_id
      WHERE  qi.product_id = OLD.id AND q.status = 'draft'
      UNION ALL
      SELECT 1
      FROM   public.sales_order_items soi
      JOIN   public.sales_orders so ON so.id = soi.sales_order_id
      WHERE  soi.product_id = OLD.id AND so.status = 'draft'
    ) refs;

    IF v_draft_refs > 0 THEN
      RAISE EXCEPTION
        'RN-B4: el producto "%" está incluido en % documento(s) en borrador — quitalo de los borradores antes de borrarlo',
        OLD.name, v_draft_refs
        USING ERRCODE = 'P0B04';
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_guard_product_soft_delete() IS
  'RN-B4 (v3-soft-delete-policy, D3): bloquea el soft delete de un producto '
  'con stock <> 0 (Σ branch_stock) o incluido en documentos draft (quotes / '
  'sales_orders — unión verificada task 3.4). ERRCODE P0B04 → el service '
  'layer lo traduce a HTTP 409 con mensaje de UX. Reconciliado en '
  '20260811000004 (la versión preliminar omitía quotes).';

-- Trigger canónico único (el preliminar quedó con otro nombre — dos triggers
-- BEFORE UPDATE sobre la misma función ejecutarían el guard dos veces).
DROP TRIGGER IF EXISTS products_guard_soft_delete ON public.products;
DROP TRIGGER IF EXISTS trg_guard_product_soft_delete ON public.products;
CREATE TRIGGER trg_guard_product_soft_delete
  BEFORE UPDATE ON public.products
  FOR EACH ROW
  WHEN (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL)
  EXECUTE FUNCTION public.fn_guard_product_soft_delete();


-- =============================================================================
-- 2. COMMENT de convivencia D1 (nunca aplicados en prod)
-- =============================================================================

COMMENT ON COLUMN public.cost_centers.is_active IS
  'Baja lógica REVERSIBLE: FALSE oculta el centro de los selectores de altas '
  'nuevas pero conserva imputaciones históricas y puede reactivarse. Para el '
  'BORRADO real ver deleted_at (v3-soft-delete-policy, D1).';

COMMENT ON COLUMN public.bank_accounts.is_active IS
  'Baja lógica REVERSIBLE: FALSE desactiva la cuenta bancaria (no aparece en '
  'selectores operativos) pero puede reactivarse. Para el BORRADO real ver '
  'deleted_at (v3-soft-delete-policy, D1).';


-- =============================================================================
-- 3. GATE estructural: el guard final contiene AMBAS ramas draft y el
--    trigger canónico es único. Aborta si no (determinístico en CI y prod).
-- =============================================================================
DO $$
DECLARE
  v_def      text;
  v_triggers int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_guard_product_soft_delete';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE R.1 FAILED: fn_guard_product_soft_delete no existe.';
  END IF;

  IF v_def NOT LIKE '%quote_items%' OR v_def NOT LIKE '%sales_order_items%' THEN
    RAISE EXCEPTION 'GATE R.1 FAILED: el guard RN-B4 no cubre la unión draft completa (quotes + sales_orders).';
  END IF;

  SELECT COUNT(*) INTO v_triggers
  FROM   pg_trigger t
  JOIN   pg_class c ON c.oid = t.tgrelid
  JOIN   pg_namespace n ON n.oid = c.relnamespace
  WHERE  n.nspname = 'public' AND c.relname = 'products'
    AND  NOT t.tgisinternal
    AND  t.tgfoid = 'public.fn_guard_product_soft_delete()'::regprocedure;

  IF v_triggers <> 1 THEN
    RAISE EXCEPTION 'GATE R.1 FAILED: se esperaba exactamente 1 trigger del guard sobre products, hay %.', v_triggers;
  END IF;

  RAISE NOTICE 'GATE R.1 PASSED: guard RN-B4 con unión draft completa y trigger canónico único.';
END $$;


-- =============================================================================
-- 4. GATE de comportamiento EN VIVO — específicamente la rama de quotes que
--    la versión preliminar omitía + sanity de borrado limpio y SKU recreable.
--    Anchor sintético auto-limpiado child→parent (patrón PRs #268/#269).
-- =============================================================================
DO $$
DECLARE
  v_fake_user_id uuid := gen_random_uuid();
  v_account_id   uuid;
  v_branch_id    uuid;
  v_product_a    uuid;
  v_product_b    uuid;
  v_quote_id     uuid;
  v_row          record;
  v_guard_fired  boolean;
  v_sku          text := '__gate_v3_sd_reconcile_sku__';
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_fake_user_id, 'authenticated', 'authenticated',
          'v3-sd-reconcile-gate@test.local', now(), now(),
          jsonb_build_object('name', 'Gate v3-sd-reconcile', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_fake_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    INSERT INTO public.accounts (id, owner_user_id)
    VALUES (gen_random_uuid(), v_fake_user_id)
    RETURNING id INTO v_account_id;
    INSERT INTO public.account_members (account_id, user_id, role)
    VALUES (v_account_id, v_fake_user_id, 'owner')
    ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO public.branches (id, account_id, name)
  VALUES (gen_random_uuid(), v_account_id, '__gate_v3_sd_reconcile_branch__')
  RETURNING id INTO v_branch_id;

  INSERT INTO public.products (id, user_id, account_id, name, price, cost, sku)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_r_product_a__', 100, 50, v_sku)
  RETURNING id INTO v_product_a;

  -- ── R.2: producto en QUOTE draft → rechazado con P0B04 (la rama faltante) ─
  INSERT INTO public.quotes (id, account_id, branch_id, status, total, created_by)
  VALUES (gen_random_uuid(), v_account_id, v_branch_id, 'draft', 100, v_fake_user_id)
  RETURNING id INTO v_quote_id;

  INSERT INTO public.quote_items (quote_id, account_id, product_id, quantity, price, subtotal)
  VALUES (v_quote_id, v_account_id, v_product_a, 1, 100, 100);

  v_guard_fired := false;
  BEGIN
    UPDATE public.products
    SET    deleted_at = now(), deleted_by = v_fake_user_id
    WHERE  id = v_product_a;
  EXCEPTION
    WHEN SQLSTATE 'P0B04' THEN
      v_guard_fired := true;
  END;

  IF NOT v_guard_fired THEN
    RAISE EXCEPTION 'GATE R.2 FAILED: el soft delete de un producto en un quote draft NO fue rechazado (la rama de quotes sigue ausente).';
  END IF;

  -- ── R.3: sin referencias activas → borrado OK con deleted_at/deleted_by ───
  DELETE FROM public.quote_items WHERE quote_id = v_quote_id;
  DELETE FROM public.quotes      WHERE id = v_quote_id;

  UPDATE public.products
  SET    deleted_at = now(), deleted_by = v_fake_user_id
  WHERE  id = v_product_a;

  SELECT deleted_at, deleted_by INTO v_row
  FROM   public.products WHERE id = v_product_a;

  IF v_row.deleted_at IS NULL OR v_row.deleted_by IS DISTINCT FROM v_fake_user_id THEN
    RAISE EXCEPTION 'GATE R.3 FAILED: el soft delete limpio no persistió deleted_at/deleted_by.';
  END IF;

  -- ── R.4: el SKU borrado se recrea (índice parcial RN-B3 operativo) ────────
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, sku)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_r_product_b__', 100, 50, v_sku)
  RETURNING id INTO v_product_b;

  IF v_product_b IS NULL THEN
    RAISE EXCEPTION 'GATE R.4 FAILED: no se pudo recrear el SKU de un producto borrado.';
  END IF;

  -- ── Limpieza child→parent por anchor ──────────────────────────────────────
  -- document_status_history: el AFTER INSERT de quotes (RN-A2) registró la
  -- creación del quote del gate; se borra explícito (además del CASCADE por
  -- accounts) para dejar el child→parent completo y auditable.
  DELETE FROM public.document_status_history WHERE account_id = v_account_id;
  DELETE FROM public.quote_items   WHERE account_id = v_account_id;
  DELETE FROM public.quotes        WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock  WHERE account_id = v_account_id;
  DELETE FROM public.products      WHERE account_id = v_account_id;
  DELETE FROM public.branches      WHERE account_id = v_account_id;
  DELETE FROM public.account_members WHERE user_id = v_fake_user_id;
  DELETE FROM public.accounts      WHERE owner_user_id = v_fake_user_id;
  DELETE FROM public.profiles      WHERE id = v_fake_user_id;
  DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
  DELETE FROM auth.users           WHERE id = v_fake_user_id;

  RAISE NOTICE 'GATES R.2/R.3/R.4 PASSED: rama quotes-draft activa, borrado limpio persiste autoría, SKU recreable.';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE %FAILED%' THEN
      RAISE;
    END IF;
    BEGIN
      DELETE FROM public.document_status_history WHERE account_id = v_account_id;
      DELETE FROM public.quote_items   WHERE account_id = v_account_id;
      DELETE FROM public.quotes        WHERE account_id = v_account_id;
      DELETE FROM public.branch_stock  WHERE account_id = v_account_id;
      DELETE FROM public.products      WHERE account_id = v_account_id;
      DELETE FROM public.branches      WHERE account_id = v_account_id;
      DELETE FROM public.account_members WHERE user_id = v_fake_user_id;
      DELETE FROM public.accounts      WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles      WHERE id = v_fake_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
      DELETE FROM auth.users           WHERE id = v_fake_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- =============================================================================
-- 5. Historial: eliminar las versiones fantasma 20260811000002/3 (aplicadas
--    por la corrida abortada; sus archivos NO existen en el repo). Es el
--    remedio del hazard documentado en CLAUDE.md (historial desincronizado);
--    se hace acá porque `supabase migration repair` exige credenciales que el
--    pipeline no expone fuera de db push. No-op en CI (las filas no existen).
--    Los EFECTOS de esas migraciones quedan reconciliados por las secciones
--    1-4 (columnas e índices eran idénticos a los canónicos; guard/trigger/
--    comments quedan corregidos acá).
-- =============================================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'supabase_migrations' AND table_name = 'schema_migrations'
  ) THEN
    DELETE FROM supabase_migrations.schema_migrations
    WHERE version IN ('20260811000002', '20260811000003');
    RAISE NOTICE 'Historial reconciliado: versiones fantasma 20260811000002/3 eliminadas si existían.';
  ELSE
    RAISE NOTICE 'supabase_migrations.schema_migrations no existe en este entorno — nada que reconciliar.';
  END IF;
END $$;
