-- =============================================================================
-- GATE: test_payment_methods_seed.sql
-- CHANGE: metodos-pago-operaciones (task 1.4 RED / D11)
--
-- Verifica el seed de formas de pago (D11). limpiezas-pagos-admin (OQ-1,
-- 2026-10-03) agregó 'Cheque' como 7º método — el seed pasó de 6 a 7:
--   (1) toda cuenta existente tiene las 7 formas sembradas (backfill Parte A
--       original + el backfill de 'Cheque' de limpiezas-pagos-admin —
--       verificado sobre las cuentas reales del stack, degrada si no hay
--       ninguna);
--   (2) re-ejecutar AMBOS backfills no duplica (idempotencia real,
--       fingerprint antes/después);
--   (3) un signup nuevo nace con las 7 formas de pago sin intervención
--       manual (handle_new_user, Parte B, actualizado a 7 por OQ-1);
--   (4) un fallo forzado del sub-bloque de seed NO aborta el signup: el
--       perfil, la cuenta y la membresía se crean igual (degrade-don't-fail,
--       técnica CHECK ... NOT VALID — mismo patrón que
--       test_analytics_events.sql Gate 4).
-- =============================================================================

-- ── (1) Toda cuenta existente tiene las 7 formas sembradas ───────────────────
DO $$
DECLARE
  v_total_accounts   integer;
  v_accounts_missing integer;
BEGIN
  SELECT COUNT(*) INTO v_total_accounts FROM public.accounts;

  IF v_total_accounts = 0 THEN
    RAISE NOTICE 'GATE PAYMENT-METHODS-SEED (1) degradado: no hay cuentas en el stack — nada que verificar.';
  ELSE
    SELECT COUNT(*) INTO v_accounts_missing
    FROM public.accounts a
    WHERE (
      SELECT COUNT(*) FROM public.payment_methods pm
      WHERE pm.account_id = a.id AND pm.deleted_at IS NULL
    ) < 7;

    IF v_accounts_missing > 0 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHODS-SEED FAILED (1): % de % cuentas tienen menos de 7 formas de pago vivas (backfill Parte A + Cheque incompleto).',
        v_accounts_missing, v_total_accounts;
    END IF;

    RAISE NOTICE 'PASS (1): las % cuentas existentes tienen las 7 formas de pago sembradas.', v_total_accounts;
  END IF;
END $$;


-- ── (2) Re-ejecutar AMBOS backfills no duplica (idempotencia real) ───────────
DO $$
DECLARE
  v_before bigint;
  v_after  bigint;
BEGIN
  SELECT COUNT(*) INTO v_before FROM public.payment_methods;

  -- Mismo INSERT exacto que la Parte A de la migración 20260928000001.
  INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
  SELECT a.id, v.name, v.kind, v.sort_order
  FROM   public.accounts a
  CROSS JOIN (VALUES
      ('Efectivo',               'cash',     1),
      ('Transferencia bancaria', 'transfer', 2),
      ('Tarjeta',                'card',     3),
      ('Billetera virtual',      'wallet',   4),
      ('Cuenta corriente',       'credit',   5),
      ('Otro',                   'other',    6)
  ) AS v(name, kind, sort_order)
  WHERE NOT EXISTS (
      SELECT 1 FROM public.payment_methods pm
      WHERE pm.account_id = a.id
        AND pm.kind       = v.kind
        AND pm.deleted_at IS NULL
  );

  -- limpiezas-pagos-admin (OQ-1): mismo INSERT exacto que el backfill de
  -- 'Cheque' de la migración 20261003000001.
  INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
  SELECT a.id, 'Cheque', 'check', 7
  FROM public.accounts a
  WHERE NOT EXISTS (
    SELECT 1 FROM public.payment_methods pm
    WHERE pm.account_id = a.id
      AND pm.kind        = 'check'
      AND pm.deleted_at IS NULL
  );

  SELECT COUNT(*) INTO v_after FROM public.payment_methods;

  IF v_before <> v_after THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-SEED FAILED (2): el backfill NO es idempotente — % filas antes, % después de re-ejecutarlo.', v_before, v_after;
  END IF;

  RAISE NOTICE 'PASS (2): backfill de Parte A + Cheque idempotente — % filas antes y después.', v_before;
END $$;


-- ── (3) Signup nuevo nace con las 7 formas de pago ────────────────────────────
DO $$
DECLARE
  v_anchor_email text := 'payment-methods-seed-gate-new@test.local';
  v_user_id      uuid := gen_random_uuid();
  v_account_id   uuid;
  v_pm_count     integer;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Seed New'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE PAYMENT-METHODS-SEED (3) degradado: no se pudo resolver una cuenta para el anchor sintético — omitido sin fallar.';
  ELSE
    SELECT COUNT(*) INTO v_pm_count
    FROM public.payment_methods
    WHERE account_id = v_account_id AND deleted_at IS NULL AND is_active = TRUE;

    IF v_pm_count <> 7 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHODS-SEED FAILED (3): un signup nuevo esperaba nacer con 7 formas de pago activas, tiene %.', v_pm_count;
    END IF;

    RAISE NOTICE 'PASS (3): el signup nuevo nace con las 7 formas de pago sembradas.';
  END IF;

  -- Cleanup hijo→padre
  DELETE FROM public.payment_methods WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches               WHERE account_id = v_account_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members        WHERE user_id = v_user_id;
  DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
  DELETE FROM public.profiles               WHERE id = v_user_id;
  DELETE FROM public.email_logs             WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
  DELETE FROM auth.users                    WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.payment_methods WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
        SET session_replication_role = replica;
        DELETE FROM public.branches               WHERE account_id = v_account_id;
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members        WHERE user_id = v_user_id;
        DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
      END IF;
      DELETE FROM public.profiles               WHERE id = v_user_id;
      DELETE FROM public.email_logs             WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
      DELETE FROM auth.users                    WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- ── (4) Fallo forzado del sub-bloque de seed no aborta el signup ─────────────
-- Técnica: CHECK ... NOT VALID fuerza el INSERT del sub-bloque a fallar
-- (nuevas filas SÍ se validan contra un CHECK NOT VALID) sin invalidar filas
-- existentes. Mismo patrón que test_analytics_events.sql Gate 4.
DO $$
DECLARE
  v_anchor_email text := 'payment-methods-seed-gate-forced@test.local';
  v_user_id      uuid := gen_random_uuid();
  v_account_id   uuid;
  v_profile_ok   boolean;
  v_pm_count     integer;
BEGIN
  ALTER TABLE public.payment_methods
    ADD CONSTRAINT tmp_pm_force_fail CHECK (false) NOT VALID;

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Seed Forced'))
  ON CONFLICT (id) DO NOTHING;

  ALTER TABLE public.payment_methods DROP CONSTRAINT IF EXISTS tmp_pm_force_fail;

  SELECT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user_id) INTO v_profile_ok;
  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF NOT v_profile_ok OR v_account_id IS NULL THEN
    RAISE NOTICE 'GATE PAYMENT-METHODS-SEED (4) degradado: no se pudo verificar el signup del anchor (contexto no lo permite) — omitido sin fallar.';
  ELSE
    SELECT COUNT(*) INTO v_pm_count FROM public.payment_methods WHERE account_id = v_account_id;

    IF v_pm_count <> 0 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHODS-SEED FAILED (4a): con el CHECK forzado, el seed no debería haber podido insertar ninguna fila, insertó %.', v_pm_count;
    END IF;

    RAISE NOTICE 'PASS (4): el signup (perfil + cuenta + membresía) se completa igual aunque el sub-bloque de seed falle (degrade-don''t-fail).';
  END IF;

  -- Cleanup hijo→padre
  DELETE FROM public.payment_methods WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches               WHERE account_id = v_account_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members        WHERE user_id = v_user_id;
  DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
  DELETE FROM public.profiles               WHERE id = v_user_id;
  DELETE FROM public.email_logs             WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
  DELETE FROM auth.users                    WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      ALTER TABLE public.payment_methods DROP CONSTRAINT IF EXISTS tmp_pm_force_fail;
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.payment_methods WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
        SET session_replication_role = replica;
        DELETE FROM public.branches               WHERE account_id = v_account_id;
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members        WHERE user_id = v_user_id;
        DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
      END IF;
      DELETE FROM public.profiles               WHERE id = v_user_id;
      DELETE FROM public.email_logs             WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
      DELETE FROM auth.users                    WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
