-- =============================================================================
-- delete-guard-ledgers — RPCs atómicas de borrado con guard fiscal y
-- compensación de los cuatro libros (cuenta corriente, caja, banco, contable).
-- =============================================================================
--
-- Daño real que motiva este change (2026-08-21): borrar una operación con
-- dinero posteado no compensaba ningún libro. Cargo fantasma de $75.150
-- contra Gomez Camila (reparado a mano); 2 movimientos de caja huérfanos
-- ($8.000, sesión abierta desde 2026-07-17); 10 asientos contables posteados
-- de operaciones inexistentes; 3 sales_orders colgadas. Ver design.md
-- (openspec/changes/delete-guard-ledgers/) para el detalle completo.
--
-- MAX(version) prod verificado 2026-08-22: 20261004000002 → este archivo usa
-- 20261005000001. Baseline de las 8 funciones tocadas/invocadas capturado en
-- openspec/changes/delete-guard-ledgers/baseline/*.sql vía pg_get_functiondef
-- EN VIVO (gate de integridad de función, regla del proyecto, 5 incidentes
-- previos) — las reescrituras de este archivo parten de ese baseline.
--
-- Censo de errcodes re-corrido 2026-08-22: P0400,401,403,404,409,410,411,412,
-- 422,423,424,431,432,433,434,450,451 ocupados. Este change usa P0425 (saldo
-- negativo) y P0426 (sin caja abierta) — confirmados libres.
--
-- Reutilización agresiva (no se escribe aritmética de libro nueva): cada
-- compensación delega en el helper ya probado que ya la sabe hacer —
-- c30_register_customer_account_movement / c30_register_supplier_account_movement
-- (vía el helper nuevo _pay_reverse_party_charge, que traduce su P0409 propio
-- a P0425), c28_register_cash_movement, _register_bank_movement,
-- rpc_reverse_stock_movement (#417, sin cambios). El contra-asiento contable
-- se emite async vía el mecanismo de outbox ya existente (mismo patrón que
-- SaleOperationCreated/SaleOperationAdjusted de asiento-venta-formulario).
--
-- Idempotente: CHECK con DROP+ADD, seed con ON CONFLICT, funciones con
-- CREATE OR REPLACE (firma sin cambios: _journal_post_from_event,
-- rpc_process_outbox_dispatch) o DROP FUNCTION IF EXISTS + CREATE (firma
-- nueva: _pay_reverse_party_charge, rpc_delete_sale_operation,
-- rpc_delete_purchase_operation) + GRANT/REVOKE explícito en el mismo
-- archivo (DROP+CREATE resetea el ACL — gotcha con 5 antecedentes en el
-- proyecto, cubierto por supabase/tests/test_function_acl_gate.sql).

-- =============================================================================
-- 1. Vocabulario — cash_movements admite 'sale_reversal'
-- =============================================================================
-- Los otros tres CHECK tocados por el diseño (customer_account_movements:
-- 'credit_note' ya existe; bank_movements: 'transfer_out' ya existe;
-- sales_orders: 'canceled' ya existe) NO requieren migración (design.md §3.4).

ALTER TABLE public.cash_movements
  DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;

ALTER TABLE public.cash_movements
  ADD CONSTRAINT cash_movements_movement_type_check
  CHECK (movement_type = ANY (ARRAY[
    'sale'::text, 'purchase_payment'::text, 'expense'::text,
    'advance'::text, 'withdrawal'::text, 'sale_reversal'::text
  ]));

COMMENT ON CONSTRAINT cash_movements_movement_type_check ON public.cash_movements IS
  'delete-guard-ledgers: agrega sale_reversal — contra-movimiento de caja al '
  'borrar una operación con ingreso de caja posteado (D5). Distinguible de '
  'withdrawal (retiro real) en los reportes de sesión.';

-- =============================================================================
-- 2. Catálogo de transiciones — sales_order confirmed → canceled
-- =============================================================================
-- record_status_transition (v3-document-status-history) exige que toda
-- transición (no-creación) esté catalogada (RN-A4). Sólo draft→confirmed y
-- NULL→draft estaban sembradas para sales_order — el borrado de una venta
-- del POS cancela la orden (D8) y necesita esta fila.

INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason)
VALUES
  ('sales_order', 'confirmed', 'canceled', true, false)
ON CONFLICT (document_type, from_status, to_status) WHERE (from_status IS NOT NULL)
DO NOTHING;

-- =============================================================================
-- 3. Helper nuevo — reversión de cargo de tercero (party-account-charge)
-- =============================================================================
-- Espejo de _pay_register_party_charge (que SIGUE existiendo, sin cambios —
-- registra el cargo original). Este helper registra la REVERSIÓN: mismo
-- despacho por party_kind, mismo helper de escritura subyacente
-- (c30_register_customer_account_movement / c30_register_supplier_account_movement)
-- — sin aritmética nueva. La única lógica propia es traducir el P0409
-- genérico de esos helpers ("overpayment") a P0425, con un mensaje que nombra
-- la acción real que destraba (registrar la devolución del pago) — task 4.4.
--
-- p_party_account_id es la cuenta YA EXISTENTE (customer_accounts.id /
-- supplier_accounts.id) que recibió el cargo original — se resuelve por el
-- llamador desde el movimiento original, NUNCA por get-or-create: una
-- reversión nunca debe poder crear una cuenta que no existía (si no existe,
-- P0404 — delegado al helper de registro, que ya lo hace).

DROP FUNCTION IF EXISTS public._pay_reverse_party_charge(uuid, text, uuid, numeric, uuid, uuid);

CREATE OR REPLACE FUNCTION public._pay_reverse_party_charge(
  p_account_id       uuid,
  p_party_kind       text,
  p_party_account_id uuid,
  p_amount           numeric,   -- importe ABSOLUTO del cargo original a revertir (positivo)
  p_reference_id     uuid,
  p_operation_id     uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_movement_id uuid;
BEGIN
  IF p_party_kind = 'customer' THEN

    BEGIN
      v_movement_id := public.c30_register_customer_account_movement(
        p_party_account_id, -p_amount, 'credit_note', p_reference_id
      );
    EXCEPTION
      WHEN SQLSTATE 'P0409' THEN
        RAISE EXCEPTION 'reversal_would_go_negative: el cliente ya canceló esta venta — registrá primero la devolución del pago antes de borrar la operación.'
          USING ERRCODE = 'P0425';
    END;

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'CustomerAccountChargeReversed',
      'CustomerAccount',
      p_party_account_id,
      jsonb_build_object(
        'account_id',          p_account_id,
        'customer_account_id', p_party_account_id,
        'reference_id',        p_reference_id,
        'operation_id',        p_operation_id,
        'amount',              -p_amount,
        'occurred_at',         now()
      ),
      now()
    );

  ELSIF p_party_kind = 'supplier' THEN

    BEGIN
      v_movement_id := public.c30_register_supplier_account_movement(
        p_party_account_id, -p_amount, 'debit_note', p_reference_id
      );
    EXCEPTION
      WHEN SQLSTATE 'P0409' THEN
        RAISE EXCEPTION 'reversal_would_go_negative: el proveedor ya cobró esta compra — registrá primero la devolución del pago antes de borrar la operación.'
          USING ERRCODE = 'P0425';
    END;

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'SupplierAccountChargeReversed',
      'SupplierAccount',
      p_party_account_id,
      jsonb_build_object(
        'account_id',          p_account_id,
        'supplier_account_id', p_party_account_id,
        'reference_id',        p_reference_id,
        'operation_id',        p_operation_id,
        'amount',              -p_amount,
        'occurred_at',         now()
      ),
      now()
    );

  ELSE
    RAISE EXCEPTION 'invalid_party_kind: % (esperado customer|supplier)', p_party_kind
      USING ERRCODE = 'P0400';
  END IF;

  RETURN v_movement_id;
END;
$function$;

COMMENT ON FUNCTION public._pay_reverse_party_charge(uuid, text, uuid, numeric, uuid, uuid) IS
  'delete-guard-ledgers (party-account-charge): reversión del cargo de un '
  'tercero (cliente o proveedor) por el borrado de la operación que lo '
  'originó. Traduce el P0409 interno de c30_register_*_account_movement a '
  'P0425. Solo callable desde RPCs SECURITY DEFINER de este módulo.';

REVOKE ALL ON FUNCTION public._pay_reverse_party_charge(uuid, text, uuid, numeric, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 4. _journal_post_from_event — dos ramas nuevas (SaleOperationDeleted,
--    PurchaseDeleted). Firma SIN CAMBIOS (p_event events) → CREATE OR REPLACE,
--    preserva ACL existente. Reescrita desde el baseline vivo (task 1.1) —
--    las 7 ramas preexistentes quedan byte a byte, solo se agregan las 2
--    ramas nuevas al final del dispatch y el filtro de entrada se amplía.
-- =============================================================================

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

  Responsabilidades:
    1. Filtrar por event_type (9 tipos en-scope; no-op para el resto).
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
            SaleOperationDeleted / PurchaseDeleted (retry).
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

    -- asiento-venta-formulario: posted_at por D5 (fecha de la venta, no el
    -- instante del relay) para SaleOperationCreated / la mitad "nueva" de
    -- SaleOperationAdjusted.
    v_posted_at       timestamptz;
BEGIN
    v_account_id := p_event.account_id;
    v_payload     := p_event.payload;
    v_event_type  := p_event.event_type;

    -- ── Filtro: solo los 9 tipos en-scope ────────────────────────────────────
    -- delete-guard-ledgers: suma SaleOperationDeleted / PurchaseDeleted. Este
    -- filtro y el de rpc_process_outbox_dispatch DEBEN listar el mismo
    -- conjunto (invariante documentado desde journal-entry-outbox).
    IF v_event_type NOT IN (
        'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
        'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
        'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted'
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
                'para SaleOperation % (SaleOperationAdjusted %). El evento quedará pending para retry.',
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
                'para la venta borrada (SaleOperationDeleted %). El evento quedará pending para retry.',
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
                'para la compra borrada (PurchaseDeleted %). El evento quedará pending para retry.',
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
        -- / PurchaseDeleted quedan cubiertas por esta misma rama genérica:
        -- v_entry_id apunta a SU contra-entry (única entry del evento).
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
$function$;

-- =============================================================================
-- 5. rpc_process_outbox_dispatch — el filtro del Consumer 3 debe listar el
--    MISMO conjunto que _journal_post_from_event (invariante documentado
--    desde journal-entry-outbox). Firma SIN CAMBIOS → CREATE OR REPLACE.
-- =============================================================================

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
       SaleOperationDeleted/PurchaseDeleted)
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
      -- Solo para los 9 tipos en-scope; _journal_post_from_event hace no-op para el resto.
      -- La idempotencia (event_id, 'JournalEntry') se gestiona dentro del helper.
      -- Un fallo en el posting (balance, NC sin original) deja el evento pending
      -- para retry — el EXCEPTION del sub-bloque lo captura sin abortar el batch.
      IF v_event.event_type IN (
          'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
          'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
          'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted'
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

-- =============================================================================
-- 6. rpc_delete_sale_operation — RPC atómica de borrado de venta
-- =============================================================================
-- operation-delete-compensation (D1/D2): resuelve la clave de operación
-- (COALESCE(operation_id, id), mismo criterio de agrupación que
-- SalesRepository.list_paginated_by_operation) → guard fiscal (P0423) →
-- compensa cuenta corriente (P0425 si dejaría saldo negativo) → compensa
-- caja (P0426 si no hay sesión abierta) → compensa banco (espejo,
-- unreconciled) → reversa de stock (#417, sin cambios) → emite
-- SaleOperationDeleted (async) → cancela la sales_order del POS si aplica →
-- DELETE → limpia operation_idempotency. Acepta p_sale_id (delete_by_id) O
-- p_operation_id (delete_by_operation) — ambos caminos convergen en la misma
-- resolución de operación, así que una sola RPC cubre los dos entry points
-- que ya expone el router (DELETE /sales/{id} y DELETE /sales?operation_id=).

DROP FUNCTION IF EXISTS public.rpc_delete_sale_operation(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_delete_sale_operation(
  p_sale_id      uuid DEFAULT NULL,
  p_operation_id uuid DEFAULT NULL,
  p_reason       text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_sale_ids             uuid[];
  v_sales_order_id       uuid;
  v_so_status             text;
  v_reference_ids        uuid[];
  v_row                  RECORD;
  v_customer_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_cash_session_id      uuid;
  v_cash_amount          numeric(12,2);
  v_cashbox_id           uuid;
  v_open_session_id      uuid;
  v_bank_row             RECORD;
  v_reversed_type        text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_sale_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_sale_operation: se requiere p_sale_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Resolver el conjunto de filas + la clave de operación (D2) ───────────
  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_sale_ids
    FROM public.sales
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.sales
    WHERE id = p_sale_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_sale_ids
      FROM public.sales
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      -- Legacy: sin operation_id — la fila es su propia operación.
      v_operation_key := p_sale_id;
      v_sale_ids := ARRAY[p_sale_id];
    END IF;
  END IF;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- sales_order asociada (camino POS) — misma convención que el guard P0423.
  SELECT id, status INTO v_sales_order_id, v_so_status
  FROM public.sales_orders
  WHERE sale_operation_id = v_operation_key;

  v_reference_ids := ARRAY[v_operation_key];
  IF v_sales_order_id IS NOT NULL THEN
    v_reference_ids := v_reference_ids || v_sales_order_id;
  END IF;

  -- ── Guard fiscal (P0423) — MISMO predicado que rpc_atomic_update_sale_operation ──
  IF v_sales_order_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.sales_orders so
    JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id
    WHERE so.id = v_sales_order_id
      AND fd.status IN ('pending_cae', 'authorized')
  ) THEN
    RAISE EXCEPTION 'invoiced_operation_immutable: la operación tiene un comprobante fiscal emitido y no puede borrarse — emití una nota de crédito'
      USING ERRCODE = 'P0423';
  END IF;

  -- ── Cuenta corriente de cliente: reversión del cargo (credit_note, P0425 si negativo) ──
  SELECT customer_account_id, SUM(amount)
  INTO v_customer_account_id, v_charge_amount
  FROM public.customer_account_movements
  WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
  GROUP BY customer_account_id;

  IF v_customer_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'customer', v_customer_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder anular esta venta'
        USING ERRCODE = 'P0426';
    END IF;

    PERFORM public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'sale_reversal', v_operation_key
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled (D6) ─────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'sale' AND source_doc_ref = ANY(v_reference_ids)
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'sale', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
    PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
  END LOOP;

  -- ── Contable: emitir SaleOperationDeleted (async, vía outbox) ────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationDeleted', 'SaleOperation', v_operation_key,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_operation_key,
      'sales_order_id', v_sales_order_id,
      'occurred_at',    now()
    ),
    now()
  );

  -- ── POS: cancelar la sales_order en la misma transacción (D8) ────────────
  IF v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    UPDATE public.sales_orders
    SET status = 'canceled', sale_operation_id = NULL
    WHERE id = v_sales_order_id;

    PERFORM public.record_status_transition(
      v_account_id, 'sales_order', v_sales_order_id, 'confirmed', 'canceled',
      v_uid, COALESCE(p_reason, 'Venta eliminada')
    );
  END IF;

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(v_sale_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) IS
  'delete-guard-ledgers: RPC atómica de borrado de venta — guard fiscal '
  '(P0423), compensa cuenta corriente (P0425), caja (P0426) y banco, revierte '
  'stock (#417), emite SaleOperationDeleted, cancela la sales_order del POS. '
  'Acepta p_sale_id (delete_by_id) o p_operation_id (delete_by_operation).';

REVOKE ALL ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) TO authenticated;

-- =============================================================================
-- 7. rpc_delete_purchase_operation — RPC atómica de borrado de compra
-- =============================================================================
-- Mismo molde que rpc_delete_sale_operation, sin la pata fiscal (las compras
-- no tienen concepto de comprobante fiscal propio) ni la de sales_order (no
-- existe un análogo "purchase_orders" en este modelo), ni la de caja (las
-- compras no tienen opt-in de caja — design.md Non-Goals, OQ-E recortado de
-- pagos-cableados-restantes: 0 movimientos de cash_movements de compra en
-- prod). Cuenta corriente de proveedor: reversión 'debit_note'.

DROP FUNCTION IF EXISTS public.rpc_delete_purchase_operation(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_delete_purchase_operation(
  p_purchase_id  uuid DEFAULT NULL,
  p_operation_id uuid DEFAULT NULL,
  p_reason       text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_purchase_ids         uuid[];
  v_row                  RECORD;
  v_supplier_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_bank_row             RECORD;
  v_reversed_type        text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_purchase_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_purchase_operation: se requiere p_purchase_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_purchase_ids
    FROM public.purchases
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.purchases
    WHERE id = p_purchase_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_purchase_ids
      FROM public.purchases
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      v_operation_key := p_purchase_id;
      v_purchase_ids := ARRAY[p_purchase_id];
    END IF;
  END IF;

  IF v_purchase_ids IS NULL OR array_length(v_purchase_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- ── Cuenta corriente de proveedor: reversión del cargo (debit_note, P0425 si negativo) ──
  SELECT supplier_account_id, SUM(amount)
  INTO v_supplier_account_id, v_charge_amount
  FROM public.supplier_account_movements
  WHERE reference_id = v_operation_key AND movement_type = 'purchase'
  GROUP BY supplier_account_id;

  IF v_supplier_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'supplier', v_supplier_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── Banco: espejo con dirección invertida ─────────────────────────────────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'purchase' AND source_doc_ref = v_operation_key
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'purchase', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  FOR v_row IN SELECT unnest(v_purchase_ids) AS id LOOP
    PERFORM public.rpc_reverse_stock_movement(v_row.id, 'purchase', COALESCE(p_reason, 'Compra eliminada'));
  END LOOP;

  -- ── Contable: emitir PurchaseDeleted (async, vía outbox) ──────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'PurchaseDeleted', 'Purchase', v_operation_key,
    jsonb_build_object(
      'account_id',   v_account_id,
      'operation_id', v_operation_key,
      'occurred_at',  now()
    ),
    now()
  );

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(v_purchase_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) IS
  'delete-guard-ledgers: RPC atómica de borrado de compra — compensa cuenta '
  'corriente de proveedor (P0425) y banco, revierte stock (#417), emite '
  'PurchaseDeleted. Acepta p_purchase_id (delete_by_id) o p_operation_id '
  '(delete_by_operation). Sin pata fiscal ni de sales_order (no aplican a compras).';

REVOKE ALL ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) TO authenticated;
