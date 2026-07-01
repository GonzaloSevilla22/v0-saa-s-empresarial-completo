-- =============================================================================
-- MIGRATION: 20260804000006_fix_audit_logs_notnull.sql
-- CHANGE:    Hotfix de producción — el consumer del outbox SIGUE crasheando tras #247
--            (5º/último blocker: audit_logs.company_id + entity_type NOT NULL)
--
-- SÍNTOMA (verificado read-only en prod gxdhpxvdjjkmxhdkkwyb, 2026-07-01):
--   events: 0 procesados / 6 pending (el más viejo del 2026-06-22).
--   journal_entries: 0 filas (max posted_at = NULL).
--   → La contabilidad de partida doble (journal-entry-outbox, V2.5 #2) NUNCA posteó
--     en producción. El relay (pg_cron activo, cada minuto) falla en el PRIMER
--     consumer de CADA evento y hace ROLLBACK del evento entero.
--
-- CAUSA RAÍZ:
--   Consumer 1 (AuditLog) de rpc_process_outbox_dispatch inserta:
--     INSERT INTO public.audit_logs (account_id, action, created_at) VALUES (...);
--   Pero public.audit_logs tiene DOS columnas legacy NOT NULL sin default que el
--   INSERT NO provee:
--     - company_id  (NOT NULL, sin default)   ← dispara primero (23502)
--     - entity_type (NOT NULL, sin default)   ← 2º, quedaría oculto tras el 1º
--   Son columnas del esquema pre-V2; en el modelo V2 el tenant es `account_id`
--   (migración companies→accounts). El consumer ya escribe `account_id` (nullable).
--
--   Esto es el MISMO patrón de drift que ya se corrigió sobre la tabla `events`
--   (C-29 hotfix #194: DROP NOT NULL guardado sobre events.company_id/entity_type).
--   #247 (20260804000005) arregló los 3 blockers de operation_idempotency; este
--   corrige el blocker que quedaba un paso más abajo (el INSERT real a audit_logs).
--
-- FIX (mínimo, drift-tolerant, SIN tocar rpc_process_outbox_dispatch ni
--      _journal_post_from_event — se preservan byte-a-byte, mismo criterio que #247):
--   DROP NOT NULL en audit_logs.company_id y audit_logs.entity_type, guardado por
--   existencia + estado actual (no-op donde ya sean nullable o no existan).
--
-- ALTERNATIVA considerada (NO elegida): que el consumer PROVEA company_id/entity_type.
--   Requeriría CREATE OR REPLACE de la función ~consumer de partida doble solo para
--   inventar valores a columnas legacy (company_id no tiene equivalente directo del
--   evento) → riesgo sobre la lógica contable > beneficio. Se sigue el precedente de
--   `events`: relajar el NOT NULL legacy.
--
-- REPLAY del backlog: AUTOMÁTICO. El pg_cron `relay-process-outbox` (activo) toma
--   en el próximo tick los 6 eventos pending: AuditLog inserta OK → Consumer 3
--   (JournalEntry) postea los asientos de los eventos contables (SaleConfirmed/
--   PurchaseCreated/PaymentReceived/PaymentMade/CreditNoteIssued) → processed_at set.
--
-- GOVERNANCE: CRÍTICO (audit_logs + contabilidad). Aprobado explícitamente por el PO
--   antes de escribir. El cambio RESTAURA el logging de auditoría (hoy 100% roto vía
--   outbox), no lo debilita: las filas de auditoría generadas por el relay quedan con
--   company_id/entity_type NULL (identificadas por account_id), igual criterio que
--   el drift ya aceptado en `events`.
--
-- APPLY: npx supabase db push (CI al mergear). NUNCA MCP apply_migration.
-- ROLLBACK: reponer NOT NULL NO es seguro (volvería a romper el relay) — no se revierte.
--   Si se necesitara, exigiría backfill de company_id/entity_type en todas las filas.
-- =============================================================================

-- ── FIX: DROP NOT NULL guardado (drift-tolerant) ─────────────────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'audit_logs'
      AND column_name = 'company_id' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.audit_logs ALTER COLUMN company_id DROP NOT NULL;
    RAISE NOTICE 'audit_logs.company_id: DROP NOT NULL aplicado';
  ELSE
    RAISE NOTICE 'audit_logs.company_id: ya nullable o inexistente — no-op';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'audit_logs'
      AND column_name = 'entity_type' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.audit_logs ALTER COLUMN entity_type DROP NOT NULL;
    RAISE NOTICE 'audit_logs.entity_type: DROP NOT NULL aplicado';
  ELSE
    RAISE NOTICE 'audit_logs.entity_type: ya nullable o inexistente — no-op';
  END IF;
END $$;

-- ── GATE (introspección, sin datos — corre en CI y prod) ─────────────────────
-- Asegura que ninguna de las dos columnas quede NOT NULL (bloqueo del relay).
DO $$
DECLARE
  v_still_notnull int;
BEGIN
  SELECT count(*) INTO v_still_notnull
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'audit_logs'
    AND column_name IN ('company_id', 'entity_type')
    AND is_nullable = 'NO';

  IF v_still_notnull <> 0 THEN
    RAISE EXCEPTION
      'hotfix FAILED: % columna(s) audit_logs.company_id/entity_type siguen NOT NULL — el relay del outbox seguiría crasheando',
      v_still_notnull;
  END IF;

  RAISE NOTICE 'audit_logs: company_id + entity_type nullables — Consumer 1 (AuditLog) del outbox puede insertar; el relay drena el backlog.';
END $$;
