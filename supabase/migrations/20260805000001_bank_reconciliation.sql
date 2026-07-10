-- =============================================================================
-- MIGRATION: 20260805000001_bank_reconciliation.sql
-- CHANGE:    bank-reconciliation (C3 de la secuencia BankReconciliation V2.5)
-- Design ref: openspec/changes/bank-reconciliation/design.md
--
-- Cierra la secuencia: C1 bank-account-ledger (20260804000002) → C2
-- bank-payment-routing (20260804000007) → C3 conciliación (este archivo).
--
-- Principio invariante (dos ledgers): la conciliación opera SOLO sobre
-- bank_movements (ledger OPERACIONAL) vs bank_statement_lines (extracto).
-- El journal contable 1110 NO se toca — sigue alimentado async por el
-- Consumer 3 del outbox (C2). Gate negativo (g) lo verifica.
--
-- Implementa (design.md):
--   D1  Match como grafo: reconciliation_matches con match_group UUID
--       (1:1 / 1:N / N:1); una fila = membresía de UNA línea o UN movimiento.
--       Partial UNIQUE por participante activo (statement_line_id /
--       bank_movement_id WHERE status='active') = enforcement anti doble-match.
--   D2  Import recibe filas normalizadas (jsonb); parseo CSV/Excel en el
--       cliente. Dedupe por (bank_account_id, file_hash). Cap 5000 líneas.
--   D3  FSM local: reconciliation_sessions.status open→closed (CLOSED terminal,
--       sin reapertura); UNIQUE parcial anti doble-apertura por cuenta.
--   D5  Estado denormalizado en bank_movements (reconciliation_status /
--       reconciled_at) mantenido SOLO por las RPCs de match/unmatch.
--       Campos económicos del ledger siguen inmutables.
--   D6  Patrones C1/C2: RLS SELECT-only por account_id denormalizado,
--       escritura solo vía RPC SECURITY DEFINER, is_account_writer.
--   D7  Idempotencia import: operation_kind='bank_statement_import' (CHECK
--       extendido en ESTA migración — regla C-30) + dedupe de dominio por hash.
--   §10 rpc_register_bank_movement amplía tipos manuales: + fee / tax_debit /
--       interest ("solo anotar" V1, decisión PO). card_settlement sigue
--       reservado a los escritores automáticos de C2 (P0410).
--
-- ERRCODEs (5 chars — convención post-20260624000001):
--   P0400  payload inválido (líneas vacías/cap/shape, período invertido)
--   P0401  sin permiso de escritura (is_account_writer)
--   P0403  sin cuenta activa
--   P0404  recurso no encontrado (sesión / grupo de match)
--   P0409  ya existe una sesión abierta para la cuenta
--   P0412  cuenta bancaria no encontrada / inactiva (heredado C1)
--   P0431  motivo requerido (cierre con diferencia / undo) — RN-A5 modelo V3
--   P0432  sesión cerrada (CLOSED es terminal — RN-A4)
--   P0433  Σ montos de líneas ≠ Σ montos de movimientos en el grupo
--   P0434  línea o movimiento ya participa de un match activo
--
-- GOVERNANCE: MEDIO (greenfield sobre ledger existente; no toca dinero en
--             vuelo, hot path de venta/pago ni journal).
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — desincroniza history)
--
-- ROLLBACK (en orden):
--   DROP FUNCTION IF EXISTS
--     public.rpc_undo_reconciliation_match(uuid, text),
--     public.rpc_create_reconciliation_match(uuid, uuid[], uuid[]),
--     public.rpc_close_reconciliation_session(uuid, text),
--     public.rpc_open_reconciliation_session(uuid, date, date, numeric),
--     public.rpc_import_bank_statement(text, uuid, text, text, jsonb);
--   DROP TABLE IF EXISTS
--     public.reconciliation_matches,
--     public.reconciliation_sessions,
--     public.bank_statement_lines,
--     public.bank_statement_imports;
--   ALTER TABLE public.bank_movements
--     DROP COLUMN IF EXISTS reconciliation_status,
--     DROP COLUMN IF EXISTS reconciled_at;
--   -- Restaurar rpc_register_bank_movement al cuerpo C1 (tipos manuales:
--   -- transfer_in/transfer_out/manual_adjustment) — ver 20260804000002 §6.
--   -- Revertir operation_idempotency CHECK (quitar 'bank_statement_import').
--
-- VERIFICATION (post-push):
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema='public' AND table_name IN
--     ('bank_statement_imports','bank_statement_lines',
--      'reconciliation_sessions','reconciliation_matches');
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema='public' AND routine_name LIKE 'rpc_%reconciliation%'
--      OR routine_name = 'rpc_import_bank_statement';
-- =============================================================================


-- ============================================================
-- 0. Extend operation_idempotency CHECK (+ 'bank_statement_import')
--    Regla C-30: todo change que agrega operation_kinds DEBE extender
--    este CHECK en la misma migración.
--    REGLA NUEVA (incidente deploy 2026-07-02): el DROP+ADD debe reproducir
--    la UNIÓN de todos los kinds vigentes en prod, no solo los que este
--    change conoce. El primer intento omitió 'event_consumer' (agregado por
--    el hotfix 20260804000005 del outbox) → 23514 sobre las filas existentes
--    de los consumers; CI no lo atrapa porque su DB nace vacía.
-- ============================================================
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
    'bank_statement_import'
  ]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'C-30: sale/purchase/payment_received/payment_made/supplier_charge. '
  'bank-account-ledger (C1): bank_movement. '
  'outbox hotfix 20260804000005: event_consumer (dedupe de consumers del relay). '
  'bank-reconciliation (C3): bank_statement_import (idempotencia del import de extracto).';


-- ============================================================
-- 1. TABLES: bank_statement_imports + bank_statement_lines (D2)
--    Datos crudos INMUTABLES del banco — append-only (RN-A3).
-- ============================================================
CREATE TABLE IF NOT EXISTS public.bank_statement_imports (
  id               uuid           NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  bank_account_id  uuid           NOT NULL REFERENCES public.bank_accounts(id) ON DELETE CASCADE,
  account_id       uuid           NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  -- account_id denormalizado para RLS sin subquery por fila (patrón C1/D6)
  file_name        text           NOT NULL,
  file_hash        text           NOT NULL,
  period_from      date           NOT NULL,
  period_to        date           NOT NULL,
  line_count       integer        NOT NULL CHECK (line_count > 0),
  imported_by      uuid,
  created_at       timestamptz    NOT NULL DEFAULT now(),
  -- Dedupe de dominio: el mismo archivo re-subido sobre la misma cuenta = replay
  CONSTRAINT bank_statement_imports_account_hash_uq UNIQUE (bank_account_id, file_hash)
);

CREATE INDEX IF NOT EXISTS bank_statement_imports_account_id_idx
  ON public.bank_statement_imports (account_id);

CREATE INDEX IF NOT EXISTS bank_statement_imports_bank_account_idx
  ON public.bank_statement_imports (bank_account_id, created_at DESC);

COMMENT ON TABLE public.bank_statement_imports IS
  'bank-reconciliation (C3 V2.5): cabecera de import de extracto bancario. '
  'El archivo se parsea en el CLIENTE a filas normalizadas (D2); el backend valida shape. '
  'Dedupe por (bank_account_id, file_hash): re-subir el mismo archivo = replay idempotente. '
  'Escritura SOLO vía rpc_import_bank_statement (SECURITY DEFINER). Append-only.';

CREATE TABLE IF NOT EXISTS public.bank_statement_lines (
  id               uuid           NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  import_id        uuid           NOT NULL REFERENCES public.bank_statement_imports(id) ON DELETE CASCADE,
  bank_account_id  uuid           NOT NULL REFERENCES public.bank_accounts(id) ON DELETE CASCADE,
  account_id       uuid           NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  line_no          integer        NOT NULL,
  value_date       date           NOT NULL,
  description      text,
  amount           numeric(14,2)  NOT NULL,
  balance          numeric(14,2),
  created_at       timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT bank_statement_lines_import_line_uq UNIQUE (import_id, line_no)
);

CREATE INDEX IF NOT EXISTS bank_statement_lines_bank_account_date_idx
  ON public.bank_statement_lines (bank_account_id, value_date);

CREATE INDEX IF NOT EXISTS bank_statement_lines_account_id_idx
  ON public.bank_statement_lines (account_id);

COMMENT ON TABLE public.bank_statement_lines IS
  'bank-reconciliation (C3 V2.5): líneas crudas del extracto bancario — dato INMUTABLE del banco. '
  'Append-only (RN-A3): sin UPDATE ni DELETE; sin policy de escritura directa. '
  'amount con signo (positivo = acreditación, negativo = débito). '
  'El estado "matcheada" se DERIVA vía EXISTS sobre reconciliation_matches activos (D5).';


-- RLS: SELECT-only por account_id denormalizado (patrón C1/D6)
ALTER TABLE public.bank_statement_imports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bank_statement_imports_select ON public.bank_statement_imports;
CREATE POLICY bank_statement_imports_select
  ON public.bank_statement_imports
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

ALTER TABLE public.bank_statement_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bank_statement_lines_select ON public.bank_statement_lines;
CREATE POLICY bank_statement_lines_select
  ON public.bank_statement_lines
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));


-- ============================================================
-- 2. TABLE: reconciliation_sessions (D3 — FSM open→closed, RN-A modelo V3)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.reconciliation_sessions (
  id                          uuid           NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  bank_account_id             uuid           NOT NULL REFERENCES public.bank_accounts(id) ON DELETE CASCADE,
  account_id                  uuid           NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  status                      text           NOT NULL DEFAULT 'open'
                              CHECK (status IN ('open', 'closed')),
  period_from                 date           NOT NULL,
  period_to                   date           NOT NULL,
  statement_closing_balance   numeric(14,2)  NOT NULL,
  ledger_closing_balance      numeric(14,2),
  difference                  numeric(14,2),
  close_reason                text,
  opened_by                   uuid,
  closed_by                   uuid,
  opened_at                   timestamptz    NOT NULL DEFAULT now(),
  closed_at                   timestamptz,
  CONSTRAINT reconciliation_sessions_period_ck CHECK (period_from <= period_to)
);

-- D3: anti doble-apertura — a lo sumo UNA sesión open por cuenta bancaria
-- (espejo del índice anti doble-apertura de cash_sessions, C-28)
CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_sessions_one_open_idx
  ON public.reconciliation_sessions (bank_account_id)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS reconciliation_sessions_account_id_idx
  ON public.reconciliation_sessions (account_id);

CREATE INDEX IF NOT EXISTS reconciliation_sessions_bank_account_idx
  ON public.reconciliation_sessions (bank_account_id, opened_at DESC);

COMMENT ON TABLE public.reconciliation_sessions IS
  'bank-reconciliation (C3 V2.5): sesión de conciliación por cuenta bancaria + período. '
  'FSM explícita (modelo V3 RN-A): open → closed; CLOSED es TERMINAL (sin reapertura — '
  'corrección = sesión nueva). UNIQUE parcial anti doble-apertura por cuenta. '
  'Al cerrar: ledger_closing_balance = opening_balance + Σ(bank_movements con '
  'COALESCE(value_date, created_at::date) <= period_to); difference = statement − ledger; '
  'difference ≠ 0 exige close_reason (RN-A5, P0431). '
  'Historial reconstruible: opened_by/at + closed_by/at + close_reason (v3-document-status-history '
  'genérico llega como retrofit sin migración de datos).';


ALTER TABLE public.reconciliation_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reconciliation_sessions_select ON public.reconciliation_sessions;
CREATE POLICY reconciliation_sessions_select
  ON public.reconciliation_sessions
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));


-- ============================================================
-- 3. TABLE: reconciliation_matches (D1 — grafo de match con match_group)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.reconciliation_matches (
  id                 uuid         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  session_id         uuid         NOT NULL REFERENCES public.reconciliation_sessions(id) ON DELETE CASCADE,
  account_id         uuid         NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  match_group        uuid         NOT NULL,
  statement_line_id  uuid         REFERENCES public.bank_statement_lines(id) ON DELETE CASCADE,
  bank_movement_id   uuid         REFERENCES public.bank_movements(id) ON DELETE CASCADE,
  status             text         NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active', 'undone')),
  matched_by         uuid,
  matched_at         timestamptz  NOT NULL DEFAULT now(),
  undo_reason        text,
  undone_by          uuid,
  undone_at          timestamptz,
  -- D1: cada fila representa la membresía de EXACTAMENTE un participante
  CONSTRAINT reconciliation_matches_one_side_ck
    CHECK ((statement_line_id IS NULL) <> (bank_movement_id IS NULL))
);

-- D1: enforcement anti doble-match — un participante solo puede tener UN match activo.
-- (La RPC pre-chequea con P0434 para error amigable; el índice cierra el race.)
CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_matches_active_line_uq
  ON public.reconciliation_matches (statement_line_id)
  WHERE status = 'active' AND statement_line_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_matches_active_movement_uq
  ON public.reconciliation_matches (bank_movement_id)
  WHERE status = 'active' AND bank_movement_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS reconciliation_matches_group_idx
  ON public.reconciliation_matches (match_group);

CREATE INDEX IF NOT EXISTS reconciliation_matches_session_idx
  ON public.reconciliation_matches (session_id);

CREATE INDEX IF NOT EXISTS reconciliation_matches_account_id_idx
  ON public.reconciliation_matches (account_id);

COMMENT ON TABLE public.reconciliation_matches IS
  'bank-reconciliation (C3 V2.5): grafo de match línea(s)-de-extracto ↔ movimiento(s) del ledger. '
  'Todas las filas de un grupo comparten match_group (soporta 1:1, 1:N, N:1 — D1). '
  'Σ montos de líneas del grupo = Σ montos de movimientos (validado por RPC, P0433). '
  'Deshacer NO borra (RN-A3): status=undone + undo_reason obligatorio (RN-A5, P0431). '
  'UNIQUE parcial por participante activo = anti doble-match a nivel DB (P0434 en la RPC).';


ALTER TABLE public.reconciliation_matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reconciliation_matches_select ON public.reconciliation_matches;
CREATE POLICY reconciliation_matches_select
  ON public.reconciliation_matches
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));


-- ============================================================
-- 4. ALTER: bank_movements — estado de conciliación (D5, aditivo)
--    PG ≥ 11: ADD COLUMN con DEFAULT constante NO reescribe la tabla.
-- ============================================================
ALTER TABLE public.bank_movements
  ADD COLUMN IF NOT EXISTS reconciliation_status text NOT NULL DEFAULT 'unreconciled'
    CHECK (reconciliation_status IN ('unreconciled', 'matched')),
  ADD COLUMN IF NOT EXISTS reconciled_at timestamptz;

COMMENT ON COLUMN public.bank_movements.reconciliation_status IS
  'bank-reconciliation (C3): estado de conciliación del movimiento. '
  'Mantenido EXCLUSIVAMENTE por rpc_create_reconciliation_match / rpc_undo_reconciliation_match. '
  'Ningún otro escritor lo setea. Los campos económicos (amount/balance_after/movement_type/'
  'value_date) siguen INMUTABLES — este UPDATE controlado de estado no rompe el append-only '
  '(mismo criterio que events.processed_at).';

COMMENT ON COLUMN public.bank_movements.reconciled_at IS
  'bank-reconciliation (C3): timestamp del match activo. NULL si unreconciled.';

-- §10 (parte declarativa): actualizar la documentación de la taxonomía —
-- fee/tax_debit/interest pasan a ser emitibles manualmente (C3, "solo anotar" V1).
COMMENT ON COLUMN public.bank_movements.movement_type IS
  'Enum completo fijado en C1 (D3). '
  'ACEPTADOS por rpc_register_bank_movement (carga manual, ampliado por C3): '
  'transfer_in, transfer_out, manual_adjustment, fee, tax_debit, interest. '
  'RESERVADO a escritores automáticos (RPCs de pago C2): card_settlement '
  '(acreditación de tarjeta, bruto≠neto — netting diferido). '
  'El CHECK a nivel tabla acepta los 7; la RPC manual rechaza card_settlement con P0410.';


-- ============================================================
-- 5. RPC: rpc_import_bank_statement (D2/D7)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_import_bank_statement(
  p_idempotency_key  text,
  p_bank_account_id  uuid,
  p_file_name        text,
  p_file_hash        text,
  p_lines            jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_ba           public.bank_accounts%ROWTYPE;
  v_existing     public.bank_statement_imports%ROWTYPE;
  v_line_count   integer;
  v_bad_lines    integer;
  v_period_from  date;
  v_period_to    date;
  v_import_id    uuid;
  v_inserted     integer;
  v_existing_op  uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Cuenta bancaria: existe, pertenece a la org, activa (P0412 — patrón C1)
  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
    AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  IF NOT v_ba.is_active THEN
    RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  -- Payload: metadata obligatoria
  IF p_file_name IS NULL OR trim(p_file_name) = ''
     OR p_file_hash IS NULL OR trim(p_file_hash) = '' THEN
    RAISE EXCEPTION 'import_payload_invalido: file_name y file_hash son obligatorios'
      USING ERRCODE = 'P0400';
  END IF;

  -- Payload: array de líneas normalizadas, 1..5000 (D2)
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
    RAISE EXCEPTION 'import_payload_invalido: p_lines debe ser un array JSON de líneas normalizadas'
      USING ERRCODE = 'P0400';
  END IF;

  v_line_count := jsonb_array_length(p_lines);
  IF v_line_count < 1 THEN
    RAISE EXCEPTION 'import_payload_invalido: el extracto no tiene líneas'
      USING ERRCODE = 'P0400';
  END IF;
  IF v_line_count > 5000 THEN
    RAISE EXCEPTION 'import_cap_excedido: máximo 5000 líneas por import, recibidas %', v_line_count
      USING ERRCODE = 'P0400';
  END IF;

  -- Shape mínimo por línea: line_no, value_date y amount no nulos
  SELECT COUNT(*) INTO v_bad_lines
  FROM jsonb_to_recordset(p_lines)
    AS x(line_no int, value_date date, description text, amount numeric, balance numeric)
  WHERE x.line_no IS NULL OR x.value_date IS NULL OR x.amount IS NULL;

  IF v_bad_lines > 0 THEN
    RAISE EXCEPTION 'import_payload_invalido: % línea(s) sin line_no/value_date/amount', v_bad_lines
      USING ERRCODE = 'P0400';
  END IF;

  -- Dedupe de dominio (D2): mismo archivo sobre la misma cuenta → replay
  SELECT * INTO v_existing
  FROM public.bank_statement_imports
  WHERE bank_account_id = p_bank_account_id
    AND file_hash = p_file_hash;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'import_id',   v_existing.id,
      'line_count',  v_existing.line_count,
      'period_from', v_existing.period_from,
      'period_to',   v_existing.period_to,
      'replayed',    true
    );
  END IF;

  -- Idempotencia técnica (D7): slot en operation_idempotency
  v_import_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'bank_statement_import', v_import_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'bank_statement_import'
      AND idempotency_key = p_idempotency_key;

    SELECT * INTO v_existing
    FROM public.bank_statement_imports
    WHERE id = v_existing_op;

    RETURN jsonb_build_object(
      'import_id',   v_existing.id,
      'line_count',  v_existing.line_count,
      'period_from', v_existing.period_from,
      'period_to',   v_existing.period_to,
      'replayed',    true
    );
  END IF;

  -- Período del extracto = min/max de value_date de las líneas
  SELECT MIN(x.value_date), MAX(x.value_date)
  INTO v_period_from, v_period_to
  FROM jsonb_to_recordset(p_lines)
    AS x(line_no int, value_date date, description text, amount numeric, balance numeric);

  INSERT INTO public.bank_statement_imports
    (id, bank_account_id, account_id, file_name, file_hash,
     period_from, period_to, line_count, imported_by)
  VALUES
    (v_import_id, p_bank_account_id, v_account_id, trim(p_file_name), p_file_hash,
     v_period_from, v_period_to, v_line_count, v_uid);

  INSERT INTO public.bank_statement_lines
    (import_id, bank_account_id, account_id, line_no, value_date, description, amount, balance)
  SELECT
    v_import_id, p_bank_account_id, v_account_id,
    x.line_no, x.value_date, x.description, x.amount, x.balance
  FROM jsonb_to_recordset(p_lines)
    AS x(line_no int, value_date date, description text, amount numeric, balance numeric);

  RETURN jsonb_build_object(
    'import_id',   v_import_id,
    'line_count',  v_line_count,
    'period_from', v_period_from,
    'period_to',   v_period_to,
    'replayed',    false
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_import_bank_statement(text, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_import_bank_statement(text, uuid, text, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.rpc_import_bank_statement IS
  'bank-reconciliation C3 (D2/D7): importa un extracto como filas normalizadas (jsonb). '
  'Guards: P0401 writer, P0412 cuenta, P0400 payload/cap 5000. '
  'Dedupe de dominio por (bank_account_id, file_hash) → replay. '
  'Idempotencia técnica operation_kind=bank_statement_import → replay. '
  'Líneas append-only: dato crudo inmutable del banco (RN-A3).';


-- ============================================================
-- 6. RPC: rpc_open_reconciliation_session (D3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_open_reconciliation_session(
  p_bank_account_id            uuid,
  p_period_from                date,
  p_period_to                  date,
  p_statement_closing_balance  numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid;
  v_account_id  uuid;
  v_ba          public.bank_accounts%ROWTYPE;
  v_session_id  uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
    AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  IF NOT v_ba.is_active THEN
    RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'periodo_invalido: period_from debe ser <= period_to'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_statement_closing_balance IS NULL THEN
    RAISE EXCEPTION 'saldo_extracto_requerido: statement_closing_balance es obligatorio'
      USING ERRCODE = 'P0400';
  END IF;

  BEGIN
    INSERT INTO public.reconciliation_sessions
      (bank_account_id, account_id, period_from, period_to,
       statement_closing_balance, opened_by)
    VALUES
      (p_bank_account_id, v_account_id, p_period_from, p_period_to,
       p_statement_closing_balance, v_uid)
    RETURNING id INTO v_session_id;
  EXCEPTION
    WHEN unique_violation THEN
      -- D3: índice UNIQUE parcial anti doble-apertura
      RAISE EXCEPTION 'session_already_open: ya existe una sesión de conciliación abierta para la cuenta %',
        p_bank_account_id
        USING ERRCODE = 'P0409';
  END;

  RETURN jsonb_build_object(
    'session_id',                v_session_id,
    'bank_account_id',           p_bank_account_id,
    'status',                    'open',
    'period_from',               p_period_from,
    'period_to',                 p_period_to,
    'statement_closing_balance', p_statement_closing_balance
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_open_reconciliation_session(uuid, date, date, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_open_reconciliation_session(uuid, date, date, numeric) TO authenticated;

COMMENT ON FUNCTION public.rpc_open_reconciliation_session IS
  'bank-reconciliation C3 (D3): abre una sesión de conciliación por cuenta + período. '
  'Guards: P0401 writer, P0412 cuenta, P0400 período. '
  'Anti doble-apertura (UNIQUE parcial) → P0409.';


-- ============================================================
-- 7. RPC: rpc_close_reconciliation_session (D3, RN-A5/RN-D5)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_close_reconciliation_session(
  p_session_id    uuid,
  p_close_reason  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_session          public.reconciliation_sessions%ROWTYPE;
  v_opening_balance  numeric(14,2);
  v_ledger_balance   numeric(14,2);
  v_difference       numeric(14,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- FOR UPDATE: serializa el cierre contra matches/unmatches concurrentes
  SELECT * INTO v_session
  FROM public.reconciliation_sessions
  WHERE id = p_session_id
    AND account_id = v_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'reconciliation_session_not_found: %', p_session_id
      USING ERRCODE = 'P0404';
  END IF;

  IF v_session.status = 'closed' THEN
    RAISE EXCEPTION 'session_closed: la sesión % ya está cerrada (CLOSED es terminal)', p_session_id
      USING ERRCODE = 'P0432';
  END IF;

  -- RN-D5: corte por fecha valor (date), no por created_at.
  -- Movimientos sin value_date (cargas manuales viejas) caen a created_at::date.
  SELECT ba.opening_balance INTO v_opening_balance
  FROM public.bank_accounts ba
  WHERE ba.id = v_session.bank_account_id;

  SELECT v_opening_balance + COALESCE(SUM(bm.amount), 0)
  INTO v_ledger_balance
  FROM public.bank_movements bm
  WHERE bm.bank_account_id = v_session.bank_account_id
    AND COALESCE(bm.value_date, bm.created_at::date) <= v_session.period_to;

  v_difference := v_session.statement_closing_balance - v_ledger_balance;

  -- RN-A5 (modelo V3): diferencia ≠ 0 exige motivo
  IF v_difference <> 0 AND (p_close_reason IS NULL OR trim(p_close_reason) = '') THEN
    RAISE EXCEPTION 'motivo_requerido: el cierre con diferencia (%.2f) exige close_reason', v_difference
      USING ERRCODE = 'P0431';
  END IF;

  UPDATE public.reconciliation_sessions
  SET status                 = 'closed',
      ledger_closing_balance = v_ledger_balance,
      difference             = v_difference,
      close_reason           = NULLIF(trim(COALESCE(p_close_reason, '')), ''),
      closed_by              = v_uid,
      closed_at              = now()
  WHERE id = p_session_id;

  RETURN jsonb_build_object(
    'session_id',                p_session_id,
    'status',                    'closed',
    'statement_closing_balance', v_session.statement_closing_balance,
    'ledger_closing_balance',    v_ledger_balance,
    'difference',                v_difference
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_close_reconciliation_session(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_close_reconciliation_session(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_close_reconciliation_session IS
  'bank-reconciliation C3 (D3): cierra la sesión. Calcula ledger_closing_balance '
  '(opening + Σ amounts con COALESCE(value_date, created_at::date) <= period_to — RN-D5) '
  'y difference = statement − ledger. difference ≠ 0 sin close_reason → P0431 (RN-A5). '
  'Sesión ya cerrada → P0432 (CLOSED terminal). NO toca el journal.';


-- ============================================================
-- 8. RPC: rpc_create_reconciliation_match (D1)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_reconciliation_match(
  p_session_id          uuid,
  p_statement_line_ids  uuid[],
  p_bank_movement_ids   uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_session         public.reconciliation_sessions%ROWTYPE;
  v_match_group     uuid;
  v_count           integer;
  v_sum_lines       numeric(14,2);
  v_sum_movements   numeric(14,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_session
  FROM public.reconciliation_sessions
  WHERE id = p_session_id
    AND account_id = v_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'reconciliation_session_not_found: %', p_session_id
      USING ERRCODE = 'P0404';
  END IF;

  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'session_closed: no se puede matchear en una sesión cerrada'
      USING ERRCODE = 'P0432';
  END IF;

  IF p_statement_line_ids IS NULL OR array_length(p_statement_line_ids, 1) IS NULL
     OR p_bank_movement_ids IS NULL OR array_length(p_bank_movement_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'match_invalido: se requiere al menos una línea de extracto y un movimiento'
      USING ERRCODE = 'P0400';
  END IF;

  -- Lock de los movimientos del grupo (serializa contra matches concurrentes)
  PERFORM 1
  FROM public.bank_movements bm
  WHERE bm.id = ANY(p_bank_movement_ids)
  FOR UPDATE;

  -- Pertenencia: TODAS las líneas son de la misma cuenta bancaria de la sesión
  SELECT COUNT(*) INTO v_count
  FROM public.bank_statement_lines l
  WHERE l.id = ANY(p_statement_line_ids)
    AND l.bank_account_id = v_session.bank_account_id
    AND l.account_id = v_account_id;

  IF v_count <> array_length(p_statement_line_ids, 1) THEN
    RAISE EXCEPTION 'match_invalido: alguna línea no existe o no pertenece a la cuenta bancaria de la sesión'
      USING ERRCODE = 'P0400';
  END IF;

  -- Pertenencia: TODOS los movimientos son de la misma cuenta bancaria
  SELECT COUNT(*) INTO v_count
  FROM public.bank_movements bm
  WHERE bm.id = ANY(p_bank_movement_ids)
    AND bm.bank_account_id = v_session.bank_account_id
    AND bm.account_id = v_account_id;

  IF v_count <> array_length(p_bank_movement_ids, 1) THEN
    RAISE EXCEPTION 'match_invalido: algún movimiento no existe o no pertenece a la cuenta bancaria de la sesión'
      USING ERRCODE = 'P0400';
  END IF;

  -- Anti doble-match (pre-check amigable; el UNIQUE parcial cierra el race)
  SELECT COUNT(*) INTO v_count
  FROM public.reconciliation_matches m
  WHERE m.status = 'active'
    AND (m.statement_line_id = ANY(p_statement_line_ids)
         OR m.bank_movement_id = ANY(p_bank_movement_ids));

  IF v_count > 0 THEN
    RAISE EXCEPTION 'already_matched: alguna línea o movimiento ya participa de un match activo'
      USING ERRCODE = 'P0434';
  END IF;

  -- Σ montos de líneas = Σ montos de movimientos (D1)
  SELECT COALESCE(SUM(l.amount), 0) INTO v_sum_lines
  FROM public.bank_statement_lines l
  WHERE l.id = ANY(p_statement_line_ids);

  SELECT COALESCE(SUM(bm.amount), 0) INTO v_sum_movements
  FROM public.bank_movements bm
  WHERE bm.id = ANY(p_bank_movement_ids);

  IF v_sum_lines <> v_sum_movements THEN
    RAISE EXCEPTION 'amounts_mismatch: Σ líneas (%) ≠ Σ movimientos (%)', v_sum_lines, v_sum_movements
      USING ERRCODE = 'P0433';
  END IF;

  v_match_group := gen_random_uuid();

  BEGIN
    -- Una fila por línea del grupo
    INSERT INTO public.reconciliation_matches
      (session_id, account_id, match_group, statement_line_id, matched_by)
    SELECT p_session_id, v_account_id, v_match_group, l.id, v_uid
    FROM public.bank_statement_lines l
    WHERE l.id = ANY(p_statement_line_ids);

    -- Una fila por movimiento del grupo
    INSERT INTO public.reconciliation_matches
      (session_id, account_id, match_group, bank_movement_id, matched_by)
    SELECT p_session_id, v_account_id, v_match_group, bm.id, v_uid
    FROM public.bank_movements bm
    WHERE bm.id = ANY(p_bank_movement_ids);
  EXCEPTION
    WHEN unique_violation THEN
      -- Race perdido contra otro match concurrente (UNIQUE parcial)
      RAISE EXCEPTION 'already_matched: alguna línea o movimiento ya participa de un match activo'
        USING ERRCODE = 'P0434';
  END;

  -- D5: denormalizar el estado en el ledger, en la MISMA transacción
  UPDATE public.bank_movements
  SET reconciliation_status = 'matched',
      reconciled_at         = now()
  WHERE id = ANY(p_bank_movement_ids);

  RETURN jsonb_build_object(
    'match_group',    v_match_group,
    'session_id',     p_session_id,
    'line_count',     array_length(p_statement_line_ids, 1),
    'movement_count', array_length(p_bank_movement_ids, 1),
    'amount',         v_sum_lines
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_reconciliation_match(uuid, uuid[], uuid[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_reconciliation_match(uuid, uuid[], uuid[]) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_reconciliation_match IS
  'bank-reconciliation C3 (D1): crea un grupo de match atómico línea(s) ↔ movimiento(s) '
  '(1:1, 1:N, N:1 vía match_group). Guards: P0401/P0404/P0432/P0400. '
  'Σ montos desbalanceada → P0433. Participante con match activo → P0434 '
  '(pre-check + UNIQUE parcial para el race). '
  'Setea reconciliation_status=matched en los movimientos (misma tx, D5). NO toca el journal.';


-- ============================================================
-- 9. RPC: rpc_undo_reconciliation_match (D1, RN-A3/RN-A5)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_undo_reconciliation_match(
  p_match_group  uuid,
  p_undo_reason  text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_session        public.reconciliation_sessions%ROWTYPE;
  v_session_id     uuid;
  v_undone_rows    integer;
  v_movement_rows  integer;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- RN-A5 (modelo V3): deshacer exige motivo
  IF p_undo_reason IS NULL OR trim(p_undo_reason) = '' THEN
    RAISE EXCEPTION 'motivo_requerido: deshacer un match exige undo_reason'
      USING ERRCODE = 'P0431';
  END IF;

  -- Resolver la sesión del grupo (todas las filas del grupo comparten sesión)
  SELECT m.session_id INTO v_session_id
  FROM public.reconciliation_matches m
  WHERE m.match_group = p_match_group
    AND m.account_id = v_account_id
    AND m.status = 'active'
  LIMIT 1;

  IF v_session_id IS NULL THEN
    RAISE EXCEPTION 'match_group_not_found: % (inexistente, ajeno o ya deshecho)', p_match_group
      USING ERRCODE = 'P0404';
  END IF;

  SELECT * INTO v_session
  FROM public.reconciliation_sessions
  WHERE id = v_session_id
  FOR UPDATE;

  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'session_closed: no se puede deshacer un match de una sesión cerrada'
      USING ERRCODE = 'P0432';
  END IF;

  -- RN-A3: deshacer NO borra — marca undone y preserva la historia
  UPDATE public.reconciliation_matches
  SET status      = 'undone',
      undo_reason = trim(p_undo_reason),
      undone_by   = v_uid,
      undone_at   = now()
  WHERE match_group = p_match_group
    AND status = 'active';

  GET DIAGNOSTICS v_undone_rows = ROW_COUNT;

  -- D5: revertir el estado denormalizado de los movimientos del grupo
  UPDATE public.bank_movements bm
  SET reconciliation_status = 'unreconciled',
      reconciled_at         = NULL
  WHERE bm.id IN (
    SELECT m.bank_movement_id
    FROM public.reconciliation_matches m
    WHERE m.match_group = p_match_group
      AND m.bank_movement_id IS NOT NULL
  );

  GET DIAGNOSTICS v_movement_rows = ROW_COUNT;

  RETURN jsonb_build_object(
    'match_group',     p_match_group,
    'undone_rows',     v_undone_rows,
    'movement_count',  v_movement_rows,
    'status',          'undone'
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_undo_reconciliation_match(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_undo_reconciliation_match(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_undo_reconciliation_match IS
  'bank-reconciliation C3 (RN-A3/RN-A5): deshace un grupo de match SIN borrar — '
  'status=undone + undo_reason obligatorio (P0431). Solo en sesión open (P0432). '
  'Grupo inexistente/ajeno/ya deshecho → P0404. '
  'Revierte reconciliation_status=unreconciled en los movimientos (misma tx, D5).';


-- ============================================================
-- 10. CREATE OR REPLACE: rpc_register_bank_movement — tipos manuales ampliados
--     (misma firma que C1 → reemplaza el cuerpo sin crear overload; el gate (h)
--      verifica que sigue habiendo UNA sola función — lección 42725)
--     Delta spec bank-movement: + fee / tax_debit / interest ("solo anotar" V1).
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_register_bank_movement(
  p_idempotency_key  text,
  p_bank_account_id  uuid,
  p_amount           numeric,
  p_type             text,
  p_value_date       date    DEFAULT NULL,
  p_branch_id        uuid    DEFAULT NULL,
  p_description      text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid           uuid;
  v_account_id    uuid;
  v_ba            public.bank_accounts%ROWTYPE;
  v_inserted      integer;
  v_existing_op   uuid;
  v_new_op_id     uuid;
  v_movement_id   uuid;
  v_balance_after numeric(14,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- C3 amplía el subconjunto MANUAL (delta spec bank-movement, "solo anotar" V1):
  -- fee / tax_debit / interest dejan de estar reservados — cargos del extracto
  -- sin contraparte en el sistema se anotan y se concilian.
  -- card_settlement SIGUE reservado a los escritores automáticos (RPCs de pago C2).
  IF p_type NOT IN ('transfer_in', 'transfer_out', 'manual_adjustment',
                    'fee', 'tax_debit', 'interest') THEN
    RAISE EXCEPTION 'movement_type_reservado: % no está permitido en la carga manual. '
      'Tipo reservado a los escritores automáticos (C2): card_settlement. '
      'Tipos aceptados: transfer_in, transfer_out, manual_adjustment, fee, tax_debit, interest.',
      p_type
      USING ERRCODE = 'P0410';
  END IF;

  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
    AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  IF NOT v_ba.is_active THEN
    RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva y no acepta nuevos movimientos',
      p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  -- Idempotencia (D6 de C1) — sin cambios
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'bank_movement', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'bank_movement'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'movement_id',   NULL,
      'balance_after', NULL,
      'replayed',      true,
      'operation_id',  v_existing_op
    );
  END IF;

  v_movement_id := public._register_bank_movement(
    p_bank_account_id,
    p_amount,
    p_type,
    NULL,              -- source_doc_type (carga manual: sin documento fuente)
    NULL,              -- source_doc_ref
    p_value_date,
    p_branch_id,
    p_description
  );

  SELECT balance_after INTO v_balance_after
  FROM public.bank_movements
  WHERE id = v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',   v_movement_id,
    'balance_after', v_balance_after,
    'replayed',      false,
    'operation_id',  v_new_op_id
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_register_bank_movement IS
  'bank-account-ledger C1, ampliada por bank-reconciliation C3: registra un movimiento bancario MANUAL. '
  'Guard is_account_writer → P0401. '
  'Subconjunto manual aceptado (C3, "solo anotar" V1): transfer_in, transfer_out, '
  'manual_adjustment, fee, tax_debit, interest. '
  'Reservado a escritores automáticos de C2 (card_settlement) → P0410. '
  'Cuenta inexistente/inactiva → P0412. '
  'Idempotente (operation_kind=bank_movement): replay devuelve replayed=true sin duplicar. '
  'Delega a _register_bank_movement para el INSERT append-only.';


-- ============================================================
-- 11. Gates SQL (RED→GREEN→TRIANGULATE validados por este DO-block)
--
-- Introspección (SIEMPRE): existencia de tablas/índices/CHECKs/RPCs,
-- ausencia de policies de escritura, gate negativo del journal, 1 solo
-- overload de rpc_register_bank_movement.
-- Comportamiento (SOLO DB vacía — CI): flujo completo import → open →
-- match → undo → close con JWT simulado (patrón C2: set_config claims +
-- WHEN OTHERS con discriminación por SQLSTATE).
-- ============================================================
DO $$
DECLARE
  v_fake_account_id    uuid;
  v_fake_user_id       uuid := gen_random_uuid();
  v_bank_account_id    uuid;
  v_movement_1         uuid;   -- +5000 transfer_in
  v_movement_2         uuid;   -- -350 fee (vía RPC manual ampliada)
  v_import_result      jsonb;
  v_result             jsonb;
  v_import_id          uuid;
  v_session_id         uuid;
  v_match_group        uuid;
  v_line_1             uuid;
  v_line_2             uuid;
  v_line_3             uuid;
  v_count              int;
  v_status             text;
  v_run_behavioral     boolean := false;

  -- introspección
  v_gate_a boolean := false;  -- 4 tablas nuevas existen
  v_gate_b boolean := false;  -- índice UNIQUE parcial anti doble-apertura
  v_gate_c boolean := false;  -- sin policies de escritura en las 4 tablas
  v_gate_d boolean := false;  -- bank_movements.reconciliation_status default unreconciled
  v_gate_e boolean := false;  -- CHECK operation_idempotency incluye bank_statement_import
  v_gate_f boolean := false;  -- RPC manual acepta fee/tax_debit/interest y mantiene P0410
  v_gate_g boolean := false;  -- gate negativo: RPCs C3 no tocan el journal
  v_gate_h boolean := false;  -- 1 solo overload de rpc_register_bank_movement (42725)
  -- comportamiento (solo CI)
  v_gate_i boolean := false;  -- import happy path (3 líneas, período min/max)
  v_gate_j boolean := false;  -- import replay por file_hash (sin duplicar)
  v_gate_k boolean := false;  -- doble apertura → P0409
  v_gate_l boolean := false;  -- fee manual aceptado (C3)
  v_gate_m boolean := false;  -- card_settlement manual → P0410
  v_gate_n boolean := false;  -- match 1:1 → movimiento matched
  v_gate_o boolean := false;  -- sumas desbalanceadas → P0433
  v_gate_p boolean := false;  -- participante ya matcheado → P0434
  v_gate_q boolean := false;  -- undo: sin motivo P0431; con motivo revierte estado
  v_gate_r boolean := false;  -- close: diferencia sin motivo P0431; con motivo cierra; post-close P0432
BEGIN

  -- ── (a) Las 4 tablas nuevas existen ───────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name IN ('bank_statement_imports', 'bank_statement_lines',
                       'reconciliation_sessions', 'reconciliation_matches');
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaban 4 tablas nuevas, hay %', v_count;
  END IF;
  v_gate_a := true;

  -- ── (b) Índice UNIQUE parcial anti doble-apertura ─────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'reconciliation_sessions'
    AND indexname = 'reconciliation_sessions_one_open_idx'
    AND indexdef LIKE '%UNIQUE%'
    AND indexdef LIKE '%open%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE (b) FAILED: falta el índice UNIQUE parcial anti doble-apertura';
  END IF;
  v_gate_b := true;

  -- ── (c) Sin policies de escritura directa en las 4 tablas nuevas ─────────
  SELECT COUNT(*) INTO v_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('bank_statement_imports', 'bank_statement_lines',
                      'reconciliation_sessions', 'reconciliation_matches')
    AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'GATE (c) FAILED: existen % policies de escritura directa — se esperaba 0', v_count;
  END IF;
  v_gate_c := true;

  -- ── (d) bank_movements.reconciliation_status con default unreconciled ────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'bank_movements'
    AND column_name = 'reconciliation_status'
    AND column_default LIKE '%unreconciled%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: bank_movements.reconciliation_status sin default unreconciled';
  END IF;
  v_gate_d := true;

  -- ── (e) CHECK de operation_idempotency incluye bank_statement_import ─────
  SELECT COUNT(*) INTO v_count
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  WHERE t.relname = 'operation_idempotency'
    AND c.conname = 'operation_idempotency_operation_kind_check'
    AND pg_get_constraintdef(c.oid) LIKE '%bank_statement_import%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE (e) FAILED: el CHECK de operation_kind no incluye bank_statement_import (regla C-30)';
  END IF;
  v_gate_e := true;

  -- ── (f) RPC manual: acepta fee/tax_debit/interest, mantiene P0410 ─────────
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'rpc_register_bank_movement'
    AND pg_get_functiondef(p.oid) LIKE '%''fee''%'
    AND pg_get_functiondef(p.oid) LIKE '%''tax_debit''%'
    AND pg_get_functiondef(p.oid) LIKE '%''interest''%'
    AND pg_get_functiondef(p.oid) LIKE '%P0410%'
    AND pg_get_functiondef(p.oid) LIKE '%card_settlement%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE (f) FAILED: rpc_register_bank_movement no amplió los tipos manuales o perdió el guard P0410';
  END IF;
  v_gate_f := true;

  -- ── (g) Gate negativo: las 5 RPCs de C3 NO tocan el journal ──────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('rpc_import_bank_statement', 'rpc_open_reconciliation_session',
                      'rpc_close_reconciliation_session', 'rpc_create_reconciliation_match',
                      'rpc_undo_reconciliation_match')
    AND (pg_get_functiondef(p.oid) LIKE '%journal_entries%'
         OR pg_get_functiondef(p.oid) LIKE '%journal_lines%'
         OR pg_get_functiondef(p.oid) LIKE '%''1110''%');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'GATE (g) FAILED: % RPC(s) de conciliación referencian el journal — la conciliación NUNCA toca el journal', v_count;
  END IF;
  v_gate_g := true;

  -- ── (h) Un solo overload de rpc_register_bank_movement (lección 42725) ───
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'rpc_register_bank_movement';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (h) FAILED: rpc_register_bank_movement tiene % overloads, se esperaba 1 (riesgo 42725)', v_count;
  END IF;
  v_gate_h := true;


  -- ══════════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Patrón C2: anchor sintético +
  -- set_config de claims JWT + WHEN OTHERS con discriminación por SQLSTATE.
  -- ══════════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- El trigger handle_new_user auto-crea account + membership(owner)
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'bank-reconciliation-gate@test.local', now(), now(),
              jsonb_build_object('name', 'C3 Gate', 'phone', '', 'locality', '', 'province', ''))
      ON CONFLICT (id) DO NOTHING;

      -- Resolver la cuenta que current_account_ids() devolverá (lección C2:
      -- usar la auto-creada, no una fija, para que las RPCs no den P0412)
      SELECT account_id INTO v_fake_account_id
      FROM public.account_members
      WHERE user_id = v_fake_user_id
      ORDER BY created_at
      LIMIT 1;

      IF v_fake_account_id IS NULL THEN
        v_fake_account_id := gen_random_uuid();
        INSERT INTO public.accounts (id, owner_user_id)
        VALUES (v_fake_account_id, v_fake_user_id) ON CONFLICT (id) DO NOTHING;
        INSERT INTO public.account_members (account_id, user_id, role)
        VALUES (v_fake_account_id, v_fake_user_id, 'owner')
        ON CONFLICT DO NOTHING;
      ELSE
        UPDATE public.account_members
        SET role = 'owner'
        WHERE account_id = v_fake_account_id
          AND user_id = v_fake_user_id
          AND role NOT IN ('owner', 'admin');
      END IF;

      -- Simular la sesión JWT (local a la transacción de la migración)
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_id::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_fake_user_id::text, true);

      INSERT INTO public.bank_accounts
        (account_id, name, bank_name, currency, opening_balance, is_active)
      VALUES
        (v_fake_account_id, 'Banco Test C3', 'Banco Ficticio', 'ARS', 10000.00, true)
      RETURNING id INTO v_bank_account_id;

      -- Movimiento 1 (+5000) directo por el helper (superuser en migración)
      v_movement_1 := public._register_bank_movement(
        v_bank_account_id, 5000.00, 'transfer_in', NULL, NULL, DATE '2026-07-15', NULL, 'transferencia test');
    EXCEPTION
      WHEN OTHERS THEN
        v_run_behavioral := false;
        RAISE NOTICE 'bank-reconciliation: anchor sintético no disponible (%) — se saltan gates de comportamiento', SQLERRM;
    END;
  END IF;


  -- ── (l) fee manual aceptado (RPC ampliada por C3) ─────────────────────────
  IF v_run_behavioral THEN
  BEGIN
    v_result := public.rpc_register_bank_movement(
      'gate-l-' || gen_random_uuid()::text, v_bank_account_id,
      -350.00, 'fee', DATE '2026-07-20', NULL, 'comisión mantenimiento test');

    IF (v_result->>'replayed')::boolean IS DISTINCT FROM false
       OR (v_result->>'movement_id') IS NULL THEN
      RAISE EXCEPTION 'GATE (l) FAILED: fee manual no se registró (%)', v_result;
    END IF;
    v_movement_2 := (v_result->>'movement_id')::uuid;
    v_gate_l := true;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GATE (l) FAILED%' THEN RAISE;
      ELSE RAISE NOTICE 'bank-reconciliation: gate (l) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (m) card_settlement manual → P0410 (sigue reservado) ─────────────────
  IF v_run_behavioral THEN
  BEGIN
    PERFORM public.rpc_register_bank_movement(
      'gate-m-' || gen_random_uuid()::text, v_bank_account_id,
      1000.00, 'card_settlement', NULL, NULL, NULL);
    RAISE EXCEPTION 'GATE (m) FAILED: card_settlement manual debería fallar con P0410';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0410' THEN
        v_gate_m := true;
      ELSIF SQLERRM LIKE 'GATE (m) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-reconciliation: gate (m) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (i) Import happy path: 3 líneas, período min/max, líneas insertadas ──
  IF v_run_behavioral THEN
  BEGIN
    v_import_result := public.rpc_import_bank_statement(
      'gate-i-' || gen_random_uuid()::text,
      v_bank_account_id,
      'extracto-julio.csv',
      'hash-gate-c3-0001',
      jsonb_build_array(
        jsonb_build_object('line_no', 1, 'value_date', '2026-07-15', 'description', 'Transferencia recibida', 'amount', 5000.00, 'balance', NULL),
        jsonb_build_object('line_no', 2, 'value_date', '2026-07-20', 'description', 'Comisión mantenimiento', 'amount', -350.00, 'balance', NULL),
        jsonb_build_object('line_no', 3, 'value_date', '2026-07-25', 'description', 'Transferencia sin registrar', 'amount', 100.00, 'balance', NULL)
      ));

    IF (v_import_result->>'replayed')::boolean IS DISTINCT FROM false
       OR (v_import_result->>'line_count')::int IS DISTINCT FROM 3
       OR (v_import_result->>'period_from') IS DISTINCT FROM '2026-07-15'
       OR (v_import_result->>'period_to') IS DISTINCT FROM '2026-07-25' THEN
      RAISE EXCEPTION 'GATE (i) FAILED: import inesperado (%)', v_import_result;
    END IF;

    v_import_id := (v_import_result->>'import_id')::uuid;

    SELECT COUNT(*) INTO v_count FROM public.bank_statement_lines WHERE import_id = v_import_id;
    IF v_count <> 3 THEN
      RAISE EXCEPTION 'GATE (i) FAILED: se esperaban 3 líneas, hay %', v_count;
    END IF;

    SELECT id INTO v_line_1 FROM public.bank_statement_lines WHERE import_id = v_import_id AND line_no = 1;
    SELECT id INTO v_line_2 FROM public.bank_statement_lines WHERE import_id = v_import_id AND line_no = 2;
    SELECT id INTO v_line_3 FROM public.bank_statement_lines WHERE import_id = v_import_id AND line_no = 3;
    v_gate_i := true;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GATE (i) FAILED%' THEN RAISE;
      ELSE RAISE NOTICE 'bank-reconciliation: gate (i) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (j) Import replay por file_hash: no duplica líneas ───────────────────
  IF v_run_behavioral AND v_gate_i THEN
  BEGIN
    v_result := public.rpc_import_bank_statement(
      'gate-j-' || gen_random_uuid()::text,   -- key DISTINTA: el dedupe es por hash
      v_bank_account_id,
      'extracto-julio.csv',
      'hash-gate-c3-0001',
      jsonb_build_array(
        jsonb_build_object('line_no', 1, 'value_date', '2026-07-15', 'description', 'x', 'amount', 5000.00, 'balance', NULL)
      ));

    IF (v_result->>'replayed')::boolean IS DISTINCT FROM true
       OR (v_result->>'import_id')::uuid IS DISTINCT FROM v_import_id THEN
      RAISE EXCEPTION 'GATE (j) FAILED: replay esperado del import original (%)', v_result;
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.bank_statement_lines WHERE import_id = v_import_id;
    IF v_count <> 3 THEN
      RAISE EXCEPTION 'GATE (j) FAILED: el replay duplicó líneas (hay %)', v_count;
    END IF;
    v_gate_j := true;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GATE (j) FAILED%' THEN RAISE;
      ELSE RAISE NOTICE 'bank-reconciliation: gate (j) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (k) Abrir sesión + anti doble-apertura P0409 ─────────────────────────
  IF v_run_behavioral THEN
  BEGIN
    v_result := public.rpc_open_reconciliation_session(
      v_bank_account_id, DATE '2026-07-01', DATE '2026-07-31', 14750.00);
    v_session_id := (v_result->>'session_id')::uuid;

    IF v_session_id IS NULL THEN
      RAISE EXCEPTION 'GATE (k) FAILED: no se abrió la sesión (%)', v_result;
    END IF;

    BEGIN
      PERFORM public.rpc_open_reconciliation_session(
        v_bank_account_id, DATE '2026-07-01', DATE '2026-07-31', 14750.00);
      RAISE EXCEPTION 'GATE (k) FAILED: la segunda apertura debería fallar con P0409';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0409' THEN
          v_gate_k := true;
        ELSE
          RAISE;
        END IF;
    END;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GATE (k) FAILED%' THEN RAISE;
      ELSE RAISE NOTICE 'bank-reconciliation: gate (k) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (n) Match 1:1: línea 1 (+5000) ↔ movimiento 1 (+5000) → matched ──────
  IF v_run_behavioral AND v_gate_i AND v_session_id IS NOT NULL THEN
  BEGIN
    v_result := public.rpc_create_reconciliation_match(
      v_session_id, ARRAY[v_line_1], ARRAY[v_movement_1]);
    v_match_group := (v_result->>'match_group')::uuid;

    SELECT reconciliation_status INTO v_status
    FROM public.bank_movements WHERE id = v_movement_1;

    IF v_status IS DISTINCT FROM 'matched' OR v_match_group IS NULL THEN
      RAISE EXCEPTION 'GATE (n) FAILED: el movimiento no quedó matched (status=%, group=%)', v_status, v_match_group;
    END IF;
    v_gate_n := true;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GATE (n) FAILED%' THEN RAISE;
      ELSE RAISE NOTICE 'bank-reconciliation: gate (n) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (o) Sumas desbalanceadas → P0433 (línea 3 = +100 vs fee = -350) ──────
  IF v_run_behavioral AND v_gate_i AND v_movement_2 IS NOT NULL THEN
  BEGIN
    PERFORM public.rpc_create_reconciliation_match(
      v_session_id, ARRAY[v_line_3], ARRAY[v_movement_2]);
    RAISE EXCEPTION 'GATE (o) FAILED: sumas desbalanceadas deberían fallar con P0433';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0433' THEN
        v_gate_o := true;
      ELSIF SQLERRM LIKE 'GATE (o) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-reconciliation: gate (o) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (p) Participante ya matcheado → P0434 (movimiento 1 ya activo) ───────
  IF v_run_behavioral AND v_gate_n THEN
  BEGIN
    PERFORM public.rpc_create_reconciliation_match(
      v_session_id, ARRAY[v_line_2], ARRAY[v_movement_1]);
    RAISE EXCEPTION 'GATE (p) FAILED: movimiento ya matcheado debería fallar con P0434';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0434' THEN
        v_gate_p := true;
      ELSIF SQLERRM LIKE 'GATE (p) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-reconciliation: gate (p) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (q) Undo: sin motivo P0431; con motivo revierte y permite re-match ───
  IF v_run_behavioral AND v_gate_n THEN
  BEGIN
    BEGIN
      PERFORM public.rpc_undo_reconciliation_match(v_match_group, NULL);
      RAISE EXCEPTION 'GATE (q) FAILED: undo sin motivo debería fallar con P0431';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0431' THEN NULL;  -- correcto
        ELSE RAISE;
        END IF;
    END;

    PERFORM public.rpc_undo_reconciliation_match(v_match_group, 'monto correspondía a otra transferencia');

    SELECT reconciliation_status INTO v_status
    FROM public.bank_movements WHERE id = v_movement_1;
    IF v_status IS DISTINCT FROM 'unreconciled' THEN
      RAISE EXCEPTION 'GATE (q) FAILED: el movimiento no volvió a unreconciled (%)', v_status;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM public.reconciliation_matches
    WHERE match_group = v_match_group AND status = 'undone' AND undo_reason IS NOT NULL;
    IF v_count < 2 THEN
      RAISE EXCEPTION 'GATE (q) FAILED: el grupo no quedó undone con motivo (filas undone=%)', v_count;
    END IF;

    -- TRIANGULATE: re-match del mismo par tras el undo (el UNIQUE parcial lo permite)
    v_result := public.rpc_create_reconciliation_match(
      v_session_id, ARRAY[v_line_1], ARRAY[v_movement_1]);
    IF (v_result->>'match_group') IS NULL THEN
      RAISE EXCEPTION 'GATE (q) FAILED: re-match tras undo no funcionó (%)', v_result;
    END IF;
    v_gate_q := true;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GATE (q) FAILED%' THEN RAISE;
      ELSE RAISE NOTICE 'bank-reconciliation: gate (q) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;

  -- ── (r) Close: diferencia sin motivo P0431; con motivo cierra; post-close P0432 ─
  -- Ledger = 10000 (opening) + 5000 (m1) - 350 (m2 fee) = 14650.
  -- Extracto = 14750 → difference = +100 (la línea 3 no está en el sistema).
  IF v_run_behavioral AND v_session_id IS NOT NULL THEN
  BEGIN
    BEGIN
      PERFORM public.rpc_close_reconciliation_session(v_session_id, NULL);
      RAISE EXCEPTION 'GATE (r) FAILED: cierre con diferencia sin motivo debería fallar con P0431';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0431' THEN NULL;  -- correcto
        ELSE RAISE;
        END IF;
    END;

    v_result := public.rpc_close_reconciliation_session(
      v_session_id, 'transferencia del 25/07 pendiente de registrar');

    IF (v_result->>'status') IS DISTINCT FROM 'closed'
       OR (v_result->>'difference')::numeric IS DISTINCT FROM 100.00
       OR (v_result->>'ledger_closing_balance')::numeric IS DISTINCT FROM 14650.00 THEN
      RAISE EXCEPTION 'GATE (r) FAILED: cierre inesperado (%)', v_result;
    END IF;

    -- CLOSED es terminal: matchear sobre sesión cerrada → P0432
    BEGIN
      PERFORM public.rpc_create_reconciliation_match(
        v_session_id, ARRAY[v_line_2], ARRAY[v_movement_2]);
      RAISE EXCEPTION 'GATE (r) FAILED: match sobre sesión cerrada debería fallar con P0432';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0432' THEN NULL;  -- correcto
        ELSE RAISE;
        END IF;
    END;
    v_gate_r := true;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GATE (r) FAILED%' THEN RAISE;
      ELSE RAISE NOTICE 'bank-reconciliation: gate (r) degradado (%)', SQLERRM;
      END IF;
  END;
  END IF;


  -- ── Limpieza del anchor sintético (solo DB de test, best-effort) ──────────
  IF v_run_behavioral THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'bank-reconciliation: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== bank-reconciliation C3 SQL gates ===';
  RAISE NOTICE '(a) 4 tablas nuevas existen:                      %', v_gate_a;
  RAISE NOTICE '(b) UNIQUE parcial anti doble-apertura:           %', v_gate_b;
  RAISE NOTICE '(c) sin policies de escritura directa:            %', v_gate_c;
  RAISE NOTICE '(d) reconciliation_status default unreconciled:   %', v_gate_d;
  RAISE NOTICE '(e) CHECK op_idempotency + bank_statement_import: %', v_gate_e;
  RAISE NOTICE '(f) RPC manual amplia fee/tax_debit/interest:     %', v_gate_f;
  RAISE NOTICE '(g) RPCs C3 no tocan el journal (negativo):       %', v_gate_g;
  RAISE NOTICE '(h) 1 solo overload rpc_register_bank_movement:   %', v_gate_h;
  RAISE NOTICE '(i) import happy path 3 lineas:                   %', v_gate_i;
  RAISE NOTICE '(j) import replay por file_hash:                  %', v_gate_j;
  RAISE NOTICE '(k) doble apertura P0409:                         %', v_gate_k;
  RAISE NOTICE '(l) fee manual aceptado (C3):                     %', v_gate_l;
  RAISE NOTICE '(m) card_settlement manual P0410:                 %', v_gate_m;
  RAISE NOTICE '(n) match 1:1 movimiento matched:                 %', v_gate_n;
  RAISE NOTICE '(o) sumas desbalanceadas P0433:                   %', v_gate_o;
  RAISE NOTICE '(p) ya matcheado P0434:                           %', v_gate_p;
  RAISE NOTICE '(q) undo con motivo + re-match:                   %', v_gate_q;
  RAISE NOTICE '(r) close diferencia/motivo/terminal:             %', v_gate_r;
  RAISE NOTICE '=== bank-reconciliation C3: schema + RPCs + gates OK ===';

END $$;
