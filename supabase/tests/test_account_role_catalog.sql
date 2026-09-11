-- =============================================================================
-- GATE: test_account_role_catalog.sql (7 bloques)
-- CHANGE: v3-rbac-multirole Parte A, grupo 2 (D1, D2) — catálogo de roles.
--
-- No depende de auth.uid() ni de un anchor sintético: todo lo que este gate
-- verifica es estructural (catálogo de datos + privilegios de tabla + RLS),
-- así que corre siempre en verde sin condiciones de entorno.
--
--   (1) el catálogo tiene EXACTAMENTE 8 filas, códigos en minúscula.
--   (2) sólo 'viewer' tiene is_writer=false; las otras 7 tienen true.
--   (3) authenticated NO puede INSERT/UPDATE/DELETE sobre el catálogo.
--   (4) authenticated SÍ puede SELECT (grant de tabla + policy RLS).
--   (5) la policy de SELECT está scopeada a `authenticated` (no a `public`
--       ni a `anon`) — anon no tiene ninguna policy que le dé filas.
--   (6) integridad referencial: account_member_roles.role sólo acepta
--       códigos del catálogo — un código inventado se rechaza (23503), sin
--       dejar la fila insertada.
--   (7) is_writer es un DATO editable sin tocar ninguna función ni RLS —
--       cambiarlo y revertirlo no requiere DDL de ningún otro objeto.
--
-- RONDA 2 DE REVISIÓN ADVERSARIAL (finding nit, corregido): el bloque (6)
-- resolvía el anchor de auth.users DESPUÉS de intentar el INSERT en
-- accounts (con owner_user_id NULLABLE, ese INSERT SIEMPRE inserta —
-- FOUND siempre es TRUE, incluso con auth.users vacío — así que la rama de
-- degradación era inalcanzable; con auth.users vacío lo que pasaba en su
-- lugar era que el INSERT siguiente en account_members reventaba con
-- 23502, no degradaba). Ahora se resuelve el anchor ANTES y se decide con
-- él; v_expected_blocks baja a 6 si degrada, para que el conteo final no
-- aborte el gate por algo que su propio comentario decía que no debía
-- abortarlo.
-- =============================================================================

DO $$
DECLARE
  v_blocks_run      int := 0;
  v_expected_blocks int := 7;
  v_count      int;
  v_codes      text[];
  v_writers    text[];
  v_test_account uuid;
  v_test_member  uuid;
  v_anchor_user  uuid;
BEGIN
  -- (1) 8 filas, códigos en minúscula
  SELECT count(*), array_agg(code ORDER BY code) INTO v_count, v_codes
  FROM public.account_role_catalog;

  IF v_count <> 8 THEN
    RAISE EXCEPTION 'GATE FAILED (1): se esperaban 8 roles en el catálogo, hay %', v_count;
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(v_codes) c WHERE c <> lower(c)) THEN
    RAISE EXCEPTION 'GATE FAILED (1): hay códigos con mayúsculas: %', v_codes;
  END IF;

  IF v_codes <> ARRAY['accountant','admin','cashier','owner','purchases','seller','stock','viewer'] THEN
    RAISE EXCEPTION 'GATE FAILED (1): el conjunto de códigos no es el esperado: %', v_codes;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (1): 8 roles, todos en minúscula: %', v_codes;

  -- (2) sólo viewer es is_writer=false
  SELECT array_agg(code ORDER BY code) INTO v_writers
  FROM public.account_role_catalog WHERE is_writer = false;

  IF v_writers <> ARRAY['viewer'] THEN
    RAISE EXCEPTION 'GATE FAILED (2): se esperaba is_writer=false SÓLO en viewer, encontrado: %', v_writers;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2): sólo viewer tiene is_writer=false';

  -- (3) authenticated no puede escribir el catálogo
  IF has_table_privilege('authenticated', 'public.account_role_catalog', 'INSERT') THEN
    RAISE EXCEPTION 'GATE FAILED (3): authenticated puede INSERT sobre el catálogo';
  END IF;
  IF has_table_privilege('authenticated', 'public.account_role_catalog', 'UPDATE') THEN
    RAISE EXCEPTION 'GATE FAILED (3): authenticated puede UPDATE sobre el catálogo';
  END IF;
  IF has_table_privilege('authenticated', 'public.account_role_catalog', 'DELETE') THEN
    RAISE EXCEPTION 'GATE FAILED (3): authenticated puede DELETE sobre el catálogo';
  END IF;
  IF has_table_privilege('anon', 'public.account_role_catalog', 'INSERT') THEN
    RAISE EXCEPTION 'GATE FAILED (3): anon puede INSERT sobre el catálogo';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3): ni authenticated ni anon pueden alterar el catálogo';

  -- (4) authenticated sí puede leer
  IF NOT has_table_privilege('authenticated', 'public.account_role_catalog', 'SELECT') THEN
    RAISE EXCEPTION 'GATE FAILED (4): authenticated no puede SELECT sobre el catálogo';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (4): authenticated puede leer el catálogo';

  -- (5) la policy de SELECT está scopeada a authenticated, no a public/anon
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'account_role_catalog'
      AND cmd = 'SELECT' AND 'authenticated' = ANY(roles)
  ) THEN
    RAISE EXCEPTION 'GATE FAILED (5): no hay policy de SELECT scopeada a authenticated';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'account_role_catalog'
      AND ('anon' = ANY(roles) OR 'public' = ANY(roles))
  ) THEN
    RAISE EXCEPTION 'GATE FAILED (5): existe una policy que alcanza a anon/public sobre el catálogo';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (5): la policy de lectura sólo alcanza a authenticated';

  -- (6) un rol fuera del catálogo se rechaza por integridad referencial
  --     (usa una cuenta/miembro sintéticos SIN pasar por handle_new_user,
  --     para no depender del signup — sólo se necesita una fila válida en
  --     account_members a la que apuntar). Resolver el anchor ANTES de
  --     insertar (ronda 2) — accounts.owner_user_id es NULLABLE, así que
  --     probar la degradación DESPUÉS del INSERT nunca la alcanzaba.
  SELECT id INTO v_anchor_user FROM auth.users LIMIT 1;
  IF v_anchor_user IS NULL THEN
    -- degrade-don't-fail: sin ningún auth.users sembrado no se puede armar
    -- el fixture de este bloque puntual — se documenta y no se aborta el
    -- gate completo por esto (el resto de los bloques no depende de esto).
    v_expected_blocks := 6;
    RAISE NOTICE 'GATE DEGRADED (6): no hay ningún auth.users para anclar el fixture — se omite el bloque de integridad referencial.';
  ELSE
    v_test_account := gen_random_uuid();
    INSERT INTO public.accounts (id, owner_user_id) VALUES (v_test_account, v_anchor_user);

    INSERT INTO public.account_members (id, account_id, user_id, role)
      VALUES (gen_random_uuid(), v_test_account, v_anchor_user, 'member')
      ON CONFLICT (account_id, user_id) DO UPDATE SET role = EXCLUDED.role
      RETURNING id INTO v_test_member;

    BEGIN
      INSERT INTO public.account_member_roles (account_id, member_id, role)
      VALUES (v_test_account, v_test_member, 'rol_inventado_fuera_de_catalogo');
      RAISE EXCEPTION 'GATE FAILED (6): un rol fuera del catálogo NO fue rechazado';
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE NOTICE 'PASS (6): rol fuera del catálogo rechazado por FK (23503)';
    END;

    IF EXISTS (SELECT 1 FROM public.account_member_roles WHERE member_id = v_test_member AND role = 'rol_inventado_fuera_de_catalogo') THEN
      RAISE EXCEPTION 'GATE FAILED (6): quedó una fila con un rol inválido';
    END IF;

    -- cleanup del fixture puntual de este bloque
    DELETE FROM public.account_member_roles WHERE member_id = v_test_member;
    DELETE FROM public.account_members WHERE id = v_test_member;
    SET session_replication_role = replica;
    DELETE FROM public.accounts WHERE id = v_test_account;
    SET session_replication_role = DEFAULT;
    v_blocks_run := v_blocks_run + 1;
  END IF;

  -- (7) is_writer es un dato editable sin tocar código
  UPDATE public.account_role_catalog SET is_writer = false WHERE code = 'seller';
  IF (SELECT is_writer FROM public.account_role_catalog WHERE code = 'seller') <> false THEN
    RAISE EXCEPTION 'GATE FAILED (7): no se pudo cambiar is_writer del catálogo por UPDATE simple';
  END IF;
  -- revertir — el catálogo real no debe quedar alterado por este gate
  UPDATE public.account_role_catalog SET is_writer = true WHERE code = 'seller';
  IF (SELECT is_writer FROM public.account_role_catalog WHERE code = 'seller') <> true THEN
    RAISE EXCEPTION 'GATE FAILED (7): no se pudo revertir is_writer del catálogo';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (7): is_writer se edita y revierte con un UPDATE de datos, sin DDL';

  IF v_blocks_run <> v_expected_blocks THEN
    RAISE EXCEPTION 'GATE ACCOUNT-ROLE-CATALOG FAILED (conteo): se ejercitaron % de % bloques esperados.', v_blocks_run, v_expected_blocks;
  END IF;

  RAISE NOTICE 'GATE ACCOUNT-ROLE-CATALOG: %/% bloques PASS.', v_blocks_run, v_expected_blocks;
END $$;
