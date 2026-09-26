-- =============================================================================
-- test_factura_fiscal_imprimible.sql — factura-fiscal-imprimible (governance
-- MEDIA con tramo ALTO: toca rpc_fiscal_document_authorize, la RPC por la que
-- pasa TODO comprobante autorizado, tanto en el relay como en la
-- reconciliación).
--
-- Verifica 20261064000001_factura_fiscal_imprimible.sql:
--
--   (1)  Columnas nuevas, todas NULLABLE y sin default:
--          fiscal_profiles: razon_social, nombre_fantasia, domicilio_comercial,
--                           iibb_numero (text), inicio_actividades (date)
--          fiscal_documents: fecha_comprobante (date), emisor_snapshot (jsonb)
--   (2)  rpc_fiscal_document_authorize con UNA sola definición y la firma de 5
--        parámetros (p_fecha_comprobante date DEFAULT NULL), SECURITY
--        DEFINER, search_path=public, ACL interna exacta (sin anon ni
--        authenticated, con service_role) y el COMMENT vivo conservado.
--   (3)  rpc_fiscal_document_set_fecha_comprobante(uuid, date): una sola
--        definición, SECURITY DEFINER, search_path fijo, ACL interna.
--   (4)  La EJECUCIÓN real de authorize (regla del proyecto: un gate que sólo
--        mira la firma no prueba nada):
--          (4a) transición real → escribe fecha_comprobante y emisor_snapshot
--               (con los datos del perfil del documento) y registra UNA fila
--               de historial;
--          (4b) cambiar el perfil después NO altera la foto;
--          (4c) camino idempotente → false, no reescribe fecha ni foto, no
--               agrega historial;
--          (4d) llamadas con 4 y 3 argumentos (backend viejo durante el
--               despliegue) → autorizan igual, fecha NULL, foto escrita;
--          (4e) colisión irresoluble (7b) → false, CAE guardado, CONGELADO,
--               sin fecha ni foto.
--   (5)  La EJECUCIÓN real de set_fecha_comprobante: completa sólo NULL sobre
--        authorized; no pisa una fecha existente; no toca un pending_cae;
--        rechaza p_fecha NULL.
--   (6)  authenticated NO puede ejecutar ninguna de las dos (intento real con
--        SET LOCAL ROLE, además del has_function_privilege del bloque 2/3).
--   (7)  Limpieza verificada: cero filas residuales del fixture.
--
-- Patrón del proyecto (test_fiscal_cae_numero_autoritativo.sql): acumular
-- fallos en text[], un solo RAISE EXCEPTION al final, anchor sintético vía
-- handle_new_user, limpieza en el camino feliz y en el EXCEPTION.
--
-- Corre en CI: KPI_Validation.yml ("Run factura fiscal imprimible gate").
-- =============================================================================

-- ── (1) Columnas nuevas ─────────────────────────────────────────────────────
DO $$
DECLARE
  v_expected CONSTANT text[][] := ARRAY[
    ARRAY['fiscal_profiles',  'razon_social',        'text'],
    ARRAY['fiscal_profiles',  'nombre_fantasia',     'text'],
    ARRAY['fiscal_profiles',  'domicilio_comercial', 'text'],
    ARRAY['fiscal_profiles',  'iibb_numero',         'text'],
    ARRAY['fiscal_profiles',  'inicio_actividades',  'date'],
    ARRAY['fiscal_documents', 'fecha_comprobante',   'date'],
    ARRAY['fiscal_documents', 'emisor_snapshot',     'jsonb']
  ];
  v_i         integer;
  v_type      text;
  v_nullable  text;
  v_default   text;
  v_offenders text[] := '{}';
BEGIN
  FOR v_i IN 1 .. array_length(v_expected, 1) LOOP
    SELECT c.data_type, c.is_nullable, c.column_default
    INTO   v_type, v_nullable, v_default
    FROM   information_schema.columns c
    WHERE  c.table_schema = 'public'
      AND  c.table_name   = v_expected[v_i][1]
      AND  c.column_name  = v_expected[v_i][2];

    IF v_type IS NULL THEN
      v_offenders := v_offenders || format('%s.%s NO EXISTE', v_expected[v_i][1], v_expected[v_i][2]);
    ELSIF v_type <> v_expected[v_i][3] THEN
      v_offenders := v_offenders || format('%s.%s es %s (se esperaba %s)',
                                           v_expected[v_i][1], v_expected[v_i][2], v_type, v_expected[v_i][3]);
    ELSIF v_nullable <> 'YES' THEN
      v_offenders := v_offenders || format('%s.%s es NOT NULL (rompería perfiles/comprobantes existentes)',
                                           v_expected[v_i][1], v_expected[v_i][2]);
    ELSIF v_default IS NOT NULL THEN
      v_offenders := v_offenders || format('%s.%s tiene default %s (no debe inventar un dato fiscal)',
                                           v_expected[v_i][1], v_expected[v_i][2], v_default);
    END IF;
    v_type := NULL; v_nullable := NULL; v_default := NULL;
  END LOOP;

  IF array_length(v_offenders, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURA-IMPRIMIBLE (1) FAILED: columnas nuevas:\n  %',
      array_to_string(v_offenders, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (1): 5 columnas del emisor en fiscal_profiles + fecha_comprobante/emisor_snapshot en fiscal_documents, NULLABLE y sin default.';
END $$;


-- ── (2) rpc_fiscal_document_authorize: firma, DEFINER, ACL, COMMENT ─────────
DO $$
DECLARE
  -- COMMENT vivo en prod al 2026-09-26 (releído por SELECT antes de escribir
  -- la migración). La migración lo CONSERVA y le suma una línea propia; este
  -- prefijo exacto es lo que prueba que no se perdió (lección de #579).
  v_live_comment CONSTANT text :=
    'Transiciona un comprobante pending_cae → authorized con el CAE de ARCA y, si '
    'ARCA autorizó un número distinto al reservado localmente, PERSISTE el de ARCA '
    '(fuente de verdad) resincronizando document_sequences hacia adelante y dejando '
    'el desfasaje en document_status_history.reason. Ante colisión con otro '
    'comprobante ya autorizado conserva el número local y NUNCA pierde el CAE; si '
    'ni ese número es libre, guarda el CAE y CONGELA el documento en vez de dejar '
    'que la excepción del índice único haga perder el CAE (lo que provocaría una '
    'segunda factura real en el próximo tick del relay). '
    'p_number con DEFAULT NULL sostiene la ventana de despliegue (backend viejo, '
    '3 args) — no es un overload: hay una sola función.';
  v_count    integer;
  v_args     text;
  v_secdef   boolean;
  v_config   text[];
  v_oid      oid;
  v_comment  text;
  v_failures text[] := '{}';
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_authorize';

  IF v_count <> 1 THEN
    v_failures := v_failures || format('se esperaba UNA definición de rpc_fiscal_document_authorize y hay %s (overload = 42725 en cada llamada de 4 argumentos del backend viejo)', v_count);
  END IF;

  SELECT p.oid, pg_get_function_identity_arguments(p.oid), p.prosecdef, p.proconfig
  INTO   v_oid, v_args, v_secdef, v_config
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_authorize'
  LIMIT  1;

  IF v_args IS DISTINCT FROM 'p_doc_id uuid, p_cae text, p_cae_due_date date, p_number bigint, p_fecha_comprobante date' THEN
    v_failures := v_failures || format('firma inesperada: (%s)', COALESCE(v_args, '<no existe>'));
  END IF;
  IF v_secdef IS DISTINCT FROM true THEN
    v_failures := v_failures || format('dejó de ser SECURITY DEFINER (fiscal_documents no tiene policy de UPDATE)');
  END IF;
  IF v_config IS NULL OR NOT ('search_path=public' = ANY (v_config)) THEN
    v_failures := v_failures || format('search_path no fijado a public: %s', COALESCE(v_config::text, '<NULL>'));
  END IF;

  IF v_oid IS NOT NULL THEN
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || format('ejecutable por authenticated (escribiría un CAE en el comprobante de cualquier cuenta)');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || format('ejecutable por anon');
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || format('SIN EXECUTE para service_role');
    END IF;

    v_comment := obj_description(v_oid, 'pg_proc');
    IF v_comment IS NULL OR left(v_comment, length(v_live_comment)) <> v_live_comment THEN
      v_failures := v_failures || format('el COMMENT vivo no se conservó (prefijo distinto): %s', COALESCE(left(v_comment, 120), '<NULL>'));
    END IF;
    IF v_comment IS NULL OR position('factura-fiscal-imprimible' in v_comment) = 0 THEN
      v_failures := v_failures || format('el COMMENT no documenta p_fecha_comprobante/emisor_snapshot (línea de factura-fiscal-imprimible)');
    END IF;
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURA-IMPRIMIBLE (2) FAILED: rpc_fiscal_document_authorize:\n  %',
      array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (2): rpc_fiscal_document_authorize con firma única de 5 parámetros, SECURITY DEFINER, search_path=public, ACL interna y COMMENT vivo conservado.';
END $$;


-- ── (3) rpc_fiscal_document_set_fecha_comprobante: firma, DEFINER, ACL ──────
DO $$
DECLARE
  v_count    integer;
  v_oid      oid;
  v_secdef   boolean;
  v_config   text[];
  v_failures text[] := '{}';
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_set_fecha_comprobante';

  IF v_count <> 1 THEN
    v_failures := v_failures || format('se esperaba UNA definición y hay %s', v_count);
  END IF;

  v_oid := to_regprocedure('public.rpc_fiscal_document_set_fecha_comprobante(uuid, date)');
  IF v_oid IS NULL THEN
    v_failures := v_failures || format('la firma (uuid, date) NO resuelve');
  ELSE
    SELECT p.prosecdef, p.proconfig INTO v_secdef, v_config FROM pg_proc p WHERE p.oid = v_oid;
    IF NOT v_secdef THEN
      v_failures := v_failures || format('no es SECURITY DEFINER (fiscal_documents no admite escritura directa)');
    END IF;
    IF v_config IS NULL OR NOT ('search_path=public' = ANY (v_config)) THEN
      v_failures := v_failures || format('search_path no fijado a public');
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || format('ejecutable por authenticated (cualquier usuario podría fechar el comprobante de otra cuenta)');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || format('ejecutable por anon');
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || format('SIN EXECUTE para service_role');
    END IF;
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURA-IMPRIMIBLE (3) FAILED: rpc_fiscal_document_set_fecha_comprobante:\n  %',
      array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (3): rpc_fiscal_document_set_fecha_comprobante interna (SECURITY DEFINER, search_path fijo, sin anon/authenticated).';
END $$;


-- ── (4)-(7) Comportamiento sobre datos ──────────────────────────────────────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_email     text := 'factura-fiscal-imprimible@test.local';
  v_user      uuid := gen_random_uuid();
  v_account   uuid;
  v_fp        uuid;
  v_pv        uuid;

  v_doc       uuid;
  v_doc_4arg  uuid;
  v_doc_3arg  uuid;
  v_doc_a     uuid;
  v_doc_b     uuid;
  v_doc_pend  uuid;

  v_ret       boolean;
  v_fecha     date;
  v_snap      jsonb;
  v_snap_2    jsonb;
  v_status    text;
  v_cae       text;
  v_frozen    timestamptz;
  v_count     integer;
  v_sqlstate  text;
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', v_email, now(), now(),
          jsonb_build_object('name', 'Gate Factura Imprimible', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account
  FROM   public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor — handle_new_user no corrió';
  END IF;

  INSERT INTO public.fiscal_profiles
    (account_id, cuit, iva_condition, iibb_condition, ambiente, delegacion_autorizada,
     razon_social, nombre_fantasia, domicilio_comercial, iibb_numero, inicio_actividades)
  VALUES (v_account, '27213790337', 'monotributista', NULL, 'homologacion', true,
          'SUMAR DE PRUEBA', 'Sumar', 'Calle 1, Mendoza', '0123456-7', DATE '2015-03-01')
  RETURNING id INTO v_fp;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, v_account, 8064, true) RETURNING id INTO v_pv;

  INSERT INTO public.document_sequences (point_of_sale_id, comprobante_type, last_number)
  VALUES (v_pv, 'factura_c', 30);

  -- ═══ (4a) Transición real: fecha + foto + una fila de historial ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account, v_fp, v_pv, 'factura_c', 8064, 1, 32500, 'pending_cae', 0)
  RETURNING id INTO v_doc;

  v_ret := public.rpc_fiscal_document_authorize(v_doc, '71234567890123', DATE '2026-10-05', 1, DATE '2026-09-25');

  IF v_ret IS NOT TRUE THEN
    v_failures := v_failures || '(4a) la transición real debía devolver true';
  END IF;

  SELECT fecha_comprobante, emisor_snapshot, status INTO v_fecha, v_snap, v_status
  FROM   public.fiscal_documents WHERE id = v_doc;

  IF v_status <> 'authorized' THEN
    v_failures := v_failures || format('(4a) el documento debía quedar authorized y quedó %s', v_status);
  END IF;
  IF v_fecha IS DISTINCT FROM DATE '2026-09-25' THEN
    v_failures := v_failures || format('(4a) fecha_comprobante debía ser 2026-09-25 y es %s', COALESCE(v_fecha::text, '<NULL>'));
  END IF;
  IF v_snap IS NULL THEN
    v_failures := v_failures || '(4a) emisor_snapshot quedó NULL en la transición real';
  ELSE
    IF v_snap->>'razon_social' IS DISTINCT FROM 'SUMAR DE PRUEBA'
       OR v_snap->>'nombre_fantasia' IS DISTINCT FROM 'Sumar'
       OR v_snap->>'domicilio_comercial' IS DISTINCT FROM 'Calle 1, Mendoza'
       OR v_snap->>'iibb_numero' IS DISTINCT FROM '0123456-7'
       OR v_snap->>'inicio_actividades' IS DISTINCT FROM '2015-03-01'
       OR v_snap->>'cuit' IS DISTINCT FROM '27213790337'
       OR v_snap->>'iva_condition' IS DISTINCT FROM 'monotributista'
       OR v_snap->>'ambiente' IS DISTINCT FROM 'homologacion' THEN
      v_failures := v_failures || format('(4a) la foto no refleja el perfil del documento: %s', v_snap::text);
    END IF;
    -- iibb_condition viaja aunque sea NULL: la clave tiene que existir para que
    -- el render distinga "no había dato" de "foto vieja sin esa clave".
    IF NOT (v_snap ? 'iibb_condition') THEN
      v_failures := v_failures || format('(4a) la foto no tiene la clave iibb_condition: %s', v_snap::text);
    END IF;
  END IF;

  SELECT count(*) INTO v_count
  FROM   public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc AND to_status = 'authorized';
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(4a) se esperaba 1 fila de historial a authorized y hay %s', v_count);
  END IF;

  -- ═══ (4b) Cambiar el perfil después no altera la foto ═══
  UPDATE public.fiscal_profiles SET domicilio_comercial = 'Calle 2, Mendoza' WHERE id = v_fp;

  SELECT emisor_snapshot INTO v_snap_2 FROM public.fiscal_documents WHERE id = v_doc;
  IF v_snap_2->>'domicilio_comercial' IS DISTINCT FROM 'Calle 1, Mendoza' THEN
    v_failures := v_failures || format('(4b) la foto cambió con el perfil: %s', v_snap_2->>'domicilio_comercial');
  END IF;

  -- ═══ (4c) Idempotencia: false, sin reescribir fecha ni foto, sin historial ═══
  v_ret := public.rpc_fiscal_document_authorize(v_doc, '79999999999999', DATE '2026-10-06', 1, DATE '2026-09-30');
  IF v_ret IS NOT FALSE THEN
    v_failures := v_failures || '(4c) authorize sobre un authorized debía devolver false';
  END IF;

  SELECT fecha_comprobante, emisor_snapshot, cae INTO v_fecha, v_snap_2, v_cae
  FROM   public.fiscal_documents WHERE id = v_doc;
  IF v_fecha IS DISTINCT FROM DATE '2026-09-25' THEN
    v_failures := v_failures || format('(4c) el camino idempotente reescribió la fecha: %s', v_fecha);
  END IF;
  IF v_snap_2 IS DISTINCT FROM v_snap THEN
    v_failures := v_failures || '(4c) el camino idempotente reescribió la foto del emisor';
  END IF;
  IF v_cae <> '71234567890123' THEN
    v_failures := v_failures || format('(4c) el camino idempotente reescribió el CAE: %s', v_cae);
  END IF;

  SELECT count(*) INTO v_count
  FROM   public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc;
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(4c) el camino idempotente agregó historial (%s filas)', v_count);
  END IF;

  -- ═══ (4d) Firma vieja: 4 y 3 argumentos ═══
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account, v_fp, v_pv, 'factura_c', 8064, 2, 100, 'pending_cae', 0)
  RETURNING id INTO v_doc_4arg;

  v_ret := public.rpc_fiscal_document_authorize(v_doc_4arg, '72222222222222', DATE '2026-10-05', 2);
  SELECT status, fecha_comprobante, emisor_snapshot INTO v_status, v_fecha, v_snap_2
  FROM   public.fiscal_documents WHERE id = v_doc_4arg;
  IF v_ret IS NOT TRUE OR v_status <> 'authorized' THEN
    v_failures := v_failures || format('(4d) la llamada de 4 argumentos debía autorizar (ret=%s, status=%s)', v_ret, v_status);
  END IF;
  IF v_fecha IS NOT NULL THEN
    v_failures := v_failures || format('(4d) sin p_fecha_comprobante la fecha debía quedar NULL y es %s', v_fecha);
  END IF;
  IF v_snap_2 IS NULL OR v_snap_2->>'domicilio_comercial' IS DISTINCT FROM 'Calle 2, Mendoza' THEN
    v_failures := v_failures || format('(4d) la foto debía escribirse igual con el perfil vigente: %s', COALESCE(v_snap_2::text, '<NULL>'));
  END IF;

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account, v_fp, v_pv, 'factura_c', 8064, 3, 100, 'pending_cae', 0)
  RETURNING id INTO v_doc_3arg;

  v_ret := public.rpc_fiscal_document_authorize(v_doc_3arg, '73333333333333', DATE '2026-10-05');
  SELECT status, fecha_comprobante INTO v_status, v_fecha
  FROM   public.fiscal_documents WHERE id = v_doc_3arg;
  IF v_ret IS NOT TRUE OR v_status <> 'authorized' OR v_fecha IS NOT NULL THEN
    v_failures := v_failures || format('(4d) la llamada de 3 argumentos debía autorizar con fecha NULL (ret=%s, status=%s, fecha=%s)', v_ret, v_status, v_fecha);
  END IF;

  -- ═══ (4e) Colisión irresoluble (7b): false, CAE guardado, congelado, sin fecha ni foto ═══
  -- A autorizado con el número 20; B pending con el MISMO número local 20
  -- (el índice único sólo cubre status='authorized', así que B puede existir).
  -- Autorizar B con p_number = 20 no entra a la rama de desfasaje (p_number =
  -- número local) y el UPDATE a authorized choca con el índice → rama 7b.
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account, v_fp, v_pv, 'factura_c', 8064, 20, 100, 'pending_cae', 0)
  RETURNING id INTO v_doc_a;
  v_ret := public.rpc_fiscal_document_authorize(v_doc_a, '74444444444444', DATE '2026-10-05', 20, DATE '2026-09-25');

  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account, v_fp, v_pv, 'factura_c', 8064, 20, 100, 'pending_cae', 0)
  RETURNING id INTO v_doc_b;

  v_ret := public.rpc_fiscal_document_authorize(v_doc_b, '75555555555555', DATE '2026-10-05', 20, DATE '2026-09-25');

  SELECT status, cae, cae_submit_unconfirmed_at, fecha_comprobante, emisor_snapshot
  INTO   v_status, v_cae, v_frozen, v_fecha, v_snap_2
  FROM   public.fiscal_documents WHERE id = v_doc_b;

  IF v_ret IS NOT FALSE THEN
    v_failures := v_failures || '(4e) la colisión irresoluble debía devolver false';
  END IF;
  IF v_status <> 'pending_cae' OR v_cae IS DISTINCT FROM '75555555555555' OR v_frozen IS NULL THEN
    v_failures := v_failures || format('(4e) debía guardar el CAE y CONGELAR sin transicionar (status=%s cae=%s frozen=%s)', v_status, v_cae, v_frozen);
  END IF;
  IF v_fecha IS NOT NULL OR v_snap_2 IS NOT NULL THEN
    v_failures := v_failures || format('(4e) la rama 7b no debía escribir fecha ni foto (fecha=%s foto=%s)', v_fecha, v_snap_2);
  END IF;

  -- ═══ (5) set_fecha_comprobante ═══
  -- sobre authorized con fecha NULL → la completa
  v_ret := public.rpc_fiscal_document_set_fecha_comprobante(v_doc_4arg, DATE '2026-09-24');
  SELECT fecha_comprobante INTO v_fecha FROM public.fiscal_documents WHERE id = v_doc_4arg;
  IF v_ret IS NOT TRUE OR v_fecha IS DISTINCT FROM DATE '2026-09-24' THEN
    v_failures := v_failures || format('(5) debía completar la fecha NULL (ret=%s, fecha=%s)', v_ret, v_fecha);
  END IF;

  -- no pisa una fecha existente
  v_ret := public.rpc_fiscal_document_set_fecha_comprobante(v_doc, DATE '2026-01-01');
  SELECT fecha_comprobante INTO v_fecha FROM public.fiscal_documents WHERE id = v_doc;
  IF v_ret IS NOT FALSE OR v_fecha IS DISTINCT FROM DATE '2026-09-25' THEN
    v_failures := v_failures || format('(5) pisó una fecha existente (ret=%s, fecha=%s)', v_ret, v_fecha);
  END IF;

  -- no toca un pending_cae (no es una factura: no tiene fecha confirmada)
  INSERT INTO public.fiscal_documents
    (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (v_account, v_fp, v_pv, 'factura_c', 8064, 4, 100, 'pending_cae', 0)
  RETURNING id INTO v_doc_pend;
  v_ret := public.rpc_fiscal_document_set_fecha_comprobante(v_doc_pend, DATE '2026-09-24');
  SELECT fecha_comprobante INTO v_fecha FROM public.fiscal_documents WHERE id = v_doc_pend;
  IF v_ret IS NOT FALSE OR v_fecha IS NOT NULL THEN
    v_failures := v_failures || format('(5) fechó un pending_cae (ret=%s, fecha=%s)', v_ret, v_fecha);
  END IF;

  -- rechaza p_fecha NULL (no "completa" con nada)
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_fiscal_document_set_fecha_comprobante(v_doc_3arg, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0400' THEN
    v_failures := v_failures || format('(5) p_fecha NULL debía rechazarse con P0400 (sqlstate=%s)', COALESCE(v_sqlstate, '<sin error>'));
  END IF;

  -- ═══ (6) authenticated no puede ejecutar ninguna de las dos (intento real) ═══
  v_sqlstate := NULL;
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.rpc_fiscal_document_authorize(v_doc_pend, '76666666666666', DATE '2026-10-05', 4, DATE '2026-09-25');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
  END;
  RESET ROLE;
  IF v_sqlstate IS DISTINCT FROM '42501' THEN
    v_failures := v_failures || format('(6) authenticated pudo ejecutar authorize (sqlstate=%s)', COALESCE(v_sqlstate, '<sin error>'));
  END IF;

  v_sqlstate := NULL;
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.rpc_fiscal_document_set_fecha_comprobante(v_doc_3arg, DATE '2026-09-24');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
  END;
  RESET ROLE;
  IF v_sqlstate IS DISTINCT FROM '42501' THEN
    v_failures := v_failures || format('(6) authenticated pudo ejecutar set_fecha_comprobante (sqlstate=%s)', COALESCE(v_sqlstate, '<sin error>'));
  END IF;

  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc_pend;
  IF v_status <> 'pending_cae' THEN
    v_failures := v_failures || format('(6) el intento de authenticated modificó el documento (status=%s)', v_status);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURA-IMPRIMIBLE (4)-(6) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (4)-(6): la transición real congela fecha y foto del emisor con una fila de historial; el perfil posterior no la altera; idempotencia y colisión irresoluble no escriben nada; la firma vieja autoriza con fecha NULL; set_fecha sólo completa NULL sobre authorized; authenticated no ejecuta ninguna.';

  -- ═══ (7) Limpieza verificada ═══
  DELETE FROM public.document_status_history WHERE account_id = v_account;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account;
  DELETE FROM public.document_sequences
  WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account);
  DELETE FROM public.points_of_sale          WHERE account_id = v_account;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account;

  SELECT count(*) INTO v_count FROM public.fiscal_documents WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FACTURA-IMPRIMIBLE (7) FAILED: quedaron % fiscal_documents del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.document_status_history WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FACTURA-IMPRIMIBLE (7) FAILED: quedaron % filas de historial del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.fiscal_profiles WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FACTURA-IMPRIMIBLE (7) FAILED: quedaron % fiscal_profiles del fixture', v_count;
  END IF;

  SET session_replication_role = replica;
  DELETE FROM public.account_members WHERE account_id = v_account;
  DELETE FROM public.accounts        WHERE id = v_account;
  DELETE FROM public.profiles        WHERE id = v_user;
  DELETE FROM auth.users             WHERE id = v_user;
  SET session_replication_role = DEFAULT;

  RAISE NOTICE 'PASS (7): limpieza verificada — cero filas residuales del fixture.';

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      RESET ROLE;
      DELETE FROM public.document_status_history WHERE account_id = v_account;
      DELETE FROM public.fiscal_documents        WHERE account_id = v_account;
      DELETE FROM public.document_sequences
      WHERE  point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account);
      DELETE FROM public.points_of_sale          WHERE account_id = v_account;
      DELETE FROM public.fiscal_profiles         WHERE account_id = v_account;
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
