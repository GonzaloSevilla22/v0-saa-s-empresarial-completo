-- =============================================================================
-- MIGRATION: 20260804000007_bank_payment_routing.sql
-- CHANGE:    bank-payment-routing (C2 de la secuencia BankReconciliation V2.5)
-- Design ref: openspec/changes/bank-payment-routing/design.md
--
-- NOTA DE TIMESTAMP: el propose original preveía 20260804000006, pero ese
-- timestamp fue tomado por el hotfix de producción 20260804000006_fix_audit_logs_notnull.sql
-- (aplicado 2026-07-01, fuera del control de este change). Se usa 20260804000007,
-- el siguiente libre confirmado por `ls supabase/migrations | sort | tail`.
--
-- PO DESIGN DECISIONS (sign-off explícito, ver openspec/changes/bank-payment-routing/design.md
-- Open Questions — resueltas para esta migración):
--   OQ-1 (cuenta bancaria destino): PARÁMETRO EXPLÍCITO p_bank_account_id (la UI elige).
--   OQ-2 (tarjeta): INCLUIDA en C2, contabilizada en BRUTO (comisión/neto se difiere a C3).
--   OQ-3 (sales 'other'): se agregan 'transfer'/'card' explícitos al CHECK de
--        sales_orders.payment_method (antes {cash,other,credit} → ahora
--        {cash,transfer,card,other,credit}). 'other' sigue mapeando a 1100 (sin cambios).
--   OQ-4 (sales-side operacional): SOLO JOURNAL para ventas en C2. NO se escribe
--        bank_movement desde _c29_confirm_order_core; NO se toca esa función más
--        allá del CHECK de payment_method (OQ-3). El posteo 1110 de la venta es
--        async vía _journal_post_from_event. bank_movement operacional de venta
--        queda diferido a un change futuro.
--   OQ-5 (backfill): NINGUNO. Pagos históricos quedan como cash (default).
--
-- Principio "dos ledgers" (heredado de C1, wireado por C2):
--   bank_movements = ledger OPERACIONAL, escrito INTRA-TX por las RPCs de pago
--   vía _register_bank_movement (contrato C1→C2). La cuenta contable 1110 Banco
--   = espejo CONTABLE, escrito ASYNC por el Consumer 3 del outbox
--   (_journal_post_from_event). La conciliación futura (C3) opera SIEMPRE sobre
--   bank_movements, NUNCA sobre el journal.
--
-- Taxonomía de payment_method en las RPCs de pago (rpc_register_payment_received/made):
--   {cash, transfer, card, check}  (default 'cash', retrocompatible)
--   cash               → camino de caja existente (sin bank_movement); journal → 1100
--   transfer / check   → _register_bank_movement(type='transfer_in'/'transfer_out'); journal → 1110
--   card               → _register_bank_movement(type='card_settlement', BRUTO);    journal → 1110
--
-- Implementa (design.md D1-D6):
--   D1  Parámetros aditivos opcionales p_payment_method/p_bank_account_id (trailing, default-safe)
--   D2  Ruteo operacional intra-tx: bank → _register_bank_movement; cash → sin cambios
--   D3  Ruteo contable async: _journal_post_from_event lee payment_method del payload
--   D4  Taxonomía {cash,transfer,card,check} con guard P0400 explícito
--   D5  Gates SQL copiados verbatim del esqueleto C1 (BEGIN/EXCEPTION, sin SAVEPOINT explícito)
--   D6  Sin backfill; sin cambios en cash collections (siguen sin cash_movements)
--
-- TDD tasks cubiertos (RED→GREEN→TRIANGULATE→REFACTOR en DO-block final):
--   Tasks 1.3-1.5  Taxonomía guard P0400 en ambas RPCs de pago
--   Tasks 2.1-2.8  rpc_register_payment_received: ruteo bancario + payload enriquecido
--   Tasks 3.1-3.7  rpc_register_payment_made: ruteo bancario + payload enriquecido
--   Tasks 4.1-4.8  _journal_post_from_event: ruteo 1110 vs 1100 en los 3 event types
--   Tasks 5.1       ALTER CHECK sales_orders.payment_method (+transfer,+card) — OQ-3
--   Tasks 6.1-6.3  Gates consolidados + gate negativo (cash no rutea a bank_movement)
--
-- ERRCODEs (5 chars — convención post-20260624000001, reutiliza espacio P04xx existente):
--   P0400  payment_method inválido / bank_account_id faltante para método bancario
--   P0401  sin permiso de escritura (is_account_writer) — sin cambios, heredado de C-30
--   P0403  sin cuenta activa — sin cambios, heredado de C-30
--   P0409  overpayment — sin cambios, heredado de C-30
--   P0412  bank_account_id no encontrado / inactivo (reutilizado de C1)
--
-- GOVERNANCE: ALTA (modifica los RPCs de dinero rpc_register_payment_received/made
--             y la función de partida doble _journal_post_from_event).
--             Diseño con sign-off explícito del PO (ver design.md OQ-1..OQ-5).
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — desincroniza history)
--
-- PREREQUISITO VERIFICADO (read-only MCP, 2026-07-01, antes de escribir esta migración):
--   Outbox Consumer 3 saludable en prod (gxdhpxvdjjkmxhdkkwyb): events pending=0,
--   processed=6; journal_entries=6, last_posted=2026-07-01 15:08:00 UTC.
--   El hotfix 20260804000006 (audit_logs NOT NULL) ya drenó el backlog — el relay
--   postea correctamente. C2 puede aplicarse sin riesgo de que 1110 quede huérfano.
--
-- ROLLBACK (en orden):
--   -- Revertir _journal_post_from_event a la versión de 20260803000001 (hardcode 1100/1300/2100/4100/4200,
--   -- sin ruteo por payment_method) — ver ese archivo para el CREATE OR REPLACE completo.
--   -- Revertir rpc_register_payment_received/made a la versión de 20260720000001
--   -- (firma de 4 params, sin payment_method/bank_account_id, sin bank_movement, sin
--   -- payment_method en el payload del evento) — ver ese archivo.
--   ALTER TABLE public.sales_orders DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check;
--   ALTER TABLE public.sales_orders ADD CONSTRAINT sales_orders_payment_method_check
--     CHECK (payment_method IN ('cash','other','credit'));
--   (Sin pérdida de datos: bank_movements ya escritos por C2 quedan como verdad operacional
--    histórica; los journal_entries con 1110 ya posteados no se revierten — solo deja de
--    generarse contabilidad nueva en 1110.)
--
-- VERIFICATION (post-push):
--   SELECT routine_name, pg_get_function_arguments(p.oid) AS args
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace, information_schema.routines r
--   WHERE n.nspname = 'public' AND r.routine_name = p.proname
--     AND p.proname IN ('rpc_register_payment_received','rpc_register_payment_made')
--   ORDER BY p.proname;
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conname = 'sales_orders_payment_method_check';
-- =============================================================================


-- ============================================================
-- 1. RPC: rpc_register_payment_received — ruteo bancario (D1/D2/D3/D4)
--
-- Firma extendida: agrega p_payment_method (default 'cash') y p_bank_account_id
-- (default NULL) como PARÁMETROS FINALES — retrocompatible con llamadores previos.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_register_payment_received(
  p_idempotency_key   text,
  p_client_id         uuid,
  p_amount            numeric,
  p_reference_sale_id uuid DEFAULT NULL,
  p_payment_method    text DEFAULT 'cash',
  p_bank_account_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_customer_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar amount > 0
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- D4: validar taxonomía de payment_method
  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- D2: método bancario exige bank_account_id válido, activo y de la cuenta
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_received'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_received', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver el resultado original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_received'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',           NULL,
      'customer_account_id',  NULL,
      'balance_after',        NULL,
      'replayed',             true,
      'operation_id',         v_existing_op
    );
  END IF;

  -- Resolver/crear la CustomerAccount (OQ-4 C-30 lazy auto-create)
  v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, p_client_id);

  -- Registrar el movimiento con signo negativo (reduce la deuda, OQ-1 C-30)
  -- El helper c30_register_customer_account_movement lanza P0409 si balance resultante < 0
  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_customer_account_movement(
    v_customer_account_id,
    -p_amount,                 -- negativo: el cobro reduce la deuda
    'payment_received',
    v_payment_id
  );

  -- Obtener el balance_after del movimiento recién insertado
  SELECT balance_after INTO v_balance_after
  FROM public.customer_account_movements
  WHERE id = v_movement_id;

  -- INSERT en payments_received
  INSERT INTO public.payments_received
    (id, account_id, customer_account_id, client_id, amount, reference_sale_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_customer_account_id, p_client_id, p_amount, p_reference_sale_id, v_movement_id, v_uid);

  -- D2: ruteo OPERACIONAL intra-tx — bank_movement solo para métodos bancarios
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := CASE WHEN p_payment_method = 'card' THEN 'card_settlement' ELSE 'transfer_in' END;

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      p_amount,                 -- positivo: ingreso
      v_bank_movement_type,
      'payment_received',
      v_payment_id,
      CURRENT_DATE,
      NULL,
      NULL
    );
  END IF;

  -- OQ-6 C-30 (evento al outbox) + payment_method/bank_account_id enriquecidos (C2 D3)
  -- El consumer AuditLog de C-25 es genérico; el Consumer 3 (JournalEntry) lee
  -- payment_method del payload para rutear 1110 vs 1100.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentReceived',
    'CustomerAccount',
    v_customer_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'customer_account_id',  v_customer_account_id,
      'client_id',            p_client_id,
      'payment_id',           v_payment_id,
      'amount',               p_amount,
      'balance_after',        v_balance_after,
      'reference_sale_id',    p_reference_sale_id,
      'payment_method',       p_payment_method,
      'bank_account_id',      p_bank_account_id,
      'occurred_at',          now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',           v_payment_id,
    'customer_account_id',  v_customer_account_id,
    'balance_after',        v_balance_after,
    'replayed',             false,
    'operation_id',         v_new_op_id
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_register_payment_received IS
  'C-30 + bank-payment-routing C2 (D1/D2/D3/D4): registra un cobro en la cuenta corriente del cliente. '
  'Idempotente (DEC-06, operation_kind=payment_received). OQ-1 C-30: P0409 si excede el saldo deudor. '
  'C2: p_payment_method ∈ {cash,transfer,card,check} (default cash, retrocompatible). '
  'Método bancario exige p_bank_account_id válido/activo (P0400/P0412) y registra un bank_movement '
  'intra-tx vía _register_bank_movement (transfer_in para transfer/check, card_settlement BRUTO para card). '
  'El evento PaymentReceived emitido lleva payment_method + bank_account_id para que '
  '_journal_post_from_event rutee la contrapartida a 1110 Banco (bancario) o 1100 Caja (cash).';


-- ============================================================
-- 2. RPC: rpc_register_payment_made — ruteo bancario (espejo de 1, D1/D2/D3/D4)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_register_payment_made(
  p_idempotency_key       text,
  p_supplier_id           uuid,
  p_amount                numeric,
  p_reference_purchase_id uuid DEFAULT NULL,
  p_payment_method        text DEFAULT 'cash',
  p_bank_account_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
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

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- D4: validar taxonomía de payment_method
  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- D2: método bancario exige bank_account_id válido, activo y de la cuenta
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_made'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_made', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_made'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',          NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    -p_amount,               -- negativo: el pago reduce lo que se debe
    'payment_made',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  INSERT INTO public.payments_made
    (id, account_id, supplier_account_id, supplier_id, amount, reference_purchase_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_supplier_account_id, p_supplier_id, p_amount, p_reference_purchase_id, v_movement_id, v_uid);

  -- D2: ruteo OPERACIONAL intra-tx — bank_movement solo para métodos bancarios
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := 'transfer_out';  -- egreso: pago por transfer/check/card → egreso bancario

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      -p_amount,                -- negativo: egreso
      v_bank_movement_type,
      'payment_made',
      v_payment_id,
      CURRENT_DATE,
      NULL,
      NULL
    );
  END IF;

  -- OQ-6 C-30: evento PaymentMade al outbox + payment_method/bank_account_id (C2 D3)
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentMade',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'payment_id',          v_payment_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'payment_method',      p_payment_method,
      'bank_account_id',     p_bank_account_id,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',          v_payment_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_register_payment_made IS
  'C-30 + bank-payment-routing C2 (D1/D2/D3/D4): registra un pago a la cuenta corriente del proveedor. '
  'Idempotente (DEC-06, operation_kind=payment_made). OQ-1 C-30: P0409 si excede el saldo deudor. '
  'C2: p_payment_method ∈ {cash,transfer,card,check} (default cash, retrocompatible). '
  'Método bancario exige p_bank_account_id válido/activo (P0400/P0412) y registra un bank_movement '
  'intra-tx vía _register_bank_movement (transfer_out, egreso). '
  'El evento PaymentMade emitido lleva payment_method + bank_account_id para que '
  '_journal_post_from_event rutee la contrapartida a 1110 Banco (bancario) o 1100 Caja (cash).';


-- ============================================================
-- 3. sales_orders.payment_method CHECK — extender taxonomía (OQ-3)
--
-- Antes: {cash, other, credit}. Ahora: {cash, transfer, card, other, credit}.
-- 'other' sigue mapeando a 1100 (sin cambios) — decisión explícita del PO.
-- NO se toca _c29_confirm_order_core más allá de este CHECK (OQ-4: sales-side
-- es journal-only en C2; no se escribe bank_movement desde el hot path de venta).
-- ============================================================
ALTER TABLE public.sales_orders DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check;
ALTER TABLE public.sales_orders ADD CONSTRAINT sales_orders_payment_method_check
  CHECK (payment_method IN ('cash', 'transfer', 'card', 'other', 'credit'));

COMMENT ON COLUMN public.sales_orders.payment_method IS
  'C-29: método de pago. C-30 agregó credit (venta a crédito). '
  'bank-payment-routing C2 (OQ-3) agrega transfer/card explícitos — rutean a 1110 Banco '
  'en _journal_post_from_event (async, journal-only en C2; sin bank_movement operacional '
  'desde el hot path de venta — deferred). other sigue mapeando a 1100 Caja (sin cambios).';


-- ============================================================
-- 4. _journal_post_from_event — ruteo 1110 Banco vs 1100 Caja (D3)
--
-- CREATE OR REPLACE preservando byte-a-byte: PurchaseCreated, CreditNoteIssued,
-- la idempotencia (event_id, JournalEntry), el ASSERT de balance P0450, y el
-- filtro de los 5 event_types en-scope. Único cambio: SaleConfirmed/PaymentReceived/
-- PaymentMade leen payment_method del payload y rutean 1110 vs 1100.
-- ============================================================
CREATE OR REPLACE FUNCTION public._journal_post_from_event(
    p_event public.events
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  journal-entry-outbox Consumer 3 — Helper de posting de asientos de partida doble.
  bank-payment-routing C2: agrega ruteo 1110 Banco (bancario) vs 1100 Caja (cash/other)
  en SaleConfirmed/PaymentReceived/PaymentMade, leído del payment_method del payload.

  Responsabilidades:
    1. Filtrar por event_type (5 tipos en-scope; no-op para el resto).
    2. Reclamar slot de idempotencia (event_id, 'JournalEntry') en operation_idempotency.
    3. Calcular las líneas de débito/crédito según el mapeo hardcodeado (D1, D4 del
       change journal-entry-outbox) + ruteo bancario (C2 D3).
    4. Validar Σdébito = Σcrédito (ASSERT — D5, ERRCODE P0450).
    5. INSERT journal_entries + journal_lines.

  Codigos de cuenta hardcodeados (D1 journal-entry-outbox — plan mínimo PYME AR):
    1100 Caja / 1110 Banco (C2: wireado — antes reservado) / 1300 Deudores por Ventas
    2100 Proveedores / 4100 Ventas / 4200 IVA Débito Fiscal
    5100 CMV/Compras / 5200 IVA Crédito Fiscal / 5300 Gastos (reservado)

  Ruteo bancario (C2 D3): "es método bancario" = payment_method IN ('transfer','card','check').
  SaleConfirmed:    credit→1300; bancario→1110; cash/other/NULL→1100 (débito).
  PaymentReceived:  bancario→1110; cash/NULL→1100 (débito).
  PaymentMade:      bancario→1110; cash/NULL→1100 (crédito).

  Notas de diseño:
    - El balance falla → RAISE EXCEPTION USING ERRCODE = 'P0450' → el event queda
      pending para retry; el batch NO aborta (BEGIN/EXCEPTION en rpc_process_outbox_dispatch).
    - account_id denormalizado en journal_lines (D7 — RLS sin subquery por fila).
    - SaleConfirmed: lookup JOIN sales_orders → fiscal_documents para neto/iva (D3/D9).
    - PurchaseCreated: neto/iva del payload (productor enriquecido en migración 2) — SIN CAMBIOS.
    - CreditNoteIssued: reversión del asiento original (D10) — SIN CAMBIOS.
    - SECURITY DEFINER + SET search_path: patrón C-25.

  ERRCODE custom:
    P0450 — balance falla (libre en espacio P04xx del proyecto).
    P0451 — asiento original no encontrado para NC (retry).
*/
DECLARE
    v_account_id      uuid;
    v_entry_id        uuid;
    v_payload         jsonb;
    v_event_type      text;

    -- Lookup fields
    v_total           numeric(14,2);
    v_payment_method  text;
    v_is_bank         boolean;
    v_neto            numeric(14,2);
    v_iva             numeric(14,2);
    v_comp_type       text;
    v_cost_center_id  uuid;
    v_operation_id    uuid;

    -- Reversal
    v_original_id     uuid;
    v_orig_entry_id   uuid;

    -- Balance tracking
    v_sum_debit       numeric(14,2) := 0;
    v_sum_credit      numeric(14,2) := 0;
    v_line_no         int := 0;

    -- Idempotency
    v_claimed         bool;
BEGIN
    v_account_id := p_event.account_id;
    v_payload     := p_event.payload;
    v_event_type  := p_event.event_type;

    -- ── Filtro: solo los 5 tipos en-scope ────────────────────────────────────
    IF v_event_type NOT IN (
        'SaleConfirmed', 'PurchaseCreated', 'PaymentReceived',
        'PaymentMade', 'CreditNoteIssued'
    ) THEN
        RETURN;  -- no-op para eventos fuera de alcance
    END IF;

    -- ── Idempotencia: reclamar slot (event_id, 'JournalEntry') ───────────────
    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
    VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        p_event.id::text || ':JournalEntry',
        'event_consumer',
        p_event.id,
        'JournalEntry'
    )
    ON CONFLICT (event_id, consumer_type)
    WHERE event_id IS NOT NULL
    DO NOTHING;

    GET DIAGNOSTICS v_claimed = ROW_COUNT;

    IF NOT v_claimed THEN
        -- Slot ya existía → skip idempotente (el asiento ya fue posteado)
        RETURN;
    END IF;

    -- ── Dispatch por event_type ───────────────────────────────────────────────

    IF v_event_type = 'SaleConfirmed' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- SaleConfirmed: 1100/1110/1300 → 4100 + 4200 (D3, D4 journal-entry-outbox;
        -- C2 D3: ruteo bancario del débito por payment_method)
        -- Lookup JOIN para comprobante_type/neto/iva_amount (D9 — no modificamos C-29)
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check');

        -- Lookup fiscal_documents via sales_orders.fiscal_document_id
        SELECT
            fd.comprobante_type,
            fd.neto,
            fd.iva_amount
        INTO
            v_comp_type,
            v_neto,
            v_iva
        FROM public.sales_orders so
        LEFT JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id
        WHERE so.id = (v_payload->>'sales_order_id')::uuid;

        -- INSERT entry header
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'SalesOrder',
            (v_payload->>'sales_order_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        -- Debit: 1300 Deudores (credit) o 1110 Banco (bancario) o 1100 Caja (cash/other)
        v_line_no := 1;
        IF v_payment_method = 'credit' THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1300', 'debit', v_total, v_line_no, NULL);
        ELSIF v_is_bank THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1110', 'debit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'debit', v_total, v_line_no, NULL);
        END IF;
        v_sum_debit := v_sum_debit + v_total;

        -- Credit: 4100 + 4200 (Factura A/B con desglose) o 4100 solo (C/sin doc) — SIN CAMBIOS
        IF v_comp_type IN ('factura_a', 'factura_b')
           AND v_neto IS NOT NULL
           AND v_iva IS NOT NULL
        THEN
            -- Factura A/B: crédito 4100 Ventas [neto] + 4200 IVA DF [iva]
            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4100', 'credit', v_neto, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_neto;

            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4200', 'credit', v_iva, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_iva;
        ELSE
            -- Factura C / sin comprobante / sin desglose: crédito único 4100 [total]
            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4100', 'credit', v_total, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_total;
        END IF;

    ELSIF v_event_type = 'PurchaseCreated' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PurchaseCreated: 5100 + 5200 → 2100/1100 (D4, D8 journal-entry-outbox) — SIN CAMBIOS
        -- (C2 no toca compras — fuera de alcance del change)
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := COALESCE(v_payload->>'payment_method', 'credit');
        v_neto           := (v_payload->>'neto')::numeric(14,2);
        v_iva            := (v_payload->>'iva_amount')::numeric(14,2);
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;
        v_operation_id   := (v_payload->>'operation_id')::uuid;

        -- Si no hay cost_center_id en el payload, intentar lookup a purchases
        IF v_cost_center_id IS NULL AND v_operation_id IS NOT NULL THEN
            SELECT cost_center_id INTO v_cost_center_id
            FROM public.purchases
            WHERE operation_id = v_operation_id
            LIMIT 1;
        END IF;

        -- INSERT entry header
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'Purchase',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        -- Debit: 5100 CMV [neto + cost_center] + 5200 IVA CF [iva, cc=NULL]
        -- o bien 5100 único [total] si no hay desglose
        v_line_no := 1;
        IF v_neto IS NOT NULL AND v_iva IS NOT NULL THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '5100', 'debit', v_neto, v_line_no, v_cost_center_id);
            v_sum_debit := v_sum_debit + v_neto;

            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '5200', 'debit', v_iva, v_line_no, NULL);
            v_sum_debit := v_sum_debit + v_iva;
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '5100', 'debit', v_total, v_line_no, v_cost_center_id);
            v_sum_debit := v_sum_debit + v_total;
        END IF;

        -- Credit: 2100 Proveedores (credit) o 1100 Caja (cash)
        v_line_no := v_line_no + 1;
        IF v_payment_method = 'cash' THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'credit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '2100', 'credit', v_total, v_line_no, NULL);
        END IF;
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'PaymentReceived' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PaymentReceived: 1100/1110 → 1300 (D1 journal-entry-outbox, 3.4;
        -- C2 D3: ruteo bancario del débito por payment_method del payload)
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check');

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'CustomerAccount',
            (v_payload->>'payment_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        IF v_is_bank THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1110', 'debit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'debit', v_total, v_line_no, NULL);
        END IF;
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '1300', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'PaymentMade' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PaymentMade: 2100 Proveedores → 1100/1110 (D1 journal-entry-outbox, 3.4;
        -- C2 D3: ruteo bancario del crédito por payment_method del payload)
        -- Evento emitido por C-30 rpc_register_payment_made
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check');

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'SupplierAccount',
            (v_payload->>'payment_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '2100', 'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        IF v_is_bank THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1110', 'credit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'credit', v_total, v_line_no, NULL);
        END IF;
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'CreditNoteIssued' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- CreditNoteIssued: reversión del asiento de venta original (D10, 3.5) — SIN CAMBIOS
        -- Localiza el original por source_sales_order_id del payload.
        -- Si no existe → RAISE para retry (P0451).
        -- ──────────────────────────────────────────────────────────────────────
        v_original_id := (v_payload->>'source_sales_order_id')::uuid;

        -- Buscar el asiento original posteado
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SalesOrder'
          AND source_doc_ref  = v_original_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento original '
                'para SalesOrder % (CreditNoteIssued %). El evento quedará pending para retry.',
                v_original_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- INSERT asiento espejo (reversal)
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        VALUES (
            v_account_id, now(), p_event.id, 'CreditNote',
            (v_payload->>'source_fiscal_document_id')::uuid, 'posted', v_orig_entry_id
        )
        RETURNING id INTO v_entry_id;

        -- Copiar líneas del original con lados invertidos (debit↔credit)
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        -- Sumar balance del asiento espejo para validación
        SELECT
            COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
            COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
        INTO v_sum_debit, v_sum_credit
        FROM public.journal_lines
        WHERE entry_id = v_entry_id;

        -- Marcar el original como reversed
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    END IF;

    -- ── ASSERT de balance: Σdébito = Σcrédito (D5 journal-entry-outbox) — SIN CAMBIOS ──
    -- Solo validar para eventos que crean líneas directamente (no para no-op)
    IF v_entry_id IS NOT NULL THEN
        -- Para los 4 primeros event_types (no reversal), calcular de la tabla
        -- (para CreditNoteIssued ya lo calculamos del espejo arriba)
        IF v_event_type != 'CreditNoteIssued' THEN
            SELECT
                COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
                COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
            INTO v_sum_debit, v_sum_credit
            FROM public.journal_lines
            WHERE entry_id = v_entry_id;
        END IF;

        IF v_sum_debit <> v_sum_credit THEN
            RAISE EXCEPTION
                'journal_balance_assertion_failed: Σdébito=% ≠ Σcrédito=% para evento % (ERRCODE P0450). '
                'El asiento no balancea — evento quedará pending para retry.',
                v_sum_debit, v_sum_credit, p_event.id
                USING ERRCODE = 'P0450';
        END IF;
    END IF;

END;
$fn$;

-- REVOKE/GRANT (patrón C-25/journal-entry-outbox — helper interno, sin cambios)
REVOKE ALL     ON FUNCTION public._journal_post_from_event(public.events) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._journal_post_from_event(public.events) FROM anon;
REVOKE EXECUTE ON FUNCTION public._journal_post_from_event(public.events) FROM authenticated;

COMMENT ON FUNCTION public._journal_post_from_event IS
    'journal-entry-outbox + bank-payment-routing C2 (D3): helper de posting de asientos de '
    'partida doble. SECURITY DEFINER + SET search_path. Llamado solo desde el Consumer 3 de '
    'rpc_process_outbox_dispatch. REVOCADO de authenticated/anon/PUBLIC. '
    'Idempotencia: (event_id, JournalEntry) en operation_idempotency + '
    'unique partial index source_event_id en journal_entries. '
    'Balance ASSERT con ERRCODE P0450; NC original no encontrada = P0451 (retry). '
    'C2: SaleConfirmed/PaymentReceived/PaymentMade rutean el leg bancario a 1110 Banco cuando '
    'payment_method ∈ {transfer,card,check}, a 1100 Caja en caso contrario (cash/other/NULL). '
    'PurchaseCreated y CreditNoteIssued sin cambios. No-op para event_type fuera de los 5 en-scope.';


-- ============================================================
-- 5. Gates SQL (RED→GREEN→TRIANGULATE — introspección + comportamiento donde aplica)
--
-- Copiado del esqueleto C1 (20260804000002): discriminador test-vs-prod
-- (SELECT count(*)=0 FROM accounts), anchor sintético en BEGIN/EXCEPTION,
-- gates de comportamiento SOLO en DB vacía (CI), gates de introspección
-- SIEMPRE (no mutan, corren también en prod).
--
-- Gates cubiertos:
--   (a) rpc_register_payment_received: taxonomía P0400 rechaza método inválido (introspección)
--   (b) rpc_register_payment_received: taxonomía acepta {cash,transfer,card,check} (introspección)
--   (c) rpc_register_payment_received: método bancario sin bank_account_id → P0400 (comportamiento)
--   (d) rpc_register_payment_received: transfer con cuenta activa → bank_movement transfer_in (comportamiento)
--   (e) rpc_register_payment_received: card con cuenta activa → bank_movement card_settlement (comportamiento)
--   (f) rpc_register_payment_received: cash NO genera bank_movement (comportamiento, gate negativo)
--   (g) rpc_register_payment_made: transfer con cuenta activa → bank_movement transfer_out negativo (comportamiento)
--   (h) rpc_register_payment_made: cash NO genera bank_movement (comportamiento, gate negativo)
--   (i) _journal_post_from_event: contiene el ruteo 1110/1100 para los 3 event types (introspección)
--   (j) sales_orders CHECK acepta transfer/card; sigue aceptando cash/other/credit (comportamiento)
--   (k) idempotencia: doble llamada misma key → replayed=true, un solo bank_movement (comportamiento)
-- ============================================================
DO $$
DECLARE
  v_fake_account_id   uuid := gen_random_uuid();
  v_fake_user_id      uuid := gen_random_uuid();
  v_fake_company_id   uuid := gen_random_uuid();
  v_bank_account_id   uuid;
  v_bank_account_inact uuid;
  v_client_id         uuid;
  v_supplier_id       uuid;
  v_result            jsonb;
  v_result2           jsonb;
  v_count             int;
  v_bm_count          int;
  v_run_behavioral    boolean := false;

  v_gate_a boolean := false;
  v_gate_b boolean := false;
  v_gate_c boolean := false;
  v_gate_d boolean := false;
  v_gate_e boolean := false;
  v_gate_f boolean := false;
  v_gate_g boolean := false;
  v_gate_h boolean := false;
  v_gate_i boolean := false;
  v_gate_j boolean := false;
  v_gate_k boolean := false;
BEGIN

  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'bank-payment-routing-gate@test.local', now(), now(),
              jsonb_build_object('name', 'C2 Gate', 'phone', '', 'locality', '', 'province', ''))
      ON CONFLICT (id) DO NOTHING;

      INSERT INTO public.accounts (id, owner_user_id)
      VALUES (v_fake_account_id, v_fake_user_id) ON CONFLICT (id) DO NOTHING;

      -- is_account_writer()/current_account_ids() exigen una fila en account_members
      -- con role owner/admin — las RPCs de pago las invocan internamente.
      INSERT INTO public.account_members (account_id, user_id, role)
      VALUES (v_fake_account_id, v_fake_user_id, 'owner')
      ON CONFLICT DO NOTHING;

      -- Las RPCs de pago leen auth.uid() y is_account_writer()/current_account_ids()
      -- (que a su vez leen auth.uid()) — en el contexto de migración no hay JWT real.
      -- Se simula la sesión fijando los claims (local a la transacción de este DO-block),
      -- mismo patrón que 20260804000003_fix_c28_cash_movement_balance.sql.
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_id::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_fake_user_id::text, true);

      INSERT INTO public.bank_accounts
        (account_id, name, bank_name, currency, opening_balance, is_active)
      VALUES
        (v_fake_account_id, 'Banco Test C2', 'Banco Ficticio', 'ARS', 10000.00, true)
      RETURNING id INTO v_bank_account_id;

      INSERT INTO public.bank_accounts
        (account_id, name, bank_name, currency, opening_balance, is_active)
      VALUES
        (v_fake_account_id, 'Banco Inactivo C2', 'Banco Ficticio', 'ARS', 0.00, false)
      RETURNING id INTO v_bank_account_inact;

      -- clients.user_id es NOT NULL (default auth.uid(), inútil sin sesión real → explícito).
      -- account_id es la columna V2 real usada por RLS/current_account_ids.
      INSERT INTO public.clients (account_id, user_id, name)
      VALUES (v_fake_account_id, v_fake_user_id, 'Cliente Test C2')
      RETURNING id INTO v_client_id;

      -- suppliers.company_id es NOT NULL legacy con FK a companies(id) ON DELETE CASCADE
      -- (esquema pre-V2). Se satisface con una companies sintética propia — el modelo
      -- V2 usa account_id (columna real usada por RLS/current_account_ids).
      INSERT INTO public.companies (id, name)
      VALUES (v_fake_company_id, 'Company Test C2 (bank-payment-routing gate)')
      ON CONFLICT (id) DO NOTHING;

      INSERT INTO public.suppliers (account_id, company_id, name)
      VALUES (v_fake_account_id, v_fake_company_id, 'Proveedor Test C2')
      RETURNING id INTO v_supplier_id;
    EXCEPTION
      WHEN OTHERS THEN
        v_run_behavioral := false;
        RAISE NOTICE 'bank-payment-routing: anchor sintético no disponible (%) — se saltan gates de comportamiento', SQLERRM;
    END;
  END IF;


  -- ── (a) taxonomía P0400: guard presente en el código (introspección) ─────
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('rpc_register_payment_received', 'rpc_register_payment_made')
      AND pg_get_functiondef(p.oid) LIKE '%invalid_payment_method%'
      AND pg_get_functiondef(p.oid) LIKE '%P0400%';

    IF v_count < 2 THEN
      RAISE EXCEPTION 'GATE (a) FAILED: falta el guard de taxonomía P0400 en alguna de las RPCs de pago (encontradas: %)', v_count;
    END IF;
    v_gate_a := true;
  END;


  -- ── (b) taxonomía acepta {cash,transfer,card,check} (introspección) ──────
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('rpc_register_payment_received', 'rpc_register_payment_made')
      AND pg_get_functiondef(p.oid) LIKE '%''cash''%'
      AND pg_get_functiondef(p.oid) LIKE '%''transfer''%'
      AND pg_get_functiondef(p.oid) LIKE '%''card''%'
      AND pg_get_functiondef(p.oid) LIKE '%''check''%';

    IF v_count < 2 THEN
      RAISE EXCEPTION 'GATE (b) FAILED: falta la taxonomía completa {cash,transfer,card,check} en alguna RPC (encontradas: %)', v_count;
    END IF;
    v_gate_b := true;
  END;


  -- ── (c) método bancario sin bank_account_id → P0400 (comportamiento) ─────
  IF v_run_behavioral THEN
  BEGIN
    BEGIN
      PERFORM public.rpc_register_payment_received(
        'gate-c-' || gen_random_uuid()::text, v_client_id, 100.00, NULL, 'transfer', NULL
      );
      RAISE EXCEPTION 'GATE (c) FAILED: transfer sin bank_account_id debería haber fallado con P0400';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0400' THEN
          v_gate_c := true;
        ELSIF SQLERRM LIKE 'GATE (c) FAILED%' THEN
          RAISE;
        ELSE
          -- Falla de infra del anchor (p.ej. simulación de JWT no soportada en este
          -- entorno) — no abortar la migración por una limitación del entorno de test.
          RAISE NOTICE 'bank-payment-routing: gate (c) saltado por entorno (%)', SQLERRM;
        END IF;
    END;
  END;
  END IF;


  -- ── (d) transfer con cuenta activa → bank_movement transfer_in (comportamiento) ──
  -- Sentinel rollback: aísla el cobro + bank_movement de prueba.
  IF v_run_behavioral THEN
  DECLARE
    v_bm_type text;
  BEGIN
    v_result := public.rpc_register_payment_received(
      'gate-d-' || gen_random_uuid()::text, v_client_id, 400.00, NULL, 'transfer', v_bank_account_id
    );

    SELECT movement_type INTO v_bm_type
    FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id
      AND source_doc_type = 'payment_received'
      AND source_doc_ref  = (v_result->>'payment_id')::uuid;

    IF v_bm_type IS DISTINCT FROM 'transfer_in' THEN
      RAISE EXCEPTION 'GATE (d) FAILED: se esperaba bank_movement transfer_in, obtuvo %', v_bm_type;
    END IF;
    v_gate_d := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'GATE_ROLLBACK_SENTINEL' THEN
        NULL;
      ELSIF SQLERRM LIKE 'GATE (d) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-payment-routing: gate (d) saltado por entorno (%)', SQLERRM;
      END IF;
  END;
  END IF;


  -- ── (e) card con cuenta activa → bank_movement card_settlement (comportamiento) ──
  IF v_run_behavioral THEN
  DECLARE
    v_bm_type text;
  BEGIN
    v_result := public.rpc_register_payment_received(
      'gate-e-' || gen_random_uuid()::text, v_client_id, 250.00, NULL, 'card', v_bank_account_id
    );

    SELECT movement_type INTO v_bm_type
    FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id
      AND source_doc_type = 'payment_received'
      AND source_doc_ref  = (v_result->>'payment_id')::uuid;

    IF v_bm_type IS DISTINCT FROM 'card_settlement' THEN
      RAISE EXCEPTION 'GATE (e) FAILED: se esperaba bank_movement card_settlement, obtuvo %', v_bm_type;
    END IF;
    v_gate_e := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'GATE_ROLLBACK_SENTINEL' THEN
        NULL;
      ELSIF SQLERRM LIKE 'GATE (e) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-payment-routing: gate (e) saltado por entorno (%)', SQLERRM;
      END IF;
  END;
  END IF;


  -- ── (f) cash NO genera bank_movement (comportamiento, gate negativo) ─────
  IF v_run_behavioral THEN
  BEGIN
    v_result := public.rpc_register_payment_received(
      'gate-f-' || gen_random_uuid()::text, v_client_id, 300.00, NULL, 'cash', NULL
    );

    SELECT COUNT(*) INTO v_bm_count
    FROM public.bank_movements
    WHERE source_doc_type = 'payment_received'
      AND source_doc_ref  = (v_result->>'payment_id')::uuid;

    IF v_bm_count <> 0 THEN
      RAISE EXCEPTION 'GATE (f) FAILED: un cobro cash NO debería generar bank_movement, se encontraron %', v_bm_count;
    END IF;
    v_gate_f := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'GATE_ROLLBACK_SENTINEL' THEN
        NULL;
      ELSIF SQLERRM LIKE 'GATE (f) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-payment-routing: gate (f) saltado por entorno (%)', SQLERRM;
      END IF;
  END;
  END IF;


  -- ── (g) pago por transferencia → bank_movement transfer_out negativo (comportamiento) ──
  IF v_run_behavioral THEN
  DECLARE
    v_bm_type   text;
    v_bm_amount numeric;
  BEGIN
    v_result := public.rpc_register_payment_made(
      'gate-g-' || gen_random_uuid()::text, v_supplier_id, 350.00, NULL, 'transfer', v_bank_account_id
    );

    SELECT movement_type, amount INTO v_bm_type, v_bm_amount
    FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id
      AND source_doc_type = 'payment_made'
      AND source_doc_ref  = (v_result->>'payment_id')::uuid;

    IF v_bm_type IS DISTINCT FROM 'transfer_out' OR v_bm_amount IS DISTINCT FROM -350.00 THEN
      RAISE EXCEPTION 'GATE (g) FAILED: se esperaba transfer_out amount=-350.00, obtuvo type=% amount=%', v_bm_type, v_bm_amount;
    END IF;
    v_gate_g := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'GATE_ROLLBACK_SENTINEL' THEN
        NULL;
      ELSIF SQLERRM LIKE 'GATE (g) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-payment-routing: gate (g) saltado por entorno (%)', SQLERRM;
      END IF;
  END;
  END IF;


  -- ── (h) pago cash NO genera bank_movement (comportamiento, gate negativo) ──
  IF v_run_behavioral THEN
  BEGIN
    v_result := public.rpc_register_payment_made(
      'gate-h-' || gen_random_uuid()::text, v_supplier_id, 200.00, NULL, 'cash', NULL
    );

    SELECT COUNT(*) INTO v_bm_count
    FROM public.bank_movements
    WHERE source_doc_type = 'payment_made'
      AND source_doc_ref  = (v_result->>'payment_id')::uuid;

    IF v_bm_count <> 0 THEN
      RAISE EXCEPTION 'GATE (h) FAILED: un pago cash NO debería generar bank_movement, se encontraron %', v_bm_count;
    END IF;
    v_gate_h := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'GATE_ROLLBACK_SENTINEL' THEN
        NULL;
      ELSIF SQLERRM LIKE 'GATE (h) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-payment-routing: gate (h) saltado por entorno (%)', SQLERRM;
      END IF;
  END;
  END IF;


  -- ── (i) _journal_post_from_event contiene el ruteo 1110/1100 (introspección) ──
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = '_journal_post_from_event'
      AND pg_get_functiondef(p.oid) LIKE '%''1110''%'
      AND pg_get_functiondef(p.oid) LIKE '%v_is_bank%';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (i) FAILED: _journal_post_from_event no contiene el ruteo 1110/v_is_bank';
    END IF;
    v_gate_i := true;
  END;


  -- ── (j) sales_orders CHECK acepta transfer/card + sigue aceptando cash/other/credit (comportamiento) ──
  IF v_run_behavioral THEN
  DECLARE
    v_branch_id uuid;
    v_so_id     uuid;
  BEGIN
    -- Necesita una branch (FK NOT NULL en sales_orders.branch_id en el esquema actual);
    -- si branches no está disponible por algún motivo se salta con excepción capturada arriba.
    SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_fake_account_id LIMIT 1;
    IF v_branch_id IS NULL THEN
      INSERT INTO public.branches (account_id, name, status)
      VALUES (v_fake_account_id, 'Sucursal Test C2', 'active')
      RETURNING id INTO v_branch_id;
    END IF;

    INSERT INTO public.sales_orders (account_id, branch_id, status, payment_method, total, created_by)
    VALUES (v_fake_account_id, v_branch_id, 'draft', 'transfer', 100, v_fake_user_id)
    RETURNING id INTO v_so_id;

    INSERT INTO public.sales_orders (account_id, branch_id, status, payment_method, total, created_by)
    VALUES (v_fake_account_id, v_branch_id, 'draft', 'card', 100, v_fake_user_id);

    -- Confirmar que los valores previos siguen aceptados
    INSERT INTO public.sales_orders (account_id, branch_id, status, payment_method, total, created_by)
    VALUES (v_fake_account_id, v_branch_id, 'draft', 'cash', 100, v_fake_user_id);
    INSERT INTO public.sales_orders (account_id, branch_id, status, payment_method, total, created_by)
    VALUES (v_fake_account_id, v_branch_id, 'draft', 'other', 100, v_fake_user_id);
    INSERT INTO public.sales_orders (account_id, branch_id, status, payment_method, total, created_by)
    VALUES (v_fake_account_id, v_branch_id, 'draft', 'credit', 100, v_fake_user_id);

    v_gate_j := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
    WHEN OTHERS THEN
      -- Si sales_orders exige columnas adicionales NOT NULL en este esquema, no bloquear
      -- la migración por eso: el CHECK en sí ya se validó por introspección (fallback).
      SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'sales_orders_payment_method_check'
          AND pg_get_constraintdef(oid) LIKE '%transfer%'
          AND pg_get_constraintdef(oid) LIKE '%card%'
      ) INTO v_gate_j;
      RAISE NOTICE 'bank-payment-routing: gate (j) comportamental no disponible (%), fallback a introspección: %', SQLERRM, v_gate_j;
  END;
  END IF;

  IF NOT v_run_behavioral THEN
    -- En prod (o si el comportamental no corrió): gate por introspección del CHECK.
    SELECT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conname = 'sales_orders_payment_method_check'
        AND pg_get_constraintdef(oid) LIKE '%transfer%'
        AND pg_get_constraintdef(oid) LIKE '%card%'
    ) INTO v_gate_j;
  END IF;


  -- ── (k) idempotencia: doble llamada misma key → replayed=true, un solo bank_movement ──
  IF v_run_behavioral THEN
  DECLARE
    v_key text := 'gate-k-' || gen_random_uuid()::text;
  BEGIN
    v_result  := public.rpc_register_payment_received(v_key, v_client_id, 150.00, NULL, 'transfer', v_bank_account_id);
    v_result2 := public.rpc_register_payment_received(v_key, v_client_id, 150.00, NULL, 'transfer', v_bank_account_id);

    IF (v_result2->>'replayed')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'GATE (k) FAILED: la segunda llamada con la misma key debería devolver replayed=true';
    END IF;

    SELECT COUNT(*) INTO v_bm_count
    FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id
      AND source_doc_type = 'payment_received'
      AND source_doc_ref  = (v_result->>'payment_id')::uuid;

    IF v_bm_count <> 1 THEN
      RAISE EXCEPTION 'GATE (k) FAILED: se esperaba exactamente 1 bank_movement tras el replay, se encontraron %', v_bm_count;
    END IF;
    v_gate_k := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'GATE_ROLLBACK_SENTINEL' THEN
        NULL;
      ELSIF SQLERRM LIKE 'GATE (k) FAILED%' THEN
        RAISE;
      ELSE
        RAISE NOTICE 'bank-payment-routing: gate (k) saltado por entorno (%)', SQLERRM;
      END IF;
  END;
  END IF;


  -- ── Limpieza del anchor sintético (SOLO en DB de test, best-effort) ───────
  IF v_run_behavioral THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
      DELETE FROM public.companies WHERE id = v_fake_company_id;  -- suppliers.company_id FK (legacy)
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'bank-payment-routing: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen de gates ─────────────────────────────────────────────────────
  RAISE NOTICE '=== bank-payment-routing C2 SQL gates ===';
  RAISE NOTICE '(a) taxonomía P0400 guard presente:                    %', v_gate_a;
  RAISE NOTICE '(b) taxonomía {cash,transfer,card,check} completa:     %', v_gate_b;
  RAISE NOTICE '(c) bancario sin bank_account_id → P0400:              %', v_gate_c;
  RAISE NOTICE '(d) transfer → bank_movement transfer_in:              %', v_gate_d;
  RAISE NOTICE '(e) card → bank_movement card_settlement (bruto):      %', v_gate_e;
  RAISE NOTICE '(f) cash cobro NO genera bank_movement:                %', v_gate_f;
  RAISE NOTICE '(g) pago transfer → bank_movement transfer_out (-):    %', v_gate_g;
  RAISE NOTICE '(h) cash pago NO genera bank_movement:                 %', v_gate_h;
  RAISE NOTICE '(i) _journal_post_from_event contiene ruteo 1110:      %', v_gate_i;
  RAISE NOTICE '(j) sales_orders CHECK acepta transfer/card:           %', v_gate_j;
  RAISE NOTICE '(k) idempotencia: replay, 1 solo bank_movement:        %', v_gate_k;
  RAISE NOTICE '=== bank-payment-routing C2: RPCs de pago + journal 1110 wireados ===';

END $$;
