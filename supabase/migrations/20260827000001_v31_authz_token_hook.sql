-- =============================================================================
-- MIGRATION: 20260827000001_v31_authz_token_hook.sql
-- CHANGE:    v31-authz-token-hook (cluster de autorización, sign-off PO 2026-07-31)
-- Design ref: openspec/changes/v31-authz-token-hook/design.md
--
-- Implementa (design.md):
--   D1  El hook pasa a emitir TRES claims bajo app_metadata, con espacios de
--       nombres separados: `role` (plataforma, profiles.role — SIN cambio
--       semántico, los 56 require_role(["user","admin"]) + require_platform_admin
--       lo siguen leyendo igual), `account_role` (tenant, account_members.role
--       de la cuenta activa — claim NUEVO), `plan` (plan efectivo — claim NUEVO).
--       `role` NUNCA transporta el rol de tenant (evita el 403 masivo descartado
--       en D1 del design).
--   D3  El claim `plan` NO reimplementa la regla del plan efectivo: llama a
--       public.get_effective_plan(account_id) (billing-pro-trial, SECURITY
--       DEFINER) — por eso alcanza con GRANT EXECUTE, sin GRANT SELECT/policy
--       sobre accounts.
--   D4  Cuenta activa resuelta con el MISMO criterio determinístico que
--       backend/core/deps.py::get_account_id tras este change: ORDER BY
--       created_at, id LIMIT 1 (la membresía más antigua, desempatada por PK).
--   D5  supabase_auth_admin no tenía NINGÚN grant sobre account_members
--       (verificado en prod, task 1.5) — se agrega GRANT SELECT + policy
--       auth_admin_can_read_memberships, mismo patrón que
--       auth_admin_can_read_roles sobre profiles (20260800000004). El
--       EXCEPTION WHEN OTHERS se conserva (nunca romper el login) pero ahora
--       loguea con RAISE WARNING + SQLSTATE — un permiso faltante deja rastro
--       en los logs de Postgres en vez de manifestarse como claims ausentes
--       sin explicación.
--   D7  Esta migración deja la función REDEFINIDA Y DORMIDA. El toggle de
--       activación vive en Supabase Dashboard → Authentication → Hooks (Beta)
--       → Customize Access Token, fuera del repo — activarlo es tarea MANUAL
--       del PO (grupo 8 de tasks.md). Nada cambia en producción con este push.
--
-- DEPENDENCIA DURA DE SECUENCIA (D3): requiere que billing-pro-trial esté
--   mergeado y aplicado ANTES (public.get_effective_plan debe existir). El
--   preflight de la Sección 1 aborta el `db push` con un mensaje explícito si
--   no es así, en vez de dejar que el EXCEPTION WHEN OTHERS del hook trague el
--   error en silencio (D5, riesgo "el hook falla en silencio por permisos
--   faltantes y nadie se entera").
--
-- IDEMPOTENCIA: CREATE OR REPLACE sobre la MISMA firma `(jsonb)` — no aplica
--   la lección 42725/C3 (el overload duplicado ocurre al *agregar* un
--   parámetro; acá la firma no cambia, verificado en el gate (a) de abajo).
--   GRANT/policy con guardas IF NOT EXISTS. El pipeline de este proyecto
--   aplica las migraciones DOS VECES por diseño (integración GitHub + Actions
--   db push) — todo bloque de este archivo es re-aplicable sin efecto
--   acumulativo.
--
-- ACL (advisors 0028/0029, gate supabase/tests/test_function_acl_gate.sql):
--   este archivo REDEFINE custom_access_token_hook (CREATE OR REPLACE) —
--   una redefinición resetea los ACLs de la función al default (EXECUTE a
--   PUBLIC, heredado por anon/authenticated), aunque los del ORIGINAL
--   (20260800000004) ya fueran correctos. Por eso la Sección 1 RE-APLICA
--   REVOKE ALL ... FROM PUBLIC, anon, authenticated + GRANT EXECUTE ... TO
--   supabase_auth_admin en el MISMO archivo, inmediatamente después del
--   CREATE OR REPLACE. La función es STABLE (no SECURITY DEFINER) — el gate
--   de ACLs solo audita funciones prosecdef=true, así que esta función no
--   entra en su allowlist ni la necesita; el REVOKE/GRANT es defensa en
--   profundidad igual (nadie debería poder invocar el hook vía PostgREST).
--   get_effective_plan NO se redefine acá (sigue viva con sus grants de
--   billing-pro-trial) — solo se restata su GRANT EXECUTE (idempotente, no
--   resetea nada porque no es una redefinición).
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration — desincroniza el historial, ver CLAUDE.md).
--
-- GOVERNANCE: CRÍTICO — redefine la función que emite claims de autorización
--   para 34 usuarios reales. La función queda dormida hasta la activación
--   MANUAL del PO en el Dashboard (D7, fuera de esta migración).
--
-- ROLLBACK (sin migración destructiva — D7):
--   1) Si el hook llegó a activarse: desactivar el toggle en el Dashboard
--      (Authentication → Hooks (Beta)) — restituye el comportamiento previo,
--      sin pérdida de datos ni cierre forzado de sesiones.
--   2) Si además hiciera falta revertir el código de esta migración:
--        DROP POLICY IF EXISTS "auth_admin_can_read_memberships" ON public.account_members;
--        REVOKE SELECT ON TABLE public.account_members FROM supabase_auth_admin;
--        -- restaurar custom_access_token_hook a la definición de
--        -- 20260800000004_auth_jwt_role_hook.sql (CREATE OR REPLACE, misma firma).
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT count(*) FROM pg_proc WHERE proname='custom_access_token_hook';        -- 1
--   SELECT proconfig FROM pg_proc WHERE proname='custom_access_token_hook';       -- {search_path=public,pg_temp}
--   SELECT has_table_privilege('supabase_auth_admin','public.account_members','SELECT'); -- true
--   SELECT has_function_privilege('supabase_auth_admin','public.get_effective_plan(uuid)','EXECUTE'); -- true
--   SELECT public.custom_access_token_hook(jsonb_build_object(
--     'user_id', (SELECT id FROM auth.users LIMIT 1), 'claims', '{}'::jsonb));
--   -- Esperado: claims.app_metadata contiene role / account_role / plan.
-- =============================================================================


-- =============================================================================
-- 0. PREFLIGHT — dependencia dura de secuencia (D3, task 1.6/3.4)
-- =============================================================================
DO $preflight$
BEGIN
  IF to_regprocedure('public.get_effective_plan(uuid)') IS NULL THEN
    RAISE EXCEPTION 'v31-authz-token-hook: DEPENDENCIA FALTANTE — public.get_effective_plan(uuid) '
      'no existe. Este change requiere billing-pro-trial mergeado y aplicado ANTES '
      '(design.md D3). Abortando el db push antes de redefinir '
      'custom_access_token_hook: si siguiera, el EXCEPTION WHEN OTHERS del hook '
      'tragaría el error en silencio y el claim `plan` saldría siempre ausente '
      'sin ningún rastro (D5).';
  END IF;
END $preflight$;


-- =============================================================================
-- 1. Redefinición del hook (D1, D3, D4, D5) — misma firma (jsonb)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claims       jsonb := COALESCE(event -> 'claims', '{}'::jsonb);
  v_user_id      uuid  := (event ->> 'user_id')::uuid;
  v_role         text;
  v_account_id   uuid;
  v_account_role text;
  v_plan         text;
  v_app_metadata jsonb;
BEGIN
  -- Rol de PLATAFORMA (D1) — sin cambio semántico respecto de 20260800000004.
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = v_user_id;

  -- Rol de TENANT (D1) + cuenta activa determinística (D4): la membresía más
  -- antigua, desempatada por PK — MISMO criterio que
  -- backend/core/deps.py::get_account_id tras este change.
  SELECT account_id, role INTO v_account_id, v_account_role
  FROM public.account_members
  WHERE user_id = v_user_id
  ORDER BY created_at, id
  LIMIT 1;

  -- Plan EFECTIVO (D3) — delegado a la definición normativa única. Sin cuenta
  -- activa no hay plan que emitir (no se inventa un default acá).
  IF v_account_id IS NOT NULL THEN
    v_plan := public.get_effective_plan(v_account_id);
  END IF;

  -- Merge aditivo sobre app_metadata existente: preserva otras claves que
  -- Supabase ya haya puesto (p.ej. provider), y cada claim nuevo se agrega
  -- SOLO si se resolvió — un valor NULL no pisa nada.
  v_app_metadata := COALESCE(v_claims -> 'app_metadata', '{}'::jsonb);

  IF v_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('role', v_role);
  END IF;

  IF v_account_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_role', v_account_role);
  END IF;

  IF v_plan IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('plan', v_plan);
  END IF;

  -- Solo tocar `claims.app_metadata` si hay algo nuevo que aportar o si YA
  -- existía (para no fabricar una clave `app_metadata: {}` en un evento que
  -- nunca la tuvo — un usuario sin profile ni membresía debe devolver los
  -- claims EXACTAMENTE como llegaron, sin ninguna clave nueva).
  IF v_app_metadata <> '{}'::jsonb OR v_claims ? 'app_metadata' THEN
    v_claims := jsonb_set(v_claims, '{app_metadata}', v_app_metadata, true);
  END IF;

  RETURN jsonb_build_object('claims', v_claims);
EXCEPTION
  WHEN OTHERS THEN
    -- Nunca romper la emisión del token: ante cualquier error, claims
    -- intactos. A diferencia de 20260800000004, esto DEJA RASTRO (D5): un
    -- permiso faltante o un cambio de esquema queda en los logs de Postgres
    -- en vez de manifestarse como claims ausentes sin explicación.
    RAISE WARNING 'custom_access_token_hook degradado (SQLSTATE=%): %', SQLSTATE, SQLERRM;
    RETURN jsonb_build_object('claims', COALESCE(event -> 'claims', '{}'::jsonb));
END;
$$;

-- ACL: una redefinición (CREATE OR REPLACE) resetea los privilegios al
-- default de Postgres para funciones (EXECUTE a PUBLIC) — hay que
-- RE-APLICAR el REVOKE/GRANT del original (20260800000004) en este mismo
-- archivo, o anon/authenticated heredarían EXECUTE de PUBLIC (advisors
-- 0028/0029, gate supabase/tests/test_function_acl_gate.sql).
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'v31-authz-token-hook (D1/D3/D4/D5): emite TRES claims bajo app_metadata — '
  '`role` (plataforma, profiles.role, SIN cambio semántico — 56 call sites de '
  'require_role(["user","admin"]) + require_platform_admin dependen de esto '
  'literalmente), `account_role` (tenant, account_members.role de la cuenta '
  'activa) y `plan` (plan efectivo vía get_effective_plan, billing-pro-trial — '
  'NO reimplementado acá). Cuenta activa: ORDER BY created_at, id LIMIT 1, '
  'mismo criterio que backend/core/deps.py::get_account_id. DORMIDO hasta la '
  'activación MANUAL del PO en Supabase Dashboard → Authentication → Hooks '
  '(Beta) — esta migración NO activa nada. STABLE (no DEFINER): corre como '
  'supabase_auth_admin, que necesita GRANT SELECT explícito sobre cada tabla '
  'que el hook lee (profiles, account_members) y GRANT EXECUTE sobre '
  'get_effective_plan (SECURITY DEFINER, no necesita SELECT sobre accounts). '
  'EXCEPTION WHEN OTHERS con RAISE WARNING(SQLSTATE) — nunca rompe el login, '
  'pero ya no degrada en silencio.';


-- =============================================================================
-- 2. Permisos nuevos para supabase_auth_admin (D5)
-- =============================================================================

-- 2.1 — account_members: GRANT SELECT + policy (patrón idéntico al de
--       profiles en 20260800000004_auth_jwt_role_hook.sql).
GRANT SELECT ON TABLE public.account_members TO supabase_auth_admin;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'account_members'
      AND policyname = 'auth_admin_can_read_memberships'
  ) THEN
    CREATE POLICY "auth_admin_can_read_memberships" ON public.account_members
      AS PERMISSIVE FOR SELECT TO supabase_auth_admin
      USING (true);
  END IF;
END $$;

-- 2.2 — get_effective_plan: restated por self-containment (ya otorgado por
--       billing-pro-trial/20260817000001; SECURITY DEFINER, no requiere
--       GRANT SELECT/policy sobre accounts — D3).
GRANT EXECUTE ON FUNCTION public.get_effective_plan(uuid) TO supabase_auth_admin;


-- =============================================================================
-- 3. GATES SQL (RED→GREEN→TRIANGULATE) — patrón v3-notifications-realtime /
--    billing-pro-trial. Estructurales: SIEMPRE (prod y CI, vía KPI_Validation
--    workflow con `supabase start`). Comportamiento: SOLO si public.accounts
--    está vacía (CI) — anchor sintético vía auth.users (handle_new_user
--    provisiona accounts + account_members + branch/caja), limpieza
--    best-effort. NOTA DE ENTORNO: este archivo se escribió sin Docker/
--    `supabase db reset` disponible en el sandbox del agente (verificado:
--    Docker Desktop no responde) — los gates de comportamiento se ejercitan
--    por primera vez cuando KPI_Validation corre en GitHub Actions sobre el
--    PR (Docker sí disponible ahí) y el pipeline aplica esta migración.
-- =============================================================================
DO $gate$
DECLARE
  v_count          int;
  v_bool           boolean;
  v_claims_out     jsonb;
  v_run_behavioral boolean := false;

  -- estructurales
  v_gate_a boolean := false;  -- 1 sola definición, STABLE, search_path fijo
  v_gate_b boolean := false;  -- GRANT SELECT + policy sobre account_members
  v_gate_c boolean := false;  -- GRANT EXECUTE sobre get_effective_plan

  -- comportamiento (solo DB vacía)
  v_user1        uuid := gen_random_uuid();
  v_user2        uuid := gen_random_uuid();
  v_account1     uuid;
  v_account2     uuid;
  v_role1        text;
  v_expected_acc uuid;
  v_expected_role text;
  v_expected_plan text;

  v_gate_d boolean := false;  -- (2.2/2.4a) usuario sin membresía: role sí, account_role no, sin excepción
  v_gate_e boolean := false;  -- (2.4b) user_id inexistente: claims intactos, sin excepción
  v_gate_f boolean := false;  -- (2.1/2.2) claims completos para cuenta nueva: role + account_role + plan
  v_gate_g boolean := false;  -- (3.3) plan refleja get_effective_plan (trial vigente)
  v_gate_h boolean := false;  -- (3.3) plan refleja get_effective_plan (billing_plan, sin trial)
  v_gate_i boolean := false;  -- (3.3) plan refleja get_effective_plan (exenta -> pro)
  v_gate_j boolean := false;  -- (4.1/4.3/4.4) determinismo de cuenta activa bajo multi-membresía, ambos órdenes
  v_gate_k boolean := false;  -- (2.3) sin GRANT: degrada TODO el app_metadata; con GRANT: vuelve a andar
BEGIN

  -- ── (a) 1 sola definición + STABLE + search_path fijo ──────────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_proc WHERE proname = 'custom_access_token_hook' AND pronamespace = 'public'::regnamespace;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaba 1 definición de custom_access_token_hook, hay %', v_count;
  END IF;

  SELECT provolatile = 's' INTO v_bool
  FROM pg_proc WHERE proname = 'custom_access_token_hook' AND pronamespace = 'public'::regnamespace;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (a) FAILED: custom_access_token_hook debe ser STABLE';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc, unnest(proconfig) cfg
    WHERE proname = 'custom_access_token_hook' AND pronamespace = 'public'::regnamespace
      AND cfg LIKE 'search_path=%'
  ) INTO v_bool;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (a) FAILED: custom_access_token_hook sin search_path fijo (advisor function_search_path_mutable)';
  END IF;

  -- ACL (advisors 0028/0029): anon/authenticated NUNCA deben poder invocar
  -- el hook vía PostgREST — ver nota de ACL en la cabecera de este archivo.
  IF has_function_privilege('anon', 'public.custom_access_token_hook(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.custom_access_token_hook(jsonb)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE (a) FAILED: custom_access_token_hook ejecutable por anon/authenticated (¿REVOKE no re-aplicado tras el CREATE OR REPLACE?)';
  END IF;
  v_gate_a := true;

  -- ── (b) account_members: GRANT SELECT + policy ──────────────────────────
  IF NOT has_table_privilege('supabase_auth_admin', 'public.account_members', 'SELECT') THEN
    RAISE EXCEPTION 'GATE (b) FAILED: supabase_auth_admin sin SELECT sobre account_members';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'account_members'
      AND policyname = 'auth_admin_can_read_memberships'
  ) INTO v_bool;
  IF NOT v_bool THEN
    RAISE EXCEPTION 'GATE (b) FAILED: falta la policy auth_admin_can_read_memberships';
  END IF;
  v_gate_b := true;

  -- ── (c) get_effective_plan: EXECUTE para supabase_auth_admin ────────────
  IF NOT has_function_privilege('supabase_auth_admin', 'public.get_effective_plan(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (c) FAILED: supabase_auth_admin sin EXECUTE sobre get_effective_plan';
  END IF;
  v_gate_c := true;

  -- ══════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- ── Anchor 1: usuario nuevo -> profile + account + membership owner ──
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_user1, 'authenticated', 'authenticated',
              'v31-authz-hook-gate-1@test.local', now(), now(),
              jsonb_build_object('name', 'Gate Uno', 'phone', '', 'locality', '', 'province', ''));

      SELECT account_id, role INTO v_account1, v_role1
      FROM public.account_members WHERE user_id = v_user1;

      -- ── (f) claims completos: role + account_role + plan ────────────────
      v_claims_out := public.custom_access_token_hook(jsonb_build_object(
        'user_id', v_user1, 'claims', jsonb_build_object('app_metadata', jsonb_build_object('provider', 'email'))
      ));

      IF (v_claims_out #>> '{claims,app_metadata,role}') IS NOT NULL
         AND (v_claims_out #>> '{claims,app_metadata,account_role}') = v_role1
         AND (v_claims_out #>> '{claims,app_metadata,plan}') = public.get_effective_plan(v_account1)
         AND (v_claims_out #>> '{claims,app_metadata,provider}') = 'email'
      THEN
        v_gate_f := true;
      ELSE
        RAISE EXCEPTION 'GATE (f) FAILED: claims incompletos o provider preexistente perdido: %', v_claims_out;
      END IF;

      -- ── (d) usuario sin membresía: role sí, account_role no, sin excepción
      DELETE FROM public.account_members WHERE user_id = v_user1;

      v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));
      IF (v_claims_out #>> '{claims,app_metadata,role}') IS NOT NULL
         AND (v_claims_out #> '{claims,app_metadata,account_role}') IS NULL
         AND (v_claims_out #> '{claims,app_metadata,plan}') IS NULL
      THEN
        v_gate_d := true;
      ELSE
        RAISE EXCEPTION 'GATE (d) FAILED: usuario sin membresía produjo claims inesperados: %', v_claims_out;
      END IF;

      -- ── (e) user_id inexistente: claims intactos, sin excepción ──────────
      v_claims_out := public.custom_access_token_hook(jsonb_build_object(
        'user_id', gen_random_uuid(), 'claims', jsonb_build_object('sub', 'irrelevant')
      ));
      IF v_claims_out = jsonb_build_object('claims', jsonb_build_object('sub', 'irrelevant')) THEN
        v_gate_e := true;
      ELSE
        RAISE EXCEPTION 'GATE (e) FAILED: user_id inexistente no devolvió los claims intactos: %', v_claims_out;
      END IF;

      -- ── Restaurar membership de user1 para los gates siguientes ──────────
      INSERT INTO public.account_members (id, account_id, user_id, role, created_at)
      VALUES (gen_random_uuid(), v_account1, v_user1, v_role1, now());

      -- ── (g)/(h)/(i) el claim `plan` refleja get_effective_plan (D3) ─────
      -- No reimplementa la regla (billing-pro-trial ya la exhaustivamente
      -- gatea) — solo prueba que el hook la INVOCA y la PROPAGA fielmente.

      -- (g) trial vigente de plan superior
      UPDATE public.accounts
      SET billing_plan = 'inicial', trial_plan = 'pro', trial_expires_at = now() + INTERVAL '10 days',
          billing_exempt = false
      WHERE id = v_account1;
      v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));
      IF (v_claims_out #>> '{claims,app_metadata,plan}') = 'pro'
         AND (v_claims_out #>> '{claims,app_metadata,plan}') = public.get_effective_plan(v_account1)
      THEN
        v_gate_g := true;
      ELSE
        RAISE EXCEPTION 'GATE (g) FAILED: trial vigente no propagado al claim plan: %', v_claims_out;
      END IF;

      -- (h) sin trial -> billing_plan
      UPDATE public.accounts
      SET trial_plan = NULL, trial_expires_at = NULL, billing_plan = 'avanzado'
      WHERE id = v_account1;
      v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));
      IF (v_claims_out #>> '{claims,app_metadata,plan}') = 'avanzado'
         AND (v_claims_out #>> '{claims,app_metadata,plan}') = public.get_effective_plan(v_account1)
      THEN
        v_gate_h := true;
      ELSE
        RAISE EXCEPTION 'GATE (h) FAILED: billing_plan sin trial no propagado al claim plan: %', v_claims_out;
      END IF;

      -- (i) exenta -> pro, sin importar billing_plan
      UPDATE public.accounts
      SET billing_plan = 'gratis', billing_exempt = true, billing_exempt_reason = 'gate v31-authz-token-hook'
      WHERE id = v_account1;
      v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));
      IF (v_claims_out #>> '{claims,app_metadata,plan}') = 'pro' THEN
        v_gate_i := true;
      ELSE
        RAISE EXCEPTION 'GATE (i) FAILED: cuenta exenta no propagó plan=pro: %', v_claims_out;
      END IF;
      UPDATE public.accounts SET billing_exempt = false, billing_exempt_reason = NULL WHERE id = v_account1;

      -- ── (j) determinismo de cuenta activa bajo multi-membresía (D4) ──────
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_user2, 'authenticated', 'authenticated',
              'v31-authz-hook-gate-2@test.local', now(), now(),
              jsonb_build_object('name', 'Gate Dos', 'phone', '', 'locality', '', 'province', ''));
      SELECT account_id INTO v_account2 FROM public.account_members WHERE user_id = v_user2;

      -- user1 gana una 2da membresía en account2, MÁS RECIENTE que la de account1.
      INSERT INTO public.account_members (id, account_id, user_id, role, created_at)
      VALUES (gen_random_uuid(), v_account2, v_user1, 'member', now() + INTERVAL '1 hour');

      SELECT account_id INTO v_expected_acc
      FROM public.account_members WHERE user_id = v_user1 ORDER BY created_at, id LIMIT 1;
      SELECT role INTO v_expected_role
      FROM public.account_members WHERE user_id = v_user1 AND account_id = v_expected_acc;
      v_expected_plan := public.get_effective_plan(v_expected_acc);

      v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));

      IF v_expected_acc <> v_account1
         OR (v_claims_out #>> '{claims,app_metadata,account_role}') <> v_expected_role
         OR (v_claims_out #>> '{claims,app_metadata,plan}') <> v_expected_plan
      THEN
        RAISE EXCEPTION 'GATE (j.1) FAILED: cuenta activa esperada=% hook_account_role=% expected_role=%',
          v_expected_acc, v_claims_out #>> '{claims,app_metadata,account_role}', v_expected_role;
      END IF;

      -- TRIANGULATE (4.4): invertir CUÁL membresía tiene el created_at más
      -- antiguo (no el orden físico de inserción) y confirmar que el
      -- resultado sigue al valor de created_at, no al orden de filas.
      UPDATE public.account_members SET created_at = now() + INTERVAL '2 hours'
      WHERE user_id = v_user1 AND account_id = v_account1;
      UPDATE public.account_members SET created_at = now() - INTERVAL '1 hour'
      WHERE user_id = v_user1 AND account_id = v_account2;

      SELECT account_id INTO v_expected_acc
      FROM public.account_members WHERE user_id = v_user1 ORDER BY created_at, id LIMIT 1;
      SELECT role INTO v_expected_role
      FROM public.account_members WHERE user_id = v_user1 AND account_id = v_expected_acc;

      v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));

      IF v_expected_acc <> v_account2
         OR (v_claims_out #>> '{claims,app_metadata,account_role}') <> v_expected_role
      THEN
        RAISE EXCEPTION 'GATE (j.2 TRIANGULATE) FAILED: invertir created_at no invirtió la cuenta elegida (esperada=%, role=%)',
          v_expected_acc, v_claims_out #>> '{claims,app_metadata,account_role}';
      END IF;
      v_gate_j := true;

      -- ── (k) sin el GRANT, degrada TODO; con el GRANT, vuelve a andar ─────
      -- Task 2.3: prueba de que el blindaje EXCEPTION WHEN OTHERS no está
      -- tapando un error de permisos. Solo se ejerce acá (DB vacía/CI):
      -- tocar GRANTs de una tabla en prod real está fuera de alcance.
      -- NOTA: la función es STABLE (no SECURITY DEFINER) — corre con los
      -- privilegios del rol que la INVOCA (D5). El rol que aplica esta
      -- migración (postgres, superusuario) bypassea GRANT/RLS por completo,
      -- así que revocarle el SELECT a supabase_auth_admin no tendría ningún
      -- efecto observable si la invocación siguiera corriendo como ese
      -- superusuario. Por eso, y SOLO para este gate, se conmuta el rol de
      -- sesión con SET LOCAL ROLE alrededor de cada invocación — así la
      -- llamada corre genuinamente como supabase_auth_admin, igual que en
      -- producción cuando Supabase Auth invoca el hook.
      REVOKE SELECT ON TABLE public.account_members FROM supabase_auth_admin;

      EXECUTE 'SET LOCAL ROLE supabase_auth_admin';
      v_claims_out := public.custom_access_token_hook(jsonb_build_object(
        'user_id', v_user1, 'claims', jsonb_build_object('sub', 'preserved')
      ));
      EXECUTE 'RESET ROLE';
      IF v_claims_out <> jsonb_build_object('claims', jsonb_build_object('sub', 'preserved')) THEN
        RAISE EXCEPTION 'GATE (k.1) FAILED: sin GRANT, el hook debía degradar TODO el app_metadata y no lo hizo: %', v_claims_out;
      END IF;

      GRANT SELECT ON TABLE public.account_members TO supabase_auth_admin;

      EXECUTE 'SET LOCAL ROLE supabase_auth_admin';
      v_claims_out := public.custom_access_token_hook(jsonb_build_object('user_id', v_user1, 'claims', '{}'::jsonb));
      EXECUTE 'RESET ROLE';
      IF (v_claims_out #>> '{claims,app_metadata,account_role}') IS NULL THEN
        RAISE EXCEPTION 'GATE (k.2) FAILED: con el GRANT restituido, el hook debía volver a emitir account_role: %', v_claims_out;
      END IF;
      v_gate_k := true;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (%' THEN
          RAISE;  -- una aserción real falló — abortar (CI lo atrapa)
        END IF;
        v_run_behavioral := false;
        RAISE NOTICE 'v31-authz-token-hook: anchor sintético/gates de comportamiento degradados (%) — %', SQLSTATE, SQLERRM;
    END;

    -- ── Limpieza best-effort del anchor sintético (solo DB de test) ────────
    BEGIN
      DELETE FROM public.account_members WHERE user_id IN (v_user1, v_user2);
      DELETE FROM public.cashboxes cb USING public.branches br
        WHERE cb.branch_id = br.id AND br.account_id IN (v_account1, v_account2);
      DELETE FROM public.branches WHERE account_id IN (v_account1, v_account2);
      DELETE FROM public.billing_events WHERE user_id IN (v_user1, v_user2);
      DELETE FROM public.accounts WHERE owner_user_id IN (v_user1, v_user2);
      DELETE FROM public.profiles WHERE id IN (v_user1, v_user2);
      DELETE FROM auth.users WHERE id IN (v_user1, v_user2);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'v31-authz-token-hook: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== v31-authz-token-hook SQL gates ===';
  RAISE NOTICE '(a) 1 def, STABLE, search_path fijo:              %', v_gate_a;
  RAISE NOTICE '(b) account_members: GRANT + policy:               %', v_gate_b;
  RAISE NOTICE '(c) get_effective_plan: EXECUTE:                   %', v_gate_c;
  RAISE NOTICE '(d) sin membresía: role sí, account_role no:       %', v_gate_d;
  RAISE NOTICE '(e) user_id inexistente: claims intactos:          %', v_gate_e;
  RAISE NOTICE '(f) claims completos (role+account_role+plan):     %', v_gate_f;
  RAISE NOTICE '(g) plan = trial vigente:                          %', v_gate_g;
  RAISE NOTICE '(h) plan = billing_plan sin trial:                 %', v_gate_h;
  RAISE NOTICE '(i) plan = pro por exención:                       %', v_gate_i;
  RAISE NOTICE '(j) determinismo de cuenta activa (D4), 2 órdenes: %', v_gate_j;
  RAISE NOTICE '(k) sin GRANT degrada, con GRANT restituye:        %', v_gate_k;
  RAISE NOTICE '=== v31-authz-token-hook: instalado y DORMIDO — activación manual del PO (D7) ===';

END $gate$;
