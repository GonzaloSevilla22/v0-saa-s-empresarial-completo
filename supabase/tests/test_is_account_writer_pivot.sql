-- =============================================================================
-- GATE: test_is_account_writer_pivot.sql
-- CHANGE: v3-rbac-multirole Parte B, grupo 8 (D11) — is_account_writer sobre
-- el pivot.
--
-- is_account_writer conserva su FIRMA (p_account_id uuid) y sus 48 policies
-- sobre 20 tablas; sólo cambia el CUERPO, para resolver EXISTS(rol activo del
-- usuario en la cuenta cuyo is_writer del catálogo sea true) en vez de
-- `role IN ('owner','admin')` contra la columna espejo. current_account_ids()
-- NO se toca (D11) — no forma parte de este gate porque resuelve tenencia,
-- no rol.
--
--   (1) estructura: la firma no cambió y las 48 policies sobre 20 tablas
--       siguen existiendo (8.2) — no depende de datos, corre siempre.
--   (2) un miembro con un rol que CONCEDE escritura (is_writer=true, p.ej.
--       'seller') -> is_account_writer = true (8.1).
--   (3) un miembro SÓLO 'viewer' (is_writer=false) -> false (8.1, D12: la
--       separación fina la hace el backend, pero viewer/no-viewer SÍ debe
--       distinguir la RLS).
--   (4) un rol VENCIDO (expires_at en el pasado) no cuenta -> false, aunque
--       la fila exista (8.1/8.5 — D4, "rol activo").
--   (5) TRIANGULATE (8.5): un miembro con 2 roles, uno vencido (viewer) y
--       otro vigente (seller, is_writer) -> true (el vigente alcanza).
--   (6) TRIANGULATE (8.5): un miembro de OTRA cuenta -> false (no hay fila
--       del pivot para esa cuenta).
--   (7) fail-closed (D11 del brief del apply): sin NINGUNA fila en el pivot
--       para ese member_id -> false (nunca se concede por ausencia de dato).
--
-- Degrade-don't-fail (mismo criterio que el resto de los gates de esta
-- familia): si no hay ningún auth.users para anclar el fixture, se documenta
-- y no se aborta el gate completo por esto.
-- =============================================================================

-- ── (1) Estructura: firma sin cambios + 48 policies / 20 tablas ─────────────
DO $$
DECLARE
  v_nargs   int;
  v_n_pol   int;
  v_n_tab   int;
BEGIN
  SELECT pronargs INTO v_nargs
  FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'is_account_writer';

  IF v_nargs <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1): is_account_writer cambió de aridad (esperaba 1 arg, tiene %)', v_nargs;
  END IF;

  SELECT count(*), count(DISTINCT tablename) INTO v_n_pol, v_n_tab
  FROM pg_policies
  WHERE schemaname = 'public'
    AND (qual ILIKE '%is_account_writer%' OR with_check ILIKE '%is_account_writer%');

  IF v_n_pol <> 48 OR v_n_tab <> 20 THEN
    RAISE EXCEPTION 'GATE FAILED (1): se esperaban 48 policies sobre 20 tablas invocando is_account_writer, hay % sobre %', v_n_pol, v_n_tab;
  END IF;

  RAISE NOTICE 'PASS (1): is_account_writer conserva su firma (1 arg) y las 48 policies sobre 20 tablas.';
END $$;


-- ── (2)-(7) comportamiento sobre el pivot, con auth.uid() sintético ─────────
DO $$
DECLARE
  v_anchor_user  uuid;
  v_account_a    uuid := gen_random_uuid();
  v_account_b    uuid := gen_random_uuid();
  v_member_a     uuid;
  v_member_b     uuid;
  v_result       boolean;
  v_expected_blocks int := 6;
  v_blocks_run   int := 0;
BEGIN
  SELECT id INTO v_anchor_user FROM auth.users LIMIT 1;
  IF v_anchor_user IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: no hay ningún auth.users para anclar el fixture — se omite el resto del gate.';
    RETURN;
  END IF;

  INSERT INTO public.accounts (id, owner_user_id) VALUES (v_account_a, v_anchor_user);
  INSERT INTO public.accounts (id, owner_user_id) VALUES (v_account_b, v_anchor_user);

  INSERT INTO public.account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_account_a, v_anchor_user, 'member')
    ON CONFLICT (account_id, user_id) DO UPDATE SET role = EXCLUDED.role
    RETURNING id INTO v_member_a;

  -- member_b: mismo user, otra cuenta -- account_members no tiene unique
  -- (account_id,user_id) que lo impida entre CUENTAS distintas.
  INSERT INTO public.account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_account_b, v_anchor_user, 'member')
    RETURNING id INTO v_member_b;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_anchor_user::text, 'role', 'authenticated')::text, true);

  -- (7) fail-closed: sin ninguna fila en el pivot para member_a todavía
  -- (el backfill de Parte A ya insertó 'member'->'viewer' para member_a en
  -- la línea de arriba vía el trigger de espejo/backfill? NO: el backfill
  -- corrió UNA vez en la migración de Parte A, sobre las filas que existían
  -- en ESE momento -- member_a se creó recién ahora, en este gate, así que
  -- NO tiene ninguna fila en el pivot todavía).
  SELECT public.is_account_writer(v_account_a) INTO v_result;
  IF v_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE FAILED (7): sin ninguna asignación en el pivot, is_account_writer debe ser false (fail-closed), dio %', v_result;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (7): fail-closed -- sin fila en el pivot, is_account_writer=false.';

  -- (2) rol que concede escritura (seller, is_writer=true)
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_a, 'seller', now());

  SELECT public.is_account_writer(v_account_a) INTO v_result;
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE FAILED (2): miembro con rol seller (is_writer=true) debe poder escribir, dio %', v_result;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2): rol seller (is_writer=true) concede escritura.';

  DELETE FROM public.account_member_roles WHERE member_id = v_member_a;

  -- (3) sólo viewer (is_writer=false)
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_a, 'viewer', now());

  SELECT public.is_account_writer(v_account_a) INTO v_result;
  IF v_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE FAILED (3): miembro SÓLO viewer (is_writer=false) NO debe poder escribir, dio %', v_result;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3): rol viewer (is_writer=false) NO concede escritura.';

  DELETE FROM public.account_member_roles WHERE member_id = v_member_a;

  -- (4) rol vencido no cuenta
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at, expires_at)
  VALUES (v_account_a, v_member_a, 'seller', now() - INTERVAL '10 days', now() - INTERVAL '1 day');

  SELECT public.is_account_writer(v_account_a) INTO v_result;
  IF v_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE FAILED (4): un rol VENCIDO no debe conceder escritura, dio %', v_result;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (4): rol vencido no concede escritura (D4).';

  -- (5) TRIANGULATE: 2 asignaciones simultáneas -- la VENCIDA de (4)
  -- ('seller', sigue en la tabla, no se borró) + una SEGUNDA, VIGENTE, con
  -- un rol DISTINTO que también es is_writer=true ('stock' -- no puede ser
  -- 'seller' de nuevo: UNIQUE(member_id,role) del pivot).
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_a, 'stock', now());

  SELECT public.is_account_writer(v_account_a) INTO v_result;
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE FAILED (5): con un rol vigente (stock) entre dos asignaciones (la otra, seller, vencida), debe poder escribir, dio %', v_result;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (5): TRIANGULATE -- un rol vigente entre varios (uno vencido) alcanza.';

  DELETE FROM public.account_member_roles WHERE member_id = v_member_a;

  -- (6) TRIANGULATE: miembro de OTRA cuenta -- v_member_b tiene rol seller en
  -- account_b, pero se pregunta por account_a.
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_b, v_member_b, 'seller', now());

  SELECT public.is_account_writer(v_account_a) INTO v_result;
  IF v_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE FAILED (6): un rol de OTRA cuenta no debe conceder escritura sobre account_a, dio %', v_result;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (6): TRIANGULATE -- miembro de otra cuenta no escribe acá.';

  -- Cleanup
  DELETE FROM public.account_member_roles WHERE member_id IN (v_member_a, v_member_b);
  DELETE FROM public.account_members WHERE id IN (v_member_a, v_member_b);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;

  IF v_blocks_run <> v_expected_blocks THEN
    RAISE EXCEPTION 'GATE IS-ACCOUNT-WRITER-PIVOT FAILED (conteo): se ejercitaron % de % bloques esperados.', v_blocks_run, v_expected_blocks;
  END IF;

  RAISE NOTICE 'GATE IS-ACCOUNT-WRITER-PIVOT: %/% bloques PASS.', v_blocks_run, v_expected_blocks;
EXCEPTION
  WHEN OTHERS THEN
    SET session_replication_role = DEFAULT;
    DELETE FROM public.account_member_roles WHERE member_id IN (v_member_a, v_member_b);
    DELETE FROM public.account_members WHERE id IN (v_member_a, v_member_b);
    SET session_replication_role = replica;
    DELETE FROM public.accounts WHERE id IN (v_account_a, v_account_b);
    SET session_replication_role = DEFAULT;
    RAISE;
END $$;
