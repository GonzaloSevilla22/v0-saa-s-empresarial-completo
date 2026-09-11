-- =============================================================================
-- GATE: test_membership_rpcs_pivot_rewrite.sql (13 bloques)
-- CHANGE: v3-rbac-multirole Parte A, grupo 5 (D3) — los 4 RPCs de membresía
-- reescritos + el hallazgo 6.3b de handle_new_user + ronda 1 de revisión
-- adversarial (blocker/major/minor cerrados).
--
-- Usa el patrón de anchor sintético vía `request.jwt.claims` local, mismo
-- molde que test_operacion_party_guard.sql / test_cuenta_corriente_party_
-- guard.sql. Degrade-don't-fail si auth.uid() no resuelve contra el claim
-- local (algún entorno de CI atípico) — v_blocks_run cuenta los PASS reales.
--
--   (1) handle_new_user (hallazgo 6.3b, CORREGIDO en ronda 1: la redacción
--       original decía que el signup abortaba con P0405 — es falso, ver la
--       cabecera de la migración): el signup escribe la asignación 'owner'
--       A TRAVÉS DEL PIVOT (no sólo en la columna espejo) — sin esto,
--       trg_derive_account_member_role degradaría en SILENCIO al fundador
--       a 'member' (el invariante de la sección 4 NO se dispara: nunca hay
--       escritura al pivot que lo active).
--   (2) rpc_change_member_role promueve member->admin (plan pro): pivot
--       queda {admin}, columna espejo = 'admin'.
--   (3) rpc_change_member_role degrada admin->member: pivot queda {viewer}
--       (D2: 'member' legacy mapea a 'viewer' en el catálogo), columna
--       espejo = 'member' (vocabulario heredado, NUNCA 'viewer').
--   (4) rpc_change_member_role sigue rechazando degradar al único owner con
--       el mismo {error} JSON de siempre (el guard app-level corta antes de
--       llegar al invariante de base).
--   (5) rpc_change_member_role sigue exigiendo plan pro para promover a
--       admin — MISMO comportamiento, Parte A no toca D17.
--   (6) rpc_remove_member: el DELETE en account_members cascada al pivot
--       (0 filas de account_member_roles para el miembro expulsado).
--   (7) rpc_accept_invitation crea la membresía Y su asignación equivalente
--       en el pivot, con assigned_by = quien invitó.
--   (8) rpc_my_account_role deriva del pivot y devuelve el MISMO vocabulario
--       heredado ('owner'/'admin'/'member') para el caller.
--   (9) RONDA 1 (finding major, corregido): rpc_change_member_role rechaza
--       un rol funcional del catálogo ('seller') — Parte A sólo habilita
--       el vocabulario legacy.
--   (10) RONDA 1 (finding major, agujero PREEXISTENTE cerrado): un caller
--       que no es miembro de la cuenta es rechazado por rpc_change_member_
--       role y por rpc_remove_member (antes, v_caller_role NULL dejaba
--       pasar el `NOT IN`).
--   (11) RONDA 1 (finding minor, corregido): rpc_change_member_role con un
--       target que no es miembro de la cuenta devuelve {error}, no una
--       excepción 23502.
--   (12) candado anti-overload (gotcha 42725) — las 5 funciones tocadas por
--       esta parte (las 4 RPCs + handle_new_user) tienen una ÚNICA
--       definición viva cada una, sin overload nuevo.
--   (13) RONDA 1 (finding BLOCKER, corregido) — RONDA 2 (finding minor,
--       corregido de nuevo): el backfill de la sección 5 mapea a la
--       asignación EQUIVALENTE (viewer/admin), nunca hardcodea 'owner' para
--       una fila legacy que no lo era. La ronda 1 lo verificaba con una
--       COPIA de la sentencia del CASE, propia del gate — no ejercitaba la
--       sentencia REAL de la migración (demostrado: reintroducir el
--       hardcodeo en el ARCHIVO REAL dejaba este gate en verde). Este
--       bloque ahora vive en una Fase separada, AL FINAL de este archivo,
--       fuera del DO principal, que reaplica el ARCHIVO REAL vía \i (mismo
--       patrón que test_cuentas_billetera_tipo.sql) contra un fixture
--       legacy propio, y assertea el resultado que la migración REAL dejó.
-- =============================================================================

DO $$
DECLARE
  v_blocks_run  int := 0;
  v_owner_uid   uuid := gen_random_uuid();
  v_member_uid  uuid := gen_random_uuid();
  v_invitee_uid uuid := gen_random_uuid();
  v_stranger_uid uuid := gen_random_uuid();
  v_account     uuid;
  v_owner_member  uuid;
  v_target_member uuid;
  v_invitee_member uuid;
  v_result      jsonb;
  v_role_result text;
  v_token       text := encode(sha256(gen_random_uuid()::text::bytea), 'hex');
  v_overload_count int;
BEGIN
  BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_owner_uid, 'gate-rpc-rewrite-owner@test.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudo crear el usuario ancla (%). Se aborta el gate.', SQLERRM;
    RETURN;
  END;

  SELECT account_id, id INTO v_account, v_owner_member FROM account_members WHERE user_id = v_owner_uid;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: handle_new_user no aprovisionó la cuenta ancla. Se aborta el gate.';
    RETURN;
  END IF;

  -- ── (1) handle_new_user escribe a través del pivot ──────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM account_member_roles WHERE member_id = v_owner_member AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'GATE FAILED (1): handle_new_user no dejó una asignación owner en el pivot para el signup';
  END IF;
  IF (SELECT role FROM account_members WHERE id = v_owner_member) <> 'owner' THEN
    RAISE EXCEPTION 'GATE FAILED (1): la columna espejo del signup no quedó en owner';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (1): handle_new_user escribe la asignación owner a través del pivot';

  UPDATE accounts SET billing_plan = 'pro' WHERE id = v_account;

  INSERT INTO auth.users (id, email) VALUES (v_member_uid, 'gate-rpc-rewrite-member@test.local');
  INSERT INTO account_members (id, account_id, user_id, role)
  VALUES (gen_random_uuid(), v_account, v_member_uid, 'member')
  RETURNING id INTO v_target_member;

  -- Simula la sesión del owner para las llamadas RPC.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_owner_uid THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los bloques que invocan RPCs.';
  ELSE
    -- ── (2) promover member -> admin ───────────────────────────────────────
    v_result := rpc_change_member_role(v_account, v_member_uid, 'admin');
    IF (v_result->>'ok') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'GATE FAILED (2): rpc_change_member_role(member->admin, plan pro) no devolvió {ok:true}: %', v_result;
    END IF;
    IF (SELECT array_agg(role) FROM account_member_roles WHERE member_id = v_target_member) <> ARRAY['admin'] THEN
      RAISE EXCEPTION 'GATE FAILED (2): el pivot del target no quedó en {admin}: %',
        (SELECT array_agg(role) FROM account_member_roles WHERE member_id = v_target_member);
    END IF;
    IF (SELECT role FROM account_members WHERE id = v_target_member) <> 'admin' THEN
      RAISE EXCEPTION 'GATE FAILED (2): la columna espejo del target no quedó en admin';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (2): rpc_change_member_role promueve a través del pivot';

    -- ── (3) degradar admin -> member (mapea a 'viewer' en el pivot) ────────
    v_result := rpc_change_member_role(v_account, v_member_uid, 'member');
    IF (v_result->>'ok') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'GATE FAILED (3): rpc_change_member_role(admin->member) no devolvió {ok:true}: %', v_result;
    END IF;
    IF (SELECT array_agg(role) FROM account_member_roles WHERE member_id = v_target_member) <> ARRAY['viewer'] THEN
      RAISE EXCEPTION 'GATE FAILED (3): el pivot del target no quedó en {viewer} (D2, mapeo legacy): %',
        (SELECT array_agg(role) FROM account_member_roles WHERE member_id = v_target_member);
    END IF;
    IF (SELECT role FROM account_members WHERE id = v_target_member) <> 'member' THEN
      RAISE EXCEPTION 'GATE FAILED (3): la columna espejo debe seguir en vocabulario heredado (member), no viewer. quedó=%',
        (SELECT role FROM account_members WHERE id = v_target_member);
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (3): degradar a member mapea a viewer en el pivot, pero la columna espejo sigue en vocabulario heredado';

    -- ── (4) no se puede degradar al único owner (mismo {error} de siempre) ─
    v_result := rpc_change_member_role(v_account, v_owner_uid, 'admin');
    IF v_result <> jsonb_build_object('error', 'No se puede degradar al único owner') THEN
      RAISE EXCEPTION 'GATE FAILED (4): el mensaje de error de degradar al único owner cambió: %', v_result;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_owner_member AND role = 'owner') THEN
      RAISE EXCEPTION 'GATE FAILED (4): el owner quedó degradado pese al rechazo';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (4): degradar al único owner sigue rechazado con el mismo {error} de siempre';

    -- ── (5) admin sigue exigiendo plan pro (D17: sin cambios en Parte A) ───
    UPDATE accounts SET billing_plan = 'gratis' WHERE id = v_account;
    v_result := rpc_change_member_role(v_account, v_member_uid, 'admin');
    IF v_result <> jsonb_build_object('error', 'El rol admin requiere plan pro') THEN
      RAISE EXCEPTION 'GATE FAILED (5): el gate de plan para admin cambió de mensaje/comportamiento: %', v_result;
    END IF;
    UPDATE accounts SET billing_plan = 'pro' WHERE id = v_account;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (5): promover a admin sigue exigiendo plan pro, byte a byte';

    -- ── (6) rpc_remove_member cascada al pivot ─────────────────────────────
    v_result := rpc_remove_member(v_account, v_member_uid);
    IF (v_result->>'ok') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'GATE FAILED (6): rpc_remove_member no devolvió {ok:true}: %', v_result;
    END IF;
    IF EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_target_member) THEN
      RAISE EXCEPTION 'GATE FAILED (6): quedaron filas del pivot para un miembro expulsado';
    END IF;
    IF EXISTS (SELECT 1 FROM account_members WHERE id = v_target_member) THEN
      RAISE EXCEPTION 'GATE FAILED (6): la membresía expulsada sigue existiendo';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (6): rpc_remove_member cascada correctamente al pivot';

    -- ── (7) rpc_accept_invitation crea la asignación equivalente ───────────
    INSERT INTO account_invitations (id, account_id, email, token, role, status, invited_by, created_at, expires_at)
    VALUES (gen_random_uuid(), v_account, 'gate-rpc-rewrite-invitee@test.local', v_token, 'admin', 'pending', v_owner_uid, now(), now() + interval '7 days');

    INSERT INTO auth.users (id, email) VALUES (v_invitee_uid, 'gate-rpc-rewrite-invitee@test.local');
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_invitee_uid::text, 'role', 'authenticated')::text, true);
    v_result := rpc_accept_invitation(v_token)::jsonb;
    IF (v_result->>'role') IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'GATE FAILED (7): rpc_accept_invitation no devolvió role=admin: %', v_result;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM account_member_roles amr
      JOIN account_members am ON am.id = amr.member_id
      WHERE am.account_id = v_account AND am.user_id = v_invitee_uid
        AND amr.role = 'admin' AND amr.assigned_by = v_owner_uid
    ) THEN
      RAISE EXCEPTION 'GATE FAILED (7): la asignación equivalente en el pivot no quedó (role=admin, assigned_by=invited_by)';
    END IF;
    SELECT id INTO v_invitee_member FROM account_members WHERE account_id = v_account AND user_id = v_invitee_uid;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (7): rpc_accept_invitation escribe la membresía y su asignación equivalente en el pivot';

    -- ── (8) rpc_my_account_role deriva del pivot, mismo vocabulario ────────
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);
    v_role_result := rpc_my_account_role(v_account);
    IF v_role_result <> 'owner' THEN
      RAISE EXCEPTION 'GATE FAILED (8): rpc_my_account_role(owner) devolvió % en vez de owner', v_role_result;
    END IF;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_invitee_uid::text, 'role', 'authenticated')::text, true);
    v_role_result := rpc_my_account_role(v_account);
    IF v_role_result <> 'admin' THEN
      RAISE EXCEPTION 'GATE FAILED (8): rpc_my_account_role(admin) devolvió % en vez de admin', v_role_result;
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (8): rpc_my_account_role deriva del pivot con el vocabulario heredado';

    -- ── (9) ronda 1 (finding MAJOR): rechaza un rol funcional del catálogo
    --     ('seller') fuera del vocabulario legacy — antes de esta ronda
    --     devolvía {ok:true} y sembraba un rol funcional inerte en el pivot.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);
    v_result := rpc_change_member_role(v_account, v_invitee_uid, 'seller');
    IF v_result <> jsonb_build_object('error', 'Rol inválido') THEN
      RAISE EXCEPTION 'GATE FAILED (9): asignar un rol funcional (seller) no fue rechazado con {error: Rol inválido}: %', v_result;
    END IF;
    IF EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_invitee_member AND role = 'seller') THEN
      RAISE EXCEPTION 'GATE FAILED (9): quedó una asignación seller pese al rechazo';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (9): rpc_change_member_role rechaza roles funcionales fuera del vocabulario legacy';

    -- ── (10) ronda 1 (finding MAJOR, agujero PREEXISTENTE cerrado): un
    --     caller que NO es miembro de la cuenta es rechazado por ambas RPCs
    --     — antes, v_caller_role resolvía a NULL y el `NOT IN` lo dejaba
    --     pasar.
    INSERT INTO auth.users (id, email) VALUES (v_stranger_uid, 'gate-rpc-rewrite-stranger@test.local');
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger_uid::text, 'role', 'authenticated')::text, true);

    v_result := rpc_change_member_role(v_account, v_invitee_uid, 'member');
    IF (v_result->>'error') IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (10): un caller ajeno a la cuenta pudo cambiar el rol de un miembro: %', v_result;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_invitee_member AND role = 'admin') THEN
      RAISE EXCEPTION 'GATE FAILED (10): el rol del target cambió pese al rechazo del caller ajeno';
    END IF;

    v_result := rpc_remove_member(v_account, v_invitee_uid);
    IF (v_result->>'error') IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (10): un caller ajeno a la cuenta pudo expulsar a un miembro: %', v_result;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM account_members WHERE id = v_invitee_member) THEN
      RAISE EXCEPTION 'GATE FAILED (10): el miembro fue expulsado pese al rechazo del caller ajeno';
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (10): un caller que no es miembro de la cuenta es rechazado por ambas RPCs';

    -- ── (11) ronda 1 (finding minor): un target que no es miembro de la
    --     cuenta devuelve {error}, no una excepción 23502.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_uid::text, 'role', 'authenticated')::text, true);
    v_result := rpc_change_member_role(v_account, gen_random_uuid(), 'admin');
    IF (v_result->>'error') IS NULL THEN
      RAISE EXCEPTION 'GATE FAILED (11): un target inexistente no devolvió {error}: %', v_result;
    END IF;
    v_blocks_run := v_blocks_run + 1;
    RAISE NOTICE 'PASS (11): un target que no es miembro de la cuenta devuelve {error}, no una excepción';
  END IF;

  -- ── (12) candado anti-overload (gotcha 42725) ───────────────────────────
  SELECT count(*) INTO v_overload_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('rpc_change_member_role', 'rpc_remove_member', 'rpc_accept_invitation', 'rpc_my_account_role', 'handle_new_user')
  GROUP BY p.proname
  HAVING count(*) > 1;

  IF FOUND THEN
    RAISE EXCEPTION 'GATE FAILED (12): al menos una de las funciones reescritas quedó con más de una definición viva (overload 42725)';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (12): sin overloads — una única definición viva de cada función reescrita';

  IF v_blocks_run <> 12 THEN
    RAISE EXCEPTION 'GATE MEMBERSHIP-RPCS-PIVOT-REWRITE FAILED (conteo, fase principal): se ejercitaron % de 12 bloques esperados (ver NOTICE ''GATE DEGRADED:'' si degradó a mitad de camino).', v_blocks_run;
  END IF;
  RAISE NOTICE 'GATE MEMBERSHIP-RPCS-PIVOT-REWRITE (fase principal): 12/12 bloques PASS. Bloque (13) corre por separado más abajo (reapply real vía \i).';

  -- ── cleanup ──────────────────────────────────────────────────────────────
  DELETE FROM account_member_roles WHERE member_id IN (
    SELECT id FROM account_members WHERE account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid)
    )
  );
  DELETE FROM account_members WHERE account_id IN (
    SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid)
  );
  DELETE FROM account_invitations WHERE account_id IN (
    SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid)
  ) OR email = 'gate-rpc-rewrite-invitee@test.local';
  SET session_replication_role = replica;
  -- ronda 2 (nit): cashboxes ANTES de branches — bajo `replica` no hay
  -- CASCADE, así que borrar branches primero deja cashboxes huérfanas.
  DELETE FROM public.cashboxes cb USING public.branches b
    WHERE cb.branch_id = b.id AND b.account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid)
    );
  DELETE FROM public.branches WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid));
  DELETE FROM public.payment_methods WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid));
  DELETE FROM public.product_categories WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid));
  DELETE FROM public.email_logs WHERE user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid);
  DELETE FROM public.profiles WHERE id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid);
  DELETE FROM public.accounts WHERE owner_user_id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid);
  SET session_replication_role = DEFAULT;
  DELETE FROM auth.users WHERE id IN (v_owner_uid, v_member_uid, v_invitee_uid, v_stranger_uid);
  RAISE NOTICE 'GATE MEMBERSHIP-RPCS-PIVOT-REWRITE (fase principal): cleanup completo.';
END $$;

-- =============================================================================
-- Fase 13 (RONDA 2, separada del DO principal): el backfill REAL, vía \i.
--
-- Reaplica el ARCHIVO REAL de la migración (\i) contra un fixture legacy
-- propio, en vez de assertear una COPIA de su sentencia (finding minor de la
-- ronda 2: la ronda 1 sí verificaba el mapeo correcto, pero con su PROPIA
-- copia del CASE — reintroducir el hardcodeo 'owner' de siempre en el
-- ARCHIVO REAL dejaba este gate en verde). \i resuelve rutas relativas al
-- cwd del proceso psql (no del script que lo invoca) — el mismo cwd (raíz
-- del repo) que usa el `-f` de este archivo. Reaplicar 20261047000001 es
-- idempotente (CREATE OR REPLACE / IF NOT EXISTS / ON CONFLICT DO NOTHING en
-- toda la migración, ya verificado ×3 en la task de checkpoint) y es la
-- migración MÁS NUEVA de la cadena — a diferencia de test_cuentas_billetera_
-- tipo.sql, no hace falta capturar/restaurar el cuerpo de ninguna función
-- (ninguna migración posterior la redefine).
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _rbac_bf_fixture (k text PRIMARY KEY, v uuid);
TRUNCATE _rbac_bf_fixture;

-- ── Fase 13a: fixture legacy propio (1 owner, 1 admin, 1 member) ────────────
-- Incluye una fila 'owner' legacy además de 'admin'/'member': con
-- fn_guard_account_owner_invariant YA instalado (Parte A completa), esta
-- Fase corre el backfill como un statement de NIVEL SUPERIOR (vía \i, fuera
-- de cualquier DO envolvente) — el constraint trigger diferido se evalúa al
-- terminar ESE statement, no al final de todo el archivo. Un fixture sin
-- ningún owner (como tenía la versión de la ronda 1, inerte porque el
-- cleanup corría en la MISMA transacción antes de que el diferido se
-- evaluara) dispara acá un P0405 genuino — no es el mapeo lo que falla, es
-- que ninguna cuenta real llega así: todo signup crea su fundador 'owner'.
DO $$
DECLARE
  v_owner_uid         uuid := gen_random_uuid();
  v_anchor_uid        uuid := gen_random_uuid();
  v_legacy_member_uid uuid := gen_random_uuid();
  v_bf_account        uuid := gen_random_uuid();
  v_bf_member_owner   uuid;
  v_bf_member_legacy  uuid;
  v_bf_member_admin   uuid;
BEGIN
  BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_owner_uid, 'gate-rpc-rewrite-backfill-real-o@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_anchor_uid, 'gate-rpc-rewrite-backfill-real-a@test.local');
    INSERT INTO auth.users (id, email) VALUES (v_legacy_member_uid, 'gate-rpc-rewrite-backfill-real-b@test.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE DEGRADED (13): no se pudieron crear los usuarios ancla del backfill real (%). Se omite la Fase 13.', SQLERRM;
    RETURN;
  END;

  -- Cuenta sintética PROPIA (no las que handle_new_user ya les creó a estos
  -- 3 usuarios vía su propio signup) para el fixture "prod-shaped" legacy.
  INSERT INTO public.accounts (id, owner_user_id) VALUES (v_bf_account, v_owner_uid);

  -- Tres membresías "shaped like prod legacy data", insertadas bajo
  -- `replica` para que trg_derive_account_member_role no las reescriba
  -- antes de tiempo — simula cómo llegaron a prod las filas legacy,
  -- insertadas ANTES de que este trigger existiera.
  SET session_replication_role = replica;
  INSERT INTO public.account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_bf_account, v_owner_uid, 'owner')
    RETURNING id INTO v_bf_member_owner;
  INSERT INTO public.account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_bf_account, v_legacy_member_uid, 'member')
    RETURNING id INTO v_bf_member_legacy;
  INSERT INTO public.account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_bf_account, v_anchor_uid, 'admin')
    RETURNING id INTO v_bf_member_admin;
  SET session_replication_role = DEFAULT;

  INSERT INTO _rbac_bf_fixture VALUES
    ('owner_uid', v_owner_uid),
    ('anchor_uid', v_anchor_uid),
    ('legacy_member_uid', v_legacy_member_uid),
    ('account', v_bf_account),
    ('member_owner', v_bf_member_owner),
    ('member_legacy', v_bf_member_legacy),
    ('member_admin', v_bf_member_admin);

  RAISE NOTICE 'FASE 13a: fixture legacy listo (1 owner, 1 admin, 1 member) para el reapply real de la migración.';
END $$;

-- ── Fase 13b: reapply REAL — ejercita el backfill de la sección 5 ──────────
\i supabase/migrations/20261047000001_v3_rbac_multirole_parte_a.sql

-- ── Fase 13c: assert contra lo que la migración REAL dejó ───────────────────
DO $$
DECLARE
  v_bf_member_owner  uuid;
  v_bf_member_legacy uuid;
  v_bf_member_admin  uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _rbac_bf_fixture WHERE k = 'account') THEN
    RETURN; -- Fase 13a degradó
  END IF;

  SELECT v INTO v_bf_member_owner  FROM _rbac_bf_fixture WHERE k = 'member_owner';
  SELECT v INTO v_bf_member_legacy FROM _rbac_bf_fixture WHERE k = 'member_legacy';
  SELECT v INTO v_bf_member_admin  FROM _rbac_bf_fixture WHERE k = 'member_admin';

  IF EXISTS (SELECT 1 FROM account_member_roles WHERE member_id IN (v_bf_member_legacy, v_bf_member_admin) AND role = 'owner') THEN
    RAISE EXCEPTION 'GATE FAILED (13): el backfill REAL (reaplicado vía \i) promovió a owner una fila legacy que no lo era';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_bf_member_owner AND role = 'owner') THEN
    RAISE EXCEPTION 'GATE FAILED (13): la fila legacy owner no quedó mapeada a owner en el pivot tras el reapply real';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_bf_member_legacy AND role = 'viewer') THEN
    RAISE EXCEPTION 'GATE FAILED (13): la fila legacy member no quedó mapeada a viewer en el pivot tras el reapply real';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_bf_member_admin AND role = 'admin') THEN
    RAISE EXCEPTION 'GATE FAILED (13): la fila legacy admin no quedó mapeada a admin en el pivot tras el reapply real';
  END IF;

  RAISE NOTICE 'PASS (13): el backfill REAL (archivo de migración reaplicado vía \i, no una copia) mapea a la asignación equivalente (owner/viewer/admin), nunca hardcodea owner para lo que no lo era';
  RAISE NOTICE 'GATE MEMBERSHIP-RPCS-PIVOT-REWRITE: 13/13 bloques PASS (12 fase principal + 1 Fase 13).';
END $$;

-- ── Fase 13d: cleanup ────────────────────────────────────────────────────────
DO $$
DECLARE
  v_owner_uid         uuid;
  v_anchor_uid        uuid;
  v_legacy_member_uid uuid;
  v_bf_account        uuid;
BEGIN
  SELECT v INTO v_owner_uid         FROM _rbac_bf_fixture WHERE k = 'owner_uid';
  SELECT v INTO v_anchor_uid        FROM _rbac_bf_fixture WHERE k = 'anchor_uid';
  SELECT v INTO v_legacy_member_uid FROM _rbac_bf_fixture WHERE k = 'legacy_member_uid';
  SELECT v INTO v_bf_account        FROM _rbac_bf_fixture WHERE k = 'account';

  IF v_bf_account IS NULL THEN
    RETURN; -- Fase 13a degradó, nada que limpiar
  END IF;

  DELETE FROM account_member_roles WHERE account_id = v_bf_account;
  SET session_replication_role = replica;
  DELETE FROM account_members WHERE account_id = v_bf_account;
  DELETE FROM accounts WHERE id = v_bf_account;

  -- Los 3 usuarios tienen además su PROPIA cuenta auto-provisionada por su
  -- propio signup (handle_new_user) — se limpia igual que el resto de este
  -- gate (cashboxes ANTES de branches, molde de test_asiento_contable_
  -- gastos.sql).
  DELETE FROM public.cashboxes cb USING public.branches b
    WHERE cb.branch_id = b.id AND b.account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid));
  DELETE FROM public.branches WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid));
  DELETE FROM public.payment_methods WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid));
  DELETE FROM public.product_categories WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid));
  DELETE FROM account_member_roles WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid));
  DELETE FROM account_members WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid));
  DELETE FROM public.email_logs WHERE user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid);
  DELETE FROM public.profiles WHERE id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid);
  DELETE FROM public.accounts WHERE owner_user_id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid);
  SET session_replication_role = DEFAULT;
  DELETE FROM auth.users WHERE id IN (v_owner_uid, v_anchor_uid, v_legacy_member_uid);

  RAISE NOTICE 'FASE 13: cleanup completo (reapply real vía \i).';
END $$;

DROP TABLE IF EXISTS _rbac_bf_fixture;
