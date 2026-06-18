-- =============================================================================
-- MIGRATION: 20260718000001_c25_events_outbox_reconcile.sql
-- C-25 v20-outbox-activation: Reconciliación del drift del outbox + activación
--
-- CONTEXT (ver hotfix 20260702000002 para el drift completo):
--   * CI: events = (id, company_id NULLABLE, title, created_at) — stub
--   * PROD: events = tenía company_id/entity_type NOT NULL (legacy); el hotfix C-29
--     ya los hizo nullable. La migración C-29 (20260702000001) hizo ADD COLUMN IF NOT
--     EXISTS sobre los V2 columns.
--   Esta migración FORMALIZA en el historial de migraciones el schema canónico del
--   outbox V2 y agrega el plumbing del relay (RPC SECURITY DEFINER + pg_cron).
--
-- IDEMPOTENCIA: todas las operaciones usan IF NOT EXISTS / DO $$ ... IF EXISTS.
--   Re-aplicar esta migración es un no-op.
-- NO DESTRUCTIVE: NO hay DROP COLUMN (Decision 2 del design.md).
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.1  Re-assert canonical V2 columns on public.events
--      ADD COLUMN IF NOT EXISTS → seguro en CI (no existen aún) y en PROD
--      (C-29 ya los agregó → IF NOT EXISTS es no-op).
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS account_id      uuid,
  ADD COLUMN IF NOT EXISTS event_type      text,
  ADD COLUMN IF NOT EXISTS aggregate_type  text,
  ADD COLUMN IF NOT EXISTS aggregate_id    uuid,
  ADD COLUMN IF NOT EXISTS payload         jsonb,
  ADD COLUMN IF NOT EXISTS occurred_at     timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS processed_at    timestamptz;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.2  Guard legacy columns: DROP NOT NULL only where they exist AND are NOT NULL
--      Idempotente — en CI (company_id ya nullable, entity_type no existe) es no-op.
--      En PROD original (company_id NOT NULL, entity_type NOT NULL) afloja ambas.
--      El hotfix C-29 (20260702000002) ya las aflojó en PROD; aquí es no-op.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- company_id
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'events'
      AND column_name = 'company_id' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.events ALTER COLUMN company_id DROP NOT NULL;
  END IF;

  -- entity_type
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'events'
      AND column_name = 'entity_type' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.events ALTER COLUMN entity_type DROP NOT NULL;
  END IF;

  -- title
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'events'
      AND column_name = 'title' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.events ALTER COLUMN title DROP NOT NULL;
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.3  Partial index for relay query: only pending events (processed_at IS NULL)
--      Keeps relay scan O(pending) regardless of processed volume.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS events_unprocessed_idx
  ON public.events (occurred_at)
  WHERE processed_at IS NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.4  Reconcile public.audit_logs for the AuditLog consumer:
--      ADD account_id (forward-fill only; no historical backfill — audit is
--      append-only and the outbox starts empty).
--      Keep legacy company_id nullable.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.audit_logs
  ADD COLUMN IF NOT EXISTS account_id uuid;

CREATE INDEX IF NOT EXISTS idx_audit_logs_account_id_created_at
  ON public.audit_logs (account_id, created_at);

COMMENT ON TABLE public.audit_logs IS
  'C-25: Registro append-only de eventos de negocio. NUNCA UPDATE/DELETE. '
  'account_id reconciliado para el consumer AuditLog del outbox (forward-fill '
  'from 2026-07-18; sin backfill histórico — audit es append-only). '
  'company_id legacy permanece nullable.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.5  Consumer-idempotency shape on public.operation_idempotency
--      Adds event_id + consumer_type columns and a partial unique index keyed by
--      (event_id, consumer_type). Does NOT break the existing
--      UNIQUE (user_id, idempotency_key) constraint.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.operation_idempotency
  ADD COLUMN IF NOT EXISTS event_id       uuid,
  ADD COLUMN IF NOT EXISTS consumer_type  text;

CREATE UNIQUE INDEX IF NOT EXISTS operation_idempotency_event_consumer_uq
  ON public.operation_idempotency (event_id, consumer_type)
  WHERE event_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.6  COMMENT on public.events documenting the canonical outbox contract
-- ─────────────────────────────────────────────────────────────────────────────
COMMENT ON TABLE public.events IS
  'C-25 (DEC-20): Transactional Outbox canónico V2. '
  'Columnas canónicas: account_id, event_type, aggregate_type, aggregate_id, '
  'payload jsonb, occurred_at timestamptz, processed_at timestamptz. '
  'processed_at IS NULL = pendiente (relay pendiente). '
  'processed_at IS NOT NULL = procesado (audit+email commitados). '
  'Columnas legacy (company_id, entity_type, title) = nullable inert; '
  'NO se eliminan (Decision 2, design.md) para evitar romper PROD. '
  'El relay usa FOR UPDATE SKIP LOCKED sobre el índice parcial events_unprocessed_idx. '
  'Producers escriben en la MISMA transacción que la mutación (DEC-20). '
  'SaleConfirmed ya existe (C-29, migration 20260702000001 ~L574).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.2  rpc_process_outbox_batch — relay SECURITY DEFINER
--      Selecciona eventos pending FOR UPDATE SKIP LOCKED, retorna el batch.
--      La lógica de dispatch (routing + consumer handlers) vive en el backend
--      Python (POST /outbox/process-pending), consistente con el patrón C-27.
--      REVOKE de anon/PUBLIC; GRANT solo a authenticated.
--
--      SECURITY DEFINER rationale (Decision 4, design.md):
--        El relay debe leer TODOS los eventos pending (cross-account) y UPDATE
--        processed_at — lo que RLS de usuario normal bloquea correctamente.
--        En vez de debilitar RLS para authenticated, se usa SECURITY DEFINER
--        estrecho: solo este RPC, revocado de anon/PUBLIC, con rationale
--        documentado. Sin service_role en código de app (hard rule).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_process_outbox_batch(
  p_batch_limit int DEFAULT 100
)
RETURNS SETOF public.events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  C-25 relay: selecciona los p_batch_limit eventos más antiguos aún no procesados,
  los lockea (SKIP LOCKED para concurrent-safe), y los retorna para que el backend
  Python haga el dispatch + marque processed_at.

  SECURITY DEFINER necesario para que el relay (corrido bajo el pg_cron role)
  pueda leer y UPDATE eventos de CUALQUIER account_id sin debilitar la RLS
  normal de usuarios (que está SELECT-only y scoped por account_id).

  El backend llama a esta función via JWT-passthrough + luego UPDATE processed_at
  row-by-row dentro de sus propias llamadas a rpc_mark_event_processed.
*/
BEGIN
  RETURN QUERY
  SELECT *
  FROM public.events
  WHERE processed_at IS NULL
  ORDER BY occurred_at
  LIMIT p_batch_limit
  FOR UPDATE SKIP LOCKED;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_process_outbox_batch(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_process_outbox_batch(int) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_process_outbox_batch(int) TO authenticated;

COMMENT ON FUNCTION public.rpc_process_outbox_batch IS
  'C-25 (D4): relay del outbox — selecciona hasta p_batch_limit eventos pending '
  '(processed_at IS NULL) ORDER BY occurred_at, FOR UPDATE SKIP LOCKED. '
  'SECURITY DEFINER para leer cross-account sin debilitar RLS usuario. '
  'REVOCADO de anon/PUBLIC. El backend Python hace el dispatch y marca '
  'processed_at via rpc_mark_event_processed.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2.2b rpc_mark_event_processed — actualiza processed_at tras dispatch exitoso
--      También SECURITY DEFINER: el backend no tiene UPDATE policy sobre events.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_mark_event_processed(
  p_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE public.events
  SET processed_at = now()
  WHERE id = p_event_id;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_mark_event_processed(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_mark_event_processed(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_mark_event_processed(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_mark_event_processed IS
  'C-25: marca un evento del outbox como procesado (processed_at = now()). '
  'Solo se llama tras el commit exitoso de TODOS los consumers (AuditLog + Email). '
  'SECURITY DEFINER — el backend JWT-passthrough no tiene UPDATE policy en events.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2.3  rpc_process_outbox_dispatch — pure-SQL relay dispatch (Decision 1 pivot)
--
--      SECURITY DEFINER rationale (Decision 4, design.md):
--        El relay debe leer TODOS los eventos pending (cross-account) e INSERT
--        en audit_logs/email_logs/operation_idempotency — tablas sin INSERT
--        policy para `authenticated`. En vez de debilitar RLS se usa una función
--        SECURITY DEFINER estrecha, revocada de anon/PUBLIC y documentada.
--        Sin service_role en código de app (hard rule).
--
--      Pivot C-25 (Decision 1 actualizado):
--        El dispatch corre completamente en-DB vía pg_cron → esta función.
--        No hay dependencia de HTTP/pg_net/Render cold-start en el hot loop.
--        El endpoint Python (/outbox/process-pending + OutboxRelayService) se
--        mantiene como trigger manual/secundario — no se elimina.
--        NOTA: C-27 (CAE/AFIP) NO puede usar este patrón porque llama WSFE
--        sobre SOAP (side-effect externo) — su gap de trigger está fuera del
--        scope de C-25.
--
--      Consumer order (per-event):
--        1. AuditLog  (mandatory first — audit domain invariant)
--        2. EmailNotification (solo para sale_created/stock_adjusted/plan_changed)
--      processed_at se escribe SOLO si ambos consumers activos tienen éxito.
--      Un consumer fallido deja processed_at NULL → retry en el próximo tick.
--      Cada consumer está idempotency-guarded por (event_id, consumer_type).
--
--      Per-event isolation:
--        Cada evento tiene su propio sub-bloque BEGIN/EXCEPTION/END. Un evento
--        corrupto no aborta el batch entero — el loop continúa con el siguiente.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_process_outbox_dispatch(
  p_batch_limit int DEFAULT 100
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  C-25 pure-SQL relay dispatch (Decision 1 pivot, design.md).

  Selecciona hasta p_batch_limit eventos pending (processed_at IS NULL),
  los lockea con FOR UPDATE SKIP LOCKED (concurrent-safe; dos runs paralelos
  no se solapan), y los procesa in-DB sin depender del backend HTTP.

  SECURITY DEFINER: necesario para leer + INSERT cross-account sin debilitar
  la RLS normal de usuarios autenticados. Revocado de anon/PUBLIC; solo
  authenticated puede invocar via EXECUTE. Documentado en Decision 4.

  Retorna el número de eventos marcados processed_at en este run.
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
    -- Per-event isolation: un evento corrupto no aborta el batch.
    -- En EXCEPTION: leave processed_at NULL → retry en el próximo tick.
    BEGIN

      -- ── Consumer 1: AuditLog (mandatory first — audit domain invariant) ──────
      -- Claim idempotency slot (event_id, 'AuditLog').
      -- sentinel user_id '00000000-...' porque user_id es NOT NULL en la tabla;
      -- la clave real de unicidad es (event_id, consumer_type).
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
      -- v_audit_claimed = true si se insertó la fila (slot recién tomado);
      -- false si ya existía (idempotent skip — no se inserta un segundo audit row).

      IF v_audit_claimed THEN
        -- INSERT append-only en audit_logs (NUNCA UPDATE/DELETE — audit domain).
        -- Columnas según insert_audit_log() en outbox_repository.py.
        INSERT INTO public.audit_logs (account_id, action, created_at)
        VALUES (v_event.account_id, v_event.event_type, now());
      END IF;
      -- Si audit_claimed = false → slot ya existía → skip idempotente (OK, continúa).

      -- ── Consumer 2: EmailNotification (solo tipos en-scope) ──────────────────
      IF v_event.event_type IN ('sale_created', 'stock_adjusted', 'plan_changed') THEN

        -- Claim idempotency slot (event_id, 'EmailNotification').
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
          -- Mapeo de subject por event_type (espejo de _build_email_content en
          -- outbox_relay_service.py).
          v_subject := CASE v_event.event_type
            WHEN 'sale_created'    THEN 'Nueva venta registrada'
            WHEN 'stock_adjusted'  THEN 'Ajuste de stock realizado'
            WHEN 'plan_changed'    THEN 'Tu plan ha sido actualizado'
            ELSE 'Evento: ' || v_event.event_type
          END;

          -- Recipient: payload->>'email' si existe, sino 'account:'||account_id
          -- (espejo de _build_email_content: payload.get('email') or f'account:{account_id}').
          v_recipient := COALESCE(
            v_event.payload->>'email',
            'account:' || v_event.account_id::text
          );

          -- INSERT en email_logs (DEC-09 path: webhook → Edge Function → Resend).
          -- Columnas según insert_email_log() en outbox_repository.py.
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
        -- Si email_claimed = false → skip idempotente (OK, continúa).

      END IF;
      -- Fin bloque EmailNotification.

      -- ── Mark processed (solo si ambos consumers activos tuvieron éxito) ──────
      -- Llegar aquí sin EXCEPTION = todos los consumers del evento OK.
      UPDATE public.events
      SET processed_at = now()
      WHERE id = v_event.id;

      v_processed_count := v_processed_count + 1;

    EXCEPTION
      WHEN OTHERS THEN
        -- Evento corrupto o fallo de consumer: dejar processed_at NULL para retry.
        -- Los slots de idempotency ya insertados en este sub-bloque fueron
        -- revertidos por el SAVEPOINT implícito del sub-bloque BEGIN/EXCEPTION/END.
        RAISE WARNING
          'rpc_process_outbox_dispatch: fallo en evento % (type=%): %',
          v_event.id, v_event.event_type, SQLERRM;
        -- Continúa con el siguiente evento del batch.
    END;

  END LOOP;

  RETURN v_processed_count;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_process_outbox_dispatch(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_process_outbox_dispatch(int) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_process_outbox_dispatch(int) TO authenticated;

COMMENT ON FUNCTION public.rpc_process_outbox_dispatch IS
  'C-25 (D1 pivot, D4): dispatch in-DB del outbox transaccional. '
  'Selecciona hasta p_batch_limit eventos pending (FOR UPDATE SKIP LOCKED), '
  'ejecuta AuditLog (mandatory first) + EmailNotification (sale_created/ '
  'stock_adjusted/plan_changed), cada uno idempotency-guarded por '
  '(event_id, consumer_type) en operation_idempotency. processed_at se '
  'escribe SOLO tras éxito de todos los consumers activos. Per-event isolation '
  'via BEGIN/EXCEPTION/END: un evento corrupto no aborta el batch. '
  'SECURITY DEFINER para leer/escribir cross-account sin debilitar RLS. '
  'REVOCADO de anon/PUBLIC. El endpoint Python (/outbox/process-pending) '
  'se mantiene como trigger manual/secundario.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2.5  pg_cron job: relay-process-outbox (cada minuto)
--
--      Pivot C-25 (Decision 1 actualizado):
--        El dispatch ahora corre completamente en-DB vía rpc_process_outbox_dispatch.
--        No hay dependencia de HTTP/pg_net/Render cold-start en el hot loop.
--        El endpoint Python se mantiene como trigger manual/secundario.
--        NOTA: el trade-off de Render cold-start (Decision 1 original) ya no
--        aplica al hot loop — este cron es autónomo (pura SQL en Postgres).
-- ─────────────────────────────────────────────────────────────────────────────
SELECT cron.unschedule('relay-process-outbox')
FROM cron.job WHERE jobname = 'relay-process-outbox';

SELECT cron.schedule(
  'relay-process-outbox',
  '* * * * *',  -- cada minuto, espejo de relay-process-pending-cae (C-27)
  $$
    -- C-25 (D1 pivot): dispatch in-DB del outbox transaccional.
    -- AuditLog + EmailNotification corren íntegramente en Postgres (SECURITY DEFINER).
    -- Sin dependencia de HTTP/pg_net/Render cold-start en este hot loop.
    -- El endpoint Python (/outbox/process-pending) se mantiene como trigger
    -- manual/secundario para debugging y operaciones puntuales.
    SELECT public.rpc_process_outbox_dispatch(100);
  $$
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification notes (para revisar con supabase db advisors):
--   - events: RLS habilitado; SELECT policy por account_id (no modificada);
--     relay via SECURITY DEFINER RPC.
--   - audit_logs: RLS habilitado; solo SELECT para admin (no INSERT policy para
--     authenticated — el relay inserta via SECURITY DEFINER scope del RPC).
--   - operation_idempotency: UNIQUE (event_id, consumer_type) WHERE event_id IS NOT NULL
--     coexiste con UNIQUE (user_id, idempotency_key).
-- ─────────────────────────────────────────────────────────────────────────────
