-- =============================================================================
-- GATE: test_custom_access_token_hook_account_roles.sql
-- CHANGE: v3-rbac-multirole Parte B, grupo 9 (D8) — claim nuevo `account_roles`
-- del custom access token hook.
--
-- Molde de la sección de comportamiento de
-- 20260827000001_v31_authz_token_hook.sql (gates (d)-(k)): invoca
-- public.custom_access_token_hook(event jsonb) DIRECTO con un event
-- sintético, sin pasar por GoTrue. A diferencia de ese gate (que necesita
-- `accounts` VACÍA para el sub-caso de determinismo entre 2 cuentas), este
-- gate sólo depende de la membresía PROPIA del usuario sintético que crea
-- -- no necesita la tabla vacía, así que corre siempre (mismo criterio que
-- test_account_role_catalog.sql / test_is_account_writer_pivot.sql: anchor
-- prestado de auth.users, fixture propio autocontenido).
--
--   (1) el claim account_role (singular, legacy) sigue emitiéndose IGUAL
--       que antes de este change — no regresión sobre v31-authz-token-hook.
--   (2) el hook emite account_roles con los roles ACTIVOS del actor (9.1) —
--       varios roles simultáneos, todos vigentes.
--   (3) un rol VENCIDO no viaja en account_roles, aunque su fila exista
--       (9.2, D4).
--   (4) usuario sin membresía: account_roles ausente (no un array vacío
--       fabricado) — mismo criterio que account_role/plan hoy.
--   (5) el claim nuevo se agrega DENTRO del bloque protegido: sin el GRANT
--       de 9.5 (member_active_roles a supabase_auth_admin), el hook
--       DEGRADA devolviendo los claims INTACTOS (RAISE WARNING, sin
--       excepción) — nunca rompe el login (9.3). Con el GRANT restituido,
--       vuelve a emitir. Mismo patrón que el gate (k) de
--       v31-authz-token-hook para account_role/account_members.
--       Ronda 1 adversarial (minor 1): este bloque (5) corre vía `SET
--       LOCAL ROLE supabase_auth_admin`, que en CI/local SIEMPRE degrada
--       por falta de membresía de rol (límite de entorno, no del
--       blindaje) — así que NUNCA ejercita el camino real. Ya NO cuenta
--       como PASS del blindaje cuando degrada (antes sí lo hacía,
--       incorrectamente). El blindaje D8 REAL se verifica en un step
--       aparte de `.github/workflows/KPI_Validation.yml` ("Run
--       v3-rbac-multirole hook D8 degrade probe (real supabase_auth_admin
--       role)") que se conecta como `supabase_auth_admin` de verdad vía
--       TCP (el rol SÍ tiene LOGIN en el stack local/CI).
-- =============================================================================
DO $$
DECLARE
  v_user1        uuid := gen_random_uuid();
  v_account1     uuid;
  v_member1      uuid;
  v_claims_out   jsonb;
  v_gate_1 boolean := false;
  v_gate_2 boolean := false;
  v_gate_3 boolean := false;
  v_gate_4 boolean := false;
  v_gate_5 boolean := false;
  v_gate_5_degraded boolean := false;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user1, 'authenticated', 'authenticated',
          'v3-rbac-hook-gate-1@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Hook RBAC', 'phone', '', 'locality', '', 'province', ''));

  SELECT account_id, id INTO v_account1, v_member1
  FROM public.account_members WHERE user_id = v_user1;

  -- El member1 recién creado por handle_new_user ya tiene su fila 'owner'
  -- en el pivot (hallazgo 6.3b de Parte A) -- se limpia para armar el
  -- fixture propio de este gate con roles funcionales.
  DELETE FROM public.account_member_roles WHERE member_id = v_member1;
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account1, v_member1, 'seller', now());
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account1, v_member1, 'stock', now());
  -- rol vencido -- no debe viajar en el claim.
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at, expires_at)
  VALUES (v_account1, v_member1, 'accountant', now() - INTERVAL '30 days', now() - INTERVAL '1 day');

  v_claims_out := public.custom_access_token_hook(jsonb_build_object(
    'user_id', v_user1, 'claims', jsonb_build_object('app_metadata', jsonb_build_object('provider', 'email'))
  ));

  -- (1) el singular sigue emitiéndose (D3: precedencia -- sin owner/admin
  -- activos, account_members.role quedó 'member').
  IF (v_claims_out #>> '{claims,app_metadata,account_role}') IS NOT NULL THEN
    v_gate_1 := true;
  ELSE
    RAISE EXCEPTION 'GATE FAILED (1): account_role (singular) dejó de emitirse: %', v_claims_out;
  END IF;

  -- (2) account_roles trae los 2 activos (seller, stock), NO el vencido.
  IF (v_claims_out #> '{claims,app_metadata,account_roles}') IS NOT NULL
     AND (
       SELECT array_agg(x ORDER BY x)
       FROM jsonb_array_elements_text(v_claims_out #> '{claims,app_metadata,account_roles}') x
     ) = ARRAY['seller', 'stock']
  THEN
    v_gate_2 := true;
  ELSE
    RAISE EXCEPTION 'GATE FAILED (2): account_roles no trae exactamente {seller,stock}: %', v_claims_out #> '{claims,app_metadata,account_roles}';
  END IF;
  v_gate_3 := true;  -- (3) queda probado por la MISMA aserción de (2): accountant (vencido) está ausente.
  RAISE NOTICE 'PASS (1)-(3): account_role singular intacto, account_roles = {seller,stock}, el vencido (accountant) excluido.';

  -- (4) usuario SIN membresía: account_roles ausente, no [] fabricado.
  DELETE FROM public.account_member_roles WHERE member_id = v_member1;
  DELETE FROM public.account_members WHERE id = v_member1;

  v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));
  IF (v_claims_out #> '{claims,app_metadata,account_roles}') IS NULL
     AND (v_claims_out #> '{claims,app_metadata,account_role}') IS NULL
  THEN
    v_gate_4 := true;
    RAISE NOTICE 'PASS (4): usuario sin membresía -- account_roles ausente (no un array vacío fabricado).';
  ELSE
    RAISE EXCEPTION 'GATE FAILED (4): usuario sin membresía produjo account_roles/account_role inesperados: %', v_claims_out;
  END IF;

  -- Restaurar membresía + roles para el gate (5).
  INSERT INTO public.account_members (id, account_id, user_id, role, created_at)
  VALUES (v_member1, v_account1, v_user1, 'member', now());
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account1, v_member1, 'seller', now());

  -- (5) sin el GRANT de member_active_roles a supabase_auth_admin, el hook
  -- entero DEGRADA (bloque protegido) -- claims intactos, sin excepción.
  --
  -- Ronda 1 adversarial (minor 1, corregido): este bloque local NUNCA
  -- ejercita esto de verdad en CI/local -- `SET LOCAL ROLE
  -- supabase_auth_admin` exige que el rol que corre el gate (`postgres`)
  -- sea miembro de supabase_auth_admin (o superusuario), y no lo es en
  -- ningún entorno medido: SIEMPRE degrada por límite de entorno, nunca
  -- por el blindaje. La versión anterior de este bloque marcaba ese
  -- degradado como `v_gate_5 := true` -- contando como "PASS" un sub-caso
  -- que en los hechos NUNCA corrió. El blindaje D8 real (el hook degrada
  -- de verdad sin el GRANT, con WARNING, sin excepción) SÍ se verifica --
  -- pero en un step APARTE de KPI_Validation.yml ("Run v3-rbac-multirole
  -- hook D8 degrade probe (real supabase_auth_admin role)") que se conecta
  -- como supabase_auth_admin REAL vía TCP (el rol SÍ tiene LOGIN en el
  -- stack local/CI, verificado). Este bloque local queda como chequeo
  -- estructural del mensaje/SQLSTATE cuando el entorno degrada, y a partir
  -- de esta ronda YA NO cuenta como PASS del blindaje cuando degrada --
  -- ver v_gate_5 vs v_gate_5_degraded y el tally final.
  REVOKE EXECUTE ON FUNCTION public.member_active_roles(uuid) FROM supabase_auth_admin;

  BEGIN
    EXECUTE 'SET LOCAL ROLE supabase_auth_admin';

    v_claims_out := public.custom_access_token_hook(jsonb_build_object(
      'user_id', v_user1, 'claims', jsonb_build_object('sub', 'preserved-rbac-b')
    ));
    EXECUTE 'RESET ROLE';

    IF v_claims_out <> jsonb_build_object('claims', jsonb_build_object('sub', 'preserved-rbac-b')) THEN
      RAISE EXCEPTION 'GATE FAILED (5.1): sin EXECUTE sobre member_active_roles, el hook debía degradar TODO el app_metadata (blindaje D8) y no lo hizo: %', v_claims_out;
    END IF;

    GRANT EXECUTE ON FUNCTION public.member_active_roles(uuid) TO supabase_auth_admin;

    EXECUTE 'SET LOCAL ROLE supabase_auth_admin';
    v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));
    EXECUTE 'RESET ROLE';

    IF (v_claims_out #> '{claims,app_metadata,account_roles}') IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (5.2): con el GRANT restituido, el hook debía volver a emitir account_roles: %', v_claims_out;
    END IF;
    v_gate_5 := true;
    RAISE NOTICE 'PASS (5): sin el GRANT necesario, el hook degrada TODO (claims intactos, D8); con el GRANT restituido, vuelve a emitir.';
  EXCEPTION
    WHEN insufficient_privilege THEN
      GRANT EXECUTE ON FUNCTION public.member_active_roles(uuid) TO supabase_auth_admin;
      IF SQLERRM LIKE '%set role%' OR SQLERRM LIKE '%permission denied to set role%' THEN
        v_gate_5_degraded := true;
        RAISE NOTICE 'GATE (5) DEGRADADO: el entorno no permite SET LOCAL ROLE supabase_auth_admin (rol de aplicación sin esa membresía) -- mismo límite documentado en el gate (k) de v31-authz-token-hook. Omitido SIN marcar PASS (ronda 1 adversarial, minor 1) -- el blindaje D8 real lo verifica el step dedicado de CI que se conecta como supabase_auth_admin real.';
      ELSE
        RAISE;
      END IF;
  END;

  -- Cleanup
  DELETE FROM public.account_member_roles WHERE member_id = v_member1;
  DELETE FROM public.account_members WHERE user_id = v_user1;
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE id = v_account1;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = v_user1;
  DELETE FROM public.email_logs WHERE user_id = v_user1;
  DELETE FROM auth.users WHERE id = v_user1;

  -- Ronda 1 adversarial (minor 1): el bloque 5 sólo cuenta para el tally
  -- si REALMENTE corrió (v_gate_5), nunca cuando degradó
  -- (v_gate_5_degraded) -- ver el mensaje final, que ya no dice "5/5" en
  -- ese caso.
  IF NOT (v_gate_1 AND v_gate_2 AND v_gate_3 AND v_gate_4 AND (v_gate_5 OR v_gate_5_degraded)) THEN
    RAISE EXCEPTION 'GATE CUSTOM-ACCESS-TOKEN-HOOK-ACCOUNT-ROLES FAILED: no todos los bloques pasaron.';
  END IF;

  IF v_gate_5 THEN
    RAISE NOTICE 'GATE CUSTOM-ACCESS-TOKEN-HOOK-ACCOUNT-ROLES: 5/5 bloques PASS.';
  ELSE
    RAISE NOTICE 'GATE CUSTOM-ACCESS-TOKEN-HOOK-ACCOUNT-ROLES: 4/5 bloques PASS (bloque 5 DEGRADADO por límite de entorno -- el blindaje D8 real se verifica en el step dedicado de CI con supabase_auth_admin real, no acá. Ronda 1 adversarial, minor 1).';
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    GRANT EXECUTE ON FUNCTION public.member_active_roles(uuid) TO supabase_auth_admin;
    DELETE FROM public.account_member_roles WHERE member_id = v_member1;
    DELETE FROM public.account_members WHERE user_id = v_user1;
    SET session_replication_role = replica;
    DELETE FROM public.accounts WHERE id = v_account1;
    SET session_replication_role = DEFAULT;
    DELETE FROM public.profiles WHERE id = v_user1;
    DELETE FROM public.email_logs WHERE user_id = v_user1;
    DELETE FROM auth.users WHERE id = v_user1;
    RAISE;
END $$;
