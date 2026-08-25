-- =============================================================================
-- GATE: test_tenancy_rls_role.sql
-- CHANGE: v31-tenancy-pool-rls Paso 2 (tasks.md 7.3c, 7.4)
--
-- El grupo 7 (backend/core/database.py::get_db_conn, backend/tests/
-- test_database.py) prueba con MOCKS que, detrás de `tenancy_rls_role_enabled`,
-- get_db_conn emite `SET LOCAL ROLE authenticated` en el orden correcto. Un
-- mock no puede probar que ese cambio de rol REALMENTE activa la RLS contra
-- Postgres — eso sólo se prueba contra una base real. Este gate reproduce el
-- mecanismo exacto que get_db_conn usa (`set_config('request.jwt.claims', ...,
-- true)` + `SET LOCAL ROLE authenticated`, mismo patrón que
-- test_payment_methods_catalog.sql (6) y test_pagos_cableados_restantes.sql)
-- y verifica:
--
--   (1) estructura: products/cashboxes/sales tienen RLS activa (no depende
--       de datos).
--   (2)-(4) aislamiento por cuenta bajo RLS REAL en los tres dominios de
--       escritura que tasks.md 7.4 pide (productos, caja, ventas): una
--       cuenta A, autenticada como `authenticated` (NO como `postgres`, que
--       bypassea RLS), no ve una fila de la cuenta B por id — ni con el
--       patrón de query que los repositories ya usan (WHERE id=$1 AND
--       account_id=$2, que igual filtraría) NI omitiendo el filtro de
--       cuenta (WHERE id=$1 a secas, tasks.md 7.3c: "una consulta que omite
--       el filtro por cuenta no devuelve filas de otra cuenta") — en ambos
--       casos el resultado es 0 FILAS, nunca un "permission denied" crudo
--       (el GRANT de tabla para `authenticated` existe — verificado contra
--       prod, ver PR — así que lo que filtra es la policy, no el ACL).
--
-- Degrade-don't-fail: si el anchor sintético no puede resolver una cuenta, o
-- si el entorno de CI no replica el GRANT base de authenticated (mismo
-- criterio que test_payment_methods_catalog.sql (6) / test_analytics_events.sql
-- Gate 5), el gate emite NOTICE y no aborta. Sólo una fuga de datos real
-- (ver una fila de la otra cuenta) hace fallar el gate.
-- =============================================================================

-- ── (1) Estructura: RLS activa en los 3 dominios (no depende de datos) ───────
DO $$
DECLARE
  v_missing text := '';
  v_table   text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['products', 'cashboxes', 'sales'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = v_table AND c.relrowsecurity
    ) THEN
      v_missing := v_missing || v_table || ' ';
    END IF;
  END LOOP;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'GATE TENANCY-RLS-ROLE FAILED (1): tablas sin RLS activa: %', v_missing;
  END IF;

  RAISE NOTICE 'PASS (1): products, cashboxes y sales tienen RLS activa.';
END $$;


-- ── (2)-(4) Aislamiento por cuenta bajo RLS REAL — productos, caja, ventas ───
DO $$
DECLARE
  v_anchor_a_email text := 'tenancy-rls-role-gate-a@test.local';
  v_anchor_b_email text := 'tenancy-rls-role-gate-b@test.local';
  v_user_a         uuid := gen_random_uuid();
  v_user_b         uuid := gen_random_uuid();
  v_account_a      uuid;
  v_account_b      uuid;
  v_branch_a       uuid;
  v_branch_b       uuid;
  v_cashbox_a      uuid;
  v_cashbox_b      uuid;
  v_product_a      uuid;
  v_product_b      uuid;
  v_sale_a         uuid;
  v_sale_b         uuid;

  v_degraded       boolean := false;
  v_leak           boolean := false;
  v_own_count      integer;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_anchor_a_email, now(), now(),
          jsonb_build_object('name', 'Gate Tenancy RLS Role A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_anchor_b_email, now(), now(),
          jsonb_build_object('name', 'Gate Tenancy RLS Role B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE TENANCY-RLS-ROLE: no se pudo resolver cuenta para los anchors sintéticos — degradando sin abortar.';
    RETURN;
  END IF;

  -- branch/cashbox: sembrados solos por handle_new_user() (mismo patrón que
  -- test_delete_guard_ledgers.sql / test_payment_methods_catalog.sql).
  SELECT id INTO v_branch_a  FROM public.branches  WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b  FROM public.branches  WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_a FROM public.cashboxes WHERE branch_id  = v_branch_a  ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_b FROM public.cashboxes WHERE branch_id  = v_branch_b  ORDER BY created_at LIMIT 1;

  IF v_branch_a IS NULL OR v_branch_b IS NULL OR v_cashbox_a IS NULL OR v_cashbox_b IS NULL THEN
    RAISE NOTICE 'GATE TENANCY-RLS-ROLE: branch/cashbox no disponibles para los anchors — degradando sin abortar.';
    RETURN;
  END IF;

  -- Setup como postgres (bypassea RLS) — mismo patrón que el resto de los gates.
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_tenancy_rls_product_a__', 1000, 400, 'GATE-TRR-A')
  RETURNING id INTO v_product_a;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_b, v_account_b, '__gate_tenancy_rls_product_b__', 1000, 400, 'GATE-TRR-B')
  RETURNING id INTO v_product_b;

  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_a, v_account_a, v_branch_a, v_product_a, 1000, 1, 1000, now())
  RETURNING id INTO v_sale_a;
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_b, v_account_b, v_branch_b, v_product_b, 1000, 1, 1000, now())
  RETURNING id INTO v_sale_b;

  -- Impersonar A con RLS REAL activa (mismo mecanismo que get_db_conn con
  -- ambas palancas encendidas: claims con alcance transaccional + SET LOCAL
  -- ROLE authenticated — no como postgres, que bypassea RLS).
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    BEGIN
      -- Control positivo: A ve sus propias filas en los 3 dominios.
      SELECT count(*) INTO v_own_count FROM public.products WHERE id = v_product_a;
      IF v_own_count <> 1 THEN
        RAISE EXCEPTION 'GATE TENANCY-RLS-ROLE FAILED (control positivo productos): A no ve su propio producto bajo RLS real (%).', v_own_count;
      END IF;
      SELECT count(*) INTO v_own_count FROM public.cashboxes WHERE id = v_cashbox_a;
      IF v_own_count <> 1 THEN
        RAISE EXCEPTION 'GATE TENANCY-RLS-ROLE FAILED (control positivo caja): A no ve su propia cashbox bajo RLS real (%).', v_own_count;
      END IF;
      SELECT count(*) INTO v_own_count FROM public.sales WHERE id = v_sale_a;
      IF v_own_count <> 1 THEN
        RAISE EXCEPTION 'GATE TENANCY-RLS-ROLE FAILED (control positivo ventas): A no ve su propia venta bajo RLS real (%).', v_own_count;
      END IF;

      -- (2) Productos: id de B, con Y sin el filtro de cuenta que ya usa el
      -- repository — ambos SHALL dar 0 filas (7.3c + 7.4).
      IF EXISTS (SELECT 1 FROM public.products WHERE id = v_product_b AND account_id = v_account_a) THEN
        v_leak := true;
      END IF;
      IF EXISTS (SELECT 1 FROM public.products WHERE id = v_product_b) THEN
        v_leak := true;
      END IF;

      -- (3) Caja: id de la cashbox de B.
      IF EXISTS (SELECT 1 FROM public.cashboxes WHERE id = v_cashbox_b) THEN
        v_leak := true;
      END IF;

      -- (4) Ventas: id de la venta de B.
      IF EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_b AND account_id = v_account_a) THEN
        v_leak := true;
      END IF;
      IF EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_b) THEN
        v_leak := true;
      END IF;
    EXCEPTION
      WHEN insufficient_privilege THEN
        IF SQLERRM LIKE 'permission denied for table%' THEN
          -- Mismo criterio que test_payment_methods_catalog.sql (6): el
          -- entorno de CI no siempre replica el GRANT base de authenticated
          -- que trae prod — es un límite del ENTORNO, no una violación de
          -- RLS. Degradar sin fallar.
          v_degraded := true;
        ELSE
          RAISE;
        END IF;
    END;

    EXECUTE 'RESET ROLE';
  EXCEPTION
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      RAISE;
  END;

  IF v_degraded THEN
    RAISE NOTICE 'GATE TENANCY-RLS-ROLE degradado: el entorno no otorga el GRANT base de authenticated sobre products/cashboxes/sales (permission denied, no RLS) — omitido sin fallar.';
  ELSIF v_leak THEN
    RAISE EXCEPTION 'GATE TENANCY-RLS-ROLE FAILED: bajo RLS real (SET LOCAL ROLE authenticated), la cuenta A vio una fila de la cuenta B en productos, caja o ventas — aislamiento roto.';
  ELSE
    RAISE NOTICE 'PASS (2)-(4): aislamiento por cuenta verificado bajo RLS real (rol authenticated) en productos, caja y ventas — con y sin el filtro explícito de account_id, A no ve filas de B (7.3c + 7.4).';
  END IF;

  -- Cleanup hijo→padre (postgres bypassea RLS acá).
  DELETE FROM public.sales           WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.branch_stock    WHERE branch_id IN (v_branch_a, v_branch_b);
  DELETE FROM public.products        WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.cashboxes       WHERE branch_id IN (v_branch_a, v_branch_b);
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches        WHERE account_id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.accounts        WHERE owner_user_id IN (v_user_a, v_user_b);
  DELETE FROM public.profiles        WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs      WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users             WHERE id IN (v_user_a, v_user_b);

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
      DELETE FROM public.sales           WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.branch_stock    WHERE branch_id IN (v_branch_a, v_branch_b);
      DELETE FROM public.products        WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.cashboxes       WHERE branch_id IN (v_branch_a, v_branch_b);
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches        WHERE account_id IN (v_account_a, v_account_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_members WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.accounts        WHERE owner_user_id IN (v_user_a, v_user_b);
      DELETE FROM public.profiles        WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs      WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users             WHERE id IN (v_user_a, v_user_b);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
