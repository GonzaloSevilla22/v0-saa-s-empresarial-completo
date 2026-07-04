-- =============================================================================
-- MIGRATION: 20260804000008_fix_bank_payment_routing_gate_cleanup.sql
-- FIX FOR:   20260804000007_bank_payment_routing.sql (C2 BankReconciliation)
--
-- BUG (found 2026-07-04, CI gate audit): el DO-block final de
-- 20260804000007 crea un anchor sintético (auth.users con email
-- 'bank-payment-routing-gate@test.local' + su cuenta + clients + suppliers)
-- para correr los gates de comportamiento en DB vacía (CI). Su limpieza
-- final (líneas ~1424-1437 de esa migración) intenta:
--
--   DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
--   DELETE FROM public.profiles WHERE id = v_fake_user_id;
--   ...
--   DELETE FROM auth.users WHERE id = v_fake_user_id;
--
-- Pero DELETE FROM accounts corre ANTES que exista ningún DELETE de
-- clients/suppliers/bank_accounts. clients.account_id y suppliers.account_id
-- son FKs SIN ON DELETE CASCADE hacia accounts(id) (ver
-- 20260606000003_account_id_columns.sql:32-33 y
-- 20260613000002_v20_suppliers_account_id.sql:15-16). El DELETE de accounts
-- lanza foreign_key_violation, cae en el "WHEN OTHERS" de la limpieza
-- (RAISE NOTICE 'limpieza parcial...') y se traga el error SIN abortar la
-- migración. Resultado: en todo reset limpio (= lo que hace CI
-- validate-kpis desde DB vacía) queda 1 fila huérfana en public.accounts
-- (+ su clients/suppliers/bank_accounts dependientes) para siempre.
--
-- IMPACTO: todas las migraciones posteriores que usan el mismo patrón de
-- discriminador test-vs-prod (`SELECT (COUNT(*) = 0) FROM public.accounts`)
-- para decidir si corren sus gates de comportamiento ven accounts NO vacía
-- y SALTEAN esos gates en silencio — nunca corrieron en CI:
--   20260806000001_v3_snapshot_pattern.sql
--   20260807000001_v3_document_status_history.sql
--   20260808000001_v3_notifications_realtime.sql
--   20260809000001_branch_min_stock_realign.sql
--
-- POR QUÉ ESTA MIGRACIÓN VA INTERCALADA (timestamp 20260804000008) Y NO AL
-- FINAL DE LA SECUENCIA: una limpieza fechada después de 20260809000001
-- correría DESPUÉS de las migraciones cuyos gates queremos revivir — el
-- huérfano ya habría saboteado sus gates para ese momento. Debe ejecutarse
-- ANTES de 20260805000001_bank_reconciliation.sql (el siguiente archivo en
-- la secuencia) para que TODAS las migraciones posteriores vean accounts
-- vacía otra vez. Timestamp 20260804000008 confirmado libre por `ls
-- supabase/migrations | sort` (existen ...0007, el siguiente en la
-- secuencia real es 20260805000001).
--
-- NUNCA editar 20260804000007 — ya está aplicada y registrada en prod
-- (modificar una migración ya aplicada desincroniza supabase_migrations.schema_migrations).
--
-- COMPORTAMIENTO EN PROD: no-op garantizado. El email
-- 'bank-payment-routing-gate@test.local' nunca existió en prod (los gates
-- de comportamiento de 20260804000007 solo corren si accounts está vacía
-- al momento del push, y prod nunca tuvo accounts vacía). Este DO-block
-- resuelve el anchor por email; si no existe, no hace nada.
--
-- PATRÓN PARA FUTUROS GATES (lección de este bug): limpieza de anchors
-- sintéticos SIEMPRE en orden hijo→padre (dependientes antes que accounts),
-- y resolver TODAS las cuentas asociadas al user sintético — no solo la
-- creada a mano por el propio gate, sino también la AUTO-CREADA por el
-- trigger handle_new_user al insertar en auth.users (mismo patrón de
-- resolución ya usado en 20260805000001_bank_reconciliation.sql: leer
-- account_id vía account_members por user_id, con fallback a
-- accounts.owner_user_id).
-- =============================================================================

DO $$
DECLARE
  v_fake_user_id     uuid;
  v_account_ids      uuid[];
  v_orphans_before   int;
  v_orphans_after    int;
BEGIN
  -- Resolver el user sintético por email (puede no existir — no-op en prod
  -- y en cualquier entorno donde el gate de 20260804000007 nunca se disparó).
  SELECT id INTO v_fake_user_id
  FROM auth.users
  WHERE email = 'bank-payment-routing-gate@test.local';

  IF v_fake_user_id IS NULL THEN
    RAISE NOTICE 'bank-payment-routing-gate-cleanup: anchor no presente, no-op (email no encontrado)';
    RETURN;
  END IF;

  -- Resolver TODAS las cuentas asociadas al user sintético:
  --   (a) la/s auto-creada/s por el trigger handle_new_user (via account_members)
  --   (b) cualquier cuenta creada a mano cuyo owner_user_id sea el user sintético
  --       (fallback del propio gate cuando el trigger no corrió)
  -- Unión de ambas fuentes — puede haber más de una cuenta si el gate corrió
  -- más de una vez sin limpiar (justamente el escenario que estamos arreglando).
  SELECT COALESCE(array_agg(DISTINCT acc_id), ARRAY[]::uuid[])
  INTO v_account_ids
  FROM (
    SELECT am.account_id AS acc_id
    FROM public.account_members am
    WHERE am.user_id = v_fake_user_id
    UNION
    SELECT a.id AS acc_id
    FROM public.accounts a
    WHERE a.owner_user_id = v_fake_user_id
  ) all_accounts;

  SELECT COUNT(*) INTO v_orphans_before FROM public.accounts;

  BEGIN
    -- ── Limpieza hijo→padre (best-effort, idempotente) ────────────────────
    -- Neutralizar cualquier JWT simulado que haya quedado seteado por el
    -- DO-block anterior en esta misma sesión de migración.
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);

    IF array_length(v_account_ids, 1) IS NOT NULL THEN
      -- Hijos directos de accounts sin ON DELETE CASCADE (la causa raíz del bug):
      DELETE FROM public.clients   WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.suppliers WHERE account_id = ANY (v_account_ids);

      -- Resto de dependientes del anchor de 20260804000007. bank_accounts,
      -- customer_accounts, supplier_accounts, branches, sales_orders y sus
      -- descendientes (payments_received/made, *_movements, bank_movements,
      -- journal_entries/lines vía events) SÍ tienen ON DELETE CASCADE desde
      -- accounts — se limpian solos al borrar accounts. Los dejamos explícitos
      -- igual por defensividad (no-op si CASCADE ya los limpió).
      DELETE FROM public.bank_accounts WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.branches      WHERE account_id = ANY (v_account_ids);

      -- companies sintética creada por el gate para satisfacer suppliers.company_id
      -- (legacy NOT NULL). Se identifica por nombre — mismo string que el gate usa.
      DELETE FROM public.companies
      WHERE name = 'Company Test C2 (bank-payment-routing gate)';

      DELETE FROM public.accounts WHERE id = ANY (v_account_ids);
    END IF;

    DELETE FROM public.account_members       WHERE user_id = v_fake_user_id;
    DELETE FROM public.profiles              WHERE id = v_fake_user_id;
    DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
    DELETE FROM auth.users                   WHERE id = v_fake_user_id;

  EXCEPTION
    WHEN OTHERS THEN
      RAISE EXCEPTION
        'bank-payment-routing-gate-cleanup: FALLÓ la limpieza del anchor huérfano (%). '
        'Esto es justamente lo que este fix debía resolver — revisar orden hijo->padre.',
        SQLERRM;
  END;

  SELECT COUNT(*) INTO v_orphans_after FROM public.accounts;

  IF v_orphans_after > 0 THEN
    RAISE NOTICE 'bank-payment-routing-gate-cleanup: limpieza aplicada. accounts antes=%, después=% (pueden quedar cuentas legítimas de otros gates/datos reales)',
      v_orphans_before, v_orphans_after;
  ELSE
    RAISE NOTICE 'bank-payment-routing-gate-cleanup: OK — 0 filas huérfanas restantes en public.accounts';
  END IF;

  -- Verificación final: el anchor específico de este bug ya no existe.
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'bank-payment-routing-gate@test.local') THEN
    RAISE EXCEPTION 'bank-payment-routing-gate-cleanup: el anchor sigue presente tras la limpieza — revisar';
  END IF;

  RAISE NOTICE 'bank-payment-routing-gate-cleanup: anchor bank-payment-routing-gate@test.local eliminado correctamente';
END $$;
