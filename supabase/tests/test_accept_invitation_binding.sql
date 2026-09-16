-- =============================================================================
-- GATE: test_accept_invitation_binding.sql
-- CHANGE: auth-hardening-jwt-cookies Parte A, grupo 8 (D14, specs
-- account-membership-roles "La aceptación de una invitación exige la identidad
-- invitada" / "… toma lock sobre la invitación").
--
-- Hasta 20261050000001, rpc_accept_invitation validaba token + status
-- 'pending' + expires_at y creaba la membresía para auth.uid() SIN comparar
-- nunca la columna `email`: cualquier sesión autenticada que consiguiera un
-- token podía canjearlo y entrar a la cuenta.
--
--   (1) Una identidad DISTINTA de la invitada -> P0404 con el MISMO texto que
--       el rechazo por token inexistente/vencido (no revela que el token es
--       válido para otro), cero filas nuevas en account_members y en el pivot,
--       y la invitación sigue `pending` (el rechazo no la consume).
--   (2) La identidad invitada acepta con normalidad la MISMA invitación --
--       con los claims en la forma de PostgREST (CON `email`), que cubre la
--       rama del atajo del COALESCE.
--   (3) La comparación ignora mayúsculas: invitación cargada en MAYÚSCULAS
--       (INSERT directo -- rpc_invite_member ya normaliza con lower(trim())),
--       identidad en minúsculas -> se acepta.
--   (4) EL BLOQUE QUE DECIDE SI ESTO FUNCIONA EN PRODUCCIÓN: los claims se
--       fijan a EXACTAMENTE {"sub": …, "role": "authenticated"} -- la forma
--       literal que empuja el backend propio (backend/core/database.py:116 y
--       :174), SIN `email` -- y la aceptación legítima igual se completa,
--       porque el email se resuelve contra auth.users dentro del cuerpo
--       SECURITY DEFINER. Un guard keyeado sólo en auth.jwt()->>'email'
--       rechazaría el 100% de las aceptaciones que lleguen por FastAPI (este
--       repo ya tiene una policy muerta por ese error:
--       20260724000001_c31_wsaa_access_tickets.sql:40-41), y un gate que
--       setea los claims a mano CON email pasaría en verde sin probar nada.
--       El bloque assertea la FORMA de los claims (2 claves, sin 'email')
--       antes de llamar a la RPC -- si alguien "arregla" el fixture
--       agregándole el email, el gate falla en vez de degradarse en silencio.
--   (5) Dos aceptaciones del MISMO token: la 2ª se rechaza y no crea una 2ª
--       membresía. LÍMITE DECLARADO: un gate de psql corre en UNA sesión, así
--       que esto ejercita la secuencia SERIALIZADA (el resultado que la spec
--       promete: "sin que se cree una segunda membresía"), no el entrelazado
--       real. La exclusión mutua entre dos transacciones concurrentes la
--       sostiene el `SELECT … FOR UPDATE`, y eso se verifica
--       ESTRUCTURALMENTE en (6) -- que es donde vive el RED de esa mitad.
--   (6) Integridad de función (molde test_operacion_party_guard.sql:521-561):
--       el cuerpo VIVO (con los comentarios removidos, para que un comentario
--       no satisfaga la aserción) contiene el lock, la resolución contra
--       auth.users y la comparación insensible a mayúsculas, y las tres
--       ocurren ANTES de la primera escritura real (el INSERT en
--       account_members).
--   (7) Cero overloads y ACLs exactas: sin EXECUTE para PUBLIC (es
--       PostgreSQL, no Supabase, el que lo otorga por default en toda función
--       nueva -- revocar sólo `anon` dejaría el permiso vivo por esa vía) ni
--       para anon; CON EXECUTE para authenticated y service_role.
-- =============================================================================

DO $$
DECLARE
  v_blocks_run     int := 0;
  v_owner_uid      uuid := gen_random_uuid();
  v_invitee_uid    uuid := gen_random_uuid();
  v_intruder_uid   uuid := gen_random_uuid();
  v_upper_uid      uuid := gen_random_uuid();
  v_backend_uid    uuid := gen_random_uuid();
  v_twice_uid      uuid := gen_random_uuid();
  v_all_uids       uuid[];
  v_account        uuid;
  v_account_ids    uuid[];
  v_result         json;
  v_token          text;
  v_token_upper    text;
  v_token_backend  text;
  v_token_twice    text;
  v_caught_code    text;
  v_caught_msg     text;
  -- Centinela de "la RPC NO rechazó". Existe porque un `RAISE EXCEPTION`
  -- puesto DENTRO del mismo bloque que lo cachea con `EXCEPTION WHEN OTHERS`
  -- se auto-tragaría: el gate seguiría fallando (bien) pero reportando
  -- "esperaba P0404, dio P0001" -- encuadraría un GUARD AUSENTE como un
  -- problema de mapeo de ERRCODE y mandaría a quien lea el CI a buscar en el
  -- lugar equivocado. Medido de verdad: con el cuerpo pre-migración este
  -- archivo falló exactamente así. El flag deja que el caso "no rechazó"
  -- hable con su propio mensaje, fuera del alcance del handler.
  v_not_rejected   boolean;
  v_members_before int;
  v_roles_before   int;
  v_def            text;
  v_pos_lock       int;
  v_pos_users      int;
  v_pos_email      int;
  v_pos_write      int;
  v_claims         jsonb;
  v_count          int;
  v_orphans        int;
BEGIN
  v_all_uids := ARRAY[v_owner_uid, v_invitee_uid, v_intruder_uid, v_upper_uid, v_backend_uid, v_twice_uid];

  BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_owner_uid,    'gate-accept-bind-owner@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_invitee_uid,  'gate-accept-bind-invitee@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_intruder_uid, 'gate-accept-bind-intruder@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_upper_uid,    'gate-accept-bind-upper@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_backend_uid,  'gate-accept-bind-backend@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_twice_uid,    'gate-accept-bind-twice@test.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudieron crear los usuarios ancla (%). Se aborta el gate.', SQLERRM;
    RETURN;
  END;

  SELECT account_id INTO v_account FROM account_members WHERE user_id = v_owner_uid;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: handle_new_user no aprovisionó la cuenta ancla. Se aborta el gate.';
    RETURN;
  END IF;

  -- Plan 'pro' (max_users = 10) con el trial apagado: las 4 aceptaciones
  -- legítimas de este gate no deben chocar nunca con el cupo -- si chocaran,
  -- el gate mediría P0402 y no el binding de email (el cupo ya lo cubre
  -- test_invite_member_roles_and_plan_gate.sql).
  UPDATE accounts SET billing_plan = 'pro', trial_plan = NULL, trial_expires_at = NULL
  WHERE id = v_account;

  -- ═══ (1) otra identidad NO puede canjear una invitación dirigida ═════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al owner -- se aborta el gate.';
    RETURN;
  END IF;

  v_result := public.rpc_invite_member('gate-accept-bind-invitee@test.local'::text, v_account, ARRAY['seller']::text[]);
  v_token  := (SELECT token FROM account_invitations WHERE id = (v_result->>'id')::uuid);

  SELECT COUNT(*) INTO v_members_before FROM account_members WHERE account_id = v_account;
  SELECT COUNT(*) INTO v_roles_before   FROM account_member_roles WHERE account_id = v_account;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_intruder_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_intruder_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al intruso -- se omite el bloque 1.';
  ELSE
    v_not_rejected := false;
    BEGIN
      PERFORM public.rpc_accept_invitation(v_token);
      v_not_rejected := true;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
    END;

    IF v_not_rejected THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (1): una identidad distinta de la invitada canjeó la invitación -- el binding de email de D14 no está en el cuerpo vivo.';
    END IF;

    IF v_caught_code <> 'P0404' THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (1): esperaba P0404, dio % (%)', v_caught_code, v_caught_msg;
    END IF;
    -- El rechazo NO debe distinguirse del de un token inexistente/vencido:
    -- mismo ERRCODE y mismo texto (contrato vigente, 20261050000001:349-352).
    IF v_caught_msg NOT ILIKE '%invalid or expired invitation token%' THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (1): el rechazo revela el caso -- esperaba el texto de token inválido/vencido, dio: %', v_caught_msg;
    END IF;

    IF (SELECT COUNT(*) FROM account_members WHERE account_id = v_account) <> v_members_before THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (1): el rechazo dejó una membresía nueva en la cuenta.';
    END IF;
    IF (SELECT COUNT(*) FROM account_member_roles WHERE account_id = v_account) <> v_roles_before THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (1): el rechazo dejó una asignación de rol nueva en el pivot.';
    END IF;
    IF EXISTS (SELECT 1 FROM account_members WHERE account_id = v_account AND user_id = v_intruder_uid) THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (1): el intruso quedó como miembro de la cuenta.';
    END IF;
    IF (SELECT status FROM account_invitations WHERE token = v_token) <> 'pending' THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (1): el rechazo consumió la invitación -- el invitado legítimo ya no podría usarla.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (1): una identidad distinta de la invitada -> P0404 con el texto de token inválido, sin membresía, sin rol, y la invitación sigue pendiente.';
  END IF;

  -- ═══ (2) la identidad invitada acepta con normalidad (claims CON email, ═══
  --     forma de PostgREST -- cubre la rama del atajo del COALESCE)
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_invitee_uid::text, 'role', 'authenticated',
                      'email', 'gate-accept-bind-invitee@test.local')::text,
    true);
  IF auth.uid() IS DISTINCT FROM v_invitee_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve a la invitada -- se omite el bloque 2.';
  ELSE
    IF auth.jwt()->>'email' IS NULL THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (2-fixture): este bloque debe correr CON el claim email presente (rama del atajo); el fixture no lo tiene.';
    END IF;
    v_result := public.rpc_accept_invitation(v_token);
    IF NOT EXISTS (
      SELECT 1 FROM account_member_roles amr
      JOIN account_members am ON am.id = amr.member_id
      WHERE am.account_id = v_account AND am.user_id = v_invitee_uid AND amr.role = 'seller'
    ) THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (2): la invitada aceptó pero no quedó con el rol invitado: %', v_result;
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (2): la identidad invitada acepta con normalidad (claims con email) y recibe su conjunto de roles.';
  END IF;

  -- ═══ (3) la comparación ignora mayúsculas ════════════════════════════════
  --     INSERT directo: rpc_invite_member normaliza con lower(trim()), así que
  --     la fila en MAYÚSCULAS sólo puede nacer de un alta histórica o de otro
  --     camino -- exactamente el caso que el binding no debe rechazar.
  v_token_upper := encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO account_invitations (id, account_id, email, token, role, roles, status, invited_by, created_at, expires_at)
  VALUES (gen_random_uuid(), v_account, 'GATE-ACCEPT-BIND-UPPER@TEST.LOCAL', v_token_upper,
          'member', ARRAY['viewer']::text[], 'pending', v_owner_uid, now(), now() + interval '7 days');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_upper_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_upper_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al invitado en mayúsculas -- se omite el bloque 3.';
  ELSE
    PERFORM public.rpc_accept_invitation(v_token_upper);
    IF NOT EXISTS (SELECT 1 FROM account_members WHERE account_id = v_account AND user_id = v_upper_uid) THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (3): la invitación cargada en MAYÚSCULAS no se aceptó con la identidad en minúsculas.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (3): la comparación de email ignora mayúsculas (lower() en ambos lados).';
  END IF;

  -- ═══ (4) la forma de claims REAL del backend propio ({sub, role}) ════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);
  v_result := public.rpc_invite_member('gate-accept-bind-backend@test.local'::text, v_account, ARRAY['cashier']::text[]);
  v_token_backend := (SELECT token FROM account_invitations WHERE id = (v_result->>'id')::uuid);

  -- EXACTAMENTE la reconstrucción que empuja backend/core/database.py: sólo
  -- `sub` y `role`, nada más. La forma se assertea ANTES de llamar a la RPC.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_backend_uid::text, 'role', 'authenticated')::text, true);
  v_claims := auth.jwt();
  IF v_claims ? 'email' THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (4-fixture): los claims de este bloque NO deben contener email -- es la forma que empuja el backend. Si alguien los "arregló" agregándoselo, el bloque dejaría de probar lo que existe para probar.';
  END IF;
  IF (SELECT COUNT(*) FROM jsonb_object_keys(v_claims)) <> 2 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (4-fixture): los claims deben tener EXACTAMENTE 2 claves (sub, role), tienen %.', (SELECT COUNT(*) FROM jsonb_object_keys(v_claims));
  END IF;
  IF auth.uid() IS DISTINCT FROM v_backend_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al invitado del bloque 4 -- se omite.';
  ELSE
    PERFORM public.rpc_accept_invitation(v_token_backend);
    IF NOT EXISTS (
      SELECT 1 FROM account_member_roles amr
      JOIN account_members am ON am.id = amr.member_id
      WHERE am.account_id = v_account AND am.user_id = v_backend_uid AND amr.role = 'cashier'
    ) THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (4): con los claims reales del backend (sin email) la aceptación legítima fue rechazada -- el guard está keyeado en el claim en vez de resolver contra auth.users (D14/B4).';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (4): con los claims EXACTOS del backend propio (sub+role, sin email) la aceptación legítima se completa -- el email se resuelve contra auth.users.';
  END IF;

  -- ═══ (5) dos aceptaciones del mismo token ════════════════════════════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);
  v_result := public.rpc_invite_member('gate-accept-bind-twice@test.local'::text, v_account, ARRAY['viewer']::text[]);
  v_token_twice := (SELECT token FROM account_invitations WHERE id = (v_result->>'id')::uuid);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_twice_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_twice_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al aceptante del bloque 5 -- se omite.';
  ELSE
    PERFORM public.rpc_accept_invitation(v_token_twice);
    v_not_rejected := false;
    BEGIN
      PERFORM public.rpc_accept_invitation(v_token_twice);
      v_not_rejected := true;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
    END;

    IF v_not_rejected THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (5): el mismo token se canjeó dos veces.';
    END IF;
    -- Una invitación ya usada sale del predicado `status = 'pending'`: mismo
    -- contrato que el resto de las validaciones (P0404), nunca un 500.
    IF v_caught_code NOT IN ('P0404', 'P0409') THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (5): el 2º canje dio % (%) -- esperaba el contrato de invitación ya usada (P0404) o de miembro existente (P0409).', v_caught_code, v_caught_msg;
    END IF;
    SELECT COUNT(*) INTO v_count FROM account_members WHERE account_id = v_account AND user_id = v_twice_uid;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (5): el doble canje dejó % membresías para el mismo usuario (esperaba 1).', v_count;
    END IF;
    IF (SELECT status FROM account_invitations WHERE token = v_token_twice) <> 'accepted' THEN
      RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (5): la invitación canjeada no quedó marcada como aceptada.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (5): el mismo token no se canjea dos veces y no deja una 2ª membresía (secuencia serializada; la exclusión mutua real la sostiene el FOR UPDATE verificado en (6)).';
  END IF;

  -- ═══ (6) integridad de función — cuerpo VIVO, sin comentarios ════════════
  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_accept_invitation';

  v_pos_lock  := position('FOR UPDATE' in v_def);
  v_pos_users := position('auth.users' in v_def);
  v_pos_email := position('lower(v_inv.email)' in v_def);
  v_pos_write := position('INSERT INTO public.account_members' in v_def);

  IF v_pos_lock = 0 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (6-lock): rpc_accept_invitation perdió el SELECT … FOR UPDATE sobre la invitación (dos aceptaciones concurrentes volverían a competir).';
  END IF;
  IF v_pos_users = 0 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (6-auth-users): el email del aceptante ya no se resuelve contra auth.users -- un guard keyeado sólo en el claim rechaza el 100%% de las aceptaciones por FastAPI (D14/B4).';
  END IF;
  IF v_pos_email = 0 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (6-binding): el cuerpo vivo ya no compara el email de la invitación con lower() en ambos lados.';
  END IF;
  IF v_pos_write = 0 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (6-ancla): no se encontró el INSERT en account_members -- el ancla de orden dejó de existir, revisar este gate.';
  END IF;
  IF NOT (v_pos_lock < v_pos_write) THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (6-orden-lock): el FOR UPDATE debe tomarse ANTES de la primera escritura. Posiciones: lock=%, insert=%.', v_pos_lock, v_pos_write;
  END IF;
  IF NOT (v_pos_email < v_pos_write) THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (6-orden-binding): el binding de email debe evaluarse ANTES de la primera escritura. Posiciones: binding=%, insert=%.', v_pos_email, v_pos_write;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (6): el cuerpo vivo conserva el lock, la resolución contra auth.users y la comparación insensible a mayúsculas, todo ANTES de la primera escritura.';

  -- ═══ (7) cero overloads + ACLs exactas ═══════════════════════════════════
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_accept_invitation';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (7-overload): hay % definiciones de rpc_accept_invitation (esperaba 1) -- un DROP+CREATE con la firma cambiada dejó un overload fantasma (42725).', v_count;
  END IF;

  -- PUBLIC: has_function_privilege no acepta 'PUBLIC' como rol, así que se
  -- mira el ACL crudo -- aclexplode devuelve grantee = 0 para PUBLIC.
  IF EXISTS (
    SELECT 1
    FROM pg_proc p, aclexplode(p.proacl) a
    WHERE p.oid = 'public.rpc_accept_invitation(text)'::regprocedure
      AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (7-public): rpc_accept_invitation quedó ejecutable por PUBLIC -- PostgreSQL lo otorga por default en toda función nueva, así que el REVOKE tras el DROP+CREATE falta o se revirtió.';
  END IF;
  IF has_function_privilege('anon', 'public.rpc_accept_invitation(text)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (7-anon): rpc_accept_invitation quedó ejecutable por anon.';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpc_accept_invitation(text)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (7-authenticated): authenticated perdió EXECUTE -- el camino PostgREST de la aceptación quedaría roto.';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.rpc_accept_invitation(text)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (7-service-role): service_role perdió EXECUTE.';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (7): una sola definición de rpc_accept_invitation, sin EXECUTE para PUBLIC ni anon, con EXECUTE para authenticated y service_role.';

  -- ═══ Cleanup ═════════════════════════════════════════════════════════════
  -- handle_new_user aprovisiona una cuenta PROPIA para CADA auth.users, y le
  -- siembra 7 payment_methods + 7 product_categories: con
  -- session_replication_role = replica el ON DELETE CASCADE no corre, así que
  -- cada tabla se limpia explícitamente. El array de ids se captura ANTES de
  -- borrar accounts (una subquery evaluada después devolvería 0 filas de
  -- forma vacua y el chequeo de saldo quedaría ciego).
  RESET request.jwt.claims;
  SELECT array_agg(id) INTO v_account_ids FROM accounts WHERE owner_user_id = ANY(v_all_uids);

  SET session_replication_role = replica;
  DELETE FROM account_invitations   WHERE account_id = ANY(v_account_ids);
  DELETE FROM account_member_roles  WHERE account_id = ANY(v_account_ids);
  DELETE FROM account_members       WHERE account_id = ANY(v_account_ids);
  DELETE FROM cashboxes WHERE branch_id IN (SELECT id FROM branches WHERE account_id = ANY(v_account_ids));
  DELETE FROM branches              WHERE account_id = ANY(v_account_ids);
  DELETE FROM payment_methods       WHERE account_id = ANY(v_account_ids);
  DELETE FROM product_categories    WHERE account_id = ANY(v_account_ids);
  DELETE FROM accounts              WHERE id = ANY(v_account_ids);
  SET session_replication_role = DEFAULT;
  DELETE FROM profiles    WHERE id = ANY(v_all_uids);
  DELETE FROM email_logs  WHERE user_id = ANY(v_all_uids);
  DELETE FROM auth.users  WHERE id = ANY(v_all_uids);

  SELECT COUNT(*) INTO v_orphans FROM (
    SELECT account_id FROM account_member_roles WHERE account_id = ANY(v_account_ids)
    UNION ALL
    SELECT account_id FROM account_invitations  WHERE account_id = ANY(v_account_ids)
    UNION ALL
    SELECT account_id FROM payment_methods      WHERE account_id = ANY(v_account_ids)
    UNION ALL
    SELECT account_id FROM product_categories   WHERE account_id = ANY(v_account_ids)
  ) orphans;
  IF v_orphans <> 0 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING: quedaron % filas huérfanas tras el cleanup.', v_orphans;
  END IF;

  IF v_blocks_run <> 7 THEN
    RAISE EXCEPTION 'GATE ACCEPT-INVITATION-BINDING FAILED (conteo): se ejercitaron % de 7 bloques esperados.', v_blocks_run;
  END IF;

  RAISE NOTICE 'GATE ACCEPT-INVITATION-BINDING: %/7 bloques PASS.', v_blocks_run;
EXCEPTION
  WHEN OTHERS THEN
    RESET request.jwt.claims;
    SET session_replication_role = replica;
    DELETE FROM account_invitations WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id = ANY(v_all_uids));
    DELETE FROM account_member_roles WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id = ANY(v_all_uids));
    DELETE FROM account_members WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id = ANY(v_all_uids));
    DELETE FROM cashboxes WHERE branch_id IN (
      SELECT id FROM branches WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id = ANY(v_all_uids))
    );
    DELETE FROM branches WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id = ANY(v_all_uids));
    DELETE FROM payment_methods WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id = ANY(v_all_uids));
    DELETE FROM product_categories WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id = ANY(v_all_uids));
    DELETE FROM accounts WHERE owner_user_id = ANY(v_all_uids);
    DELETE FROM profiles WHERE id = ANY(v_all_uids);
    DELETE FROM email_logs WHERE user_id = ANY(v_all_uids);
    DELETE FROM auth.users WHERE id = ANY(v_all_uids);
    SET session_replication_role = DEFAULT;
    RAISE;
END $$;
