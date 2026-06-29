-- =============================================================================
-- MIGRATION: 20260804000005_fix_outbox_consumer_idempotency.sql
-- CHANGE:    Hotfix de producción — el consumer del outbox crashea en cada evento
--
-- SÍNTOMA (recurrente cada ~minuto vía pg_cron, en los logs de Postgres):
--   WARNING: rpc_process_outbox_dispatch: fallo en evento <uuid> (type=<...>):
--   null value in column "operation_id" of relation "operation_idempotency"
--   violates not-null constraint
--
-- EFECTO: rpc_process_outbox_dispatch falla en el PRIMER consumer (AuditLog) de
--   CADA evento → processed_at queda NULL → retry infinito y ningún consumer corre.
--   El Consumer 3 (JournalEntry / _journal_post_from_event) nunca postea: la
--   partida doble está parada en prod. No bloquea ventas/compras (esas solo
--   INSERTan en events); es el relay async.
--
-- CAUSA RAÍZ: C-25 (20260718000001) introdujo la idempotencia por consumer sobre
--   operation_idempotency. Los consumers reclaman un "slot marcador" así:
--     INSERT INTO operation_idempotency
--       (user_id, idempotency_key, operation_kind, event_id, consumer_type)
--     VALUES ('00000000-0000-0000-0000-000000000000'::uuid,
--             event_id||':Consumer', 'event_consumer', event_id, 'Consumer')
--     ON CONFLICT (event_id, consumer_type) WHERE event_id IS NOT NULL DO NOTHING;
--   Esa fila marcador choca con TRES constraints de la tabla (diseñada para la
--   idempotencia de operaciones de usuario, NO para marcadores de consumer):
--     (1) operation_id NOT NULL   → el INSERT lo omite        (dispara primero en prod)
--     (2) operation_kind_check    → no incluye 'event_consumer' (23514; lo cazó el gate de CI)
--     (3) user_id_fkey → auth.users(id) → el sentinel '000…0' no existe (FK violation)
--   Las tres deben corregirse para que el relay funcione. (1) enmascaraba (2) y (3).
--
-- FIX (mínimo, SIN tocar las funciones consumer — se preservan byte-a-byte para no
--      arriesgar la lógica de posteo contable de _journal_post_from_event):
--   (1) operation_id  → DROP NOT NULL (los marcadores no tienen operación).
--   (2) operation_kind_check → agregar 'event_consumer'.
--   (3) user_id_fkey  → DROP. Los marcadores usan un sentinel que no es un usuario
--       real; el FK (cleanup ON DELETE CASCADE) no aplica a ellos. Las filas reales
--       de operación siguen llevando un user_id válido (auth.uid()); solo se pierde
--       la garantía referencial DB-enforced sobre esa columna en una tabla que es un
--       LOG de idempotencia transitorio (orfandad inocua si se borra un usuario).
--
-- ALTERNATIVA considerada (NO elegida): mantener el FK y cambiar los marcadores a
--   user_id NULL exigiría CREATE OR REPLACE de rpc_process_outbox_dispatch y del
--   ~200-líneas _journal_post_from_event solo para cambiar un literal — riesgo de
--   transcripción sobre lógica de partida doble > beneficio de conservar el FK.
--
-- REPLAY del backlog: AUTOMÁTICO. Al aplicar, el cron toma en el próximo tick los
--   eventos pending (processed_at IS NULL) y postea sus asientos. Backlog al
--   diagnóstico: 3 eventos (2 SaleConfirmed + 1 PurchaseCreated). Posteo correcto e
--   idempotente (índice único parcial journal_entries(source_event_id), design D6).
--   OK del PO obtenido (toca el journal contable).
--
-- GOVERNANCE: ALTA (journal/contabilidad + idempotencia). Migración para review.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — desincroniza el history)
-- ROLLBACK:
--   ALTER TABLE public.operation_idempotency
--     ADD CONSTRAINT operation_idempotency_user_id_fkey
--     FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;  -- (orfanes romperían el re-add)
--   ALTER TABLE public.operation_idempotency
--     DROP CONSTRAINT operation_idempotency_operation_kind_check,
--     ADD  CONSTRAINT operation_idempotency_operation_kind_check
--       CHECK (operation_kind = ANY (ARRAY['sale','purchase','payment_received',
--              'payment_made','supplier_charge','bank_movement']));
--   ALTER TABLE public.operation_idempotency ALTER COLUMN operation_id SET NOT NULL; -- (filas NULL lo romperían)
-- =============================================================================

-- ── (1) operation_id nullable — los marcadores de consumer no tienen operación ──
ALTER TABLE public.operation_idempotency
  ALTER COLUMN operation_id DROP NOT NULL;

-- ── (2) operation_kind acepta 'event_consumer' (mismo patrón que bank_movement) ──
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
    'event_consumer'   -- C-25 outbox: marcadores de idempotencia por (event_id, consumer_type)
  ]));

-- ── (3) drop del FK user_id → auth.users (incompatible con el sentinel '000…0') ──
ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_user_id_fkey;

COMMENT ON COLUMN public.operation_idempotency.operation_id IS
  'UUID de la operación (sale/purchase/payment) para idempotencia de mutaciones; provisto por '
  'las RPCs. NULLABLE desde 20260804000005: los marcadores de CONSUMERS del outbox '
  '(operation_kind=''event_consumer'', dedupados por (event_id, consumer_type)) no tienen operación.';

COMMENT ON COLUMN public.operation_idempotency.user_id IS
  'Usuario de la operación (auth.uid()) para las filas de mutación. Desde 20260804000005 SIN FK a '
  'auth.users: los marcadores de consumer del outbox usan el sentinel 00000000-…-000000000000 '
  '(no es un usuario real). Las filas de operación siguen llevando un user_id válido por convención.';


-- ============================================================
-- Gates SQL (TDD — RED→GREEN validados por este DO-block)
--   (a) operation_id es NULLABLE.
--   (b) NO existe el FK operation_idempotency_user_id_fkey.
--   (c) el CHECK acepta 'event_consumer'.
--   (d) Comportamiento: el INSERT EXACTO del consumer (sentinel '000…0',
--       operation_kind='event_consumer', operation_id omitido) ahora tiene éxito.
--       Sentinel rollback — no deja la fila de prueba.
-- ============================================================
DO $gate$
DECLARE
  v_notnull       boolean;
  v_fk_count      int;
  v_test_event_id uuid := gen_random_uuid();
  v_gate_a boolean := false;
  v_gate_b boolean := false;
  v_gate_c boolean := false;
  v_gate_d boolean := false;
BEGIN
  -- (a) operation_id ya NO es NOT NULL
  SELECT a.attnotnull INTO v_notnull
  FROM pg_attribute a
  WHERE a.attrelid = 'public.operation_idempotency'::regclass
    AND a.attname  = 'operation_id' AND NOT a.attisdropped;
  IF v_notnull IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE (a) FAILED: operation_id sigue NOT NULL (attnotnull=%)', v_notnull;
  END IF;
  v_gate_a := true;

  -- (b) el FK user_id → auth.users fue dropeado
  SELECT count(*) INTO v_fk_count
  FROM pg_constraint
  WHERE conrelid = 'public.operation_idempotency'::regclass
    AND contype = 'f' AND conname = 'operation_idempotency_user_id_fkey';
  IF v_fk_count <> 0 THEN
    RAISE EXCEPTION 'GATE (b) FAILED: el FK operation_idempotency_user_id_fkey sigue existiendo';
  END IF;
  v_gate_b := true;

  -- (c) el CHECK acepta 'event_consumer' (introspección del def)
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.operation_idempotency'::regclass
      AND conname = 'operation_idempotency_operation_kind_check'
      AND pg_get_constraintdef(oid) LIKE '%event_consumer%'
  ) INTO v_gate_c;
  IF NOT v_gate_c THEN
    RAISE EXCEPTION 'GATE (c) FAILED: operation_kind_check no acepta ''event_consumer''';
  END IF;

  -- (d) el INSERT EXACTO del consumer (réplica de rpc_process_outbox_dispatch /
  --     _journal_post_from_event) ahora tiene éxito. Sentinel rollback.
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
    v_gate_d := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
  END;

  RAISE NOTICE '=== fix-outbox-consumer-idempotency gates ===';
  RAISE NOTICE '(a) operation_id nullable:              %', v_gate_a;
  RAISE NOTICE '(b) FK user_id dropeado:                %', v_gate_b;
  RAISE NOTICE '(c) CHECK acepta event_consumer:        %', v_gate_c;
  RAISE NOTICE '(d) INSERT marcador de consumer OK:     %', v_gate_d;
END
$gate$;
