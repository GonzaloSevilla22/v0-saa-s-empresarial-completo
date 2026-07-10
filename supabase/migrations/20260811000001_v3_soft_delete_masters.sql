-- =============================================================================
-- v3-soft-delete-policy — Soft delete unificado de maestros (Modelo V3 §4)
--
-- Política única de borrado por categoría (RN-B1..RN-B4):
--   - Maestros → soft delete (deleted_at + deleted_by). Este change.
--   - Documentos confirmados → nunca se borran; se anulan por transición
--     con motivo (document-status-history, 20260807000001).
--   - Ledgers append-only → contra-asiento (ya resuelto por diseño).
--   - Drafts → hard delete permitido (sin valor probatorio).
--   - Plataforma → Membership se revoca, UserAccount se anonimiza.
--
-- Alcance de maestros: clients, products, suppliers, cost_centers,
-- cashboxes, bank_accounts. `branches` queda FUERA (V3 §4: se desactiva con
-- is_active, no se borra — tiene movimientos referenciándola y su propia FSM).
-- `categories` / `price_lists` no existen como tablas — nada que migrar.
--
-- Decisiones vinculantes (design.md del change):
--   D1: is_active se CONSERVA (baja lógica reversible); deleted_at/deleted_by
--       se agregan EN PARALELO. Sin drops. No BREAKING.
--   D2: índices únicos parciales ganan "AND deleted_at IS NULL" manteniendo
--       el scope existente (products sigue por user_id — OQ1 fuera de scope).
--   D3: guard RN-B4 como trigger BEFORE UPDATE sobre products (ERRCODE P0B04).
--   D5: migración aditiva; gates degradan con NOTICE en CI vacío donde son
--       data-dependientes; gates con fixture sintético se auto-limpian
--       child→parent (lección PRs #268/#269).
--
-- Rollback: aditivo — en prod NO se dropea; se deja de escribir. (Referencia:
--   DROP TRIGGER trg_guard_product_soft_delete ON products;
--   DROP FUNCTION fn_guard_product_soft_delete();
--   DROP COLUMN deleted_at/deleted_by; recrear índices sin el predicado.)
-- =============================================================================


-- =============================================================================
-- 1. Columnas de soft delete (tasks 1.1 / 1.2 — aditivo, IF NOT EXISTS)
--    products.deleted_at YA existe (20260620000001): solo se agrega deleted_by.
--    deleted_by es uuid SIN FK dura a auth.users: referencia lógica, consistente
--    con otras columnas de autoría del proyecto (no acopla a auth, no bloquea).
-- =============================================================================

ALTER TABLE public.clients       ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.clients       ADD COLUMN IF NOT EXISTS deleted_by uuid;

ALTER TABLE public.products      ADD COLUMN IF NOT EXISTS deleted_by uuid;

ALTER TABLE public.suppliers     ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.suppliers     ADD COLUMN IF NOT EXISTS deleted_by uuid;

ALTER TABLE public.cost_centers  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.cost_centers  ADD COLUMN IF NOT EXISTS deleted_by uuid;

ALTER TABLE public.cashboxes     ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.cashboxes     ADD COLUMN IF NOT EXISTS deleted_by uuid;

ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS deleted_by uuid;

-- ── 1.3 Convivencia is_active vs deleted_at (D1) ────────────────────────────
-- is_active = baja lógica REVERSIBLE (desactivar temporalmente; pantallas de
-- administración la muestran). deleted_at IS NOT NULL = BORRADO (fuera de toda
-- lectura por defecto; irreversible desde la UI). deleted_at implica inactivo,
-- pero is_active=false NO implica borrado.

COMMENT ON COLUMN public.cost_centers.is_active IS
  'Baja lógica REVERSIBLE: FALSE oculta el centro de los selectores de altas '
  'nuevas pero conserva imputaciones históricas y puede reactivarse. Para el '
  'BORRADO real ver deleted_at (v3-soft-delete-policy, D1).';

COMMENT ON COLUMN public.cost_centers.deleted_at IS
  'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado — la fila sale de '
  'toda lectura por defecto. Convive con is_active (baja lógica reversible): '
  'deleted_at implica inactivo, pero is_active=false NO implica borrado.';

COMMENT ON COLUMN public.cost_centers.deleted_by IS
  'Autoría del borrado (RN-B2): uuid del usuario que ejecutó el soft delete. '
  'Referencia lógica a auth.users (sin FK dura).';

COMMENT ON COLUMN public.bank_accounts.is_active IS
  'Baja lógica REVERSIBLE: FALSE desactiva la cuenta bancaria (no aparece en '
  'selectores operativos) pero puede reactivarse. Para el BORRADO real ver '
  'deleted_at (v3-soft-delete-policy, D1).';

COMMENT ON COLUMN public.bank_accounts.deleted_at IS
  'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado — la fila sale de '
  'toda lectura por defecto. Convive con is_active (baja lógica reversible).';

COMMENT ON COLUMN public.bank_accounts.deleted_by IS
  'Autoría del borrado (RN-B2): uuid del usuario que ejecutó el soft delete.';

COMMENT ON COLUMN public.clients.deleted_at IS
  'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado. Reemplaza al hard '
  'delete previo del backend — las referencias históricas (ventas, cuentas '
  'corrientes) se preservan.';

COMMENT ON COLUMN public.clients.deleted_by IS
  'Autoría del borrado (RN-B2): uuid del usuario que ejecutó el soft delete.';

COMMENT ON COLUMN public.products.deleted_by IS
  'Autoría del borrado (RN-B2): uuid del usuario que ejecutó el soft delete. '
  'Completa el deleted_at que existe desde 20260620000001.';

COMMENT ON COLUMN public.suppliers.deleted_at IS
  'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado.';

COMMENT ON COLUMN public.suppliers.deleted_by IS
  'Autoría del borrado (RN-B2): uuid del usuario que ejecutó el soft delete.';

COMMENT ON COLUMN public.cashboxes.deleted_at IS
  'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado. Scope de cuenta '
  'INDIRECTO vía branch_id → branches.account_id (OQ2 del design).';

COMMENT ON COLUMN public.cashboxes.deleted_by IS
  'Autoría del borrado (RN-B2): uuid del usuario que ejecutó el soft delete.';


-- =============================================================================
-- 1.4 GATE estructural: las 6 tablas quedan con deleted_at + deleted_by.
--     Degrada con NOTICE/WARNING (no aborta) — task 1.4.
-- =============================================================================
DO $$
DECLARE
  v_missing text := '';
  v_tbl     text;
  v_col     text;
BEGIN
  FOREACH v_tbl IN ARRAY ARRAY['clients','products','suppliers','cost_centers','cashboxes','bank_accounts'] LOOP
    FOREACH v_col IN ARRAY ARRAY['deleted_at','deleted_by'] LOOP
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = v_tbl AND column_name = v_col
      ) THEN
        v_missing := v_missing || format(' %s.%s', v_tbl, v_col);
      END IF;
    END LOOP;
  END LOOP;

  IF v_missing <> '' THEN
    RAISE WARNING 'GATE 1.4 DEGRADED: faltan columnas de soft delete:%s', v_missing;
  ELSE
    RAISE NOTICE 'GATE 1.4 PASSED: las 6 tablas de maestros tienen deleted_at y deleted_by.';
  END IF;
END $$;


-- =============================================================================
-- 2. Índices únicos parciales (RN-B3, tasks 2.1–2.4)
--    Gate 2.1 integrado: si hay duplicados ACTIVOS por clave natural, NOTICE
--    y se conserva el índice existente (no aborta, no rompe db push en prod).
--    Nota D2: el índice nuevo es MÁS permisivo (excluye borrados) — sobre
--    datos existentes no puede introducir colisiones nuevas; el gate es
--    defensa en profundidad.
-- =============================================================================

-- ── 2.2 products SKU: (user_id, sku) WHERE sku IS NOT NULL AND deleted_at IS NULL
DO $$
DECLARE
  v_dupes int;
BEGIN
  SELECT COUNT(*) INTO v_dupes FROM (
    SELECT user_id, sku
    FROM   public.products
    WHERE  sku IS NOT NULL AND deleted_at IS NULL
    GROUP  BY user_id, sku
    HAVING COUNT(*) > 1
  ) d;

  IF v_dupes > 0 THEN
    RAISE NOTICE 'GATE 2.1 (products.sku) DEGRADED: % claves (user_id, sku) duplicadas entre filas activas — se conserva el índice existente sin recrear. Requiere limpieza manual antes de reintentar.', v_dupes;
  ELSE
    DROP INDEX IF EXISTS public.idx_products_sku_user;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_products_sku_user
      ON public.products (user_id, sku)
      WHERE sku IS NOT NULL AND deleted_at IS NULL;
    RAISE NOTICE 'GATE 2.1 (products.sku) PASSED: 0 duplicados activos — idx_products_sku_user recreado parcial (RN-B3).';
  END IF;
END $$;

-- ── 2.3 products barcode: añade AND deleted_at IS NULL al WHERE existente
DO $$
DECLARE
  v_dupes int;
BEGIN
  SELECT COUNT(*) INTO v_dupes FROM (
    SELECT user_id, barcode
    FROM   public.products
    WHERE  barcode IS NOT NULL AND barcode <> '' AND deleted_at IS NULL
    GROUP  BY user_id, barcode
    HAVING COUNT(*) > 1
  ) d;

  IF v_dupes > 0 THEN
    RAISE NOTICE 'GATE 2.1 (products.barcode) DEGRADED: % claves (user_id, barcode) duplicadas entre filas activas — se conserva el índice existente sin recrear.', v_dupes;
  ELSE
    DROP INDEX IF EXISTS public.idx_products_barcode_unique;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_products_barcode_unique
      ON public.products (user_id, barcode)
      WHERE barcode IS NOT NULL AND barcode <> '' AND deleted_at IS NULL;
    RAISE NOTICE 'GATE 2.1 (products.barcode) PASSED: 0 duplicados activos — idx_products_barcode_unique recreado parcial (RN-B3).';
  END IF;
END $$;

-- ── 2.4 cost_centers: (account_id, lower(name)) WHERE deleted_at IS NULL
--        (reemplaza cost_centers_account_name_lower_idx, mismo nombre)
DO $$
DECLARE
  v_dupes int;
BEGIN
  SELECT COUNT(*) INTO v_dupes FROM (
    SELECT account_id, lower(name) AS lname
    FROM   public.cost_centers
    WHERE  deleted_at IS NULL
    GROUP  BY account_id, lower(name)
    HAVING COUNT(*) > 1
  ) d;

  IF v_dupes > 0 THEN
    RAISE NOTICE 'GATE 2.1 (cost_centers.name) DEGRADED: % nombres duplicados entre filas activas — se conserva el índice existente sin recrear.', v_dupes;
  ELSE
    DROP INDEX IF EXISTS public.cost_centers_account_name_lower_idx;
    CREATE UNIQUE INDEX IF NOT EXISTS cost_centers_account_name_lower_idx
      ON public.cost_centers (account_id, lower(name))
      WHERE deleted_at IS NULL;
    RAISE NOTICE 'GATE 2.1 (cost_centers.name) PASSED: 0 duplicados activos — cost_centers_account_name_lower_idx recreado parcial (RN-B3).';
  END IF;
END $$;


-- =============================================================================
-- 3. Guard RN-B4: no soft-deletear un producto con referencia activa
--    (tasks 3.1 / 3.2 / 3.4)
--
-- 3.4 — Enumeración VERIFICADA de estados 'draft' vigentes (lección C3: la
--       unión se enumera contra el schema real, CI no atrapa kinds faltantes):
--   - quotes.status: CHECK ('draft','sent','accepted','expired','rejected')
--     (20260702000001) — líneas en quote_items.product_id.
--   - sales_orders.status: CHECK ('draft','confirmed','canceled')
--     (20260702000001) — líneas en sales_order_items.product_id.
--   Son los ÚNICOS documentos con estado 'draft' en el schema y en el catálogo
--   FSM document_status_transitions (20260807000001). sales/purchases nacen
--   confirmadas (sin draft); fiscal_documents usa pending_cae/authorized/
--   rejected; cash_sessions usa open/closed. sale_items/purchase_items cuelgan
--   de documentos SIN estado draft — no participan del guard.
--
-- SECURITY DEFINER: el guard debe poder leer branch_stock/quotes/sales_orders
-- aunque el UPDATE venga de un rol con RLS que no vea esas filas — es un
-- invariante de datos, imposible de saltar desde cualquier capa (D3).
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
  'layer lo traduce a HTTP 409 con mensaje de UX.';

DROP TRIGGER IF EXISTS trg_guard_product_soft_delete ON public.products;
CREATE TRIGGER trg_guard_product_soft_delete
  BEFORE UPDATE ON public.products
  FOR EACH ROW
  WHEN (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL)
  EXECUTE FUNCTION public.fn_guard_product_soft_delete();


-- =============================================================================
-- 4. GATES de comportamiento (tasks 2.5 + 3.3) — fixture sintético
--    auto-limpiado child→parent (patrón 20260809000001 / PRs #268/#269).
--    El anchor entra por auth.users (email identificable) y el trigger
--    handle_new_user auto-crea account + membership; la limpieza borra por
--    owner_user_id para cubrir cualquier account auto-creada.
--    Los fallos de aserción ABORTAN (fixture determinístico, CI lo atrapa);
--    los pasos data-dependientes degradan con NOTICE.
-- =============================================================================
DO $$
DECLARE
  v_fake_user_id uuid := gen_random_uuid();
  v_account_id   uuid;
  v_branch_id    uuid;
  v_product_a    uuid;  -- con stock → borrado rechazado; luego stock 0 → borrado OK
  v_product_b    uuid;  -- en quote draft → borrado rechazado; sin draft → OK
  v_product_c    uuid;  -- recrea el SKU de A tras el soft delete (gate 2.5)
  v_quote_id     uuid;
  v_row          record;
  v_guard_fired  boolean;
  v_sku          text := '__gate_v3_sd_sku__';
  v_idx_partial  boolean;
BEGIN
  -- ── Fixture ────────────────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_fake_user_id, 'authenticated', 'authenticated',
          'v3-soft-delete-gate@test.local', now(), now(),
          jsonb_build_object('name', 'Gate v3-soft-delete', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_fake_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    -- Fallback defensivo si handle_new_user no auto-creó nada (drift).
    INSERT INTO public.accounts (id, owner_user_id)
    VALUES (gen_random_uuid(), v_fake_user_id)
    RETURNING id INTO v_account_id;
    INSERT INTO public.account_members (account_id, user_id, role)
    VALUES (v_account_id, v_fake_user_id, 'owner')
    ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO public.branches (id, account_id, name)
  VALUES (gen_random_uuid(), v_account_id, '__gate_v3_sd_branch__')
  RETURNING id INTO v_branch_id;

  INSERT INTO public.products (id, user_id, account_id, name, price, cost, sku)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_v3_sd_product_a__', 100, 50, v_sku)
  RETURNING id INTO v_product_a;

  INSERT INTO public.products (id, user_id, account_id, name, price, cost)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_v3_sd_product_b__', 100, 50)
  RETURNING id INTO v_product_b;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_product_a, v_branch_id, 10, 0);

  -- ── GATE 3.3.a: soft delete con stock <> 0 → rechazado con P0B04 ──────────
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
    RAISE EXCEPTION 'GATE 3.3.a FAILED: el soft delete de un producto con stock 10 NO fue rechazado por el guard RN-B4.';
  END IF;

  -- ── GATE 3.3.b: producto en quote draft → rechazado con P0B04 ─────────────
  INSERT INTO public.quotes (id, account_id, branch_id, status, total, created_by)
  VALUES (gen_random_uuid(), v_account_id, v_branch_id, 'draft', 100, v_fake_user_id)
  RETURNING id INTO v_quote_id;

  INSERT INTO public.quote_items (quote_id, account_id, product_id, quantity, price, subtotal)
  VALUES (v_quote_id, v_account_id, v_product_b, 1, 100, 100);

  v_guard_fired := false;
  BEGIN
    UPDATE public.products
    SET    deleted_at = now(), deleted_by = v_fake_user_id
    WHERE  id = v_product_b;
  EXCEPTION
    WHEN SQLSTATE 'P0B04' THEN
      v_guard_fired := true;
  END;

  IF NOT v_guard_fired THEN
    RAISE EXCEPTION 'GATE 3.3.b FAILED: el soft delete de un producto en un quote draft NO fue rechazado por el guard RN-B4.';
  END IF;

  -- ── GATE 3.3.c: sin stock ni drafts → el soft delete tiene éxito ──────────
  UPDATE public.branch_stock SET quantity = 0
  WHERE  product_id = v_product_a AND branch_id = v_branch_id;

  UPDATE public.products
  SET    deleted_at = now(), deleted_by = v_fake_user_id
  WHERE  id = v_product_a;

  SELECT deleted_at, deleted_by INTO v_row
  FROM   public.products WHERE id = v_product_a;

  IF v_row.deleted_at IS NULL OR v_row.deleted_by IS DISTINCT FROM v_fake_user_id THEN
    RAISE EXCEPTION 'GATE 3.3.c FAILED: el soft delete sin referencias activas no persistió deleted_at/deleted_by (deleted_at=%, deleted_by=%).',
      v_row.deleted_at, v_row.deleted_by;
  END IF;

  -- ── GATE 2.5: el SKU del producto borrado se puede recrear ────────────────
  SELECT indexdef LIKE '%deleted_at IS NULL%' INTO v_idx_partial
  FROM   pg_indexes
  WHERE  schemaname = 'public' AND indexname = 'idx_products_sku_user';

  IF v_idx_partial IS DISTINCT FROM true THEN
    RAISE NOTICE 'GATE 2.5 DEGRADED: idx_products_sku_user no es parcial por deleted_at (¿gate 2.1 lo saltó por duplicados?) — se omite la verificación de recreación de SKU.';
  ELSE
    INSERT INTO public.products (id, user_id, account_id, name, price, cost, sku)
    VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_v3_sd_product_c__', 100, 50, v_sku)
    RETURNING id INTO v_product_c;

    -- Triangulación: un SEGUNDO activo con el mismo SKU sí debe violar unicidad.
    v_guard_fired := false;
    BEGIN
      INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
      VALUES (v_fake_user_id, v_account_id, '__gate_v3_sd_product_d__', 100, 50, v_sku);
    EXCEPTION
      WHEN unique_violation THEN
        v_guard_fired := true;
    END;

    IF NOT v_guard_fired THEN
      RAISE EXCEPTION 'GATE 2.5 FAILED: dos productos ACTIVOS con el mismo SKU no violaron el índice único parcial.';
    END IF;

    RAISE NOTICE 'GATE 2.5 PASSED: SKU de producto borrado recreable; duplicado activo rechazado (RN-B3).';
  END IF;

  -- ── Limpieza child→parent por anchor (lección PRs #268/#269) ──────────────
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

  RAISE NOTICE 'GATE 3.3 PASSED: guard RN-B4 rechaza stock<>0 (a) y draft-ref (b); permite el borrado limpio con deleted_at+deleted_by (c).';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE %FAILED%' THEN
      RAISE;
    END IF;
    -- Best-effort cleanup si algo falló a mitad de camino.
    BEGIN
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
