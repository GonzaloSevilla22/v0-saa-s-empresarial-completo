-- =============================================================================
-- MIGRATION: 20260804000005_fix_outbox_idempotency_operation_id_nullable.sql
-- CHANGE:    Hotfix de producción — el consumer del outbox crashea en cada evento
--
-- SÍNTOMA (recurrente cada ~minuto vía pg_cron, en los logs de Postgres):
--   WARNING: rpc_process_outbox_dispatch: fallo en evento <uuid> (type=<...>):
--   null value in column "operation_id" of relation "operation_idempotency"
--   violates not-null constraint
--
-- EFECTO: rpc_process_outbox_dispatch falla en el PRIMER consumer (AuditLog) de
--   CADA evento → processed_at queda NULL → el evento se reintenta para siempre y
--   ningún consumer corre. En particular, el Consumer 3 (JournalEntry,
--   _journal_post_from_event) nunca postea: la partida doble está parada en prod.
--   No bloquea ventas/compras (esas solo INSERTan en events); es el relay async.
--
-- CAUSA RAÍZ: C-25 (20260718000001_c25_events_outbox_reconcile.sql) agregó la forma
--   de idempotencia por consumer sobre operation_idempotency:
--     · columnas event_id + consumer_type (nullable)
--     · índice único parcial (event_id, consumer_type) WHERE event_id IS NOT NULL
--   y los consumers reclaman el slot con:
--     INSERT INTO operation_idempotency
--       (user_id, idempotency_key, operation_kind, event_id, consumer_type)
--     VALUES ('000…0', event_id||':Consumer', 'event_consumer', event_id, 'Consumer')
--     ON CONFLICT (event_id, consumer_type) WHERE event_id IS NOT NULL DO NOTHING;
--   Las filas de event-consumer NO tienen operación → NO proveen operation_id.
--   PERO C-25 nunca dropeó el NOT NULL de operation_id → el INSERT viola la
--   constraint en cada evento.
--
--   La intención de C-25 era operation_id nullable para estas filas: ya existe el
--   índice PARCIAL idx_operation_idempotency_operation (user_id, operation_id)
--   WHERE operation_id IS NOT NULL — que solo tiene sentido si operation_id puede
--   ser NULL. El DROP NOT NULL simplemente faltó.
--
-- FIX (mínimo, alineado a la intención de C-25):
--   ALTER TABLE public.operation_idempotency ALTER COLUMN operation_id DROP NOT NULL;
--
-- SEGURIDAD del cambio:
--   · Los flujos de operación (sale/purchase/payment) SIEMPRE proveen operation_id
--     (gen_random_uuid()) → siguen insertando NOT NULL; el DROP no los afecta.
--   · La única clase de filas con operation_id NULL serán las de event-consumer
--     (operation_kind='event_consumer'), dedupadas por (event_id, consumer_type) y
--     también por (user_id, operation_kind, idempotency_key) — sin colisión.
--   · Doble posteo al journal evitado por dos garantías (design D6):
--     el slot (event_id,'JournalEntry') + el índice único parcial
--     journal_entries(source_event_id) WHERE source_event_id IS NOT NULL.
--
-- REPLAY del backlog: AUTOMÁTICO. Al aplicar este fix, el cron rpc_process_outbox_dispatch
--   tomará en el próximo tick los eventos pending (processed_at IS NULL) y posteará sus
--   asientos. Backlog al momento del diagnóstico: 3 eventos (2 SaleConfirmed + 1
--   PurchaseCreated). DECISIÓN DEL PO requerida antes de mergear (toca journal contable).
--
-- GOVERNANCE: ALTA (journal/contabilidad + idempotencia). Migración propuesta para
--   review; el merge dispara el replay automático del backlog al journal.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — desincroniza el history)
-- ROLLBACK:
--   -- Solo si NO se insertaron filas de event-consumer con operation_id NULL:
--   ALTER TABLE public.operation_idempotency ALTER COLUMN operation_id SET NOT NULL;
--   (Tras el primer tick del cron habrá filas con operation_id NULL → el SET NOT NULL
--    fallaría; en ese caso el rollback exige limpiar esas filas primero.)
-- =============================================================================

ALTER TABLE public.operation_idempotency
  ALTER COLUMN operation_id DROP NOT NULL;

COMMENT ON COLUMN public.operation_idempotency.operation_id IS
  'UUID de la operación para idempotencia de mutaciones (sale/purchase/payment): provisto por '
  'las RPCs. NULLABLE desde 20260804000005: las filas de idempotencia de CONSUMERS del outbox '
  '(operation_kind=''event_consumer'', dedupadas por (event_id, consumer_type)) no tienen operación '
  'y dejan operation_id NULL. C-25 introdujo esas filas pero olvidó dropear el NOT NULL → '
  'rpc_process_outbox_dispatch crasheaba en cada evento.';


-- ============================================================
-- Gates SQL (TDD — RED→GREEN validados por este DO-block)
--   (a) Introspección (SIEMPRE, incl. prod): operation_id es NULLABLE.
--   (b) Comportamiento: el INSERT exacto de event-consumer (operation_id omitido)
--       ahora tiene éxito. Sentinel rollback — no deja la fila de prueba.
-- ============================================================
DO $gate$
DECLARE
  v_notnull boolean;
  v_test_event_id uuid := gen_random_uuid();
  v_gate_a boolean := false;
  v_gate_b boolean := false;
BEGIN
  -- ── (a) operation_id ya NO es NOT NULL ────────────────────────────────────
  SELECT a.attnotnull INTO v_notnull
  FROM pg_attribute a
  WHERE a.attrelid = 'public.operation_idempotency'::regclass
    AND a.attname  = 'operation_id'
    AND NOT a.attisdropped;

  IF v_notnull IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE (a) FAILED: operation_idempotency.operation_id sigue siendo NOT NULL (attnotnull=%)', v_notnull;
  END IF;
  v_gate_a := true;

  -- ── (b) el claim de consumer (sin operation_id) ahora inserta OK ──────────
  -- Réplica exacta del INSERT de rpc_process_outbox_dispatch / _journal_post_from_event.
  BEGIN
    INSERT INTO public.operation_idempotency
      (user_id, idempotency_key, operation_kind, event_id, consumer_type)
    VALUES (
      '00000000-0000-0000-0000-000000000000'::uuid,
      v_test_event_id::text || ':JournalEntry',
      'event_consumer',
      v_test_event_id,
      'JournalEntry'
    );
    v_gate_b := true;
    -- revertir la fila de prueba
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
  END;

  RAISE NOTICE '=== fix-outbox-idempotency-operation-id-nullable gates ===';
  RAISE NOTICE '(a) operation_id nullable:                         %', v_gate_a;
  RAISE NOTICE '(b) INSERT de event-consumer (sin operation_id) OK: %', v_gate_b;
END
$gate$;
