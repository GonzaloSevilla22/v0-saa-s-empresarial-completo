-- =============================================================================
-- MIGRATION: 20260819000001_billing_edge_effective_plan.sql
-- CHANGE:    billing-edge-effective-plan (sign-off PO 2026-07-31)
-- Design ref: openspec/changes/billing-edge-effective-plan/design.md
--
-- Implementa (design.md):
--   D1  rpc_my_effective_plan(): wrapper delgado SIN argumentos sobre la
--       definición normativa get_effective_plan(account_id) (billing-pro-trial,
--       20260817000001). Necesario porque get_effective_plan(uuid) tiene
--       EXECUTE revocado de authenticated/anon (D2 de billing-pro-trial) y
--       las Edge Functions llaman con el JWT del usuario, no con service_role.
--       get_effective_plan(uuid) NO CAMBIA: firma y grants intactos.
--   D2  Resolución de la cuenta del llamador: reutiliza el helper canónico
--       current_account_ids() (20260606000001) para el conjunto de cuentas
--       elegibles del usuario, y desempata determinísticamente por la
--       membresía MÁS ANTIGUA (account_members.created_at ASC), con
--       desempate final por account_id ASC si dos membresías comparten
--       created_at exacto. Sin cuenta resoluble: 'gratis' (fail-closed, D5).
--   D5  Fail-closed en la resolución del plan (nunca el plan más alto) — ver
--       design.md § D5. El fail-open de plan_limits vive en la capa Edge
--       Function (_shared/effective-plan.ts / ai-quota.ts), no acá.
--
-- OQ-1..OQ-4 (sign-off PO 2026-07-31, ver tasks.md § 0.1):
--   OQ-1 = opción (B) — este wrapper RPC (no service_role, no GRANT directo
--          de get_effective_plan).
--   OQ-4 = regla determinista documentada acá (D2), sin "cuenta activa"
--          seleccionable (eso pertenece a v3-rbac-multirole).
--
-- DESVIACIÓN DOCUMENTADA (encontrada en TDD, task 2.4 — corregida antes del
-- merge, no llegó a prod): la primera versión de la query D2 filtraba
-- `account_members` solo por `account_id IN (SELECT current_account_ids())`,
-- sin restringir `user_id`. En una cuenta con 2+ miembros eso deja pasar
-- filas de OTROS usuarios de esa misma cuenta al ORDER BY/LIMIT 1, así que
-- el desempate por created_at podía levantar la membresía de otro usuario en
-- vez de la propia. El gate de comportamiento (i)/(j) lo detectó de forma
-- intermitente (~30-50% de las corridas de `supabase db reset --local`,
-- dependía del orden aleatorio de los UUID generados en cada corrida) —
-- confirmado con un anchor sintético dedicado antes de tocar el código. Fix:
-- agregar `AND am.user_id = (SELECT auth.uid())` a la query (ver el
-- comentario en el cuerpo de la función). El gate (i)/(j) se endureció para
-- ser determinista (ya no depende de UUIDs al azar): se verificó con un
-- control negativo que, sin el fix, el gate falla el 100% de las veces.
--
-- IDEMPOTENCIA: DROP FUNCTION IF EXISTS + CREATE (no CREATE OR REPLACE — la
-- función es nueva; DROP+CREATE evita cualquier overload residual si la
-- migración corre dos veces contra un estado intermedio distinto, lección
-- 42725/C3). Sin backfill de datos: 100% aditiva, no toca ninguna fila
-- existente ni la firma/grants de get_effective_plan.
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration). El pipeline de este proyecto aplica las
--        migraciones DOS VECES por diseño (integración GitHub + Actions db
--        push) — todo bloque de este archivo es re-aplicable sin efecto
--        acumulativo.
--
-- GOVERNANCE: CRÍTICO — billing de 34 cuentas reales, una con pago
--   reconciliado. Migración puramente aditiva: no otorga ni revoca acceso
--   de ninguna cuenta por sí sola, solo agrega una vía de lectura nueva para
--   Edge Functions. El efecto de negocio (cuentas pagas/exentas recuperan su
--   cuota real) ocurre recién cuando las Edge Functions se despliegan
--   consumiéndola — orden obligatorio: esta migración ANTES que el deploy de
--   funciones (ver design.md § Migration Plan, tasks.md § 8.1).
--
-- ROLLBACK (aditivo — sin pérdida de datos):
--   -- Revertir primero los archivos de Edge Function (vuelven a leer
--   -- profiles) y recién después, opcionalmente:
--   DROP FUNCTION IF EXISTS public.rpc_my_effective_plan();
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT proname, prosecdef, provolatile FROM pg_proc WHERE proname = 'rpc_my_effective_plan';
--   SELECT has_function_privilege('authenticated', 'public.rpc_my_effective_plan()', 'EXECUTE'); -- true
--   SELECT has_function_privilege('authenticated', 'public.get_effective_plan(uuid)', 'EXECUTE'); -- false (sin cambios, D2 billing-pro-trial)
-- =============================================================================


-- =============================================================================
-- 1. rpc_my_effective_plan() — wrapper delgado sin argumentos (D1, D2)
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_my_effective_plan();

CREATE FUNCTION public.rpc_my_effective_plan()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  -- D2: cuenta de la membresía MÁS ANTIGUA entre las elegibles según el
  -- helper canónico current_account_ids() (20260606000001) — desempate por
  -- account_id ASC si dos membresías comparten created_at exacto.
  --
  -- CRÍTICO: el filtro `am.user_id = (SELECT auth.uid())` es OBLIGATORIO acá
  -- y NO es redundante con `account_id IN (SELECT current_account_ids())`.
  -- Ese IN solo restringe QUÉ CUENTAS son elegibles; no restringe qué FILA
  -- de account_members se lee para cada una. En una cuenta compartida (2+
  -- miembros) hay una fila por miembro — sin este filtro, el ORDER BY podía
  -- levantar la fila de OTRO usuario (p. ej. el owner de una cuenta de la
  -- que el llamador es simple member) y devolver el plan de una cuenta que
  -- el llamador nunca tuvo intención de resolver. Confirmado con un anchor
  -- de 2 cuentas + 2 usuarios: sin este filtro, el resultado era
  -- indeterminista (~30-50% de las corridas) dependiendo del orden aleatorio
  -- de los UUID de cuenta al desempatar por created_at entre filas de
  -- USUARIOS DISTINTOS que por casualidad compartían timestamp.
  SELECT am.account_id
  INTO v_account_id
  FROM public.account_members am
  WHERE am.user_id = (SELECT auth.uid())
    AND am.account_id IN (SELECT public.current_account_ids())
  ORDER BY am.created_at ASC, am.account_id ASC
  LIMIT 1;

  -- Sin cuenta resoluble (usuario sin membresía, o sin sesión válida):
  -- fail-closed, nunca lanza.
  IF v_account_id IS NULL THEN
    RETURN 'gratis';
  END IF;

  RETURN public.get_effective_plan(v_account_id);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_my_effective_plan() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_effective_plan() TO authenticated;

COMMENT ON FUNCTION public.rpc_my_effective_plan() IS
  'billing-edge-effective-plan (D1/D2, sign-off PO 2026-07-31): wrapper SIN '
  'argumentos sobre get_effective_plan(uuid) para que las Edge Functions '
  '(JWT de usuario, sin service_role) lean el plan efectivo sin exponer '
  'get_effective_plan a authenticated (permanece revocada — D2 de '
  'billing-pro-trial). La cuenta del llamador se deriva SIEMPRE de '
  'auth.uid() vía current_account_ids(): es imposible por construcción '
  'consultar el plan de una cuenta ajena. Regla de desempate multi-cuenta '
  '(OQ-4): la membresía con MENOR account_members.created_at (más antigua); '
  'si dos membresías comparten created_at exacto, desempata el MENOR '
  'account_id. Sin cuenta resoluble: gratis (fail-closed, D5). No introduce '
  '"cuenta activa" seleccionable — eso pertenece a v3-rbac-multirole.';


-- =============================================================================
-- 2. GATES SQL (RED→GREEN→TRIANGULATE) — patrón billing-pro-trial /
--    v31-fsm-status-triggers. Estructurales: SIEMPRE (prod y CI).
--    Comportamiento: SOLO si public.accounts está vacía (CI) — anchor
--    sintético vía auth.users (handle_new_user provisiona accounts +
--    account_members + branch/caja), impersonación via
--    request.jwt.claim.sub (patrón 20260804000007), limpieza best-effort.
-- =============================================================================
DO $gate$
DECLARE
  v_count          int;
  v_bool           boolean;
  v_result         text;
  v_run_behavioral boolean := false;

  -- estructurales
  v_gate_a boolean := false;  -- rpc_my_effective_plan: 1 sola def, STABLE+DEFINER
  v_gate_b boolean := false;  -- authenticated CON EXECUTE, anon/PUBLIC SIN EXECUTE
  v_gate_c boolean := false;  -- get_effective_plan: authenticated/anon SIGUEN sin EXECUTE (D2 intacta)
  v_gate_d boolean := false;  -- get_effective_plan: sigue con 1 sola definición (42725)

  -- comportamiento (solo DB vacía)
  v_fake_user_1      uuid := gen_random_uuid();  -- owner de account_1
  v_fake_user_2      uuid := gen_random_uuid();  -- owner de account_2
  v_fake_user_h      uuid := gen_random_uuid();  -- usuario sin membresía (gate h)
  v_fake_account_1   uuid;
  v_fake_account_2   uuid;
  v_membership_1_at  timestamptz;
  v_expected_account uuid;
  v_expected_plan    text;
  v_results          text[];
  v_status           text;

  v_gate_e boolean := false;  -- cuenta nueva (trial): rpc = 'pro' = get_effective_plan
  v_gate_f boolean := false;  -- exención + trial vencido: rpc = 'pro'
  v_gate_g boolean := false;  -- billing_plan='inicial' sin trial: rpc = 'inicial' para 5 billing_status
  v_gate_h boolean := false;  -- usuario sin membresía: rpc = 'gratis'
  v_gate_i boolean := false;  -- multi-cuenta: membresía más antigua gana, 2 invocaciones consistentes
  v_gate_j boolean := false;  -- multi-cuenta: desempate por account_id cuando created_at coincide
BEGIN

  -- ── (a) rpc_my_effective_plan: 1 sola definición, STABLE + SECURITY DEFINER ──
  SELECT COUNT(*) INTO v_count
  FROM pg_proc WHERE proname = 'rpc_my_effective_plan' AND pronamespace = 'public'::regnamespace;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaba 1 definición de rpc_my_effective_plan, hay % (lección 42725/overload)', v_count;
  END IF;

  SELECT provolatile = 's' AND prosecdef INTO v_bool
  FROM pg_proc WHERE proname = 'rpc_my_effective_plan' AND pronamespace = 'public'::regnamespace;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (a) FAILED: rpc_my_effective_plan debe ser STABLE + SECURITY DEFINER';
  END IF;
  v_gate_a := true;

  -- ── (b) Grants de rpc_my_effective_plan ─────────────────────────────────
  IF NOT has_function_privilege('authenticated', 'public.rpc_my_effective_plan()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (b) FAILED: authenticated SIN EXECUTE sobre rpc_my_effective_plan';
  END IF;

  IF has_function_privilege('anon', 'public.rpc_my_effective_plan()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (b) FAILED: anon NO debería tener EXECUTE sobre rpc_my_effective_plan';
  END IF;
  v_gate_b := true;

  -- ── (c) get_effective_plan: authenticated/anon SIGUEN sin EXECUTE (D2) ──
  IF has_function_privilege('authenticated', 'public.get_effective_plan(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.get_effective_plan(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (c) FAILED: get_effective_plan quedó ejecutable por authenticated/anon — se debilitó D2 de billing-pro-trial';
  END IF;
  v_gate_c := true;

  -- ── (d) get_effective_plan: sigue con 1 sola definición (42725/C3) ──────
  SELECT COUNT(*) INTO v_count
  FROM pg_proc WHERE proname = 'get_effective_plan' AND pronamespace = 'public'::regnamespace;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: se esperaba 1 definición de get_effective_plan, hay % (esta migración no debe tocar su firma)', v_count;
  END IF;
  v_gate_d := true;

  -- ══════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- ── setup: user_1 → account_1 (trial nuevo, vía handle_new_user) ────
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_1, 'authenticated', 'authenticated',
              'billing-edge-effective-plan-gate-1@test.local', now(), now(),
              jsonb_build_object('name', 'Gate 1', 'phone', '', 'locality', '', 'province', ''));

      SELECT a.id INTO v_fake_account_1 FROM public.accounts a WHERE a.owner_user_id = v_fake_user_1;

      -- Impersonar user_1 (patrón 20260804000007): rpc_my_effective_plan()
      -- lee auth.uid() vía current_account_ids(), no hay JWT real en un DO block.
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_1::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_fake_user_1::text, true);

      -- ── (e) cuenta nueva en trial: rpc = 'pro' = get_effective_plan ─────
      SELECT public.rpc_my_effective_plan() INTO v_result;
      IF v_result = 'pro' AND v_result = public.get_effective_plan(v_fake_account_1) THEN
        v_gate_e := true;
      ELSE
        RAISE EXCEPTION 'GATE (e) FAILED: cuenta nueva en trial → rpc=% get_effective_plan=%', v_result, public.get_effective_plan(v_fake_account_1);
      END IF;

      -- ── (f) exención + trial vencido → rpc = 'pro' ──────────────────────
      UPDATE public.accounts
      SET billing_plan = 'gratis',
          trial_plan = 'pro',
          trial_expires_at = now() - INTERVAL '1 day',
          billing_exempt = true,
          billing_exempt_reason = 'gate de comportamiento billing-edge-effective-plan'
      WHERE id = v_fake_account_1;

      SELECT public.rpc_my_effective_plan() INTO v_result;
      IF v_result = 'pro' THEN
        v_gate_f := true;
      ELSE
        RAISE EXCEPTION 'GATE (f) FAILED: cuenta exenta con trial vencido → rpc=%', v_result;
      END IF;

      -- ── (g) billing_plan='inicial' sin trial: rpc='inicial' para los 5 billing_status ──
      UPDATE public.accounts
      SET billing_plan = 'inicial', trial_plan = NULL, trial_expires_at = NULL,
          billing_exempt = false, billing_exempt_reason = NULL
      WHERE id = v_fake_account_1;

      v_results := ARRAY[]::text[];
      FOREACH v_status IN ARRAY ARRAY['active','trialing','expired','cancelled','cancelling'] LOOP
        UPDATE public.accounts SET billing_status = v_status WHERE id = v_fake_account_1;
        SELECT public.rpc_my_effective_plan() INTO v_result;
        v_results := array_append(v_results, v_result);
      END LOOP;

      IF (SELECT COUNT(DISTINCT r) FROM unnest(v_results) r) = 1 AND v_results[1] = 'inicial' THEN
        v_gate_g := true;
      ELSE
        RAISE EXCEPTION 'GATE (g) FAILED: billing_status alteró el resultado de rpc_my_effective_plan: %', v_results;
      END IF;

      -- Dejar account_1 en un billing_status estable para las comparaciones (i)/(j).
      UPDATE public.accounts SET billing_status = 'active' WHERE id = v_fake_account_1;

      -- ── (h) usuario sin membresía alguna → rpc = 'gratis' ───────────────
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_h, 'authenticated', 'authenticated',
              'billing-edge-effective-plan-gate-h@test.local', now(), now(),
              jsonb_build_object('name', 'Gate H', 'phone', '', 'locality', '', 'province', ''));

      -- handle_new_user crea una cuenta propia + membresía propia: se
      -- eliminan a propósito para simular un usuario sin ninguna cuenta
      -- resoluble (la cuenta huérfana resultante se limpia al final).
      DELETE FROM public.account_members WHERE user_id = v_fake_user_h;

      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_h::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_fake_user_h::text, true);

      SELECT public.rpc_my_effective_plan() INTO v_result;
      IF v_result = 'gratis' THEN
        v_gate_h := true;
      ELSE
        RAISE EXCEPTION 'GATE (h) FAILED: usuario sin membresía → rpc=% (se esperaba gratis, fail-closed)', v_result;
      END IF;

      -- ── setup multi-cuenta: user_2 → account_2 (plan distinto de account_1) ──
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_2, 'authenticated', 'authenticated',
              'billing-edge-effective-plan-gate-2@test.local', now(), now(),
              jsonb_build_object('name', 'Gate 2', 'phone', '', 'locality', '', 'province', ''));

      SELECT a.id INTO v_fake_account_2 FROM public.accounts a WHERE a.owner_user_id = v_fake_user_2;

      -- account_2 exenta → plan 'pro', deliberadamente distinto de account_1
      -- ('inicial', dejado por el gate g) para que el resultado de (i) pruebe
      -- QUÉ cuenta ganó, no solo que no hubo error.
      UPDATE public.accounts
      SET billing_exempt = true, billing_exempt_reason = 'gate de comportamiento billing-edge-effective-plan (multi-cuenta)'
      WHERE id = v_fake_account_2;

      SELECT created_at INTO v_membership_1_at
      FROM public.account_members WHERE account_id = v_fake_account_1 AND user_id = v_fake_user_1;

      -- La propia membresía de user_2 en account_2 (su owner-row) se fija
      -- deliberadamente MÁS ANTIGUA que la de user_1 en account_1. Esto hace
      -- el gate (i) determinista de verdad: si el filtro `am.user_id =
      -- auth.uid()` alguna vez se pierde en la función (regresión exacta que
      -- este gate detectó durante el desarrollo de este change — sin el
      -- filtro, el ORDER BY podía levantar la fila de OTRO usuario en una
      -- cuenta compartida), el resultado SIEMPRE sería 'pro' (la fila de
      -- user_2, la más antigua de TODAS), nunca al azar según el UUID
      -- generado en cada corrida.
      UPDATE public.account_members
      SET created_at = v_membership_1_at - INTERVAL '1 day'
      WHERE account_id = v_fake_account_2 AND user_id = v_fake_user_2;

      -- user_1 se suma como member de account_2 — membresía MÁS NUEVA que la
      -- de account_1 (controlado explícitamente vía UPDATE, sin depender de
      -- gaps de reloj).
      INSERT INTO public.account_members (account_id, user_id, role, created_at)
      VALUES (v_fake_account_2, v_fake_user_1, 'member', now());

      UPDATE public.account_members
      SET created_at = v_membership_1_at + INTERVAL '1 hour'
      WHERE account_id = v_fake_account_2 AND user_id = v_fake_user_1;

      -- ── (i) membresía más antigua gana; 2 invocaciones dan el mismo resultado ──
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_1::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_fake_user_1::text, true);

      SELECT public.rpc_my_effective_plan() INTO v_result;
      IF v_result = 'inicial' THEN
        SELECT public.rpc_my_effective_plan() INTO v_result;  -- segunda invocación
        IF v_result = 'inicial' THEN
          v_gate_i := true;
        ELSE
          RAISE EXCEPTION 'GATE (i) FAILED: segunda invocación de rpc_my_effective_plan divergió: %', v_result;
        END IF;
      ELSE
        RAISE EXCEPTION 'GATE (i) FAILED: se esperaba que ganara la membresía más antigua (account_1, plan inicial), rpc=%', v_result;
      END IF;

      -- ── (j) desempate por account_id cuando created_at coincide ─────────
      UPDATE public.account_members
      SET created_at = v_membership_1_at
      WHERE account_id = v_fake_account_2 AND user_id = v_fake_user_1;

      v_expected_account := LEAST(v_fake_account_1, v_fake_account_2);
      v_expected_plan    := public.get_effective_plan(v_expected_account);

      SELECT public.rpc_my_effective_plan() INTO v_result;
      IF v_result = v_expected_plan THEN
        v_gate_j := true;
      ELSE
        RAISE EXCEPTION 'GATE (j) FAILED: con created_at empatado se esperaba el plan de la cuenta con menor id (%), rpc=%', v_expected_plan, v_result;
      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (%' THEN
          RAISE;  -- una aserción real falló — abortar (CI lo atrapa)
        END IF;
        v_run_behavioral := false;
        RAISE NOTICE 'billing-edge-effective-plan: anchor sintético/gates de comportamiento degradados (%) — %', SQLSTATE, SQLERRM;
    END;

    -- ── Limpieza best-effort del anchor sintético (solo DB de test) ────────
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      DELETE FROM public.billing_events WHERE user_id IN (v_fake_user_1, v_fake_user_2, v_fake_user_h);
      -- accounts en cascada arrastra account_members/branches/cashboxes.
      DELETE FROM public.accounts WHERE owner_user_id IN (v_fake_user_1, v_fake_user_2, v_fake_user_h);
      DELETE FROM public.profiles WHERE id IN (v_fake_user_1, v_fake_user_2, v_fake_user_h);
      DELETE FROM auth.users WHERE id IN (v_fake_user_1, v_fake_user_2, v_fake_user_h);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'billing-edge-effective-plan: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== billing-edge-effective-plan SQL gates ===';
  RAISE NOTICE '(a) rpc_my_effective_plan: 1 def, STABLE+DEFINER:  %', v_gate_a;
  RAISE NOTICE '(b) grants rpc_my_effective_plan correctos:        %', v_gate_b;
  RAISE NOTICE '(c) get_effective_plan sigue revocada (D2):        %', v_gate_c;
  RAISE NOTICE '(d) get_effective_plan sigue con 1 sola def:       %', v_gate_d;
  RAISE NOTICE '(e) cuenta nueva en trial → pro:                   %', v_gate_e;
  RAISE NOTICE '(f) exención + trial vencido → pro:                %', v_gate_f;
  RAISE NOTICE '(g) billing_status no altera el resultado:         %', v_gate_g;
  RAISE NOTICE '(h) usuario sin membresía → gratis:                %', v_gate_h;
  RAISE NOTICE '(i) multi-cuenta: membresía más antigua gana:      %', v_gate_i;
  RAISE NOTICE '(j) multi-cuenta: desempate por account_id:        %', v_gate_j;
  RAISE NOTICE '=== billing-edge-effective-plan: instalado OK ===';

END $gate$;
