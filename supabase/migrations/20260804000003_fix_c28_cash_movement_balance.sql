-- =============================================================================
-- MIGRATION: 20260804000003_fix_c28_cash_movement_balance.sql
-- CHANGE:    Hotfix de correctitud de C-28 v21-cash-session (caja en producción)
--
-- BUG (descubierto durante el apply de bank-account-ledger, V2.5):
--   public.c28_register_cash_movement (migración 20260701000001_c28_cash_session.sql,
--   ≈línea 194) calculaba el saldo previo de la sesión así:
--
--       SELECT COALESCE(MAX(cm.balance_after), v_session.opening_balance)
--       INTO v_prev_balance
--       FROM public.cash_movements cm
--       WHERE cm.session_id = p_session_id;
--       v_balance_after := v_prev_balance + p_amount;
--
--   MAX(balance_after) devuelve el PICO histórico de saldo, no el saldo CORRIENTE.
--   En cuanto un movimiento baja el saldo (egreso/retiro/pago a proveedor) y luego
--   entra otra actividad, el cálculo arranca del pico y no del saldo real.
--
--   Ejemplo (opening = 1000):
--     +500 → 1500   (MAX=1500 ✓)
--     -200 → 1300   (MAX(1500,1300)=1500; 1500-200=1300 ✓ por casualidad)
--     +300 → MAX(1500,1300)+300 = 1800   ✗  (el saldo correcto es 1600)
--
--   Impacto: cash_movements.balance_after (el saldo corriente por movimiento que se
--   muestra en la lista de la caja) queda mal en CUALQUIER sesión con un egreso
--   seguido de actividad. Bug de correctitud en producción (caja con usuarios reales).
--
--   ALCANCE ACOTADO: el arqueo al cierre (cash_sessions.expected_balance / difference)
--   NO depende de balance_after — rpc_close_cash_session lo recalcula desde
--   opening_balance + SUM(cash_movements.amount) (ver 20260701000001 §1.7, línea ~333).
--   Por lo tanto el arqueo histórico ya es correcto; solo balance_after está corrupto.
--
-- FIX (mismo patrón aplicado al ledger bancario en 20260804000002_bank_account_ledger.sql,
--      helper _register_bank_movement): calcular el saldo previo como
--      opening_balance + SUM(amount de los movimientos previos), NO MAX(balance_after):
--
--       SELECT v_session.opening_balance + COALESCE(SUM(cm.amount), 0)
--       INTO v_prev_balance
--       FROM public.cash_movements cm
--       WHERE cm.session_id = p_session_id;
--       v_balance_after := v_prev_balance + p_amount;
--
--   El SELECT ... FOR UPDATE sobre cash_sessions (sin cambios) ya serializa el cálculo,
--   así que SUM es seguro frente a concurrencia.
--
-- QUÉ NO CAMBIA (CREATE OR REPLACE — firma, guards y semántica idénticos):
--   · Firma: c28_register_cash_movement(uuid, numeric, text, uuid)
--   · Guards: P0409 no_open_session, P0422 branch_closed
--   · INSERT append-only con created_by = auth.uid()
--   · LANGUAGE plpgsql, NO SECURITY DEFINER (intra-transacción), SET search_path = public
--   · REVOKE ALL FROM PUBLIC (callable solo desde RPCs SECURITY DEFINER del módulo)
--   El ÚNICO cambio funcional es el cálculo de v_prev_balance (MAX → opening + SUM).
--
-- BACKFILL: NO incluido — decisión del PO (2026-06-27): corregir SOLO de acá en adelante.
--   Los cash_movements.balance_after históricos de sesiones con egresos quedan como están
--   (saldo corriente mostrado por movimiento). No se pierde dinero: el arqueo al cierre ya
--   es correcto (cash_sessions.expected_balance/difference se recalculan desde SUM(amount),
--   no desde balance_after — ver ALCANCE). Si el PO reconsidera, el backfill es determinístico:
--   por sesión, walk de los movimientos append-only por created_at y running-sum desde
--   opening_balance.
--
-- GOVERNANCE: MEDIO (misma que la migración original 20260701000001). Correctitud de
--   un cálculo; sin cambio de firma, contrato ni datos históricos.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — desincroniza el history)
--
-- ROLLBACK (restaurar el cálculo previo — re-introduce el bug):
--   Reaplicar la definición de c28_register_cash_movement de
--   20260701000001_c28_cash_session.sql §1.5 (con MAX(cm.balance_after)).
--   Sin cambios de schema ni de datos: rollback puramente de lógica de función.
--
-- VERIFICATION (post-push):
--   SELECT pg_get_functiondef(p.oid) ILIKE '%opening_balance + COALESCE(SUM%' AS fixed
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.proname = 'c28_register_cash_movement';  -- => true
-- =============================================================================


-- ============================================================
-- 1. CREATE OR REPLACE: c28_register_cash_movement
--    Idéntica a 20260701000001 §1.5 salvo el cálculo de v_prev_balance.
-- ============================================================
CREATE OR REPLACE FUNCTION public.c28_register_cash_movement(
  p_session_id    uuid,
  p_amount        numeric,
  p_type          text,
  p_reference_id  uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_session      public.cash_sessions%ROWTYPE;
  v_branch_status text;
  v_prev_balance  numeric(12,2);
  v_balance_after numeric(12,2);
  v_movement_id   uuid;
  v_user_id       uuid;
BEGIN
  -- D3: lock de fila de la sesión para serializar cálculo de balance_after
  SELECT * INTO v_session
  FROM public.cash_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  -- Validar que la sesión esté open
  IF v_session.id IS NULL OR v_session.status <> 'open' THEN
    RAISE EXCEPTION 'no_open_session'
      USING ERRCODE = 'P0409';
  END IF;

  -- Validar que la sucursal esté activa
  SELECT b.status INTO v_branch_status
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = v_session.cashbox_id;

  IF v_branch_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'branch_closed'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular el saldo previo = opening_balance + SUM(amount de los movimientos previos).
  -- (SUM(amount), NO MAX(balance_after): el saldo corriente puede BAJAR tras un egreso,
  --  y MAX devolvería el pico histórico, no el saldo actual. El FOR UPDATE de arriba
  --  serializa el cálculo, así que SUM es seguro. Mismo patrón que _register_bank_movement.)
  SELECT v_session.opening_balance + COALESCE(SUM(cm.amount), 0)
  INTO v_prev_balance
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_balance_after := v_prev_balance + p_amount;

  -- Resolver el usuario actual del JWT
  v_user_id := auth.uid();

  -- Insertar el movimiento (append-only)
  INSERT INTO public.cash_movements
    (session_id, amount, movement_type, reference_id, balance_after, created_by)
  VALUES
    (p_session_id, p_amount, p_type, p_reference_id, v_balance_after, v_user_id)
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;

-- REVOKE acceso público — solo callable desde RPCs SECURITY DEFINER de este módulo.
-- (CREATE OR REPLACE preserva la ACL existente; se re-afirma por idempotencia/claridad.)
REVOKE ALL ON FUNCTION public.c28_register_cash_movement(uuid, numeric, text, uuid) FROM PUBLIC;

COMMENT ON FUNCTION public.c28_register_cash_movement(uuid, numeric, text, uuid) IS
  'C-28 v21-cash-session: helper intra-transacción del ledger de caja (NO SECURITY DEFINER, '
  'corre en la transacción del llamador). FOR UPDATE sobre cash_sessions serializa el cálculo. '
  'Hotfix 20260804000003: balance_after = opening_balance + SUM(amount de movimientos previos) + amount '
  '(SUM, no MAX(balance_after): el saldo corriente puede bajar tras un egreso). '
  'REVOKE de PUBLIC: callable solo desde rpc_register_cash_movement y el hot path de venta (C-29).';


-- ============================================================
-- 2. Gates SQL (TDD — RED→GREEN validados por este DO-block)
--
-- Estilo espejo de bank-account-ledger §7 y c28_cash_session §1.9.
-- Sub-bloques BEGIN/EXCEPTION por gate (PL/pgSQL NO admite SAVEPOINT/ROLLBACK TO
-- SAVEPOINT explícitos); el gate de comportamiento revierte sus datos vía un
-- sentinel (RAISE capturado).
--
-- Gates:
--   (a) Introspección (corre SIEMPRE, incl. prod): el cuerpo de la función usa
--       opening_balance + SUM(cm.amount) y NO MAX(cm.balance_after).
--       Garantía permanente de que el fix está desplegado y no reaparece la regresión.
--   (b) Comportamiento (SOLO en DB de test/vacía, vía anchor sintético): la secuencia
--       firmada +500 / -200 / +300 sobre opening=1000 → 1500 / 1300 / 1600.
--       Con el bug viejo (MAX) el tercer movimiento daría 1800; con el fix da 1600.
--
-- El anchor de comportamiento se crea SOLO si public.accounts está vacía (CI). En
-- producción (con cuentas reales) v_run_behavioral=false → CERO mutación de datos.
-- ============================================================
DO $$
DECLARE
  v_fake_user_id    uuid := gen_random_uuid();
  v_fake_account_id uuid := gen_random_uuid();
  v_branch_id       uuid;
  v_cashbox_id      uuid;
  v_session_id      uuid;
  v_count           int;
  v_run_behavioral  boolean := false;
  v_gate_a boolean := false;
  v_gate_b boolean := false;
BEGIN

  -- ── (a) Introspección del cuerpo de la función (SIEMPRE) ──────────────────
  -- RED del bug: el cuerpo contenía MAX(cm.balance_after).
  -- GREEN del fix: contiene opening_balance + COALESCE(SUM(cm.amount), ...) y NO MAX(...).
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'c28_register_cash_movement'
      AND pg_get_functiondef(p.oid) ILIKE '%sum(cm.amount)%'
      AND pg_get_functiondef(p.oid) NOT ILIKE '%max(cm.balance_after)%';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (a) FAILED: c28_register_cash_movement no usa SUM(amount) '
        'o todavía referencia MAX(balance_after) — el fix no está aplicado.';
    END IF;
    v_gate_a := true;
  END;


  -- ── SETUP del anchor de comportamiento (SOLO en DB de test/vacía) ─────────
  -- Igual que bank-account-ledger §7: en una DB VACÍA (CI, sin cuentas) creamos un
  -- anchor sintético (auth.users → account → branch → cashbox → cash_session) para
  -- poder ejercitar el helper. En prod (con cuentas reales) se SALTA → 0 mutación.
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'c28-balance-gate@test.local', now(), now(),
              jsonb_build_object('name', 'C28 Balance Gate', 'phone', '',
                                 'locality', '', 'province', ''))
      ON CONFLICT (id) DO NOTHING;

      INSERT INTO public.accounts (id, owner_user_id)
      VALUES (v_fake_account_id, v_fake_user_id) ON CONFLICT (id) DO NOTHING;

      INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
      VALUES (v_fake_account_id, 'Sucursal Gate C28', true, 'active', now())
      RETURNING id INTO v_branch_id;

      INSERT INTO public.cashboxes (branch_id, name, currency)
      VALUES (v_branch_id, 'Caja Gate C28', 'ARS')
      RETURNING id INTO v_cashbox_id;

      INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
      VALUES (v_cashbox_id, 'open', 1000.00, v_fake_user_id)
      RETURNING id INTO v_session_id;

      -- El helper escribe created_by = auth.uid(); cash_movements.created_by es NOT NULL.
      -- En la migración no hay JWT real → fijamos el claim al usuario del anchor (local a la tx).
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_id::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_fake_user_id::text, true);
    EXCEPTION
      WHEN OTHERS THEN
        v_run_behavioral := false;
        RAISE NOTICE 'fix-c28-balance: anchor sintético no disponible (%) — se salta el gate de comportamiento (b)', SQLERRM;
    END;
  END IF;


  -- ── (b) Secuencia firmada +500 / -200 / +300 → 1500 / 1300 / 1600 ─────────
  -- El saldo baja (egreso) y vuelve a subir → valida que el helper usa opening+SUM(amount),
  -- no MAX(balance_after) (que daría 1800 en el tercer movimiento). Sentinel rollback.
  IF v_run_behavioral THEN
  DECLARE
    v_m1 uuid; v_m2 uuid; v_m3 uuid;
    v_b1 numeric; v_b2 numeric; v_b3 numeric;
  BEGIN
    v_m1 := public.c28_register_cash_movement(v_session_id,  500.00, 'sale');
    v_m2 := public.c28_register_cash_movement(v_session_id, -200.00, 'withdrawal');
    v_m3 := public.c28_register_cash_movement(v_session_id,  300.00, 'sale');

    SELECT cm.balance_after INTO v_b1 FROM public.cash_movements cm WHERE cm.id = v_m1;
    SELECT cm.balance_after INTO v_b2 FROM public.cash_movements cm WHERE cm.id = v_m2;
    SELECT cm.balance_after INTO v_b3 FROM public.cash_movements cm WHERE cm.id = v_m3;

    IF v_b1 IS DISTINCT FROM 1500.00 THEN
      RAISE EXCEPTION 'GATE (b) FAILED: +500 esperaba 1500, obtuvo %', v_b1;
    END IF;
    IF v_b2 IS DISTINCT FROM 1300.00 THEN
      RAISE EXCEPTION 'GATE (b) FAILED: -200 esperaba 1300, obtuvo %', v_b2;
    END IF;
    IF v_b3 IS DISTINCT FROM 1600.00 THEN
      RAISE EXCEPTION 'GATE (b) FAILED: +300 esperaba 1600, obtuvo % (con el bug viejo daría 1800)', v_b3;
    END IF;
    v_gate_b := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      -- sentinel (rollback OK) o assertion real (GATE (b) FAILED → re-raise, aborta).
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
    WHEN OTHERS THEN
      -- Falla de infra del anchor (p.ej. auth.uid() NULL → created_by NOT NULL en este
      -- entorno): el gate (a) por introspección ya garantiza el fix. Se SALTA (b) con
      -- NOTICE en vez de abortar la migración por una limitación del entorno de test.
      RAISE NOTICE 'fix-c28-balance: gate (b) saltado por entorno (%) — el fix está garantizado por el gate (a)', SQLERRM;
  END;
  END IF;


  -- ── Limpieza del anchor sintético (SOLO en DB de test, best-effort) ───────
  -- En prod v_run_behavioral=false → no se creó nada. DELETE accounts por owner →
  -- CASCADE a branches→cashboxes→cash_sessions→cash_movements (e incluye la cuenta
  -- auto-creada por handle_new_user). Una limpieza parcial en la DB de test (descartable)
  -- NO debe abortar la migración.
  IF v_run_behavioral THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'fix-c28-balance: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;


  -- ── Resumen de gates ──────────────────────────────────────────────────────
  RAISE NOTICE '=== fix-c28-cash-movement-balance SQL gates ===';
  RAISE NOTICE '(a) cuerpo usa SUM(amount), no MAX(balance_after):  %', v_gate_a;
  RAISE NOTICE '(b) secuencia +500/-200/+300 → 1500/1300/1600:       %', v_gate_b;
  RAISE NOTICE '=== fix-c28-cash-movement-balance: hotfix aplicado ===';

END $$;
