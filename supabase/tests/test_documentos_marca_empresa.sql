-- =============================================================================
-- test_documentos_marca_empresa.sql — Gate de comportamiento:
-- documentos-marca-empresa, TANDA A (governance MEDIA).
--
-- Pedido del PO (2026-10-11): "en todos los comprobantes, remitos, facturas,
-- presupuesto, etc., [...] toda la información de la empresa y el logo de la
-- misma, de cada usuario. Y sacale el color verde y dejalos blancos, o en
-- Configuración que cada usuario pueda elegir la paleta de colores".
--
-- Verifica 20261078000001_documentos_marca_empresa.sql:
--
--   (a) Metadatos y privilegios de public.account_branding: PK/FK a accounts
--       (CASCADE), RLS activa, EXACTAMENTE 3 políticas (INSERT, SELECT, UPDATE;
--       ninguna de DELETE), privilegios de tabla (anon sin NINGUNO; authenticated
--       con SELECT/INSERT/UPDATE y SIN DELETE/TRUNCATE/REFERENCES/TRIGGER —
--       "sin DELETE" cerrado también en la capa de privilegios, no sólo por la
--       ausencia de política), disparador BEFORE INSERT OR UPDATE por fila y su
--       función SECURITY DEFINER sin EXECUTE para PUBLIC/anon/authenticated; y
--       que la marca NO se guardó en accounts, fiscal_profiles ni profiles.
--   (b) Matriz de CHECKs (segunda capa; la primera es Pydantic): cada fila
--       inválida se rechaza con 23514 Y con el NOMBRE de la restricción esperada
--       (para que un caso no "pase" por un CHECK ajeno) y su control positivo
--       —la fila válida del mismo campo— se acepta. Se corre con
--       session_replication_role = replica para AISLAR la capa de CHECK (el
--       disparador de guard corre antes y, sin auth.uid(), rechazaría todo).
--   (c) RLS y guard bajo SET LOCAL ROLE + claims reales: owner y admin insertan
--       y actualizan; el seller recibe P0401 (INSERT y UPDATE) y la fila no
--       cambia; el viewer recibe P0401 al insertar (el guard corre antes que la
--       RLS) y 0 filas al actualizar; la RLS por SÍ SOLA (disparador desactivado
--       en la fixture) rechaza al viewer y a otra cuenta con 42501 "row-level
--       security" y deja pasar al seller (la RLS es de escritores; el guard es
--       el que restringe a owner/admin); otra cuenta no lee ni escribe la fila
--       de A; account_id es inmutable (P0401); DELETE y TRUNCATE → 42501 con
--       texto "permission denied" (capa de PRIVILEGIO, no de RLS); anon no lee.
--   (d) rpc_commercial_issuer EJECUTADA como un vendedor que no es el dueño:
--       EXACTAMENTE las 18 claves del design D4 (6 legadas + 12 nuevas), valores
--       de la marca, del perfil fiscal y del dueño; NINGÚN valor es el email de
--       Auth del dueño (con control positivo del predicado); cuenta sin fila de
--       marca → claves nuevas NULL y las legadas intactas; P0404 a otra cuenta.
--   (e) Introspección de la RPC: UNA sola firma, SECURITY DEFINER, STABLE, ACL
--       exacta {postgres, authenticated, service_role}, search_path fijo y
--       COMMENT con "document-branding".
--   (f) Limpieza verificada: cero filas del fixture en toda tabla de public con
--       account_id, cuentas, usuarios, profiles y billing_events.
--
-- Patrón del proyecto: fallos acumulados en text[], un RAISE EXCEPTION por
-- bloque, anchors vía handle_new_user, fixture en su propio bloque con limpieza
-- asertada. Cada sección de datos va en su propio sub-bloque: un error
-- inesperado se registra como falla (no aborta las demás), así la salida RED
-- muestra TODAS las secciones que fallan.
--
-- Corre en CI: KPI_Validation.yml ("Run documentos marca empresa gate").
-- =============================================================================

-- ── (a) + (e) Introspección (sin datos) ──────────────────────────────────────
DO $$
DECLARE
  v_failures text[] := '{}';
  v_count    integer;
  v_text     text;
  v_oid      oid;
  v_bad      text;
BEGIN
  IF to_regclass('public.account_branding') IS NULL THEN
    v_failures := v_failures || '(a) la tabla public.account_branding no existe'::text;
  ELSE
    -- RLS
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.account_branding'::regclass AND relrowsecurity) THEN
      v_failures := v_failures || '(a) account_branding sin RLS activa'::text;
    END IF;

    -- PK sobre account_id, FK a accounts con ON DELETE CASCADE
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.account_branding'::regclass AND contype = 'p'
        AND pg_get_constraintdef(oid) = 'PRIMARY KEY (account_id)'
    ) THEN
      v_failures := v_failures || '(a) la PK de account_branding debía ser (account_id)'::text;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.account_branding'::regclass AND contype = 'f'
        AND confrelid = 'public.accounts'::regclass AND confdeltype = 'c'
    ) THEN
      v_failures := v_failures || '(a) falta el FK account_id → accounts(id) ON DELETE CASCADE'::text;
    END IF;

    -- Políticas: exactamente 3, nombres y comandos, ninguna de DELETE
    SELECT count(*), string_agg(policyname || ':' || cmd, ',' ORDER BY policyname)
    INTO   v_count, v_text
    FROM   pg_policies WHERE schemaname = 'public' AND tablename = 'account_branding';
    IF v_count <> 3 OR v_text IS DISTINCT FROM
       'account_branding_member_select:SELECT,account_branding_writer_insert:INSERT,account_branding_writer_update:UPDATE' THEN
      v_failures := v_failures || format('(a) account_branding debía tener 3 políticas (member_select, writer_insert, writer_update; sin DELETE); tiene %s: %s', v_count, COALESCE(v_text, '<ninguna>'));
    END IF;
    -- Las dos de escritura invocan is_account_writer (alimentan el conteo 45/18 del pivot).
    SELECT count(*) INTO v_count
    FROM   pg_policies
    WHERE  schemaname = 'public' AND tablename = 'account_branding'
      AND  cmd IN ('INSERT', 'UPDATE')
      AND  COALESCE(qual, '') || COALESCE(with_check, '') ILIKE '%is_account_writer%';
    IF v_count <> 2 THEN
      v_failures := v_failures || format('(a) las 2 políticas de escritura debían invocar is_account_writer; lo hacen %s', v_count);
    END IF;

    -- Privilegios de tabla
    v_bad := '';
    IF has_table_privilege('anon', 'public.account_branding', 'SELECT')     THEN v_bad := v_bad || 'anon/SELECT '; END IF;
    IF has_table_privilege('anon', 'public.account_branding', 'INSERT')     THEN v_bad := v_bad || 'anon/INSERT '; END IF;
    IF has_table_privilege('anon', 'public.account_branding', 'UPDATE')     THEN v_bad := v_bad || 'anon/UPDATE '; END IF;
    IF has_table_privilege('anon', 'public.account_branding', 'DELETE')     THEN v_bad := v_bad || 'anon/DELETE '; END IF;
    IF has_table_privilege('anon', 'public.account_branding', 'TRUNCATE')   THEN v_bad := v_bad || 'anon/TRUNCATE '; END IF;
    IF has_table_privilege('anon', 'public.account_branding', 'REFERENCES') THEN v_bad := v_bad || 'anon/REFERENCES '; END IF;
    IF has_table_privilege('anon', 'public.account_branding', 'TRIGGER')    THEN v_bad := v_bad || 'anon/TRIGGER '; END IF;
    IF has_table_privilege('authenticated', 'public.account_branding', 'DELETE')     THEN v_bad := v_bad || 'authenticated/DELETE '; END IF;
    IF has_table_privilege('authenticated', 'public.account_branding', 'TRUNCATE')   THEN v_bad := v_bad || 'authenticated/TRUNCATE '; END IF;
    IF has_table_privilege('authenticated', 'public.account_branding', 'REFERENCES') THEN v_bad := v_bad || 'authenticated/REFERENCES '; END IF;
    IF has_table_privilege('authenticated', 'public.account_branding', 'TRIGGER')    THEN v_bad := v_bad || 'authenticated/TRIGGER '; END IF;
    IF v_bad <> '' THEN
      v_failures := v_failures || format('(a) privilegios de tabla que no debían existir: %s', v_bad);
    END IF;
    -- Control positivo: lo que SÍ debe conservar (si no, el gate negativo sería vacuo).
    IF NOT has_table_privilege('authenticated', 'public.account_branding', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'public.account_branding', 'INSERT')
       OR NOT has_table_privilege('authenticated', 'public.account_branding', 'UPDATE') THEN
      v_failures := v_failures || '(a) authenticated debía conservar SELECT/INSERT/UPDATE sobre account_branding'::text;
    END IF;
    IF NOT has_table_privilege('service_role', 'public.account_branding', 'SELECT') THEN
      v_failures := v_failures || '(a) service_role debía conservar SELECT sobre account_branding'::text;
    END IF;

    -- Disparador BEFORE INSERT OR UPDATE por fila
    SELECT t.tgtype INTO v_count
    FROM   pg_trigger t
    WHERE  t.tgrelid = 'public.account_branding'::regclass
      AND  t.tgname = 'trg_account_branding_guard_owner_admin' AND NOT t.tgisinternal;
    IF v_count IS NULL THEN
      v_failures := v_failures || '(a) falta el disparador trg_account_branding_guard_owner_admin'::text;
    ELSIF (v_count & 1) = 0 OR (v_count & 2) = 0 OR (v_count & 4) = 0 OR (v_count & 16) = 0 OR (v_count & 8) <> 0 THEN
      v_failures := v_failures || format('(a) el disparador debía ser BEFORE INSERT OR UPDATE FOR EACH ROW (sin DELETE); tgtype=%s', v_count);
    END IF;

    -- Función guard: existe, DEFINER, search_path fijo y sin EXECUTE
    v_oid := to_regprocedure('public.account_branding_guard_owner_admin()');
    IF v_oid IS NULL THEN
      v_failures := v_failures || '(a) falta la función public.account_branding_guard_owner_admin()'::text;
    ELSE
      IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
        v_failures := v_failures || '(a) account_branding_guard_owner_admin() debía ser SECURITY DEFINER'::text;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_oid AND proconfig::text LIKE '%search_path=%') THEN
        v_failures := v_failures || '(a) account_branding_guard_owner_admin() sin search_path fijo'::text;
      END IF;
      IF has_function_privilege('anon', v_oid, 'EXECUTE')
         OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
         OR has_function_privilege('public', v_oid, 'EXECUTE') THEN
        v_failures := v_failures || '(a) account_branding_guard_owner_admin() es función trigger SECURITY DEFINER y no debe ser EXECUTE para PUBLIC/anon/authenticated'::text;
      END IF;
    END IF;

    -- La marca NO vive en accounts, fiscal_profiles ni profiles.
    SELECT string_agg(table_name || '.' || column_name, ', ') INTO v_text
    FROM   information_schema.columns
    WHERE  table_schema = 'public'
      AND  table_name IN ('accounts', 'fiscal_profiles', 'profiles')
      AND  column_name ~* '(logo|brand|palette|accent)';
    IF v_text IS NOT NULL THEN
      v_failures := v_failures || format('(a) la marca no debía guardarse en accounts/fiscal_profiles/profiles; hay columnas: %s', v_text);
    END IF;
  END IF;

  -- ── (e) rpc_commercial_issuer ──────────────────────────────────────────────
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_commercial_issuer';
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(e) rpc_commercial_issuer: se esperaba UNA definición y hay %s', v_count);
  END IF;
  v_oid := to_regprocedure('public.rpc_commercial_issuer(uuid)');
  IF v_oid IS NULL THEN
    v_failures := v_failures || '(e) rpc_commercial_issuer(uuid) no resuelve'::text;
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      v_failures := v_failures || '(e) rpc_commercial_issuer dejó de ser SECURITY DEFINER'::text;
    END IF;
    IF (SELECT provolatile FROM pg_proc WHERE oid = v_oid) <> 's' THEN
      v_failures := v_failures || '(e) rpc_commercial_issuer dejó de ser STABLE'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_oid AND proconfig::text LIKE '%search_path=public%') THEN
      v_failures := v_failures || '(e) rpc_commercial_issuer perdió su search_path fijo'::text;
    END IF;
    SELECT string_agg(a, ',' ORDER BY a) INTO v_text
    FROM   (SELECT unnest(proacl)::text AS a FROM pg_proc WHERE oid = v_oid) s;
    IF v_text IS DISTINCT FROM 'authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres' THEN
      v_failures := v_failures || format('(e) ACL de rpc_commercial_issuer debía ser exactamente {postgres, authenticated, service_role}=X; es %s', COALESCE(v_text, '<NULL>'));
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') OR has_function_privilege('public', v_oid, 'EXECUTE') THEN
      v_failures := v_failures || '(e) rpc_commercial_issuer es ejecutable por anon/PUBLIC'::text;
    END IF;
    v_text := obj_description(v_oid, 'pg_proc');
    IF v_text IS NULL OR v_text NOT LIKE '%document-branding%' THEN
      v_failures := v_failures || format('(e) el COMMENT de rpc_commercial_issuer debía citar document-branding; es: %s', COALESCE(v_text, '<NULL>'));
    END IF;
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE DOCUMENTOS-MARCA-EMPRESA (a,e) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (a,e): account_branding (PK/FK, RLS, 3 políticas sin DELETE, privilegios, disparador y función guard, la marca no vive en otras tablas) y rpc_commercial_issuer (firma única, DEFINER, STABLE, ACL exacta, COMMENT).';
END $$;


-- ── (b)(c)(d)(f) Comportamiento sobre datos ──────────────────────────────────
-- Intenta una sentencia dentro de una subtransacción que SIEMPRE se revierte
-- (un control positivo no deja filas) y devuelve 'ok' o 'SQLSTATE:restricción'.
CREATE OR REPLACE FUNCTION pg_temp.dm_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
  v_cname text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'dm_try: rollback del control' USING ERRCODE = 'P9999';
  EXCEPTION
    WHEN SQLSTATE 'P9999' THEN
      RETURN 'ok';
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
      RETURN SQLSTATE || ':' || COALESCE(v_cname, '');
  END;
END;
$f$;

-- ¿Algún VALOR (no clave) del jsonb es exactamente `p_value`? Mismo predicado
-- para el chequeo real y para su control positivo.
CREATE OR REPLACE FUNCTION pg_temp.dm_has_value(p_json jsonb, p_value text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(bool_or((e.value #>> '{}') = p_value), false)
  FROM   jsonb_each(p_json) AS e;
$f$;

DO $$
DECLARE
  v_failures   text[] := '{}';
  v_owner_a    uuid := gen_random_uuid();
  v_owner_b    uuid := gen_random_uuid();
  v_admin      uuid := gen_random_uuid();
  v_seller     uuid := gen_random_uuid();
  v_viewer     uuid := gen_random_uuid();
  v_users      uuid[];
  v_accounts   uuid[];
  v_account_a  uuid;
  v_account_b  uuid;
  v_member     uuid;
  v_claims_a   text;
  v_claims_b   text;
  v_claims_ad  text;
  v_claims_s   text;
  v_claims_v   text;
  v_email_a    text := 'docmarca-gate-owner-a@test.local';
  v_email_b    text := 'docmarca-gate-owner-b@test.local';

  v_png        text := '\x89504e470d0a1a0a00';
  v_sha        text;
  v_state      text;
  v_msg        text;
  v_int        integer;
  v_text       text;
  v_cnt        bigint;
  v_tbl        text;
  v_result     jsonb;
  v_keys       text;
  r            record;
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'docmarca-gate-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate Documentos ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_owner_b, 'owner-b'), (v_admin, 'admin'),
               (v_seller, 'seller'), (v_viewer, 'viewer')) AS u(id, tag);
  v_users := ARRAY[v_owner_a, v_owner_b, v_admin, v_seller, v_viewer];

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no resolvió las cuentas de los owners';
  END IF;
  -- Todas las cuentas que el alta de los 5 usuarios provisionó (para la limpieza).
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  -- admin / seller / viewer: miembros de A con UN solo rol activo.
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_admin, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'admin');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_viewer, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'viewer');

  UPDATE public.profiles SET business_name = 'Negocio Gate Dueño A', phone = '2615550101' WHERE id = v_owner_a;
  UPDATE public.profiles SET business_name = 'Negocio Gate Dueño B', phone = '2615550202' WHERE id = v_owner_b;

  v_claims_a  := json_build_object('sub', v_owner_a::text, 'role', 'authenticated')::text;
  v_claims_b  := json_build_object('sub', v_owner_b::text, 'role', 'authenticated')::text;
  -- AJUSTE A PROPÓSITO (multiusuario-operativo, tanda A, D1): el admin, el seller y el viewer
  -- tienen DOS membresías (su cuenta personal, que crea handle_new_user, y la A donde son
  -- miembros), y la RLS / el guard de la marca resuelven la cuenta con `current_account_ids()`,
  -- que ahora devuelve la cuenta ACTIVA: sin declararla rige la personal (la más antigua) y la
  -- marca de A sería invisible para ellos. Para trabajar en A su token DECLARA la cuenta A
  -- (app_metadata.account_id — lo que emite el hook cuando A es su cuenta activa).
  v_claims_ad := json_build_object('sub', v_admin::text,   'role', 'authenticated',
                                   'app_metadata', json_build_object('account_id', v_account_a::text))::text;
  v_claims_s  := json_build_object('sub', v_seller::text,  'role', 'authenticated',
                                   'app_metadata', json_build_object('account_id', v_account_a::text))::text;
  v_claims_v  := json_build_object('sub', v_viewer::text,  'role', 'authenticated',
                                   'app_metadata', json_build_object('account_id', v_account_a::text))::text;

  -- ═══ (b) Matriz de CHECKs (capa de CHECK aislada con replica) ═══
  BEGIN
    SET session_replication_role = replica;
    FOR r IN
      SELECT * FROM (VALUES
        -- (caso, columnas, valores SQL, resultado esperado)
        ('display_name válido (80)',          'display_name', format('%L', repeat('x', 80)), 'ok'),
        ('display_name en blanco',            'display_name', $v$'   '$v$,                  '23514:account_branding_display_name_check'),
        ('display_name vacío',                'display_name', $v$''$v$,                     '23514:account_branding_display_name_check'),
        ('display_name 81 caracteres',        'display_name', format('%L', repeat('x', 81)), '23514:account_branding_display_name_check'),
        ('legal_name válido (120)',           'legal_name',   format('%L', repeat('x', 120)), 'ok'),
        ('legal_name 121 caracteres',         'legal_name',   format('%L', repeat('x', 121)), '23514:account_branding_legal_name_check'),
        ('legal_name en blanco',              'legal_name',   $v$' '$v$,                    '23514:account_branding_legal_name_check'),
        ('address válido (200)',              'address',      format('%L', repeat('x', 200)), 'ok'),
        ('address 201 caracteres',            'address',      format('%L', repeat('x', 201)), '23514:account_branding_address_check'),
        ('address en blanco',                 'address',      $v$'  '$v$,                   '23514:account_branding_address_check'),
        ('phone válido (40)',                 'phone',        format('%L', repeat('1', 40)), 'ok'),
        ('phone 41 caracteres',               'phone',        format('%L', repeat('1', 41)), '23514:account_branding_phone_check'),
        ('phone en blanco',                   'phone',        $v$'   '$v$,                  '23514:account_branding_phone_check'),
        ('footer_note válido (280)',          'footer_note',  format('%L', repeat('x', 280)), 'ok'),
        ('footer_note 281 caracteres',        'footer_note',  format('%L', repeat('x', 281)), '23514:account_branding_footer_note_check'),
        ('footer_note en blanco',             'footer_note',  $v$' '$v$,                    '23514:account_branding_footer_note_check'),
        ('email válido',                      'email',        $v$'ventas@sumar.com.ar'$v$,  'ok'),
        ('email sin arroba',                  'email',        $v$'ventas.sumar.com.ar'$v$,  '23514:account_branding_email_check'),
        ('email con espacio',                 'email',        $v$'ven tas@sumar.com.ar'$v$, '23514:account_branding_email_check'),
        ('email sin dominio con punto',       'email',        $v$'ventas@sumar'$v$,         '23514:account_branding_email_check'),
        ('email con marcado',                 'email',        $v$'a<b>@sumar.com.ar'$v$,    '23514:account_branding_email_check'),
        ('email de 121 caracteres',           'email',        format('%L', repeat('a', 108) || '@sumar.com.ar'), '23514:account_branding_email_check'),
        ('tax_id con guiones',                'tax_id',       $v$'20-12345678-6'$v$,        'ok'),
        ('tax_id sin guiones',                'tax_id',       $v$'20123456786'$v$,          'ok'),
        ('tax_id corto',                      'tax_id',       $v$'123'$v$,                  '23514:account_branding_tax_id_check'),
        ('tax_id con guiones mal puestos',    'tax_id',       $v$'20-1234567-86'$v$,        '23514:account_branding_tax_id_check'),
        ('tax_id con letras',                 'tax_id',       $v$'20-1234567a-6'$v$,        '23514:account_branding_tax_id_check'),
        ('website válido',                    'website',      $v$'https://www.sumar.com.ar'$v$, 'ok'),
        ('website con espacio',               'website',      $v$'sumar com.ar'$v$,         '23514:account_branding_website_check'),
        ('website con marcado <',             'website',      $v$'sumar.com.ar<script>'$v$, '23514:account_branding_website_check'),
        ('website con comillas',              'website',      $v$'sumar"onload'$v$,         '23514:account_branding_website_check'),
        ('website de 121 caracteres',         'website',      format('%L', repeat('a', 121)), '23514:account_branding_website_check'),
        ('paleta del catálogo',               'palette_preset', $v$'bordo'$v$,              'ok'),
        ('paleta fuera del catálogo',         'palette_preset', $v$'rosa'$v$,               '23514:account_branding_palette_preset_check'),
        ('personalizado con color válido',    'palette_preset, accent_color', $v$'personalizado', '#7c2d12'$v$, 'ok'),
        ('personalizado sin color',           'palette_preset', $v$'personalizado'$v$,      '23514:account_branding_palette_accent_coherent_check'),
        ('color con una paleta del catálogo', 'palette_preset, accent_color', $v$'azul', '#112233'$v$, '23514:account_branding_palette_accent_coherent_check'),
        ('color con mayúsculas',              'palette_preset, accent_color', $v$'personalizado', '#ABCDEF'$v$, '23514:account_branding_accent_color_check'),
        ('color de 3 dígitos',                'palette_preset, accent_color', $v$'personalizado', '#abc'$v$, '23514:account_branding_accent_color_check'),
        ('color sin almohadilla',             'palette_preset, accent_color', $v$'personalizado', '7c2d12'$v$, '23514:account_branding_accent_color_check'),
        ('logo PNG completo',                 'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\x89504e470d0a1a0a00'::bytea, 'image/png', %L, 1000, 250, now()$v$, repeat('a', 64)), 'ok'),
        ('logo JPEG completo',                'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\xffd8ffe000'::bytea, 'image/jpeg', %L, 750, 1000, now()$v$, repeat('b', 64)), 'ok'),
        ('logo parcial (sólo el tipo)',       'logo_mime', $v$'image/png'$v$,               '23514:account_branding_logo_all_or_nothing_check'),
        ('logo parcial (sin huella)',         'logo_image, logo_mime, logo_width, logo_height, logo_updated_at',
            $v$'\x89504e470d0a1a0a00'::bytea, 'image/png', 10, 10, now()$v$,              '23514:account_branding_logo_all_or_nothing_check'),
        ('logo: el tipo dice JPEG y los bytes son PNG', 'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\x89504e470d0a1a0a00'::bytea, 'image/jpeg', %L, 10, 10, now()$v$, repeat('a', 64)), '23514:account_branding_logo_signature_check'),
        ('logo: el tipo dice PNG y los bytes son JPEG', 'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\xffd8ffe000'::bytea, 'image/png', %L, 10, 10, now()$v$, repeat('a', 64)), '23514:account_branding_logo_signature_check'),
        ('logo: bytes sin firma de imagen',   'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\x0011223344'::bytea, 'image/png', %L, 10, 10, now()$v$, repeat('a', 64)), '23514:account_branding_logo_signature_check'),
        ('logo: tipo fuera de PNG/JPEG',      'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\x89504e470d0a1a0a00'::bytea, 'image/gif', %L, 10, 10, now()$v$, repeat('a', 64)), '23514:account_branding_logo_mime_check'),
        ('logo de exactamente 300 KB',        'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$decode('89504e470d0a1a0a' || repeat('00', 307192), 'hex'), 'image/png', %L, 10, 10, now()$v$, repeat('a', 64)), 'ok'),
        ('logo de 300 KB + 1 byte',           'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$decode('89504e470d0a1a0a' || repeat('00', 307193), 'hex'), 'image/png', %L, 10, 10, now()$v$, repeat('a', 64)), '23514:account_branding_logo_size_check'),
        ('logo: huella con forma inválida',   'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            $v$'\x89504e470d0a1a0a00'::bytea, 'image/png', 'no-es-una-huella', 10, 10, now()$v$, '23514:account_branding_logo_sha256_check'),
        ('logo: huella en mayúsculas',        'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\x89504e470d0a1a0a00'::bytea, 'image/png', %L, 10, 10, now()$v$, repeat('A', 64)), '23514:account_branding_logo_sha256_check'),
        ('logo: ancho 1001',                  'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\x89504e470d0a1a0a00'::bytea, 'image/png', %L, 1001, 10, now()$v$, repeat('a', 64)), '23514:account_branding_logo_dimensions_check'),
        ('logo: alto 0',                      'logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at',
            format($v$'\x89504e470d0a1a0a00'::bytea, 'image/png', %L, 10, 0, now()$v$, repeat('a', 64)), '23514:account_branding_logo_dimensions_check')
      ) AS t(caso, cols, vals, esperado)
    LOOP
      v_state := pg_temp.dm_try(format('INSERT INTO public.account_branding (account_id, %s) VALUES (%L, %s)',
                                       r.cols, v_account_a, r.vals));
      IF v_state IS DISTINCT FROM r.esperado THEN
        v_failures := v_failures || format('(b) %s: se esperaba %s; salió %s', r.caso, r.esperado, v_state);
      END IF;
    END LOOP;
    -- Fila completa y válida: el conjunto de CHECKs no rechaza una marca real.
    v_state := pg_temp.dm_try(format($q$INSERT INTO public.account_branding
        (account_id, display_name, legal_name, tax_id, address, phone, email, website, footer_note, palette_preset,
         accent_color, logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at)
      VALUES (%L, 'Sumar', 'Ropa Deportiva SRL', '20-12345678-6', 'Calle Falsa 123', '2615550101',
              'ventas@sumar.com.ar', 'sumar.com.ar', 'Alias: sumar.ropa', 'personalizado', '#7c2d12',
              '\x89504e470d0a1a0a00'::bytea, 'image/png', %L, 1000, 250, now())$q$, v_account_a, repeat('c', 64)));
    IF v_state <> 'ok' THEN
      v_failures := v_failures || format('(b) la fila completa y válida debía aceptarse; salió %s', v_state);
    END IF;
    SET session_replication_role = DEFAULT;
  EXCEPTION WHEN OTHERS THEN
    SET session_replication_role = DEFAULT;
    v_failures := v_failures || format('(b) error inesperado: %s %s', SQLSTATE, SQLERRM);
  END;

  -- ═══ (c) RLS y guard ═══
  BEGIN
    -- (c0) Antes de que exista la fila: seller y viewer no insertan (guard: P0401).
    FOR r IN SELECT * FROM (VALUES ('seller', v_claims_s), ('viewer', v_claims_v)) AS t(quien, claims) LOOP
      PERFORM set_config('request.jwt.claims', r.claims, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      BEGIN
        INSERT INTO public.account_branding (account_id, display_name) VALUES (v_account_a, 'intento ' || r.quien);
        v_state := 'ok';
      EXCEPTION WHEN OTHERS THEN
        v_state := SQLSTATE;
      END;
      EXECUTE 'RESET ROLE';
      IF v_state <> 'P0401' THEN
        v_failures := v_failures || format('(c0) INSERT de un %s debía rechazarse con P0401 (guard owner/admin); salió %s', r.quien, v_state);
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM public.account_branding WHERE account_id = v_account_a) THEN
      v_failures := v_failures || '(c0) quedó una fila de marca de A a pesar de los rechazos'::text;
    END IF;

    -- (c1) La RLS por sí sola. Con el disparador desactivado (DDL transaccional
    --      de la fixture): el viewer y otra cuenta chocan con la RLS (42501 "row-level
    --      security"); el seller PASA la RLS (es escritor) — prueba que el guard es
    --      lo que restringe a owner/admin, y que la RLS es lo que cierra a los no
    --      escritores y a otras cuentas.
    ALTER TABLE public.account_branding DISABLE TRIGGER trg_account_branding_guard_owner_admin;
    FOR r IN SELECT * FROM (VALUES ('viewer', v_claims_v, true), ('otra cuenta', v_claims_b, true), ('seller', v_claims_s, false))
                      AS t(quien, claims, debe_fallar) LOOP
      PERFORM set_config('request.jwt.claims', r.claims, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      BEGIN
        INSERT INTO public.account_branding (account_id, display_name) VALUES (v_account_a, 'rls ' || r.quien);
        v_state := 'ok';
        v_msg := '';
      EXCEPTION WHEN OTHERS THEN
        v_state := SQLSTATE;
        v_msg := SQLERRM;
      END;
      EXECUTE 'RESET ROLE';
      IF r.debe_fallar AND (v_state <> '42501' OR v_msg NOT ILIKE '%row-level security%') THEN
        v_failures := v_failures || format('(c1) RLS sola: INSERT de %s debía fallar con 42501 "row-level security"; salió %s / %s', r.quien, v_state, v_msg);
      ELSIF NOT r.debe_fallar AND v_state <> 'ok' THEN
        v_failures := v_failures || format('(c1) RLS sola: el seller (escritor) debía pasar la RLS; salió %s / %s', v_state, v_msg);
      END IF;
      -- Se limpia lo que haya entrado (como postgres; authenticated no tiene DELETE).
      DELETE FROM public.account_branding WHERE account_id = v_account_a;
    END LOOP;
    ALTER TABLE public.account_branding ENABLE TRIGGER trg_account_branding_guard_owner_admin;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.account_branding'::regclass
                   AND tgname = 'trg_account_branding_guard_owner_admin' AND tgenabled = 'O') THEN
      v_failures := v_failures || '(c1) el disparador de guard no quedó habilitado'::text;
    END IF;

    -- (c2) El owner inserta la marca completa de A (con logo) y el admin la actualiza.
    v_sha := encode(sha256(decode(substr(v_png, 3), 'hex')), 'hex');
    PERFORM set_config('request.jwt.claims', v_claims_a, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      INSERT INTO public.account_branding
        (account_id, display_name, legal_name, tax_id, address, phone, email, website, footer_note, palette_preset,
         logo_image, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at, updated_by)
      VALUES (v_account_a, 'Marca Gate', 'Razón Marca SRL', '20-11111111-2', 'Calle Marca 123', '2615550999',
              'ventas@marcagate.test', 'marcagate.test', 'Alias: marca.gate', 'azul',
              decode(substr(v_png, 3), 'hex'), 'image/png', v_sha, 100, 50, now(), v_owner_a);
      v_state := 'ok';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> 'ok' THEN
      v_failures := v_failures || format('(c2) el owner debía poder insertar la marca de su cuenta; salió %s', v_state);
    END IF;

    PERFORM set_config('request.jwt.claims', v_claims_ad, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      UPDATE public.account_branding SET footer_note = 'Alias: marca.gate.admin', updated_at = now() WHERE account_id = v_account_a;
      GET DIAGNOSTICS v_int = ROW_COUNT;
      v_state := 'ok:' || v_int;
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> 'ok:1' THEN
      v_failures := v_failures || format('(c2) el admin debía poder actualizar la marca; salió %s', v_state);
    ELSIF (SELECT footer_note FROM public.account_branding WHERE account_id = v_account_a) IS DISTINCT FROM 'Alias: marca.gate.admin' THEN
      v_failures := v_failures || '(c2) la actualización del admin no quedó escrita'::text;
    END IF;
    UPDATE public.account_branding SET footer_note = 'Alias: marca.gate' WHERE account_id = v_account_a;

    -- (c3) El seller no actualiza (P0401) y la fila no cambia; el viewer no actualiza (0 filas).
    PERFORM set_config('request.jwt.claims', v_claims_s, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      UPDATE public.account_branding SET display_name = 'hackeado por seller' WHERE account_id = v_account_a;
      v_state := 'ok';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> 'P0401' THEN
      v_failures := v_failures || format('(c3) UPDATE por un seller debía rechazarse con P0401; salió %s', v_state);
    END IF;

    PERFORM set_config('request.jwt.claims', v_claims_v, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      UPDATE public.account_branding SET display_name = 'hackeado por viewer' WHERE account_id = v_account_a;
      GET DIAGNOSTICS v_int = ROW_COUNT;
      v_state := 'ok:' || v_int;
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
    END;
    -- El viewer SÍ lee la marca de su cuenta (control positivo de la visibilidad).
    SELECT count(*) INTO v_cnt FROM public.account_branding WHERE account_id = v_account_a;
    EXECUTE 'RESET ROLE';
    IF v_state NOT IN ('ok:0', 'P0401', '42501') THEN
      v_failures := v_failures || format('(c3) UPDATE por un viewer debía afectar 0 filas o rechazarse; salió %s', v_state);
    END IF;
    IF v_cnt <> 1 THEN
      v_failures := v_failures || format('(c3) un miembro viewer debía leer la marca de su cuenta; ve %s fila(s)', v_cnt);
    END IF;
    IF (SELECT display_name FROM public.account_branding WHERE account_id = v_account_a) IS DISTINCT FROM 'Marca Gate' THEN
      v_failures := v_failures || '(c3) la fila cambió a pesar de los rechazos del seller/viewer'::text;
    END IF;

    -- (c4) Otra cuenta: no la lee, no la actualiza, no inserta en A.
    PERFORM set_config('request.jwt.claims', v_claims_b, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_cnt FROM public.account_branding WHERE account_id = v_account_a;
    BEGIN
      UPDATE public.account_branding SET display_name = 'hackeado por B' WHERE account_id = v_account_a;
      GET DIAGNOSTICS v_int = ROW_COUNT;
      v_state := 'ok:' || v_int;
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
    END;
    BEGIN
      INSERT INTO public.account_branding (account_id, display_name) VALUES (v_account_a, 'insert de B en A');
      v_text := 'ok';
    EXCEPTION WHEN OTHERS THEN
      v_text := SQLSTATE;
    END;
    EXECUTE 'RESET ROLE';
    IF v_cnt <> 0 THEN
      v_failures := v_failures || format('(c4) la cuenta B ve %s fila(s) de la marca de A', v_cnt);
    END IF;
    IF v_state NOT IN ('ok:0', '42501', 'P0401') THEN
      v_failures := v_failures || format('(c4) la cuenta B no debía poder actualizar la marca de A; salió %s', v_state);
    END IF;
    IF v_text = 'ok' THEN
      v_failures := v_failures || '(c4) la cuenta B pudo insertar en la cuenta A'::text;
    END IF;
    IF (SELECT display_name FROM public.account_branding WHERE account_id = v_account_a) IS DISTINCT FROM 'Marca Gate' THEN
      v_failures := v_failures || '(c4) la fila de A cambió por una escritura de B'::text;
    END IF;

    -- (c5) account_id inmutable: el owner de A no muda su fila a la cuenta B.
    PERFORM set_config('request.jwt.claims', v_claims_a, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      UPDATE public.account_branding SET account_id = v_account_b WHERE account_id = v_account_a;
      v_state := 'ok';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> 'P0401' THEN
      v_failures := v_failures || format('(c5) mudar account_id debía rechazarse con P0401; salió %s', v_state);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.account_branding WHERE account_id = v_account_a)
       OR EXISTS (SELECT 1 FROM public.account_branding WHERE account_id = v_account_b) THEN
      v_failures := v_failures || '(c5) la fila se mudó de cuenta a pesar del rechazo'::text;
    END IF;

    -- (c6) Sin DELETE ni TRUNCATE: 42501 con texto "permission denied" (capa de
    --      privilegio, no de RLS) y la fila sobrevive.
    PERFORM set_config('request.jwt.claims', v_claims_a, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      DELETE FROM public.account_branding WHERE account_id = v_account_a;
      v_state := 'ok';
      v_msg := '';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
      v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> '42501' OR v_msg NOT ILIKE 'permission denied%' THEN
      v_failures := v_failures || format('(c6) DELETE del owner debía fallar con 42501 "permission denied"; salió %s / %s', v_state, v_msg);
    END IF;
    PERFORM set_config('request.jwt.claims', v_claims_a, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      TRUNCATE public.account_branding;
      v_state := 'ok';
      v_msg := '';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
      v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> '42501' OR v_msg NOT ILIKE 'permission denied%' THEN
      v_failures := v_failures || format('(c6) TRUNCATE del owner debía fallar con 42501 "permission denied"; salió %s / %s', v_state, v_msg);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.account_branding WHERE account_id = v_account_a) THEN
      v_failures := v_failures || '(c6) la fila de marca desapareció (DELETE/TRUNCATE no debían poder borrarla)'::text;
    END IF;

    -- (c7) anon no lee.
    PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE 'SET LOCAL ROLE anon';
    BEGIN
      SELECT count(*) INTO v_cnt FROM public.account_branding;
      v_state := 'ok';
      v_msg := '';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
      v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> '42501' OR v_msg NOT ILIKE 'permission denied%' THEN
      v_failures := v_failures || format('(c7) anon no debía leer account_branding (42501 permission denied); salió %s / %s', v_state, v_msg);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    BEGIN EXECUTE 'RESET ROLE'; EXCEPTION WHEN OTHERS THEN NULL; END;
    v_failures := v_failures || format('(c) error inesperado: %s %s', SQLSTATE, SQLERRM);
  END;

  -- ═══ (d) rpc_commercial_issuer ═══
  BEGIN
    -- Perfil fiscal de A (CUIT sintético de la allow-list de fixtures).
    INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, razon_social, nombre_fantasia, domicilio_comercial)
    VALUES (v_account_a, '20123456786', 'monotributista', 'Razón Fiscal Gate SRL', 'Fantasía Gate', 'Calle Fiscal 1');

    -- (d1) Como vendedor que NO es el dueño.
    PERFORM set_config('request.jwt.claims', v_claims_s, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      v_result := public.rpc_commercial_issuer(v_account_a);
    EXCEPTION WHEN OTHERS THEN
      v_result := NULL;
      v_failures := v_failures || format('(d1) rpc_commercial_issuer como seller falló: %s %s', SQLSTATE, SQLERRM);
    END;
    EXECUTE 'RESET ROLE';
    IF v_result IS NOT NULL THEN
      SELECT string_agg(k, ',' ORDER BY k) INTO v_keys FROM jsonb_object_keys(v_result) AS k;
      IF v_keys IS DISTINCT FROM
         'accent_color,brand_address,brand_display_name,brand_email,brand_footer_note,brand_legal_name,brand_phone,brand_tax_id,brand_website,business_name,cuit,domicilio_comercial,iva_condition,logo_sha256,nombre_fantasia,palette_preset,phone,razon_social' THEN
        v_failures := v_failures || format('(d1) rpc_commercial_issuer debía devolver EXACTAMENTE las 18 claves del design D4; devolvió %s', v_keys);
      END IF;
      -- legadas (perfil fiscal + perfil del dueño)
      IF v_result->>'business_name' IS DISTINCT FROM 'Negocio Gate Dueño A' OR v_result->>'phone' IS DISTINCT FROM '2615550101'
         OR v_result->>'nombre_fantasia' IS DISTINCT FROM 'Fantasía Gate' OR v_result->>'razon_social' IS DISTINCT FROM 'Razón Fiscal Gate SRL'
         OR v_result->>'cuit' IS DISTINCT FROM '20123456786' OR v_result->>'domicilio_comercial' IS DISTINCT FROM 'Calle Fiscal 1' THEN
        v_failures := v_failures || format('(d1) valores legados incorrectos (perfil fiscal / dueño): %s', v_result);
      END IF;
      -- nuevas
      IF v_result->>'iva_condition' IS DISTINCT FROM 'monotributista' THEN
        v_failures := v_failures || format('(d1) iva_condition debía salir del perfil fiscal; salió %s', v_result->>'iva_condition');
      END IF;
      IF v_result->>'brand_display_name' IS DISTINCT FROM 'Marca Gate' OR v_result->>'brand_legal_name' IS DISTINCT FROM 'Razón Marca SRL'
         OR v_result->>'brand_tax_id' IS DISTINCT FROM '20-11111111-2' OR v_result->>'brand_address' IS DISTINCT FROM 'Calle Marca 123'
         OR v_result->>'brand_phone' IS DISTINCT FROM '2615550999' OR v_result->>'brand_email' IS DISTINCT FROM 'ventas@marcagate.test'
         OR v_result->>'brand_website' IS DISTINCT FROM 'marcagate.test' OR v_result->>'brand_footer_note' IS DISTINCT FROM 'Alias: marca.gate'
         OR v_result->>'palette_preset' IS DISTINCT FROM 'azul' OR (v_result->'accent_color') IS DISTINCT FROM 'null'::jsonb
         OR v_result->>'logo_sha256' IS DISTINCT FROM v_sha THEN
        v_failures := v_failures || format('(d1) valores de la marca incorrectos: %s', v_result);
      END IF;
      -- Nunca el email de Auth del dueño (ni de nadie del fixture) como VALOR.
      IF pg_temp.dm_has_value(v_result, v_email_a) OR pg_temp.dm_has_value(v_result, v_email_b)
         OR pg_temp.dm_has_value(v_result, 'docmarca-gate-seller@test.local') THEN
        v_failures := v_failures || format('(d1) un VALOR de la lectura del emisor es un email de acceso: %s', v_result);
      END IF;
      -- Control positivo del predicado: si el email estuviera, lo detectaría.
      IF NOT pg_temp.dm_has_value(v_result || jsonb_build_object('contacto', v_email_a), v_email_a) THEN
        v_failures := v_failures || '(d1) el predicado de "ningún valor es un email de acceso" no detecta un email plantado (gate vacuo)'::text;
      END IF;
      -- La imagen NUNCA viaja en la lectura.
      IF v_result::text LIKE '%logo_image%' OR length(v_result::text) > 2000 THEN
        v_failures := v_failures || format('(d1) la lectura del emisor no debe incluir la imagen del logo (largo %s)', length(v_result::text));
      END IF;
    END IF;

    -- (d2) Cuenta SIN fila de marca (B): claves nuevas NULL, legadas intactas.
    PERFORM set_config('request.jwt.claims', v_claims_b, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      v_result := public.rpc_commercial_issuer(v_account_b);
    EXCEPTION WHEN OTHERS THEN
      v_result := NULL;
      v_failures := v_failures || format('(d2) rpc_commercial_issuer sobre una cuenta sin marca falló: %s %s', SQLSTATE, SQLERRM);
    END;
    EXECUTE 'RESET ROLE';
    IF v_result IS NOT NULL THEN
      SELECT string_agg(k, ',' ORDER BY k) INTO v_keys FROM jsonb_object_keys(v_result) AS k;
      IF array_length(string_to_array(v_keys, ','), 1) IS DISTINCT FROM 18 THEN
        v_failures := v_failures || format('(d2) sin fila de marca también debían salir las 18 claves; salió %s', v_keys);
      END IF;
      IF v_result->>'business_name' IS DISTINCT FROM 'Negocio Gate Dueño B' OR v_result->>'phone' IS DISTINCT FROM '2615550202' THEN
        v_failures := v_failures || format('(d2) sin marca las claves legadas debían ser las del perfil del dueño: %s', v_result);
      END IF;
      IF (v_result->'brand_display_name') IS DISTINCT FROM 'null'::jsonb OR (v_result->'brand_legal_name') IS DISTINCT FROM 'null'::jsonb
         OR (v_result->'brand_tax_id') IS DISTINCT FROM 'null'::jsonb OR (v_result->'brand_address') IS DISTINCT FROM 'null'::jsonb
         OR (v_result->'brand_phone') IS DISTINCT FROM 'null'::jsonb OR (v_result->'brand_email') IS DISTINCT FROM 'null'::jsonb
         OR (v_result->'brand_website') IS DISTINCT FROM 'null'::jsonb OR (v_result->'brand_footer_note') IS DISTINCT FROM 'null'::jsonb
         OR (v_result->'palette_preset') IS DISTINCT FROM 'null'::jsonb OR (v_result->'accent_color') IS DISTINCT FROM 'null'::jsonb
         OR (v_result->'logo_sha256') IS DISTINCT FROM 'null'::jsonb OR (v_result->'iva_condition') IS DISTINCT FROM 'null'::jsonb THEN
        v_failures := v_failures || format('(d2) sin fila de marca ni perfil fiscal las claves nuevas debían ser NULL: %s', v_result);
      END IF;
      IF pg_temp.dm_has_value(v_result, v_email_b) THEN
        v_failures := v_failures || '(d2) la lectura de la cuenta B incluye el email de acceso de su dueño'::text;
      END IF;
    END IF;

    -- (d3) Otra cuenta no lee el emisor de A: P0404 account_not_found.
    PERFORM set_config('request.jwt.claims', v_claims_b, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      PERFORM public.rpc_commercial_issuer(v_account_a);
      v_state := 'ok';
      v_msg := '';
    EXCEPTION WHEN OTHERS THEN
      v_state := SQLSTATE;
      v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_state <> 'P0404' OR v_msg NOT LIKE 'account_not_found%' THEN
      v_failures := v_failures || format('(d3) otra cuenta -> P0404 account_not_found; salió %s / %s', v_state, v_msg);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    BEGIN EXECUTE 'RESET ROLE'; EXCEPTION WHEN OTHERS THEN NULL; END;
    v_failures := v_failures || format('(d) error inesperado: %s %s', SQLSTATE, SQLERRM);
  END;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE DOCUMENTOS-MARCA-EMPRESA (b,c,d) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (b,c,d): matriz de CHECKs (con control positivo por campo), RLS + guard (owner/admin escriben; seller P0401; viewer; otra cuenta ciega; account_id inmutable; sin DELETE/TRUNCATE con permission denied; anon no lee) y rpc_commercial_issuer (18 claves, valores, sin email de acceso, sin fila de marca, P0404).';

  -- ═══ (f) Limpieza asertada ═══
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
      v_failures := v_failures || format('(f) residuo: %s fila(s) del fixture en %s', v_cnt, v_tbl);
    END IF;
  END LOOP;
  SELECT count(*) INTO v_cnt FROM public.accounts WHERE id = ANY(v_accounts);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(f) residuo: %s cuenta(s) del fixture', v_cnt); END IF;
  SELECT count(*) INTO v_cnt FROM auth.users WHERE id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(f) residuo: %s usuario(s) del fixture', v_cnt); END IF;
  SELECT count(*) INTO v_cnt FROM public.profiles WHERE id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(f) residuo: %s profiles del fixture', v_cnt); END IF;
  SELECT count(*) INTO v_cnt FROM public.billing_events WHERE user_id = ANY(v_users);
  IF v_cnt <> 0 THEN v_failures := v_failures || format('(f) residuo: %s billing_events del fixture', v_cnt); END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE DOCUMENTOS-MARCA-EMPRESA (f) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (f): limpieza verificada — cero filas del fixture en toda tabla de public con account_id.';

EXCEPTION
  WHEN OTHERS THEN
    -- El bloque se revierte entero al propagar el error: el fixture no
    -- persiste. Sólo hay que devolver el rol y el modo de replicación.
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- GATE DOCUMENTOS-MARCA-EMPRESA PASSED (2 bloques: introspección + b/c/d/f).
-- =============================================================================
