-- =============================================================================
-- test_idempotency.sql — Idempotency system correctness tests
--
-- Verifies:
--   1. Schema: UNIQUE(user_id, operation_kind, idempotency_key) existe.
--   2. Schema: operation_id es NULLABLE (contrato post-20260804000005: los
--      marcadores del consumer del outbox insertan NULL por diseño) y ninguna
--      fila que NO sea marcador ('event_consumer') lleva operation_id NULL.
--   3. Auth: ambos RPCs rechazan llamadas sin sesión.
--   4. Guards: amount > 0 y array cap presentes en el cuerpo de ambas funciones.
--   5. Isolation: ON CONFLICT target y replay SELECT filtran por operation_kind.
--   6. Estructura: rpc_create_sale_operation y rpc_create_purchase_operation
--      existen con las firmas correctas y son SECURITY DEFINER.
--
-- Nota sobre tests de runtime (replay, double-submit, cross-user):
--   Requieren una sesión autenticada real (auth.uid() != NULL).
--   Estos tests verifican los invariants de esquema y lógica que son
--   chequeables sin sesión. Los tests de comportamiento deben correrse
--   en un entorno Supabase con usuarios de test (ver comentarios al final).
--
-- Usa RAISE EXCEPTION para que psql retorne exit code 1 en cualquier falla.
--
-- Corre en CI: KPI_Validation.yml lo ejecuta con -v ON_ERROR_STOP=1 contra la
-- DB recién construida por `supabase start` (cableado tras el H-1 del QA de
-- PR #361 — el assert de NOT NULL quedó stale porque este archivo no corría
-- en ningún lado).
-- =============================================================================

DO $$
DECLARE
  v_ok      boolean;
  v_raised  boolean;
  v_col_nullable text;
BEGIN

  -- ── 1. UNIQUE constraint incluye operation_kind ──────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_namespace n ON c.connamespace = n.oid
    WHERE n.nspname = 'public'
      AND c.conrelid = 'public.operation_idempotency'::regclass
      AND c.contype = 'u'
      AND c.conname = 'operation_idempotency_user_kind_key_unique'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: UNIQUE constraint operation_idempotency_user_kind_key_unique not found';
  END IF;
  RAISE NOTICE 'PASS: UNIQUE(user_id, operation_kind, idempotency_key) constraint exists';

  -- ── 2. El constraint viejo fue eliminado ─────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_namespace n ON c.connamespace = n.oid
    WHERE n.nspname = 'public'
      AND c.conrelid = 'public.operation_idempotency'::regclass
      AND c.conname = 'operation_idempotency_user_key_unique'
  ) INTO v_ok;

  IF v_ok THEN
    RAISE EXCEPTION 'FAIL: old UNIQUE(user_id, idempotency_key) constraint still exists — cross-kind collision possible';
  END IF;
  RAISE NOTICE 'PASS: old 2-column UNIQUE constraint removed';

  -- ── 3. operation_id es NULLABLE, con NULL solo en marcadores de consumer ─────
  -- 20260531230737 la hizo NOT NULL (las RPCs de usuario siempre insertan UUID),
  -- pero 20260804000005 revirtió a nullable A PROPÓSITO: los marcadores del
  -- consumer del outbox (operation_kind = 'event_consumer', dedupados por
  -- (event_id, consumer_type)) insertan operation_id NULL por diseño (sign-off
  -- PO en el header de esa migración). Restaurar NOT NULL rompería
  -- rpc_process_outbox_dispatch en prod. El contrato real es por-fila:
  --   operation_kind = 'event_consumer' OR operation_id IS NOT NULL
  SELECT is_nullable INTO v_col_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name   = 'operation_idempotency'
    AND column_name  = 'operation_id';

  IF v_col_nullable IS DISTINCT FROM 'YES' THEN
    RAISE EXCEPTION 'FAIL: operation_idempotency.operation_id is NOT NULL — outbox consumer markers insert NULL by design (20260804000005); NOT NULL breaks rpc_process_outbox_dispatch';
  END IF;

  SELECT NOT EXISTS (
    SELECT 1 FROM public.operation_idempotency
    WHERE operation_kind <> 'event_consumer'
      AND operation_id IS NULL
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: non-marker row(s) with operation_id NULL — replay would return corrupt {operation_id: null} result';
  END IF;
  RAISE NOTICE 'PASS: operation_id nullable, NULL only on event_consumer markers (post-20260804000005 contract)';

  -- ── 4. Ambas funciones existen y son SECURITY DEFINER ────────────────────────
  SELECT bool_and(p.prosecdef)
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname IN ('rpc_create_sale_operation', 'rpc_create_purchase_operation');

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: one or both aggregate RPCs missing or not SECURITY DEFINER';
  END IF;
  RAISE NOTICE 'PASS: both aggregate RPCs exist and are SECURITY DEFINER';

  -- ── 5. rpc_create_sale_operation rechaza llamada sin sesión ──────────────────
  v_raised := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      'test-key-no-session',
      NULL,
      CURRENT_DATE,
      'ARS',
      '[{"product_id": null, "amount": 100, "quantity": 1, "unit_id": null}]'::jsonb
    );
  EXCEPTION
    -- Solo insufficient_privilege cuenta como pass: cualquier otro error (p.ej.
    -- undefined_function por drift de firma) aborta el DO block y falla el test.
    WHEN insufficient_privilege THEN v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL: rpc_create_sale_operation did not raise for unauthenticated call';
  END IF;
  RAISE NOTICE 'PASS: rpc_create_sale_operation rejects unauthenticated call';

  -- ── 6. rpc_create_purchase_operation rechaza llamada sin sesión ──────────────
  v_raised := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      'test-key-no-session',
      CURRENT_DATE,
      'test',
      '[{"product_id": null, "amount": 100, "quantity": 1, "unit_id": null}]'::jsonb
    );
  EXCEPTION
    -- Solo insufficient_privilege cuenta como pass (ver sección 5).
    WHEN insufficient_privilege THEN v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL: rpc_create_purchase_operation did not raise for unauthenticated call';
  END IF;
  RAISE NOTICE 'PASS: rpc_create_purchase_operation rejects unauthenticated call';

  -- ── 7. amount > 0 guard presente en rpc_create_sale_operation ────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_create_sale_operation'
      AND p.prosrc LIKE '%Amount must be greater than zero%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: rpc_create_sale_operation missing amount > 0 guard';
  END IF;
  RAISE NOTICE 'PASS: rpc_create_sale_operation has amount > 0 guard';

  -- ── 8. amount > 0 guard presente en rpc_create_purchase_operation ────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_create_purchase_operation'
      AND p.prosrc LIKE '%Amount must be greater than zero%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: rpc_create_purchase_operation missing amount > 0 guard';
  END IF;
  RAISE NOTICE 'PASS: rpc_create_purchase_operation has amount > 0 guard';

  -- ── 9. Array cap (500 items) presente en ambos RPCs ──────────────────────────
  SELECT bool_and(p.prosrc LIKE '%Too many items in a single operation%')
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname IN ('rpc_create_sale_operation', 'rpc_create_purchase_operation');

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: one or both RPCs missing 500-item cap guard';
  END IF;
  RAISE NOTICE 'PASS: both RPCs have 500-item array cap';

  -- ── 10. Replay SELECT filtra por operation_kind = sale ───────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_create_sale_operation'
      AND p.prosrc LIKE '%operation_kind = ''sale''%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: rpc_create_sale_operation replay SELECT missing operation_kind = ''sale'' filter — cross-kind replay possible';
  END IF;
  RAISE NOTICE 'PASS: rpc_create_sale_operation replay filters by operation_kind = sale';

  -- ── 11. Replay SELECT filtra por operation_kind = purchase ───────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_create_purchase_operation'
      AND p.prosrc LIKE '%operation_kind = ''purchase''%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: rpc_create_purchase_operation replay SELECT missing operation_kind = ''purchase'' filter — cross-kind replay possible';
  END IF;
  RAISE NOTICE 'PASS: rpc_create_purchase_operation replay filters by operation_kind = purchase';

  -- ── 12. ON CONFLICT target actualizado en ambos RPCs ────────────────────────
  SELECT bool_and(
    p.prosrc LIKE '%ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING%'
  )
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname IN ('rpc_create_sale_operation', 'rpc_create_purchase_operation');

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: one or both RPCs still using old 2-column ON CONFLICT target';
  END IF;
  RAISE NOTICE 'PASS: both RPCs use ON CONFLICT (user_id, operation_kind, idempotency_key)';

  -- ── 13. RLS habilitado en operation_idempotency ───────────────────────────────
  SELECT relrowsecurity INTO v_ok
  FROM pg_class
  WHERE oid = 'public.operation_idempotency'::regclass;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: RLS not enabled on operation_idempotency — users could read each other''s keys';
  END IF;
  RAISE NOTICE 'PASS: RLS enabled on operation_idempotency';

  -- ── 14. CHECK constraint limita idempotency_key a 512 chars ─────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_namespace n ON c.connamespace = n.oid
    WHERE n.nspname = 'public'
      AND c.conrelid = 'public.operation_idempotency'::regclass
      AND c.contype = 'c'
      AND c.conname = 'operation_idempotency_key_length'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: CHECK constraint operation_idempotency_key_length not found — unbounded key allows DoS';
  END IF;
  RAISE NOTICE 'PASS: idempotency_key bounded to 512 chars';

  -- ── 15. CHECK del contrato por-fila de operation_id (H-1, 20260906000001) ───
  -- El invariante que el assert 3 chequea sobre DATOS queda además garantizado
  -- por la DB: operation_kind IN ('event_consumer', 'subscription_webhook')
  -- OR operation_id IS NOT NULL.
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.operation_idempotency'::regclass
      AND conname  = 'operation_idempotency_operation_id_contract'
      AND contype  = 'c'
      AND convalidated
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: CHECK operation_idempotency_operation_id_contract missing or NOT VALID — per-row contract only enforced by this test, not by the DB';
  END IF;
  RAISE NOTICE 'PASS: per-row operation_id contract enforced by validated CHECK constraint';

  -- ── 15b. subscription_webhook exento del contrato por-fila (hotfix
  --         20261027000001, incidente 2026-09-04) ───────────────────────────
  -- Una notificación de webhook de suscripción no es una operación del
  -- dominio con fila propia que referenciar — misma razón que event_consumer
  -- ya estaba exento. Sin esto, TODA notificación de MercadoPago de
  -- suscripción muere con 23514 → 422 (ver backend/core/errors.py).
  SELECT pg_get_constraintdef(oid) LIKE '%subscription_webhook%'
     AND pg_get_constraintdef(oid) LIKE '%event_consumer%'
  INTO v_ok
  FROM pg_constraint
  WHERE conrelid = 'public.operation_idempotency'::regclass
    AND conname  = 'operation_idempotency_operation_id_contract';

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: operation_idempotency_operation_id_contract does not exempt subscription_webhook (alongside event_consumer) — every MercadoPago subscription webhook notification dies with 23514/422 (incident 2026-09-04)';
  END IF;
  RAISE NOTICE 'PASS: per-row operation_id contract exempts subscription_webhook alongside event_consumer';

  -- ── 16. 'credit_note' presente en el CHECK de operation_kind ────────────────
  -- 20260803000003 creó rpc_issue_credit_note insertando kind 'credit_note'
  -- pero nunca lo agregó al CHECK: toda emisión de NC moría con 23514
  -- (Lección C3: la DB de CI nace vacía y no atrapa kinds faltantes).
  SELECT pg_get_constraintdef(oid) LIKE '%credit_note%' INTO v_ok
  FROM pg_constraint
  WHERE conrelid = 'public.operation_idempotency'::regclass
    AND conname  = 'operation_idempotency_operation_kind_check';

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: operation_kind CHECK does not allow ''credit_note'' — rpc_issue_credit_note inserts that kind and would die with 23514';
  END IF;
  RAISE NOTICE 'PASS: operation_kind CHECK includes credit_note';

  -- ── 17. rpc_issue_credit_note usa el conflict target de 3 columnas ──────────
  -- Nació (20260803000003) con ON CONFLICT (user_id, idempotency_key): ese
  -- UNIQUE de 2 columnas fue eliminado en 20260531230737, así que CADA llamada
  -- fallaba con 42P10 antes de hacer nada. El replay SELECT además debe filtrar
  -- por operation_kind (aislamiento cross-kind, igual que sale/purchase).
  SELECT p.prosrc LIKE '%ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING%'
     AND p.prosrc LIKE '%operation_kind = ''credit_note''%'
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname = 'rpc_issue_credit_note';

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: rpc_issue_credit_note still uses the dropped 2-column ON CONFLICT target (42P10 on every call) or replay SELECT lacks operation_kind filter';
  END IF;
  RAISE NOTICE 'PASS: rpc_issue_credit_note uses 3-column conflict target and kind-filtered replay';

  RAISE NOTICE '=== All idempotency tests passed (18/18) ===';
END;
$$;

-- =============================================================================
-- Tests de runtime que requieren sesión autenticada
-- (no corren en CI sin setup de usuarios de test)
--
-- TEST A — Replay: misma key, mismo kind → segunda llamada retorna replayed=true
--   CALL rpc_create_sale_operation('key-A', null, now()::date, 'ARS', '[...]');
--   -- segunda llamada con la misma key:
--   result := rpc_create_sale_operation('key-A', null, now()::date, 'ARS', '[...]');
--   ASSERT result->>'replayed' = 'true';
--   ASSERT (SELECT COUNT(*) FROM sales WHERE operation_id = result->>'operation_id') = 1;
--
-- TEST B — Cross-kind isolation: sale key no bloquea purchase con mismo UUID
--   CALL rpc_create_sale_operation('key-B', ...);
--   result := rpc_create_purchase_operation('key-B', ...);  -- debe crear nueva compra
--   ASSERT result->>'replayed' = 'false';
--
-- TEST C — Cross-user isolation: user A y user B pueden usar el mismo UUID
--   -- Como user A: CALL rpc_create_sale_operation('key-C', ...);
--   -- Como user B: result := rpc_create_sale_operation('key-C', ...);
--   ASSERT result->>'replayed' = 'false';  -- B crea su propia venta
--
-- TEST D — amount = 0 rechazado
--   BEGIN; CALL rpc_create_sale_operation('key-D', null, now()::date, 'ARS',
--     '[{"product_id":null,"amount":0,"quantity":1,"unit_id":null}]');
--   -- esperar SQLSTATE P400
--   ROLLBACK;
-- =============================================================================
