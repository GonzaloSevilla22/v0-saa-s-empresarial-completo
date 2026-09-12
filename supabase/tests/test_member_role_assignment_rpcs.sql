-- =============================================================================
-- GATE: test_member_role_assignment_rpcs.sql
-- CHANGE: v3-rbac-multirole Parte C, grupo 14 (D-account-membership-roles,
-- D-org-roles "Cambio de rol controlado por jerarquía") — RPCs nuevas
-- rpc_assign_member_role / rpc_revoke_member_role / rpc_list_account_members.
--
-- Usa el patrón de anchor sintético vía `request.jwt.claims` local + signup
-- real por `INSERT INTO auth.users` (handle_new_user aprovisiona cuenta +
-- membresía owner a través del pivot), mismo molde que
-- test_membership_rpcs_pivot_rewrite.sql. Degrade-don't-fail si auth.uid()
-- no resuelve contra el claim local.
--
--   (1) Estructura: las 3 funciones existen con la aridad esperada y las
--       ACLs correctas (sin EXECUTE para anon/PUBLIC, con EXECUTE para
--       authenticated).
--   (2) El owner asigna un rol operativo ('seller') a un miembro -> fila
--       creada, is_active=true en el listado.
--   (3) El owner asigna un rol con vencimiento futuro -> is_active=true,
--       expires_at presente.
--   (4) Idempotencia: reasignar el MISMO rol (con OTRO vencimiento) no
--       duplica la fila -- sigue habiendo 1 sola asignación de ese rol para
--       el miembro, con el expires_at actualizado.
--   (5) El administrador NO puede otorgar el rol de propietario -> P0403.
--   (6) El administrador NO puede otorgar el rol de administrador -> P0403.
--   (7) El administrador SÍ puede otorgar un rol operativo ('cashier') a
--       cualquier miembro.
--   (8) Un no-miembro de la cuenta no tiene autoridad para asignar ningún
--       rol -> P0403.
--   (9) Tenencia: el target no es miembro de esta cuenta -> P0404.
--   (10) Catálogo: un código de rol que no existe -> P0400.
--   (11) Owner con vencimiento -> P0406 (el trigger de la Parte A se
--        dispara a través de esta RPC nueva, sin duplicarlo).
--   (12) Invariante de propietario: revocar la única asignación owner
--        activa de la cuenta -> P0405 (el constraint trigger DEFERRABLE de
--        la Parte A se dispara a través de rpc_revoke_member_role).
--   (13) Revocar un rol que el miembro NO tiene vigente es un no-op
--        idempotente (0 filas afectadas, sin error).
--   (14) rpc_list_account_members: devuelve el conjunto COMPLETO (vigente +
--        vencida, cada una con is_active correcto) y aplica guard de
--        tenencia -- un no-miembro que pregunta por esta cuenta obtiene 0
--        filas.
--
--   RONDA 1 ADVERSARIAL -- cobertura nueva (finding MINOR: huecos en la
--   matriz de autoridad) + guard nuevo (finding MINOR: admin modificando
--   los roles de un propietario):
--   (15) Un MIEMBRO sin owner/admin (viewer/seller/stock) no tiene
--        autoridad para ASIGNAR roles -> P0403 (antes sólo se probaba el
--        caso de un NO-miembro, bloque 8; éste es el caso realista).
--   (16) El mismo miembro sin autoridad no puede REVOCAR roles -> P0403.
--   (17) El administrador no puede revocarse a sí mismo el rol admin ->
--        P0403 (simetría de (6), que sólo probaba ASIGNAR).
--   (18) El administrador no puede revocarle el rol owner al propietario ->
--        P0403 (simetría de (5), que sólo probaba ASIGNAR).
--   (19) GUARD NUEVO: el administrador NO puede asignarle NINGÚN rol
--        (aunque sea operativo, p.ej. 'viewer') a un target que hoy tiene
--        owner activo -> P0403.
--   (20) GUARD NUEVO: el administrador NO puede revocarle NINGÚN rol
--        (aunque el target no lo tenga vigente) a un target que hoy tiene
--        owner activo -> P0403 -- el guard debe disparar ANTES del DELETE
--        idempotente de (13), no depender de que la fila exista.
--
--   RONDA 2 ADVERSARIAL (finding MAJOR: el invariante de propietario sólo
--   lo aplicaba el constraint trigger DIFERIDO, inalcanzable por el backend
--   real -- ver el comentario "3.5" de rpc_revoke_member_role en la
--   migración):
--   (21) Revocar el único owner activo SIN forzar `SET CONSTRAINTS ...
--        IMMEDIATE` (a diferencia de (12)) -> P0405 de inmediato igual --
--        prueba que el rechazo NO depende de que el constraint trigger
--        diferido llegue a evaluarse, que es exactamente la condición bajo
--        la que corre PostgREST/el backend (nunca fuerza el constraint a
--        modo inmediato). El owner sigue con su fila intacta después.
-- =============================================================================

-- ── (1) Estructura: aridad + ACLs ────────────────────────────────────────────
DO $$
BEGIN
  IF (SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_assign_member_role') <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1): rpc_assign_member_role no tiene exactamente 1 definición.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_revoke_member_role') <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1): rpc_revoke_member_role no tiene exactamente 1 definición.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_list_account_members') <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1): rpc_list_account_members no tiene exactamente 1 definición.';
  END IF;

  IF has_function_privilege('anon', 'public.rpc_assign_member_role(uuid,uuid,text,timestamptz)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_revoke_member_role(uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_list_account_members(uuid)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE FAILED (1): alguna RPC nueva es ejecutable por anon.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.rpc_assign_member_role(uuid,uuid,text,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_revoke_member_role(uuid,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_list_account_members(uuid)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE FAILED (1): alguna RPC nueva NO es ejecutable por authenticated.';
  END IF;

  RAISE NOTICE 'PASS (1): estructura -- aridad + ACLs correctas.';
END $$;


-- ── (2)-(14) comportamiento ──────────────────────────────────────────────────
DO $$
DECLARE
  v_blocks_run     int := 0;
  v_owner_uid      uuid := gen_random_uuid();
  v_member_uid     uuid := gen_random_uuid();
  v_admin_uid      uuid := gen_random_uuid();
  v_stranger_uid   uuid := gen_random_uuid();
  v_account        uuid;
  v_owner_member   uuid;
  v_target_member  uuid;
  v_admin_member   uuid;
  v_result         jsonb;
  v_caught_code    text;
  v_other_account  uuid;
  v_orphans        int;
BEGIN
  BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_owner_uid, 'gate-assign-rpc-owner@test.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudo crear el usuario ancla (%). Se aborta el gate.', SQLERRM;
    RETURN;
  END;

  SELECT account_id, id INTO v_account, v_owner_member FROM account_members WHERE user_id = v_owner_uid;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: handle_new_user no aprovisionó la cuenta ancla. Se aborta el gate.';
    RETURN;
  END IF;

  INSERT INTO auth.users (id, email) VALUES (v_member_uid, 'gate-assign-rpc-member@test.local');
  INSERT INTO account_members (id, account_id, user_id, role)
  VALUES (gen_random_uuid(), v_account, v_member_uid, 'member')
  RETURNING id INTO v_target_member;
  INSERT INTO account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account, v_target_member, 'viewer', now())
  ON CONFLICT (member_id, role) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES (v_admin_uid, 'gate-assign-rpc-admin@test.local');
  INSERT INTO account_members (id, account_id, user_id, role)
  VALUES (gen_random_uuid(), v_account, v_admin_uid, 'admin')
  RETURNING id INTO v_admin_member;
  INSERT INTO account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account, v_admin_member, 'admin', now())
  ON CONFLICT (member_id, role) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES (v_stranger_uid, 'gate-assign-rpc-stranger@test.local');
  -- v_stranger_uid tiene su PROPIA cuenta (via handle_new_user), no la de
  -- v_account -- es "un no-miembro de esta cuenta".
  SELECT account_id INTO v_other_account FROM account_members WHERE user_id = v_stranger_uid;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al anchor con request.jwt.claims local -- se omiten los bloques que invocan RPCs.';
  ELSE
    -- ── (2) owner asigna rol operativo ────────────────────────────────────
    v_result := public.rpc_assign_member_role(v_account, v_member_uid, 'seller', NULL);
    IF (v_result->>'role') IS DISTINCT FROM 'seller' THEN
      RAISE EXCEPTION 'GATE FAILED (2): rpc_assign_member_role no devolvió role=seller: %', v_result;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM account_member_roles
      WHERE member_id = v_target_member AND role = 'seller' AND expires_at IS NULL
    ) THEN
      RAISE EXCEPTION 'GATE FAILED (2): no quedó la fila seller sin vencimiento en el pivot.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (2): owner asigna un rol operativo.';

    -- ── (3) owner asigna rol con vencimiento futuro ───────────────────────
    v_result := public.rpc_assign_member_role(v_account, v_member_uid, 'stock', now() + INTERVAL '3 days');
    IF NOT EXISTS (
      SELECT 1 FROM account_member_roles
      WHERE member_id = v_target_member AND role = 'stock' AND expires_at > now()
    ) THEN
      RAISE EXCEPTION 'GATE FAILED (3): no quedó la fila stock con vencimiento futuro.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (3): owner asigna un rol con vencimiento futuro.';

    -- ── (4) idempotencia: reasignar el MISMO rol no duplica ───────────────
    v_result := public.rpc_assign_member_role(v_account, v_member_uid, 'stock', now() + INTERVAL '30 days');
    IF (SELECT COUNT(*) FROM account_member_roles WHERE member_id = v_target_member AND role = 'stock') <> 1 THEN
      RAISE EXCEPTION 'GATE FAILED (4): reasignar "stock" duplicó la fila en vez de actualizarla.';
    END IF;
    IF (SELECT expires_at FROM account_member_roles WHERE member_id = v_target_member AND role = 'stock')
       < now() + INTERVAL '29 days'
    THEN
      RAISE EXCEPTION 'GATE FAILED (4): reasignar "stock" no actualizó expires_at.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (4): idempotencia -- reasignar el mismo rol renueva expires_at sin duplicar.';

    -- ── (9) tenencia: target no es miembro de esta cuenta -> P0404 ────────
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_stranger_uid, 'seller', NULL);
      RAISE EXCEPTION 'GATE FAILED (9): asignar a un no-miembro no fue rechazado.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0404' THEN
        RAISE EXCEPTION 'GATE FAILED (9): esperaba P0404, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (9): tenencia -- target ajeno a la cuenta rechazado con P0404.';

    -- ── (10) catálogo: rol inexistente -> P0400 ───────────────────────────
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_member_uid, 'superadmin', NULL);
      RAISE EXCEPTION 'GATE FAILED (10): un rol fuera del catálogo no fue rechazado.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0400' THEN
        RAISE EXCEPTION 'GATE FAILED (10): esperaba P0400, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (10): catálogo -- rol inexistente rechazado con P0400.';

    -- ── (11) owner con vencimiento -> P0406 (trigger de la Parte A) ───────
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_member_uid, 'owner', now() + INTERVAL '1 day');
      RAISE EXCEPTION 'GATE FAILED (11): asignar owner con vencimiento no fue rechazado.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0406' THEN
        RAISE EXCEPTION 'GATE FAILED (11): esperaba P0406, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (11): owner con vencimiento rechazado con P0406 (trigger reutilizado).';

    -- ── (14a) rpc_list_account_members: conjunto completo, vigente+vencida ─
    IF NOT EXISTS (
      SELECT 1 FROM public.rpc_list_account_members(v_account) m
      WHERE m.member_id = v_target_member
        AND m.roles @> jsonb_build_array(jsonb_build_object('role', 'seller', 'expires_at', NULL, 'is_active', true))
    ) THEN
      RAISE EXCEPTION 'GATE FAILED (14a): el listado no muestra la asignación seller vigente.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (14a): rpc_list_account_members expone el conjunto completo con is_active correcto.';

    -- ── (12) invariante de propietario: revocar el único owner -> P0405 ───
    -- El constraint trigger de la Parte A es DEFERRABLE INITIALLY DEFERRED
    -- (se evalúa al COMMIT, no por sentencia) -- SET CONSTRAINTS ...
    -- IMMEDIATE lo fuerza a evaluarse ACÁ, dentro del mismo DO block, igual
    -- que test_account_owner_invariant.sql de la Parte A.
    -- RONDA 3 (nit): con el chequeo SÍNCRONO 3.5 ya en pie, el valor de este bloque es la SIMETRÍA con (21) -- con y sin forzar IMMEDIATE --, no la deferencia (esa cobertura vive en test_account_owner_invariant.sql).
    BEGIN
      SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
      PERFORM public.rpc_revoke_member_role(v_account, v_owner_uid, 'owner');
      RAISE EXCEPTION 'GATE FAILED (12): revocar el único owner no fue rechazado.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0405' THEN
        RAISE EXCEPTION 'GATE FAILED (12): esperaba P0405, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    SET CONSTRAINTS trg_guard_account_owner_invariant DEFERRED;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (12): invariante de propietario disparado a través de rpc_revoke_member_role.';

    -- ── (21) RONDA 2 ADVERSARIAL (finding MAJOR): el MISMO revoke del único
    --     owner, pero SIN forzar `SET CONSTRAINTS ... IMMEDIATE` -- exactamente
    --     como PostgREST/el backend invocan esta RPC (una sentencia normal
    --     dentro de su propia transacción, nunca con el constraint puesto en
    --     modo inmediato). El constraint trigger DEFERRABLE de la Parte A NO
    --     se evaluaría hasta el COMMIT si el rechazo dependiera sólo de él --
    --     este bloque prueba que el chequeo NUEVO (paso 3.5 de
    --     rpc_revoke_member_role, síncrono) rechaza de inmediato, sin
    --     necesidad de forzar nada ni de llegar al COMMIT. Antes del fix,
    --     este mismo bloque NO fallaba acá (el DELETE se ejecutaba sin
    --     error) -- el 500/RuntimeError sólo aparecía en el backend real, al
    --     intentar comitear la transacción del request DESPUÉS de haber
    --     enviado la respuesta 200.
    BEGIN
      PERFORM public.rpc_revoke_member_role(v_account, v_owner_uid, 'owner');
      RAISE EXCEPTION 'GATE FAILED (21): revocar el único owner SIN forzar el constraint no fue rechazado de inmediato.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0405' THEN
        RAISE EXCEPTION 'GATE FAILED (21): esperaba P0405, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    -- Verificación adicional: el owner SIGUE ahí -- el rechazo síncrono
    -- ocurrió ANTES del DELETE, así que no hay nada que compensar ni que el
    -- trigger diferido deba deshacer al COMMIT.
    IF NOT EXISTS (
      SELECT 1 FROM account_member_roles WHERE member_id = v_owner_member AND role = 'owner'
    ) THEN
      RAISE EXCEPTION 'GATE FAILED (21): el rechazo síncrono no debía dejar sin la fila owner al propietario.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (21): revocar el único owner se rechaza de inmediato, sin depender del constraint trigger diferido (ronda 2 adversarial).';

    -- ── (13) revocar un rol NO vigente es un no-op idempotente ────────────
    v_result := public.rpc_revoke_member_role(v_account, v_member_uid, 'purchases');
    IF EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_target_member AND role = 'purchases') THEN
      RAISE EXCEPTION 'GATE FAILED (13): revocar un rol nunca asignado dejó una fila inesperada.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (13): revocar un rol no vigente es idempotente (0 filas, sin error).';
  END IF;

  -- ── (5)-(8) autoridad del ADMIN (sesión distinta) ────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_uid::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_admin_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al admin -- se omiten los bloques (5)-(8).';
  ELSE
    -- ── (5) admin NO puede otorgar owner ───────────────────────────────────
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_member_uid, 'owner', NULL);
      RAISE EXCEPTION 'GATE FAILED (5): el admin pudo otorgar el rol owner.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (5): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (5): el administrador no puede otorgar el rol de propietario.';

    -- ── (6) admin NO puede otorgar admin ───────────────────────────────────
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_member_uid, 'admin', NULL);
      RAISE EXCEPTION 'GATE FAILED (6): el admin pudo otorgar el rol admin.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (6): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (6): el administrador no puede otorgar el rol de administrador.';

    -- ── (7) admin SÍ puede otorgar un rol operativo ────────────────────────
    v_result := public.rpc_assign_member_role(v_account, v_member_uid, 'cashier', NULL);
    IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_target_member AND role = 'cashier') THEN
      RAISE EXCEPTION 'GATE FAILED (7): el admin no pudo otorgar el rol operativo cashier.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (7): el administrador SÍ puede otorgar un rol operativo.';

    -- ── (17) admin NO puede revocarse a sí mismo el rol admin ──────────────
    -- (simetría de (6), que sólo probaba ASIGNAR -- cobertura nueva, ronda 1)
    BEGIN
      PERFORM public.rpc_revoke_member_role(v_account, v_admin_uid, 'admin');
      RAISE EXCEPTION 'GATE FAILED (17): el admin pudo revocarse a sí mismo el rol admin.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (17): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (17): el administrador no puede revocarse a sí mismo el rol de administrador.';

    -- ── (18) admin NO puede revocarle el rol owner al propietario ──────────
    -- (simetría de (5), que sólo probaba ASIGNAR -- cobertura nueva, ronda 1)
    BEGIN
      PERFORM public.rpc_revoke_member_role(v_account, v_owner_uid, 'owner');
      RAISE EXCEPTION 'GATE FAILED (18): el admin pudo revocarle el rol owner al propietario.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (18): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (18): el administrador no puede revocar el rol de propietario a un owner.';

    -- ── (19) GUARD NUEVO (ronda 1 adversarial, finding MINOR): admin NO
    --     puede asignarle NINGÚN rol a un target que hoy tiene owner
    --     activo, aunque el rol PEDIDO sea operativo -- antes de este fix
    --     esto se aceptaba (reproducido por el revisor:
    --     rpc_assign_member_role(acc, <owner>, 'viewer', NULL) no era
    --     rechazado) ────────────────────────────────────────────────────────
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_owner_uid, 'viewer', NULL);
      RAISE EXCEPTION 'GATE FAILED (19): el admin pudo asignarle un rol operativo al propietario.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (19): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (19): el administrador no puede modificar el conjunto de roles de un propietario (guard nuevo).';

    -- ── (20) GUARD NUEVO: mismo criterio del lado de REVOKE, con un rol
    --     operativo que el propietario NO tiene vigente -- el guard debe
    --     disparar ANTES del DELETE idempotente de (13), no depender de
    --     que la fila exista ──────────────────────────────────────────────
    BEGIN
      PERFORM public.rpc_revoke_member_role(v_account, v_owner_uid, 'seller');
      RAISE EXCEPTION 'GATE FAILED (20): el admin pudo revocar un rol operativo del propietario.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (20): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (20): el administrador no puede revocar un rol operativo del propietario (guard nuevo).';
  END IF;

  -- ── (15)-(16) autoridad: un MIEMBRO sin owner/admin no tiene autoridad ──
  -- (cobertura nueva, ronda 1 adversarial -- antes sólo se probaba el caso
  -- de un NO-miembro en (8); v_member_uid es miembro real con roles
  -- {viewer,seller,stock}, ninguno owner/admin: cae en la rama ELSE.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_member_uid::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_member_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al member sin autoridad -- se omiten los bloques (15)-(16).';
  ELSE
    -- ── (15) un miembro sin autoridad no puede ASIGNAR roles ────────────────
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_admin_uid, 'viewer', NULL);
      RAISE EXCEPTION 'GATE FAILED (15): un miembro sin autoridad (viewer/seller/stock) pudo asignar un rol.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (15): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (15): un miembro sin owner/admin no tiene autoridad para asignar roles.';

    -- ── (16) un miembro sin autoridad no puede REVOCAR roles ────────────────
    BEGIN
      PERFORM public.rpc_revoke_member_role(v_account, v_admin_uid, 'admin');
      RAISE EXCEPTION 'GATE FAILED (16): un miembro sin autoridad pudo revocar un rol.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (16): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (16): un miembro sin owner/admin no tiene autoridad para revocar roles.';
  END IF;

  -- ── (8) no-miembro sin autoridad ──────────────────────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger_uid::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_stranger_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al stranger -- se omite el bloque (8).';
  ELSE
    BEGIN
      PERFORM public.rpc_assign_member_role(v_account, v_member_uid, 'viewer', NULL);
      RAISE EXCEPTION 'GATE FAILED (8): un no-miembro de la cuenta pudo asignar un rol.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (8): esperaba P0403, dio % (%)', v_caught_code, SQLERRM;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (8): un no-miembro de la cuenta no tiene autoridad para asignar roles.';

    -- ── (14b) guard de tenencia de rpc_list_account_members ────────────────
    IF (SELECT COUNT(*) FROM public.rpc_list_account_members(v_account)) <> 0 THEN
      RAISE EXCEPTION 'GATE FAILED (14b): un no-miembro obtuvo filas del listado de OTRA cuenta.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (14b): rpc_list_account_members es fail-closed por tenencia.';
  END IF;

  -- Cleanup. handle_new_user aprovisiona una cuenta PROPIA para CADA
  -- auth.users insertado (owner, member, admin, stranger tienen 4 cuentas
  -- distintas, no sólo v_account/v_other_account) -- se limpia por
  -- owner_user_id IN (los 4 uids), no por los 2 ids de cuenta capturados.
  --
  -- RONDA 2 ADVERSARIAL (finding MINOR, corregido): el DELETE de
  -- account_member_roles de la versión anterior filtraba SÓLO por los 3
  -- member_id capturados en variables (los de v_account) -- las 4 cuentas
  -- AUTO-APROVISIONADAS (una por cada auth.users insertado, incluida la del
  -- propio owner) también siembran su fila de pivot 'owner' vía
  -- handle_new_user, y el DELETE FROM accounts de abajo corre bajo
  -- `session_replication_role = replica` (desactiva el ON DELETE CASCADE) --
  -- esas filas quedaban huérfanas (+3 medidas: admin/member/stranger, cada
  -- uno dueño de su propia cuenta). Igual que handle_new_user siembra 7
  -- payment_methods + 7 product_categories por cuenta, sin ningún DELETE
  -- explícito para ellas (+28 huérfanas medidas: 4 cuentas × 7). Mismo
  -- patrón que test_admin_kpis.sql (#521): se captura el array de ids de
  -- cuenta ANTES de borrar `accounts` (una vez borrada, un `WHERE account_id
  -- IN (SELECT id FROM accounts WHERE owner_user_id IN (...))` evaluado
  -- DESPUÉS del DELETE devolvería 0 filas de forma VACUA -- el propio chequeo
  -- de saldo quedaría ciego a la fuga que debía atrapar) y se filtra/assertea
  -- contra ese array capturado, no contra los ids de member_id/cuenta
  -- originalmente acotados.
  RESET request.jwt.claims;
  DECLARE
    v_account_ids uuid[];
  BEGIN
    SELECT array_agg(id) INTO v_account_ids
    FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);

    DELETE FROM account_member_roles WHERE account_id = ANY(v_account_ids);
    DELETE FROM account_members WHERE id IN (v_owner_member, v_target_member, v_admin_member);
    SET session_replication_role = replica;
    DELETE FROM cashboxes WHERE branch_id IN (
      SELECT id FROM branches WHERE account_id = ANY(v_account_ids)
    );
    DELETE FROM branches WHERE account_id = ANY(v_account_ids);
    DELETE FROM account_members WHERE account_id = ANY(v_account_ids);
    DELETE FROM payment_methods WHERE account_id = ANY(v_account_ids);
    DELETE FROM product_categories WHERE account_id = ANY(v_account_ids);
    DELETE FROM accounts WHERE id = ANY(v_account_ids);
    SET session_replication_role = DEFAULT;
    DELETE FROM profiles WHERE id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);
    DELETE FROM email_logs WHERE user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);
    DELETE FROM auth.users WHERE id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);

    -- Ronda 2 adversarial: assertear saldo CERO contra el array CAPTURADO
    -- (no una subquery contra `accounts`, ya vacía a esta altura) -- mismo
    -- patrón que el bloque de #521 en test_admin_kpis.sql.
    SELECT COUNT(*) INTO v_orphans FROM (
      SELECT account_id FROM account_member_roles WHERE account_id = ANY(v_account_ids)
      UNION ALL
      SELECT account_id FROM payment_methods WHERE account_id = ANY(v_account_ids)
      UNION ALL
      SELECT account_id FROM product_categories WHERE account_id = ANY(v_account_ids)
    ) orphans;
    IF v_orphans <> 0 THEN
      RAISE EXCEPTION 'GATE MEMBER-ROLE-ASSIGNMENT-RPCS: quedaron % filas huérfanas tras el cleanup (account_member_roles/payment_methods/product_categories)', v_orphans;
    END IF;
  END;

  IF v_blocks_run <> 21 THEN
    RAISE EXCEPTION 'GATE MEMBER-ROLE-ASSIGNMENT-RPCS FAILED (conteo): se ejercitaron % de 21 bloques esperados (algunos pueden haberse degradado por límite del entorno local -- ver NOTICEs arriba).', v_blocks_run;
  END IF;

  RAISE NOTICE 'GATE MEMBER-ROLE-ASSIGNMENT-RPCS: %/21 bloques PASS.', v_blocks_run;
EXCEPTION
  WHEN OTHERS THEN
    RESET request.jwt.claims;
    SET session_replication_role = replica;
    DELETE FROM account_member_roles WHERE member_id IN (
      SELECT id FROM account_members WHERE account_id IN (
        SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid)
      )
    );
    DELETE FROM cashboxes WHERE branch_id IN (
      SELECT id FROM branches WHERE account_id IN (
        SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid)
      )
    );
    DELETE FROM branches WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid)
    );
    DELETE FROM account_members WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid)
    );
    -- Ronda 2 adversarial: mismo cleanup de payment_methods/product_categories
    -- que el camino feliz -- una corrida que falla a mitad de camino (el
    -- caso que ESTE handler cubre) sembraba la MISMA fuga que el hallazgo
    -- original, sólo que con más frecuencia (cualquier corrida rota en
    -- desarrollo). Subquery evaluada ANTES del DELETE FROM accounts de abajo
    -- -- todavía resuelve filas reales acá.
    DELETE FROM payment_methods WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid)
    );
    DELETE FROM product_categories WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid)
    );
    DELETE FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);
    DELETE FROM profiles WHERE id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);
    DELETE FROM email_logs WHERE user_id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);
    DELETE FROM auth.users WHERE id IN (v_owner_uid, v_member_uid, v_admin_uid, v_stranger_uid);
    SET session_replication_role = DEFAULT;
    RAISE;
END $$;
