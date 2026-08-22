-- =============================================================================
-- banco-caja-historial-ajustes — historial de movimientos (molde Stock) +
-- ajuste manual con motivo obligatorio en Caja y Banco, sin tapar la señal
-- antifraude del arqueo (RN-95) y sin postear asiento contable (OQ-2).
-- =============================================================================
--
-- Pedido textual del PO (2026-08-22): "quiero que caja tenga su propio modulo
-- y no lo comparta con banco y que dentro de estos dos, tanto en banco y
-- caja, alla un historial de movimiento como tiene el modulo stock. y dentro
-- tanto de banco y caja alla 1 que sea ajuste para poder hacer ajuste para
-- consolidar las cuentas". Firmas de sign-off (2026-08-22): OQ-1 = A
-- (conservar sesiones con arqueo — "caja siempre abierta" descartada);
-- OQ-2 = ajustes SOLO en su libro, SIN asiento contable; OQ-3 gateado a
-- v3-rbac-multirole (sin restricción de rol adicional por ahora).
--
-- MAX(version) prod verificado 2026-08-22 (solo SELECT, MCP): 20261005000001
-- → este archivo usa 20261006000001. Baseline de las 4 funciones tocadas
-- capturado en openspec/changes/banco-caja-historial-ajustes/baseline/*.sql
-- vía pg_get_functiondef EN VIVO (gate de integridad de función, regla del
-- proyecto) — las reescrituras de este archivo parten de ese baseline.
--
-- Censo de ERRCODE re-corrido 2026-08-22: P0400,401,403,404,409,410,411,412,
-- 422,423,424,425,426,431,432,433,434,450,451 ocupados. Este change usa
-- P0413 — confirmado libre (design.md D6).
--
-- Idempotente: columnas con IF NOT EXISTS, CHECKs con DROP+ADD (o ADD ...
-- NOT VALID + VALIDATE inmediato para no bloquear las tablas con tráfico),
-- índice con IF NOT EXISTS, funciones con DROP FUNCTION IF EXISTS <firma
-- vieja exacta> + CREATE OR REPLACE (firma nueva: rpc_register_cash_movement,
-- c28_register_cash_movement — ambas ganan p_description trailing) o
-- CREATE OR REPLACE (firma sin cambios: rpc_close_cash_session,
-- rpc_register_bank_movement) + REVOKE/GRANT explícito de
-- PUBLIC/anon/authenticated en el mismo archivo para las 4 (gotcha visto 6
-- veces en el proyecto: el default-privilege setup de Supabase hosted
-- otorga EXECUTE a anon/authenticated directamente sobre funciones nuevas
-- del schema public, "REVOKE ... FROM PUBLIC" solo no alcanza — 20261004000002).

-- =============================================================================
-- 1. cash_movements — columna de motivo + vocabulario ampliado + CHECK +
--    índice para el historial ordenado por fecha
-- =============================================================================

ALTER TABLE public.cash_movements
  ADD COLUMN IF NOT EXISTS description text;

COMMENT ON COLUMN public.cash_movements.description IS
  'banco-caja-historial-ajustes: motivo del movimiento. Obligatorio (CHECK)
  únicamente para movement_type = ''adjustment''; opcional para el resto.';

ALTER TABLE public.cash_movements
  DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;

ALTER TABLE public.cash_movements
  ADD CONSTRAINT cash_movements_movement_type_check
  CHECK (movement_type = ANY (ARRAY[
    'sale'::text, 'purchase_payment'::text, 'expense'::text,
    'advance'::text, 'withdrawal'::text, 'sale_reversal'::text,
    'adjustment'::text
  ]));

COMMENT ON CONSTRAINT cash_movements_movement_type_check ON public.cash_movements IS
  'banco-caja-historial-ajustes: agrega adjustment — ajuste manual con motivo
  obligatorio (ver cash_movements_adjustment_needs_reason) para consolidar el
  saldo del sistema contra el efectivo real, sin tapar la señal antifraude
  del arqueo (RN-95, D5 del design).';

-- Motivo obligatorio SOLO para adjustment. NOT VALID porque las 65 filas
-- históricas tienen description NULL y ninguna es adjustment — el CHECK
-- gobierna lo nuevo sin reescribir el pasado (RED task 2.2 → GREEN acá).
-- VALIDATE inmediato: el predicado ya se cumple, no bloquea la tabla.
ALTER TABLE public.cash_movements
  DROP CONSTRAINT IF EXISTS cash_movements_adjustment_needs_reason;

ALTER TABLE public.cash_movements
  ADD CONSTRAINT cash_movements_adjustment_needs_reason
  CHECK (movement_type <> 'adjustment' OR (description IS NOT NULL AND btrim(description) <> ''))
  NOT VALID;

ALTER TABLE public.cash_movements
  VALIDATE CONSTRAINT cash_movements_adjustment_needs_reason;

COMMENT ON CONSTRAINT cash_movements_adjustment_needs_reason ON public.cash_movements IS
  'banco-caja-historial-ajustes (D4): ningún camino de escritura puede
  registrar un ajuste de caja sin motivo no vacío. Ledger append-only —
  un ajuste equivocado se corrige con otro ajuste, nunca con UPDATE/DELETE.';

-- Historial de caja por cashbox (D2): el índice existente es
-- (session_id, created_at) ascendente, sirve pero fuerza backward scan en el
-- orden DESC que usa la pantalla nueva.
CREATE INDEX IF NOT EXISTS idx_cash_movements_session_created_desc
  ON public.cash_movements (session_id, created_at DESC);

-- =============================================================================
-- 2. cash_sessions — snapshot de ajustes al cierre (D5, señal antifraude RN-95)
-- =============================================================================

ALTER TABLE public.cash_sessions
  ADD COLUMN IF NOT EXISTS adjustments_total numeric(12,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.cash_sessions.adjustments_total IS
  'banco-caja-historial-ajustes (D5): Σ(cash_movements.amount) FILTER
  (movement_type=''adjustment'') de la sesión, materializada al cierre por
  rpc_close_cash_session (patrón v3-snapshot-pattern). expected_balance y
  difference NO cambian de definición (siguen incluyendo los ajustes) —
  difference_before_adjustments (calculada, no persistida) = difference +
  adjustments_total es la señal de lo que habría dado el arqueo sin los
  ajustes. DEFAULT 0: las 65 filas históricas y las sesiones cerradas antes
  de este change no tuvieron ajustes.';

-- =============================================================================
-- 3. bank_movements — motivo obligatorio para manual_adjustment (D6)
-- =============================================================================
-- NOT VALID porque las 3 filas históricas son transfer_in, ninguna
-- manual_adjustment — el predicado ya se cumple, VALIDATE inmediato no
-- bloquea. Espejo exacto del CHECK de cash_movements (mismo predicado,
-- distinto tipo gatillante) para que ningún escritor futuro lo evada aunque
-- el guard P0413 de la RPC (§5) se salte por algún camino nuevo.

ALTER TABLE public.bank_movements
  DROP CONSTRAINT IF EXISTS bank_movements_adjustment_needs_reason;

ALTER TABLE public.bank_movements
  ADD CONSTRAINT bank_movements_adjustment_needs_reason
  CHECK (movement_type <> 'manual_adjustment' OR (description IS NOT NULL AND btrim(description) <> ''))
  NOT VALID;

ALTER TABLE public.bank_movements
  VALIDATE CONSTRAINT bank_movements_adjustment_needs_reason;

COMMENT ON CONSTRAINT bank_movements_adjustment_needs_reason ON public.bank_movements IS
  'banco-caja-historial-ajustes (D6): espejo a nivel tabla del guard P0413 de
  rpc_register_bank_movement — ningún camino futuro puede registrar un
  manual_adjustment sin motivo no vacío.';

-- =============================================================================
-- 4. rpc_register_cash_movement — p_description trailing (D4)
-- =============================================================================
-- Firma nueva (4→5 args, DEFAULT NULL al final: el hot path de venta,
-- 63/65 movimientos históricos, no se toca) ⇒ DROP FUNCTION IF EXISTS con la
-- firma vieja EXACTA evita el overload ambiguo 42725 (gate ANTI-OVERLOAD
-- verificado por supabase/tests/test_banco_caja_historial_ajustes.sql).

DROP FUNCTION IF EXISTS public.rpc_register_cash_movement(uuid, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.rpc_register_cash_movement(
  p_session_id    uuid,
  p_amount        numeric,
  p_type          text,
  p_reference_id  uuid DEFAULT NULL::uuid,
  p_description   text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id  uuid;
  v_movement_id uuid;
BEGIN
  -- Resolver account_id vía cadena de FKs
  SELECT b.account_id INTO v_account_id
  FROM public.cash_sessions cs
  JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
  JOIN public.branches b   ON b.id  = cb.branch_id
  WHERE cs.id = p_session_id;

  IF v_account_id IS NULL THEN
    -- La sesión no existe — el helper emitirá no_open_session
    NULL;
  ELSIF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Delegar al helper intra-transacción (D2). banco-caja-historial-ajustes:
  -- propaga p_description — el CHECK cash_movements_adjustment_needs_reason
  -- es quien gobierna la obligatoriedad para movement_type='adjustment'.
  v_movement_id := public.c28_register_cash_movement(
    p_session_id, p_amount, p_type, p_reference_id, p_description
  );

  RETURN jsonb_build_object('movement_id', v_movement_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_register_cash_movement(uuid, numeric, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_register_cash_movement(uuid, numeric, text, uuid, text) TO authenticated;

-- =============================================================================
-- 5. c28_register_cash_movement — p_description trailing (D4)
-- =============================================================================
-- Mismo motivo de DROP+CREATE que §4 (firma 4→5 args).

DROP FUNCTION IF EXISTS public.c28_register_cash_movement(uuid, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.c28_register_cash_movement(
  p_session_id    uuid,
  p_amount        numeric,
  p_type          text,
  p_reference_id  uuid DEFAULT NULL::uuid,
  p_description   text DEFAULT NULL::text
)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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

  -- Insertar el movimiento (append-only). banco-caja-historial-ajustes:
  -- suma description — cash_movements_adjustment_needs_reason rechaza un
  -- adjustment sin motivo no vacío, sin código nuevo acá.
  INSERT INTO public.cash_movements
    (session_id, amount, movement_type, reference_id, balance_after, created_by, description)
  VALUES
    (p_session_id, p_amount, p_type, p_reference_id, v_balance_after, v_user_id, p_description)
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.c28_register_cash_movement(uuid, numeric, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.c28_register_cash_movement(uuid, numeric, text, uuid, text) TO authenticated;

-- =============================================================================
-- 6. rpc_close_cash_session — adjustments_total + difference_before_adjustments (D5)
-- =============================================================================
-- Firma SIN CAMBIOS (uuid, numeric, text) → CREATE OR REPLACE preserva ACL;
-- REVOKE/GRANT explícito igual, por higiene uniforme con las otras 3.
-- expected_balance y difference NO cambian de fórmula (D5) — solo se agrega
-- el snapshot adjustments_total y el valor derivado difference_before_
-- adjustments, sin persistir este último (se recalcula: difference + adjustments_total).

CREATE OR REPLACE FUNCTION public.rpc_close_cash_session(p_session_id uuid, p_counted_balance numeric, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_session                       public.cash_sessions%ROWTYPE;
  v_account_id                    uuid;
  v_sum_movements                 numeric(12,2);
  v_adjustments_total             numeric(12,2);
  v_expected                      numeric(12,2);
  v_difference                    numeric(12,2);
  v_difference_before_adjustments numeric(12,2);
  v_close_reason                  text;
  v_branch_id                     uuid;
  v_existing_op                   uuid;
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
        'session_id',                     v_session.id,
        'status',                         v_session.status,
        'opening_balance',                v_session.opening_balance,
        'expected_balance',               v_session.expected_balance,
        'counted_balance',                v_session.counted_balance,
        'difference',                     v_session.difference,
        'closing_balance',                v_session.closing_balance,
        'adjustments_total',              v_session.adjustments_total,
        'difference_before_adjustments',  v_session.difference + v_session.adjustments_total
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

  -- D7 (journal-entry-outbox) / D5 (banco-caja-historial-ajustes): expected_balance
  -- SIGUE siendo opening_balance + Σ(cash_movements.amount) — SIN CAMBIOS,
  -- incluye los ajustes. adjustments_total se materializa aparte (snapshot al
  -- cierre) para poder reconstruir la diferencia SIN ajustes.
  SELECT
    COALESCE(SUM(cm.amount), 0),
    COALESCE(SUM(cm.amount) FILTER (WHERE cm.movement_type = 'adjustment'), 0)
  INTO v_sum_movements, v_adjustments_total
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_expected                      := v_session.opening_balance + v_sum_movements;
  v_difference                    := p_counted_balance - v_expected;
  v_difference_before_adjustments := v_difference + v_adjustments_total;

  -- v3-document-status-history (D7 / RN-A5): la diferencia de arqueo ≠ 0
  -- queda descripta como reason del cierre (señal antifraude, RN-95).
  -- banco-caja-historial-ajustes (D5): si hubo ajustes, el reason los nombra
  -- también — un ajuste que lleva la diferencia a cero queda evidenciado en
  -- el historial de transición, no solo en la fila.
  IF v_difference <> 0 THEN
    v_close_reason := format('diferencia de arqueo: %s (esperado %s, contado %s)',
                             v_difference, v_expected, p_counted_balance);
  END IF;

  IF v_adjustments_total <> 0 THEN
    v_close_reason := COALESCE(v_close_reason || '; ', '') ||
      format('ajustes de caja: %s (diferencia sin ajustes: %s)',
             v_adjustments_total, v_difference_before_adjustments);
  END IF;

  -- Cerrar la sesión — materializar arqueo (D7) + snapshot de ajustes (D5)
  UPDATE public.cash_sessions
  SET
    status             = 'closed',
    counted_balance    = p_counted_balance,
    expected_balance   = v_expected,
    difference         = v_difference,
    closing_balance    = p_counted_balance,
    adjustments_total  = v_adjustments_total,
    closed_by          = auth.uid(),
    closed_at          = now()
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
  -- banco-caja-historial-ajustes: suma adjustments_total al payload.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'CashSessionClosed', 'CashSession', p_session_id,
    jsonb_build_object(
      'session_id',         p_session_id,
      'branch_id',          v_branch_id,
      'difference',         v_difference,
      'adjustments_total',  v_adjustments_total,
      'closed_by',          auth.uid()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'session_id',                     p_session_id,
    'status',                         'closed',
    'opening_balance',                v_session.opening_balance,
    'expected_balance',               v_expected,
    'counted_balance',                p_counted_balance,
    'difference',                     v_difference,
    'closing_balance',                p_counted_balance,
    'adjustments_total',              v_adjustments_total,
    'difference_before_adjustments',  v_difference_before_adjustments
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_close_cash_session(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_close_cash_session(uuid, numeric, text) TO authenticated;

-- =============================================================================
-- 7. rpc_register_bank_movement — motivo obligatorio para manual_adjustment (D6)
-- =============================================================================
-- Firma SIN CAMBIOS (p_description ya existía como último parámetro opcional)
-- → CREATE OR REPLACE preserva ACL; REVOKE/GRANT explícito igual, por
-- higiene uniforme. El guard P0413 se agrega DESPUÉS de resolver la cuenta
-- bancaria (P0412) y ANTES de INSERT INTO operation_idempotency — una
-- llamada rechazada no debe quemar el slot de idempotencia (D6, task 3.10).

CREATE OR REPLACE FUNCTION public.rpc_register_bank_movement(p_idempotency_key text, p_bank_account_id uuid, p_amount numeric, p_type text, p_value_date date DEFAULT NULL::date, p_branch_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- banco-caja-historial-ajustes (D6, task 3.10): motivo obligatorio SOLO
  -- para manual_adjustment, ANTES de consumir el slot de idempotencia — una
  -- llamada rechazada no debe quemar la clave (task 3.11: reintentar con
  -- motivo debe poder usar la MISMA Idempotency-Key).
  IF p_type = 'manual_adjustment'
     AND (p_description IS NULL OR btrim(p_description) = '') THEN
    RAISE EXCEPTION 'adjustment_reason_required: un ajuste manual de banco requiere un motivo no vacío (p_description).'
      USING ERRCODE = 'P0413';
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
$function$;

REVOKE ALL ON FUNCTION public.rpc_register_bank_movement(text, uuid, numeric, text, date, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_register_bank_movement(text, uuid, numeric, text, date, uuid, text) TO authenticated;
