-- =============================================================================
-- MIGRATION: 20260806000002_fix_v3_snapshot_gate_cleanup.sql
-- FIX FOR:   20260806000001_v3_snapshot_pattern.sql (v3-snapshot-pattern)
--
-- BUG (found 2026-07-04, CI gate audit — mismo patrón que
-- 20260804000008_fix_bank_payment_routing_gate_cleanup.sql): el DO-block
-- final de comportamiento de 20260806000001 crea un anchor sintético
-- (auth.users con email 'v3-snapshot-gate@test.local' + su cuenta + branch +
-- products + clients +, vía RPCs, sales/purchases/sales_orders/etc.) para
-- correr sus gates de comportamiento en DB vacía (CI). Su limpieza final
-- (líneas ~2465-2478 de esa migración) hace:
--
--   DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
--   DELETE FROM public.profiles WHERE id = v_fake_user_id;
--   DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
--   DELETE FROM auth.users WHERE id = v_fake_user_id;
--
-- Pero DELETE FROM accounts corre ANTES que ningún DELETE de sus dependientes
-- SIN ON DELETE CASCADE. Confirmado en 20260606000003_account_id_columns.sql
-- (líneas 20-33): products.account_id, sales.account_id, purchases.account_id,
-- clients.account_id y stock_movements.account_id son FKs a accounts(id) SIN
-- CASCADE (default RESTRICT). El culpable que dispara el error es
-- products_account_id_fkey (el gate crea 2 productos), y el grafo real es
-- más profundo que el del sibling bank-payment-routing:
--
--   accounts (owner_user_id / account_members) del anchor v3-snapshot-gate:
--     - clients             (INSERT directo, gate setup)               — RESTRICT
--     - products (x2)       (INSERT directo, gate setup)                — RESTRICT
--     - branch_stock        (via c21_apply_branch_stock_delta)          — CASCADE (accounts Y products/branches)
--     - account_feature_flags (sale_items_rpc_v2)                      — CASCADE
--     - branches            (Casa Central Gate)                        — CASCADE (desde accounts)
--     - sales + sale_items + stock_movements  (gate j: rpc_create_sale_operation) — sales/stock_movements RESTRICT, sale_items CASCADE
--     - purchases                              (gate l: rpc_create_purchase_operation) — RESTRICT
--     - quotes + quote_items                   (gate m: INSERT directo)  — CASCADE
--     - sales_orders + sales_order_items        (gate m: rpc_accept_quote → _c29_confirm_order_core) — CASCADE desde accounts,
--       PERO sales_orders.branch_id es NOT NULL REFERENCES branches(id) SIN
--       CASCADE/SET NULL (ver 20260702000001_c29_quote_salesorder.sql:172) →
--       bloquea el DELETE de "branches" (que corre vía CASCADE de accounts)
--       si sales_orders no se borra ANTES.
--     - sales (fila extra, gate n: backfill idempotente) + sale_items extra — igual que arriba
--     - operation_idempotency (via rpc_create_sale_operation / rpc_accept_quote) — RESTRICT
--
-- Todo esto se traga en el "WHEN OTHERS" del cleanup original (RAISE NOTICE
-- 'limpieza parcial...') sin abortar la migración. Resultado: en todo reset
-- limpio (= lo que hace CI validate-kpis desde DB vacía) queda 1 fila
-- huérfana en public.accounts (+ dependientes) para siempre.
--
-- IMPACTO: todas las migraciones posteriores que usan el mismo patrón de
-- discriminador test-vs-prod (`SELECT (COUNT(*) = 0) FROM public.accounts`)
-- para decidir si corren sus gates de comportamiento ven accounts NO vacía
-- y SALTEAN esos gates en silencio — nunca corrieron en CI:
--   20260807000001_v3_document_status_history.sql
--   20260808000001_v3_notifications_realtime.sql
--   20260809000001_branch_min_stock_realign.sql
--
-- POR QUÉ ESTA MIGRACIÓN VA INTERCALADA (timestamp 20260806000002) Y NO AL
-- FINAL DE LA SECUENCIA: debe ejecutarse INMEDIATAMENTE DESPUÉS de
-- 20260806000001 (el archivo que crea el huérfano) y ANTES de
-- 20260807000001 (el siguiente archivo en la secuencia real), para que TODAS
-- las migraciones posteriores vean accounts vacía otra vez. Timestamp
-- 20260806000002 confirmado libre por `ls supabase/migrations | sort`
-- (existe ...0806000001, el siguiente en la secuencia real es
-- 20260807000001).
--
-- NUNCA editar 20260806000001 — ya está aplicada y registrada en prod
-- (modificar una migración ya aplicada desincroniza supabase_migrations.schema_migrations).
--
-- COMPORTAMIENTO EN PROD: no-op garantizado. El email
-- 'v3-snapshot-gate@test.local' nunca existió en prod (los gates de
-- comportamiento de 20260806000001 solo corren si accounts está vacía al
-- momento del push, y prod nunca tuvo accounts vacía). Este DO-block
-- resuelve el anchor por email; si no existe, no hace nada.
-- =============================================================================

DO $$
DECLARE
  v_fake_user_id     uuid;
  v_account_ids      uuid[];
  v_orphans_before   int;
  v_orphans_after    int;
BEGIN
  -- Resolver el user sintético por email (puede no existir — no-op en prod
  -- y en cualquier entorno donde el gate de 20260806000001 nunca se disparó).
  SELECT id INTO v_fake_user_id
  FROM auth.users
  WHERE email = 'v3-snapshot-gate@test.local';

  IF v_fake_user_id IS NULL THEN
    RAISE NOTICE 'v3-snapshot-gate-cleanup: anchor no presente, no-op (email no encontrado)';
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
    -- Neutralizar cualquier JWT simulado que haya quedado seteado por un
    -- DO-block anterior en esta misma sesión de migración.
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);

    IF array_length(v_account_ids, 1) IS NOT NULL THEN
      -- sales_orders.branch_id es NOT NULL sin CASCADE/SET NULL hacia
      -- branches(id) — debe borrarse ANTES que accounts (cuyo CASCADE
      -- borraría branches y violaría sales_orders_branch_id_fkey).
      -- sales_order_items tiene CASCADE desde sales_orders, pero lo dejamos
      -- explícito por defensividad.
      DELETE FROM public.sales_order_items WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.sales_orders      WHERE account_id = ANY (v_account_ids);

      -- Hijos directos de accounts sin ON DELETE CASCADE (la causa raíz del bug):
      DELETE FROM public.sales             WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.purchases         WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.clients           WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.products          WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.stock_movements   WHERE account_id = ANY (v_account_ids);

      -- events (outbox): sin FK a accounts (account_id es columna suelta,
      -- agregada por ADD COLUMN sin REFERENCES — ver 20260702000001 §2.1).
      -- Por eso NO bloquea el DELETE de accounts, pero si no se limpia acá
      -- queda un evento pending (processed_at IS NULL) con un account_id que
      -- ya no existe. rpc_process_outbox_dispatch (activado recién en
      -- 20260808000001_v3_notifications_realtime, Consumer 3 JournalEntry)
      -- drena TODO el backlog sin filtrar por cuenta y, al toparse con este
      -- evento huérfano (ej. PurchaseCreated del gate (l) de esta misma
      -- migración), su INSERT INTO journal_entries hereda ese account_id
      -- inexistente y viola journal_entries_account_id_fkey. Confirmado en
      -- la primera corrida real de ese gate (revivido por este mismo fix):
      -- WARNING pero no aborta (per-event EXCEPTION WHEN OTHERS en el
      -- dispatcher) — igual se limpia acá para no ensuciar el outbox de
      -- reruns futuros.
      DELETE FROM public.events            WHERE account_id = ANY (v_account_ids);

      -- Resto de dependientes del anchor de 20260806000001: branch_stock,
      -- account_feature_flags, branches, quotes, quote_items, sale_items,
      -- sales_order_items (ya borrado arriba) SÍ tienen ON DELETE CASCADE
      -- desde accounts (o transitivamente desde products/branches ya
      -- vaciados arriba) — se limpian solos al borrar accounts. Los dejamos
      -- explícitos igual por defensividad (no-op si CASCADE ya los limpió).
      DELETE FROM public.branch_stock          WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.account_feature_flags WHERE account_id = ANY (v_account_ids);
      DELETE FROM public.quotes                WHERE account_id = ANY (v_account_ids);

      DELETE FROM public.accounts WHERE id = ANY (v_account_ids);
    END IF;

    DELETE FROM public.account_members       WHERE user_id = v_fake_user_id;
    DELETE FROM public.profiles              WHERE id = v_fake_user_id;
    DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
    DELETE FROM auth.users                   WHERE id = v_fake_user_id;

  EXCEPTION
    WHEN OTHERS THEN
      RAISE EXCEPTION
        'v3-snapshot-gate-cleanup: FALLÓ la limpieza del anchor huérfano (%). '
        'Esto es justamente lo que este fix debía resolver — revisar orden hijo->padre.',
        SQLERRM;
  END;

  SELECT COUNT(*) INTO v_orphans_after FROM public.accounts;

  IF v_orphans_after > 0 THEN
    RAISE NOTICE 'v3-snapshot-gate-cleanup: limpieza aplicada. accounts antes=%, después=% (pueden quedar cuentas legítimas de otros gates/datos reales)',
      v_orphans_before, v_orphans_after;
  ELSE
    RAISE NOTICE 'v3-snapshot-gate-cleanup: OK — 0 filas huérfanas restantes en public.accounts';
  END IF;

  -- Verificación final: el anchor específico de este bug ya no existe.
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'v3-snapshot-gate@test.local') THEN
    RAISE EXCEPTION 'v3-snapshot-gate-cleanup: el anchor sigue presente tras la limpieza — revisar';
  END IF;

  RAISE NOTICE 'v3-snapshot-gate-cleanup: anchor v3-snapshot-gate@test.local eliminado correctamente';
END $$;
