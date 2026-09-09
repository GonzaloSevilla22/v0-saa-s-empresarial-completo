-- =============================================================================
-- GATE: test_bank_default_destination.sql
-- CHANGE: bank-default-destination (cobranzas-catalogo-pagos OQ-5)
--
-- Ejercita de verdad (sesión sintética vía request.jwt.claims, mismo patrón
-- que test_pos_banco_movimientos.sql/test_payment_method_operations.sql) el
-- helper nuevo `_pay_assign_default_bank_destination` y su cableado en
-- `rpc_create_bank_account`. Cubre:
--   (1) cuenta con 0 bancos activos: crear el 1º banco vía
--       rpc_create_bank_account asigna automáticamente las formas de pago
--       bancarias (transfer/card/wallet/check) SIN destino — y NO toca
--       cash/credit/other (no son bancarias) ni una forma de pago que YA
--       tenía un destino asignado (aunque apunte a un banco hoy inactivo —
--       el filtro es `bank_account_id IS NULL`, no "banco activo").
--   (2) idempotencia por-cuenta: invocar el helper de nuevo con el mismo
--       estado (1 banco activo, nada más para asignar) devuelve 0 filas.
--   (3) crear el 2º banco (2 bancos activos ahora) NO cambia ninguna
--       asignación existente — "con varias, no adivinar".
--   (4) el helper invocado directo con 2 bancos activos devuelve 0.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email   text := 'bank-default-destination-gate@test.local';
  v_user_id        uuid;
  v_account_id     uuid;
  v_resolved       boolean := false;

  v_pm_transfer    uuid;
  v_pm_card        uuid;
  v_pm_wallet      uuid;
  v_pm_check       uuid;
  v_pm_cash        uuid;
  v_pm_credit      uuid;
  v_pm_other       uuid;

  v_bank_stale     uuid;  -- 1er banco creado — luego se desactiva (simula un
                          -- destino manual histórico que quedó apuntando a
                          -- un banco que ya no está activo)
  v_bank_1         uuid;  -- único banco ACTIVO durante (1)/(2)
  v_bank_2         uuid;  -- 2º banco activo, para (3)/(4)

  v_result         jsonb;
  v_count          integer;
  v_bank_account_id uuid;
BEGIN
  -- ── Anchor sintético (resuelto por email primero — un gen_random_uuid()
  -- nuevo en cada corrida rompía el índice único de email si el cleanup de
  -- una corrida previa no había llegado a correr) ────────────────────────
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_anchor_email;
  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
            jsonb_build_object('name', 'Gate Bank Default Destination'));
  END IF;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE BANK-DEFAULT-DESTINATION: no se pudo resolver cuenta para el anchor sintético (provisioning-seed no disponible en este contexto, o el anchor ya existía de una corrida previa) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'transfer' LIMIT 1;
  SELECT id INTO v_pm_card     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'card' LIMIT 1;
  SELECT id INTO v_pm_wallet   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'wallet' LIMIT 1;
  SELECT id INTO v_pm_check    FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'check' LIMIT 1;
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;
  SELECT id INTO v_pm_credit   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'credit' LIMIT 1;
  SELECT id INTO v_pm_other    FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'other' LIMIT 1;

  IF v_pm_transfer IS NULL OR v_pm_card IS NULL OR v_pm_wallet IS NULL OR v_pm_check IS NULL THEN
    RAISE NOTICE 'GATE BANK-DEFAULT-DESTINATION: catálogo de formas de pago (seed de 7 kinds) no disponible para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  -- Precondición: cuenta nueva, 0 bancos, ninguna forma de pago con destino.
  IF EXISTS (SELECT 1 FROM public.bank_accounts WHERE account_id = v_account_id) THEN
    RAISE NOTICE 'GATE BANK-DEFAULT-DESTINATION: el anchor ya tenía cuentas bancarias de una corrida previa — degradando sin abortar (no es un entorno limpio).';
    RETURN;
  END IF;

  -- ── Sesión sintética (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ──
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE BANK-DEFAULT-DESTINATION: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;
  v_resolved := true;

  -- ═══════════ Fixture: un destino "manual histórico" hacia un banco que
  -- luego queda inactivo — simula el caso real de "ya tenía destino" sin
  -- violar la precondición de 0 bancos ACTIVOS al momento de (1). Crear este
  -- banco es en sí mismo el 1er banco de la cuenta, así que dispara el
  -- helper y asigna las 4 formas bancarias — se resetean 3 a NULL a
  -- propósito para dejar sólo 'transfer' apuntando a él, y luego se
  -- desactiva. ═══════════════════════════════════════════════════════════
  SELECT public.rpc_create_bank_account(p_name => '__gate_bdd_bank_stale__') INTO v_result;
  v_bank_stale := (v_result->>'bank_account_id')::uuid;

  UPDATE public.payment_methods SET bank_account_id = NULL WHERE id IN (v_pm_card, v_pm_wallet, v_pm_check);
  UPDATE public.bank_accounts SET is_active = FALSE WHERE id = v_bank_stale;

  SELECT bank_account_id INTO v_bank_account_id FROM public.payment_methods WHERE id = v_pm_transfer;
  IF v_bank_account_id <> v_bank_stale THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FIXTURE FAILED: transfer debía apuntar al banco stale (%), quedó en %.', v_bank_stale, v_bank_account_id;
  END IF;

  -- Reconfirmar precondición de (1): 0 bancos ACTIVOS en este punto.
  SELECT COUNT(*) INTO v_count FROM public.bank_accounts WHERE account_id = v_account_id AND is_active AND deleted_at IS NULL;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FIXTURE FAILED: esperaba 0 bancos activos antes de (1), hay %.', v_count;
  END IF;

  -- ═══════════════ (1) Crear el 1er banco ACTIVO asigna lo que falta ═══════
  SELECT public.rpc_create_bank_account(p_name => '__gate_bdd_bank_1__') INTO v_result;
  v_bank_1 := (v_result->>'bank_account_id')::uuid;

  -- card/wallet/check estaban sin destino → ahora apuntan a v_bank_1.
  PERFORM 1 FROM public.payment_methods WHERE id = v_pm_card   AND bank_account_id = v_bank_1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (1-card): esperaba bank_account_id = % (único banco activo), no se asignó.', v_bank_1;
  END IF;
  PERFORM 1 FROM public.payment_methods WHERE id = v_pm_wallet AND bank_account_id = v_bank_1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (1-wallet): esperaba bank_account_id = %, no se asignó.', v_bank_1;
  END IF;
  PERFORM 1 FROM public.payment_methods WHERE id = v_pm_check  AND bank_account_id = v_bank_1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (1-check): esperaba bank_account_id = %, no se asignó.', v_bank_1;
  END IF;

  -- transfer YA tenía destino (el banco stale, ahora inactivo) → NO se toca.
  SELECT bank_account_id INTO v_bank_account_id FROM public.payment_methods WHERE id = v_pm_transfer;
  IF v_bank_account_id IS DISTINCT FROM v_bank_stale THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (1-transfer-no-touch): transfer ya tenía destino (%) — no debía reasignarse, quedó en %.', v_bank_stale, v_bank_account_id;
  END IF;

  -- cash/credit/other no son bancarios → jamás se tocan.
  PERFORM 1 FROM public.payment_methods WHERE id IN (v_pm_cash, v_pm_credit, v_pm_other) AND bank_account_id IS NOT NULL;
  IF FOUND THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (1-no-bancarios): cash/credit/other no debían tener bank_account_id asignado.';
  END IF;

  RAISE NOTICE 'PASS (1): crear el único banco activo asigna transfer/card/wallet/check sin destino a él, preserva el destino ya existente (transfer→stale) y nunca toca cash/credit/other.';

  -- ═══════════════ (2) Idempotencia por-cuenta: reinvocar el helper ════════
  SELECT public._pay_assign_default_bank_destination(v_account_id) INTO v_count;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (2-idempotencia): reinvocar el helper con el mismo estado (1 banco activo, nada pendiente) debía devolver 0, devolvió %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (2): reinvocar el helper sin nada pendiente por asignar es un no-op (0 filas) — reaplicar la migración no duplica ni pisa.';

  -- ═══════════════ (3) Crear el 2º banco activo no cambia nada ═════════════
  SELECT public.rpc_create_bank_account(p_name => '__gate_bdd_bank_2__') INTO v_result;
  v_bank_2 := (v_result->>'bank_account_id')::uuid;

  PERFORM 1 FROM public.payment_methods WHERE id = v_pm_card   AND bank_account_id = v_bank_1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (3): crear un 2º banco activo NO debía cambiar el destino de card (seguía en %), con 2+ bancos no se adivina.', v_bank_1;
  END IF;
  PERFORM 1 FROM public.payment_methods WHERE id = v_pm_transfer AND bank_account_id = v_bank_stale;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (3-transfer): crear un 2º banco activo NO debía tocar el destino ya asignado de transfer.';
  END IF;
  RAISE NOTICE 'PASS (3): con 2 bancos activos, crear el 2º no reasigna ninguna forma de pago existente.';

  -- ═══════════════ (4) El helper con 2 bancos activos devuelve 0 ══════════
  SELECT public._pay_assign_default_bank_destination(v_account_id) INTO v_count;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE BANK-DEFAULT-DESTINATION FAILED (4): con 2 bancos activos el helper debía devolver 0 (no adivinar), devolvió %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (4): con 2 bancos activos el helper no asigna nada (no adivina).';

  RAISE NOTICE 'GATE BANK-DEFAULT-DESTINATION: todos los checks PASS (resolved=%).', v_resolved;
END $$;


-- ── Cleanup (molde test_receivables_aging_fifo.sql — deja la DB como estaba) ─
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('bank-default-destination-gate@test.local');

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.bank_movements WHERE bank_account_id IN (SELECT id FROM public.bank_accounts WHERE account_id = ANY(v_accounts));
    DELETE FROM public.bank_accounts  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payment_methods WHERE account_id = ANY(v_accounts);
    DELETE FROM public.product_categories WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = ANY(v_users);
  DELETE FROM public.email_logs WHERE user_id = ANY(v_users) OR recipient IN ('bank-default-destination-gate@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE BANK-DEFAULT-DESTINATION: cleanup completo.';
END $$;
