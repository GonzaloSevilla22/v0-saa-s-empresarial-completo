-- =============================================================================
-- test_fiscal_cae_numero_autoritativo.sql — Gates de comportamiento:
-- fiscal-emision-segura (governance CRÍTICO).
--
-- Es el PRIMER gate SQL del dominio fiscal: hasta este change `supabase/tests/`
-- no tenía ninguno (ls | grep -i "fiscal|cae|afip" → vacío), y por eso
-- `rpc_fiscal_document_authorize` pudo pasar de tener EXECUTE para
-- `authenticated` sin que nada lo notara.
--
-- Verifica 20261054000001_fiscal_emision_segura.sql:
--
--   (1)  Firma ÚNICA de rpc_fiscal_document_authorize (uuid, text, date, bigint),
--        SECURITY DEFINER, sin overload (el 42725 de siempre).
--   (2)  ACLs exactas de las 5 RPCs del relay: sin EXECUTE para PUBLIC/anon/
--        authenticated, con postgres y service_role.
--   (3)  Meta-candado del gate de ACLs: las 5 firmas cargadas en
--        v_internal_only_fns de test_function_acl_gate.sql RESUELVEN. El
--        chequeo (3) de ese gate es drift-tolerante (ignora firmas que no
--        resuelven), así que un cambio de firma futuro lo apagaría EN
--        SILENCIO. Ya pasó en este proyecto.
--   (4)  Cuerpos vivos: authorize nombra el desfasaje, la colisión, el caso
--        irresoluble y el UPDATE de document_sequences; claim_pending excluye
--        los congelados.
--   (5)  Desfasaje: ARCA autorizó otro número → se adopta, queda el rastro en
--        document_status_history y el contador se resincroniza.
--   (6)  Sin desfasaje (mismo número, y p_number NULL): nada se toca.
--   (7)  Colisión: se conserva el número local y NUNCA se pierde el CAE.
--   (7b) Caso irresoluble (ni el de ARCA ni el local están libres): el CAE se
--        guarda igual y el documento queda CONGELADO en vez de perder el CAE
--        por la excepción del índice único — que habría provocado una segunda
--        factura real en el próximo tick del relay.
--   (8)  El congelamiento congela: claim_pending devuelve 0 filas, con control
--        positivo (un hermano sin congelar devuelve 1).
--   (9)  Idempotencias: freeze no repisa su marca; authorize sobre un doc ya
--        authorized devuelve false y NO agrega una segunda fila de historial.
--   (10) Resincronización SOLO hacia adelante.
--   (11) Limpieza verificada: cero filas residuales de los fixtures.
--   (12) G9: un mismo CUIT no puede tener el mismo punto de venta ACTIVO en dos
--        cuentas (P0435), por los dos lados (alta/actualización de PV y cambio
--        de CUIT del perfil), sin tocar las filas que ya existen.
--
-- Patrón del proyecto (test_edicion_preserva_contexto.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final, anchors sintéticos vía
-- handle_new_user, limpieza en el camino feliz y en el EXCEPTION.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

-- ── (1) Firma única, sin overload ────────────────────────────────────────────
DO $$
DECLARE
  v_count integer;
  v_args  text;
  v_secdef boolean;
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_authorize';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (1) FAILED: se esperaba UNA sola definición de rpc_fiscal_document_authorize y hay %. Un overload es el 42725 clásico: la llamada de 3 argumentos del backend viejo resolvería a la función vieja y el número de ARCA no se persistiría nunca.', v_count;
  END IF;

  SELECT pg_get_function_identity_arguments(p.oid), p.prosecdef
  INTO   v_args, v_secdef
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_authorize';

  IF v_args <> 'p_doc_id uuid, p_cae text, p_cae_due_date date, p_number bigint' THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (1) FAILED: firma inesperada de rpc_fiscal_document_authorize: (%)', v_args;
  END IF;

  IF NOT v_secdef THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (1) FAILED: rpc_fiscal_document_authorize dejó de ser SECURITY DEFINER (fiscal_documents no tiene policy de UPDATE: sin DEFINER el relay no puede autorizar nada).';
  END IF;

  RAISE NOTICE 'PASS (1): rpc_fiscal_document_authorize con firma única (uuid, text, date, bigint) y SECURITY DEFINER.';
END $$;


-- ── (2) ACLs exactas de las 5 RPCs del relay ────────────────────────────────
DO $$
DECLARE
  v_fns CONSTANT text[] := ARRAY[
    'public.rpc_fiscal_document_authorize(uuid, text, date, bigint)',
    'public.rpc_fiscal_document_claim_pending(uuid, integer)',
    'public.rpc_fiscal_document_retry(uuid, integer, timestamp with time zone, text)',
    'public.rpc_fiscal_document_reject(uuid, text)',
    'public.rpc_fiscal_document_freeze_unconfirmed(uuid, bigint, text)'
  ];
  v_sig       text;
  v_oid       oid;
  v_offenders text[] := '{}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    RAISE NOTICE 'GATE FISCAL-CAE (2): rol anon no existe en este entorno — chequeo omitido';
    RETURN;
  END IF;

  FOREACH v_sig IN ARRAY v_fns LOOP
    v_oid := to_regprocedure(v_sig);
    IF v_oid IS NULL THEN
      v_offenders := v_offenders || format('%s NO EXISTE', v_sig);
      CONTINUE;
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_offenders := v_offenders || format('%s ejecutable por authenticated', v_sig);
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_offenders := v_offenders || format('%s ejecutable por anon', v_sig);
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_offenders := v_offenders || format('%s SIN EXECUTE para service_role', v_sig);
    END IF;
  END LOOP;

  IF array_length(v_offenders, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (2) FAILED: ACLs de las RPCs del relay del CAE.\n  %\n  Contexto: rpc_fiscal_document_authorize es SECURITY DEFINER y NO valida tenencia — recibe el doc_id, el CAE y la fecha y los escribe. Con EXECUTE para authenticated, un POST a PostgREST con el uuid del comprobante de CUALQUIER cuenta lo marca authorized con un CAE inventado. NUNCA re-otorgar (¿DROP+CREATE sin re-aplicar el REVOKE?).',
      array_to_string(v_offenders, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (2): las 5 RPCs del relay sin EXECUTE para anon/authenticated y con service_role.';
END $$;


-- ── (3) Meta-candado: las firmas del gate de ACLs resuelven ─────────────────
DO $$
DECLARE
  -- MISMAS cadenas que v_internal_only_fns de test_function_acl_gate.sql. Si
  -- alguna deja de resolver, el chequeo (3) de ese gate la IGNORA en silencio
  -- (es drift-tolerante por diseño) y la protección desaparece sin que nada
  -- falle. Este bloque es el que convierte ese silencio en un fallo.
  v_sigs CONSTANT text[] := ARRAY[
    'public.rpc_fiscal_document_authorize(uuid, text, date, bigint)',
    'public.rpc_fiscal_document_claim_pending(uuid, integer)',
    'public.rpc_fiscal_document_retry(uuid, integer, timestamp with time zone, text)',
    'public.rpc_fiscal_document_reject(uuid, text)',
    'public.rpc_fiscal_document_freeze_unconfirmed(uuid, bigint, text)'
  ];
  v_sig       text;
  v_offenders text[] := '{}';
BEGIN
  FOREACH v_sig IN ARRAY v_sigs LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      v_offenders := v_offenders || v_sig;
    END IF;
  END LOOP;

  IF array_length(v_offenders, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (3) FAILED: firmas cargadas en v_internal_only_fns (test_function_acl_gate.sql) que NO resuelven — el chequeo (3) de ese gate las ignora y queda apagado en silencio:\n  %\n  Arreglo: actualizar la firma en AMBOS archivos en el mismo PR.',
      array_to_string(v_offenders, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (3): las 5 firmas del gate de ACLs resuelven — el chequeo (3) sigue vivo.';
END $$;


-- ── (4) Cuerpos vivos ───────────────────────────────────────────────────────
DO $$
DECLARE
  v_authorize text;
  v_claim     text;
  v_missing   text[] := '{}';
  v_token     text;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure('public.rpc_fiscal_document_authorize(uuid, text, date, bigint)'))
  INTO   v_authorize;
  SELECT pg_get_functiondef(to_regprocedure('public.rpc_fiscal_document_claim_pending(uuid, integer)'))
  INTO   v_claim;

  FOREACH v_token IN ARRAY ARRAY['ARCA_NUMBER_MISMATCH', 'ARCA_NUMBER_COLLISION',
                                 'ARCA_NUMBER_UNRESOLVABLE', 'document_sequences'] LOOP
    IF position(v_token in v_authorize) = 0 THEN
      v_missing := v_missing || format('authorize sin "%s"', v_token);
    END IF;
  END LOOP;

  IF position('cae_submit_unconfirmed_at IS NULL' in v_claim) = 0 THEN
    -- m-1 (red team 2026-09-22): un literal SIN tipar concatenado con `||` a
    -- un text[] es AMBIGUO en Postgres (intenta parsearlo como literal de
    -- array) y explota con "malformed array literal" en vez del mensaje del
    -- gate — es decir, este mismo camino de FALLO nunca se había ejercitado.
    -- format() sin argumentos devuelve un `text` tipado (mismo patrón que la
    -- línea de arriba), que resuelve al operador correcto (anyarray||anyelement).
    v_missing := v_missing || format('claim_pending sin el predicado de congelamiento');
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (4) FAILED: los cuerpos vivos perdieron piezas del change:\n  %',
      array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (4): cuerpos vivos con el desfasaje, la colisión, el caso irresoluble, la resincronización y el predicado de congelamiento.';
END $$;


-- ── (5)-(11) Comportamiento sobre datos ─────────────────────────────────────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_email_a   text := 'fiscal-cae-numero-a@test.local';
  v_user_a    uuid := gen_random_uuid();
  v_account_a uuid;
  v_fp_a      uuid;

  v_pv_5      uuid;   -- bloque (5) desfasaje
  v_pv_6      uuid;   -- bloque (6) sin desfasaje
  v_pv_7      uuid;   -- bloque (7) colisión
  v_pv_7b     uuid;   -- bloque (7b) irresoluble
  v_pv_8      uuid;   -- bloque (8)/(9) congelamiento
  v_pv_10     uuid;   -- bloque (10) resincronización

  v_doc       uuid;
  v_doc_b     uuid;
  v_doc_sib   uuid;
  v_ret       boolean;
  v_num       bigint;
  v_status    text;
  v_cae       text;
  v_reason    text;
  v_last      bigint;
  v_count     integer;
  v_frozen_at timestamptz;
  v_frozen_2  timestamptz;
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Fiscal CAE Numero', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor — handle_new_user no corrió';
  END IF;

  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_a, '20555555559', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fp_a;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 8005, true) RETURNING id INTO v_pv_5;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 8006, true) RETURNING id INTO v_pv_6;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 8007, true) RETURNING id INTO v_pv_7;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 8017, true) RETURNING id INTO v_pv_7b;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 8008, true) RETURNING id INTO v_pv_8;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 8010, true) RETURNING id INTO v_pv_10;

  -- ═══ (5) Desfasaje: ARCA autorizó 9 y localmente estaba el 7 ═══
  INSERT INTO public.document_sequences (point_of_sale_id, comprobante_type, last_number)
  VALUES (v_pv_5, 'factura_c', 7);

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_5, 'factura_c', 8005, 7, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc;

  v_ret := public.rpc_fiscal_document_authorize(v_doc, 'CAE-DESFASAJE-01', current_date + 10, 9);

  IF v_ret IS NOT TRUE THEN
    v_failures := v_failures || '(5) authorize con desfasaje debía devolver true';
  END IF;

  SELECT number, status, cae INTO v_num, v_status, v_cae
  FROM public.fiscal_documents WHERE id = v_doc;

  IF v_num <> 9 THEN
    v_failures := v_failures || format('(5) el número debía adoptarse de ARCA (9) y quedó %s', v_num);
  END IF;
  IF v_status <> 'authorized' OR v_cae <> 'CAE-DESFASAJE-01' THEN
    v_failures := v_failures || format('(5) estado/CAE inesperados: %s / %s', v_status, v_cae);
  END IF;

  SELECT reason INTO v_reason
  FROM   public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc
  ORDER  BY occurred_at DESC LIMIT 1;

  IF v_reason IS NULL OR v_reason NOT LIKE 'ARCA_NUMBER_MISMATCH: local=7 arca=9%' THEN
    v_failures := v_failures || format('(5) el desfasaje debía quedar en document_status_history.reason; got %s', COALESCE(v_reason, '<NULL>'));
  END IF;

  SELECT last_number INTO v_last
  FROM   public.document_sequences
  WHERE  point_of_sale_id = v_pv_5 AND comprobante_type = 'factura_c';

  IF v_last <> 9 THEN
    v_failures := v_failures || format('(5) document_sequences debía resincronizarse a 9 y quedó %s', v_last);
  END IF;

  -- ═══ (6) Sin desfasaje: mismo número, y p_number NULL ═══
  INSERT INTO public.document_sequences (point_of_sale_id, comprobante_type, last_number)
  VALUES (v_pv_6, 'factura_c', 7);

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_6, 'factura_c', 8006, 7, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc;

  v_ret := public.rpc_fiscal_document_authorize(v_doc, 'CAE-IGUAL-01', current_date + 10, 7);

  SELECT number INTO v_num FROM public.fiscal_documents WHERE id = v_doc;
  SELECT reason INTO v_reason FROM public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc
  ORDER  BY occurred_at DESC LIMIT 1;
  SELECT last_number INTO v_last FROM public.document_sequences
  WHERE  point_of_sale_id = v_pv_6 AND comprobante_type = 'factura_c';

  IF v_num <> 7 OR v_reason IS NOT NULL OR v_last <> 7 THEN
    v_failures := v_failures || format('(6) número igual: no debía tocar nada; number=%s reason=%s last=%s',
                                       v_num, COALESCE(v_reason, '<NULL>'), v_last);
  END IF;

  -- p_number NULL (la llamada de 3 argumentos del backend viejo: DEFAULT NULL)
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_6, 'factura_c', 8006, 8, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc;

  v_ret := public.rpc_fiscal_document_authorize(v_doc, 'CAE-NULL-01', current_date + 10);

  SELECT number INTO v_num FROM public.fiscal_documents WHERE id = v_doc;
  SELECT reason INTO v_reason FROM public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc
  ORDER  BY occurred_at DESC LIMIT 1;
  SELECT last_number INTO v_last FROM public.document_sequences
  WHERE  point_of_sale_id = v_pv_6 AND comprobante_type = 'factura_c';

  IF v_ret IS NOT TRUE OR v_num <> 8 OR v_reason IS NOT NULL OR v_last <> 7 THEN
    v_failures := v_failures || format('(6) p_number NULL (backend viejo, 3 args): debía comportarse como antes; ret=%s number=%s reason=%s last=%s',
                                       v_ret, v_num, COALESCE(v_reason, '<NULL>'), v_last);
  END IF;

  -- ═══ (7) Colisión: el número de ARCA ya lo tiene otro autorizado ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts, cae)
  VALUES (v_account_a, v_fp_a, v_pv_7, 'factura_c', 8007, 9, 1000, 'authorized', 0, 'CAE-A-YA-ESTABA')
  RETURNING id INTO v_doc;

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_7, 'factura_c', 8007, 11, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_b;

  v_ret := public.rpc_fiscal_document_authorize(v_doc_b, 'CAE-B-REAL', current_date + 10, 9);

  SELECT number, status, cae INTO v_num, v_status, v_cae
  FROM public.fiscal_documents WHERE id = v_doc_b;
  SELECT reason INTO v_reason FROM public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc_b
  ORDER  BY occurred_at DESC LIMIT 1;

  IF v_status <> 'authorized' OR v_cae <> 'CAE-B-REAL' THEN
    v_failures := v_failures || format('(7) la colisión NUNCA debe costar el CAE real; status=%s cae=%s', v_status, COALESCE(v_cae, '<NULL>'));
  END IF;
  IF v_num <> 11 THEN
    v_failures := v_failures || format('(7) con colisión se conserva el número local (11) y quedó %s', v_num);
  END IF;
  IF v_reason IS NULL OR v_reason NOT LIKE 'ARCA_NUMBER_COLLISION%' THEN
    v_failures := v_failures || format('(7) falta el rastro de la colisión; reason=%s', COALESCE(v_reason, '<NULL>'));
  END IF;

  -- ═══ (7b) Irresoluble: ni el número de ARCA ni el local están libres ═══
  -- Sin el EXCEPTION WHEN unique_violation del authorize, el índice único
  -- parcial abortaría la RPC, el CAE REAL se perdería y el próximo tick del
  -- cron pediría OTRO: segunda factura real.
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts, cae)
  VALUES (v_account_a, v_fp_a, v_pv_7b, 'factura_c', 8017, 20, 1000, 'authorized', 0, 'CAE-OCUPA-20')
  RETURNING id INTO v_doc;

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts, cae)
  VALUES (v_account_a, v_fp_a, v_pv_7b, 'factura_c', 8017, 21, 1000, 'authorized', 0, 'CAE-OCUPA-21')
  RETURNING id INTO v_doc;

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_7b, 'factura_c', 8017, 21, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_b;

  v_ret := public.rpc_fiscal_document_authorize(v_doc_b, 'CAE-IRRESOLUBLE', current_date + 10, 20);

  SELECT status, cae, number, cae_submit_unconfirmed_at, arca_requested_number
  INTO   v_status, v_cae, v_num, v_frozen_at, v_last
  FROM   public.fiscal_documents WHERE id = v_doc_b;

  IF v_ret IS NOT FALSE THEN
    v_failures := v_failures || '(7b) el caso irresoluble no transiciona: authorize debe devolver false';
  END IF;
  IF v_cae <> 'CAE-IRRESOLUBLE' THEN
    v_failures := v_failures || format('(7b) el CAE real debía guardarse igual; cae=%s', COALESCE(v_cae, '<NULL>'));
  END IF;
  IF v_status <> 'pending_cae' THEN
    v_failures := v_failures || format('(7b) el estado no debía transicionar; status=%s', v_status);
  END IF;
  IF v_frozen_at IS NULL THEN
    v_failures := v_failures || '(7b) el documento debía quedar CONGELADO (cae_submit_unconfirmed_at)';
  END IF;
  IF v_last <> 20 THEN
    v_failures := v_failures || format('(7b) arca_requested_number debía quedar en 20; got %s', COALESCE(v_last::text, '<NULL>'));
  END IF;

  SELECT count(*) INTO v_count FROM public.rpc_fiscal_document_claim_pending(v_doc_b, 10);
  IF v_count <> 0 THEN
    v_failures := v_failures || format('(7b) un documento irresoluble NO debe ser reclamable; claim devolvió %s filas', v_count);
  END IF;

  -- ═══ (8) El congelamiento congela (con control positivo) ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_8, 'factura_c', 8008, 51, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc;

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_8, 'factura_c', 8008, 52, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_sib;

  -- Control positivo PRIMERO: el hermano sin congelar SÍ se reclama. Sin esto,
  -- el bloque podría pasar porque el fixture era inválido (claim devolviendo 0
  -- por cualquier otra razón del predicado).
  SELECT count(*) INTO v_count FROM public.rpc_fiscal_document_claim_pending(v_doc_sib, 10);
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(8) control positivo: el hermano sin congelar debía reclamarse (1 fila) y dio %s', v_count);
  END IF;

  v_ret := public.rpc_fiscal_document_freeze_unconfirmed(v_doc, 51, '[CAE_SUBMIT_UNCONFIRMED] Read timed out');
  IF v_ret IS NOT TRUE THEN
    v_failures := v_failures || '(8) freeze_unconfirmed debía devolver true la primera vez';
  END IF;

  SELECT count(*) INTO v_count FROM public.rpc_fiscal_document_claim_pending(v_doc, 10);
  IF v_count <> 0 THEN
    v_failures := v_failures || format('(8) un documento congelado NO debe ser reclamable; claim devolvió %s filas', v_count);
  END IF;

  SELECT status, attempts, next_attempt_at IS NULL, arca_requested_number
  INTO   v_status, v_count, v_ret, v_last
  FROM   public.fiscal_documents WHERE id = v_doc;

  IF v_status <> 'pending_cae' THEN
    v_failures := v_failures || format('(8) el congelado sigue pending_cae (no sabemos si ARCA autorizó); status=%s', v_status);
  END IF;
  IF v_count <> 0 THEN
    v_failures := v_failures || format('(8) el freno es estructural: attempts no se toca; attempts=%s', v_count);
  END IF;
  IF v_last <> 51 THEN
    v_failures := v_failures || format('(8) arca_requested_number debía quedar en 51; got %s', COALESCE(v_last::text, '<NULL>'));
  END IF;

  -- ═══ (9) Idempotencias ═══
  SELECT cae_submit_unconfirmed_at INTO v_frozen_at
  FROM public.fiscal_documents WHERE id = v_doc;

  v_ret := public.rpc_fiscal_document_freeze_unconfirmed(v_doc, 99, 'otro detalle');
  IF v_ret IS NOT FALSE THEN
    v_failures := v_failures || '(9) freeze_unconfirmed sobre un doc ya congelado debía devolver false';
  END IF;

  SELECT cae_submit_unconfirmed_at, arca_requested_number INTO v_frozen_2, v_last
  FROM public.fiscal_documents WHERE id = v_doc;

  IF v_frozen_2 <> v_frozen_at OR v_last <> 51 THEN
    v_failures := v_failures || '(9) freeze_unconfirmed no debe repisar la marca previa ni el número pedido';
  END IF;

  -- authorize sobre un doc ya authorized → false y sin segunda fila de historial
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_8, 'factura_c', 8008, 60, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_b;

  v_ret := public.rpc_fiscal_document_authorize(v_doc_b, 'CAE-IDEMP-01', current_date + 10, 60);
  v_ret := public.rpc_fiscal_document_authorize(v_doc_b, 'CAE-IDEMP-02', current_date + 10, 61);

  IF v_ret IS NOT FALSE THEN
    v_failures := v_failures || '(9) authorize sobre un doc ya authorized debía devolver false';
  END IF;

  SELECT count(*) INTO v_count
  FROM   public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc_b;

  IF v_count <> 1 THEN
    v_failures := v_failures || format('(9) el segundo authorize no debe agregar historial; filas=%s', v_count);
  END IF;

  SELECT cae INTO v_cae FROM public.fiscal_documents WHERE id = v_doc_b;
  IF v_cae <> 'CAE-IDEMP-01' THEN
    v_failures := v_failures || format('(9) el segundo authorize no debe repisar el CAE; cae=%s', v_cae);
  END IF;

  -- ═══ (10) Resincronización SOLO hacia adelante ═══
  INSERT INTO public.document_sequences (point_of_sale_id, comprobante_type, last_number)
  VALUES (v_pv_10, 'factura_c', 9);

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_a, v_fp_a, v_pv_10, 'factura_c', 8010, 8, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc;

  v_ret := public.rpc_fiscal_document_authorize(v_doc, 'CAE-ATRAS-01', current_date + 10, 5);

  SELECT last_number INTO v_last FROM public.document_sequences
  WHERE  point_of_sale_id = v_pv_10 AND comprobante_type = 'factura_c';
  SELECT number INTO v_num FROM public.fiscal_documents WHERE id = v_doc;

  IF v_last <> 9 THEN
    v_failures := v_failures || format('(10) el contador NUNCA baja (retroceder re-entregaría un número ya usado); last=%s', v_last);
  END IF;
  IF v_num <> 5 THEN
    v_failures := v_failures || format('(10) el número del comprobante sigue siendo el de ARCA; number=%s', v_num);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (5)-(10) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (5)-(10): desfasaje persistido y resincronizado, número igual y p_number NULL sin efecto, colisión sin perder el CAE, caso irresoluble congelado con el CAE guardado, congelamiento con control positivo, idempotencias y resincronización sólo hacia adelante.';

  -- ═══ (11) Limpieza verificada ═══
  DELETE FROM public.document_status_history WHERE account_id = v_account_a;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account_a;
  DELETE FROM public.document_sequences
  WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account_a);
  DELETE FROM public.points_of_sale          WHERE account_id = v_account_a;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account_a;

  SELECT count(*) INTO v_count FROM public.fiscal_documents WHERE account_id = v_account_a;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (11) FAILED: quedaron % fiscal_documents del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.document_status_history WHERE account_id = v_account_a;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (11) FAILED: quedaron % filas de document_status_history del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.document_sequences ds
  JOIN public.points_of_sale pos ON pos.id = ds.point_of_sale_id
  WHERE pos.account_id = v_account_a;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (11) FAILED: quedaron % document_sequences del fixture', v_count;
  END IF;

  SET session_replication_role = replica;
  DELETE FROM public.account_members WHERE account_id = v_account_a;
  DELETE FROM public.accounts        WHERE id = v_account_a;
  DELETE FROM public.profiles        WHERE id = v_user_a;
  DELETE FROM auth.users             WHERE id = v_user_a;
  SET session_replication_role = DEFAULT;

  RAISE NOTICE 'PASS (11): limpieza verificada — cero filas residuales del fixture.';

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      DELETE FROM public.document_status_history WHERE account_id = v_account_a;
      DELETE FROM public.fiscal_documents        WHERE account_id = v_account_a;
      DELETE FROM public.document_sequences
      WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account_a);
      DELETE FROM public.points_of_sale          WHERE account_id = v_account_a;
      DELETE FROM public.fiscal_profiles         WHERE account_id = v_account_a;
      SET session_replication_role = replica;
      DELETE FROM public.account_members WHERE account_id = v_account_a;
      DELETE FROM public.accounts        WHERE id = v_account_a;
      DELETE FROM public.profiles        WHERE id = v_user_a;
      DELETE FROM auth.users             WHERE id = v_user_a;
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- ── (12) G9: un CUIT no puede tener el mismo PV activo en dos cuentas ───────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_email_a   text := 'fiscal-cae-g9-a@test.local';
  v_email_b   text := 'fiscal-cae-g9-b@test.local';
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_account_a uuid;
  v_account_b uuid;
  v_fp_a      uuid;
  v_fp_b      uuid;
  v_pv_a      uuid;
  v_pv_b      uuid;
  v_cuit      text := '20666666663';
  v_otro_cuit text := '27888888884';
  v_state     text;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate G9 A', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate G9 B', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED (12): no se pudieron resolver las dos cuentas';
  END IF;

  -- Cuenta A: el CUIT y el PV 9101 activo.
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_a, v_cuit, 'monotributista', 'produccion', true) RETURNING id INTO v_fp_a;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_a, v_account_a, 9101, true) RETURNING id INTO v_pv_a;

  -- Cuenta B con OTRO CUIT: el mismo número de PV es legítimo (ARCA numera por
  -- CUIT + PV, así que dos CUIT distintos no comparten secuencia).
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_b, v_otro_cuit, 'monotributista', 'produccion', true) RETURNING id INTO v_fp_b;

  BEGIN
    INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
    VALUES (v_fp_b, v_account_b, 9101, true) RETURNING id INTO v_pv_b;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(12) con CUIT distinto el mismo número de PV debe aceptarse; se rechazó con %s', v_state);
  END IF;

  -- Mismo CUIT + mismo PV activo en otra cuenta → P0435.
  BEGIN
    UPDATE public.fiscal_profiles SET cuit = v_cuit WHERE id = v_fp_b;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0435' THEN
    v_failures := v_failures || format('(12) cambiar el CUIT del perfil para que colisione debía dar P0435; got %s', v_state);
  END IF;

  -- El PV inactivo no compite por la numeración de ARCA.
  UPDATE public.points_of_sale SET is_active = false WHERE id = v_pv_b;
  BEGIN
    UPDATE public.fiscal_profiles SET cuit = v_cuit WHERE id = v_fp_b;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(12) con el PV inactivo el cambio de CUIT debía aceptarse; got %s', v_state);
  END IF;

  -- Reactivar ese PV (ahora los dos perfiles comparten CUIT) → P0435.
  BEGIN
    UPDATE public.points_of_sale SET is_active = true WHERE id = v_pv_b;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0435' THEN
    v_failures := v_failures || format('(12) reactivar un PV que colisiona debía dar P0435; got %s', v_state);
  END IF;

  -- Alta directa de un PV conflictivo en la cuenta B → P0435.
  BEGIN
    INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
    VALUES (v_fp_b, v_account_b, 9101, true);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0435' THEN
    v_failures := v_failures || format('(12) el alta de un PV conflictivo debía dar P0435; got %s', v_state);
  END IF;

  -- NO TOCA FILAS EXISTENTES: con el duplicado ya vivo (lo que hoy pasa en
  -- prod), un UPDATE que no cambia número ni actividad ni perfil pasa igual —
  -- y DESACTIVARLO también, que es parte de cómo se arregla.
  SET session_replication_role = replica;
  UPDATE public.points_of_sale SET is_active = true WHERE id = v_pv_b;  -- crea el duplicado sin el guard
  SET session_replication_role = DEFAULT;

  BEGIN
    UPDATE public.points_of_sale SET branch_id = NULL WHERE id = v_pv_b;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(12) un UPDATE inocuo sobre el duplicado PREEXISTENTE no debe rechazarse; got %s', v_state);
  END IF;

  BEGIN
    UPDATE public.points_of_sale SET is_active = false WHERE id = v_pv_b;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(12) DESACTIVAR el duplicado preexistente debe poder hacerse (es la salida); got %s', v_state);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (12) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (12): G9 — mismo CUIT + mismo PV activo en dos cuentas rechazado con P0435 por los dos lados, CUIT distinto y PV inactivo aceptados, filas preexistentes intactas.';

  -- Limpieza
  DELETE FROM public.points_of_sale  WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.fiscal_profiles WHERE account_id IN (v_account_a, v_account_b);
  SET session_replication_role = replica;
  DELETE FROM public.account_members WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.accounts        WHERE id IN (v_account_a, v_account_b);
  DELETE FROM public.profiles        WHERE id IN (v_user_a, v_user_b);
  DELETE FROM auth.users             WHERE id IN (v_user_a, v_user_b);
  SET session_replication_role = DEFAULT;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      DELETE FROM public.points_of_sale  WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.fiscal_profiles WHERE account_id IN (v_account_a, v_account_b);
      SET session_replication_role = replica;
      DELETE FROM public.account_members WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.accounts        WHERE id IN (v_account_a, v_account_b);
      DELETE FROM public.profiles        WHERE id IN (v_user_a, v_user_b);
      DELETE FROM auth.users             WHERE id IN (v_user_a, v_user_b);
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- GATE FISCAL-CAE PASSED (12 bloques).
-- =============================================================================
