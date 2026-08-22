-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-22, vía
-- pg_get_functiondef(oid) — task 1.1 de delete-guard-ledgers (extendida: no
-- estaba en la lista original de 7 funciones, pero el propio comentario de
-- esta función documenta el invariante "el filtro del dispatcher y el de
-- _journal_post_from_event deben listar el mismo conjunto" — SaleOperationDeleted
-- y PurchaseDeleted deben sumarse a AMBOS filtros o el evento nunca despacha).
-- MAX(version) al momento de la captura: 20261004000002.

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
       SaleOperationAdjusted/PaymentReceived/PaymentMade/CreditNoteIssued)
    4. Notification (CashSessionClosed/StockBelowMinimum/FiscalDocumentRejected/
       QuoteAccepted/TransferDispatched) — v3-notifications-realtime.

  processed_at se escribe SOLO si todos los consumers activos del evento tienen
  éxito. Un consumer fallido deja processed_at NULL → retry en el próximo tick.
  Cada consumer está idempotency-guarded por (event_id, consumer_type).

  Per-event isolation: BEGIN/EXCEPTION/END por evento.
  SECURITY DEFINER: cross-account sin debilitar RLS. REVOCADO de anon/PUBLIC.

  asiento-venta-formulario (2026-08-20): agrega SaleOperationCreated y
  SaleOperationAdjusted al filtro del Consumer 3 — el filtro del dispatcher
  y el de _journal_post_from_event deben listar el mismo conjunto (mismo
  invariante que journal-entry-outbox ya documenta).
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
      -- Solo para los 7 tipos en-scope; _journal_post_from_event hace no-op para el resto.
      -- La idempotencia (event_id, 'JournalEntry') se gestiona dentro del helper.
      -- Un fallo en el posting (balance, NC sin original) deja el evento pending
      -- para retry — el EXCEPTION del sub-bloque lo captura sin abortar el batch.
      IF v_event.event_type IN (
          'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
          'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
          'CreditNoteIssued'
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
$function$
