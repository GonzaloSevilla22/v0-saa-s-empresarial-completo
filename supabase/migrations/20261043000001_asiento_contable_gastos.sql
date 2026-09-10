-- =============================================================================
-- asiento-contable-gastos — el gasto pasa a producir su asiento de partida
-- doble por el mismo outbox que ya sirve a la venta, la compra y los cobros.
-- =============================================================================
--
-- Origen: D10 de gastos-forma-pago (archivado 2026-08-30) dejó dicho:
-- "_journal_post_from_event no tiene rama de gasto y public.events no tiene
-- ningún event_type de gasto. Este change deja lista la forma de pago, que
-- es el dato que le falta al asiento futuro para elegir la contrapartida."
-- El PO aprobó cerrar el candidato en el programa "cero candidatos"
-- (2026-09-07). 5300 Gastos figura desde journal-entry-outbox con la
-- anotación literal "(reservado)" — deja de estarlo con esta migración.
--
-- CHECKPOINT DE INTEGRIDAD DE FUNCIÓN (regla del proyecto desde
-- metodos-pago-operaciones): las seis funciones de esta migración se
-- rehashearon (md5(pg_get_functiondef), CRLF stripped) contra la base local
-- 2026-09-10, que refleja producción al día con origin/main hasta
-- 20261041000001 (importador-gastos-transaccional) + 42/2 tipos previos.
-- Las cinco reescrituras parten del cuerpo VIVO, NUNCA del último archivo de
-- migración — 6/6 hashes coincidieron exacto contra el registro del
-- orquestador antes de escribir esta línea:
--   rpc_create_expense(9 args)          c8f2ef987a6efe06ba0303e93d367d6a
--   rpc_update_expense(11 args)         1ffcbd2de7921f6e002a74a60307ac17
--   rpc_delete_expense(uuid)            4d78ee3b241bea2f4df34ceb0afb7cce
--   _journal_post_from_event(events)    1106ce7750c94f2e01e4752726411051
--   rpc_process_outbox_dispatch(int)    507b1bcdd8747c755b4c20c3ec928e97
--   _journal_sale_debit_account(text)   acc4e7d76bfded788b54f8f3e578a074 (molde, NO se toca)
--
-- MAX(version) verificado antes de escribir este archivo: origin/main llega
-- a 20261041000001 (41 migraciones); 20261042000001 está reservada por
-- productos-costo-nullable (en vuelo, aplicada sólo en la base local
-- compartida, aún sin mergear). Este archivo usa 20261043000001 — número
-- indicado explícitamente por el orquestador; si el orden de merge real
-- difiere, el propio orquestador renumera al rebasar (precedente:
-- cuenta-corriente-party-guard, renumerada tres veces).
--
-- Todo CREATE OR REPLACE, ninguna firma cambia (D12) → las ACLs se preservan
-- para las cinco funciones reescritas; sólo la función NUEVA
-- (_journal_expense_credit_account) necesita su REVOKE explícito, en este
-- mismo archivo. Cero ERRCODEs nuevos: P0450 (balance) y P0451 (asiento
-- original no encontrado) ya existen desde journal_entry_schema.
--
-- REUTILIZACIÓN ANTES QUE REPETICIÓN (regla PO 2026-08-02): el productor vive
-- ÚNICAMENTE dentro de las tres RPC de gasto (D1) — rpc_import_expenses NO SE
-- TOCA: invoca rpc_create_expense fila por fila y hereda la emisión del
-- evento sin una segunda definición. _journal_expense_credit_account es el
-- espejo exacto de _journal_sale_debit_account (D4), no un CASE embebido
-- repetido en las tres ramas del consumidor.
--
-- Qué agrega:
--   1. _journal_expense_credit_account(text) — mapeo kind→cuenta de crédito.
--   2. _journal_post_from_event — filtro 11→14 + tres ramas ELSIF nuevas
--      (ExpenseCreated / ExpenseAdjusted / ExpenseDeleted), sin tocar NINGUNA
--      rama previa (control de no-regresión, task 4.10).
--   3. rpc_create_expense — INSERT INTO events plano al final (ExpenseCreated).
--   4. rpc_update_expense — INSERT INTO events plano tras el UPDATE, sólo si
--      existe el ExpenseCreated del gasto (D7). NO se suma al guard P0423.
--   5. rpc_delete_expense — INSERT INTO events plano ANTES del DELETE físico
--      (el account_id ya no se podría leer después), sólo si existe el
--      ExpenseCreated (D7).
--   6. rpc_process_outbox_dispatch — filtro del Consumer 3, 11→14, idéntico
--      al del helper (invariante D8, gate cableado en el mismo PR).
--   7. Dos índices (idx_journal_entries_source_doc, idx_events_aggregate) —
--      corrección de findings, revisor ronda 1 (nit).
--
-- CORRECCIÓN DE FINDINGS (revisor, ronda 1, 2026-09-10):
--   - [blocker] Lookup del "asiento vigente" en ExpenseAdjusted/ExpenseDeleted
--     no excluía contra-asientos (reversal_of): a partir de la 2a edición de
--     un mismo gasto revertía el contra-asiento en vez del asiento vigente.
--     Fix: `AND reversal_of IS NULL` + `ORDER BY posted_at DESC, created_at
--     DESC` en los dos lookups.
--   - [major] rpc_update_expense derivaba el kind del CRÉDITO de la forma de
--     pago DECLARADA en la edición, no de lo que realmente ocurrió en los
--     libros de dinero — la edición nunca mueve caja ni banco (D6), así que
--     cambiar a un kind bancario en la edición podía acreditar 1110 Banco sin
--     ningún bank_movement real que lo respalde. Fix: v_final_kind se deriva
--     de la EXISTENCIA de bank_movements del gasto (D4 design.md: "el asiento
--     nombra la cuenta que efectivamente se movió"), nunca del payment_method.
--   - Gate ampliado con la triangulación que faltaba: doble edición del mismo
--     gasto (bloque F) y alta→edición→borrado (bloque F2), más el bloque F3
--     (edición no acredita 1110 sin bank_movement real).
--   - Dos índices nuevos (arriba) — costo despreciable hoy, público.events y
--     journal_entries sin política de retención.
--
-- CORRECCIÓN DE FINDINGS (revisor, ronda 2, 2026-09-10):
--   - [major] El delta de spec (openspec/changes/asiento-contable-gastos/
--     specs/journal-entry/spec.md) prescribía la clave de búsqueda del
--     "asiento vigente" SIN `reversal_of IS NULL` — exactamente el predicado
--     que el fix [blocker] de la ronda 1 sumó al CÓDIGO pero que el propose
--     nunca corrigió en la spec. El código ya era correcto (verificado con
--     datos reales); sólo la spec quedaba enseñando la clave defectuosa a
--     quien la reimplemente. Fix puramente documental: los dos requirements
--     (`ExpenseAdjusted`/`ExpenseDeleted`) ahora incluyen `reversal_of IS
--     NULL` en la tupla, un SHALL normativo de "a lo sumo un asiento vigente
--     por gasto en todo momento", y dos scenarios nuevos que fijan lo que el
--     gate ya asserta: segunda edición (bloque F) y alta→edición→borrado
--     (bloque F2).
--   - [nit] Los dos predicados D7 (rpc_update_expense/rpc_delete_expense)
--     filtraban `public.events` por `event_type` + `aggregate_id` +
--     `account_id`, sin `aggregate_type` — el índice `idx_events_aggregate`
--     de la ronda 1 lidera por `aggregate_type`, así que esos dos EXISTS no
--     lo aprovechaban por prefijo (EXPLAIN confirmado: Index Cond sólo sobre
--     `aggregate_id`). Fix: se suma `AND aggregate_type = 'Expense'` a los
--     dos — son eventos de gasto por construcción, no cambia la semántica —
--     y ahora sí calzan con el índice por columna líder.
--   - [minor, residual documentado — no corregido en código] Editar la forma
--     de pago de un gasto a un kind bancario (transfer/card/check/wallet)
--     sin que exista un bank_movement real (porque la edición nunca mueve
--     dinero, D6) deja el documento diciendo "Transferencia" mientras el
--     asiento sigue acreditando 1100 Caja — el fix [major] de la ronda 1 hizo
--     que el asiento sea el más HONESTO de los tres artefactos (no hay
--     bank_movement, no hay 1110), pero la contradicción visual queda
--     visible por primera vez en /reportes/libro-diario. Se documenta en
--     design.md §D15 y como candidato en CHANGES.md en vez de rechazar el
--     cambio en rpc_update_expense (opción (a) del revisor): la opción (b)
--     no ensancha la superficie de este change con un ERRCODE y un caso de
--     validación nuevos sobre una decisión de diseño ya firmada (D14, ronda
--     1), y el estado contable queda visible en /gastos y en el libro diario
--     para que el PO lo note en el humo real (task 14.2).
--
-- Idempotencia del archivo: CREATE OR REPLACE en las seis funciones + CREATE
-- INDEX IF NOT EXISTS → reaplicable N veces sin efecto adicional (verificado,
-- task 6.4).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1) Helper nuevo: _journal_expense_credit_account(kind) — espejo de
--    _journal_sale_debit_account(kind) MENOS el caso credit/1300, que el
--    gasto rechaza en la puerta (P0400, credit_not_supported_for_expense).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._journal_expense_credit_account(p_kind text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  -- D4 (asiento-contable-gastos): espejo de _journal_sale_debit_account,
  -- SIN la rama credit — un gasto no tiene contraparte con cuenta corriente,
  -- se rechaza en rpc_create_expense/rpc_update_expense antes de llegar acá.
  -- 'cash'/'other'/NULL (sin imputar) acreditan 1100 Caja: el opt-in de caja
  -- gobierna el arqueo, no la cuenta contable (OQ-2); sin imputar NO va a
  -- 2100 Proveedores porque el gasto no tiene proveedor al que deberle (OQ-1).
  SELECT CASE
    WHEN p_kind IN ('transfer', 'card', 'check', 'wallet') THEN '1110'
    ELSE '1100'  -- cash, other, NULL (sin imputar)
  END;
$function$;

REVOKE ALL ON FUNCTION public._journal_expense_credit_account(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._journal_expense_credit_account(text) FROM anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2) _journal_post_from_event — filtro 11→14 + tres ramas de gasto nuevas.
--    Reescritura completa a partir del cuerpo vivo (md5 arriba); las once
--    ramas previas quedan byte a byte, mismo orden, mismas condiciones.
-- ─────────────────────────────────────────────────────────────────────────────
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

  asiento-contable-gastos (2026-09-10): agrega TRES ramas de gasto — el
  último documento operativo que movía dinero sin dejar rastro contable
  (D10 de gastos-forma-pago). Débito único a 5300 Gastos con el
  cost_center_id de la línea (mismo trato que 5100 en PurchaseCreated);
  crédito por _journal_expense_credit_account(kind), espejo de
  _journal_sale_debit_account menos el caso credit (D4):
    - ExpenseCreated: asiento nuevo, fechado por la fecha de negocio del
      gasto (D5, mismo idioma que SaleOperationCreated).
    - ExpenseAdjusted: molde BYTE A BYTE de SaleOperationAdjusted — localizar
      + revertir + volver a postear con los valores editados.
    - ExpenseDeleted: molde de SaleOperationDeleted/PurchaseDeleted — SOLO
      revertir, la contra-entry es la única entry del evento. La
      localización NO lee public.expenses: el borrado del gasto es físico y
      la fila ya no existe cuando el relay corre.
  D7 (en las tres RPC de gasto, no acá): el productor de ExpenseAdjusted y
  ExpenseDeleted sólo emite si existe un ExpenseCreated previo — evita el
  evento envenenado de un gasto histórico sin backfill (OQ-3).
  El conjunto canónico pasa de 11 a 14 tipos (D8) — invariante verificado por
  supabase/tests/test_cobranzas_reverso.sql bloque (11), cableado a CI en
  este mismo PR.

  Responsabilidades:
    1. Filtrar por event_type (14 tipos en-scope; no-op para el resto).
    2. Reclamar slot de idempotencia (event_id, 'JournalEntry') en operation_idempotency.
    3. Calcular las líneas de débito/crédito según el mapeo hardcodeado (D1, D4 del
       change journal-entry-outbox) + ruteo bancario (C2 D3, extendido por
       pagos-cableados-restantes D7) + mapeo de gasto (asiento-contable-gastos D4).
    4. Validar Σdébito = Σcrédito (ASSERT — D5, ERRCODE P0450).
    5. INSERT journal_entries + journal_lines.

  Codigos de cuenta hardcodeados (D1 journal-entry-outbox — plan mínimo PYME AR):
    1100 Caja / 1110 Banco (C2: wireado — antes reservado) / 1300 Deudores por Ventas
    2100 Proveedores / 4100 Ventas / 4200 IVA Débito Fiscal
    5100 CMV/Compras / 5200 IVA Crédito Fiscal / 5300 Gastos (asiento-contable-gastos: EN USO)

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
  ExpenseCreated / ExpenseAdjusted (nuevo entry): _journal_expense_credit_account(kind)
                     — bancario→1110; cash/other/sin-imputar→1100; SIN rama credit.

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
            PaymentMadeReversed / ExpenseAdjusted / ExpenseDeleted (retry).
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
    -- asiento-contable-gastos: identificador del gasto, source_doc_ref de
    -- las tres ramas nuevas.
    v_expense_id      uuid;

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
    -- SaleOperationAdjusted. asiento-contable-gastos reutiliza la misma
    -- variable para el mismo propósito en las ramas de gasto.
    v_posted_at       timestamptz;
BEGIN
    v_account_id := p_event.account_id;
    v_payload     := p_event.payload;
    v_event_type  := p_event.event_type;

    -- ── Filtro: solo los 14 tipos en-scope ───────────────────────────────────
    -- asiento-contable-gastos: suma ExpenseCreated / ExpenseAdjusted /
    -- ExpenseDeleted (11→14). Este filtro y el de rpc_process_outbox_dispatch
    -- DEBEN listar el mismo conjunto (invariante documentado desde
    -- journal-entry-outbox, verificado por gate desde cobranzas-reverso — D13,
    -- ampliado a 14 por D8 de este change).
    IF v_event_type NOT IN (
        'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
        'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
        'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted',
        'PaymentReceivedReversed', 'PaymentMadeReversed',
        'ExpenseCreated', 'ExpenseAdjusted', 'ExpenseDeleted'
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

    ELSIF v_event_type = 'ExpenseCreated' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-contable-gastos (D3/D4/D5): asiento nuevo — débito único a
        -- 5300 Gastos con el cost_center_id del gasto (mismo trato que 5100
        -- en PurchaseCreated), crédito por _journal_expense_credit_account
        -- (espejo de _journal_sale_debit_account, sin la rama credit).
        -- Fechado por la fecha de negocio del gasto (D5, mismo idioma que
        -- SaleOperationCreated) — NUNCA por el instante del relay.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'kind';  -- crudo, puede ser NULL (sin imputar)
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;
        v_expense_id     := (v_payload->>'expense_id')::uuid;

        IF v_payload->>'expense_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'expense_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'Expense',
            v_expense_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '5300', 'debit', v_total, v_line_no, v_cost_center_id);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_expense_credit_account(v_payment_method),
                'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'ExpenseAdjusted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-contable-gastos (D6): molde BYTE A BYTE de
        -- SaleOperationAdjusted — localizar + revertir + volver a postear con
        -- los valores editados. El asiento posteado NO vuelve inmutable al
        -- gasto (D6): este productor sólo se emite si existe ExpenseCreated
        -- (D7, garantizado por el caller, no acá).
        -- ──────────────────────────────────────────────────────────────────────
        v_expense_id := (v_payload->>'expense_id')::uuid;

        -- Corrección de findings (revisor, ronda 1, blocker): excluir
        -- contra-asientos (reversal_of IS NOT NULL) del lookup del "vigente".
        -- Sin este filtro, a partir de la SEGUNDA edición hay DOS filas
        -- status='posted' para el mismo source_doc_ref (el asiento nuevo Y el
        -- contra-asiento de la edición anterior) y LIMIT 1 elige una
        -- arbitraria — revirtiendo el contra-asiento en vez del vigente.
        -- ORDER BY por robustez: aun con el filtro, si alguna vez hubiera más
        -- de una fila válida, quedarse con la más reciente.
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'Expense'
          AND source_doc_ref  = v_expense_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el gasto % (ExpenseAdjusted %). El evento quedará pending for retry.',
                v_expense_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- Contra-entry: reversión exacta, lados invertidos. posted_at=now():
        -- la corrección data la corrección, no el gasto original.
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        VALUES (
            v_account_id, now(), NULL, 'Expense',
            v_expense_id, 'posted', v_orig_entry_id
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
                'journal_balance_assertion_failed: la contra-entry de ExpenseAdjusted % no balancea (ERRCODE P0450).',
                p_event.id
                USING ERRCODE = 'P0450';
        END IF;

        -- El asiento vigente queda revertido.
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

        -- Asiento nuevo: valores editados, mismo mapeo que ExpenseCreated.
        v_sum_debit  := 0;
        v_sum_credit := 0;

        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'kind';
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;

        IF v_payload->>'expense_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'expense_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'Expense',
            v_expense_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '5300', 'debit', v_total, v_line_no, v_cost_center_id);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_expense_credit_account(v_payment_method),
                'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'ExpenseDeleted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-contable-gastos: molde de SaleOperationDeleted/PurchaseDeleted
        -- — SOLO revertir, la contra-entry es la ÚNICA entry del evento → lleva
        -- su propio source_event_id. La localización NO lee public.expenses:
        -- el borrado del gasto es físico y la fila ya no existe cuando el
        -- relay corre — el evento ya trae todo lo necesario (D7, emitido sólo
        -- si existe ExpenseCreated, garantizado por el caller).
        -- ──────────────────────────────────────────────────────────────────────
        v_expense_id := (v_payload->>'expense_id')::uuid;

        -- Corrección de findings (revisor, ronda 1, blocker): mismo fix que
        -- ExpenseAdjusted arriba — excluir contra-asientos del lookup del
        -- "vigente" para no revertir el contra-asiento de una edición previa
        -- en vez del asiento que refleja el estado real del gasto.
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'Expense'
          AND source_doc_ref  = v_expense_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el gasto borrado (ExpenseDeleted %). El evento quedará pending for retry.',
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
        -- tabla contra v_entry_id — que en SaleOperationAdjusted/ExpenseAdjusted
        -- apunta al asiento NUEVO (la contra-entry ya se validó individualmente
        -- más arriba, antes de marcarse reversed el original). SaleOperationDeleted
        -- / PurchaseDeleted / PaymentReceivedReversed / PaymentMadeReversed /
        -- ExpenseDeleted quedan cubiertas por esta misma rama genérica:
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
                'El asiento no balancea — evento quedará pending for retry.',
                v_sum_debit, v_sum_credit, p_event.id
                USING ERRCODE = 'P0450';
        END IF;
    END IF;

END;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3) rpc_create_expense — INSERT INTO events plano (ExpenseCreated), al final,
--    después de que caja/banco ya se resolvieron. Firma intacta (9 args).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_expense(p_category text, p_amount numeric, p_date date, p_description text DEFAULT NULL::text, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_expense_id          uuid;
  v_branch              RECORD;
  v_gate_branch         uuid;
  v_kind                text;
  v_cash_movement_id    uuid;
  v_bank_movement_id    uuid;
  v_cash_session_status text;
  v_cash_session_branch uuid;
BEGIN
  -- ── (a) Autenticación, tenant desde la SESIÓN y rol de escritura ──────────
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede registrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── IMPORTE POSITIVO — la precondición de la que depende TODO lo de abajo ─
  -- COPIADO VERBATIM de los dos baselines de los que este RPC toma sus otros
  -- predicados (rpc_create_sale_operation_v2 L154 y rpc_create_purchase_
  -- operation L239: 'Amount must be greater than zero', P0400). La primera
  -- versión de este archivo se trajo el bloque de opt-in de caja y la llamada
  -- bancaria y dejó afuera esta línea, y sin ella:
  --   · la pata de caja registra `-p_amount`, o sea que con p_amount = -5000
  --     escribe un movimiento 'expense' de +5000 — un "gasto" que SUMA plata
  --     al cajón que después se arquea y se firma;
  --   · el guard de signo del borrado (sección 4, `v_cash_amount < 0`) queda
  --     FALSO sobre ese movimiento positivo, así que el DELETE procede SIN
  --     registrar el expense_reversal y la plata fantasma queda sin ningún
  --     documento que la respalde ni forma de rastrearla (el gasto ya no
  --     existe). Es el modo de falla exacto de delete-guard-ledgers —204
  --     operaciones backfilleadas— reintroducido por el change que dice
  --     cerrarlo;
  --   · la pata bancaria produce un 'transfer_out' que AUMENTA el saldo y se
  --     va a la conciliación contra el extracto real.
  -- Se rechaza en el SERVIDOR aunque la UI ya lo limite, por la misma doctrina
  -- que D3: la API no puede ser un bypass del formulario. Gate: sección 8.
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Derivación del kind desde el catálogo ─────────────────────────────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2: el kind se
  -- DERIVA del catálogo, nunca se acepta como texto del cliente, y el mismo
  -- predicado (id + account_id + is_active + deleted_at) cubre de una vez la
  -- forma de pago ajena, la inactiva y la borrada.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = v_account_id
      AND is_active = TRUE AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ── D3: credit NO aplica a un gasto ───────────────────────────────────────
  -- expenses no tiene contraparte (ni supplier_id ni client_id): no hay cuenta
  -- corriente que cargar. Se rechaza en el servidor además de ocultarse en la
  -- UI, para que la API no sea un bypass del selector.
  IF v_kind = 'credit' THEN
    RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Sucursal: mismo predicado y mismo COALESCE que la venta (C-26 / D6) ───
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  -- ── Centro de costo: mismo predicado que la edición de compra ─────────────
  -- (rpc_atomic_update_purchase_operation). El INSERT plano que este RPC
  -- reemplaza aceptaba cualquier cost_center_id, incluido el de otra cuenta:
  -- la FK no está scopeada por tenant.
  IF p_cost_center_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.cost_centers
      WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'cost_center_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ── D5: la cuenta bancaria deja de fallar en silencio EN EL GASTO ─────────
  -- BLOQUEANTE DE PRODUCTO MEDIDO: payment_methods con bank_account_id
  -- configurado = 0 de 37 cuentas. Con la cuenta sin resolver,
  -- _pay_register_operation_bank_movement retorna NULL SIN ERROR — o sea que,
  -- tal cual está, el pedido literal del PO ("que estos movimientos concilien
  -- banco") fallaría en silencio para el 100% de los tenants.
  --
  -- El guard vive ACÁ, en el caller, y NO en el helper: la spec bank-movement
  -- tiene un escenario explícito —"sin cuenta resuelta la venta sigue
  -- funcionando igual que antes"— y el helper es punto de paso de venta,
  -- compra y POS. El endurecimiento asimétrico es deliberado: el gasto NACE
  -- con este contrato, las ventas no.
  --
  -- CONDICIONADO a que la organización tenga al menos una cuenta bancaria
  -- activa: un guard incondicional dejaría a 33 de 37 tenants sin poder
  -- registrar un gasto por transferencia hasta que carguen una cuenta — un
  -- bloqueo de registro por un problema de configuración, el mismo error que
  -- D1 evita en caja.
  --
  -- La resolución se hace con el MISMO helper que usará después
  -- _pay_register_operation_bank_movement (override → default → NULL), así que
  -- no hay una segunda definición de "qué cuenta corresponde"; y si la cuenta
  -- informada es ajena, inactiva o borrada, el propio helper ya levanta P0412
  -- desde acá.
  IF v_kind IN ('transfer', 'card', 'check', 'wallet')
     AND public._pay_resolve_bank_account(v_account_id, p_payment_method_id, p_bank_account_id) IS NULL
     AND EXISTS (
       SELECT 1 FROM public.bank_accounts
       WHERE account_id = v_account_id AND is_active = TRUE AND deleted_at IS NULL
     )
  THEN
    RAISE EXCEPTION 'bank_account_required_for_expense: elegí la cuenta bancaria de la que sale el dinero — sin ella el gasto no aparecería nunca en la conciliación bancaria'
      USING ERRCODE = 'P0412';
  END IF;

  -- ── (b) El gasto ──────────────────────────────────────────────────────────
  -- D6: branch_id se persiste RESUELTO (COALESCE con la default), no crudo:
  -- el escenario de spec exige que un gasto sin sucursal informada quede con
  -- la sucursal por defecto de la cuenta. RN-93 estaba incumplida al 100%
  -- para gastos (0 de 175).
  INSERT INTO public.expenses
    (user_id, account_id, category, amount, description, date,
     branch_id, cost_center_id, payment_method_id)
  VALUES
    (v_uid, v_account_id, p_category, p_amount, p_description, p_date,
     v_gate_branch, p_cost_center_id, p_payment_method_id)
  RETURNING id INTO v_expense_id;

  -- ── (c) PATA DE CAJA — opt-in explícito con las tres condiciones ──────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2 (bloque
  -- "pagos-cableados-restantes OQ-C/D4"), con las dos ÚNICAS adaptaciones que
  -- D1 autoriza:
  --   (a) p_date se declara `date` y se compara DIRECTO contra
  --       reporting_local_today(). ⚠️ PROHIBIDO `p_date timestamptz` con
  --       `p_date::date`: ese cast se resuelve en el TimeZone de la SESIÓN
  --       (UTC en este servidor) mientras reporting_local_today() es
  --       (now() AT TIME ZONE 'America/Argentina/Mendoza')::date, así que un
  --       gasto legítimo de hoy cargado entre las 21:00 y las 23:59 ART
  --       (= 00:00-02:59 UTC del día siguiente) se rechazaría con P0422 justo
  --       en la franja en que el microemprendedor cierra el día. Con `date` el
  --       resultado es invariante por construcción — y lo que ya viaja por el
  --       payload es una fecha pura (ExpenseCreate.date: datetime.date).
  --   (b) c28_register_cash_movement(sesión, -p_amount, 'expense', id_del_gasto):
  --       signo NEGATIVO (egreso) y el gasto como referencia.
  --
  -- La ausencia de p_cash_session_id es NO-OP: bloquear el alta porque no hay
  -- caja abierta convertiría un problema de arqueo en un problema de registro
  -- (D1). El helper aporta gratis P0409 (sesión abierta), P0401 (tenencia,
  -- agregada por tenancy-guard-caja-outbox — el gasto es exactamente el
  -- "caller futuro" que ese guard fue escrito para cubrir), P0422 (sucursal
  -- activa), balance_after serializado y created_by.
  IF p_cash_session_id IS NOT NULL THEN
    IF v_kind IS DISTINCT FROM 'cash' THEN
      RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
        USING ERRCODE = 'P0422';
    END IF;

    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cs.id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva del gasto'
        USING ERRCODE = 'P0422';
    END IF;

    IF p_date <> public.reporting_local_today() THEN
      RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja un gasto fechado hoy (%)', public.reporting_local_today()
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      -- qa-integral-modulos (G16/H11): 5o argumento p_description — el motivo
      -- del gasto viaja al historial de caja (antes se omitia y quedaba NULL).
      p_cash_session_id, -p_amount, 'expense', v_expense_id, p_description
    );
  END IF;

  -- ── PATA BANCARIA — llamada INCONDICIONAL al helper compartido ────────────
  -- CALCADA de la de rpc_create_purchase_operation (baseline), que ya despacha
  -- un EGRESO con este mismo helper. Sin ningún IF previo: el helper decide.
  -- Aporta gratis el predicado kind IN ('transfer','card','check','wallet'),
  -- la resolución override→default→NULL, la validación de la cuenta (P0412),
  -- el rechazo de cuenta bancaria sobre kind no bancario (P0400), el mapa
  -- kind→movement_type (card→card_settlement, resto out→transfer_out), el
  -- signo y el guard de período conciliado (P0424), que revierte la operación
  -- ENTERA si la fecha cae dentro de una reconciliation_sessions cerrada.
  --
  -- p_value_date = p_date, que ya es `date` (D1) y por lo tanto no arrastra
  -- ningún cast dependiente de la zona de la sesión. Va SÍ O SÍ: con NULL el
  -- movimiento caería en created_at y la sugerencia automática de conciliación
  -- (monto exacto, ventana ±3 días) se desalinearía del extracto.
  --
  -- p_branch_id = v_gate_branch: la sucursal EFECTIVA, la misma que se
  -- persistió en el gasto.
  v_bank_movement_id := public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    p_amount, 'out', 'expense', v_expense_id,
    -- qa-integral-modulos (G16/H11): p_description reemplaza el NULL literal —
    -- el motivo del gasto viaja al historial bancario.
    p_date, v_gate_branch, p_description
  );

  -- ── asiento-contable-gastos: ExpenseCreated, INSERT plano, misma transacción ──
  -- Sin manejador de excepciones (spec transactional-outbox: "tragarse un
  -- evento fallido mientras la mutación commitea dejaría el dinero movido y
  -- el libro diario sin el asiento correspondiente, en silencio"). El
  -- productor vive ACÁ (D1): rpc_import_expenses invoca esta RPC fila por
  -- fila y hereda la emisión sin una segunda definición. p_date ya es `date`
  -- pura (D5, ⚠️ nunca el timestamptz de expenses.date) y v_kind viaja crudo,
  -- incluido NULL (sin imputar) — la presunción de la cuenta vive en el
  -- consumidor, no acá.
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload)
  VALUES (
    v_account_id, 'ExpenseCreated', 'Expense', v_expense_id,
    jsonb_build_object(
      'account_id', v_account_id,
      'expense_id', v_expense_id,
      'amount', p_amount,
      'expense_date', p_date,
      'cost_center_id', p_cost_center_id,
      'kind', v_kind
    )
  );

  RETURN jsonb_build_object(
    'expense_id',       v_expense_id,
    'branch_id',        v_gate_branch,
    'payment_method_kind', v_kind,
    'cash_movement_id', v_cash_movement_id,
    'bank_movement_id', v_bank_movement_id
  );
END;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4) rpc_update_expense — INSERT INTO events plano (ExpenseAdjusted), sólo si
--    existe el ExpenseCreated del gasto (D7). NO se suma al guard P0423
--    (D6): los dos EXISTS de caja/banco quedan exactamente como están.
--    Firma intacta (11 args).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_update_expense(p_expense_id uuid, p_category text DEFAULT NULL::text, p_amount numeric DEFAULT NULL::numeric, p_date date DEFAULT NULL::date, p_description text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_old                 RECORD;
  v_branch              RECORD;
  v_final_payment_method_id uuid;
  v_final_branch_id     uuid;
  v_final_cost_center_id    uuid;
  -- asiento-contable-gastos (D7): valores finales resultantes de la edición,
  -- para la carga de ExpenseAdjusted — mismo mapeo que ExpenseCreated.
  v_final_amount        numeric;
  v_final_date          date;
  v_final_kind          text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede editar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Localización POR TENANT: si el gasto no aparece, P0404 — sin distinguir
  -- "no existe" de "es de otra cuenta" (D4).
  SELECT * INTO v_old
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── D11: los dos guards de inmutabilidad, ANTES DE CUALQUIER ESCRITURA ────
  -- Mismos predicados y mismo ERRCODE que rpc_atomic_update_sale_operation
  -- (baseline). Los mensajes son distinguibles a propósito: el usuario tiene
  -- que saber cuál de los dos libros produjo el bloqueo.
  --
  -- asiento-contable-gastos (D6): la existencia de un ASIENTO contable NO se
  -- suma a estos guards. Un gasto sin movimiento de caja ni bancario sigue
  -- siendo plenamente editable aunque ya tenga su asiento posteado; la
  -- edición lo corrige por el par contra-asiento/asiento nuevo más abajo.
  IF EXISTS (
    SELECT 1 FROM public.cash_movements cm
    WHERE cm.reference_id = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_cash_movement_immutable: el gasto tiene un movimiento de caja posteado y no puede editarse — borralo y volvé a cargarlo (el borrado compensa la caja)'
      USING ERRCODE = 'P0423';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_bank_movement_immutable: el gasto tiene un movimiento bancario posteado y no puede editarse — borralo y volvé a cargarlo (el borrado registra el movimiento espejo)'
      USING ERRCODE = 'P0423';
  END IF;

  -- ── Importe positivo, espejo del alta ─────────────────────────────────────
  -- Sin esto la edición sería el bypass del guard del alta: un gasto legítimo
  -- pasaría a importe negativo con un solo PUT. `NULL` conserva la semántica
  -- COALESCE heredada del UPDATE que este RPC reemplaza ("no cambia"), y por
  -- eso el predicado es IS NOT NULL AND <= 0 y no el del alta.
  IF p_amount IS NOT NULL AND p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── D12: tri-estado, campo por campo, con validación ANTES del UPDATE ─────
  IF p_payment_method_provided THEN
    -- ⚠️ La validación de reimputación se aplica SÓLO cuando el valor cambia.
    -- El formulario manda `paymentMethodId` SIEMPRE (está en el literal del
    -- payload) y en edición ofrece a propósito las formas dadas de baja
    -- (`includeInactive={isEdit}`, para que un gasto histórico siga nombrando
    -- la suya). Con el predicado aplicado sin excepción, desactivar una forma
    -- de pago volvía INOPERABLE todo gasto que la usara: cualquier edición
    -- —aunque sólo tocara el importe— rebotaba con P0404 hasta reactivarla.
    -- Reenviar el valor vigente es PRESERVAR, no reimputar. La TENENCIA sí se
    -- verifica siempre: lo que se relaja es `is_active`/`deleted_at`, nunca el
    -- `account_id`. Gate: sección 8.7, con control negativo (cambiar a OTRA
    -- forma inactiva sigue siendo P0404).
    IF p_payment_method_id IS NOT NULL
       AND p_payment_method_id IS DISTINCT FROM v_old.payment_method_id THEN
      -- Mismo predicado que el alta: cuenta + activa + no borrada.
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
      -- D3 también en la edición: la API no puede ser un bypass del selector.
      IF (SELECT kind FROM public.payment_methods WHERE id = p_payment_method_id) = 'credit' THEN
        RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
          USING ERRCODE = 'P0400';
      END IF;
    ELSIF p_payment_method_id IS NOT NULL THEN
      -- Reenvío del valor vigente: sólo tenencia (el gasto ya es del tenant,
      -- pero la FK de payment_methods no está scopeada por cuenta y el guard
      -- de tenencia no se relaja nunca — lección de cuenta-corriente-party-guard).
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old.payment_method_id;
  END IF;

  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old.branch_id;
  END IF;

  IF p_cost_center_provided THEN
    IF p_cost_center_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.cost_centers
        WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
      ) THEN
        RAISE EXCEPTION 'cost_center_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_cost_center_id := p_cost_center_id;
  ELSE
    v_final_cost_center_id := v_old.cost_center_id;
  END IF;

  UPDATE public.expenses
  SET category          = COALESCE(p_category, v_old.category),
      amount            = COALESCE(p_amount, v_old.amount),
      date              = COALESCE(p_date::timestamptz, v_old.date),
      description       = COALESCE(p_description, v_old.description),
      payment_method_id = v_final_payment_method_id,
      branch_id         = v_final_branch_id,
      cost_center_id    = v_final_cost_center_id
  WHERE id = p_expense_id AND account_id = v_account_id;

  -- ── asiento-contable-gastos (D7): ExpenseAdjusted, SÓLO si existe el alta ──
  -- El predicado evalúa la EXISTENCIA DEL EVENTO de alta, nunca la del
  -- asiento: un gasto creado y editado/borrado dentro de la misma ventana de
  -- relay tiene su ExpenseCreated sin procesar y todavía no tiene asiento, y
  -- tiene que emitir igual — el relay procesa en orden de ocurrencia y el
  -- fallo recuperable (P0451) del consumidor resuelve si quedan en corridas
  -- distintas. Un gasto histórico (sin ExpenseCreated) no emite nada: si
  -- emitiera, el consumidor jamás encontraría el asiento original y
  -- reintentaría con P0451 cada minuto, para siempre (evento envenenado).
  IF EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'ExpenseCreated' AND aggregate_type = 'Expense' AND aggregate_id = p_expense_id AND account_id = v_account_id
  ) THEN
    v_final_amount := COALESCE(p_amount, v_old.amount);
    v_final_date   := COALESCE(p_date, v_old.date::date);

    -- Corrección de findings (revisor, ronda 1, major): el `kind` que decide
    -- la CONTRAPARTIDA del asiento se deriva de lo que REALMENTE ocurrió en
    -- los libros de dinero (design.md D4: "el asiento nombra la cuenta del
    -- libro que efectivamente se movió"), NUNCA de la forma de pago
    -- declarada en el edit. rpc_update_expense jamás llama a
    -- _pay_register_operation_bank_movement ni a c28_register_cash_movement
    -- (la edición no mueve dinero, D6) — y el guard de inmutabilidad de
    -- arriba ya garantiza que, si llegamos hasta acá, el gasto NO tiene
    -- ningún bank_movement posteado. Sin este fix, cambiar la forma de pago
    -- a un kind bancario en la edición acreditaría 1110 Banco sin que exista
    -- ningún movimiento bancario real que lo respalde — un descuadre de
    -- conciliación esperando a pasar. La rama IS NULL (verdadera 100% del
    -- tiempo, por el guard de arriba) queda declarada por robustez, no por
    -- necesidad: si alguna vez cambia el guard, este derivado sigue siendo
    -- correcto sin tocarlo.
    IF EXISTS (
      SELECT 1 FROM public.bank_movements bm
      WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
    ) THEN
      -- Los cuatro kind bancarios son equivalentes para
      -- _journal_expense_credit_account (todos → 1110): cualquiera sirve.
      v_final_kind := 'transfer';
    ELSE
      v_final_kind := NULL;
    END IF;

    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload)
    VALUES (
      v_account_id, 'ExpenseAdjusted', 'Expense', p_expense_id,
      jsonb_build_object(
        'account_id', v_account_id,
        'expense_id', p_expense_id,
        'amount', v_final_amount,
        'expense_date', v_final_date,
        'cost_center_id', v_final_cost_center_id,
        'kind', v_final_kind
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'payment_method_id', v_final_payment_method_id,
    'branch_id',         v_final_branch_id,
    'cost_center_id',    v_final_cost_center_id
  );
END;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5) rpc_delete_expense — INSERT INTO events plano (ExpenseDeleted), SÓLO si
--    existe el ExpenseCreated (D7), ANTES del DELETE físico (el account_id
--    ya no se podría leer después). Firma intacta (uuid).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_delete_expense(p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_expense          RECORD;
  v_cashbox_id       uuid;
  v_cash_amount      numeric(12,2);
  v_open_session_id  uuid;
  v_cash_reversal_id uuid;
  v_bank_row         RECORD;
  v_reversed_type    text;
  v_bank_reversals   integer := 0;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede borrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  -- Copiado del baseline de rpc_delete_sale_operation (20261005000001:1205-1234)
  -- CON UNA INVERSIÓN OBLIGATORIA Y EXPLÍCITA DEL GUARD DE SIGNO.
  --
  -- ⚠️⚠️ El original es `IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0`,
  -- porque los movimientos agrupados de una VENTA son de tipo 'sale' con
  -- importe POSITIVO. Los del GASTO son de tipo 'expense' con importe
  -- NEGATIVO (lo fija este mismo change: expense negativo, expense_reversal
  -- positivo). Copiado verbatim, `v_cash_amount > 0` es FALSO PARA TODO GASTO:
  -- se saltearía el bloque entero, no se registraría el expense_reversal,
  -- NUNCA se lanzaría P0426 y el DELETE procedería igual — se reintroduciría
  -- exactamente el borrado inseguro que motivó delete-guard-ledgers, desde el
  -- change que dice cerrarlo. Y sin levantar un solo error.
  --
  -- Por eso el guard correcto NO es el positivo del original, y por eso el
  -- gate tiene un CONTROL NEGATIVO obligatorio (5.4b): un test que sólo
  -- assertara "no hubo error" quedaría verde por omisión.
  --
  -- ⚠️ Y por eso tampoco es `v_cash_amount < 0`: esa forma sigue dependiendo
  -- de una invariante que vive en OTRA función (que el alta nunca acepte un
  -- importe no positivo). El guard es `<> 0`: **existe movimiento de caja del
  -- gasto ⇒ SIEMPRE se compensa**, cualquiera sea el signo. Con `< 0`, un solo
  -- movimiento 'expense' positivo —el que producía el alta antes del guard de
  -- P0400, o cualquier camino futuro— hacía que el DELETE procediera sin
  -- compensar y SIN levantar un error. El SELECT de abajo ya filtra
  -- `movement_type = 'expense'`, así que las reversas no se autocompensan.
  -- Gate: sección 8.5, que inyecta a mano el estado corrupto.
  --
  -- La sesión ORIGINAL nunca se toca: el ledger de caja es append-only. El
  -- contra-movimiento va SIEMPRE a la sesión abierta actual de la MISMA caja,
  -- con el mismo criterio que ya rige para el borrado de una venta en efectivo.
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = p_expense_id AND movement_type = 'expense'
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
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar este gasto'
        USING ERRCODE = 'P0426';
    END IF;

    -- El movimiento del gasto es NEGATIVO (lo garantiza el guard de importe
    -- positivo del alta), así que -v_cash_amount da el INGRESO positivo que
    -- repone la plata en el cajón. Si por cualquier camino el movimiento
    -- fuera positivo, la contra-partida sale negativa y compensa igual: la
    -- reversa es siempre el opuesto exacto de lo que se posteó.
    v_cash_reversal_id := public.c28_register_cash_movement(
      -- qa-integral-modulos (G16/H11): la reversa lleva el motivo del gasto
      -- borrado (mismo criterio que el alta y que el backfill de la seccion 3).
      v_open_session_id, -v_cash_amount, 'expense_reversal', p_expense_id,
      v_expense.description
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled ───────────
  -- Loop calcado del de rpc_delete_sale_operation. Se usa _register_bank_movement
  -- (el escritor crudo) y NO _pay_register_operation_bank_movement: la reversa
  -- no tiene que volver a resolver la cuenta ni volver a evaluar el guard de
  -- período conciliado — va contra la MISMA cuenta del movimiento original.
  -- Es el único uso autorizado del escritor crudo en este change (D2).
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'expense' AND source_doc_ref = p_expense_id
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'expense', p_expense_id, CURRENT_DATE, v_bank_row.branch_id,
      -- qa-integral-modulos (G16/H11): el espejo nombra al gasto borrado.
      -- El marcador 'Reversión por borrado de gasto' se CONSERVA: el gate
      -- test_gastos_forma_pago (5.5/5.7) lo exige como ancla del contrato.
      'Reversión por borrado de gasto' || COALESCE(': ' || v_expense.description, '')
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  -- ── asiento-contable-gastos (D7): ExpenseDeleted, SÓLO si existe el alta,
  -- ANTES del borrado físico ─────────────────────────────────────────────────
  -- El account_id ya no se podría leer de public.expenses después del DELETE
  -- de más abajo, así que el evento se emite ANTES. Carga mínima: cuenta +
  -- id del gasto — es todo lo que el consumidor necesita para localizar el
  -- asiento vigente por su source_doc_ref y revertirlo (la lookup NO lee
  -- public.expenses).
  IF EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'ExpenseCreated' AND aggregate_type = 'Expense' AND aggregate_id = p_expense_id AND account_id = v_account_id
  ) THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload)
    VALUES (
      v_account_id, 'ExpenseDeleted', 'Expense', p_expense_id,
      jsonb_build_object('account_id', v_account_id, 'expense_id', p_expense_id)
    );
  END IF;

  -- ── El borrado, DESPUÉS de las dos compensaciones y del evento contable ──
  DELETE FROM public.expenses WHERE id = p_expense_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'deleted',           true,
    'cash_reversal_id',  v_cash_reversal_id,
    'bank_reversals',    v_bank_reversals
  );
END;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6) rpc_process_outbox_dispatch — filtro del Consumer 3, 11→14, idéntico al
--    del helper (D8). Firma intacta (p_batch_limit integer DEFAULT 100).
-- ─────────────────────────────────────────────────────────────────────────────
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
       PaymentMadeReversed/ExpenseCreated/ExpenseAdjusted/ExpenseDeleted)
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

  asiento-contable-gastos (2026-09-10, D8): agrega ExpenseCreated,
  ExpenseAdjusted y ExpenseDeleted (11→14) — mismo invariante; el gate de
  test_cobranzas_reverso.sql bloque (11) pasa a esperar los 14 tipos y se
  cablea a KPI_Validation.yml en este mismo PR (nunca había corrido en CI).
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
      -- Solo para los 14 tipos en-scope; _journal_post_from_event hace no-op
      -- para el resto. La idempotencia (event_id, 'JournalEntry') se gestiona
      -- dentro del helper. Un fallo en el posting (balance, NC sin original,
      -- reverso sin original) deja el evento pending para retry — el
      -- EXCEPTION del sub-bloque lo captura sin abortar el batch.
      IF v_event.event_type IN (
          'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
          'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
          'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted',
          'PaymentReceivedReversed', 'PaymentMadeReversed',
          'ExpenseCreated', 'ExpenseAdjusted', 'ExpenseDeleted'
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


-- ─────────────────────────────────────────────────────────────────────────────
-- 7) Índices (revisor, ronda 1, nit): los dos EXISTS correlacionados que este
--    change agrega (D7 en rpc_update_expense/rpc_delete_expense, y el lookup
--    del "asiento vigente" en ExpenseAdjusted/ExpenseDeleted) recorren
--    public.events y public.journal_entries sin índice por la columna que
--    buscan. Costo hoy despreciable (883 filas / 623 filas en prod al
--    2026-09-10), pero ambas tablas crecen sin política de retención — se
--    crean de una vez, en la misma migración, porque es barato. El primero
--    además sirve al lookup del consumidor y al filtro `source_doc_ref` del
--    libro diario (/reportes/libro-diario).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_journal_entries_source_doc
    ON public.journal_entries (source_doc_type, source_doc_ref);

CREATE INDEX IF NOT EXISTS idx_events_aggregate
    ON public.events (aggregate_type, aggregate_id);
