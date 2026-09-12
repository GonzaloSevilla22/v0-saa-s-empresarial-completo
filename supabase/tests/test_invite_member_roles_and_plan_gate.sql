-- =============================================================================
-- GATE: test_invite_member_roles_and_plan_gate.sql
-- CHANGE: v3-rbac-multirole Parte C, grupo 15 (D17, D18, account-membership-
-- roles "La invitación de un miembro admite el conjunto de roles con que se
-- incorpora" / "El cupo comercial cuenta miembros, no roles").
--
--   (1) El gate "admin requiere plan pro" se retira de rpc_change_member_role
--       -- una cuenta en el plan más barato promueve member->admin sin error.
--   (2) El gate de plan se retira de rpc_invite_member(3-arg) -- invitar con
--       el rol admin en el conjunto no exige plan pro.
--   (3) El cupo cuenta MIEMBROS, no asignaciones: un miembro con 4 roles
--       simultáneos sigue consumiendo UN solo lugar -- invitar a una 2ª
--       persona con cupo para 5 y sólo 1 miembro real se acepta igual.
--   (4) rpc_invite_member(3-arg): cupo agotado -> P0402, TEXTO conservado
--       ("member quota reached").
--   (5) rpc_invite_member(3-arg): invitación pendiente duplicada -> P0407,
--       texto conservado ("pending invitation already exists").
--   (6) rpc_invite_member(3-arg): el administrador NO puede invitar con el
--       rol de administrador en el conjunto -> P0403.
--   (7) rpc_invite_member(2-arg, TeamSection.tsx): cupo agotado -> P0402
--       también (mismo código que el overload de 3 args).
--   (8) Invitación SIN roles declarados (NULL) resuelve a {viewer} al
--       aceptarse.
--   (9) Invitación con el conjunto {seller, cashier} concede AMBOS roles al
--       aceptarse.
--   (10) rpc_accept_invitation: cupo agotado AL MOMENTO DE ACEPTAR (no al
--        invitar) -> P0402 -- la cuenta se llenó con otro miembro entre la
--        invitación y la aceptación.
--   (11) rpc_accept_invitation: token inválido/vencido -> P0404 (ronda 1
--        adversarial, finding NIT: P0001 -> P0404, texto conservado).
--   (12) rpc_accept_invitation: el caller YA es miembro de la cuenta de la
--        invitación -> P0409 (ronda 1 adversarial, finding NIT: P0001 ->
--        P0409, texto conservado).
--
-- membership-quota-effective-plan (humo v3-rbac-multirole, bug 1,
-- 2026-09-12) -- el cupo se evalúa contra el plan EFECTIVO
-- (public.get_effective_plan), no accounts.billing_plan crudo:
--   (13) Cuenta 'gratis' con trial 'pro' VIGENTE (estado real de TODA
--        cuenta nueva, billing-pro-trial): invitar al 2º miembro PASA --
--        el cupo es el del trial (10), no el de 'gratis' (1, ya ocupado
--        por el owner).
--   (13b) Ronda 3 adversarial (finding NIT): el mismo cupo EFECTIVO,
--        ejercitado EN CONDUCTA sobre el overload de 2 args de
--        rpc_invite_member (el que invoca de verdad TeamSection.tsx) -- el
--        overload de 3 args ya se ejercita en conducta en (13); el de 2
--        args sólo estaba cubierto por el candado de texto (16).
--   (14) Cuenta 'gratis' con trial VENCIDO (o sin trial): el efectivo
--        degrada a 'gratis' -> cupo 1, ya a tope con el owner -> P0402 al
--        invitar.
--   (15) rpc_accept_invitation respeta el MISMO cupo efectivo, evaluado de
--        nuevo al aceptar (no heredado del momento de invitar): una
--        invitación creada mientras el trial estaba vigente se rechaza con
--        P0402 si el trial vence ANTES de que se acepte.
--   (16) Ninguna de las 4 funciones (rpc_invite_member × 2, rpc_accept_
--        invitation, rpc_create_branch) lee accounts.billing_plan crudo --
--        candado de texto (regex sobre pg_get_functiondef sin comentarios)
--        que asegura que el fix no se revierta en silencio en una
--        reescritura futura. rpc_create_branch sumada en ronda 3 adversarial
--        (finding MINOR): mismo bug lateral, misma migración
--        (20261050000001) -- ver también supabase/tests/
--        test_sucursal_guard_vaciado.sql (G3a/G3b) para la conducta.
-- =============================================================================

DO $$
DECLARE
  v_blocks_run    int := 0;
  -- A1: plan 'gratis' (max_users=1), YA a cupo con el solo owner.
  v_a1_owner_uid  uuid := gen_random_uuid();
  v_a1_account    uuid;
  -- A2: plan 'avanzado' (max_users=5), con margen para varios sub-tests.
  v_a2_owner_uid  uuid := gen_random_uuid();
  v_a2_admin_uid  uuid := gen_random_uuid();
  v_a2_account    uuid;
  v_a2_owner_member uuid;
  v_a2_admin_member uuid;
  -- A4: plan 'inicial' (max_users=2), dedicada a la carrera invite/accept.
  v_a4_owner_uid  uuid := gen_random_uuid();
  v_a4_filler_uid uuid := gen_random_uuid();
  v_a4_account    uuid;
  -- A5: plan 'gratis' con trial 'pro' VIGENTE (estado real de TODA cuenta
  -- nueva, billing-pro-trial) -- bloques 13 y 15 (membership-quota-
  -- effective-plan).
  v_a5_owner_uid   uuid := gen_random_uuid();
  v_a5_invitee_uid uuid := gen_random_uuid();
  v_a5_account     uuid;
  -- A6: plan 'gratis' con trial VENCIDO -- bloque 14.
  v_a6_owner_uid  uuid := gen_random_uuid();
  v_a6_account    uuid;
  v_result        jsonb;
  v_result_json   json;
  v_caught_code   text;
  v_caught_msg    text;
  v_inv_token     text;
  v_def           text;
  v_account_ids   uuid[];
  v_orphans       int;
BEGIN
  BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_a1_owner_uid, 'gate-invite-a1-owner@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_a2_owner_uid, 'gate-invite-a2-owner@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_a2_admin_uid, 'gate-invite-a2-admin@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_a4_owner_uid, 'gate-invite-a4-owner@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_a4_filler_uid, 'gate-invite-a4-filler@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_a5_owner_uid, 'gate-invite-a5-owner@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_a5_invitee_uid, 'gate-invite-a5-invitee@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_a6_owner_uid, 'gate-invite-a6-owner@test.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudieron crear los usuarios ancla (%). Se aborta el gate.', SQLERRM;
    RETURN;
  END;

  SELECT account_id INTO v_a1_account FROM account_members WHERE user_id = v_a1_owner_uid;
  SELECT account_id, id INTO v_a2_account, v_a2_owner_member FROM account_members WHERE user_id = v_a2_owner_uid;
  SELECT account_id INTO v_a4_account FROM account_members WHERE user_id = v_a4_owner_uid;
  SELECT account_id INTO v_a5_account FROM account_members WHERE user_id = v_a5_owner_uid;
  SELECT account_id INTO v_a6_account FROM account_members WHERE user_id = v_a6_owner_uid;

  IF v_a1_account IS NULL OR v_a2_account IS NULL OR v_a4_account IS NULL
     OR v_a5_account IS NULL OR v_a6_account IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: handle_new_user no aprovisionó alguna cuenta ancla. Se aborta el gate.';
    RETURN;
  END IF;

  -- membership-quota-effective-plan (bug 1, 2026-09-12): handle_new_user
  -- siembra TODA cuenta nueva con trial_plan='pro' vigente (30 días) --
  -- ahora que el cupo se evalúa contra el plan EFECTIVO (get_effective_
  -- plan), un trial vigente le ganaría a billing_plan y estas 3 cuentas
  -- dejarían de comportarse como 'gratis'(1)/'avanzado'(5)/'inicial'(2)
  -- crudos. Se apaga el trial explícitamente en las 3 -- A1/A2/A4 siguen
  -- probando billing_plan puro (sin trial); A5/A6 (abajo) son las únicas
  -- que ejercitan el trial a propósito.
  UPDATE accounts SET billing_plan = 'gratis',   trial_plan = NULL, trial_expires_at = NULL WHERE id = v_a1_account;
  UPDATE accounts SET billing_plan = 'avanzado', trial_plan = NULL, trial_expires_at = NULL WHERE id = v_a2_account;
  UPDATE accounts SET billing_plan = 'inicial',  trial_plan = NULL, trial_expires_at = NULL WHERE id = v_a4_account;
  -- A5: 'gratis' + trial 'pro' vigente (10 días) -- exactamente el estado
  -- con el que handle_new_user aprovisiona toda cuenta nueva (no hace
  -- falta simularlo -- ya nace así; se fija el vencimiento explícito para
  -- que el gate no dependa de la ventana de 30 días real).
  UPDATE accounts SET billing_plan = 'gratis', trial_plan = 'pro',
    trial_expires_at = now() + interval '10 days' WHERE id = v_a5_account;
  -- A6: 'gratis' con trial VENCIDO -- el efectivo degrada a 'gratis' (cupo 1).
  UPDATE accounts SET billing_plan = 'gratis', trial_plan = 'pro',
    trial_expires_at = now() - interval '1 day' WHERE id = v_a6_account;

  -- A2: 2º miembro real con rol admin (para el bloque 6).
  INSERT INTO account_members (id, account_id, user_id, role)
  VALUES (gen_random_uuid(), v_a2_account, v_a2_admin_uid, 'admin')
  RETURNING id INTO v_a2_admin_member;
  INSERT INTO account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_a2_account, v_a2_admin_member, 'admin', now())
  ON CONFLICT (member_id, role) DO NOTHING;

  -- ═══ Sesión: owner de A2 ═══════════════════════════════════════════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2_owner_uid::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_a2_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al owner de A2 -- se omiten los bloques 1-3, 5, 8, 9.';
  ELSE
    -- ── (1) plan gate removido de rpc_change_member_role (A2 no es pro) ───
    v_result := public.rpc_change_member_role(v_a2_account, v_a2_admin_uid, 'member');
    IF (v_result->>'ok') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'GATE FAILED setup: no se pudo degradar admin->member para el bloque 1: %', v_result;
    END IF;
    v_result := public.rpc_change_member_role(v_a2_account, v_a2_admin_uid, 'admin');
    IF (v_result->>'ok') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'GATE FAILED (1): promover a admin en un plan NO-pro fue rechazado: %', v_result;
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (1): rpc_change_member_role promueve a admin sin exigir plan pro (D17).';

    -- ── (3) cupo cuenta MIEMBROS, no asignaciones ─────────────────────────
    PERFORM public.rpc_assign_member_role(v_a2_account, v_a2_owner_uid, 'seller', NULL);
    PERFORM public.rpc_assign_member_role(v_a2_account, v_a2_owner_uid, 'cashier', NULL);
    PERFORM public.rpc_assign_member_role(v_a2_account, v_a2_owner_uid, 'stock', NULL);
    IF (SELECT COUNT(*) FROM account_member_roles amr JOIN account_members am ON am.id = amr.member_id
        WHERE am.account_id = v_a2_account AND am.user_id = v_a2_owner_uid) < 4 THEN
      RAISE EXCEPTION 'GATE FAILED setup (3): el owner de A2 no quedó con 4 roles simultáneos.';
    END IF;
    -- Con 2 miembros reales (owner + admin) y cupo de 5 ('avanzado'), invitar
    -- una 3ª persona debe aceptarse SIN que los 4 roles del owner cuenten
    -- de más -- el cupo mira account_members, nunca account_member_roles.
    v_result_json := public.rpc_invite_member('gate-invite-a2-third@test.local'::text, v_a2_account, ARRAY['viewer']::text[]);
    IF v_result_json IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (3): la invitación de la 3ª persona fue rechazada pese a haber cupo real.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (3): el cupo cuenta MIEMBROS, no asignaciones -- un miembro con 4 roles consume un solo lugar.';

    -- ── (2) plan gate removido de rpc_invite_member(3-arg): rol admin ─────
    v_result_json := public.rpc_invite_member('gate-invite-a2-admininvite@test.local'::text, v_a2_account, ARRAY['admin']::text[]);
    IF v_result_json IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (2): invitar con el rol admin en un plan NO-pro fue rechazado.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (2): rpc_invite_member invita con el rol admin sin exigir plan pro (D17).';

    -- ── (5) invitación pendiente duplicada -> P0407, texto conservado ─────
    BEGIN
      PERFORM public.rpc_invite_member('gate-invite-a2-admininvite@test.local'::text, v_a2_account, ARRAY['viewer']::text[]);
      RAISE EXCEPTION 'GATE FAILED (5): una 2ª invitación pendiente para el mismo email no fue rechazada.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
      IF v_caught_code <> 'P0407' THEN
        RAISE EXCEPTION 'GATE FAILED (5): esperaba P0407, dio % (%)', v_caught_code, v_caught_msg;
      END IF;
      IF v_caught_msg NOT ILIKE '%pending invitation already exists%' THEN
        RAISE EXCEPTION 'GATE FAILED (5): el texto del mensaje no se conservó: %', v_caught_msg;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (5): invitación duplicada -> P0407 con el texto original conservado (D18).';

    -- ── (8) invitación sin roles declarados -> {viewer} al aceptar ────────
    v_result_json := public.rpc_invite_member('gate-invite-a2-noroles@test.local'::text, v_a2_account, NULL::text[]);
    v_inv_token := (SELECT token FROM account_invitations WHERE id = (v_result_json->>'id')::uuid);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a4_filler_uid::text, 'role', 'authenticated')::text, true);
    IF auth.uid() IS DISTINCT FROM v_a4_filler_uid THEN
      RAISE NOTICE 'GATE DEGRADED: no se pudo simular al aceptante del bloque 8.';
    ELSE
      v_result_json := public.rpc_accept_invitation(v_inv_token);
      IF NOT EXISTS (
        SELECT 1 FROM account_member_roles amr
        JOIN account_members am ON am.id = amr.member_id
        WHERE am.account_id = v_a2_account AND am.user_id = v_a4_filler_uid AND amr.role = 'viewer'
      ) THEN
        RAISE EXCEPTION 'GATE FAILED (8): la invitación sin roles no resolvió a viewer al aceptarse.';
      END IF;
      v_blocks_run := v_blocks_run + 1;
      RAISE NOTICE 'PASS (8): invitación sin roles declarados resuelve a {viewer} (account-membership-roles).';
    END IF;

    -- ── (9) invitación con {seller, cashier} concede ambos ────────────────
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2_owner_uid::text, 'role', 'authenticated')::text, true);
    v_result_json := public.rpc_invite_member('gate-invite-a2-tworoles@test.local'::text, v_a2_account, ARRAY['seller','cashier']::text[]);
    v_inv_token := (SELECT token FROM account_invitations WHERE id = (v_result_json->>'id')::uuid);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a4_owner_uid::text, 'role', 'authenticated')::text, true);
    -- v_a4_owner_uid es owner de SU PROPIA cuenta (A4) -- puede aceptar una
    -- invitación de A2 igual, porque "ya es miembro" sólo mira A2, no A4.
    IF auth.uid() IS DISTINCT FROM v_a4_owner_uid THEN
      RAISE NOTICE 'GATE DEGRADED: no se pudo simular al aceptante del bloque 9.';
    ELSE
      v_result_json := public.rpc_accept_invitation(v_inv_token);
      IF (SELECT COUNT(*) FROM account_member_roles amr
          JOIN account_members am ON am.id = amr.member_id
          WHERE am.account_id = v_a2_account AND am.user_id = v_a4_owner_uid
            AND amr.role IN ('seller','cashier')) <> 2
      THEN
        RAISE EXCEPTION 'GATE FAILED (9): la invitación con {seller,cashier} no concedió ambos roles.';
      END IF;
      v_blocks_run := v_blocks_run + 1;
      RAISE NOTICE 'PASS (9): invitación con un conjunto de roles concede TODOS al aceptarse.';

      -- ── (11) token inválido/vencido -> P0404 (ronda 1 adversarial, ─────────
      --    finding NIT: P0001 -> P0404, texto conservado). Todavía en la
      --    sesión de v_a4_owner_uid (auth.uid() ya resuelto arriba).
      BEGIN
        PERFORM public.rpc_accept_invitation('token-inexistente-' || gen_random_uuid()::text);
        RAISE EXCEPTION 'GATE FAILED (11): un token inexistente no fue rechazado.';
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
        IF v_caught_code <> 'P0404' THEN
          RAISE EXCEPTION 'GATE FAILED (11): esperaba P0404, dio %', v_caught_code;
        END IF;
      END;
      v_blocks_run := v_blocks_run + 1;
      RAISE NOTICE 'PASS (11): rpc_accept_invitation -- token inválido/vencido -> P0404 (ronda 1 adversarial).';
    END IF;
  END IF;

  -- ── (12) ya es miembro -> P0409 (ronda 1 adversarial, finding NIT: ───────
  --    P0001 -> P0409, texto conservado). v_a4_owner_uid YA es miembro de
  --    A2 desde el bloque 9 -- se crea una invitación NUEVA para el MISMO
  --    email y se intenta aceptar de nuevo.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2_owner_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_a2_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al owner de A2 -- se omite el setup del bloque 12.';
  ELSE
    v_result_json := public.rpc_invite_member('gate-invite-a2-alreadymember@test.local'::text, v_a2_account, ARRAY['viewer']::text[]);
    v_inv_token := (SELECT token FROM account_invitations WHERE id = (v_result_json->>'id')::uuid);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a4_owner_uid::text, 'role', 'authenticated')::text, true);
    IF auth.uid() IS DISTINCT FROM v_a4_owner_uid THEN
      RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al aceptante del bloque 12.';
    ELSE
      BEGIN
        PERFORM public.rpc_accept_invitation(v_inv_token);
        RAISE EXCEPTION 'GATE FAILED (12): aceptar una invitación de una cuenta de la que YA es miembro no fue rechazado.';
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
        IF v_caught_code <> 'P0409' THEN
          RAISE EXCEPTION 'GATE FAILED (12): esperaba P0409, dio % (%)', v_caught_code, v_caught_msg;
        END IF;
        IF v_caught_msg NOT ILIKE '%already a member%' THEN
          RAISE EXCEPTION 'GATE FAILED (12): el texto del mensaje no se conservó: %', v_caught_msg;
        END IF;
      END;
      v_blocks_run := v_blocks_run + 1;
      RAISE NOTICE 'PASS (12): rpc_accept_invitation -- ya es miembro -> P0409, texto conservado (ronda 1 adversarial).';
    END IF;
  END IF;

  -- ═══ membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, ══════
  --     2026-09-12) -- bloques 13-15: A5 (gratis + trial pro vigente) y A6
  --     (gratis + trial vencido).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a5_owner_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_a5_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al owner de A5 -- se omiten los bloques 13 y 15.';
  ELSE
    -- ── (13) 'gratis' + trial 'pro' VIGENTE: invitar al 2º miembro PASA ────
    --    (cupo del trial efectivo = 10, no el de 'gratis' crudo = 1, ya
    --    ocupado por el owner). Sin este fix, TODA cuenta nueva quedaba sin
    --    poder invitar durante los 30 días de trial.
    v_result_json := public.rpc_invite_member('gate-invite-a5-invitee@test.local'::text, v_a5_account, ARRAY['viewer']::text[]);
    IF v_result_json IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (13): invitar en una cuenta gratis con trial pro VIGENTE fue rechazado -- el cupo debe ser el del plan EFECTIVO (bug 1, membership-quota-effective-plan).';
    END IF;
    v_inv_token := (SELECT token FROM account_invitations WHERE id = (v_result_json->>'id')::uuid);
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (13): rpc_invite_member -- cuenta gratis con trial pro vigente invita sin cupo agotado (plan EFECTIVO, no billing_plan crudo).';

    -- ── (13b) rpc_invite_member(2-arg, TeamSection.tsx): MISMO trial VIGENTE ──
    --    Ronda 3 adversarial (finding NIT): el overload de 3 args ya se
    --    ejercita EN CONDUCTA arriba (13); el de 2 args -- el que invoca de
    --    verdad TeamSection.tsx -- sólo estaba cubierto por el candado de
    --    texto (16): si mañana alguien reescribe este overload llamando a
    --    get_effective_plan y DESCARTA el resultado, (16) seguiría en verde
    --    por texto aunque la conducta se rompa. Se invita un email DISTINTO,
    --    todavía con el trial de A5 vigente (antes del UPDATE de (15) que lo
    --    vence).
    v_result_json := public.rpc_invite_member('gate-invite-a5-quick@test.local'::text, v_a5_account);
    IF v_result_json IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (13b): rpc_invite_member(2-arg) con trial pro VIGENTE fue rechazado -- debería usar el cupo EFECTIVO igual que el overload de 3 args.';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (13b): rpc_invite_member(2-arg, TeamSection.tsx) también invita con el cupo EFECTIVO (trial pro vigente) -- en CONDUCTA, no sólo por candado de texto.';

    -- ── (15) rpc_accept_invitation reevalúa el cupo EFECTIVO al aceptar ────
    --    (no lo hereda del momento de invitar): se deja vencer el trial de
    --    A5 ENTRE la invitación de arriba y la aceptación -- el efectivo
    --    degrada a 'gratis' (cupo 1, ya a tope con el owner) -> P0402.
    --    Prueba que rpc_accept_invitation llama a get_effective_plan() de
    --    NUEVO, no reutiliza un valor cacheado de rpc_invite_member.
    UPDATE accounts SET trial_expires_at = now() - interval '1 day' WHERE id = v_a5_account;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a5_invitee_uid::text, 'role', 'authenticated')::text, true);
    IF auth.uid() IS DISTINCT FROM v_a5_invitee_uid THEN
      RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al aceptante del bloque 15.';
    ELSE
      BEGIN
        PERFORM public.rpc_accept_invitation(v_inv_token);
        RAISE EXCEPTION 'GATE FAILED (15): aceptar tras vencer el trial (efectivo degradado a gratis, cupo agotado) no fue rechazado.';
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
        IF v_caught_code <> 'P0402' THEN
          RAISE EXCEPTION 'GATE FAILED (15): esperaba P0402, dio % (%)', v_caught_code, v_caught_msg;
        END IF;
        IF v_caught_msg NOT ILIKE '%member quota reached%' THEN
          RAISE EXCEPTION 'GATE FAILED (15): el texto del mensaje de cupo no se conservó: %', v_caught_msg;
        END IF;
      END;
      v_blocks_run := v_blocks_run + 1;
      RAISE NOTICE 'PASS (15): rpc_accept_invitation reevalúa el plan EFECTIVO al aceptar (no lo hereda del momento de invitar) -> P0402 cuando el trial venció entretanto.';
    END IF;
  END IF;

  -- ── (14) 'gratis' + trial VENCIDO: el efectivo degrada a 'gratis' ─────────
  --    (cupo 1, ya a tope con el owner) -> P0402 al invitar.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a6_owner_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_a6_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al owner de A6 -- se omite el bloque 14.';
  ELSE
    BEGIN
      PERFORM public.rpc_invite_member('gate-invite-a6-x@test.local'::text, v_a6_account, ARRAY['viewer']::text[]);
      RAISE EXCEPTION 'GATE FAILED (14): invitar con el trial VENCIDO (efectivo gratis, cupo agotado) no fue rechazado.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
      IF v_caught_code <> 'P0402' THEN
        RAISE EXCEPTION 'GATE FAILED (14): esperaba P0402, dio % (%)', v_caught_code, v_caught_msg;
      END IF;
      IF v_caught_msg NOT ILIKE '%member quota reached%' THEN
        RAISE EXCEPTION 'GATE FAILED (14): el texto del mensaje de cupo no se conservó: %', v_caught_msg;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (14): rpc_invite_member -- trial vencido degrada el efectivo a gratis (cupo 1) -> P0402.';
  END IF;

  -- ── (16) candado de texto: ninguna de las 3 lee billing_plan crudo ────────
  --    (regex sobre pg_get_functiondef SIN comentarios -- una mención del
  --    identificador dentro de un comentario no es una lectura; mismo
  --    patrón que ya usa test_tenancy_guard_caja_outbox.sql). Cada una debe,
  --    además, llamar a get_effective_plan.
  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_invite_member' AND p.pronargs = 2;
  IF position('billing_plan' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_invite_member(2-arg) todavía lee billing_plan crudo -- el fix de membership-quota-effective-plan se revirtió.';
  END IF;
  IF position('get_effective_plan' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_invite_member(2-arg) no llama a get_effective_plan.';
  END IF;

  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_invite_member' AND p.pronargs = 3;
  IF position('billing_plan' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_invite_member(3-arg) todavía lee billing_plan crudo -- el fix de membership-quota-effective-plan se revirtió.';
  END IF;
  IF position('get_effective_plan' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_invite_member(3-arg) no llama a get_effective_plan.';
  END IF;

  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_accept_invitation';
  IF position('billing_plan' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_accept_invitation todavía lee billing_plan crudo -- el fix de membership-quota-effective-plan se revirtió.';
  END IF;
  IF position('get_effective_plan' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_accept_invitation no llama a get_effective_plan.';
  END IF;

  -- Ronda 3 adversarial (finding MINOR): rpc_create_branch tenía la MISMA
  -- clase de bug lateral (max_branches/has_branches_module contra
  -- billing_plan crudo) -- sumada al mismo candado de texto, misma
  -- migración (20261050000001).
  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_branch';
  IF position('billing_plan' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_create_branch todavía lee billing_plan crudo -- el fix de membership-quota-effective-plan (hallazgo lateral MINOR, ronda 3 adversarial) se revirtió.';
  END IF;
  IF position('get_effective_plan' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE FAILED (16): rpc_create_branch no llama a get_effective_plan.';
  END IF;

  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (16): ninguna de las 4 funciones lee billing_plan crudo -- las 4 resuelven el cupo/módulo contra get_effective_plan.';

  -- ═══ Sesión: admin de A2 -- bloque 6 ═══════════════════════════════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2_admin_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_a2_admin_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al admin de A2 -- se omite el bloque 6.';
  ELSE
    BEGIN
      PERFORM public.rpc_invite_member('gate-invite-a2-adminattempt@test.local'::text, v_a2_account, ARRAY['admin']::text[]);
      RAISE EXCEPTION 'GATE FAILED (6): el administrador pudo invitar con el rol admin en el conjunto.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0403' THEN
        RAISE EXCEPTION 'GATE FAILED (6): esperaba P0403, dio %', v_caught_code;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (6): el administrador no puede invitar con el rol de administrador en el conjunto.';
  END IF;

  -- ═══ Sesión: owner de A1 (YA a cupo, gratis max=1) -- bloques 4, 7 ═════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a1_owner_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_a1_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al owner de A1 -- se omiten los bloques 4 y 7.';
  ELSE
    -- ── (4) rpc_invite_member(3-arg): cupo agotado -> P0402 ───────────────
    BEGIN
      PERFORM public.rpc_invite_member('gate-invite-a1-x@test.local'::text, v_a1_account, ARRAY['viewer']::text[]);
      RAISE EXCEPTION 'GATE FAILED (4): invitar con la cuenta a cupo no fue rechazado.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
      IF v_caught_code <> 'P0402' THEN
        RAISE EXCEPTION 'GATE FAILED (4): esperaba P0402, dio % (%)', v_caught_code, v_caught_msg;
      END IF;
      IF v_caught_msg NOT ILIKE '%member quota reached%' THEN
        RAISE EXCEPTION 'GATE FAILED (4): el texto del mensaje de cupo no se conservó: %', v_caught_msg;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (4): rpc_invite_member(3-arg) -- cupo agotado -> P0402, texto conservado (D18).';

    -- ── (7) rpc_invite_member(2-arg, TeamSection.tsx): cupo agotado ───────
    BEGIN
      PERFORM public.rpc_invite_member('gate-invite-a1-y@test.local'::text, v_a1_account);
      RAISE EXCEPTION 'GATE FAILED (7): el overload de 2 args no rechazó la cuenta a cupo.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE;
      IF v_caught_code <> 'P0402' THEN
        RAISE EXCEPTION 'GATE FAILED (7): esperaba P0402, dio %', v_caught_code;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (7): rpc_invite_member(2-arg) -- mismo código de cupo P0402 (D18).';
  END IF;

  -- ═══ Bloque 10: carrera invite/accept en A4 (inicial, max=2) ═══════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a4_owner_uid::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_a4_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al owner de A4 -- se omite el bloque 10.';
  ELSE
    v_result_json := public.rpc_invite_member('gate-invite-a4-late@test.local'::text, v_a4_account, ARRAY['viewer']::text[]);
    v_inv_token := (SELECT token FROM account_invitations WHERE id = (v_result_json->>'id')::uuid);

    -- Entre la invitación y la aceptación, la cuenta se llena con otro
    -- miembro real (v_a4_filler_uid, que en el bloque 8 ya aceptó una
    -- invitación de A2 -- acá se une DIRECTO a A4 para simular la carrera,
    -- sin pasar por invite/accept).
    INSERT INTO account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_a4_account, v_a4_filler_uid, 'member')
    ON CONFLICT (account_id, user_id) DO NOTHING;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2_owner_uid::text, 'role', 'authenticated')::text, true);
    -- v_a2_owner_uid acepta la invitación tardía de A4 -- no es miembro de
    -- A4 todavía, así que el chequeo "ya es miembro" no interfiere.
    BEGIN
      PERFORM public.rpc_accept_invitation(v_inv_token);
      RAISE EXCEPTION 'GATE FAILED (10): aceptar con la cuenta YA llena entretanto no fue rechazado.';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_code = RETURNED_SQLSTATE, v_caught_msg = MESSAGE_TEXT;
      IF v_caught_code <> 'P0402' THEN
        RAISE EXCEPTION 'GATE FAILED (10): esperaba P0402, dio % (%)', v_caught_code, v_caught_msg;
      END IF;
    END;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (10): rpc_accept_invitation rechaza con P0402 si el cupo se agotó entre invitar y aceptar.';
  END IF;

  -- Cleanup. handle_new_user aprovisiona una cuenta PROPIA para CADA
  -- auth.users insertado -- v_a2_admin_uid y v_a4_filler_uid tienen la SUYA
  -- además de A1/A2/A4, así que se limpia por owner_user_id (los 5 uids),
  -- no sólo por los 3 ids de cuenta capturados.
  --
  -- RONDA 2 ADVERSARIAL (finding MINOR, corregido): handle_new_user siembra
  -- 7 payment_methods + 7 product_categories por cuenta -- sin un DELETE
  -- explícito para ellas, el `DELETE FROM accounts` de abajo (bajo
  -- `session_replication_role = replica`, que desactiva el ON DELETE
  -- CASCADE) las dejaba huérfanas (+35 medidas de cada tipo: 5 cuentas × 7).
  -- El array de ids se captura ANTES de borrar `accounts` -- una vez
  -- borrada, una subquery evaluada DESPUÉS devolvería 0 filas de forma
  -- VACUA y el chequeo de saldo quedaría ciego a la fuga que debía atrapar
  -- (mismo patrón que #521 en test_admin_kpis.sql).
  RESET request.jwt.claims;
  SELECT array_agg(id) INTO v_account_ids
  FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);

  SET session_replication_role = replica;
  DELETE FROM account_invitations WHERE account_id = ANY(v_account_ids);
  DELETE FROM account_member_roles WHERE account_id = ANY(v_account_ids);
  DELETE FROM account_members WHERE account_id = ANY(v_account_ids);
  DELETE FROM cashboxes WHERE branch_id IN (
    SELECT id FROM branches WHERE account_id = ANY(v_account_ids)
  );
  DELETE FROM branches WHERE account_id = ANY(v_account_ids);
  DELETE FROM payment_methods WHERE account_id = ANY(v_account_ids);
  DELETE FROM product_categories WHERE account_id = ANY(v_account_ids);
  DELETE FROM accounts WHERE id = ANY(v_account_ids);
  SET session_replication_role = DEFAULT;
  DELETE FROM profiles WHERE id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);
  DELETE FROM email_logs WHERE user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);
  DELETE FROM auth.users WHERE id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);

  -- Ronda 2 adversarial: assertear saldo CERO contra el array CAPTURADO
  -- (mismo patrón que el bloque de #521 en test_admin_kpis.sql).
  SELECT COUNT(*) INTO v_orphans FROM (
    SELECT account_id FROM account_member_roles WHERE account_id = ANY(v_account_ids)
    UNION ALL
    SELECT account_id FROM payment_methods WHERE account_id = ANY(v_account_ids)
    UNION ALL
    SELECT account_id FROM product_categories WHERE account_id = ANY(v_account_ids)
  ) orphans;
  IF v_orphans <> 0 THEN
    RAISE EXCEPTION 'GATE INVITE-MEMBER-ROLES-AND-PLAN-GATE: quedaron % filas huérfanas tras el cleanup (account_member_roles/payment_methods/product_categories)', v_orphans;
  END IF;

  IF v_blocks_run <> 17 THEN
    RAISE EXCEPTION 'GATE INVITE-MEMBER-ROLES-AND-PLAN-GATE FAILED (conteo): se ejercitaron % de 17 bloques esperados.', v_blocks_run;
  END IF;

  RAISE NOTICE 'GATE INVITE-MEMBER-ROLES-AND-PLAN-GATE: %/17 bloques PASS.', v_blocks_run;
EXCEPTION
  WHEN OTHERS THEN
    RESET request.jwt.claims;
    SET session_replication_role = replica;
    DELETE FROM account_invitations WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid)
    );
    DELETE FROM account_member_roles WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid)
    );
    DELETE FROM account_members WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid)
    );
    DELETE FROM cashboxes WHERE branch_id IN (
      SELECT id FROM branches WHERE account_id IN (
        SELECT id FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid)
      )
    );
    DELETE FROM branches WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid)
    );
    -- Ronda 2 adversarial: mismo cleanup de payment_methods/product_categories
    -- que el camino feliz -- subquery evaluada ANTES del DELETE FROM
    -- accounts de abajo, todavía resuelve filas reales acá.
    DELETE FROM payment_methods WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid)
    );
    DELETE FROM product_categories WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid)
    );
    DELETE FROM accounts WHERE owner_user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);
    DELETE FROM profiles WHERE id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);
    DELETE FROM email_logs WHERE user_id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);
    DELETE FROM auth.users WHERE id IN (v_a1_owner_uid, v_a2_owner_uid, v_a2_admin_uid, v_a4_owner_uid, v_a4_filler_uid, v_a5_owner_uid, v_a5_invitee_uid, v_a6_owner_uid);
    SET session_replication_role = DEFAULT;
    RAISE;
END $$;
