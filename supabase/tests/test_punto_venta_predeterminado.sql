-- =============================================================================
-- test_punto_venta_predeterminado.sql — Gate de comportamiento:
-- punto-venta-seleccion (governance MEDIA, dominio fiscal).
--
-- Pedido del PO (2026-09-25): "quiero que en la venta se pueda elegir el punto
-- de venta o al facturar, por si tienen más de 1". Medido en prod: 2 de 2
-- cuentas con puntos de venta tienen DOS activos (3 y 9999), así que facturar
-- una venta del POS desde /ventas/ordenes (que manda point_of_sale_id NULL con
-- varios activos) fallaba SIEMPRE con P0422 ambiguous_point_of_sale.
--
-- Verifica 20261063000001_punto_venta_predeterminado.sql:
--
--   (0) Introspección: points_of_sale.is_default boolean NOT NULL DEFAULT
--       false; CHECK points_of_sale_default_is_active (NOT is_default OR
--       is_active); índice ÚNICO PARCIAL points_of_sale_one_default_per_account
--       ON (account_id) WHERE is_default; rpc_emit_pending_cae con UNA sola
--       definición, SECURITY DEFINER, ACLs exactas (authenticated y
--       service_role CON EXECUTE, anon y PUBLIC SIN) y el COMMENT vivo
--       conservado (R4) + la línea de este change; md5 (sin CR) de
--       rpc_emit_subscription_payment_cae IGUAL al vivo de prod medido antes
--       de escribir la migración (D5: la facturación de suscripciones NO se
--       toca — si una migración futura la reescribe a propósito, actualizar
--       este md5 en el mismo PR).
--   Ejecuta rpc_emit_pending_cae como un owner real (SET LOCAL ROLE
--   authenticated + request.jwt.claims):
--   (a) 1 PV activo, sin PV explícito → usa ese.
--   (b) 2 activos sin predeterminado, sin explícito → P0422, sin reservar
--       número (document_sequences intacta) y sin comprobante nuevo.
--   (c) 2 activos con el 9999 predeterminado, sin explícito → pending_cae por
--       el 9999 (point_of_sale_id y punto_de_venta).
--   (d) explícito (3) ≠ predeterminado (9999) → gana el explícito.
--   (e) explícito INACTIVO con predeterminado vivo → P0404, nunca el
--       predeterminado en silencio.
--   (e2) tenencia: el predeterminado de OTRA cuenta no resuelve la
--       ambigüedad de ésta (P0422).
--   (f) índice único: un segundo predeterminado en la misma cuenta falla
--       (23505); en otra cuenta pasa.
--   (g) CHECK: marcar un PV inactivo como predeterminado falla (23514), y
--       desactivar el predeterminado SIN limpiar la marca también (23514);
--       desactivar limpiando la marca en la misma sentencia pasa.
--   (h) rpc_emit_subscription_payment_cae con 2 activos + predeterminado y sin
--       explícito sigue dando P0422 (D5); control positivo con PV explícito.
--   (z) Limpieza verificada: cero filas del fixture en toda tabla de public
--       con account_id.
--
-- Patrón del proyecto: fallos acumulados en text[], un RAISE EXCEPTION por
-- bloque, anchors vía handle_new_user, limpieza en el camino feliz y en el
-- EXCEPTION.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

-- ── (0) Introspección ────────────────────────────────────────────────────────
DO $$
DECLARE
  v_failures text[] := '{}';
  v_sig CONSTANT text :=
    'public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)';
  v_sub_sig CONSTANT text :=
    'public.rpc_emit_subscription_payment_cae(text, uuid, integer, text)';
  -- md5 de pg_get_functiondef VIVO de prod (sin \r), medido 2026-09-26 antes
  -- de escribir la migración. D5: la facturación de suscripciones no cambia.
  v_sub_md5 CONSTANT text := 'a74f516057f5346fe88d8ba026f918d8';
  v_oid      oid;
  v_count    integer;
  v_secdef   boolean;
  v_type     text;
  v_notnull  boolean;
  v_default  text;
  v_def      text;
  v_comment  text;
BEGIN
  -- Columna
  SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
  INTO   v_type, v_notnull, v_default
  FROM   pg_attribute a
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE  a.attrelid = 'public.points_of_sale'::regclass
    AND  a.attname = 'is_default' AND NOT a.attisdropped;

  IF v_type IS NULL THEN
    v_failures := v_failures || 'points_of_sale.is_default no existe'::text;
  ELSIF v_type <> 'boolean' OR NOT v_notnull OR v_default IS DISTINCT FROM 'false' THEN
    v_failures := v_failures || format('points_of_sale.is_default debía ser boolean NOT NULL DEFAULT false; es %s notnull=%s default=%s',
                                       v_type, v_notnull, COALESCE(v_default, '<NULL>'));
  END IF;

  -- CHECK
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.points_of_sale'::regclass
      AND  conname  = 'points_of_sale_default_is_active'
      AND  contype  = 'c'
      AND  pg_get_constraintdef(oid) ILIKE '%NOT is_default%OR is_active%'
  ) THEN
    v_failures := v_failures || 'falta el CHECK points_of_sale_default_is_active (NOT is_default OR is_active)'::text;
  END IF;

  -- Índice único parcial
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_index i
    JOIN   pg_class c ON c.oid = i.indexrelid
    WHERE  i.indrelid = 'public.points_of_sale'::regclass
      AND  c.relname  = 'points_of_sale_one_default_per_account'
      AND  i.indisunique
      AND  pg_get_indexdef(i.indexrelid) ILIKE '%(account_id)%WHERE is_default%'
  ) THEN
    v_failures := v_failures || 'falta el índice único parcial points_of_sale_one_default_per_account ON (account_id) WHERE is_default'::text;
  END IF;

  -- RPC de ventas: una sola definición, DEFINER, ACLs, COMMENT
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_emit_pending_cae';
  IF v_count <> 1 THEN
    v_failures := v_failures || format('rpc_emit_pending_cae: se esperaba UNA definición y hay %s (overload 42725)', v_count);
  END IF;

  v_oid := to_regprocedure(v_sig);
  IF v_oid IS NULL THEN
    v_failures := v_failures || format('%s no resuelve — la firma cambió', v_sig);
  ELSE
    SELECT prosecdef INTO v_secdef FROM pg_proc WHERE oid = v_oid;
    IF NOT v_secdef THEN
      v_failures := v_failures || 'rpc_emit_pending_cae dejó de ser SECURITY DEFINER'::text;
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || 'rpc_emit_pending_cae SIN EXECUTE para authenticated (es RPC de usuario)'::text;
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || 'rpc_emit_pending_cae SIN EXECUTE para service_role'::text;
    END IF;
    IF has_function_privilege('public', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || 'rpc_emit_pending_cae ejecutable por PUBLIC'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || 'rpc_emit_pending_cae ejecutable por anon'::text;
    END IF;

    v_def := replace(pg_get_functiondef(v_oid), E'\r', '');
    IF v_def NOT LIKE '%is_default%' THEN
      v_failures := v_failures || 'rpc_emit_pending_cae no contiene la rama del predeterminado (is_default)'::text;
    END IF;
    -- El resto de la resolución D11 sigue intacto.
    IF v_def NOT LIKE '%point_of_sale_not_found_or_inactive%'
       OR v_def NOT LIKE '%no_active_point_of_sale%'
       OR v_def NOT LIKE '%ambiguous_point_of_sale%' THEN
      v_failures := v_failures || 'rpc_emit_pending_cae perdió alguno de los tres rechazos de la resolución D11'::text;
    END IF;
    -- R4 (fiscal-riesgos-residuales) sigue vivo.
    IF v_def NOT LIKE '%client_not_found%' THEN
      v_failures := v_failures || 'rpc_emit_pending_cae perdió el guard de tenencia del cliente (R4)'::text;
    END IF;

    v_comment := obj_description(v_oid, 'pg_proc');
    IF v_comment IS NULL
       OR v_comment NOT LIKE '%fiscal-riesgos-residuales (R4)%'
       OR v_comment NOT LIKE '%punto-venta-seleccion%' THEN
      v_failures := v_failures || format('COMMENT de rpc_emit_pending_cae: debía conservar el vivo (R4) y sumar punto-venta-seleccion; es: %s',
                                         COALESCE(v_comment, '<NULL>'));
    END IF;
  END IF;

  -- RPC de suscripciones: intacta (D5)
  v_oid := to_regprocedure(v_sub_sig);
  IF v_oid IS NULL THEN
    v_failures := v_failures || format('%s no resuelve — la firma cambió', v_sub_sig);
  ELSIF md5(replace(pg_get_functiondef(v_oid), E'\r', '')) <> v_sub_md5 THEN
    v_failures := v_failures || format('rpc_emit_subscription_payment_cae cambió (md5 %s, esperado %s): D5 de punto-venta-seleccion la deja intacta. Si una migración la reescribe A PROPÓSITO, actualizar este md5 en el mismo PR.',
                                       md5(replace(pg_get_functiondef(v_oid), E'\r', '')), v_sub_md5);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE PUNTO-VENTA-PREDETERMINADO (0) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (0): columna, CHECK, índice único parcial, RPC de ventas (firma única, DEFINER, ACLs, COMMENT) y RPC de suscripciones intacta.';
END $$;


-- ── (a)-(h) Comportamiento sobre datos ───────────────────────────────────────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_user_c    uuid := gen_random_uuid();
  v_users     uuid[];
  v_account_a uuid;
  v_account_b uuid;
  v_account_c uuid;
  v_accounts  uuid[];
  v_claims_a  text;

  v_fp_a      uuid;
  v_fp_b      uuid;
  v_fp_c      uuid;
  v_pv_a3     uuid;
  v_pv_a9999  uuid;
  v_pv_a7     uuid;   -- inactivo
  v_pv_b5     uuid;
  v_pv_b6     uuid;
  v_pv_c3     uuid;
  v_pv_c9999  uuid;
  v_receipt   uuid;

  v_result    jsonb;
  v_state     text;
  v_seq_rows_before  integer;
  v_seq_rows_after   integer;
  v_seq_sum_before   bigint;
  v_seq_sum_after    bigint;
  v_docs_before      integer;
  v_docs_after       integer;
  v_doc_pv           uuid;
  v_doc_numero       integer;
  v_admin_fp_others  integer;
  v_tbl       text;
  v_cnt       bigint;
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v_user_a, 'authenticated', 'authenticated', 'pv-predeterminado-a@test.local', now(), now(),
     jsonb_build_object('name', 'Gate PV Predeterminado A', 'phone', '', 'locality', '', 'province', '')),
    (v_user_b, 'authenticated', 'authenticated', 'pv-predeterminado-b@test.local', now(), now(),
     jsonb_build_object('name', 'Gate PV Predeterminado B', 'phone', '', 'locality', '', 'province', '')),
    (v_user_c, 'authenticated', 'authenticated', 'pv-predeterminado-c@test.local', now(), now(),
     jsonb_build_object('name', 'Gate PV Predeterminado C', 'phone', '', 'locality', '', 'province', ''));
  v_users := ARRAY[v_user_a, v_user_b, v_user_c];

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_c FROM public.account_members WHERE user_id = v_user_c ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_c IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no resolvió las tres cuentas del fixture';
  END IF;
  v_accounts := ARRAY[v_account_a, v_account_b, v_account_c];

  -- CUITs sintéticos distintos por cuenta: el guard P0435 impide compartir
  -- (CUIT, PV) activo entre cuentas.
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_a, '20990630011', 'monotributista', 'homologacion', true) RETURNING id INTO v_fp_a;
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_b, '20990630029', 'monotributista', 'homologacion', true) RETURNING id INTO v_fp_b;
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_c, '20990630037', 'monotributista', 'homologacion', true) RETURNING id INTO v_fp_c;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 3, true) RETURNING id INTO v_pv_a3;

  v_claims_a := json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text;

  -- ═══ (a) Un solo PV activo, sin explícito → ese ═══
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 100);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(a) con UN PV activo y sin explícito debía emitir; got %s', v_state);
  ELSIF (v_result->>'point_of_sale_id')::uuid IS DISTINCT FROM v_pv_a3
     OR (v_result->>'punto_de_venta')::integer IS DISTINCT FROM 3 THEN
    v_failures := v_failures || format('(a) debía usar el PV 3; got %s', v_result);
  END IF;

  -- Segundo PV activo + uno inactivo
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 9999, true) RETURNING id INTO v_pv_a9999;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 7, false) RETURNING id INTO v_pv_a7;

  -- ═══ (b) Dos activos, sin predeterminado, sin explícito → P0422 sin rastro ═══
  SELECT count(*), COALESCE(sum(last_number), 0) INTO v_seq_rows_before, v_seq_sum_before
  FROM   public.document_sequences WHERE point_of_sale_id IN (v_pv_a3, v_pv_a9999, v_pv_a7);
  SELECT count(*) INTO v_docs_before FROM public.fiscal_documents WHERE account_id = v_account_a;

  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 200);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';

  IF v_state <> 'P0422' THEN
    v_failures := v_failures || format('(b) dos activos SIN predeterminado y sin explícito debía dar P0422; got %s', v_state);
  END IF;
  SELECT count(*), COALESCE(sum(last_number), 0) INTO v_seq_rows_after, v_seq_sum_after
  FROM   public.document_sequences WHERE point_of_sale_id IN (v_pv_a3, v_pv_a9999, v_pv_a7);
  SELECT count(*) INTO v_docs_after FROM public.fiscal_documents WHERE account_id = v_account_a;
  IF v_seq_rows_after <> v_seq_rows_before OR v_seq_sum_after <> v_seq_sum_before THEN
    v_failures := v_failures || format('(b) el P0422 no debía reservar número: filas %s->%s, suma %s->%s',
                                       v_seq_rows_before, v_seq_rows_after, v_seq_sum_before, v_seq_sum_after);
  END IF;
  IF v_docs_after <> v_docs_before THEN
    v_failures := v_failures || format('(b) el P0422 no debía crear comprobante: %s->%s', v_docs_before, v_docs_after);
  END IF;

  -- ═══ (e2) El predeterminado de OTRA cuenta no resuelve la ambigüedad ═══
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active, is_default)
  VALUES (v_fp_b, v_account_b, 5, true, true) RETURNING id INTO v_pv_b5;

  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 250);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';

  IF v_state <> 'P0422' THEN
    v_failures := v_failures || format('(e2) el predeterminado de OTRA cuenta no debía resolver la ambigüedad de A; got %s', v_state);
  END IF;

  -- ═══ (c) Dos activos con el 9999 predeterminado, sin explícito → 9999 ═══
  UPDATE public.points_of_sale SET is_default = true WHERE id = v_pv_a9999;

  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 300);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(c) con el 9999 predeterminado y sin explícito debía emitir; got %s', v_state);
  ELSE
    SELECT point_of_sale_id, punto_de_venta INTO v_doc_pv, v_doc_numero
    FROM   public.fiscal_documents WHERE id = (v_result->>'fiscal_document_id')::uuid;
    IF v_doc_pv IS DISTINCT FROM v_pv_a9999 OR v_doc_numero IS DISTINCT FROM 9999
       OR (v_result->>'punto_de_venta')::integer IS DISTINCT FROM 9999
       OR v_result->>'status' IS DISTINCT FROM 'pending_cae' THEN
      v_failures := v_failures || format('(c) debía salir pending_cae por el 9999; fila pv=%s numero=%s, respuesta=%s',
                                         v_doc_pv, v_doc_numero, v_result);
    END IF;
  END IF;

  -- ═══ (d) Explícito (3) ≠ predeterminado (9999) → gana el explícito ═══
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 400, NULL, v_pv_a3);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(d) con explícito 3 debía emitir; got %s', v_state);
  ELSIF (v_result->>'point_of_sale_id')::uuid IS DISTINCT FROM v_pv_a3
     OR (v_result->>'punto_de_venta')::integer IS DISTINCT FROM 3 THEN
    v_failures := v_failures || format('(d) el PV explícito (3) debía ganar sobre el predeterminado (9999); got %s', v_result);
  END IF;

  -- ═══ (e) Explícito INACTIVO con predeterminado vivo → P0404 ═══
  SELECT count(*) INTO v_docs_before FROM public.fiscal_documents WHERE account_id = v_account_a;
  PERFORM set_config('request.jwt.claims', v_claims_a, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 500, NULL, v_pv_a7);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';

  IF v_state <> 'P0404' THEN
    v_failures := v_failures || format('(e) un PV explícito inactivo debía dar P0404 aunque haya predeterminado; got %s', v_state);
  END IF;
  SELECT count(*) INTO v_docs_after FROM public.fiscal_documents WHERE account_id = v_account_a;
  IF v_docs_after <> v_docs_before THEN
    v_failures := v_failures || format('(e) el P0404 no debía crear comprobante (ni por el predeterminado): %s->%s', v_docs_before, v_docs_after);
  END IF;

  -- ═══ (f) Índice único parcial ═══
  BEGIN
    UPDATE public.points_of_sale SET is_default = true WHERE id = v_pv_a3;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> '23505' THEN
    v_failures := v_failures || format('(f) un segundo predeterminado en la misma cuenta debía fallar con 23505; got %s', v_state);
  END IF;
  IF (SELECT count(*) FROM public.points_of_sale WHERE account_id = v_account_a AND is_default) <> 1
     OR NOT (SELECT is_default FROM public.points_of_sale WHERE id = v_pv_a9999) THEN
    v_failures := v_failures || '(f) tras el rechazo, el 9999 debía seguir siendo el ÚNICO predeterminado de A'::text;
  END IF;
  -- En otra cuenta pasa (B ya tiene su predeterminado desde (e2), C todavía no).
  BEGIN
    INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active, is_default)
    VALUES (v_fp_c, v_account_c, 3, true, true) RETURNING id INTO v_pv_c3;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(f) un predeterminado en OTRA cuenta debía pasar; got %s', v_state);
  END IF;

  -- ═══ (g) CHECK: sólo un PV activo puede ser predeterminado ═══
  BEGIN
    UPDATE public.points_of_sale SET is_default = true WHERE id = v_pv_a7;  -- inactivo
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state NOT IN ('23514', '23505') THEN
    v_failures := v_failures || format('(g) marcar un PV INACTIVO como predeterminado debía fallar; got %s', v_state);
  END IF;
  -- Aislado del índice: un inactivo en B (cuyo predeterminado es el 5) sin
  -- que la unicidad intervenga: primero se quita la marca del 5.
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_b, v_account_b, 6, false) RETURNING id INTO v_pv_b6;
  UPDATE public.points_of_sale SET is_default = false WHERE id = v_pv_b5;
  BEGIN
    UPDATE public.points_of_sale SET is_default = true WHERE id = v_pv_b6;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> '23514' THEN
    v_failures := v_failures || format('(g) marcar un PV inactivo como predeterminado (sin choque de unicidad) debía dar 23514; got %s', v_state);
  END IF;
  -- Desactivar el predeterminado SIN limpiar la marca → 23514.
  BEGIN
    UPDATE public.points_of_sale SET is_active = false WHERE id = v_pv_a9999;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> '23514' THEN
    v_failures := v_failures || format('(g) desactivar el predeterminado sin limpiar la marca debía dar 23514; got %s', v_state);
  END IF;
  -- Control: desactivarlo limpiando la marca en la misma sentencia pasa, y la
  -- cuenta queda SIN predeterminado (el 3 no se promueve solo).
  BEGIN
    UPDATE public.points_of_sale SET is_active = false, is_default = false WHERE id = v_pv_a9999;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(g) desactivar limpiando la marca en la misma sentencia debía pasar; got %s', v_state);
  ELSIF (SELECT count(*) FROM public.points_of_sale WHERE account_id = v_account_a AND is_default) <> 0 THEN
    v_failures := v_failures || '(g) tras desactivar el predeterminado la cuenta debía quedar SIN predeterminado'::text;
  END IF;

  -- ═══ (h) Facturación de suscripciones: sin cambio (D5) ═══
  -- La RPC resuelve el emisor como "el perfil fiscal de una cuenta cuyo owner
  -- es profiles.role = 'admin'" (LIMIT 1). Si el entorno ya tiene otro, el
  -- fixture no puede garantizar que resuelva el suyo: se omite la parte de
  -- comportamiento (el md5 del bloque (0) igual fija el cuerpo).
  SELECT count(*) INTO v_admin_fp_others
  FROM   public.fiscal_profiles fp
  JOIN   public.accounts a  ON a.id = fp.account_id
  JOIN   public.profiles pr ON pr.id = a.owner_user_id
  WHERE  pr.role = 'admin';

  IF v_admin_fp_others > 0 THEN
    RAISE NOTICE 'SKIP (h, comportamiento): el entorno ya tiene % perfil(es) fiscal(es) de un admin de plataforma; el md5 del bloque (0) fija igual la RPC.', v_admin_fp_others;
  ELSE
    -- prevent_profile_privilege_escalation bloquea el UPDATE de role fuera
    -- de un caller ya-admin: escape sancionado para setup de test (mismo
    -- patrón que test_admin_kpis.sql) — DISABLE/ENABLE en la misma
    -- transacción.
    ALTER TABLE public.profiles DISABLE TRIGGER trg_prevent_profile_escalation;
    UPDATE public.profiles SET role = 'admin' WHERE id = v_user_c;
    ALTER TABLE public.profiles ENABLE TRIGGER trg_prevent_profile_escalation;
    INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
    VALUES (v_fp_c, v_account_c, 9999, true) RETURNING id INTO v_pv_c9999;
    -- C: PV 3 activo y PREDETERMINADO (desde (f)) + PV 9999 activo.
    INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, amount)
    VALUES (v_user_c, 'plan_upgraded', 'gratis', 'pro', 1000)
    RETURNING id INTO v_receipt;

    -- Como el admin de plataforma real (owner de la cuenta emisora):
    -- rpc_next_document_number exige owner/admin por auth.uid().
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_user_c::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      v_result := public.rpc_emit_subscription_payment_cae(v_receipt::text);
      v_state := 'ok';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> 'P0422' THEN
      v_failures := v_failures || format('(h) la facturación de suscripciones con 2 activos + predeterminado y SIN explícito debía seguir dando P0422 (D5); got %s', v_state);
    END IF;

    -- Control positivo: con PV explícito el mismo recibo se factura.
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_user_c::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      v_result := public.rpc_emit_subscription_payment_cae(v_receipt::text, v_pv_c9999);
      v_state := 'ok';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> 'ok' OR (v_result->>'punto_de_venta')::integer IS DISTINCT FROM 9999 THEN
      v_failures := v_failures || format('(h) control positivo: con PV explícito 9999 debía facturar; got %s / %s', v_state, v_result);
    END IF;
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE PUNTO-VENTA-PREDETERMINADO (a-h) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (a-h): único → ese; varios sin predeterminado → P0422 sin rastro; el predeterminado ajeno no cuenta; varios con predeterminado → el predeterminado; explícito gana; explícito inactivo → P0404; un predeterminado por cuenta; sólo activo; suscripciones sin cambio.';

  -- ═══ (z) Limpieza verificada ═══
  DELETE FROM public.document_status_history WHERE account_id = ANY(v_accounts);
  DELETE FROM public.fiscal_documents        WHERE account_id = ANY(v_accounts);
  DELETE FROM public.document_sequences
  WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = ANY(v_accounts));
  DELETE FROM public.points_of_sale          WHERE account_id = ANY(v_accounts);
  DELETE FROM public.fiscal_profiles         WHERE account_id = ANY(v_accounts);
  DELETE FROM public.billing_events          WHERE user_id = ANY(v_users);
  -- email_logs.user_id es ON DELETE SET NULL: sin esto quedan huérfanos.
  DELETE FROM public.email_logs              WHERE user_id = ANY(v_users);

  -- Bajo replica la RI está apagada (branches prohíbe el borrado físico,
  -- P0428): se retira explícito todo lo que cuelga de las cuentas, en TODA
  -- tabla base de public con account_id (lo que handle_new_user siembra hoy y
  -- lo que siembre mañana).
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

  -- Residuo cero: toda tabla base de public con account_id o user_id.
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
  SELECT count(*) INTO v_cnt FROM public.billing_events WHERE user_id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(z) residuo: %s billing_events del fixture', v_cnt); END IF;
  SELECT count(*) INTO v_cnt FROM public.profiles WHERE id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(z) residuo: %s profiles del fixture', v_cnt); END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE PUNTO-VENTA-PREDETERMINADO (z) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (z): limpieza verificada — cero filas del fixture en toda tabla de public con account_id.';

EXCEPTION
  WHEN OTHERS THEN
    -- El bloque se revierte entero al propagar el error (subtransacción de
    -- plpgsql): el fixture no persiste. Sólo hay que devolver el rol.
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- GATE PUNTO-VENTA-PREDETERMINADO PASSED (2 bloques: introspección + a-h/z).
-- =============================================================================
