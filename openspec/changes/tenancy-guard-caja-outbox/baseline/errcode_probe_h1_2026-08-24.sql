-- =============================================================================
-- VERIFICACIÓN EMPÍRICA DEL ERRCODE DE LA CAPA 2 — task 3.6 🛑
--
-- Qué se prueba: que el ERRCODE del backstop de c28_register_cash_movement
-- puede ser P0401 pero NO P0001, porque el gate de comportamiento embebido en
-- 20260804000003_fix_c28_cash_movement_balance.sql §(b) tiene este manejador:
--
--     EXCEPTION
--       WHEN raise_exception THEN
--         IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
--       WHEN OTHERS THEN
--         RAISE NOTICE 'fix-c28-balance: gate (b) saltado por entorno (%) …';
--
-- `WHEN raise_exception` matchea ÚNICAMENTE la clase P0001. Con P0401 el
-- rechazo del guard cae en WHEN OTHERS y degrada a NOTICE; con P0001 el
-- manejador RE-LANZA (el SQLERRM no es el sentinel) y aborta la migración —
-- y con ella `npx supabase db reset`.
--
-- Este archivo reproduce el manejador LITERAL sobre el guard real, en las dos
-- variantes, dentro de un BEGIN … ROLLBACK: no deja tenants sintéticos ni
-- cambia el cuerpo de ninguna función (el CREATE OR REPLACE contrafáctico del
-- CASO 2 revierte con el rollback, porque el DDL de Postgres es transaccional).
--
-- Uso:
--   docker exec -i supabase_db_v0-saa-s-empresarial-completo \
--     psql -U postgres -d postgres \
--     < openspec/changes/tenancy-guard-caja-outbox/baseline/errcode_probe_h1_2026-08-24.sql
--   (SIN -v ON_ERROR_STOP=1: el CASO 2 provoca un error a propósito y lo captura.)
--
-- NOTA IMPORTANTE que este probe dejó a la vista y que el design no preveía:
-- en un `db reset` LIMPIO el gate (b) de 20260804000003 NO se degrada, porque
-- las migraciones se aplican en orden de timestamp y ese archivo corre mucho
-- antes de que 20261013000001 exista — cuando lo ejercita, el helper todavía
-- no tiene guard. Medido: el reset completo termina con RC=0 y 262
-- migraciones. La degradación sólo puede ocurrir si 20260804000003 se
-- re-aplica DESPUÉS del guard, y ese archivo NO está en la cadena de reapply
-- de CI. O sea: la cobertura del gate (b) no se pierde, y la réplica del saldo
-- firmado en test_tenancy_guard_caja_outbox.sql (3.7) es cobertura ADICIONAL,
-- no un reemplazo. La elección del ERRCODE sigue importando igual, porque
-- cualquier re-aplicación manual posterior al guard cae en el escenario del
-- CASO 2.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE errcode_probe_ctx (user_a uuid, session_b uuid) ON COMMIT DROP;

DO $$
DECLARE
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_account_b uuid;
  v_branch_b  uuid;
  v_cashbox_b uuid;
  v_session_b uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'errcode-probe-a@test.local', now(), now(),
          jsonb_build_object('name', 'Errcode probe A'));
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'errcode-probe-b@test.local', now(), now(),
          jsonb_build_object('name', 'Errcode probe B'));

  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b  FROM public.branches  WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_b FROM public.cashboxes WHERE branch_id  = v_branch_b  ORDER BY created_at LIMIT 1;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_b, 'open', 1000, v_user_b) RETURNING id INTO v_session_b;

  INSERT INTO errcode_probe_ctx VALUES (v_user_a, v_session_b);

  -- Sesión del usuario A: NO es miembro de la cuenta B. Es exactamente la
  -- situación del anchor del gate (b) (su usuario tampoco es miembro de la
  -- cuenta de la que cuelgan sucursal, caja y sesión).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
END $$;

-- ── CASO 1 — ERRCODE actual (P0401): el manejador del gate (b) DEGRADA ───────
DO $$
DECLARE
  v_ctx errcode_probe_ctx%ROWTYPE;
BEGIN
  SELECT * INTO v_ctx FROM errcode_probe_ctx;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_ctx.user_a::text, 'role', 'authenticated')::text, true);

  DECLARE
    v_m1 uuid;
  BEGIN
    -- Manejador LITERAL del gate (b) de 20260804000003.
    v_m1 := public.c28_register_cash_movement(v_ctx.session_b, 500.00, 'sale');
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
      RAISE NOTICE 'CASO 1 — INESPERADO: el rechazo del guard cayó en WHEN raise_exception (el ERRCODE sería P0001).';
    WHEN OTHERS THEN
      RAISE NOTICE 'CASO 1 — OK: el guard levantó % y el manejador lo DEGRADÓ a NOTICE ("gate (b) saltado por entorno: %"). La migración sigue: `db reset` NO aborta.', SQLSTATE, SQLERRM;
  END;
END $$;

-- ── CASO 2 — contrafáctico con P0001: el manejador RE-LANZA y aborta ─────────
-- Se cambia SÓLO el ERRCODE del guard, dentro de la transacción (el DDL de
-- Postgres es transaccional, así que el ROLLBACK del final lo revierte).
CREATE OR REPLACE FUNCTION public.c28_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_owner_account_id uuid;
BEGIN
  -- Variante SÓLO para el probe: el mismo guard con ERRCODE P0001.
  SELECT b.account_id INTO v_owner_account_id
  FROM public.cash_sessions cs
  JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
  JOIN public.branches b   ON b.id  = cb.branch_id
  WHERE cs.id = p_session_id;

  IF v_owner_account_id IS NULL
     OR v_owner_account_id NOT IN (SELECT public.current_account_ids()) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NULL;
END;
$function$;

DO $$
DECLARE
  v_ctx errcode_probe_ctx%ROWTYPE;
BEGIN
  SELECT * INTO v_ctx FROM errcode_probe_ctx;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_ctx.user_a::text, 'role', 'authenticated')::text, true);

  BEGIN
    DECLARE
      v_m1 uuid;
    BEGIN
      v_m1 := public.c28_register_cash_movement(v_ctx.session_b, 500.00, 'sale');
      RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
    EXCEPTION
      WHEN raise_exception THEN
        IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
        RAISE NOTICE 'CASO 2 — INESPERADO: no relanzó.';
      WHEN OTHERS THEN
        RAISE NOTICE 'CASO 2 — INESPERADO: degradó a NOTICE con % (%).', SQLSTATE, SQLERRM;
    END;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'CASO 2 — CONFIRMADO: con ERRCODE P0001 el manejador del gate (b) RE-LANZÓ % (%). En la migración real eso aborta el archivo y con él `npx supabase db reset`. Por eso el guard usa P0401.', SQLSTATE, SQLERRM;
  END;
END $$;

ROLLBACK;
