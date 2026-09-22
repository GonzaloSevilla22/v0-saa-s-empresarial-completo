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
-- fiscal-riesgos-residuales (20261059000001) agrega:
--
--   (13) Firma única, SECURITY DEFINER y ACLs de las 2 RPCs nuevas de la marca
--        previa (mark_submit_started / clear_submit_mark), y las 2 columnas que
--        claim_pending pasa a devolver (cae_submit_started_at,
--        receptor_iva_condition).
--   (14) Meta-candado de firmas: EXTIENDE el array del bloque (3) a las 7 RPCs
--        internas del relay (5 de #577 + las 2 nuevas), que son las mismas
--        cadenas de v_internal_only_fns en test_function_acl_gate.sql.
--        (Las ACLs de las 7 viven en el bloque (2), también extendido.)
--   (15) Cuerpos vivos: EXTIENDE el bloque (4). claim_pending devuelve la marca
--        y NO la usa como predicado de exclusión (ese error la volvería
--        inalcanzable para siempre); mark_submit_started tiene el guard de
--        marca viva; clear_submit_mark no desmarca congelados y acota la
--        re-emisión con attempts + 1.
--   (16) Comportamiento de la marca sobre datos: marcar, reclamar con la marca,
--        rechazar la segunda marca, el índice único del número en vuelo,
--        limpiar y volver al reposo, y la cota de re-emisión por attempts.
--   (17) R2 — allow-list de escritura sobre fiscal_documents y
--        document_sequences: cero INSERT/UPDATE/DELETE/TRUNCATE para
--        anon/authenticated, SELECT sólo para authenticated, y ninguna policy
--        de escritura sobre fiscal_documents.
--   (18) R2 — el trigger BEFORE INSERT existe, está habilitado y MUERDE, con la
--        matriz de evasión ejecutada (authorized / rejected / pending_cae con
--        CAE / pending_cae con marca) y el control positivo (pending_cae limpio
--        pasa).
--   (19) Limpieza verificada de los fixtures nuevos (dentro del bloque (16)).
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


-- ── (2) ACLs exactas de las 7 RPCs del relay ────────────────────────────────
DO $$
DECLARE
  v_fns CONSTANT text[] := ARRAY[
    'public.rpc_fiscal_document_authorize(uuid, text, date, bigint)',
    'public.rpc_fiscal_document_claim_pending(uuid, integer)',
    'public.rpc_fiscal_document_retry(uuid, integer, timestamp with time zone, text)',
    'public.rpc_fiscal_document_reject(uuid, text)',
    'public.rpc_fiscal_document_freeze_unconfirmed(uuid, bigint, text)',
    -- fiscal-riesgos-residuales (R1): las 2 de la marca previa. Mismo contrato
    -- que las 5 de arriba — SECURITY DEFINER, sin validación de tenencia,
    -- reciben el doc_id y escriben. mark_submit_started con EXECUTE para
    -- authenticated sería la primitiva para MARCAR un comprobante ajeno y
    -- dejarlo sin poder emitirse; clear_submit_mark, la de BORRARLE la marca a
    -- uno cuyo FECAESolicitar salió de verdad — o sea, provocar la segunda
    -- factura real que este change existe para impedir.
    'public.rpc_fiscal_document_mark_submit_started(uuid, bigint)',
    'public.rpc_fiscal_document_clear_submit_mark(uuid, text)'
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

  RAISE NOTICE 'PASS (2): las 7 RPCs del relay sin EXECUTE para anon/authenticated y con service_role.';
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
    'public.rpc_fiscal_document_freeze_unconfirmed(uuid, bigint, text)',
    -- (14) fiscal-riesgos-residuales (R1)
    'public.rpc_fiscal_document_mark_submit_started(uuid, bigint)',
    'public.rpc_fiscal_document_clear_submit_mark(uuid, text)'
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

  RAISE NOTICE 'PASS (3)+(14): las 7 firmas del gate de ACLs resuelven — el chequeo (3) sigue vivo.';
END $$;


-- ── (4) Cuerpos vivos ───────────────────────────────────────────────────────
DO $$
DECLARE
  v_authorize text;
  v_claim     text;
  v_mark      text;
  v_clear     text;
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

  -- ── (15) fiscal-riesgos-residuales (R1) ────────────────────────────────────
  -- claim_pending TIENE que devolver la marca: sin la columna, el processor no
  -- puede saber que el documento ya tiene un envío en curso y vuelve a pedir un
  -- CAE nuevo — que es exactamente el riesgo R1.
  IF position('fd.cae_submit_started_at' in v_claim) = 0 THEN
    v_missing := v_missing || format('claim_pending no devuelve cae_submit_started_at (el relay no podría reconciliar y re-emitiría)');
  END IF;

  -- OQ-3: el único camino de emisión pasa por acá. Sin esta columna llega None
  -- al adapter y ARCA recibe siempre CondicionIVAReceptorId=5.
  IF position('fd.receptor_iva_condition' in v_claim) = 0 THEN
    v_missing := v_missing || format('claim_pending no devuelve receptor_iva_condition (ARCA recibiría siempre consumidor final)');
  END IF;

  -- Candado contra el error "obvio": excluir del claim a los documentos
  -- MARCADOS. Parece la defensa natural y es lo contrario — un documento cuyo
  -- proceso murió quedaría inalcanzable PARA SIEMPRE (ni se reconcilia ni se
  -- emite). La marca no excluye; lo que cambia es qué se hace con el documento.
  IF position('cae_submit_started_at IS NULL' in v_claim) > 0 THEN
    v_missing := v_missing || format('claim_pending EXCLUYE a los marcados (cae_submit_started_at IS NULL en el WHERE): quedarían inalcanzables para siempre');
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.rpc_fiscal_document_mark_submit_started(uuid, bigint)'))
  INTO   v_mark;
  SELECT pg_get_functiondef(to_regprocedure('public.rpc_fiscal_document_clear_submit_mark(uuid, text)'))
  INTO   v_clear;

  IF v_mark IS NULL THEN
    v_missing := v_missing || format('rpc_fiscal_document_mark_submit_started NO EXISTE');
  ELSIF position('cae_submit_started_at IS NULL' in v_mark) = 0 THEN
    -- Sin este guard, marcar dos veces pisaría el número de un envío que puede
    -- estar en vuelo y la reconciliación consultaría en ARCA el número equivocado.
    v_missing := v_missing || format('mark_submit_started sin el guard de marca viva (cae_submit_started_at IS NULL)');
  END IF;

  IF v_clear IS NULL THEN
    v_missing := v_missing || format('rpc_fiscal_document_clear_submit_mark NO EXISTE');
  ELSE
    IF position('cae_submit_unconfirmed_at IS NULL' in v_clear) = 0 THEN
      v_missing := v_missing || format('clear_submit_mark sin el guard de congelados: desmarcaría un congelado por la vía automática');
    END IF;
    IF position('attempts + 1' in v_clear) = 0 THEN
      -- La cota de la re-emisión: claim_pending exige attempts < p_max_attempts,
      -- así que el ciclo marca → 602 → limpieza → marca no puede volverse infinito.
      v_missing := v_missing || format('clear_submit_mark sin attempts + 1: la re-emisión dejaría de estar acotada');
    END IF;
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (4)+(15) FAILED: los cuerpos vivos perdieron piezas del change:\n  %',
      array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (4)+(15): cuerpos vivos con el desfasaje, la colisión, el caso irresoluble, la resincronización, el predicado de congelamiento, la marca previa devuelta (y NO usada para excluir) y los guards de mark/clear.';
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
  -- fiscal-riesgos-residuales (R2): el trigger trg_guard_fiscal_document_insert_interno
  -- rechaza con P0436 cualquier INSERT que no nazca pending_cae y sin CAE. Este
  -- fixture necesita sembrar el estado FINAL de un comprobante ya emitido, que
  -- por el camino legítimo se alcanza con un UPDATE del relay. Se elude con
  -- session_replication_role = replica, el mismo patrón que este archivo ya usa
  -- en sus bloques de limpieza — y la elusión es DELIBERADA y acotada a la
  -- sembrada, no un rol exento en el trigger (eso lo volvería inverificable).
  SET session_replication_role = replica;
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts, cae)
  VALUES (v_account_a, v_fp_a, v_pv_7, 'factura_c', 8007, 9, 1000, 'authorized', 0, 'CAE-A-YA-ESTABA')
  RETURNING id INTO v_doc;
  SET session_replication_role = DEFAULT;

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
  -- R2: misma elusión acotada que el bloque (7) — ver el comentario de arriba.
  SET session_replication_role = replica;
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts, cae)
  VALUES (v_account_a, v_fp_a, v_pv_7b, 'factura_c', 8017, 20, 1000, 'authorized', 0, 'CAE-OCUPA-20')
  RETURNING id INTO v_doc;

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts, cae)
  VALUES (v_account_a, v_fp_a, v_pv_7b, 'factura_c', 8017, 21, 1000, 'authorized', 0, 'CAE-OCUPA-21')
  RETURNING id INTO v_doc;
  SET session_replication_role = DEFAULT;

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

-- ── (13) R1: firma, SECURITY DEFINER y ACLs de las 2 RPCs de la marca previa,
--        y las 2 columnas que claim_pending pasa a devolver ──────────────────
DO $$
DECLARE
  v_fns CONSTANT text[] := ARRAY[
    'public.rpc_fiscal_document_mark_submit_started(uuid, bigint)',
    'public.rpc_fiscal_document_clear_submit_mark(uuid, text)'
  ];
  v_names CONSTANT text[] := ARRAY[
    'rpc_fiscal_document_mark_submit_started',
    'rpc_fiscal_document_clear_submit_mark'
  ];
  v_has_anon  boolean;
  v_sig       text;
  v_oid       oid;
  v_count     integer;
  v_secdef    boolean;
  v_result    text;
  v_offenders text[] := '{}';
  i           integer;
BEGIN
  v_has_anon := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon');

  FOR i IN 1 .. array_length(v_fns, 1) LOOP
    v_sig := v_fns[i];

    SELECT count(*) INTO v_count
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_names[i];

    IF v_count <> 1 THEN
      v_offenders := v_offenders || format('%s: se esperaba UNA sola definición y hay %s (un overload es el 42725 de siempre)', v_names[i], v_count);
      CONTINUE;
    END IF;

    v_oid := to_regprocedure(v_sig);
    IF v_oid IS NULL THEN
      v_offenders := v_offenders || format('%s NO EXISTE con esa firma', v_sig);
      CONTINUE;
    END IF;

    SELECT prosecdef INTO v_secdef FROM pg_proc WHERE oid = v_oid;
    IF NOT v_secdef THEN
      v_offenders := v_offenders || format('%s dejó de ser SECURITY DEFINER (el relay corre con service conn y fiscal_documents no tiene policy de UPDATE)', v_sig);
    END IF;

    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_offenders := v_offenders || format('%s ejecutable por authenticated', v_sig);
    END IF;
    IF v_has_anon AND has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_offenders := v_offenders || format('%s ejecutable por anon', v_sig);
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_offenders := v_offenders || format('%s SIN EXECUTE para service_role (el relay dejaría de poder marcar y NINGÚN comprobante se emitiría)', v_sig);
    END IF;
  END LOOP;

  -- El tipo de retorno de claim_pending es parte del contrato con el relay: si
  -- pierde cae_submit_started_at, el processor no ve la marca y vuelve a pedir
  -- un CAE nuevo (R1). DROP+CREATE con una columna de menos no falla en ningún
  -- otro lado — asyncpg simplemente no traería la clave.
  SELECT pg_get_function_result(to_regprocedure('public.rpc_fiscal_document_claim_pending(uuid, integer)'))
  INTO   v_result;

  IF v_result IS NULL THEN
    v_offenders := v_offenders || format('rpc_fiscal_document_claim_pending(uuid, integer) NO EXISTE');
  ELSE
    IF position('cae_submit_started_at' in v_result) = 0 THEN
      v_offenders := v_offenders || format('claim_pending no DEVUELVE cae_submit_started_at: %s', v_result);
    END IF;
    IF position('receptor_iva_condition' in v_result) = 0 THEN
      v_offenders := v_offenders || format('claim_pending no DEVUELVE receptor_iva_condition (OQ-3): %s', v_result);
    END IF;
  END IF;

  IF array_length(v_offenders, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (13) FAILED: las RPCs de la marca previa (R1).\n  %\n  Contexto: mark_submit_started es la que hace que un FECAESolicitar NUNCA salga sin marca commiteada, y clear_submit_mark la única que borra esa marca. Con EXECUTE para authenticated, la segunda es la primitiva para provocar a mano la segunda factura real que este change impide.',
      array_to_string(v_offenders, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (13): las 2 RPCs de la marca previa con firma única, SECURITY DEFINER y sin EXECUTE para anon/authenticated; claim_pending devuelve la marca y la condición IVA del receptor.';
END $$;


-- ── (16)+(19) R1: comportamiento de la marca sobre datos ────────────────────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_email_m   text := 'fiscal-marca-previa@test.local';
  v_user_m    uuid := gen_random_uuid();
  v_account_m uuid;
  v_fp_m      uuid;

  v_pv_a      uuid;   -- marcado / limpieza / cota
  v_pv_u      uuid;   -- índice único del número en vuelo
  v_pv_f      uuid;   -- congelado

  v_doc1      uuid;   -- marcar → reclamar → limpiar
  v_doc2      uuid;   -- número NULL / clear sin marca
  v_doc3      uuid;   -- authorized → no se marca
  v_doc4      uuid;   -- índice único (primero)
  v_doc5      uuid;   -- índice único (segundo, colisiona)
  v_doc6      uuid;   -- congelado + marcado
  v_doc7      uuid;   -- cota de re-emisión
  v_doc8      uuid;   -- rechazo SIN marca (control positivo)
  v_doc9      uuid;   -- rechazo CON marca → P0438
  v_doc10     uuid;   -- rechazo de un congelado SIN marca previa (estilo #577)

  v_ret       boolean;
  v_state     text;
  v_started   timestamptz;
  v_req       bigint;
  v_attempts  integer;
  v_count     integer;
  v_last_err  text;
  v_cond      text;
  i           integer;
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_m, 'authenticated', 'authenticated', v_email_m, now(), now(),
          jsonb_build_object('name', 'Gate Fiscal Marca Previa', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_m
  FROM   public.account_members WHERE user_id = v_user_m ORDER BY created_at LIMIT 1;

  IF v_account_m IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED (16): no se pudo resolver account para el anchor — handle_new_user no corrió';
  END IF;

  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_m, '20555555560', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fp_m;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_m, v_account_m, 8020, true) RETURNING id INTO v_pv_a;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_m, v_account_m, 8021, true) RETURNING id INTO v_pv_u;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_m, v_account_m, 8022, true) RETURNING id INTO v_pv_f;

  -- ═══ (16.a) Marcar un pending_cae limpio, y reclamarlo CON la marca ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts, receptor_iva_condition)
  VALUES (v_account_m, v_fp_m, v_pv_a, 'factura_c', 8020, 1, 1000, 'pending_cae', 0, 'monotributista')
  RETURNING id INTO v_doc1;

  v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc1, 101);
  IF v_ret IS NOT TRUE THEN
    v_failures := v_failures || '(16.a) mark_submit_started sobre un pending_cae limpio debía devolver true';
  END IF;

  SELECT cae_submit_started_at, arca_requested_number
  INTO   v_started, v_req
  FROM   public.fiscal_documents WHERE id = v_doc1;

  IF v_started IS NULL OR v_req <> 101 THEN
    v_failures := v_failures || format('(16.a) la marca debía quedar persistida; started=%s requested=%s',
                                       COALESCE(v_started::text, '<NULL>'), COALESCE(v_req::text, '<NULL>'));
  END IF;

  -- El documento MARCADO se sigue reclamando (si no, quedaría inalcanzable), y
  -- la fila que devuelve trae la marca — es el dato con el que el processor
  -- decide reconciliar en vez de pedir un CAE nuevo.
  SELECT count(*), max(cae_submit_started_at), max(arca_requested_number), max(receptor_iva_condition)
  INTO   v_count, v_started, v_req, v_cond
  FROM   public.rpc_fiscal_document_claim_pending(v_doc1, 10);

  IF v_count <> 1 THEN
    v_failures := v_failures || format('(16.a) un documento MARCADO debe seguir siendo reclamable (para reconciliarlo); claim devolvió %s filas', v_count);
  END IF;
  IF v_started IS NULL OR v_req <> 101 THEN
    v_failures := v_failures || '(16.a) claim_pending debe devolver la marca (cae_submit_started_at + arca_requested_number)';
  END IF;
  IF v_cond IS DISTINCT FROM 'monotributista' THEN
    v_failures := v_failures || format('(16.a, OQ-3) claim_pending debe devolver receptor_iva_condition; got %s', COALESCE(v_cond, '<NULL>'));
  END IF;

  -- ═══ (16.b) Segunda marca sobre el mismo documento → P0437 ═══
  BEGIN
    v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc1, 102);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0437' THEN
    v_failures := v_failures || format('(16.b) una segunda marca (envío ya en curso) debía dar P0437; got %s', v_state);
  END IF;

  SELECT arca_requested_number INTO v_req FROM public.fiscal_documents WHERE id = v_doc1;
  IF v_req <> 101 THEN
    v_failures := v_failures || format('(16.b) la segunda marca NO debe pisar el número en vuelo; requested=%s', COALESCE(v_req::text, '<NULL>'));
  END IF;

  -- ═══ (16.c) Marcar sin número → P0437 (no se marca un envío sin número) ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_a, 'factura_c', 8020, 2, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc2;

  BEGIN
    v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc2, NULL);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0437' THEN
    v_failures := v_failures || format('(16.c) marcar con p_arca_requested_number NULL debía dar P0437; got %s', v_state);
  END IF;

  SELECT cae_submit_started_at INTO v_started FROM public.fiscal_documents WHERE id = v_doc2;
  IF v_started IS NOT NULL THEN
    v_failures := v_failures || '(16.c) una marca sin número no debe dejar rastro';
  END IF;

  -- ═══ (16.d) Documento inexistente → P0437 ═══
  BEGIN
    v_ret := public.rpc_fiscal_document_mark_submit_started(gen_random_uuid(), 1);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0437' THEN
    v_failures := v_failures || format('(16.d) marcar un documento inexistente debía dar P0437; got %s', v_state);
  END IF;

  -- ═══ (16.e) Documento ya authorized → P0437 ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_a, 'factura_c', 8020, 3, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc3;

  v_ret := public.rpc_fiscal_document_authorize(v_doc3, 'CAE-MARCA-YA-AUTH', current_date + 10, 3);

  BEGIN
    v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc3, 3);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0437' THEN
    v_failures := v_failures || format('(16.e) marcar un documento ya authorized debía dar P0437; got %s', v_state);
  END IF;

  -- ═══ (16.f) Dos documentos del mismo PV/tipo con el mismo número EN VUELO ═══
  -- Hoy el relay es serial y no puede pasar; el índice único parcial hace que,
  -- si algún día deja de serlo, el segundo falle al MARCAR (sin enviar nada) en
  -- vez de pedirle a ARCA un número que otro documento ya tiene en vuelo.
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_u, 'factura_c', 8021, 1, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc4;

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_u, 'factura_c', 8021, 2, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc5;

  v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc4, 500);
  IF v_ret IS NOT TRUE THEN
    v_failures := v_failures || '(16.f) control positivo: la PRIMERA marca del número 500 debía pasar';
  END IF;

  BEGIN
    v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc5, 500);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> '23505' THEN
    v_failures := v_failures || format('(16.f) marcar el MISMO número en vuelo en el mismo PV debía violar fiscal_documents_submit_mark_uq (23505); got %s', v_state);
  END IF;

  -- ═══ (16.g) Limpiar la marca: vuelve al reposo, con attempts + 1 ═══
  v_ret := public.rpc_fiscal_document_clear_submit_mark(v_doc1, 'ARCA_602: no existen datos en nuestros registros (ultimo=100 < 101)');
  IF v_ret IS NOT TRUE THEN
    v_failures := v_failures || '(16.g) clear_submit_mark sobre un marcado debía devolver true';
  END IF;

  SELECT cae_submit_started_at, arca_requested_number, attempts, last_error
  INTO   v_started, v_req, v_attempts, v_last_err
  FROM   public.fiscal_documents WHERE id = v_doc1;

  IF v_started IS NOT NULL OR v_req IS NOT NULL THEN
    v_failures := v_failures || '(16.g) clear_submit_mark debía dejar la marca y el número en NULL';
  END IF;
  IF v_attempts <> 1 THEN
    v_failures := v_failures || format('(16.g) clear_submit_mark debía incrementar attempts (cota de la re-emisión); attempts=%s', v_attempts);
  END IF;
  IF v_last_err IS NULL OR position('ARCA_602' in v_last_err) = 0 THEN
    v_failures := v_failures || format('(16.g) el detalle de ARCA debía quedar en last_error; got %s', COALESCE(v_last_err, '<NULL>'));
  END IF;

  -- next_attempt_at = now() ⇒ el PRÓXIMO tick lo toma, ya sin marca.
  SELECT count(*), max(cae_submit_started_at)
  INTO   v_count, v_started
  FROM   public.rpc_fiscal_document_claim_pending(v_doc1, 10);

  IF v_count <> 1 OR v_started IS NOT NULL THEN
    v_failures := v_failures || format('(16.g) tras la limpieza el documento debe volver al reposo y ser reclamable SIN marca; filas=%s started=%s',
                                       v_count, COALESCE(v_started::text, '<NULL>'));
  END IF;

  -- ═══ (16.h) clear sobre un documento SIN marca → false, sin efectos ═══
  SELECT attempts INTO v_attempts FROM public.fiscal_documents WHERE id = v_doc2;

  v_ret := public.rpc_fiscal_document_clear_submit_mark(v_doc2, 'no debería tocar nada');
  IF v_ret IS NOT FALSE THEN
    v_failures := v_failures || '(16.h) clear_submit_mark sobre un documento sin marca debía devolver false';
  END IF;

  SELECT attempts, last_error INTO v_count, v_last_err FROM public.fiscal_documents WHERE id = v_doc2;
  IF v_count <> v_attempts OR v_last_err IS NOT NULL THEN
    v_failures := v_failures || format('(16.h) clear_submit_mark sin marca no debe tener efectos; attempts %s→%s last_error=%s',
                                       v_attempts, v_count, COALESCE(v_last_err, '<NULL>'));
  END IF;

  -- ═══ (16.i) Un CONGELADO marcado: no se reclama y NO se desmarca ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_f, 'factura_c', 8022, 1, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc6;

  v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc6, 700);
  v_ret := public.rpc_fiscal_document_freeze_unconfirmed(v_doc6, 700, '[CAE_SUBMIT_UNCONFIRMED] respuesta ilegible');

  SELECT count(*) INTO v_count FROM public.rpc_fiscal_document_claim_pending(v_doc6, 10);
  IF v_count <> 0 THEN
    v_failures := v_failures || format('(16.i) un congelado (aunque esté marcado) NO debe reclamarse; claim devolvió %s filas', v_count);
  END IF;

  v_ret := public.rpc_fiscal_document_clear_submit_mark(v_doc6, 'intento de desmarcar un congelado');
  IF v_ret IS NOT FALSE THEN
    v_failures := v_failures || '(16.i) clear_submit_mark NO debe desmarcar un congelado (devolver false)';
  END IF;

  SELECT cae_submit_started_at, arca_requested_number
  INTO   v_started, v_req
  FROM   public.fiscal_documents WHERE id = v_doc6;

  IF v_started IS NULL OR v_req <> 700 THEN
    v_failures := v_failures || '(16.i) la marca de un congelado debe sobrevivir (es el rastro para resolverlo a mano)';
  END IF;

  -- ═══ (16.j) La re-emisión está ACOTADA por attempts ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_a, 'factura_c', 8020, 4, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc7;

  FOR i IN 1 .. 9 LOOP
    v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc7, 900 + i);
    v_ret := public.rpc_fiscal_document_clear_submit_mark(v_doc7, format('ciclo %s', i));
  END LOOP;

  SELECT attempts INTO v_attempts FROM public.fiscal_documents WHERE id = v_doc7;
  IF v_attempts <> 9 THEN
    v_failures := v_failures || format('(16.j) tras 9 ciclos marca→limpieza attempts debía ser 9; got %s', v_attempts);
  END IF;

  -- Control positivo: con attempts = 9 todavía se reclama.
  SELECT count(*) INTO v_count FROM public.rpc_fiscal_document_claim_pending(v_doc7, 10);
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(16.j) control positivo: con attempts=9 el documento todavía debe reclamarse; filas=%s', v_count);
  END IF;

  v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc7, 910);
  v_ret := public.rpc_fiscal_document_clear_submit_mark(v_doc7, 'ciclo 10');

  SELECT count(*) INTO v_count FROM public.rpc_fiscal_document_claim_pending(v_doc7, 10);
  IF v_count <> 0 THEN
    v_failures := v_failures || format('(16.j) con attempts=10 el ciclo marca→602→limpieza→marca debe cortarse; filas=%s', v_count);
  END IF;

  -- ═══ (16.k) MAJOR 2 (c): `rejected` PROHIBIDO sobre un envío que salió ═════
  -- `rpc_fiscal_document_reject` no tenía más guard que `status='pending_cae'`,
  -- así que dejaba TERMINAL un documento cuyo número ya se le pidió a ARCA — y
  -- también uno CONGELADO, congelado justamente porque no sabemos si ARCA lo
  -- autorizó. Es el CHOKE POINT: cubre de una vez los tres caminos que el red
  -- team encontró (el guard de ambiente, el error ordinario y una llamada
  -- manual), mismo patrón que `cuenta-corriente-party-guard` usó con
  -- `c30_get_or_create_*`.

  -- (16.k.1) CONTROL POSITIVO: sin marca, el rechazo sigue funcionando. Sin
  -- este caso el guard podría ser "no rechazar nunca" y nadie lo notaría.
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_a, 'factura_c', 8020, 5, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc8;

  v_ret := public.rpc_fiscal_document_reject(v_doc8, '[WSFE_ERROR] sin marca: se rechaza');
  IF v_ret IS NOT TRUE THEN
    v_failures := v_failures || '(16.k.1) control positivo: un pending_cae SIN marca se sigue rechazando';
  END IF;

  SELECT status INTO v_state FROM public.fiscal_documents WHERE id = v_doc8;
  IF v_state <> 'rejected' THEN
    v_failures := v_failures || format('(16.k.1) el documento sin marca debía quedar rejected; got %s', v_state);
  END IF;

  -- (16.k.2) Con la marca viva → P0438, y el documento NO se mueve.
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_a, 'factura_c', 8020, 6, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc9;

  v_ret := public.rpc_fiscal_document_mark_submit_started(v_doc9, 500);

  BEGIN
    v_ret := public.rpc_fiscal_document_reject(v_doc9, '[WSFE_ERROR] tope de intentos');
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0438' THEN
    v_failures := v_failures || format('(16.k.2) rechazar un documento con la marca viva debía dar P0438; got %s', v_state);
  END IF;

  SELECT status INTO v_state FROM public.fiscal_documents WHERE id = v_doc9;
  IF v_state <> 'pending_cae' THEN
    v_failures := v_failures || format('(16.k.2) el documento marcado NO debe moverse de pending_cae; got %s', v_state);
  END IF;

  -- (16.k.3) Un CONGELADO tampoco se rechaza. El congelamiento protegía contra
  -- `claim_pending`, no contra el rechazo: v_doc6 quedó congelado en (16.i).
  BEGIN
    v_ret := public.rpc_fiscal_document_reject(v_doc6, '[WSFE_ERROR] rechazo de un congelado');
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0438' THEN
    v_failures := v_failures || format('(16.k.3) rechazar un CONGELADO debía dar P0438; got %s', v_state);
  END IF;

  SELECT status INTO v_state FROM public.fiscal_documents WHERE id = v_doc6;
  IF v_state <> 'pending_cae' THEN
    v_failures := v_failures || format('(16.k.3) el congelado NO debe quedar rejected; got %s', v_state);
  END IF;

  -- (16.k.4) Congelado SIN marca previa: la SEGUNDA mitad del predicado tiene
  -- que ser load-bearing por sí sola. No es un caso sintético — un comprobante
  -- congelado entre el deploy de #577 y el de este change tiene
  -- cae_submit_unconfirmed_at puesto y cae_submit_started_at NULL, porque esa
  -- columna todavía no existía. Sin este caso, un guard que mirara sólo la
  -- marca previa pasaría el gate igual (v_doc6 tiene las dos).
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account_m, v_fp_m, v_pv_f, 'factura_c', 8022, 9, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc10;

  UPDATE public.fiscal_documents
  SET cae_submit_unconfirmed_at = now(),
      arca_requested_number     = 800,
      cae_submit_started_at     = NULL
  WHERE id = v_doc10;

  BEGIN
    v_ret := public.rpc_fiscal_document_reject(v_doc10, '[WSFE_ERROR] congelado al estilo #577');
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  IF v_state <> 'P0438' THEN
    v_failures := v_failures || format('(16.k.4) rechazar un congelado SIN marca previa (estilo #577) debía dar P0438; got %s', v_state);
  END IF;

  SELECT status INTO v_state FROM public.fiscal_documents WHERE id = v_doc10;
  IF v_state <> 'pending_cae' THEN
    v_failures := v_failures || format('(16.k.4) el congelado sin marca previa NO debe quedar rejected; got %s', v_state);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (16) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (16): marca previa persistida y devuelta por claim_pending, segunda marca / sin número / documento inexistente / ya authorized rechazados con P0437, número en vuelo único por PV, limpieza con attempts+1 y vuelta al reposo, congelado no desmarcable, re-emisión acotada y rechazo prohibido (P0438) sobre marcado y congelado con control positivo.';

  -- ═══ (19) Limpieza verificada ═══
  DELETE FROM public.document_status_history WHERE account_id = v_account_m;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account_m;
  DELETE FROM public.document_sequences
  WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account_m);
  DELETE FROM public.points_of_sale          WHERE account_id = v_account_m;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account_m;

  SELECT count(*) INTO v_count FROM public.fiscal_documents WHERE account_id = v_account_m;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (19) FAILED: quedaron % fiscal_documents del fixture de la marca previa', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.document_status_history WHERE account_id = v_account_m;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (19) FAILED: quedaron % filas de document_status_history del fixture de la marca previa', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.document_sequences ds
  JOIN public.points_of_sale pos ON pos.id = ds.point_of_sale_id
  WHERE pos.account_id = v_account_m;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (19) FAILED: quedaron % document_sequences del fixture de la marca previa', v_count;
  END IF;

  SET session_replication_role = replica;
  DELETE FROM public.account_members WHERE account_id = v_account_m;
  DELETE FROM public.accounts        WHERE id = v_account_m;
  DELETE FROM public.profiles        WHERE id = v_user_m;
  DELETE FROM auth.users             WHERE id = v_user_m;
  SET session_replication_role = DEFAULT;

  RAISE NOTICE 'PASS (19): limpieza verificada — cero filas residuales del fixture de la marca previa.';

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      DELETE FROM public.document_status_history WHERE account_id = v_account_m;
      DELETE FROM public.fiscal_documents        WHERE account_id = v_account_m;
      DELETE FROM public.document_sequences
      WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account_m);
      DELETE FROM public.points_of_sale          WHERE account_id = v_account_m;
      DELETE FROM public.fiscal_profiles         WHERE account_id = v_account_m;
      SET session_replication_role = replica;
      DELETE FROM public.account_members WHERE account_id = v_account_m;
      DELETE FROM public.accounts        WHERE id = v_account_m;
      DELETE FROM public.profiles        WHERE id = v_user_m;
      DELETE FROM auth.users             WHERE id = v_user_m;
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- ── (17) R2: allow-list de escritura sobre las dos tablas fiscales ─────────
-- Éste es el bloque que atrapa un `GRANT ALL ON ALL TABLES IN SCHEMA public`
-- de una migración futura, en CI y en el PR que lo introduzca.
DO $$
DECLARE
  v_tables CONSTANT text[] := ARRAY['public.fiscal_documents', 'public.document_sequences'];
  v_writes CONSTANT text[] := ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'];
  v_has_anon  boolean;
  v_t         text;
  v_priv      text;
  v_count     integer;
  v_offenders text[] := '{}';
BEGIN
  v_has_anon := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon');

  FOREACH v_t IN ARRAY v_tables LOOP
    FOREACH v_priv IN ARRAY v_writes LOOP
      IF has_table_privilege('authenticated', v_t, v_priv) THEN
        v_offenders := v_offenders || format('authenticated conserva %s sobre %s', v_priv, v_t);
      END IF;
      IF v_has_anon AND has_table_privilege('anon', v_t, v_priv) THEN
        v_offenders := v_offenders || format('anon conserva %s sobre %s', v_priv, v_t);
      END IF;
    END LOOP;

    -- SELECT: authenticated SÍ (la pantalla y la suscripción Realtime de
    -- FiscalDocumentBadge lo necesitan — Realtime evalúa la policy de SELECT),
    -- anon NO (tenía el privilegio pero ninguna policy, así que nunca vio una
    -- fila: el cambio observable es 403 en vez de []).
    IF NOT has_table_privilege('authenticated', v_t, 'SELECT') THEN
      v_offenders := v_offenders || format('authenticated PERDIÓ el SELECT sobre %s (se rompe el badge fiscal y su Realtime)', v_t);
    END IF;
    IF v_has_anon AND has_table_privilege('anon', v_t, 'SELECT') THEN
      v_offenders := v_offenders || format('anon conserva SELECT sobre %s', v_t);
    END IF;
  END LOOP;

  -- Ninguna policy de escritura sobre fiscal_documents. Sin el GRANT la policy
  -- ya sería letra muerta, pero dejarla puesta es una trampa: un re-GRANT
  -- accidental la reactiva sola. Con la policy borrada, un re-GRANT choca
  -- contra RLS sin policy ⇒ cero filas insertables.
  SELECT count(*) INTO v_count
  FROM   pg_policies
  WHERE  schemaname = 'public' AND tablename = 'fiscal_documents'
    AND  cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL');

  IF v_count <> 0 THEN
    v_offenders := v_offenders || format('fiscal_documents volvió a tener %s policy(s) de escritura', v_count);
  END IF;

  -- Control positivo: las de SELECT siguen vivas (si no, el gate pasaría
  -- porque alguien borró TODAS las policies y rompió la lectura).
  FOREACH v_t IN ARRAY ARRAY['fiscal_documents', 'document_sequences'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public' AND tablename = v_t AND cmd = 'SELECT'
    ) THEN
      v_offenders := v_offenders || format('%s se quedó SIN policy de SELECT', v_t);
    END IF;
  END LOOP;

  IF array_length(v_offenders, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (17) FAILED: allow-list de escritura de las tablas fiscales.\n  %\n  Contexto: con INSERT, un writer podía POSTear a PostgREST un comprobante status=''authorized'' con un CAE inventado en su propia cuenta (medido: HTTP 201). Y TRUNCATE NO pasa por RLS: vaciaba fiscal_documents y document_sequences de TODOS los tenants.',
      array_to_string(v_offenders, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (17): fiscal_documents y document_sequences sin escritura directa para anon/authenticated, con SELECT sólo para authenticated y sin policies de escritura.';
END $$;


-- ── (18) R2: el trigger BEFORE INSERT existe, está habilitado y MUERDE ─────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_email_i   text := 'fiscal-insert-interno@test.local';
  v_user_i    uuid := gen_random_uuid();
  v_account_i uuid;
  v_fp_i      uuid;
  v_pv_i      uuid;

  v_enabled   "char";
  v_timing    text;
  v_state     text;
  v_doc       uuid;
  v_count     integer;
BEGIN
  -- ═══ Metadata: BEFORE INSERT y HABILITADO ═══
  SELECT t.tgenabled,
         CASE WHEN (t.tgtype & 2) <> 0 THEN 'BEFORE' ELSE 'AFTER' END
  INTO   v_enabled, v_timing
  FROM   pg_trigger t
  WHERE  t.tgrelid = 'public.fiscal_documents'::regclass
    AND  t.tgname = 'trg_guard_fiscal_document_insert_interno';

  IF v_enabled IS NULL THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (18) FAILED: no existe el trigger trg_guard_fiscal_document_insert_interno sobre fiscal_documents.';
  END IF;
  IF v_timing <> 'BEFORE' THEN
    v_failures := v_failures || format('(18) el trigger debe ser BEFORE INSERT y es %s', v_timing);
  END IF;
  IF v_enabled <> 'O' THEN
    -- tgenabled='D' (disabled) o 'R'/'A' (replica) lo apagarían en silencio
    -- para el camino normal. Es el mismo mecanismo con el que los fixtures lo
    -- eluden a propósito (session_replication_role = replica).
    v_failures := v_failures || format('(18) el trigger no está habilitado en modo origin; tgenabled=%s', v_enabled);
  END IF;

  -- ═══ Setup del fixture ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_i, 'authenticated', 'authenticated', v_email_i, now(), now(),
          jsonb_build_object('name', 'Gate Fiscal Insert Interno', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_i
  FROM   public.account_members WHERE user_id = v_user_i ORDER BY created_at LIMIT 1;

  IF v_account_i IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED (18): no se pudo resolver account para el anchor — handle_new_user no corrió';
  END IF;

  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_i, '20555555561', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fp_i;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp_i, v_account_i, 8030, true) RETURNING id INTO v_pv_i;

  -- ═══ Matriz de evasión EJECUTADA: las 5 formas deben fallar con P0436 ═══
  -- (a) el ataque medido: status='authorized' con CAE inventado
  BEGIN
    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, cae)
    VALUES (v_account_i, v_fp_i, v_pv_i, 'factura_c', 8030, 1, 1000, 'authorized', 'CAE-INVENTADO-01');
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'P0436' THEN
    v_failures := v_failures || format('(18a) un INSERT con status=authorized + CAE debía dar P0436; got %s', v_state);
  END IF;

  -- (b) 'rejected' tampoco: un comprobante sólo NACE pending_cae
  BEGIN
    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status)
    VALUES (v_account_i, v_fp_i, v_pv_i, 'factura_c', 8030, 2, 1000, 'rejected');
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'P0436' THEN
    v_failures := v_failures || format('(18b) un INSERT con status=rejected debía dar P0436; got %s', v_state);
  END IF;

  -- (c) pending_cae CON CAE: el estado engaña, el CAE es lo que no puede nacer
  BEGIN
    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, cae)
    VALUES (v_account_i, v_fp_i, v_pv_i, 'factura_c', 8030, 3, 1000, 'pending_cae', 'CAE-INVENTADO-02');
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'P0436' THEN
    v_failures := v_failures || format('(18c) un INSERT pending_cae CON cae debía dar P0436; got %s', v_state);
  END IF;

  -- (d) pending_cae con la marca de envío ya puesta: nacería "reconciliable"
  --     contra un número que nadie pidió
  BEGIN
    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status,
       cae_submit_started_at, arca_requested_number)
    VALUES (v_account_i, v_fp_i, v_pv_i, 'factura_c', 8030, 4, 1000, 'pending_cae', now(), 99);
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'P0436' THEN
    v_failures := v_failures || format('(18d) un INSERT pending_cae CON marca de envío debía dar P0436; got %s', v_state);
  END IF;

  -- (e) pending_cae nacido CONGELADO
  BEGIN
    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status,
       cae_submit_unconfirmed_at)
    VALUES (v_account_i, v_fp_i, v_pv_i, 'factura_c', 8030, 5, 1000, 'pending_cae', now());
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'P0436' THEN
    v_failures := v_failures || format('(18e) un INSERT pending_cae nacido CONGELADO debía dar P0436; got %s', v_state);
  END IF;

  -- ═══ Control positivo: un comprobante legítimo SÍ nace ═══
  -- Sin esto, el bloque pasaría igual si el trigger rechazara TODO (y la
  -- emisión entera estaría rota sin que el gate lo notara).
  BEGIN
    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
    VALUES (v_account_i, v_fp_i, v_pv_i, 'factura_c', 8030, 6, 1000, 'pending_cae', 0)
    RETURNING id INTO v_doc;
    v_state := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  IF v_state <> 'ok' THEN
    v_failures := v_failures || format('(18) control positivo: un pending_cae limpio DEBE poder nacer (es lo que insertan las 2 RPCs de emisión); got %s', v_state);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FISCAL-CAE (18) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (18): trg_guard_fiscal_document_insert_interno BEFORE INSERT y habilitado; las 5 formas de nacer con CAE/estado/marca rechazadas con P0436 y el pending_cae limpio aceptado.';

  -- ═══ Limpieza verificada ═══
  DELETE FROM public.document_status_history WHERE account_id = v_account_i;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account_i;
  DELETE FROM public.document_sequences
  WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account_i);
  DELETE FROM public.points_of_sale          WHERE account_id = v_account_i;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account_i;

  SELECT count(*) INTO v_count FROM public.fiscal_documents WHERE account_id = v_account_i;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FISCAL-CAE (18) FAILED: quedaron % fiscal_documents del fixture del trigger', v_count;
  END IF;

  SET session_replication_role = replica;
  DELETE FROM public.account_members WHERE account_id = v_account_i;
  DELETE FROM public.accounts        WHERE id = v_account_i;
  DELETE FROM public.profiles        WHERE id = v_user_i;
  DELETE FROM auth.users             WHERE id = v_user_i;
  SET session_replication_role = DEFAULT;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      DELETE FROM public.document_status_history WHERE account_id = v_account_i;
      DELETE FROM public.fiscal_documents        WHERE account_id = v_account_i;
      DELETE FROM public.document_sequences
      WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account_i);
      DELETE FROM public.points_of_sale          WHERE account_id = v_account_i;
      DELETE FROM public.fiscal_profiles         WHERE account_id = v_account_i;
      SET session_replication_role = replica;
      DELETE FROM public.account_members WHERE account_id = v_account_i;
      DELETE FROM public.accounts        WHERE id = v_account_i;
      DELETE FROM public.profiles        WHERE id = v_user_i;
      DELETE FROM auth.users             WHERE id = v_user_i;
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- GATE FISCAL-CAE PASSED (18 bloques).
-- =============================================================================
