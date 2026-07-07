-- =============================================================================
-- MIGRATION: 20260815000001_v3_api_standards.sql
-- CHANGE: v3-api-standards §4 — idempotencia de cerrar caja (migración gobernada)
--
-- WHY:
--   El estándar de plataforma V3 §6.3 exige Idempotency-Key en toda mutación
--   no-idempotente. Cerrar caja (POST /cash/sessions/{id}/close) era la única
--   mutación de este tipo sin idempotencia real: el CHECK
--   operation_idempotency_operation_kind_check en prod (gxdhpxvdjjkmxhdkkwyb)
--   NO incluye 'cash_session_close'.
--
--   Verificado con pg_get_constraintdef ANTES de escribir este archivo
--   (Lección C3 — CI no atrapa kinds faltantes porque su DB nace vacía):
--
--     CHECK ((operation_kind = ANY (ARRAY['sale'::text, 'purchase'::text,
--       'payment_received'::text, 'payment_made'::text,
--       'supplier_charge'::text, 'bank_movement'::text,
--       'event_consumer'::text, 'bank_statement_import'::text])))
--
--   Esta migración recrea el CHECK con esa unión exacta + 'cash_session_close'.
--
-- SCOPE (sign-off PO 2026-07-07): SOLO transporte + 1 kind nuevo. NO cambia
--   la lógica del arqueo, los montos, ni ninguna otra tabla. rpc_close_cash_session
--   se actualiza (en un archivo del propio backend/apply, ver design D5) para
--   registrar en operation_idempotency dentro de la MISMA transacción del
--   cierre — el patrón ya usado por rpc_register_payment_received, etc.
--
-- IDEMPOTENCIA: DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT (recreable en cada
--   reset/CI sin duplicar objetos). APPLY: npx supabase db push (NUNCA MCP
--   apply_migration — la integración GitHub de Supabase auto-aplica al
--   mergear, ANTES del db push de Actions; "Remote database is up to date"
--   en Actions después del merge es esperado, no un fallo).
-- =============================================================================

ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;

ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale',
    'purchase',
    'payment_received',
    'payment_made',
    'supplier_charge',
    'bank_movement',
    'event_consumer',
    'bank_statement_import',
    'cash_session_close'
  ]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'v3-api-standards §4: agrega cash_session_close (Idempotency-Key en cerrar '
  'caja). Preserva la unión previa verificada en prod el 2026-07-07: '
  'sale/purchase/payment_received/payment_made/supplier_charge (C-30), '
  'bank_movement (bank-account-ledger C1), event_consumer (outbox hotfix '
  '20260804000005), bank_statement_import (bank-reconciliation C3).';

-- =============================================================================
-- rpc_close_cash_session: registra idempotencia dentro de la misma transacción
-- de cierre (D5). Preserva byte-a-byte la lógica de arqueo de la versión
-- previa (20260808000002_v3_notifications_producers.sql) — solo agrega:
--   (a) el parámetro p_idempotency_key,
--   (b) el guard de replay (SELECT existente en operation_idempotency),
--   (c) el INSERT en operation_idempotency antes del RETURN.
-- Ningún cambio a los cálculos de expected_balance/difference/counted_balance.
--
-- NOTA (fix post-CI): agregar un parámetro nuevo con CREATE OR REPLACE no
-- reemplaza la función — Postgres resuelve por (nombre, tipos de args), así
-- que (uuid, numeric) y (uuid, numeric, text) quedan como DOS overloads
-- distintos y el COMMENT ON FUNCTION posterior se vuelve ambiguo (42725: se
-- detectó en el CI, la DB nace vacía con la versión previa aplicada por las
-- migraciones anteriores). Se hace DROP explícito del overload de 2
-- argumentos antes del CREATE OR REPLACE para dejar un solo overload vigente.
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_close_cash_session(uuid, numeric);

CREATE OR REPLACE FUNCTION public.rpc_close_cash_session(
  p_session_id       uuid,
  p_counted_balance  numeric,
  p_idempotency_key  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session        public.cash_sessions%ROWTYPE;
  v_account_id     uuid;
  v_sum_movements  numeric(12,2);
  v_expected       numeric(12,2);
  v_difference     numeric(12,2);
  v_close_reason   text;
  v_branch_id      uuid;
  v_existing_op    uuid;
BEGIN
  -- v3-api-standards §4 (D5): replay — misma (user_id, operation_kind, key)
  -- ya cerró esta (u otra) sesión; devolver el resultado previo sin
  -- re-ejecutar el efecto. Solo aplica si se envió una clave.
  IF p_idempotency_key IS NOT NULL THEN
    SELECT oi.operation_id INTO v_existing_op
    FROM public.operation_idempotency oi
    WHERE oi.user_id = auth.uid()
      AND oi.operation_kind = 'cash_session_close'
      AND oi.idempotency_key = p_idempotency_key;

    IF v_existing_op IS NOT NULL THEN
      SELECT cs.* INTO v_session
      FROM public.cash_sessions cs
      WHERE cs.id = v_existing_op;

      RETURN jsonb_build_object(
        'session_id',       v_session.id,
        'status',           v_session.status,
        'opening_balance',  v_session.opening_balance,
        'expected_balance', v_session.expected_balance,
        'counted_balance',  v_session.counted_balance,
        'difference',       v_session.difference,
        'closing_balance',  v_session.closing_balance
      );
    END IF;
  END IF;

  -- Cargar sesión
  SELECT cs.* INTO v_session
  FROM public.cash_sessions cs
  WHERE cs.id = p_session_id;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'session_not_open'
      USING ERRCODE = 'P0409';
  END IF;

  -- Guard: permiso de escritura
  SELECT b.account_id, b.id INTO v_account_id, v_branch_id
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = v_session.cashbox_id;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validar que esté abierta
  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'session_not_open'
      USING ERRCODE = 'P0409';
  END IF;

  -- D7: calcular expected_balance = opening_balance + Σ(cash_movements.amount)
  SELECT COALESCE(SUM(cm.amount), 0)
  INTO v_sum_movements
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_expected   := v_session.opening_balance + v_sum_movements;
  v_difference := p_counted_balance - v_expected;

  -- v3-document-status-history (D7 / RN-A5): la diferencia de arqueo ≠ 0
  -- queda descripta como reason del cierre (señal antifraude, RN-95)
  IF v_difference <> 0 THEN
    v_close_reason := format('diferencia de arqueo: %s (esperado %s, contado %s)',
                             v_difference, v_expected, p_counted_balance);
  END IF;

  -- Cerrar la sesión — materializar arqueo (D7)
  UPDATE public.cash_sessions
  SET
    status           = 'closed',
    counted_balance  = p_counted_balance,
    expected_balance = v_expected,
    difference       = v_difference,
    closing_balance  = p_counted_balance,
    closed_by        = auth.uid(),
    closed_at        = now()
  WHERE id = p_session_id;

  -- v3-document-status-history (RN-A1): cierre en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'cash_session', p_session_id, 'open', 'closed',
    auth.uid(), v_close_reason);

  -- v3-api-standards §4 (D5): registrar idempotencia en la misma transacción
  -- del cierre — mismo patrón atómico que el resto de las mutaciones (DEC-06).
  IF p_idempotency_key IS NOT NULL THEN
    INSERT INTO public.operation_idempotency
      (user_id, idempotency_key, operation_kind, operation_id)
    VALUES
      (auth.uid(), p_idempotency_key, 'cash_session_close', p_session_id);
  END IF;

  -- v3-notifications-realtime (5.1): productor de CashSessionClosed.
  -- El Consumer 4 del outbox decide si difference<>0 amerita aviso (no-op
  -- si es 0) — este producer emite SIEMPRE, el filtro vive en el consumer
  -- (_notification_from_event), igual que el resto de los productores.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'CashSessionClosed', 'CashSession', p_session_id,
    jsonb_build_object(
      'session_id', p_session_id,
      'branch_id',  v_branch_id,
      'difference', v_difference,
      'closed_by',  auth.uid()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'session_id',        p_session_id,
    'status',            'closed',
    'opening_balance',   v_session.opening_balance,
    'expected_balance',  v_expected,
    'counted_balance',   p_counted_balance,
    'difference',        v_difference,
    'closing_balance',   p_counted_balance
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_close_cash_session IS
  'C-28 + v3-document-status-history + v3-notifications-realtime + '
  'v3-api-standards §4: cierra la sesión con arqueo, registra open→closed en '
  'document_status_history (RN-A1), emite CashSessionClosed al outbox (5.1) y '
  '— si se envía p_idempotency_key — registra la operación en '
  'operation_idempotency dentro de la misma transacción (replay-safe: un '
  'segundo cierre con la misma clave devuelve el resultado del primero sin '
  're-ejecutar el efecto). p_idempotency_key es opcional (DEFAULT NULL) para '
  'no romper llamadas existentes sin clave.';
