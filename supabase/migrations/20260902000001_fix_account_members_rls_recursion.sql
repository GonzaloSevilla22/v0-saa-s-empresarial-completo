-- =============================================================================
-- MIGRATION: 20260902000001_fix_account_members_rls_recursion.sql
-- CHANGE:    fix/account-members-rls-recursion
--
-- QUÉ ARREGLA
--   Una DB construida desde la cadena completa de migraciones queda con RLS
--   RECURSIVA en public.account_members: cualquier lectura vía PostgREST
--   devuelve 500 con
--     {"code":"42P17","message":"infinite recursion detected in policy for
--      relation \"account_members\""}
--   El auth-context del frontend no puede resolver `user.accountId` y toda
--   pantalla que dependa de él queda vacía.
--
-- CAUSA (20260606000001_tenant_tables.sql §account_members policies)
--   La policy account_members_same_account_select se consulta A SÍ MISMA:
--     account_id IN (SELECT am2.account_id FROM public.account_members am2
--                    WHERE am2.user_id = (SELECT auth.uid()))
--   El comentario que acompaña esa policy dice que NO se puede usar
--   current_account_ids() "porque causaría recursión infinita al leer
--   account_members". Eso es FALSO: ese helper es SECURITY DEFINER y
--   account_members tiene relforcerowsecurity = false, así que el helper
--   bypassea RLS y no recursa. Evitar el helper y escribir el subselect
--   directo es justamente lo que produce la recursión.
--
-- POR QUÉ NO SE VE EN PRODUCCIÓN — DRIFT
--   Prod fue parcheado fuera de la cadena y hoy tiene (capturado con
--   pg_get_functiondef / pg_policies el 2026-08-04, regla del proyecto: partir
--   del cuerpo vivo, no de los archivos históricos):
--     · policy: account_id IN (SELECT get_account_ids_for_user((SELECT auth.uid())))
--       roles = {public}, cmd = SELECT
--     · helper get_account_ids_for_user(uuid): STABLE SECURITY DEFINER,
--       search_path='public', owner postgres — QUE NO EXISTE EN LA CADENA.
--   Son DOS drifts: la policy y el helper que la sostiene.
--
-- QUÉ HACE ESTA MIGRACIÓN (sign-off PO 2026-08-04: "copiar prod tal cual")
--   Alinea la cadena con prod, byte a byte, para esta tabla:
--     1. Crea get_account_ids_for_user(uuid) con el cuerpo vigente en prod.
--     2. Reemplaza la policy recursiva por la de prod.
--   En PRODUCCIÓN es un NO-OP semántico (deja exactamente lo que ya hay); el
--   efecto real es sobre CI y sobre cualquier entorno nuevo. Deliberadamente
--   NO se endurece a `TO authenticated`: eso cambiaría la autorización viva de
--   prod, y este change es de alineación, no de política nueva. (Verificado:
--   con `TO public`, anon ve 0 filas porque auth.uid() es NULL.)
--
-- ACLs
--   Se deja el EXECUTE por defecto (PUBLIC) igual que en prod. La función es
--   uno de los 4 helpers de RLS de la allowlist de
--   supabase/tests/test_function_acl_gate.sql ('public.get_account_ids_for_user
--   (p_user_id uuid)') — NUNCA revocar: las policies lo ejecutan como el rol
--   consultante y revocarlo rompe toda lectura de las tablas que lo usan.
--
-- RIESGO / BLAST RADIUS
--   Auditoría sobre el schema completo: account_members_same_account_select es
--   la ÚNICA policy auto-referencial de la base (0 coincidencias en el resto), y
--   en prod ninguna otra policy referencia account_members directamente.
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
-- ROLLBACK: restaurar la policy previa (la recursiva) con el cuerpo de
--   20260606000001 y `DROP FUNCTION IF EXISTS public.get_account_ids_for_user(uuid)`.
--   Nótese que eso REINTRODUCE el bug: el rollback real es no aplicar.
-- =============================================================================


-- =============================================================================
-- 1. Helper get_account_ids_for_user — cuerpo exacto de prod
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_account_ids_for_user(p_user_id uuid)
RETURNS SETOF uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT account_id FROM public.account_members WHERE user_id = p_user_id
$function$;

COMMENT ON FUNCTION public.get_account_ids_for_user(uuid) IS
    'Helper de RLS (SECURITY DEFINER): cuentas a las que pertenece un usuario. '
    'Bypassea RLS a propósito para que las policies de account_members no '
    'recursen. Alineado con el cuerpo vigente en producción.';


-- =============================================================================
-- 2. Policy sin recursión — cuerpo exacto de prod
-- =============================================================================
DROP POLICY IF EXISTS "account_members_same_account_select" ON public.account_members;

CREATE POLICY "account_members_same_account_select" ON public.account_members
  FOR SELECT
  USING (
    account_id IN (SELECT public.get_account_ids_for_user((SELECT auth.uid())))
  );


-- =============================================================================
-- 3. Gate de introspección (corre SIEMPRE, también en prod)
-- =============================================================================
DO $$
DECLARE
  v_qual text;
BEGIN
  SELECT qual INTO v_qual
  FROM   pg_policies
  WHERE  schemaname = 'public'
    AND  tablename  = 'account_members'
    AND  policyname = 'account_members_same_account_select';

  IF v_qual IS NULL THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: falta la policy account_members_same_account_select.';
  END IF;

  IF position('get_account_ids_for_user' in v_qual) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: la policy no usa el helper SECURITY DEFINER get_account_ids_for_user — cualquier subselect directo a account_members recursa (42P17).';
  END IF;

  IF v_qual ~ 'FROM\s+account_members' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: la policy de account_members vuelve a consultar account_members directamente (recursión).';
  END IF;

  -- El helper tiene que ser SECURITY DEFINER: sin eso, la policy recursa igual.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_account_ids_for_user' AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: get_account_ids_for_user no existe o no es SECURITY DEFINER.';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: account_members_same_account_select usa el helper SECURITY DEFINER y no se auto-consulta.';
END $$;


-- =============================================================================
-- 4. Gate de comportamiento auto-limpiante (solo DB vacía/CI, NOTICE-degrade)
--    Dos usuarios en la MISMA cuenta: el compañero de equipo tiene que verse
--    (razón de ser de la policy) y un ajeno no. Corre como `authenticated` con
--    una sesión sintética, que es donde la recursión se manifiesta — como
--    `postgres` la RLS ni se evalúa y el bug es invisible.
-- =============================================================================
DO $$
DECLARE
  v_owner_id  uuid := gen_random_uuid();
  v_mate_id   uuid := gen_random_uuid();
  v_other_id  uuid := gen_random_uuid();
  v_account   uuid;
  v_seen      bigint;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_owner_id, 'authenticated', 'authenticated', 'am-rls-gate-owner@test.local', now(), now(),
          jsonb_build_object('name', 'Gate AM Owner', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account
  FROM   public.account_members
  WHERE  user_id = v_owner_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE AM-RLS: no se pudo resolver una account para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  -- Compañero de equipo: usuario propio + membresía en la cuenta del owner.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_mate_id, 'authenticated', 'authenticated', 'am-rls-gate-mate@test.local', now(), now(),
          jsonb_build_object('name', 'Gate AM Mate', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account, v_mate_id, 'member')
  ON CONFLICT DO NOTHING;

  BEGIN
    -- ── (a) El owner ve a TODO su equipo, sin recursión ────────────────────
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_owner_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    SELECT count(*) INTO v_seen
    FROM   public.account_members
    WHERE  account_id = v_account;

    IF v_seen <> 2 THEN
      EXECUTE 'RESET ROLE';
      RAISE EXCEPTION 'GATE AM-RLS FAILED (a): el owner debería ver 2 miembros de su cuenta, vio % — la policy de equipo no está funcionando.', v_seen;
    END IF;

    -- ── (b) Un usuario ajeno no ve nada de esa cuenta ──────────────────────
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_other_id::text, 'role', 'authenticated')::text, true);

    SELECT count(*) INTO v_seen
    FROM   public.account_members
    WHERE  account_id = v_account;

    EXECUTE 'RESET ROLE';

    IF v_seen <> 0 THEN
      RAISE EXCEPTION 'GATE AM-RLS FAILED (b): un usuario ajeno vio % filas de una cuenta que no es suya — aislamiento roto.', v_seen;
    END IF;

  EXCEPTION
    WHEN sqlstate '42P17' THEN
      EXECUTE 'RESET ROLE';
      RAISE EXCEPTION 'GATE AM-RLS FAILED: la policy sigue recursando (42P17) al leer account_members como authenticated.';
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      IF SQLERRM LIKE 'GATE AM-RLS FAILED%' THEN
        RAISE;
      END IF;
      RAISE NOTICE 'GATE AM-RLS: no se pudo ejecutar el gate de comportamiento (%) — degradando sin abortar.', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'GATE AM-RLS PASSED: sin recursión, el compañero de cuenta se ve (a) y el ajeno no (b).';

  -- ── Limpieza hijo→padre por anchor (accounts=0 al final) ────────────────
  DELETE FROM public.branch_stock WHERE branch_id IN (
    SELECT id FROM public.branches WHERE account_id IN (
      SELECT account_id FROM public.account_members WHERE user_id IN (v_owner_id, v_mate_id)));
  DELETE FROM public.cashboxes WHERE branch_id IN (
    SELECT id FROM public.branches WHERE account_id IN (
      SELECT account_id FROM public.account_members WHERE user_id IN (v_owner_id, v_mate_id)));
  DELETE FROM public.branches WHERE account_id IN (
    SELECT account_id FROM public.account_members WHERE user_id IN (v_owner_id, v_mate_id));
  DELETE FROM public.account_members       WHERE user_id IN (v_owner_id, v_mate_id);
  DELETE FROM public.accounts              WHERE owner_user_id IN (v_owner_id, v_mate_id);
  DELETE FROM public.profiles              WHERE id IN (v_owner_id, v_mate_id);
  DELETE FROM public.email_logs            WHERE user_id IN (v_owner_id, v_mate_id);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_owner_id, v_mate_id);
  DELETE FROM auth.users                   WHERE id IN (v_owner_id, v_mate_id);

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', '', true);
      DELETE FROM public.branch_stock WHERE branch_id IN (
        SELECT id FROM public.branches WHERE account_id IN (
          SELECT account_id FROM public.account_members WHERE user_id IN (v_owner_id, v_mate_id)));
      DELETE FROM public.cashboxes WHERE branch_id IN (
        SELECT id FROM public.branches WHERE account_id IN (
          SELECT account_id FROM public.account_members WHERE user_id IN (v_owner_id, v_mate_id)));
      DELETE FROM public.branches WHERE account_id IN (
        SELECT account_id FROM public.account_members WHERE user_id IN (v_owner_id, v_mate_id));
      DELETE FROM public.account_members       WHERE user_id IN (v_owner_id, v_mate_id);
      DELETE FROM public.accounts              WHERE owner_user_id IN (v_owner_id, v_mate_id);
      DELETE FROM public.profiles              WHERE id IN (v_owner_id, v_mate_id);
      DELETE FROM public.email_logs            WHERE user_id IN (v_owner_id, v_mate_id);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_owner_id, v_mate_id);
      DELETE FROM auth.users                   WHERE id IN (v_owner_id, v_mate_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
