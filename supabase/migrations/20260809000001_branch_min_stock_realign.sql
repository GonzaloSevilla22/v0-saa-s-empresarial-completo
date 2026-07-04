-- =============================================================================
-- branch-min-stock-realign — Realinea el umbral de alerta de stock bajo
--
-- Problema: el formulario de productos escribe products.min_stock, pero los
-- consumidores REALES de la alerta (trigger check_branch_low_stock → email +
-- productor StockBelowMinimum a la outbox) leen branch_stock.min_stock, que
-- nace en 0 y nunca se actualiza tras la creación. Divergencia doble
-- (write path + read path): la pantalla responde al valor editado (lee la
-- vista, que hoy expone p.min_stock), pero el email/campana disparan contra
-- un valor viejo y frozen.
--
-- Esta migración:
--   1.2 Crea rpc_set_product_min_stock (SECURITY DEFINER + is_account_writer)
--       que propaga min_stock a TODAS las filas branch_stock existentes del
--       producto (semántica "aplica a todas las sucursales", decisión PO
--       2026-07-04).
--   1.3/1.4 Gate RED→GREEN de la RPC.
--   1.5/1.6 Backfill idempotente products.min_stock → branch_stock.min_stock
--       con gate de 0 divergencias.
--   1.7/1.8 Recrea v_products_with_stock exponiendo min_stock DERIVADO de
--       branch_stock (no de products.min_stock), mismo nombre de columna.
--   1.9 Deprecación (COMMENT) de products.min_stock — NO se dropea.
--   1.10 Gate de paridad: el trigger check_branch_low_stock sigue emitiendo
--       StockBelowMinimum (no se toca en este change).
--
-- No afecta: rpc_bulk_upsert_products (dual-write se conserva),
-- rpc_adjust_branch_stock, rpc_transfer_stock, rpc_apply_product_stock_delta
-- (siguen tocando solo quantity), stock_movements, dinero/fiscal.
--
-- Governance: MEDIO. Prod: gxdhpxvdjjkmxhdkkwyb.
-- =============================================================================


-- =============================================================================
-- 1.2 — rpc_set_product_min_stock
--
-- Esqueleto de rpc_adjust_branch_stock (20260608000000_branch_stock.sql:876).
-- Propaga p_min_stock a TODAS las filas branch_stock existentes del producto.
-- Guards: auth.uid() NOT NULL (P0401) → resolver account_id del producto →
-- is_account_writer(account_id) (P0401) → producto existe (P0404).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_set_product_min_stock(
  p_product_id uuid,
  p_min_stock  int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid        uuid;
  v_account_id uuid;
  v_min_stock  int;
  v_updated    int;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- Resolver la cuenta del producto (no la del caller): el producto ya
  -- pertenece a una cuenta fija; el caller debe ser writer de ESA cuenta.
  SELECT account_id INTO v_account_id
  FROM   public.products
  WHERE  id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can set min_stock'
      USING ERRCODE = 'P0401';
  END IF;

  v_min_stock := GREATEST(COALESCE(p_min_stock, 0), 0);

  UPDATE public.branch_stock
  SET    min_stock = v_min_stock
  WHERE  product_id = p_product_id
    AND  account_id = v_account_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object(
    'product_id',    p_product_id,
    'min_stock',     v_min_stock,
    'rows_updated',  v_updated
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_set_product_min_stock IS
  'branch-min-stock-realign (1.2): propaga min_stock del producto a TODAS '
  'las filas branch_stock existentes de ese producto (semántica "aplica a '
  'todas las sucursales", decisión PO 2026-07-04). SECURITY DEFINER + guard '
  'is_account_writer — mismo patrón que rpc_adjust_branch_stock. Filas '
  'branch_stock lazy futuras (creadas por otros deltas) nacen en min_stock=0 '
  'hasta la próxima edición que re-propague; comportamiento aceptado y '
  'documentado (ver design.md Decisión (a)).';

REVOKE ALL     ON FUNCTION public.rpc_set_product_min_stock(uuid, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_set_product_min_stock(uuid, int) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_set_product_min_stock(uuid, int) TO authenticated;


-- =============================================================================
-- 1.3/1.4 — RED→GREEN gate: rpc_set_product_min_stock actualiza TODAS las
-- filas branch_stock de un producto de prueba (2 sucursales), y solo esas
-- filas (no otro producto). Fixture creado y revertido dentro del bloque.
-- =============================================================================
DO $$
DECLARE
  v_fake_user_id      uuid := gen_random_uuid();
  v_account_id        uuid;
  v_branch_a          uuid;
  v_branch_b          uuid;
  v_product_id        uuid;
  v_other_product_id  uuid;
  v_min_a             int;
  v_min_b             int;
  v_min_other         int;
  v_rpc_result        jsonb;
BEGIN
  -- Anchor sintético: accounts.owner_user_id es NOT NULL REFERENCES auth.users.
  -- Patrón C2/C3 (20260805000001_bank_reconciliation.sql:1288-1305): crear un
  -- auth.users + accounts real y aislado, limpiar al final.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_fake_user_id, 'authenticated', 'authenticated',
          'branch-min-stock-gate-1-3@test.local', now(), now(),
          jsonb_build_object('name', 'Gate 1.3', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.accounts (id, owner_user_id)
  VALUES (gen_random_uuid(), v_fake_user_id)
  RETURNING id INTO v_account_id;

  INSERT INTO public.branches (id, account_id, name)
  VALUES (gen_random_uuid(), v_account_id, '__gate_1_3_branch_a__')
  RETURNING id INTO v_branch_a;

  INSERT INTO public.branches (id, account_id, name)
  VALUES (gen_random_uuid(), v_account_id, '__gate_1_3_branch_b__')
  RETURNING id INTO v_branch_b;

  INSERT INTO public.products (id, user_id, account_id, name, price, cost)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_1_3_product__', 100, 50)
  RETURNING id INTO v_product_id;

  INSERT INTO public.products (id, user_id, account_id, name, price, cost)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_1_3_other_product__', 100, 50)
  RETURNING id INTO v_other_product_id;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_product_id, v_branch_a, 10, 0);
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_product_id, v_branch_b, 20, 0);
  -- Control: otro producto, no debe verse afectado.
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_other_product_id, v_branch_a, 5, 0);

  -- Simular la sesión JWT del owner para pasar el guard is_account_writer
  -- de la RPC real (ejercemos la RPC completa, no un UPDATE directo).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_id::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_fake_user_id::text, true);

  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_id, v_fake_user_id, 'owner')
  ON CONFLICT DO NOTHING;

  SELECT public.rpc_set_product_min_stock(v_product_id, 7) INTO v_rpc_result;

  SELECT min_stock INTO v_min_a FROM public.branch_stock
    WHERE product_id = v_product_id AND branch_id = v_branch_a;
  SELECT min_stock INTO v_min_b FROM public.branch_stock
    WHERE product_id = v_product_id AND branch_id = v_branch_b;
  SELECT min_stock INTO v_min_other FROM public.branch_stock
    WHERE product_id = v_other_product_id AND branch_id = v_branch_a;

  IF v_min_a <> 7 OR v_min_b <> 7 THEN
    RAISE EXCEPTION
      'GATE 1.3 FAILED: propagación no actualizó todas las filas branch_stock (a=%, b=%)',
      v_min_a, v_min_b;
  END IF;

  IF v_min_other <> 0 THEN
    RAISE EXCEPTION
      'GATE 1.3 FAILED: propagación afectó branch_stock de OTRO producto (other=%)',
      v_min_other;
  END IF;

  -- Limpieza del fixture (no dejar basura en prod).
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  DELETE FROM public.branch_stock WHERE account_id = v_account_id;
  DELETE FROM public.products WHERE account_id = v_account_id;
  DELETE FROM public.branches WHERE account_id = v_account_id;
  DELETE FROM public.account_members WHERE account_id = v_account_id;
  DELETE FROM public.accounts WHERE id = v_account_id;
  DELETE FROM auth.users WHERE id = v_fake_user_id;

  RAISE NOTICE 'GATE 1.3/1.4 PASSED: rpc_set_product_min_stock propaga a todas las filas branch_stock del producto, sin afectar otros productos.';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE 1.3 FAILED%' THEN
      RAISE;
    END IF;
    -- Best-effort cleanup si algo falló a mitad de camino.
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      DELETE FROM public.branch_stock WHERE account_id = v_account_id;
      DELETE FROM public.products WHERE account_id = v_account_id;
      DELETE FROM public.branches WHERE account_id = v_account_id;
      DELETE FROM public.account_members WHERE account_id = v_account_id;
      DELETE FROM public.accounts WHERE id = v_account_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- =============================================================================
-- 1.5 — Backfill idempotente products.min_stock → branch_stock.min_stock
--
-- Dirección products→branch_stock: es el valor que el usuario editó
-- creyendo que funcionaba. IS DISTINCT FROM hace el UPDATE idempotente
-- (converge, no re-escribe filas ya sincronizadas). Espeja el estilo de la
-- reconciliación C-21 (20260620000001:146-159).
-- =============================================================================
UPDATE public.branch_stock bs
SET    min_stock = COALESCE(p.min_stock, 0)
FROM   public.products p
WHERE  bs.product_id = p.id
  AND  p.deleted_at IS NULL
  AND  bs.min_stock IS DISTINCT FROM COALESCE(p.min_stock, 0);


-- =============================================================================
-- 1.6 — GATE (0 divergencias): aborta la migración si queda alguna fila
-- branch_stock de un producto no borrado con min_stock <> products.min_stock.
-- =============================================================================
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM   public.branch_stock bs
  JOIN   public.products p ON p.id = bs.product_id
  WHERE  p.deleted_at IS NULL
    AND  bs.min_stock <> COALESCE(p.min_stock, 0);

  IF v_count > 0 THEN
    RAISE EXCEPTION
      'GATE 1.6 FAILED: % filas branch_stock siguen con min_stock ≠ products.min_stock tras el backfill. Rollback.',
      v_count;
  END IF;

  RAISE NOTICE 'GATE 1.6 PASSED: 0 divergencias branch_stock.min_stock vs products.min_stock.';
END $$;


-- =============================================================================
-- 1.7 — Recrear v_products_with_stock: min_stock DERIVADO de branch_stock
--
-- Lista explícita de columnas idéntica a 20260620000001:207-257, reemplazando
-- la fuente de min_stock: en vez de p.min_stock, exponer
-- COALESCE(MAX(bs.min_stock), 0) — espejo de la subconsulta de stock.
-- Con la propagación "aplica a todas", el valor es uniforme entre filas de
-- un mismo producto, así que MAX es seguro y determinista.
-- security_invoker = true se preserva (no bypasea RLS).
-- =============================================================================
DROP VIEW IF EXISTS public.v_products_with_stock;

CREATE VIEW public.v_products_with_stock
WITH (security_invoker = true)
AS
SELECT
    p.id,
    p.user_id,
    p.name,
    p.price,
    p.cost,
    p.created_at,
    p.category,
    -- branch-min-stock-realign (1.7): min_stock ahora deriva de branch_stock,
    -- NO de products.min_stock (columna deprecada, ver COMMENT en 1.9).
    -- Mismo nombre de columna: cero cambios de frontend.
    COALESCE(
        (SELECT MAX(bs.min_stock)
         FROM   public.branch_stock bs
         WHERE  bs.product_id = p.id),
        0
    ) AS min_stock,
    p.parent_id,
    p.barcode,
    p.is_variant,
    p.company_id,
    p.sku,
    p.account_id,
    p.deleted_at,
    p.stock_control_type,
    -- stock calculado desde branch_stock (sin cambios, C-21).
    COALESCE(
        (SELECT SUM(bs.quantity)
         FROM   public.branch_stock bs
         WHERE  bs.product_id = p.id),
        0
    ) AS stock
FROM public.products p;

COMMENT ON VIEW public.v_products_with_stock IS
    'C-21 + branch-min-stock-realign: vista de compatibilidad — expone '
    'columnas explícitas de products (sin products.stock ni products.min_stock '
    'como fuente) con stock = COALESCE(Σ branch_stock.quantity, 0) y '
    'min_stock = COALESCE(MAX(branch_stock.min_stock), 0). '
    'security_invoker = true (no bypasea RLS). Mismo nombre de columna '
    '"min_stock" que antes — ningún consumidor de frontend cambia. '
    'products.min_stock queda DEPRECATED (ver COMMENT en esa columna); '
    'la única fuente de verdad del umbral de alerta es branch_stock.min_stock.';


-- =============================================================================
-- 1.8 — GATE: la vista expone min_stock derivado de branch_stock
--
-- Caso 1: producto con products.min_stock distinto del branch_stock.min_stock
--   → la vista debe devolver el de branch_stock.
-- Caso 2: producto sin ninguna fila branch_stock → la vista debe exponer 0
--   (COALESCE), sin error.
-- =============================================================================
DO $$
DECLARE
  v_fake_user_id uuid := gen_random_uuid();
  v_account_id  uuid;
  v_branch_id   uuid;
  v_product_id  uuid;
  v_product_no_rows_id uuid;
  v_view_min_stock int;
  v_view_min_stock_no_rows int;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_fake_user_id, 'authenticated', 'authenticated',
          'branch-min-stock-gate-1-8@test.local', now(), now(),
          jsonb_build_object('name', 'Gate 1.8', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.accounts (id, owner_user_id)
  VALUES (gen_random_uuid(), v_fake_user_id)
  RETURNING id INTO v_account_id;

  INSERT INTO public.branches (id, account_id, name)
  VALUES (gen_random_uuid(), v_account_id, '__gate_1_8_branch__')
  RETURNING id INTO v_branch_id;

  -- Caso 1: products.min_stock = 99 (legacy), branch_stock.min_stock = 5.
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, min_stock)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_1_8_product__', 100, 50, 99)
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_product_id, v_branch_id, 10, 5);

  SELECT min_stock INTO v_view_min_stock
  FROM public.v_products_with_stock
  WHERE id = v_product_id;

  IF v_view_min_stock <> 5 THEN
    RAISE EXCEPTION
      'GATE 1.8 FAILED: la vista expuso min_stock=% (esperado 5 desde branch_stock, no 99 de products)',
      v_view_min_stock;
  END IF;

  -- Caso 2: producto sin ninguna fila branch_stock.
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, min_stock)
  VALUES (gen_random_uuid(), v_fake_user_id, v_account_id, '__gate_1_8_product_no_rows__', 100, 50, 42)
  RETURNING id INTO v_product_no_rows_id;

  SELECT min_stock INTO v_view_min_stock_no_rows
  FROM public.v_products_with_stock
  WHERE id = v_product_no_rows_id;

  IF v_view_min_stock_no_rows <> 0 THEN
    RAISE EXCEPTION
      'GATE 1.8 FAILED: producto sin filas branch_stock expuso min_stock=% (esperado 0 via COALESCE)',
      v_view_min_stock_no_rows;
  END IF;

  -- Revertir el fixture.
  DELETE FROM public.branch_stock WHERE account_id = v_account_id;
  DELETE FROM public.products WHERE account_id = v_account_id;
  DELETE FROM public.branches WHERE account_id = v_account_id;
  DELETE FROM public.accounts WHERE id = v_account_id;
  DELETE FROM auth.users WHERE id = v_fake_user_id;

  RAISE NOTICE 'GATE 1.8 PASSED: v_products_with_stock expone min_stock derivado de branch_stock (con y sin filas).';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE 1.8 FAILED%' THEN
      RAISE;
    END IF;
    BEGIN
      DELETE FROM public.branch_stock WHERE account_id = v_account_id;
      DELETE FROM public.products WHERE account_id = v_account_id;
      DELETE FROM public.branches WHERE account_id = v_account_id;
      DELETE FROM public.accounts WHERE id = v_account_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- =============================================================================
-- 1.9 — Deprecación de products.min_stock (COMMENT, NO DROP)
--
-- La columna se conserva por el dual-write del importador
-- (rpc_bulk_upsert_products). DROP diferido a un change destructivo
-- posterior, como su hermana products.stock (C-21 checkpoint #2).
-- =============================================================================
COMMENT ON COLUMN public.products.min_stock IS
  'DEPRECATED (branch-min-stock-realign, 2026-07-04): fuente de verdad del '
  'umbral de alerta es branch_stock.min_stock. Se conserva por el dual-write '
  'del importador; DROP diferido a change destructivo posterior.';


-- =============================================================================
-- 1.10 — GATE de paridad: check_branch_low_stock sigue existiendo y emite
-- StockBelowMinimum a la outbox (no se toca el trigger en este change; el
-- gate solo verifica que no se rompió).
-- =============================================================================
DO $$
DECLARE
  v_trigger_exists boolean;
  v_function_source text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM   pg_trigger t
    JOIN   pg_class c ON c.oid = t.tgrelid
    WHERE  c.relname = 'branch_stock'
      AND  t.tgname = 'on_branch_stock_update'
      AND  NOT t.tgisinternal
  ) INTO v_trigger_exists;

  IF NOT v_trigger_exists THEN
    RAISE EXCEPTION
      'GATE 1.10 FAILED: el trigger on_branch_stock_update ya no existe sobre branch_stock.';
  END IF;

  SELECT pg_get_functiondef(oid) INTO v_function_source
  FROM   pg_proc
  WHERE  proname = 'check_branch_low_stock'
  LIMIT 1;

  IF v_function_source IS NULL THEN
    RAISE EXCEPTION
      'GATE 1.10 FAILED: la función check_branch_low_stock ya no existe.';
  END IF;

  IF v_function_source NOT LIKE '%StockBelowMinimum%' THEN
    RAISE EXCEPTION
      'GATE 1.10 FAILED: check_branch_low_stock ya no emite StockBelowMinimum a la outbox (parity broken).';
  END IF;

  IF v_function_source NOT LIKE '%low_branch_stock_alert%' THEN
    RAISE EXCEPTION
      'GATE 1.10 FAILED: check_branch_low_stock ya no encola low_branch_stock_alert en email_logs (parity broken).';
  END IF;

  RAISE NOTICE 'GATE 1.10 PASSED: check_branch_low_stock sigue existiendo y emitiendo StockBelowMinimum + low_branch_stock_alert.';
END $$;


-- =============================================================================
-- 1.11 — Confirmado en propose (2026-07-04): get_dashboard_critical_stock
-- (ambos overloads, 20260623000001:74-116) y rpc_dashboard_kpi_summary leen
-- FROM v_products_with_stock WHERE stock <= min_stock. Al recrear la vista
-- con min_stock derivado de branch_stock, ambos KPIs auto-alinean SIN tocar
-- ninguna función. Gate de verificación defensivo: confirmar que ambas
-- funciones siguen leyendo de la vista (no de products directo) — si
-- divergiera de lo verificado en propose, esta migración fallaría acá y
-- habría que recrearlas en un fix-forward.
-- =============================================================================
DO $$
DECLARE
  v_src_1 text;
  v_src_2 text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src_1
  FROM   pg_proc
  WHERE  proname = 'get_dashboard_critical_stock'
    AND  pronargs = 0
  LIMIT 1;

  IF v_src_1 IS NULL OR v_src_1 NOT LIKE '%v_products_with_stock%' THEN
    RAISE EXCEPTION
      'GATE 1.11 FAILED: get_dashboard_critical_stock() ya no lee v_products_with_stock (drift detectado — requiere fix-forward).';
  END IF;

  SELECT pg_get_functiondef(oid) INTO v_src_2
  FROM   pg_proc
  WHERE  proname = 'rpc_dashboard_kpi_summary'
  LIMIT 1;

  IF v_src_2 IS NULL OR v_src_2 NOT LIKE '%v_products_with_stock%' THEN
    RAISE EXCEPTION
      'GATE 1.11 FAILED: rpc_dashboard_kpi_summary ya no lee v_products_with_stock (drift detectado — requiere fix-forward).';
  END IF;

  RAISE NOTICE 'GATE 1.11 PASSED: get_dashboard_critical_stock y rpc_dashboard_kpi_summary siguen leyendo v_products_with_stock — auto-alineados con el nuevo min_stock derivado.';
END $$;
