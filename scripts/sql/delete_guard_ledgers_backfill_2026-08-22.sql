-- =============================================================================
-- delete-guard-ledgers — reparación histórica (tasks 10.1-10.8)
-- =============================================================================
--
-- Repara el daño histórico medido en prod (gxdhpxvdjjkmxhdkkwyb) por el bug
-- que este change cierra: borrar una operación con dinero posteado no
-- compensaba ningún libro. Firmado por el PO 2026-08-22 (OQ-4/OQ-5: SÍ).
--
-- REQUIERE que la migración 20261005000001_delete_guard_ledgers.sql YA esté
-- aplicada en prod (siembra la transición sales_order confirmed→canceled y
-- amplía cash_movements.movement_type con sale_reversal) — ejecutar SOLO
-- post-merge de la PR de apply.
--
-- Conteos re-medidos en prod inmediatamente antes de escribir este script
-- (2026-08-22, vía MCP execute_sql SOLO SELECT — coinciden con design.md,
-- salvo banco: el barrido de una sola convención daba 2 falsos positivos,
-- resueltos como legítimos al chequear la segunda convención — 0 huérfanos
-- reales confirmado, igual que design.md):
--   - Caja: 2 movimientos huérfanos ($2.600 + $5.400 = $8.000), sesión
--     85fc6698-d9da-47c9-bc9c-cdb344e050e0, todavía abierta.
--   - Contable: 10 asientos posteados sin operación viva — 3 SaleOperation
--     + 3 SalesOrder + 4 Purchase.
--   - sales_orders colgadas: 3 (las mismas 3 de la convención SalesOrder).
--   - Cuenta corriente: 1 huérfano (fantasma de Camila, $75.150) — YA
--     compensado a mano el 2026-08-21 con un movimiento 'adjustment'
--     (id 99ee6816-946d-4992-9793-59b1f5df8b3e). EXCLUIDO de este script —
--     el filtro es "no tocar customer_account_movements en absoluto" (D9,
--     task 10.6). Su asiento contable SÍ se repara más abajo (es un libro
--     distinto, no fue tocado por el ajuste manual).
--   - Banco: 0 huérfanos reales — no se escribe nada (task 10.7).
--
-- Mecanismo (D9): la caja escribe DIRECTO (auth.uid() es NULL en un script
-- sin sesión de usuario, y created_by es NOT NULL en el ledger — se hereda
-- del movimiento original, mismo patrón que el ajuste manual de Camila). El
-- contable va vía EVENTO al consumidor real (_journal_post_from_event a
-- través de rpc_process_outbox_dispatch) — mismo camino que un borrado en
-- vivo, igual que el backfill de #431/#433 de asiento-venta-formulario.
--
-- Idempotente: cada INSERT/UPDATE está gateado por NOT EXISTS / status
-- actual — una segunda ejecución no debe escribir nada (re-ejecución = 0,
-- verificado más abajo con las mismas seis consultas de auditoría).
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- 0. Gate de conteos — abortar SIN ESCRIBIR si algo drifted desde la medición
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.cash_movements
  WHERE id IN ('18ffab3e-687f-4d9e-9762-d8de2872dbc8', '56d66638-06e3-4e8c-bb65-22dafae105ef')
    AND movement_type = 'sale' AND session_id = '85fc6698-d9da-47c9-bc9c-cdb344e050e0';
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GATE ABORT (caja): esperaba 2 movimientos huérfanos verificados, hay %. No se escribe nada.', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.journal_entries
  WHERE id IN ('9794f397-3e88-45cf-81f2-a125cac389c4', '46c304c9-2d67-4cec-b9d9-7064e7163a32', '33d55c61-7026-40ed-ba11-03116e8a27ef')
    AND source_doc_type = 'SaleOperation' AND status = 'posted';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ABORT (journal SaleOperation): esperaba 3, hay %. No se escribe nada.', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.journal_entries
  WHERE id IN ('36dc9f22-d0ba-4bf9-8fd2-c67e52585634', '2f661e76-614e-46de-8f0c-3b3adf8d60d7', '0157a526-c901-40df-8674-0e534aa05e1d')
    AND source_doc_type = 'SalesOrder' AND status = 'posted';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ABORT (journal SalesOrder): esperaba 3, hay %. No se escribe nada.', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.journal_entries
  WHERE id IN ('235bd83e-5c47-47dd-bb90-650ec0c91901', '69d7766e-9114-4d95-a07c-b4f53ad32364', '058c87b8-8c34-4890-abaa-c6d394228948', '1219cee1-ce8c-4bf8-b9f4-5283c1d291d2')
    AND source_doc_type = 'Purchase' AND status = 'posted';
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'GATE ABORT (journal Purchase): esperaba 4, hay %. No se escribe nada.', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.sales_orders
  WHERE id IN ('63f5247b-3ca7-4027-8925-4617d521f06d', 'e11aed88-8906-44d8-a0f5-9dec08b3ae94', 'b79a6a7a-8f19-454f-9a3f-e6d9b11e16c5')
    AND status = 'confirmed';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ABORT (sales_orders colgadas): esperaba 3 en confirmed (o ya reparadas → 0 es el estado final esperado en un re-run, pero un run FRESCO debe ver 3), hay %. Si esto es un re-run, ignorar vía el guard de idempotencia de cada paso — este gate solo protege la primera ejecución.', v_count;
  END IF;

  -- No verificamos aquí la exclusión de Camila (customer_account_movements)
  -- porque este script NUNCA toca esa tabla — nada que gatear.

  RAISE NOTICE 'GATE OK: los 5 conteos verificados coinciden con la medición 2026-08-22.';
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Caja — compensar los 2 movimientos huérfanos en su sesión (abierta),
--    escritura directa, created_by heredado del movimiento original (D9).
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_session_id  uuid := '85fc6698-d9da-47c9-bc9c-cdb344e050e0';
  v_created_by  uuid := '08504e4f-3189-43ea-8bc2-7f683e70aaf4';
  v_prev_balance numeric;
  v_new_id      uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.cash_movements
    WHERE session_id = v_session_id AND movement_type = 'sale_reversal'
      AND reference_id = 'e11aed88-8906-44d8-a0f5-9dec08b3ae94'
  ) THEN
    SELECT cs.opening_balance + COALESCE(SUM(cm.amount), 0) INTO v_prev_balance
    FROM public.cash_sessions cs
    LEFT JOIN public.cash_movements cm ON cm.session_id = cs.id
    WHERE cs.id = v_session_id
    GROUP BY cs.opening_balance;

    INSERT INTO public.cash_movements
      (session_id, amount, movement_type, reference_id, balance_after, created_by)
    VALUES
      (v_session_id, -2600.00, 'sale_reversal', 'e11aed88-8906-44d8-a0f5-9dec08b3ae94',
       v_prev_balance - 2600.00, v_created_by)
    RETURNING id INTO v_new_id;

    RAISE NOTICE 'Caja: reversa % insertada por -2600.00 (venta e11aed88), balance_after=%.', v_new_id, v_prev_balance - 2600.00;
  ELSE
    RAISE NOTICE 'Caja: la reversa de e11aed88 ya existe (re-ejecución) — skip.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.cash_movements
    WHERE session_id = v_session_id AND movement_type = 'sale_reversal'
      AND reference_id = '63f5247b-3ca7-4027-8925-4617d521f06d'
  ) THEN
    SELECT cs.opening_balance + COALESCE(SUM(cm.amount), 0) INTO v_prev_balance
    FROM public.cash_sessions cs
    LEFT JOIN public.cash_movements cm ON cm.session_id = cs.id
    WHERE cs.id = v_session_id
    GROUP BY cs.opening_balance;

    INSERT INTO public.cash_movements
      (session_id, amount, movement_type, reference_id, balance_after, created_by)
    VALUES
      (v_session_id, -5400.00, 'sale_reversal', '63f5247b-3ca7-4027-8925-4617d521f06d',
       v_prev_balance - 5400.00, v_created_by)
    RETURNING id INTO v_new_id;

    RAISE NOTICE 'Caja: reversa % insertada por -5400.00 (venta 63f5247b), balance_after=%.', v_new_id, v_prev_balance - 5400.00;
  ELSE
    RAISE NOTICE 'Caja: la reversa de 63f5247b ya existe (re-ejecución) — skip.';
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Contable — emitir los 10 eventos de reversión, vía el consumidor REAL
--    (mismo camino que un borrado en vivo — #431/#433). posted_at de la
--    contra-entry = hoy (OQ-5, mismo criterio que CreditNoteIssued y
--    SaleOperationAdjusted: la reversión data la corrección, no el hecho
--    original).
-- ─────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- 3 × SaleOperationDeleted (convención SaleOperation)
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleOperationDeleted' AND aggregate_id = 'baedc539-9000-45b2-a321-b23f78797ac9') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('3834e5d7-f3a9-4496-8fdd-84edf8a8b252', 'SaleOperationDeleted', 'SaleOperation', 'baedc539-9000-45b2-a321-b23f78797ac9',
      jsonb_build_object('account_id', '3834e5d7-f3a9-4496-8fdd-84edf8a8b252', 'operation_id', 'baedc539-9000-45b2-a321-b23f78797ac9',
                          'sales_order_id', NULL, 'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleOperationDeleted' AND aggregate_id = 'a7710cec-9a39-4914-8c77-b6d8d72ba3c6') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('f715d4f0-eba2-42d4-bbc5-8436a4d6d394', 'SaleOperationDeleted', 'SaleOperation', 'a7710cec-9a39-4914-8c77-b6d8d72ba3c6',
      jsonb_build_object('account_id', 'f715d4f0-eba2-42d4-bbc5-8436a4d6d394', 'operation_id', 'a7710cec-9a39-4914-8c77-b6d8d72ba3c6',
                          'sales_order_id', NULL, 'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleOperationDeleted' AND aggregate_id = '81aadbf7-762a-480d-afb4-199b3143eede') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('f715d4f0-eba2-42d4-bbc5-8436a4d6d394', 'SaleOperationDeleted', 'SaleOperation', '81aadbf7-762a-480d-afb4-199b3143eede',
      jsonb_build_object('account_id', 'f715d4f0-eba2-42d4-bbc5-8436a4d6d394', 'operation_id', '81aadbf7-762a-480d-afb4-199b3143eede',
                          'sales_order_id', NULL, 'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  -- 3 × SaleOperationDeleted (convención SalesOrder — el consumidor cae al
  -- segundo lookup porque operation_id no matchea ningún asiento SaleOperation)
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleOperationDeleted' AND aggregate_id = 'e906433c-7eb3-40fb-9722-d2d32b31dabc') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('192b9efe-44f5-4882-87da-7202295c18ea', 'SaleOperationDeleted', 'SaleOperation', 'e906433c-7eb3-40fb-9722-d2d32b31dabc',
      jsonb_build_object('account_id', '192b9efe-44f5-4882-87da-7202295c18ea', 'operation_id', 'e906433c-7eb3-40fb-9722-d2d32b31dabc',
                          'sales_order_id', '63f5247b-3ca7-4027-8925-4617d521f06d', 'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleOperationDeleted' AND aggregate_id = 'f9e108f9-2c8c-4372-b8be-db635e5d2b91') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('192b9efe-44f5-4882-87da-7202295c18ea', 'SaleOperationDeleted', 'SaleOperation', 'f9e108f9-2c8c-4372-b8be-db635e5d2b91',
      jsonb_build_object('account_id', '192b9efe-44f5-4882-87da-7202295c18ea', 'operation_id', 'f9e108f9-2c8c-4372-b8be-db635e5d2b91',
                          'sales_order_id', 'e11aed88-8906-44d8-a0f5-9dec08b3ae94', 'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleOperationDeleted' AND aggregate_id = 'd1afb941-bca7-413d-8f59-daf581870ae4') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('192b9efe-44f5-4882-87da-7202295c18ea', 'SaleOperationDeleted', 'SaleOperation', 'd1afb941-bca7-413d-8f59-daf581870ae4',
      jsonb_build_object('account_id', '192b9efe-44f5-4882-87da-7202295c18ea', 'operation_id', 'd1afb941-bca7-413d-8f59-daf581870ae4',
                          'sales_order_id', 'b79a6a7a-8f19-454f-9a3f-e6d9b11e16c5', 'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  -- 4 × PurchaseDeleted
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'PurchaseDeleted' AND aggregate_id = '86b51560-79b4-40f0-a7cb-c5b500668bfa') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('3834e5d7-f3a9-4496-8fdd-84edf8a8b252', 'PurchaseDeleted', 'Purchase', '86b51560-79b4-40f0-a7cb-c5b500668bfa',
      jsonb_build_object('account_id', '3834e5d7-f3a9-4496-8fdd-84edf8a8b252', 'operation_id', '86b51560-79b4-40f0-a7cb-c5b500668bfa',
                          'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'PurchaseDeleted' AND aggregate_id = 'dfc8db58-c794-4349-9ba6-71459776c95e') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('f715d4f0-eba2-42d4-bbc5-8436a4d6d394', 'PurchaseDeleted', 'Purchase', 'dfc8db58-c794-4349-9ba6-71459776c95e',
      jsonb_build_object('account_id', 'f715d4f0-eba2-42d4-bbc5-8436a4d6d394', 'operation_id', 'dfc8db58-c794-4349-9ba6-71459776c95e',
                          'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'PurchaseDeleted' AND aggregate_id = 'b60e8be1-317a-41ec-a8b7-25f1cd6d3810') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('3834e5d7-f3a9-4496-8fdd-84edf8a8b252', 'PurchaseDeleted', 'Purchase', 'b60e8be1-317a-41ec-a8b7-25f1cd6d3810',
      jsonb_build_object('account_id', '3834e5d7-f3a9-4496-8fdd-84edf8a8b252', 'operation_id', 'b60e8be1-317a-41ec-a8b7-25f1cd6d3810',
                          'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'PurchaseDeleted' AND aggregate_id = 'bf3356aa-38c8-4ed9-bb21-89b74debecc1') THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES ('192b9efe-44f5-4882-87da-7202295c18ea', 'PurchaseDeleted', 'Purchase', 'bf3356aa-38c8-4ed9-bb21-89b74debecc1',
      jsonb_build_object('account_id', '192b9efe-44f5-4882-87da-7202295c18ea', 'operation_id', 'bf3356aa-38c8-4ed9-bb21-89b74debecc1',
                          'occurred_at', now(), 'repair', 'delete-guard-ledgers-2026-08-22'),
      now());
  END IF;

  RAISE NOTICE 'Contable: 10 eventos de reversión asegurados (insertados o ya existentes de una re-ejecución).';
END $$;

-- Despachar el outbox: procesa los 10 eventos recién insertados (y
-- cualquier otro evento legítimo que estuviera pendiente — comportamiento
-- normal del relay, sin efectos adversos).
SELECT public.rpc_process_outbox_dispatch(100) AS processed_count;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Órdenes — cancelar las 3 sales_orders colgadas, con la transición
--    registrada en el historial (D8, mismo helper que usaría un borrado en vivo).
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_system_actor uuid := '00000000-0000-0000-0000-000000000000';
  v_acct         uuid;
  v_ids          uuid[] := ARRAY[
    '63f5247b-3ca7-4027-8925-4617d521f06d',
    'e11aed88-8906-44d8-a0f5-9dec08b3ae94',
    'b79a6a7a-8f19-454f-9a3f-e6d9b11e16c5'
  ];
  v_id           uuid;
BEGIN
  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT account_id INTO v_acct FROM public.sales_orders WHERE id = v_id AND status = 'confirmed';
    IF v_acct IS NOT NULL THEN
      UPDATE public.sales_orders SET status = 'canceled', sale_operation_id = NULL WHERE id = v_id;
      PERFORM public.record_status_transition(
        v_acct, 'sales_order', v_id, 'confirmed', 'canceled', v_system_actor,
        'Reparación histórica delete-guard-ledgers 2026-08-22 — venta del POS borrada antes del guard, sin compensación en su momento.'
      );
      RAISE NOTICE 'sales_order % cancelada y desvinculada.', v_id;
    ELSE
      RAISE NOTICE 'sales_order % ya no está confirmed (re-ejecución o ya reparada) — skip.', v_id;
    END IF;
  END LOOP;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Cuenta corriente — NO SE TOCA (D9/task 10.6). El fantasma de Camila
--    (customer_account_movements, operación baedc539) ya fue compensado a
--    mano el 2026-08-21 (movimiento 'adjustment' id
--    99ee6816-946d-4992-9793-59b1f5df8b3e). Este script no escribe en
--    customer_account_movements ni en customer_accounts bajo ninguna condición.
-- ─────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Banco — NO SE TOCA (task 10.7). Verificado 2026-08-22: los 2
--    candidatos de una primera pasada de una sola convención resultaron ser
--    movimientos LEGÍTIMOS de ventas vivas referenciadas por sales_orders.id
--    (segunda convención) — 0 huérfanos reales, igual que design.md.
-- ─────────────────────────────────────────────────────────────────────────

COMMIT;

-- =============================================================================
-- 6. Post-condición — re-correr las seis consultas de auditoría (dejar el
--    resultado en el PR). Todas deben dar 0 filas (o, para cuenta corriente,
--    seguir dando exactamente 1 — el fantasma de Camila, deliberadamente sin tocar).
-- =============================================================================

-- 6a. Caja — huérfanos restantes (esperado: 0)
SELECT cm.id, cm.session_id, cm.amount, cm.movement_type, cm.reference_id
FROM public.cash_movements cm
JOIN public.cash_sessions cs ON cs.id = cm.session_id
LEFT JOIN public.sales_orders so ON so.id = cm.reference_id
LEFT JOIN public.sales s ON s.operation_id = so.sale_operation_id
WHERE cm.movement_type = 'sale'
  AND (so.id IS NULL OR so.sale_operation_id IS NULL OR s.id IS NULL);

-- 6b. Journal SaleOperation — huérfanos restantes (esperado: 0)
SELECT je.id, je.source_doc_ref, je.status
FROM public.journal_entries je
WHERE je.source_doc_type = 'SaleOperation' AND je.status = 'posted'
  AND NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.operation_id = je.source_doc_ref);

-- 6c. Journal SalesOrder — huérfanos restantes (esperado: 0)
SELECT je.id, je.source_doc_ref, je.status
FROM public.journal_entries je
LEFT JOIN public.sales_orders so ON so.id = je.source_doc_ref
LEFT JOIN public.sales s ON s.operation_id = so.sale_operation_id
WHERE je.source_doc_type = 'SalesOrder' AND je.status = 'posted'
  AND (so.id IS NULL OR so.sale_operation_id IS NULL OR s.id IS NULL);

-- 6d. Journal Purchase — huérfanos restantes (esperado: 0)
SELECT je.id, je.source_doc_ref, je.status
FROM public.journal_entries je
WHERE je.source_doc_type = 'Purchase' AND je.status = 'posted'
  AND NOT EXISTS (SELECT 1 FROM public.purchases p WHERE p.operation_id = je.source_doc_ref);

-- 6e. sales_orders colgadas restantes (esperado: 0)
SELECT so.id, so.status, so.sale_operation_id
FROM public.sales_orders so
WHERE so.status = 'confirmed' AND so.sale_operation_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.operation_id = so.sale_operation_id);

-- 6f. Cuenta corriente — sigue exactamente en 1 (Camila, sin tocar por diseño)
SELECT cam.id, cam.reference_id, cam.amount
FROM public.customer_account_movements cam
WHERE cam.movement_type = 'sale'
  AND NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.operation_id = cam.reference_id);

-- 6g. Sesión 85fc6698 — el saldo debe haber bajado exactamente $8.000
SELECT cs.id, cs.opening_balance + COALESCE(SUM(cm.amount), 0) AS current_balance
FROM public.cash_sessions cs
LEFT JOIN public.cash_movements cm ON cm.session_id = cs.id
WHERE cs.id = '85fc6698-d9da-47c9-bc9c-cdb344e050e0'
GROUP BY cs.id, cs.opening_balance;
