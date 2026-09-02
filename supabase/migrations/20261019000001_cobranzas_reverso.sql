-- =============================================================================
-- cobranzas-reverso — anular un cobro de cuenta corriente o un pago a
-- proveedor desde la aplicación, compensando los cuatro libros (cuenta
-- corriente, caja, banco, libro diario) en una sola transacción.
-- =============================================================================
--
-- Origen: OQ-4 de caja-compras-cobranzas, firmada por el PO el 2026-09-01
-- ("FUERA de este change, por recomendación. Candidato cobranzas-reverso
-- dado de alta"). Sign-off del PO (2026-09-02, "continua") sobre las 5 OQs
-- del design, todas por su recomendación:
--   OQ-1: el cobro/pago anulado se BORRA (no voided_at) — D2.
--   OQ-2: motivo OPCIONAL, pero visible y viaja al contra-movimiento de caja
--         y al payload del evento — D1 apply / task 3.4.
--   OQ-3: is_account_writer anula, igual que cobra (v3-rbac-multirole queda
--         fuera de alcance, CRÍTICO, bloqueado a sign-off del PO).
--   OQ-4: SIN ventana temporal — D7.
--   OQ-5: payment_method NULL de los movimientos con documento borrado se
--         acepta (cosmético, ya pasa con los 7 pagos históricos).
--
-- CHECKPOINT DE INTEGRIDAD DE FUNCIÓN (regla del proyecto desde
-- metodos-pago-operaciones): las 12 funciones de
-- openspec/changes/cobranzas-reverso/baseline/prod_measurements_2026-09-02.md
-- se re-capturaron vía mcp__supabase__execute_sql (SELECT, read-only) el
-- 2026-09-02 antes de escribir una sola línea de este archivo. 12/12 hashes
-- COINCIDEN EXACTO contra el baseline — cero divergencia. La reescritura de
-- _journal_post_from_event y rpc_process_outbox_dispatch parte de los
-- volcados vivos en openspec/changes/cobranzas-reverso/baseline/
-- live_functiondefs/*.sql, NUNCA del último archivo de migración.
--
-- MAX(version) de prod re-verificado 2026-09-02 (sólo SELECT, MCP) antes de
-- escribir este archivo: 20261018000001 con 267 migraciones, idéntico al
-- último archivo de origin/main → este archivo usa 20261019000001.
--
-- REUTILIZACIÓN ANTES QUE REPETICIÓN (regla PO 2026-08-02): cero helpers SQL
-- nuevos. rpc_reverse_payment_received/_made son, palabra por palabra, el
-- molde de rpc_delete_expense (compensación multi-libro, disparo por
-- existencia `<> 0`, sesión abierta actual, escritor bancario crudo) aplicado
-- a payments_received/payments_made. Los tres helpers de escritura
-- (c30_register_customer/supplier_account_movement, c28_register_cash_movement,
-- _register_bank_movement) se invocan tal cual, sin un parámetro nuevo (D4).
--
-- D4 — por qué NO se usa _pay_reverse_party_charge: ese helper revierte un
-- CARGO (signo negativo, puede violar balance>=0 → P0425). Este change
-- revierte un COBRO/PAGO (signo positivo, D6: NUNCA puede violar balance>=0
-- — el guard aritmético hace la traducción P0409→P0425 inalcanzable por
-- diseño, no por omisión).
--
-- D5/D13 — el contra-asiento contable NACE con el reverso (no se difiere):
-- las ramas PaymentReceived/PaymentMade de _journal_post_from_event están
-- vivas y el 100% de los 7 pagos históricos tiene asiento posted. Los DOS
-- filtros de event_type (el de _journal_post_from_event y el del Consumer 3
-- de rpc_process_outbox_dispatch) pasan de 9 a 11 tipos EN EL MISMO commit;
-- el gate del invariante vive en supabase/tests/test_cobranzas_reverso.sql.
--
-- BREAKING (dominio, declarado en el proposal): anular un cobro/pago que
-- posteó movimiento de caja exige sesión de caja abierta (P0426, mismo
-- comportamiento que venta/gasto/compra). La fila de payments_received/
-- payments_made DESAPARECE al anularse — el rastro sobrevive en los dos
-- movimientos del ledger, en el evento y en el contra-asiento (reversal_of).
--
-- Orden de este archivo: CHECKs (idempotentes) → RPCs nuevas → reescritura de
-- _journal_post_from_event → reescritura de rpc_process_outbox_dispatch →
-- REVOKE/GRANT de las dos RPCs nuevas (las dos funciones reescritas NO
-- cambian de firma y CREATE OR REPLACE preserva su ACL existente — ver
-- test_function_acl_gate.sql check (3): un REVOKE/GRANT "de plantilla" sobre
-- ellas sin necesidad fue justo el bug que motivó ese gate).
-- =============================================================================


-- ═══════════════════ (2) CHECKs de los tres ledgers — aditivo ════════════════

-- (2.2) cash_movements.movement_type: 11 → 13
ALTER TABLE public.cash_movements DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;
ALTER TABLE public.cash_movements ADD CONSTRAINT cash_movements_movement_type_check
  CHECK (movement_type = ANY (ARRAY[
    'sale'::text, 'purchase_payment'::text, 'expense'::text, 'advance'::text,
    'withdrawal'::text, 'sale_reversal'::text, 'expense_reversal'::text,
    'purchase_payment_reversal'::text, 'payment_received'::text, 'payment_made'::text,
    'payment_received_reversal'::text, 'payment_made_reversal'::text, 'adjustment'::text
  ]));

-- (2.3) customer_account_movements.movement_type: 4 → 5
ALTER TABLE public.customer_account_movements DROP CONSTRAINT IF EXISTS customer_account_movements_movement_type_check;
ALTER TABLE public.customer_account_movements ADD CONSTRAINT customer_account_movements_movement_type_check
  CHECK (movement_type = ANY (ARRAY[
    'sale'::text, 'payment_received'::text, 'payment_received_reversal'::text,
    'credit_note'::text, 'adjustment'::text
  ]));

-- (2.4) supplier_account_movements.movement_type: 4 → 5
ALTER TABLE public.supplier_account_movements DROP CONSTRAINT IF EXISTS supplier_account_movements_movement_type_check;
ALTER TABLE public.supplier_account_movements ADD CONSTRAINT supplier_account_movements_movement_type_check
  CHECK (movement_type = ANY (ARRAY[
    'purchase'::text, 'payment_made'::text, 'payment_made_reversal'::text,
    'debit_note'::text, 'adjustment'::text
  ]));


-- ═══════════ (3) rpc_reverse_payment_received — molde de rpc_delete_expense ═══

CREATE OR REPLACE FUNCTION public.rpc_reverse_payment_received(
  p_payment_id uuid,
  p_reason     text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-reverso — anula un cobro de cuenta corriente (payments_received),
  compensando los cuatro libros en una sola transacción para los tres
  primeros y emitiendo el evento que produce el contra-asiento (D5).

  Molde EXACTO de rpc_delete_expense (baseline/live_functiondefs/
  rpc_delete_expense.sql), con las adaptaciones de D1-D13:
    - Cuenta corriente: contra-movimiento POSITIVO tipo propio
      'payment_received_reversal' (D1), SIN traducción P0409→P0425 (D6: es
      aritméticamente inalcanzable — el cobro sólo se aceptó si no dejaba el
      saldo negativo, y la reversa SUMA el mismo importe: balance_after
      resultante siempre >= balance de partida).
    - Caja: disparo por EXISTENCIA `<> 0`, JAMÁS por signo (D3) — el mismo
      guard que gastos-forma-pago dejó comentado en mayúsculas: un guard de
      signo copiado del molde equivocado se saltearía el bloque entero, no
      registraría la reversa, NUNCA lanzaría P0426 y el DELETE procedería
      igual — sin levantar un solo error. Sesión abierta ACTUAL de la misma
      caja (D7), P0426 si no hay ninguna. Sin ventana temporal (D7/OQ-4).
    - Banco: escritor crudo _register_bank_movement (D11), único uso
      autorizado — va contra la MISMA cuenta, no reevalúa el guard de
      período conciliado.
    - Evento PaymentReceivedReversed: INSERT plano SIN EXCEPTION (tenancy-
      guard-caja-outbox h2: tragarse un evento fallido mientras la anulación
      commitea deja los libros de dinero compensados y el diario no, en
      silencio e irrecuperable).
    - DELETE del documento, DESPUÉS de las cuatro compensaciones (D2).
    - Idempotencia por AUSENCIA del documento (D9): sin p_idempotency_key —
      el segundo intento no encuentra el pago y falla P0404.
    - Guard de tenencia (D8): resuelve por (id, account_id) ANTES de tocar
      cualquier libro; P0404 si no existe o es de otra cuenta, mensaje que no
      revela cuál de los dos casos ocurrió.
*/
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_payment              RECORD;
  v_account_movement_id  uuid;
  v_cashbox_id           uuid;
  v_cash_amount          numeric(12,2);
  v_open_session_id      uuid;
  v_cash_reversal_id     uuid;
  v_bank_row             RECORD;
  v_reversed_type        text;
  v_bank_reversals       integer := 0;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede anular el cobro'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- D8: guard de tenencia — filtro explícito, ANTES de tocar cualquier
  -- libro. El mensaje no distingue "no existe" de "es de otra cuenta".
  SELECT * INTO v_payment
  FROM public.payments_received
  WHERE id = p_payment_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment_not_found: el cobro no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Cuenta corriente: contra-movimiento POSITIVO, tipo propio (D1) ───────
  -- D6: no se traduce P0409→P0425 — es aritméticamente inalcanzable en este
  -- camino (comentario normativo, no folklore): balance_after = balance +
  -- v_payment.amount >= balance >= 0 siempre.
  v_account_movement_id := public.c30_register_customer_account_movement(
    v_payment.customer_account_id,
    v_payment.amount,
    'payment_received_reversal',
    p_payment_id
  );

  -- ── Caja: disparo por EXISTENCIA `<> 0`, jamás por signo (D3) ────────────
  -- ⚠️ Ver el comentario de advertencia completo en baseline/live_functiondefs/
  -- rpc_delete_expense.sql — el guard `<> 0` (no `> 0` ni `< 0`) es el único
  -- que sirve a la vez al cobro (movimiento positivo) y, en el espejo
  -- rpc_reverse_payment_made, al pago (movimiento negativo).
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = p_payment_id AND movement_type = 'payment_received'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount <> 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder anular este cobro'
        USING ERRCODE = 'P0426';
    END IF;

    -- El movimiento del cobro es POSITIVO (payment_received), así que
    -- -v_cash_amount da el EGRESO que saca la plata del cajón — anular un
    -- cobro saca dinero, no lo repone (D12, redacción de la superficie).
    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'payment_received_reversal', p_payment_id, p_reason
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled (D11) ────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'payment_received' AND source_doc_ref = p_payment_id
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'payment_received', p_payment_id, CURRENT_DATE, v_bank_row.branch_id,
      'Anulación de cobro' || COALESCE(': ' || p_reason, '')
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  -- ── Evento: el contra-asiento nace con el reverso (D5). INSERT plano, SIN
  -- EXCEPTION — tenancy-guard-caja-outbox h2: tragarse el fallo dejaría los
  -- libros de dinero compensados y el diario no, en silencio.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentReceivedReversed',
    'CustomerAccount',
    v_payment.customer_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'payment_id',           p_payment_id,
      'customer_account_id',  v_payment.customer_account_id,
      'client_id',            v_payment.client_id,
      'amount',                v_payment.amount,
      'reason',                p_reason,
      'occurred_at',           now()
    ),
    now()
  );

  -- ── El borrado, DESPUÉS de las cuatro compensaciones (D2) ────────────────
  DELETE FROM public.payments_received WHERE id = p_payment_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'payment_id',           p_payment_id,
    'reversed',              true,
    'account_movement_id',  v_account_movement_id,
    'cash_reversal_id',      v_cash_reversal_id,
    'bank_reversals',        v_bank_reversals
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_reverse_payment_received(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_payment_received(uuid, text) TO authenticated;


-- ═══════════ (4) rpc_reverse_payment_made — espejo exacto del proveedor ══════

CREATE OR REPLACE FUNCTION public.rpc_reverse_payment_made(
  p_payment_id uuid,
  p_reason     text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-reverso — espejo EXACTO de rpc_reverse_payment_received para el
  pago a proveedor (payments_made). Única diferencia real: tabla, tipo de
  movimiento, source_doc_type y evento — signo, guards y orden son idénticos.

  D3 (atención al signo, task 4.2): el movimiento de caja del pago a
  proveedor es NEGATIVO (payment_made postea -p_amount), así que su reversa
  es POSITIVA (repone la plata). El guard sigue siendo `<> 0` — es exactamente
  por esta asimetría entre cobro y pago que el guard NO puede ser de signo.
*/
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_payment              RECORD;
  v_account_movement_id  uuid;
  v_cashbox_id           uuid;
  v_cash_amount          numeric(12,2);
  v_open_session_id      uuid;
  v_cash_reversal_id     uuid;
  v_bank_row             RECORD;
  v_reversed_type        text;
  v_bank_reversals       integer := 0;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede anular el pago'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_payment
  FROM public.payments_made
  WHERE id = p_payment_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment_not_found: el pago no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Cuenta corriente: contra-movimiento POSITIVO, tipo propio (D1) ───────
  v_account_movement_id := public.c30_register_supplier_account_movement(
    v_payment.supplier_account_id,
    v_payment.amount,
    'payment_made_reversal',
    p_payment_id
  );

  -- ── Caja: disparo por EXISTENCIA `<> 0`, jamás por signo (D3) ────────────
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = p_payment_id AND movement_type = 'payment_made'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount <> 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder anular este pago'
        USING ERRCODE = 'P0426';
    END IF;

    -- El movimiento del pago es NEGATIVO (payment_made), así que
    -- -v_cash_amount da el INGRESO que repone la plata en el cajón.
    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'payment_made_reversal', p_payment_id, p_reason
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled (D11) ────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'payment_made' AND source_doc_ref = p_payment_id
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'payment_made', p_payment_id, CURRENT_DATE, v_bank_row.branch_id,
      'Anulación de pago' || COALESCE(': ' || p_reason, '')
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  -- ── Evento: el contra-asiento nace con el reverso (D5). INSERT plano ────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentMadeReversed',
    'SupplierAccount',
    v_payment.supplier_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'payment_id',           p_payment_id,
      'supplier_account_id',  v_payment.supplier_account_id,
      'supplier_id',          v_payment.supplier_id,
      'amount',                v_payment.amount,
      'reason',                p_reason,
      'occurred_at',           now()
    ),
    now()
  );

  -- ── El borrado, DESPUÉS de las cuatro compensaciones (D2) ────────────────
  DELETE FROM public.payments_made WHERE id = p_payment_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'payment_id',           p_payment_id,
    'reversed',              true,
    'account_movement_id',  v_account_movement_id,
    'cash_reversal_id',      v_cash_reversal_id,
    'bank_reversals',        v_bank_reversals
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_reverse_payment_made(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_payment_made(uuid, text) TO authenticated;


-- ═══ (5) _journal_post_from_event — dos ramas nuevas + filtro 9→11 (D5/D13) ═══
-- Parte BYTE A BYTE del volcado vivo en baseline/live_functiondefs/
-- _journal_post_from_event.sql (md5 ef2d9459f125c200a28b757d266eb738,
-- verificado en el checkpoint 1.2 del apply). Únicos cambios: el filtro
-- v_event_type NOT IN (...) (9→11 tipos), la declaración de v_payment_id, y
-- las dos ramas ELSIF PaymentReceivedReversed/PaymentMadeReversed, calcadas
-- de PurchaseDeleted (única convención de referencia — el cobro/pago tiene
-- UN solo camino de alta, a diferencia de la venta). Las 9 ramas
-- preexistentes quedan intactas.

CREATE OR REPLACE FUNCTION public._journal_post_from_event(p_event events)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  journal-entry-outbox Consumer 3 — Helper de posting de asientos de partida doble.
  bank-payment-routing C2: agrega ruteo 1110 Banco (bancario) vs 1100 Caja (cash/other)
  en SaleConfirmed/PaymentReceived/PaymentMade, leído del payment_method del payload.
  pagos-cableados-restantes (D7/OQ-1): 'wallet' se suma al vocabulario
  bancario en esas tres ramas — antes caía en 1100 Caja por omisión, ahora
  rutea a 1110 Banco como transfer/card/check (recomendación fundada, OQ-1
  del design.md — reversible con un one-liner si el PO decide otra cosa).

  asiento-venta-formulario (2026-08-20): agrega DOS ramas operation-level,
  moldeadas sobre PurchaseCreated: SaleOperationCreated / SaleOperationAdjusted.

  delete-guard-ledgers (2026-08-22): agrega DOS ramas de contra-asiento por
  borrado, calcadas de la PRIMERA MITAD de SaleOperationAdjusted (localizar +
  revertir, SIN la segunda mitad de asiento-de-reemplazo — el borrado no
  reemplaza, solo revierte):
    - SaleOperationDeleted: resuelve el asiento vigente probando las DOS
      convenciones en orden — (SaleOperation, operation_id) primero
      (formulario), luego (SalesOrder, sales_order_id) (POS) — mismo
      predicado de dos convenciones que gobierna todo el change
      (operation-delete-compensation D2).
    - PurchaseDeleted: única convención (Purchase, operation_id) — las
      compras no tienen el concepto de doble referencia de la venta.
    Ambas ramas: la contra-entry es la ÚNICA entry del evento (a diferencia
    de SaleOperationAdjusted) → SÍ lleva su propio source_event_id —
    trazabilidad evento→asiento completa (ventaja documentada en design §D7).
    El ASSERT de balance común del final de la función las cubre sin código
    adicional (mismo mecanismo que ya usan las 7 ramas preexistentes).

  cobranzas-reverso (2026-09-02): agrega DOS ramas de contra-asiento por
  ANULACIÓN de un cobro/pago, mismo molde que SaleOperationDeleted/
  PurchaseDeleted (localizar + revertir, la contra-entry es la única entry
  del evento). Única convención de referencia en los dos casos — el cobro y
  el pago, a diferencia de la venta, tienen un solo camino de alta:
    - PaymentReceivedReversed: localiza por (CustomerAccount, payment_id).
    - PaymentMadeReversed: localiza por (SupplierAccount, payment_id).
  D5: diferir esta reversión NO era una opción — a diferencia del gasto y la
  compra en efectivo (cuyos asientos no existían cuando se cablearon sus
  libros de dinero), las ramas PaymentReceived/PaymentMade YA estaban vivas y
  el 100% de los pagos históricos tenía asiento posted.

  Responsabilidades:
    1. Filtrar por event_type (11 tipos en-scope; no-op para el resto).
    2. Reclamar slot de idempotencia (event_id, 'JournalEntry') en operation_idempotency.
    3. Calcular las líneas de débito/crédito según el mapeo hardcodeado (D1, D4 del
       change journal-entry-outbox) + ruteo bancario (C2 D3, extendido por
       pagos-cableados-restantes D7).
    4. Validar Σdébito = Σcrédito (ASSERT — D5, ERRCODE P0450).
    5. INSERT journal_entries + journal_lines.

  Codigos de cuenta hardcodeados (D1 journal-entry-outbox — plan mínimo PYME AR):
    1100 Caja / 1110 Banco (C2: wireado — antes reservado) / 1300 Deudores por Ventas
    2100 Proveedores / 4100 Ventas / 4200 IVA Débito Fiscal
    5100 CMV/Compras / 5200 IVA Crédito Fiscal / 5300 Gastos (reservado)

  Ruteo bancario (C2 D3, extendido pagos-cableados-restantes D7): "es método
  bancario" = payment_method IN ('transfer','card','check','wallet').
  SaleConfirmed:    credit→1300; bancario→1110; cash/other/NULL→1100 (débito).
  PaymentReceived:  bancario→1110; cash/NULL→1100 (débito).
  PaymentMade:      bancario→1110; cash/NULL→1100 (crédito).
  PurchaseCreated:  SIN CAMBIOS — cash→1100; todo lo demás (incl. wallet)→2100
                     Proveedores (no tiene predicado v_is_bank — D8 original).
  SaleOperationCreated / SaleOperationAdjusted (nuevo entry): mismo mapeo
                     que SaleConfirmed pero vía _journal_sale_debit_account(kind),
                     y el sin-imputar (NULL) rutea a 1100 (D3, deliberadamente
                     distinto del default 'credit' de PurchaseCreated).

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
    P0451 — asiento original no encontrado para NC / SaleOperationAdjusted /
            SaleOperationDeleted / PurchaseDeleted / PaymentReceivedReversed /
            PaymentMadeReversed (retry).
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
    -- cobranzas-reverso: identificador del cobro/pago anulado, source_doc_ref
    -- de las dos ramas nuevas.
    v_payment_id      uuid;

    -- Reversal
    v_original_id     uuid;
    v_orig_entry_id   uuid;

    -- Balance tracking
    v_sum_debit       numeric(14,2) := 0;
    v_sum_credit      numeric(14,2) := 0;
    v_line_no         int := 0;

    -- Idempotency
    v_claimed         bool;

    -- asiento-venta-formulario: posted_at por D5 (fecha de la venta, no el
    -- instante del relay) para SaleOperationCreated / la mitad "nueva" de
    -- SaleOperationAdjusted.
    v_posted_at       timestamptz;
BEGIN
    v_account_id := p_event.account_id;
    v_payload     := p_event.payload;
    v_event_type  := p_event.event_type;

    -- ── Filtro: solo los 11 tipos en-scope ───────────────────────────────────
    -- cobranzas-reverso: suma PaymentReceivedReversed / PaymentMadeReversed
    -- (9→11). Este filtro y el de rpc_process_outbox_dispatch DEBEN listar el
    -- mismo conjunto (invariante documentado desde journal-entry-outbox,
    -- verificado por gate desde cobranzas-reverso — D13).
    IF v_event_type NOT IN (
        'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
        'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
        'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted',
        'PaymentReceivedReversed', 'PaymentMadeReversed'
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
        -- C2 D3: ruteo bancario del débito por payment_method; D7
        -- pagos-cableados-restantes: wallet se suma al vocabulario bancario)
        -- Lookup JOIN para comprobante_type/neto/iva_amount (D9 — no modificamos C-29)
        -- SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check', 'wallet');

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

    ELSIF v_event_type = 'SaleOperationCreated' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-venta-formulario (D1-D6): molde operation-level de
        -- PurchaseCreated. SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';  -- crudo, puede ser NULL (D6 productor)
        v_operation_id   := (v_payload->>'operation_id')::uuid;

        IF v_payload->>'sale_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'sale_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'SaleOperation',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_sale_debit_account(v_payment_method),
                'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '4100', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'SaleOperationAdjusted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-venta-formulario (D7, override del PO): edición sobre una
        -- operación cuyo asiento ya fue posteado. SIN CAMBIOS (delete-guard-
        -- ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_original_id := (v_payload->>'old_operation_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_original_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para SaleOperation % (SaleOperationAdjusted %). El evento quedará pending for retry.',
                v_original_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- Contra-entry: reversión exacta (mismo patrón de copia con lados
        -- invertidos que ya usa CreditNoteIssued). posted_at=now(): la
        -- reversión data la corrección, no la venta original.
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        VALUES (
            v_account_id, now(), NULL, 'SaleOperation',
            v_original_id, 'posted', v_orig_entry_id
        )
        RETURNING id INTO v_entry_id;

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

        -- Balance de la contra-entry, validado individualmente (además del
        -- ASSERT común al final, que valida el asiento NUEVO).
        SELECT
            COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
            COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
        INTO v_sum_debit, v_sum_credit
        FROM public.journal_lines
        WHERE entry_id = v_entry_id;

        IF v_sum_debit <> v_sum_credit THEN
            RAISE EXCEPTION
                'journal_balance_assertion_failed: la contra-entry de SaleOperationAdjusted % no balancea (ERRCODE P0450).',
                p_event.id
                USING ERRCODE = 'P0450';
        END IF;

        -- El asiento vigente queda revertido.
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

        -- Asiento nuevo: valores editados, mismo ruteo por kind que
        -- SaleOperationCreated vía el helper compartido (D3/D4).
        v_sum_debit  := 0;
        v_sum_credit := 0;

        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_operation_id   := (v_payload->>'new_operation_id')::uuid;

        IF v_payload->>'sale_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'sale_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'SaleOperation',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_sale_debit_account(v_payment_method),
                'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '4100', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'PaymentReceived' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PaymentReceived: SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check', 'wallet');

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
        -- PaymentMade: SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check', 'wallet');

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
        -- CreditNoteIssued: SIN CAMBIOS (delete-guard-ledgers): byte a byte.
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
                'para SalesOrder % (CreditNoteIssued %). El evento quedará pending for retry.',
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

    ELSIF v_event_type = 'SaleOperationDeleted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- delete-guard-ledgers (operation-delete-compensation / journal-entry):
        -- contra-asiento por borrado — SOLO la mitad "revertir" de
        -- SaleOperationAdjusted, sin asiento de reemplazo. Resuelve el asiento
        -- vigente probando las DOS convenciones en orden: (SaleOperation,
        -- operation_id) primero (formulario), luego (SalesOrder,
        -- sales_order_id) (POS, D2). La contra-entry es la ÚNICA entry del
        -- evento → lleva su propio source_event_id (ventaja sobre Adjusted,
        -- §D7). El ASSERT de balance común del final la valida — sin código
        -- adicional (misma mecánica que las 7 ramas preexistentes).
        -- ──────────────────────────────────────────────────────────────────────
        v_operation_id := (v_payload->>'operation_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_operation_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL AND v_payload->>'sales_order_id' IS NOT NULL THEN
            SELECT id INTO v_orig_entry_id
            FROM public.journal_entries
            WHERE source_doc_type = 'SalesOrder'
              AND source_doc_ref  = (v_payload->>'sales_order_id')::uuid
              AND status          = 'posted'
              AND account_id      = v_account_id
            LIMIT 1;
        END IF;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para la venta borrada (SaleOperationDeleted %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- Contra-entry: copia source_doc_type/source_doc_ref del asiento
        -- original (cualquiera de las dos convenciones que haya resuelto) —
        -- es una REVERSIÓN, no un documento fiscal nuevo (a diferencia de
        -- CreditNoteIssued, que sí es su propio 'CreditNote').
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

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

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'PurchaseDeleted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- delete-guard-ledgers: mismo molde que SaleOperationDeleted, única
        -- convención (Purchase, operation_id) — las compras no tienen el
        -- concepto de doble referencia de la venta. cost_center_id por línea
        -- se preserva automáticamente: se copia igual que el resto de la fila.
        -- ──────────────────────────────────────────────────────────────────────
        v_operation_id := (v_payload->>'operation_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'Purchase'
          AND source_doc_ref  = v_operation_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para la compra borrada (PurchaseDeleted %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

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

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'PaymentReceivedReversed' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- cobranzas-reverso (D5/D13): contra-asiento por anulación de un
        -- cobro. Mismo molde que PurchaseDeleted — única convención de
        -- referencia (CustomerAccount, payment_id): el cobro tiene un solo
        -- camino de alta, no dos como la venta.
        -- ──────────────────────────────────────────────────────────────────────
        v_payment_id := (v_payload->>'payment_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'CustomerAccount'
          AND source_doc_ref  = v_payment_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el cobro anulado (PaymentReceivedReversed %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

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

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'PaymentMadeReversed' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- cobranzas-reverso: espejo exacto para el pago a proveedor —
        -- (SupplierAccount, payment_id).
        -- ──────────────────────────────────────────────────────────────────────
        v_payment_id := (v_payload->>'payment_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SupplierAccount'
          AND source_doc_ref  = v_payment_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el pago anulado (PaymentMadeReversed %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

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

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    END IF;

    -- ── ASSERT de balance: Σdébito = Σcrédito (D5 journal-entry-outbox) — SIN CAMBIOS ──
    -- Solo validar para eventos que crean líneas directamente (no para no-op)
    IF v_entry_id IS NOT NULL THEN
        -- Para los tipos que no son reversal puro (CreditNoteIssued ya
        -- calculó su propio balance del espejo arriba), recalcular de la
        -- tabla contra v_entry_id — que en SaleOperationAdjusted apunta al
        -- asiento NUEVO (la contra-entry ya se validó individualmente más
        -- arriba, antes de marcarse reversed el original). SaleOperationDeleted
        -- / PurchaseDeleted / PaymentReceivedReversed / PaymentMadeReversed
        -- quedan cubiertas por esta misma rama genérica: v_entry_id apunta a
        -- SU contra-entry (única entry del evento).
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
                'El asiento no balancea — evento quedará pending for retry.',
                v_sum_debit, v_sum_credit, p_event.id
                USING ERRCODE = 'P0450';
        END IF;
    END IF;

END;
$function$;


-- ═══ (6) rpc_process_outbox_dispatch — filtro del Consumer 3, 9→11 (D13) ═════
-- Parte BYTE A BYTE del volcado vivo en baseline/live_functiondefs/
-- rpc_process_outbox_dispatch.sql (md5 28ef69cefc0fd0a5d112b656e7795ac6,
-- verificado en el checkpoint 1.2). Único cambio: el filtro del Consumer 3
-- (mismo conjunto exacto que el de _journal_post_from_event arriba — D13) y
-- el comentario de cabecera que lo enumera. Los Consumers 1, 2 y 4 y toda la
-- lógica de aislamiento por evento quedan byte a byte.

CREATE OR REPLACE FUNCTION public.rpc_process_outbox_dispatch(p_batch_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  C-25 + journal-entry-outbox + v3-notifications-realtime pure-SQL relay dispatch.

  Consumer order (per-event):
    1. AuditLog  (mandatory first — audit domain invariant)
    2. EmailNotification (sale_created/stock_adjusted/plan_changed)
    3. JournalEntry (SaleConfirmed/PurchaseCreated/SaleOperationCreated/
       SaleOperationAdjusted/PaymentReceived/PaymentMade/CreditNoteIssued/
       SaleOperationDeleted/PurchaseDeleted/PaymentReceivedReversed/
       PaymentMadeReversed)
    4. Notification (CashSessionClosed/StockBelowMinimum/FiscalDocumentRejected/
       QuoteAccepted/TransferDispatched) — v3-notifications-realtime.

  processed_at se escribe SOLO si todos los consumers activos del evento tienen
  éxito. Un consumer fallido deja processed_at NULL → retry en el próximo tick.
  Cada consumer está idempotency-guarded por (event_id, consumer_type).

  Per-event isolation: BEGIN/EXCEPTION/END por evento.
  SECURITY DEFINER: cross-account sin debilitar RLS. REVOCADO de anon/PUBLIC.

  delete-guard-ledgers (2026-08-22): agrega SaleOperationDeleted y
  PurchaseDeleted al filtro del Consumer 3 — mismo invariante ya documentado
  por asiento-venta-formulario: el filtro del dispatcher y el de
  _journal_post_from_event deben listar el mismo conjunto.

  cobranzas-reverso (2026-09-02, D13): agrega PaymentReceivedReversed y
  PaymentMadeReversed (9→11) — mismo invariante, ahora sostenido además por
  un gate automático (supabase/tests/test_cobranzas_reverso.sql) que compara
  los dos conjuntos extraídos de los cuerpos vivos, no sólo por este
  comentario.
*/
DECLARE
  v_event           public.events%ROWTYPE;
  v_processed_count int := 0;
  v_audit_claimed   bool;
  v_email_claimed   bool;
  v_subject         text;
  v_recipient       text;
BEGIN
  FOR v_event IN
    SELECT *
    FROM public.events
    WHERE processed_at IS NULL
    ORDER BY occurred_at
    LIMIT p_batch_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN

      -- ── Consumer 1: AuditLog (mandatory first) ────────────────────────────
      INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
      VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        v_event.id::text || ':AuditLog',
        'event_consumer',
        v_event.id,
        'AuditLog'
      )
      ON CONFLICT (event_id, consumer_type)
      WHERE event_id IS NOT NULL
      DO NOTHING;

      GET DIAGNOSTICS v_audit_claimed = ROW_COUNT;

      IF v_audit_claimed THEN
        INSERT INTO public.audit_logs (account_id, action, created_at)
        VALUES (v_event.account_id, v_event.event_type, now());
      END IF;

      -- ── Consumer 2: EmailNotification ─────────────────────────────────────
      IF v_event.event_type IN ('sale_created', 'stock_adjusted', 'plan_changed') THEN

        INSERT INTO public.operation_idempotency
          (user_id, idempotency_key, operation_kind, event_id, consumer_type)
        VALUES (
          '00000000-0000-0000-0000-000000000000'::uuid,
          v_event.id::text || ':EmailNotification',
          'event_consumer',
          v_event.id,
          'EmailNotification'
        )
        ON CONFLICT (event_id, consumer_type)
        WHERE event_id IS NOT NULL
        DO NOTHING;

        GET DIAGNOSTICS v_email_claimed = ROW_COUNT;

        IF v_email_claimed THEN
          v_subject := CASE v_event.event_type
            WHEN 'sale_created'    THEN 'Nueva venta registrada'
            WHEN 'stock_adjusted'  THEN 'Ajuste de stock realizado'
            WHEN 'plan_changed'    THEN 'Tu plan ha sido actualizado'
            ELSE 'Evento: ' || v_event.event_type
          END;

          v_recipient := COALESCE(
            v_event.payload->>'email',
            'account:' || v_event.account_id::text
          );

          INSERT INTO public.email_logs
            (event_type, recipient, subject, status, metadata)
          VALUES (
            v_event.event_type,
            v_recipient,
            v_subject,
            'pending',
            jsonb_build_object(
              'event_id',   v_event.id::text,
              'account_id', v_event.account_id::text
            )
          )
          ON CONFLICT DO NOTHING;
        END IF;

      END IF;

      -- ── Consumer 3: JournalEntry (journal-entry-outbox) ───────────────────
      -- Solo para los 11 tipos en-scope; _journal_post_from_event hace no-op
      -- para el resto. La idempotencia (event_id, 'JournalEntry') se gestiona
      -- dentro del helper. Un fallo en el posting (balance, NC sin original,
      -- reverso sin original) deja el evento pending para retry — el
      -- EXCEPTION del sub-bloque lo captura sin abortar el batch.
      IF v_event.event_type IN (
          'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
          'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
          'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted',
          'PaymentReceivedReversed', 'PaymentMadeReversed'
      ) THEN
        PERFORM public._journal_post_from_event(v_event);
      END IF;

      -- ── Consumer 4: Notification (v3-notifications-realtime) ─────────────
      -- Solo para los 5 tipos en-scope; _notification_from_event hace no-op
      -- para el resto (incluyendo CashSessionClosed con difference=0 y
      -- audiencia vacía). La idempotencia (event_id, 'Notification') se
      -- gestiona dentro del helper, igual que el Consumer 3.
      IF v_event.event_type IN (
          'CashSessionClosed', 'StockBelowMinimum', 'FiscalDocumentRejected',
          'QuoteAccepted', 'TransferDispatched'
      ) THEN
        PERFORM public._notification_from_event(v_event);
      END IF;

      -- ── Mark processed (todos los consumers activos tuvieron éxito) ─────────
      UPDATE public.events
      SET processed_at = now()
      WHERE id = v_event.id;

      v_processed_count := v_processed_count + 1;

    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING
          'rpc_process_outbox_dispatch: fallo en evento % (type=%): %',
          v_event.id, v_event.event_type, SQLERRM;
    END;

  END LOOP;

  RETURN v_processed_count;
END;
$function$;
