-- =============================================================================
-- test_fiscal_emit_consumidor_final.sql — Gate de comportamiento:
-- fiscal-emit-cae-consumidor-final (fix ad-hoc, governance CRÍTICO).
--
-- rpc_emit_pending_cae (el camino de "facturar una VENTA", a diferencia de
-- rpc_emit_subscription_payment_cae que factura una suscripción) levanta
-- SQLSTATE 55000 "record v_client is not assigned yet" cuando se la llama SIN
-- p_client_id. Causa: v_client era un RECORD que sólo se asigna dentro del
-- IF p_client_id IS NOT NULL, pero el INSERT en fiscal_documents lee
-- v_client.legal_name / v_client.iva_condition INCONDICIONALMENTE — en
-- plpgsql leer un campo de un RECORD nunca asignado es error, nunca NULL. El
-- propio comentario de la migración que lo introdujo (v3-snapshot-pattern)
-- dice que ese caso debe dejar los snapshots en NULL ("consumidor final,
-- comportamiento previo"): el bug es que el código nunca hizo eso.
--
-- Origen: 20260806000001_v3_snapshot_pattern.sql, reescrita en
-- 20260807000001_v3_document_status_history.sql (agosto 2026).
--
-- Por qué nunca explotó en prod: las 2 únicas facturas reales salieron por
-- rpc_emit_subscription_payment_cae (medido 2026-09-22: 2 fiscal_documents en
-- prod, ambos con subscription_payment_id, 0 sin cliente y sin suscripción).
-- rpc_emit_pending_cae jamás se ejercitó en producción — pero el schema del
-- backend (backend/schemas/fiscal.py, client_id: uuid.UUID | None = None)
-- permite emitir sin cliente, así que el primer usuario que facture a
-- consumidor final por este camino se come un 500.
--
-- Verifica 20261058000001_fiscal_emit_pending_cae_consumidor_final.sql:
--
--   (1) Firma única de rpc_emit_pending_cae (los 9 parámetros documentados),
--       SECURITY DEFINER, sin overload (el 42725 de siempre).
--   (2) ACLs exactas: authenticated y service_role CON EXECUTE (es una RPC de
--       usuario — jamás revocar authenticated); anon y PUBLIC SIN EXECUTE.
--   (3) Emisión SIN cliente (consumidor final): NO debe levantar. El
--       documento nace pending_cae, sin CAE, con client_id y los snapshots
--       del receptor en NULL, y con su fila en document_status_history
--       (NULL -> pending_cae).
--   (4) Triangulación — consumidor final CON documento del receptor
--       (receptor_doc_tipo/receptor_doc_nro) pero SIN cliente: esos dos
--       campos se persisten, los snapshots siguen NULL.
--   (5) Control positivo CON cliente: los snapshots copian legal_name/
--       iva_condition del cliente (distintos de los del perfil fiscal), y un
--       cliente con legal_name NULL nace igual, sin error, con snapshot NULL.
--   (6) Limpieza verificada: cero filas residuales del fixture.
--
-- Patrón del proyecto (test_fiscal_cae_numero_autoritativo.sql): acumular
-- fallos en text[], un solo RAISE EXCEPTION al final de cada bloque, anchors
-- sintéticos vía handle_new_user, set_config('request.jwt.claims', …) + SET
-- LOCAL ROLE authenticated para llamar la RPC como usuario, limpieza en el
-- camino feliz y en el EXCEPTION.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

-- ── (1) Firma única, sin overload ────────────────────────────────────────────
DO $$
DECLARE
  v_count  integer;
  v_args   text;
  v_secdef boolean;
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_emit_pending_cae';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (1) FAILED: se esperaba UNA sola definición de rpc_emit_pending_cae y hay %. Un overload es el 42725 clásico: una llamada vieja podría resolver a una función distinta con el bug sin arreglar.', v_count;
  END IF;

  SELECT pg_get_function_identity_arguments(p.oid), p.prosecdef
  INTO   v_args, v_secdef
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_emit_pending_cae';

  IF v_args <> 'p_comprobante_type text, p_total numeric, p_client_id uuid, p_point_of_sale_id uuid, p_receptor_doc_tipo integer, p_receptor_doc_nro text, p_neto numeric, p_iva_amount numeric, p_iva_alicuota_id integer' THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (1) FAILED: firma inesperada de rpc_emit_pending_cae: (%)', v_args;
  END IF;

  IF NOT v_secdef THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (1) FAILED: rpc_emit_pending_cae dejó de ser SECURITY DEFINER (fiscal_documents no tiene policy de INSERT: sin DEFINER nadie puede emitir un comprobante).';
  END IF;

  RAISE NOTICE 'PASS (1): rpc_emit_pending_cae con firma única (9 parámetros) y SECURITY DEFINER.';
END $$;


-- ── (2) ACLs exactas ─────────────────────────────────────────────────────────
DO $$
DECLARE
  v_sig CONSTANT text :=
    'public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)';
  v_oid oid;
  v_offenders text[] := '{}';
BEGIN
  v_oid := to_regprocedure(v_sig);
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (2) FAILED: % no resuelve — la firma cambió.', v_sig;
  END IF;

  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    v_offenders := v_offenders || 'rpc_emit_pending_cae SIN EXECUTE para authenticated (es RPC de usuario: la usa cualquier cuenta para facturar una venta)';
  END IF;
  IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    v_offenders := v_offenders || 'rpc_emit_pending_cae SIN EXECUTE para service_role';
  END IF;
  IF has_function_privilege('public', v_oid, 'EXECUTE') THEN
    v_offenders := v_offenders || 'rpc_emit_pending_cae ejecutable por PUBLIC';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_offenders := v_offenders || 'rpc_emit_pending_cae ejecutable por anon';
    END IF;
  ELSE
    RAISE NOTICE 'GATE FISCAL-EMIT-CF (2): rol anon no existe en este entorno — ese chequeo se omite';
  END IF;

  IF array_length(v_offenders, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-EMIT-CF (2) FAILED: ACLs de rpc_emit_pending_cae.\n  %\n  Es RPC de usuario, NUNCA revocar authenticated; NUNCA re-otorgar a anon (¿DROP+CREATE sin re-aplicar el REVOKE/GRANT del archivo de migración?).',
      array_to_string(v_offenders, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (2): authenticated y service_role con EXECUTE; anon y PUBLIC sin EXECUTE.';
END $$;


-- ── (3)-(6) Comportamiento sobre datos ───────────────────────────────────────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_email     text := 'fiscal-emit-consumidor-final@test.local';
  v_user      uuid := gen_random_uuid();
  v_account   uuid;
  v_fp        uuid;
  v_pv        uuid;
  v_claims    text;

  v_client_ok       uuid;  -- cliente con legal_name/iva_condition distintos del perfil
  v_client_nulls    uuid;  -- cliente con legal_name/iva_condition NULL

  v_doc_id    uuid;
  v_doc_id_2  uuid;
  v_doc_id_3  uuid;
  v_doc_id_4  uuid;
  v_result    jsonb;

  v_client_id_col     uuid;
  v_recept_name       text;
  v_recept_iva        text;
  v_status            text;
  v_cae               text;
  v_recept_doc_tipo   integer;
  v_recept_doc_nro    text;
  v_count             integer;
  v_trigger_exists    boolean;
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', v_email, now(), now(),
          jsonb_build_object('name', 'Gate Emit Consumidor Final', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account
  FROM   public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor — handle_new_user no corrió';
  END IF;

  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account, '20111111112', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fp;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, v_account, 9201, true) RETURNING id INTO v_pv;

  v_claims := json_build_object('sub', v_user::text, 'role', 'authenticated')::text;

  -- Informativo, no aserción: si el guard P0436 (fiscal-riesgos-residuales,
  -- rama hermana sin mergear) está vivo en este entorno, prueba en el mismo
  -- log que el comprobante nace limpio (pending_cae, sin CAE) también bajo
  -- ese guard — sin que este gate (que corre en CI, donde el guard NO existe
  -- todavía) dependa de él.
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_guard_fiscal_document_insert_interno'
      AND tgrelid = 'public.fiscal_documents'::regclass
  ) INTO v_trigger_exists;
  RAISE NOTICE 'INFO: trigger P0436 (trg_guard_fiscal_document_insert_interno) presente en este entorno = %', v_trigger_exists;

  -- ═══ (3) SIN cliente (consumidor final) ═══
  PERFORM set_config('request.jwt.claims', v_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 1500);
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (3) FAILED: emitir SIN cliente (consumidor final) no debe levantar — sqlstate=% msg=%',
      SQLSTATE, SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  IF v_result->>'status' <> 'pending_cae' OR v_result->>'number' IS NULL THEN
    v_failures := v_failures || format('(3) respuesta inesperada de la RPC: %s', v_result::text);
  END IF;

  v_doc_id := (v_result->>'fiscal_document_id')::uuid;

  SELECT client_id, receptor_legal_name, receptor_iva_condition, status, cae
  INTO   v_client_id_col, v_recept_name, v_recept_iva, v_status, v_cae
  FROM   public.fiscal_documents WHERE id = v_doc_id;

  IF v_client_id_col IS NOT NULL THEN
    v_failures := v_failures || format('(3) client_id debía quedar NULL y quedó %s', v_client_id_col);
  END IF;
  IF v_recept_name IS NOT NULL THEN
    v_failures := v_failures || format('(3) receptor_legal_name debía quedar NULL y quedó %s', v_recept_name);
  END IF;
  IF v_recept_iva IS NOT NULL THEN
    v_failures := v_failures || format('(3) receptor_iva_condition debía quedar NULL y quedó %s', v_recept_iva);
  END IF;
  IF v_status <> 'pending_cae' THEN
    v_failures := v_failures || format('(3) status debía ser pending_cae y quedó %s', v_status);
  END IF;
  IF v_cae IS NOT NULL THEN
    v_failures := v_failures || format('(3) cae debía quedar NULL y quedó %s', v_cae);
  END IF;

  SELECT count(*) INTO v_count
  FROM   public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc_id
    AND  from_status IS NULL AND to_status = 'pending_cae';
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(3) faltó la fila de document_status_history (NULL -> pending_cae); encontradas %s', v_count);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-EMIT-CF (3) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (3): emisión SIN cliente no levanta; nace pending_cae, sin CAE, client_id y snapshots del receptor en NULL, con su fila en document_status_history.';

  -- ═══ (4) Triangulación: SIN cliente pero CON documento del receptor ═══
  PERFORM set_config('request.jwt.claims', v_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 2500, NULL, NULL, 96, '12345678');
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (4) FAILED: emitir SIN cliente pero CON receptor_doc_tipo/nro no debe levantar — sqlstate=% msg=%',
      SQLSTATE, SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  v_doc_id_2 := (v_result->>'fiscal_document_id')::uuid;

  SELECT client_id, receptor_legal_name, receptor_iva_condition, receptor_doc_tipo, receptor_doc_nro
  INTO   v_client_id_col, v_recept_name, v_recept_iva, v_recept_doc_tipo, v_recept_doc_nro
  FROM   public.fiscal_documents WHERE id = v_doc_id_2;

  IF v_client_id_col IS NOT NULL THEN
    v_failures := v_failures || format('(4) client_id debía quedar NULL y quedó %s', v_client_id_col);
  END IF;
  IF v_recept_name IS NOT NULL OR v_recept_iva IS NOT NULL THEN
    v_failures := v_failures || format('(4) los snapshots debían quedar NULL; legal_name=%s iva_condition=%s', COALESCE(v_recept_name, '<NULL>'), COALESCE(v_recept_iva, '<NULL>'));
  END IF;
  IF v_recept_doc_tipo <> 96 OR v_recept_doc_nro <> '12345678' THEN
    v_failures := v_failures || format('(4) receptor_doc_tipo/nro debían persistirse; got tipo=%s nro=%s', v_recept_doc_tipo, COALESCE(v_recept_doc_nro, '<NULL>'));
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-EMIT-CF (4) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (4): SIN cliente pero CON documento del receptor — receptor_doc_tipo/nro se persisten y los snapshots siguen NULL.';

  -- ═══ (5) Control positivo CON cliente ═══
  INSERT INTO public.clients (account_id, user_id, name, legal_name, iva_condition)
  VALUES (v_account, v_user, 'Cliente Control', 'Cliente Control SA', 'responsable_inscripto')
  RETURNING id INTO v_client_ok;

  PERFORM set_config('request.jwt.claims', v_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 3500, v_client_ok);
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (5) FAILED: emitir CON cliente no debe levantar — sqlstate=% msg=%',
      SQLSTATE, SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  v_doc_id_3 := (v_result->>'fiscal_document_id')::uuid;

  SELECT client_id, receptor_legal_name, receptor_iva_condition
  INTO   v_client_id_col, v_recept_name, v_recept_iva
  FROM   public.fiscal_documents WHERE id = v_doc_id_3;

  IF v_client_id_col <> v_client_ok THEN
    v_failures := v_failures || format('(5) client_id debía ser %s y quedó %s', v_client_ok, v_client_id_col);
  END IF;
  IF v_recept_name <> 'Cliente Control SA' THEN
    v_failures := v_failures || format('(5) receptor_legal_name debía copiar el del cliente (Cliente Control SA) y quedó %s', COALESCE(v_recept_name, '<NULL>'));
  END IF;
  IF v_recept_iva <> 'responsable_inscripto' THEN
    v_failures := v_failures || format('(5) receptor_iva_condition debía copiar el del cliente (responsable_inscripto, distinto del monotributista del perfil fiscal) y quedó %s', COALESCE(v_recept_iva, '<NULL>'));
  END IF;

  -- Sub-caso: cliente con legal_name/iva_condition NULL — nace igual, snapshot NULL.
  INSERT INTO public.clients (account_id, user_id, name, legal_name, iva_condition)
  VALUES (v_account, v_user, 'Cliente Sin Datos Fiscales', NULL, NULL)
  RETURNING id INTO v_client_nulls;

  PERFORM set_config('request.jwt.claims', v_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    v_result := public.rpc_emit_pending_cae('factura_c', 4500, v_client_nulls);
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (5) FAILED: emitir CON cliente sin legal_name/iva_condition no debe levantar — sqlstate=% msg=%',
      SQLSTATE, SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  v_doc_id_4 := (v_result->>'fiscal_document_id')::uuid;

  SELECT client_id, receptor_legal_name, receptor_iva_condition
  INTO   v_client_id_col, v_recept_name, v_recept_iva
  FROM   public.fiscal_documents WHERE id = v_doc_id_4;

  IF v_client_id_col <> v_client_nulls THEN
    v_failures := v_failures || format('(5) sub-caso NULL: client_id debía ser %s y quedó %s', v_client_nulls, v_client_id_col);
  END IF;
  IF v_recept_name IS NOT NULL OR v_recept_iva IS NOT NULL THEN
    v_failures := v_failures || format('(5) sub-caso NULL: los snapshots debían quedar NULL; legal_name=%s iva_condition=%s', COALESCE(v_recept_name, '<NULL>'), COALESCE(v_recept_iva, '<NULL>'));
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-EMIT-CF (5) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (5): CON cliente los snapshots copian legal_name/iva_condition del cliente (distintos de los del perfil fiscal); un cliente sin esos datos nace igual, con snapshot NULL.';

  -- ═══ (6) Limpieza verificada ═══
  DELETE FROM public.document_status_history WHERE account_id = v_account;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account;
  DELETE FROM public.document_sequences
  WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account);
  DELETE FROM public.points_of_sale          WHERE account_id = v_account;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account;
  DELETE FROM public.clients                 WHERE account_id = v_account;

  SELECT count(*) INTO v_count FROM public.fiscal_documents WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (6) FAILED: quedaron % fiscal_documents del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.document_status_history WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (6) FAILED: quedaron % filas de document_status_history del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.clients WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (6) FAILED: quedaron % clients del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.points_of_sale WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (6) FAILED: quedaron % points_of_sale del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.fiscal_profiles WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-EMIT-CF (6) FAILED: quedaron % fiscal_profiles del fixture', v_count;
  END IF;

  SET session_replication_role = replica;
  DELETE FROM public.account_members WHERE account_id = v_account;
  DELETE FROM public.accounts        WHERE id = v_account;
  DELETE FROM public.profiles        WHERE id = v_user;
  DELETE FROM auth.users             WHERE id = v_user;
  SET session_replication_role = DEFAULT;

  RAISE NOTICE 'PASS (6): limpieza verificada — cero filas residuales del fixture.';

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
      DELETE FROM public.document_status_history WHERE account_id = v_account;
      DELETE FROM public.fiscal_documents        WHERE account_id = v_account;
      DELETE FROM public.document_sequences
      WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account);
      DELETE FROM public.points_of_sale          WHERE account_id = v_account;
      DELETE FROM public.fiscal_profiles         WHERE account_id = v_account;
      DELETE FROM public.clients                 WHERE account_id = v_account;
      SET session_replication_role = replica;
      DELETE FROM public.account_members WHERE account_id = v_account;
      DELETE FROM public.accounts        WHERE id = v_account;
      DELETE FROM public.profiles        WHERE id = v_user;
      DELETE FROM auth.users             WHERE id = v_user;
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- GATE FISCAL-EMIT-CF PASSED (6 bloques).
-- =============================================================================
