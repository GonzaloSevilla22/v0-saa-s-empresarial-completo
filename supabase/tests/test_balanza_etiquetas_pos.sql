-- =============================================================================
-- test_balanza_etiquetas_pos.sql — Gate de comportamiento:
-- balanza-etiquetas-pos (governance MEDIA con tramos LOW).
--
-- Pedido del PO (2026-09-28): "quiero implementar integraciones con balanzas
-- porque me lo están pidiendo para una verdulería". La balanza etiquetadora
-- (Systel Cuora Neo) imprime un EAN-13 con el PLU del artículo; Aliadata lo
-- resuelve contra `products.scale_plu` con la configuración de
-- `scale_settings`.
--
-- Verifica 20261066000001_balanza_etiquetas_pos.sql:
--
--   (0) Introspección: products.scale_plu integer NULL; CHECK
--       products_scale_plu_range (1..999999) y products_scale_plu_not_parent;
--       índice único parcial idx_products_scale_plu_account_unique ON
--       (account_id, scale_plu) WHERE scale_plu IS NOT NULL AND deleted_at IS
--       NULL; scale_plu ÚLTIMA columna de v_products_with_stock (que conserva
--       security_invoker); scale_settings con RLS activa, 3 políticas (SELECT/
--       INSERT/UPDATE, ninguna de DELETE), disparador de guard owner/admin cuya
--       función NO es ejecutable por PUBLIC/anon/authenticated, anon sin
--       privilegios sobre la tabla; rpc_bulk_upsert_products con UNA sola
--       definición, SECURITY DEFINER, sin EXECUTE para authenticated/anon, con
--       `scale_plu` y `CONSTRAINT_NAME` en el cuerpo y su COMMENT vivo.
--   (a) unicidad por cuenta: PLU duplicado en la cuenta → 23505 del índice;
--       en otra cuenta pasa; un producto soft-deleted libera su PLU.
--   (b) CHECK de rango: 0 y 1.000.000 → 23514 products_scale_plu_range.
--   (b') CHECK products_scale_plu_not_parent: PLU a un variant_only, y pasar a
--       variant_only un producto con PLU → 23514; el producto no cambia.
--   (c) la vista expone scale_plu como última columna y con el valor real.
--   (d) scale_settings: CHECK de forma de layouts; seller no inserta ni
--       actualiza (P0401); owner sí; miembro de otra cuenta no ve la fila ni
--       puede escribirla; no hay DELETE (la fila sobrevive a un DELETE del
--       owner); anon sin privilegios.
--   (e) EJECUTA rpc_import_products como un owner real (SET LOCAL ROLE
--       authenticated + claims): asigna PLU; celda ausente o vacía conserva;
--       un PLU de otro producto rechaza el lote sin escritura parcial con el
--       error en su fila y el mensaje nombra el código (509); una fila
--       "Padre" (variant_only) con PLU da error de fila.
--   (z) Limpieza verificada: cero filas del fixture en toda tabla de public
--       con account_id, cuentas, usuarios, profiles y billing_events.
--
-- Patrón del proyecto: fallos acumulados en text[], un RAISE EXCEPTION por
-- bloque, anchors vía handle_new_user, fixture en su propio bloque con
-- limpieza asertada.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

-- ── (0) Introspección ────────────────────────────────────────────────────────
DO $$
DECLARE
  v_failures text[] := '{}';
  v_type     text;
  v_notnull  boolean;
  v_last_col text;
  v_indexdef text;
  v_oid      oid;
  v_count    integer;
  v_secdef   boolean;
  v_def      text;
  v_comment  text;
  v_policies text;
BEGIN
  -- Columna
  SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull
  INTO   v_type, v_notnull
  FROM   pg_attribute a
  WHERE  a.attrelid = 'public.products'::regclass
    AND  a.attname = 'scale_plu' AND NOT a.attisdropped;
  IF v_type IS NULL THEN
    v_failures := v_failures || 'products.scale_plu no existe'::text;
  ELSIF v_type <> 'integer' OR v_notnull THEN
    v_failures := v_failures || format('products.scale_plu debía ser integer NULL; es %s notnull=%s', v_type, v_notnull);
  END IF;

  -- CHECKs
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.products'::regclass AND conname = 'products_scale_plu_range' AND contype = 'c'
      AND  pg_get_constraintdef(oid) ILIKE '%scale_plu%1%999999%'
  ) THEN
    v_failures := v_failures || 'falta el CHECK products_scale_plu_range (scale_plu entre 1 y 999999)'::text;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.products'::regclass AND conname = 'products_scale_plu_not_parent' AND contype = 'c'
      AND  pg_get_constraintdef(oid) ILIKE '%scale_plu IS NULL%variant_only%'
  ) THEN
    v_failures := v_failures || 'falta el CHECK products_scale_plu_not_parent (scale_plu IS NULL OR stock_control_type IS DISTINCT FROM variant_only)'::text;
  END IF;

  -- Índice único parcial
  SELECT pg_get_indexdef(i.indexrelid) INTO v_indexdef
  FROM   pg_index i JOIN pg_class c ON c.oid = i.indexrelid
  WHERE  i.indrelid = 'public.products'::regclass
    AND  c.relname = 'idx_products_scale_plu_account_unique' AND i.indisunique;
  IF v_indexdef IS NULL THEN
    v_failures := v_failures || 'falta el índice único idx_products_scale_plu_account_unique'::text;
  ELSIF v_indexdef NOT ILIKE '%(account_id, scale_plu)%'
     OR v_indexdef NOT ILIKE '%scale_plu IS NOT NULL%'
     OR v_indexdef NOT ILIKE '%deleted_at IS NULL%' THEN
    v_failures := v_failures || format('idx_products_scale_plu_account_unique debía ser (account_id, scale_plu) WHERE scale_plu IS NOT NULL AND deleted_at IS NULL; es %s', v_indexdef);
  END IF;

  -- Vista: scale_plu última columna + security_invoker
  SELECT column_name INTO v_last_col
  FROM   information_schema.columns
  WHERE  table_schema = 'public' AND table_name = 'v_products_with_stock'
  ORDER  BY ordinal_position DESC LIMIT 1;
  IF v_last_col IS DISTINCT FROM 'scale_plu' THEN
    v_failures := v_failures || format('la última columna de v_products_with_stock debía ser scale_plu; es %s', COALESCE(v_last_col, '<ninguna>'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_class
    WHERE oid = 'public.v_products_with_stock'::regclass
      AND reloptions @> ARRAY['security_invoker=true']
  ) THEN
    v_failures := v_failures || 'v_products_with_stock perdió security_invoker'::text;
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.v_products_with_stock', 'SELECT') THEN
    v_failures := v_failures || 'v_products_with_stock: authenticated perdió SELECT'::text;
  END IF;

  -- scale_settings
  IF to_regclass('public.scale_settings') IS NULL THEN
    v_failures := v_failures || 'la tabla public.scale_settings no existe'::text;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.scale_settings'::regclass AND relrowsecurity) THEN
      v_failures := v_failures || 'scale_settings sin RLS activa'::text;
    END IF;
    SELECT count(*), string_agg(cmd, ',' ORDER BY cmd) INTO v_count, v_policies
    FROM   pg_policies WHERE schemaname = 'public' AND tablename = 'scale_settings';
    IF v_count <> 3 OR v_policies <> 'INSERT,SELECT,UPDATE' THEN
      v_failures := v_failures || format('scale_settings debía tener 3 políticas (INSERT,SELECT,UPDATE, sin DELETE); tiene %s: %s', v_count, COALESCE(v_policies, '<ninguna>'));
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.scale_settings'::regclass
        AND tgname = 'trg_scale_settings_guard_owner_admin' AND NOT tgisinternal
    ) THEN
      v_failures := v_failures || 'falta el disparador trg_scale_settings_guard_owner_admin'::text;
    END IF;
    IF to_regprocedure('public.scale_settings_guard_owner_admin()') IS NULL THEN
      v_failures := v_failures || 'falta la función public.scale_settings_guard_owner_admin()'::text;
    ELSIF has_function_privilege('anon', 'public.scale_settings_guard_owner_admin()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.scale_settings_guard_owner_admin()', 'EXECUTE')
       OR has_function_privilege('public', 'public.scale_settings_guard_owner_admin()', 'EXECUTE') THEN
      v_failures := v_failures || 'scale_settings_guard_owner_admin() es función trigger SECURITY DEFINER y no debe ser EXECUTE para PUBLIC/anon/authenticated'::text;
    END IF;
    IF has_table_privilege('anon', 'public.scale_settings', 'SELECT')
       OR has_table_privilege('anon', 'public.scale_settings', 'INSERT')
       OR has_table_privilege('anon', 'public.scale_settings', 'UPDATE')
       OR has_table_privilege('anon', 'public.scale_settings', 'DELETE') THEN
      v_failures := v_failures || 'anon conserva privilegios sobre scale_settings'::text;
    END IF;
  END IF;

  -- rpc_bulk_upsert_products
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_bulk_upsert_products';
  IF v_count <> 1 THEN
    v_failures := v_failures || format('rpc_bulk_upsert_products: se esperaba UNA definición y hay %s', v_count);
  END IF;
  v_oid := to_regprocedure('public.rpc_bulk_upsert_products(jsonb, uuid)');
  IF v_oid IS NULL THEN
    v_failures := v_failures || 'rpc_bulk_upsert_products(jsonb, uuid) no resuelve'::text;
  ELSE
    SELECT prosecdef INTO v_secdef FROM pg_proc WHERE oid = v_oid;
    IF NOT v_secdef THEN
      v_failures := v_failures || 'rpc_bulk_upsert_products dejó de ser SECURITY DEFINER'::text;
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR has_function_privilege('public', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || 'rpc_bulk_upsert_products volvió a ser ejecutable por authenticated/anon/PUBLIC (sólo vía rpc_import_products)'::text;
    END IF;
    v_def := replace(pg_get_functiondef(v_oid), E'\r', '');
    IF v_def NOT LIKE '%scale_plu%' THEN
      v_failures := v_failures || 'rpc_bulk_upsert_products no persiste scale_plu'::text;
    END IF;
    IF v_def NOT LIKE '%CONSTRAINT_NAME%' THEN
      v_failures := v_failures || 'rpc_bulk_upsert_products no lee CONSTRAINT_NAME en la rama de error por fila'::text;
    END IF;
    v_comment := obj_description(v_oid, 'pg_proc');
    IF v_comment IS NULL OR v_comment NOT LIKE 'Alta masiva de productos. Invocable SOLO desde rpc_import_products%' THEN
      v_failures := v_failures || format('rpc_bulk_upsert_products perdió su COMMENT vivo; es: %s', COALESCE(v_comment, '<NULL>'));
    END IF;
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE BALANZA-ETIQUETAS-POS (0) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (0): columna, 2 CHECK, índice único parcial, vista (última columna + security_invoker), scale_settings (RLS, 3 políticas, disparador, ACLs) y rpc_bulk_upsert_products (firma única, DEFINER, ACL, cuerpo, COMMENT).';
END $$;


-- ── (a)-(e) + (z) Comportamiento sobre datos ─────────────────────────────────
DO $$
DECLARE
  v_failures   text[] := '{}';
  v_owner_a    uuid := gen_random_uuid();
  v_owner_b    uuid := gen_random_uuid();
  v_seller     uuid := gen_random_uuid();
  v_users      uuid[];
  v_account_a  uuid;
  v_account_b  uuid;
  v_seller_own uuid;
  v_seller_mid uuid;
  v_accounts   uuid[];
  v_claims_a   text;
  v_claims_b   text;
  v_claims_s   text;

  v_p_a1       uuid;
  v_p_b1       uuid;
  v_p_a3       uuid;
  v_parent     uuid;
  v_with_plu   uuid;

  v_state      text;
  v_constraint text;
  v_int        integer;
  v_text       text;
  v_cnt        bigint;
  v_before     bigint;
  v_result     jsonb;
  v_tbl        text;
  v_layouts    jsonb := jsonb_build_array(
    jsonb_build_object('kind', 'weighed', 'enabled', true, 'segments', jsonb_build_array(
      jsonb_build_object('field', 'fixed',  'digits', 2, 'value', '20'),
      jsonb_build_object('field', 'plu',    'digits', 4),
      jsonb_build_object('field', 'amount', 'digits', 6, 'decimals', 2))),
    jsonb_build_object('kind', 'unit', 'enabled', true, 'segments', jsonb_build_array(
      jsonb_build_object('field', 'fixed',  'digits', 2, 'value', '21'),
      jsonb_build_object('field', 'plu',    'digits', 4),
      jsonb_build_object('field', 'amount', 'digits', 6, 'decimals', 2))),
    jsonb_build_object('kind', 'multi', 'enabled', false, 'segments', jsonb_build_array(
      jsonb_build_object('field', 'fixed',   'digits', 2, 'value', '22'),
      jsonb_build_object('field', 'ignored', 'digits', 2),
      jsonb_build_object('field', 'ignored', 'digits', 8)))
  );
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v_owner_a, 'authenticated', 'authenticated', 'balanza-gate-owner-a@test.local', now(), now(),
     jsonb_build_object('name', 'Gate Balanza Owner A', 'phone', '', 'locality', '', 'province', '')),
    (v_owner_b, 'authenticated', 'authenticated', 'balanza-gate-owner-b@test.local', now(), now(),
     jsonb_build_object('name', 'Gate Balanza Owner B', 'phone', '', 'locality', '', 'province', '')),
    (v_seller, 'authenticated', 'authenticated', 'balanza-gate-seller@test.local', now(), now(),
     jsonb_build_object('name', 'Gate Balanza Seller', 'phone', '', 'locality', '', 'province', ''));
  v_users := ARRAY[v_owner_a, v_owner_b, v_seller];

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_seller_own FROM public.account_members WHERE user_id = v_seller ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL OR v_seller_own IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no resolvió las cuentas del fixture';
  END IF;
  v_accounts := ARRAY[v_account_a, v_account_b, v_seller_own];

  -- El seller es miembro de la cuenta A con rol 'seller' únicamente (escritor
  -- para is_account_writer, pero no owner/admin).
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_seller_mid;
  INSERT INTO public.account_member_roles (account_id, member_id, role)
  VALUES (v_account_a, v_seller_mid, 'seller');

  v_claims_a := json_build_object('sub', v_owner_a::text, 'role', 'authenticated')::text;
  v_claims_b := json_build_object('sub', v_owner_b::text, 'role', 'authenticated')::text;
  v_claims_s := json_build_object('sub', v_seller::text,  'role', 'authenticated')::text;

  -- ═══ (a) Unicidad por cuenta, filas vivas ═══
  INSERT INTO public.products (user_id, account_id, name, price, cost, min_stock, scale_plu)
  VALUES (v_owner_a, v_account_a, 'Gate Balanza Tomate', 10, 5, 0, 509) RETURNING id INTO v_p_a1;

  BEGIN
    INSERT INTO public.products (user_id, account_id, name, price, cost, min_stock, scale_plu)
    VALUES (v_owner_a, v_account_a, 'Gate Balanza Tomate bis', 10, 5, 0, 509);
    v_state := 'ok';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    v_state := '23505';
  END;
  IF v_state <> '23505' OR v_constraint IS DISTINCT FROM 'idx_products_scale_plu_account_unique' THEN
    v_failures := v_failures || format('(a) PLU duplicado en la cuenta debía fallar por idx_products_scale_plu_account_unique; got %s / %s', v_state, v_constraint);
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, min_stock, scale_plu)
  VALUES (v_owner_b, v_account_b, 'Gate Balanza Tomate B', 10, 5, 0, 509) RETURNING id INTO v_p_b1;
  IF v_p_b1 IS NULL THEN
    v_failures := v_failures || '(a) el mismo PLU en otra cuenta debía coexistir'::text;
  END IF;

  UPDATE public.products SET deleted_at = now(), deleted_by = v_owner_a WHERE id = v_p_a1;
  BEGIN
    INSERT INTO public.products (user_id, account_id, name, price, cost, min_stock, scale_plu)
    VALUES (v_owner_a, v_account_a, 'Gate Balanza Tomate nuevo', 12, 6, 0, 509) RETURNING id INTO v_p_a3;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('(a) reutilizar el PLU de un producto soft-deleted debía permitirse; got %s %s', SQLSTATE, SQLERRM);
  END;

  -- ═══ (b) CHECK de rango ═══
  FOREACH v_int IN ARRAY ARRAY[0, 1000000] LOOP
    v_constraint := NULL;
    BEGIN
      INSERT INTO public.products (user_id, account_id, name, price, cost, min_stock, scale_plu)
      VALUES (v_owner_a, v_account_a, 'Gate Balanza rango', 10, 5, 0, v_int);
      v_state := 'ok';
    EXCEPTION WHEN check_violation THEN
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
      v_state := '23514';
    END;
    IF v_state <> '23514' OR v_constraint IS DISTINCT FROM 'products_scale_plu_range' THEN
      v_failures := v_failures || format('(b) scale_plu=%s debía fallar por products_scale_plu_range; got %s / %s', v_int, v_state, v_constraint);
    END IF;
  END LOOP;

  -- ═══ (b') CHECK products_scale_plu_not_parent ═══
  INSERT INTO public.products (user_id, account_id, name, price, cost, min_stock, stock_control_type)
  VALUES (v_owner_a, v_account_a, 'Gate Balanza Padre', 0, NULL, 0, 'variant_only') RETURNING id INTO v_parent;
  v_constraint := NULL;
  BEGIN
    UPDATE public.products SET scale_plu = 700 WHERE id = v_parent;
    v_state := 'ok';
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    v_state := '23514';
  END;
  IF v_state <> '23514' OR v_constraint IS DISTINCT FROM 'products_scale_plu_not_parent' THEN
    v_failures := v_failures || format('(b'') PLU a un variant_only debía fallar por products_scale_plu_not_parent; got %s / %s', v_state, v_constraint);
  END IF;
  IF (SELECT scale_plu FROM public.products WHERE id = v_parent) IS NOT NULL THEN
    v_failures := v_failures || '(b'') el padre quedó con PLU a pesar del rechazo'::text;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, min_stock, scale_plu)
  VALUES (v_owner_a, v_account_a, 'Gate Balanza con PLU', 10, 5, 0, 701) RETURNING id INTO v_with_plu;
  v_constraint := NULL;
  BEGIN
    UPDATE public.products SET stock_control_type = 'variant_only' WHERE id = v_with_plu;
    v_state := 'ok';
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    v_state := '23514';
  END;
  IF v_state <> '23514' OR v_constraint IS DISTINCT FROM 'products_scale_plu_not_parent' THEN
    v_failures := v_failures || format('(b'') pasar a variant_only un producto con PLU debía fallar por products_scale_plu_not_parent; got %s / %s', v_state, v_constraint);
  END IF;
  IF (SELECT stock_control_type FROM public.products WHERE id = v_with_plu) = 'variant_only' THEN
    v_failures := v_failures || '(b'') el producto con PLU quedó variant_only a pesar del rechazo'::text;
  END IF;

  -- ═══ (c) La vista expone el valor ═══
  SELECT scale_plu INTO v_int FROM public.v_products_with_stock WHERE id = v_p_a3;
  IF v_int IS DISTINCT FROM 509 THEN
    v_failures := v_failures || format('(c) v_products_with_stock.scale_plu debía ser 509; got %s', v_int);
  END IF;

  -- ═══ (d) scale_settings ═══
  -- (d0) CHECK de forma de layouts. El disparador de guard corre ANTES que el
  --      CHECK (y como postgres no hay auth.uid()): se aÃ­sla el CHECK con
  --      session_replication_role = replica, que saltea triggers pero NUNCA
  --      constraints.
  SET session_replication_role = replica;
  BEGIN
    INSERT INTO public.scale_settings (account_id, enabled, layouts) VALUES (v_account_b, false, '{}'::jsonb);
    v_state := 'ok';
  EXCEPTION WHEN check_violation THEN
    v_state := '23514';
  END;
  SET session_replication_role = DEFAULT;
  IF v_state <> '23514' THEN
    v_failures := v_failures || format('(d0) layouts que no es un array de 3 debía fallar el CHECK; got %s', v_state);
  END IF;

  -- (d1) seller no inserta
  PERFORM set_config('request.jwt.claims', v_claims_s, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO public.scale_settings (account_id, enabled, layouts) VALUES (v_account_a, true, v_layouts);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_state <> 'P0401' THEN
    v_failures := v_failures || format('(d1) INSERT por un seller debía rechazarse con P0401; got %s', v_state);
  END IF;

  -- (d2) owner inserta y actualiza
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO public.scale_settings (account_id, enabled, layouts, updated_by) VALUES (v_account_a, false, v_layouts, v_owner_a);
    UPDATE public.scale_settings SET enabled = true, updated_at = now() WHERE account_id = v_account_a;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(d2) el owner debía poder insertar y actualizar; got %s', v_state);
  ELSIF NOT EXISTS (SELECT 1 FROM public.scale_settings WHERE account_id = v_account_a AND enabled) THEN
    v_failures := v_failures || '(d2) la fila del owner no quedó habilitada'::text;
  END IF;

  -- (d3) seller no actualiza
  PERFORM set_config('request.jwt.claims', v_claims_s, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    UPDATE public.scale_settings SET enabled = false WHERE account_id = v_account_a;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_state <> 'P0401' THEN
    v_failures := v_failures || format('(d3) UPDATE por un seller debía rechazarse con P0401; got %s', v_state);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.scale_settings WHERE account_id = v_account_a AND enabled) THEN
    v_failures := v_failures || '(d3) el UPDATE del seller cambió la fila a pesar del rechazo'::text;
  END IF;

  -- (d4) miembro de otra cuenta: no ve la fila, no la escribe
  PERFORM set_config('request.jwt.claims', v_claims_b, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_cnt FROM public.scale_settings WHERE account_id = v_account_a;
  BEGIN
    UPDATE public.scale_settings SET enabled = false WHERE account_id = v_account_a;
    GET DIAGNOSTICS v_int = ROW_COUNT;
    v_state := 'ok:' || v_int;
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  BEGIN
    INSERT INTO public.scale_settings (account_id, enabled, layouts) VALUES (v_account_a, false, v_layouts);
    v_text := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_text := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_cnt <> 0 THEN
    v_failures := v_failures || format('(d4) la cuenta B ve %s fila(s) de scale_settings de la cuenta A', v_cnt);
  END IF;
  IF v_state NOT IN ('ok:0', '42501', 'P0401') THEN
    v_failures := v_failures || format('(d4) la cuenta B no debía poder actualizar la fila de A; got %s', v_state);
  END IF;
  IF v_text = 'ok' THEN
    v_failures := v_failures || '(d4) la cuenta B pudo insertar configuración en la cuenta A'::text;
  END IF;

  -- (d5) sin DELETE: la fila sobrevive a un DELETE del owner
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    DELETE FROM public.scale_settings WHERE account_id = v_account_a;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT EXISTS (SELECT 1 FROM public.scale_settings WHERE account_id = v_account_a) THEN
    v_failures := v_failures || '(d5) el owner pudo borrar la fila de scale_settings (no hay política de DELETE)'::text;
  END IF;

  -- ═══ (e) rpc_import_products como owner real ═══
  -- (e1) asigna PLU a un producto nuevo
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_result := public.rpc_import_products(
    'gate-balanza-e1-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Balanza Zanahoria', 'sku', 'GATE-BAL-ZAN', 'price', 480, 'scale_plu', 261)),
    'gate-balanza-e1.csv', 'gate-balanza-e1-' || gen_random_uuid()::text);
  EXECUTE 'RESET ROLE';
  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    v_failures := v_failures || format('(e1) el import con PLU debía confirmarse; got %s', v_result);
  ELSIF (SELECT scale_plu FROM public.products WHERE account_id = v_account_a AND sku = 'GATE-BAL-ZAN' AND deleted_at IS NULL) IS DISTINCT FROM 261 THEN
    v_failures := v_failures || '(e1) el producto importado no quedó con scale_plu = 261'::text;
  END IF;

  -- (e2) celda ausente y celda vacía conservan
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_result := public.rpc_import_products(
    'gate-balanza-e2-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Balanza Zanahoria', 'sku', 'GATE-BAL-ZAN', 'price', 500)),
    'gate-balanza-e2.csv', 'gate-balanza-e2-' || gen_random_uuid()::text);
  v_text := v_result::text;
  v_result := public.rpc_import_products(
    'gate-balanza-e2b-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Balanza Zanahoria', 'sku', 'GATE-BAL-ZAN', 'price', 520, 'scale_plu', '')),
    'gate-balanza-e2b.csv', 'gate-balanza-e2b-' || gen_random_uuid()::text);
  EXECUTE 'RESET ROLE';
  IF (v_text::jsonb->>'committed')::boolean IS DISTINCT FROM true OR (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    v_failures := v_failures || format('(e2) los imports sin PLU debían confirmarse; got %s / %s', v_text, v_result);
  ELSIF (SELECT scale_plu FROM public.products WHERE account_id = v_account_a AND sku = 'GATE-BAL-ZAN' AND deleted_at IS NULL) IS DISTINCT FROM 261
     OR (SELECT price FROM public.products WHERE account_id = v_account_a AND sku = 'GATE-BAL-ZAN' AND deleted_at IS NULL) IS DISTINCT FROM 520 THEN
    v_failures := v_failures || '(e2) celda ausente/vacía debía conservar scale_plu = 261 (y actualizar el precio a 520)'::text;
  END IF;

  -- (e3) PLU de otro producto → lote rechazado sin escritura parcial,
  --      error en su fila con el código en el mensaje
  -- El PLU 509 lo usa el producto vivo v_p_a3 ("Tomate nuevo") de la cuenta A.
  SELECT count(*) INTO v_before FROM public.products WHERE account_id = v_account_a;
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_result := public.rpc_import_products(
    'gate-balanza-e3-' || gen_random_uuid()::text,
    jsonb_build_array(
      jsonb_build_object('row_no', 1, 'name', 'Gate Balanza Batata', 'sku', 'GATE-BAL-BAT', 'price', 300),
      jsonb_build_object('row_no', 2, 'name', 'Gate Balanza Cebolla', 'sku', 'GATE-BAL-CEB', 'price', 200, 'scale_plu', 509)),
    'gate-balanza-e3.csv', 'gate-balanza-e3-' || gen_random_uuid()::text);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_cnt FROM public.products WHERE account_id = v_account_a;
  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    v_failures := v_failures || format('(e3) un PLU ajeno debía rechazar el lote; got %s', v_result);
  ELSIF jsonb_array_length(v_result->'errors') <> 1
     OR (v_result->'errors'->0->>'row')::int IS DISTINCT FROM 2
     OR position('509' in COALESCE(v_result->'errors'->0->>'message', '')) = 0 THEN
    v_failures := v_failures || format('(e3) el error debía venir en la fila 2 y nombrar el código 509; got %s', v_result->'errors');
  END IF;
  IF v_cnt <> v_before THEN
    v_failures := v_failures || format('(e3) el lote rechazado dejó escritura parcial: products %s -> %s', v_before, v_cnt);
  END IF;

  -- (e4) fila "Padre" (variant_only) con PLU → error de fila
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_result := public.rpc_import_products(
    'gate-balanza-e4-' || gen_random_uuid()::text,
    jsonb_build_array(
      jsonb_build_object('row_no', 1, 'name', 'Gate Balanza Padre Import', 'sku', 'GATE-BAL-PADRE', 'is_variant', false,
                         'stock_control_type', 'variant_only', 'scale_plu', 262)),
    'gate-balanza-e4.csv', 'gate-balanza-e4-' || gen_random_uuid()::text);
  EXECUTE 'RESET ROLE';
  IF (v_result->>'committed')::boolean IS DISTINCT FROM false
     OR jsonb_array_length(v_result->'errors') <> 1
     OR (v_result->'errors'->0->>'row')::int IS DISTINCT FROM 1
     OR position('variante' in COALESCE(v_result->'errors'->0->>'message', '')) = 0 THEN
    v_failures := v_failures || format('(e4) una fila Padre con PLU debía dar error de fila (mensaje sobre las variantes); got %s', v_result);
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE account_id = v_account_a AND sku = 'GATE-BAL-PADRE') THEN
    v_failures := v_failures || '(e4) la fila Padre con PLU quedó escrita'::text;
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE BALANZA-ETIQUETAS-POS (a-e) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (a-e): unicidad por cuenta, rango, padre, vista, scale_settings (seller P0401, owner ok, otra cuenta ciega, sin DELETE) y rpc_import_products (asigna, conserva, rechaza PLU ajeno y fila Padre con el código en el mensaje).';

  -- ═══ (z) Limpieza asertada ═══
  DELETE FROM public.billing_events WHERE user_id = ANY(v_users);
  DELETE FROM public.email_logs     WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  FOR v_tbl IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables t
      ON   t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY($1)', v_tbl) USING v_accounts;
  END LOOP;
  DELETE FROM public.product_attributes WHERE user_id = ANY(v_users);
  DELETE FROM public.accounts WHERE id = ANY(v_accounts);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  DELETE FROM public.profiles        WHERE id = ANY(v_users);
  DELETE FROM auth.users             WHERE id = ANY(v_users);
  -- El cascade desde auth.users dispara auditoría: segunda pasada.
  SET session_replication_role = replica;
  FOR v_tbl IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables t
      ON   t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY($1)', v_tbl) USING v_accounts;
  END LOOP;
  SET session_replication_role = DEFAULT;

  v_failures := '{}';
  FOR v_tbl IN
    SELECT DISTINCT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables t
      ON   t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE account_id = ANY($1)', v_tbl) INTO v_cnt USING v_accounts;
    IF v_cnt <> 0 THEN
      v_failures := v_failures || format('(z) residuo: %s fila(s) del fixture en %s', v_cnt, v_tbl);
    END IF;
  END LOOP;
  SELECT count(*) INTO v_cnt FROM public.accounts WHERE id = ANY(v_accounts);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(z) residuo: %s cuenta(s) del fixture', v_cnt); END IF;
  SELECT count(*) INTO v_cnt FROM auth.users WHERE id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(z) residuo: %s usuario(s) del fixture', v_cnt); END IF;
  SELECT count(*) INTO v_cnt FROM public.profiles WHERE id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(z) residuo: %s profiles del fixture', v_cnt); END IF;
  SELECT count(*) INTO v_cnt FROM public.billing_events WHERE user_id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(z) residuo: %s billing_events del fixture', v_cnt); END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE BALANZA-ETIQUETAS-POS (z) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (z): limpieza verificada — cero filas del fixture en toda tabla de public con account_id.';

EXCEPTION
  WHEN OTHERS THEN
    -- El bloque se revierte entero al propagar el error: el fixture no
    -- persiste. Sólo hay que devolver el rol.
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- GATE BALANZA-ETIQUETAS-POS PASSED (2 bloques: introspección + a-e/z).
-- =============================================================================
