-- =============================================================================
-- test_idempotency.sql — Idempotency system correctness tests
--
-- Verifies:
--   1. Schema: UNIQUE(user_id, operation_kind, idempotency_key) existe.
--   2. Schema: operation_id es NOT NULL.
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

  -- ── 3. operation_id es NOT NULL ──────────────────────────────────────────────
  SELECT is_nullable INTO v_col_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name   = 'operation_idempotency'
    AND column_name  = 'operation_id';

  IF v_col_nullable IS DISTINCT FROM 'NO' THEN
    RAISE EXCEPTION 'FAIL: operation_idempotency.operation_id is nullable — replay with NULL operation_id would return corrupt result';
  END IF;
  RAISE NOTICE 'PASS: operation_id is NOT NULL';

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
    WHEN insufficient_privilege THEN v_raised := true;
    WHEN OTHERS THEN v_raised := true;
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
    WHEN insufficient_privilege THEN v_raised := true;
    WHEN OTHERS THEN v_raised := true;
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

  -- ── 13. CHECK constraint limita idempotency_key a 512 chars ─────────────────
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

  RAISE NOTICE '=== All idempotency tests passed (14/14) ===';
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
