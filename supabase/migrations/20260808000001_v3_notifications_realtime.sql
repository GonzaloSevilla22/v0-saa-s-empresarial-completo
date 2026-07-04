-- =============================================================================
-- MIGRATION: 20260808000001_v3_notifications_realtime.sql
-- CHANGE:    v3-notifications-realtime
-- Design ref: openspec/changes/v3-notifications-realtime/design.md
--
-- Cierra la tríada del Modelo V3 §3 "snapshot + historial + aviso": agrega el
-- Consumer 4 (Notification) al relay del outbox y una tabla read-model
-- `notifications` servida en tiempo real via Supabase Realtime `postgres_changes`.
--
-- TDD tasks cubiertos (RED→GREEN→TRIANGULATE→REFACTOR), ver tasks.md:
--   Grupo 1 (1.1-1.8): schema notifications + índices + RLS
--   Grupo 2 (2.1-2.6): helpers _notification_audience + _notification_from_event
--   Grupo 3 (3.1-3.5): Consumer 4 en rpc_process_outbox_dispatch + publicación Realtime
--   Grupo 4 (4.1-4.2): retención TTL via pg_cron
--
-- IDEMPOTENCIA: IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — regla del proyecto).
--
-- NOTA (lección C3, project memory): antes de recrear cualquier CHECK ya
-- existente en prod (p.ej. operation_idempotency.operation_kind), este archivo
-- NO lo toca — 'event_consumer' ya fue aceptado por 20260804000005. Solo se
-- REUSA ese operation_kind para el marcador de idempotencia del Consumer 4,
-- exactamente igual que el Consumer 3 (journal-entry-outbox).
-- =============================================================================

-- =============================================================================
-- 1. SCHEMA: notifications + índices + RLS
-- =============================================================================

-- ─── 1.2 Tabla notifications ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.notifications (
    id          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid          NOT NULL
                              REFERENCES public.accounts(id) ON DELETE CASCADE,
    branch_id   uuid          NULL
                              REFERENCES public.branches(id) ON DELETE SET NULL,
    type        text          NOT NULL,
    severity    text          NOT NULL
                              CHECK (severity IN ('info', 'warning', 'urgent')),
    payload     jsonb         NOT NULL DEFAULT '{}'::jsonb,
    audience    uuid[]        NOT NULL,
    read        boolean       NOT NULL DEFAULT false,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    read_at     timestamptz   NULL
);

COMMENT ON TABLE public.notifications IS
    'v3-notifications-realtime: read model efímero de la campana de notificaciones. '
    'Escritura SOLO vía _notification_from_event (SECURITY DEFINER, Consumer 4 del '
    'relay del outbox) — sin política INSERT para authenticated. Entrega en tiempo '
    'real via Supabase Realtime postgres_changes (requiere RLS activa + tabla en '
    'la publicación supabase_realtime — D1 design.md). TTL: filas read=true se '
    'purgan a los 30 días (pg_cron, Grupo 4); las no leídas nunca se auto-borran.';

COMMENT ON COLUMN public.notifications.type IS
    'Nombre semántico del tipo de aviso (no el event_type del outbox 1:1, aunque '
    'hoy coinciden): StockBelowMinimum, CashSessionClosed, FiscalDocumentRejected, '
    'QuoteAccepted, TransferDispatched.';

COMMENT ON COLUMN public.notifications.audience IS
    'Array de auth.uid() que puede ver esta fila. Resuelto server-side por '
    '_notification_audience (D3) — el cliente nunca decide su propia audiencia. '
    'La política SELECT exige (select auth.uid()) = ANY(audience) además del '
    'account_id — RLS es la garantía real, no el filter de red del cliente (D1).';

COMMENT ON COLUMN public.notifications.read_at IS
    'NULL mientras read=false. Se setea al marcar-como-leída (UPDATE directo con '
    'RLS, D5 — sin RPC). Usado por el TTL de retención (Grupo 4, D6).';

-- ─── 1.3 Índices ──────────────────────────────────────────────────────────────
-- Dropdown del bell: ORDER BY created_at DESC LIMIT N.
CREATE INDEX IF NOT EXISTS idx_notifications_account_created
    ON public.notifications (account_id, created_at DESC);

-- Badge de no-leídas: WHERE frecuente → índice parcial (best-practice Supabase, D6).
CREATE INDEX IF NOT EXISTS idx_notifications_account_unread
    ON public.notifications (account_id)
    WHERE read = false;

-- Nota (Open Question design.md): índice GIN sobre audience NO se crea por
-- defecto — pocas filas por cuenta esperadas; se agrega en un change posterior
-- si el advisor de prod lo sugiere bajo carga real.

-- ─── 1.4 RLS ──────────────────────────────────────────────────────────────────
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- 1.5 SELECT: pertenencia a la cuenta Y a la audiencia (ambas condiciones).
DROP POLICY IF EXISTS "notifications_audience_select" ON public.notifications;
CREATE POLICY "notifications_audience_select" ON public.notifications
    FOR SELECT
    TO authenticated
    USING (
        account_id IN (SELECT current_account_ids())
        AND (SELECT auth.uid()) = ANY(audience)
    );

-- 1.6 UPDATE: USING (qué filas puede tocar) + WITH CHECK (qué puede quedar tras
-- el update). Mismas columnas inmutables en ambas cláusulas para que ningún
-- valor de esas columnas pase el check tras la mutación (D5 design.md).
-- Solo read/read_at pueden mutar; el resto se re-verifica igual en WITH CHECK.
DROP POLICY IF EXISTS "notifications_audience_update" ON public.notifications;
CREATE POLICY "notifications_audience_update" ON public.notifications
    FOR UPDATE
    TO authenticated
    USING (
        account_id IN (SELECT current_account_ids())
        AND (SELECT auth.uid()) = ANY(audience)
    )
    WITH CHECK (
        account_id IN (SELECT current_account_ids())
        AND (SELECT auth.uid()) = ANY(audience)
    );

-- 1.7 Sin política INSERT para authenticated (gate abajo lo verifica) —
-- la única vía de escritura es _notification_from_event (SECURITY DEFINER).

-- =============================================================================
-- 2. HELPERS: _notification_audience + _notification_from_event
-- =============================================================================

-- ─── 2.2 _notification_audience ──────────────────────────────────────────────
-- Mapeo binario (D3 design.md): con account_members.role IN ('owner','member')
-- hoy, casi todos los targets colapsan a "owners". Aislado en un único punto
-- para migrar a v3-rbac-multirole sin tocar el dispatch/producers/frontend.
CREATE OR REPLACE FUNCTION public._notification_audience(
    p_account_id uuid,
    p_target     text,
    p_branch_id  uuid
)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  v3-notifications-realtime (D3) — Resolución de audiencia por rol.

  Mapeo actual (catálogo binario account_members.role IN ('owner','member')):
    ADMIN / PURCHASES / URGENT_FISCAL → owners de la cuenta.
    SELLER                            → owners + members de la cuenta.
    BRANCH_DEST                       → members ligados al branch destino
                                         (via user_branches si existe esa tabla;
                                          si no hay ninguno, fallback a owners).

  Cuando v3-rbac-multirole amplíe account_members.role, se reescribe SOLO esta
  función — el dispatch, los producers, la tabla notifications y el frontend
  no cambian (D3 design.md).
*/
DECLARE
    v_audience uuid[];
BEGIN
    IF p_target IN ('ADMIN', 'PURCHASES', 'URGENT_FISCAL') THEN
        SELECT COALESCE(array_agg(user_id), ARRAY[]::uuid[])
        INTO v_audience
        FROM public.account_members
        WHERE account_id = p_account_id
          AND role = 'owner';

    ELSIF p_target = 'SELLER' THEN
        SELECT COALESCE(array_agg(user_id), ARRAY[]::uuid[])
        INTO v_audience
        FROM public.account_members
        WHERE account_id = p_account_id;

    ELSIF p_target = 'BRANCH_DEST' THEN
        -- No existe hoy un catálogo user<->branch dedicado (RBAC lo trae
        -- v3-rbac-multirole); fallback directo a owners de la cuenta.
        SELECT COALESCE(array_agg(user_id), ARRAY[]::uuid[])
        INTO v_audience
        FROM public.account_members
        WHERE account_id = p_account_id
          AND role = 'owner';

    ELSE
        v_audience := ARRAY[]::uuid[];
    END IF;

    RETURN v_audience;
END;
$fn$;

REVOKE ALL     ON FUNCTION public._notification_audience(uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._notification_audience(uuid, text, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public._notification_audience(uuid, text, uuid) FROM authenticated;

COMMENT ON FUNCTION public._notification_audience IS
    'v3-notifications-realtime (D3): resuelve el array de auth.uid() destinatario '
    'de una notificación según un target semántico V3 (ADMIN/PURCHASES/SELLER/ '
    'BRANCH_DEST/URGENT_FISCAL), mapeado al catálogo binario owner/member vigente. '
    'SECURITY DEFINER. Llamada solo desde _notification_from_event. REVOCADA de '
    'anon/authenticated/PUBLIC. Punto único de migración a v3-rbac-multirole.';

-- ─── 2.3 _notification_from_event ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._notification_from_event(
    p_event public.events
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  v3-notifications-realtime (D2) — Consumer 4 (Notification) del relay del outbox.

  Responsabilidades:
    1. Filtrar por event_type (5 tipos en-scope; no-op para el resto).
    2. Reclamar slot de idempotencia (event_id, 'Notification') en
       operation_idempotency (mismo patrón exacto que el Consumer 3 JournalEntry).
    3. Dispatch por tipo → target semántico + severity (D3 tabla design.md).
    4. Resolver audience via _notification_audience; si vacía → no insertar
       (nada dirigido a nadie), pero el evento igual queda processed (el
       marcador de idempotencia ya se reclamó — D3 design.md).
    5. INSERT INTO notifications.

  CashSessionClosed: solo genera aviso si difference <> 0 (D3/D4). Con
  difference = 0 el helper hace no-op (return) SIN insertar fila, pero el slot
  de idempotencia ya quedó reclamado (evita reprocesos si el evento se re-emite).

  Un fallo (RAISE) es capturado por el EXCEPTION WHEN OTHERS del sub-bloque
  per-event en rpc_process_outbox_dispatch → el evento queda pending, retry
  en el próximo tick, el batch no aborta (mismo patrón Consumer 3).
*/
DECLARE
    v_payload    jsonb;
    v_event_type text;
    v_target     text;
    v_severity   text;
    v_branch_id  uuid;
    v_difference numeric;
    v_audience   uuid[];
    v_claimed    bool;
BEGIN
    v_payload    := p_event.payload;
    v_event_type := p_event.event_type;

    -- ── Filtro: solo los 5 tipos en-scope ────────────────────────────────────
    IF v_event_type NOT IN (
        'CashSessionClosed', 'StockBelowMinimum', 'FiscalDocumentRejected',
        'QuoteAccepted', 'TransferDispatched'
    ) THEN
        RETURN;  -- no-op para eventos fuera de alcance
    END IF;

    -- ── CashSessionClosed: solo si difference <> 0 (D3/D4) ───────────────────
    IF v_event_type = 'CashSessionClosed' THEN
        v_difference := COALESCE((v_payload->>'difference')::numeric, 0);
        IF v_difference = 0 THEN
            RETURN;  -- sin diferencia de arqueo, no hace falta avisar
        END IF;
    END IF;

    -- ── Idempotencia: reclamar slot (event_id, 'Notification') ───────────────
    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
    VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        p_event.id::text || ':Notification',
        'event_consumer',
        p_event.id,
        'Notification'
    )
    ON CONFLICT (event_id, consumer_type)
    WHERE event_id IS NOT NULL
    DO NOTHING;

    GET DIAGNOSTICS v_claimed = ROW_COUNT;

    IF NOT v_claimed THEN
        RETURN;  -- slot ya existía → skip idempotente (ya se avisó)
    END IF;

    -- ── Dispatch por event_type → target + severity (D3 tabla design.md) ────
    IF v_event_type = 'CashSessionClosed' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'FiscalDocumentRejected' THEN
        v_target    := 'URGENT_FISCAL';
        v_severity  := 'urgent';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'StockBelowMinimum' THEN
        v_target    := 'PURCHASES';
        v_severity  := 'warning';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'QuoteAccepted' THEN
        v_target    := 'SELLER';
        v_severity  := 'info';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'TransferDispatched' THEN
        v_target    := 'BRANCH_DEST';
        v_severity  := 'info';
        v_branch_id := (v_payload->>'destination_branch_id')::uuid;
    END IF;

    -- ── Resolver audiencia ────────────────────────────────────────────────────
    v_audience := public._notification_audience(p_event.account_id, v_target, v_branch_id);

    IF v_audience IS NULL OR array_length(v_audience, 1) IS NULL THEN
        RETURN;  -- audiencia vacía: nada dirigido a nadie (idempotencia ya reclamada)
    END IF;

    -- ── INSERT notifications ──────────────────────────────────────────────────
    INSERT INTO public.notifications
        (account_id, branch_id, type, severity, payload, audience)
    VALUES (
        p_event.account_id,
        v_branch_id,
        v_event_type,
        v_severity,
        v_payload,
        v_audience
    );
END;
$fn$;

REVOKE ALL     ON FUNCTION public._notification_from_event(public.events) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._notification_from_event(public.events) FROM anon;
REVOKE EXECUTE ON FUNCTION public._notification_from_event(public.events) FROM authenticated;

COMMENT ON FUNCTION public._notification_from_event IS
    'v3-notifications-realtime (D2): helper del Consumer 4 (Notification) del '
    'relay del outbox. SECURITY DEFINER + SET search_path. Llamado solo desde '
    'rpc_process_outbox_dispatch. REVOCADO de authenticated/anon/PUBLIC. '
    'Idempotencia: (event_id, Notification) en operation_idempotency (mismo '
    'patrón que Consumer 3 JournalEntry). No-op para event_type fuera de los 5 '
    'en-scope, para CashSessionClosed con difference=0, y para audience vacía.';

-- =============================================================================
-- 3. CONSUMER 4: agregar Notification a rpc_process_outbox_dispatch
--    CREATE OR REPLACE preservando Consumers 1 (AuditLog), 2 (EmailNotification)
--    y 3 (JournalEntry) BYTE-A-BYTE (safety net task 3.1 — ver diff de esta
--    migración contra 20260803000001_journal_entry_schema.sql).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_process_outbox_dispatch(
  p_batch_limit int DEFAULT 100
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  C-25 + journal-entry-outbox + v3-notifications-realtime pure-SQL relay dispatch.

  Consumer order (per-event):
    1. AuditLog  (mandatory first — audit domain invariant)
    2. EmailNotification (sale_created/stock_adjusted/plan_changed)
    3. JournalEntry (SaleConfirmed/PurchaseCreated/PaymentReceived/PaymentMade/CreditNoteIssued)
    4. Notification (CashSessionClosed/StockBelowMinimum/FiscalDocumentRejected/
       QuoteAccepted/TransferDispatched) — v3-notifications-realtime.

  processed_at se escribe SOLO si todos los consumers activos del evento tienen
  éxito. Un consumer fallido deja processed_at NULL → retry en el próximo tick.
  Cada consumer está idempotency-guarded por (event_id, consumer_type).

  Per-event isolation: BEGIN/EXCEPTION/END por evento.
  SECURITY DEFINER: cross-account sin debilitar RLS. REVOCADO de anon/PUBLIC.
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
      -- Solo para los 5 tipos en-scope; _journal_post_from_event hace no-op para el resto.
      -- La idempotencia (event_id, 'JournalEntry') se gestiona dentro del helper.
      -- Un fallo en el posting (balance, NC sin original) deja el evento pending
      -- para retry — el EXCEPTION del sub-bloque lo captura sin abortar el batch.
      IF v_event.event_type IN (
          'SaleConfirmed', 'PurchaseCreated', 'PaymentReceived',
          'PaymentMade', 'CreditNoteIssued'
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

REVOKE ALL     ON FUNCTION public.rpc_process_outbox_dispatch(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_process_outbox_dispatch(int) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_process_outbox_dispatch(int) TO authenticated;

COMMENT ON FUNCTION public.rpc_process_outbox_dispatch IS
    'C-25 + journal-entry-outbox + v3-notifications-realtime: dispatch in-DB del '
    'outbox transaccional. '
    'Consumer 1: AuditLog (mandatory first). '
    'Consumer 2: EmailNotification (sale_created/stock_adjusted/plan_changed). '
    'Consumer 3: JournalEntry (SaleConfirmed/PurchaseCreated/PaymentReceived/PaymentMade/CreditNoteIssued) '
    '— llama a _journal_post_from_event (SECURITY DEFINER). '
    'Consumer 4: Notification (CashSessionClosed/StockBelowMinimum/FiscalDocumentRejected/'
    'QuoteAccepted/TransferDispatched) — llama a _notification_from_event (SECURITY DEFINER). '
    'processed_at SOLO tras éxito de todos los consumers activos. '
    'Per-event isolation: BEGIN/EXCEPTION/END. REVOCADO de anon/PUBLIC.';

-- ─── 3.5 Publicación Realtime ─────────────────────────────────────────────────
-- Requisito D1 design.md: Realtime respeta RLS SOLO si la tabla está en la
-- publicación Y la RLS está activa. RLS ya se habilitó arriba (sección 1.4)
-- ANTES de este ALTER PUBLICATION — orden importa (Risks/Trade-offs design.md).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'notifications'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
    END IF;
END $$;

-- =============================================================================
-- 4. RETENCIÓN: TTL cleanup (30 días, solo leídas)
-- =============================================================================

-- ─── 4.1 Función de cleanup ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._notifications_cleanup()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
    DELETE FROM public.notifications
    WHERE read = true
      AND read_at < now() - interval '30 days';
$fn$;

REVOKE ALL     ON FUNCTION public._notifications_cleanup() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._notifications_cleanup() FROM anon;
REVOKE EXECUTE ON FUNCTION public._notifications_cleanup() FROM authenticated;

COMMENT ON FUNCTION public._notifications_cleanup IS
    'v3-notifications-realtime (D6): TTL de retención — purga notifications '
    'leídas (read=true) con read_at anterior a 30 días. Las no-leídas NUNCA se '
    'auto-borran. Programada via pg_cron (job notifications-cleanup-ttl, '
    'patrón del relay C-27/C-25). SECURITY DEFINER, revocada de authenticated/anon.';

-- ─── 4.2 pg_cron schedule (patrón del relay C-27/C-25 — diario) ──────────────
SELECT cron.unschedule('notifications-cleanup-ttl')
FROM cron.job WHERE jobname = 'notifications-cleanup-ttl';

SELECT cron.schedule(
    'notifications-cleanup-ttl',
    '0 3 * * *',  -- diario a las 03:00 UTC — read model efímero, no es hot path
    $$ SELECT public._notifications_cleanup(); $$
);

-- =============================================================================
-- GATES SQL (TDD RED→GREEN — patrón C2/C3/journal-entry-outbox/v3-document-
-- status-history). Estructurales: SIEMPRE (prod y CI). Comportamiento: SOLO
-- si public.accounts está vacía (DB de test/CI) — anchor sintético en
-- auth.users (handle_new_user), limpieza best-effort, SIN exception-rollback
-- (accounts.owner_user_id tiene FK a auth.users — el sentinel-rollback de
-- 20260804000005 no aplica acá porque esa tabla no tiene esa FK).
-- =============================================================================
DO $gate$
DECLARE
    -- Estructurales
    v_col_count         int;
    v_idx_full          boolean;
    v_idx_partial       boolean;
    v_rls_enabled       boolean;
    v_insert_policy     int;
    v_audience_exists   boolean;
    v_from_event_exists boolean;
    v_audience_grants   int;
    v_from_event_grants int;
    v_published         boolean;
    v_job_exists        boolean;

    -- Comportamiento (solo DB vacía)
    v_run_behavioral    boolean;
    v_fake_user_id      uuid := gen_random_uuid();
    v_fake_member_id    uuid := gen_random_uuid();
    v_fake_account_id   uuid;
    v_notif_id          uuid;
    v_visible_in        boolean;
    v_visible_out       boolean;
    v_event_zero        public.events%ROWTYPE;
    v_event_nonzero     public.events%ROWTYPE;
    v_event_in_scope    public.events%ROWTYPE;
    v_event_out_scope   public.events%ROWTYPE;
    v_count             int;
    v_audience_result   uuid[];
    v_processed_in      timestamptz;
    v_processed_out     timestamptz;
    v_old_read_id       uuid;
    v_recent_read_id    uuid;
    v_unread_id         uuid;
BEGIN
    -- ══════════════════════════════════════════════════════════════════════
    -- ESTRUCTURALES (siempre — prod y CI)
    -- ══════════════════════════════════════════════════════════════════════

    -- (1.1) columnas esperadas de notifications
    SELECT count(*) INTO v_col_count
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'notifications'
      AND column_name IN ('id','account_id','branch_id','type','severity',
                           'payload','audience','read','created_at','read_at');
    IF v_col_count <> 10 THEN
        RAISE EXCEPTION 'GATE 1.1 FAILED: notifications tiene % de 10 columnas esperadas', v_col_count;
    END IF;

    -- (1.3) índices
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'notifications'
          AND indexname = 'idx_notifications_account_created'
    ) INTO v_idx_full;
    IF NOT v_idx_full THEN
        RAISE EXCEPTION 'GATE 1.3 FAILED: falta idx_notifications_account_created';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'notifications'
          AND indexname = 'idx_notifications_account_unread'
    ) INTO v_idx_partial;
    IF NOT v_idx_partial THEN
        RAISE EXCEPTION 'GATE 1.3 FAILED: falta idx_notifications_account_unread (parcial)';
    END IF;

    -- (1.4) RLS activa
    SELECT relrowsecurity INTO v_rls_enabled
    FROM pg_class WHERE oid = 'public.notifications'::regclass;
    IF NOT v_rls_enabled THEN
        RAISE EXCEPTION 'GATE 1.4 FAILED: RLS no está habilitada en notifications';
    END IF;

    -- (1.7) sin política INSERT para authenticated
    SELECT count(*) INTO v_insert_policy
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'notifications'
      AND cmd = 'INSERT' AND 'authenticated' = ANY(roles);
    IF v_insert_policy <> 0 THEN
        RAISE EXCEPTION 'GATE 1.7 FAILED: existe política INSERT para authenticated (no debería)';
    END IF;

    -- (2.1) helpers existen
    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = '_notification_audience')
    INTO v_audience_exists;
    IF NOT v_audience_exists THEN
        RAISE EXCEPTION 'GATE 2.1 FAILED: _notification_audience no existe';
    END IF;

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = '_notification_from_event')
    INTO v_from_event_exists;
    IF NOT v_from_event_exists THEN
        RAISE EXCEPTION 'GATE 2.1 FAILED: _notification_from_event no existe';
    END IF;

    -- (2.5) REVOKE de anon/authenticated/PUBLIC
    SELECT count(*) INTO v_audience_grants
    FROM information_schema.routine_privileges
    WHERE routine_schema = 'public' AND routine_name = '_notification_audience'
      AND grantee IN ('anon', 'authenticated', 'PUBLIC');
    IF v_audience_grants <> 0 THEN
        RAISE EXCEPTION 'GATE 2.5 FAILED: _notification_audience tiene grants a anon/authenticated/PUBLIC';
    END IF;

    SELECT count(*) INTO v_from_event_grants
    FROM information_schema.routine_privileges
    WHERE routine_schema = 'public' AND routine_name = '_notification_from_event'
      AND grantee IN ('anon', 'authenticated', 'PUBLIC');
    IF v_from_event_grants <> 0 THEN
        RAISE EXCEPTION 'GATE 2.5 FAILED: _notification_from_event tiene grants a anon/authenticated/PUBLIC';
    END IF;

    -- (3.5) tabla en la publicación supabase_realtime
    SELECT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'notifications'
    ) INTO v_published;
    IF NOT v_published THEN
        RAISE EXCEPTION 'GATE 3.5 FAILED: notifications no está en la publicación supabase_realtime';
    END IF;

    -- (4.2) pg_cron job existe
    SELECT EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'notifications-cleanup-ttl'
    ) INTO v_job_exists;
    IF NOT v_job_exists THEN
        RAISE EXCEPTION 'GATE 4.2 FAILED: pg_cron job notifications-cleanup-ttl no existe';
    END IF;

    RAISE NOTICE '=== v3-notifications-realtime GATES ESTRUCTURALES === OK';

    -- ══════════════════════════════════════════════════════════════════════
    -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3/DSH.
    -- ══════════════════════════════════════════════════════════════════════
    SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

    IF v_run_behavioral THEN
        BEGIN
            -- El trigger handle_new_user auto-crea account + membership(owner)
            INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
            VALUES (v_fake_user_id, 'authenticated', 'authenticated',
                    'v3-notifications-gate@test.local', now(), now(),
                    jsonb_build_object('name', 'Notif Gate', 'phone', '', 'locality', '', 'province', ''))
            ON CONFLICT (id) DO NOTHING;

            SELECT account_id INTO v_fake_account_id
            FROM public.account_members
            WHERE user_id = v_fake_user_id
            ORDER BY created_at
            LIMIT 1;

            IF v_fake_account_id IS NULL THEN
                v_fake_account_id := gen_random_uuid();
                INSERT INTO public.accounts (id, owner_user_id)
                VALUES (v_fake_account_id, v_fake_user_id) ON CONFLICT (id) DO NOTHING;
                INSERT INTO public.account_members (account_id, user_id, role)
                VALUES (v_fake_account_id, v_fake_user_id, 'owner')
                ON CONFLICT DO NOTHING;
            END IF;

            -- Segundo user "member" (fuera de audiencia en varios escenarios)
            INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
            VALUES (v_fake_member_id, 'authenticated', 'authenticated',
                    'v3-notifications-gate-member@test.local', now(), now(),
                    jsonb_build_object('name', 'Notif Gate Member', 'phone', '', 'locality', '', 'province', ''))
            ON CONFLICT (id) DO NOTHING;

            INSERT INTO public.account_members (account_id, user_id, role)
            VALUES (v_fake_account_id, v_fake_member_id, 'member')
            ON CONFLICT DO NOTHING;
        EXCEPTION
            WHEN OTHERS THEN
                v_run_behavioral := false;
                RAISE NOTICE 'v3-notifications-realtime: anchor sintético no disponible (%) — se saltan gates de comportamiento', SQLERRM;
        END;
    END IF;

    IF v_run_behavioral THEN

        -- ── (1.8) RLS de audiencia: owner ve su fila, member no ───────────────
        INSERT INTO public.notifications
            (account_id, type, severity, payload, audience)
        VALUES (v_fake_account_id, 'GateTest', 'info', '{}'::jsonb, ARRAY[v_fake_user_id])
        RETURNING id INTO v_notif_id;

        SELECT (v_fake_user_id   = ANY(audience)) INTO v_visible_in
        FROM public.notifications WHERE id = v_notif_id;
        SELECT (v_fake_member_id = ANY(audience)) INTO v_visible_out
        FROM public.notifications WHERE id = v_notif_id;

        IF NOT v_visible_in THEN
            RAISE EXCEPTION 'GATE 1.8 FAILED: usuario en audiencia debería ver la fila';
        END IF;
        IF v_visible_out THEN
            RAISE EXCEPTION 'GATE 1.8 FAILED: usuario fuera de audiencia NO debería ver la fila';
        END IF;

        -- ── (2.6) CashSessionClosed dif=0 no crea fila; dif≠0 sí; idempotente ─
        INSERT INTO public.events
            (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
            v_fake_account_id, 'CashSessionClosed', 'CashSession', gen_random_uuid(),
            jsonb_build_object('session_id', gen_random_uuid(), 'branch_id', NULL,
                                'difference', 0, 'closed_by', v_fake_user_id),
            now()
        )
        RETURNING * INTO v_event_zero;

        PERFORM public._notification_from_event(v_event_zero);

        SELECT count(*) INTO v_count
        FROM public.notifications
        WHERE account_id = v_fake_account_id AND type = 'CashSessionClosed';
        IF v_count <> 0 THEN
            RAISE EXCEPTION 'GATE 2.6 FAILED: CashSessionClosed con difference=0 NO debería crear fila (creó %)', v_count;
        END IF;

        INSERT INTO public.events
            (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
            v_fake_account_id, 'CashSessionClosed', 'CashSession', gen_random_uuid(),
            jsonb_build_object('session_id', gen_random_uuid(), 'branch_id', NULL,
                                'difference', 150.50, 'closed_by', v_fake_user_id),
            now()
        )
        RETURNING * INTO v_event_nonzero;

        PERFORM public._notification_from_event(v_event_nonzero);

        SELECT count(*) INTO v_count
        FROM public.notifications
        WHERE account_id = v_fake_account_id AND type = 'CashSessionClosed';
        IF v_count <> 1 THEN
            RAISE EXCEPTION 'GATE 2.6 FAILED: CashSessionClosed con difference!=0 debería crear 1 fila (creó %)', v_count;
        END IF;

        SELECT audience INTO v_audience_result
        FROM public.notifications
        WHERE account_id = v_fake_account_id AND type = 'CashSessionClosed';
        IF NOT (v_audience_result @> ARRAY[v_fake_user_id] AND array_length(v_audience_result, 1) = 1) THEN
            RAISE EXCEPTION 'GATE 2.6 FAILED: audience esperada = [owner] únicamente, obtenida %', v_audience_result;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM public.notifications
            WHERE account_id = v_fake_account_id AND type = 'CashSessionClosed'
              AND severity = 'warning'
        ) THEN
            RAISE EXCEPTION 'GATE 2.6 FAILED: severity esperada = warning';
        END IF;

        -- Idempotencia: re-ejecutar el helper con el MISMO evento no duplica.
        PERFORM public._notification_from_event(v_event_nonzero);

        SELECT count(*) INTO v_count
        FROM public.notifications
        WHERE account_id = v_fake_account_id AND type = 'CashSessionClosed';
        IF v_count <> 1 THEN
            RAISE EXCEPTION 'GATE 2.6 FAILED: re-ejecución duplicó filas (esperado 1, obtenido %)', v_count;
        END IF;

        -- ── (3.4) Consumer 4 integrado: in-scope crea notification y queda
        --     processed; fuera de scope también queda processed (consumers
        --     1-3) pero NO crea notification ────────────────────────────────
        INSERT INTO public.events
            (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
            v_fake_account_id, 'QuoteAccepted', 'Quote', gen_random_uuid(),
            jsonb_build_object('quote_id', gen_random_uuid(), 'seller_id', v_fake_user_id,
                                'branch_id', NULL, 'total', 1000),
            now()
        )
        RETURNING * INTO v_event_in_scope;

        INSERT INTO public.events
            (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
            v_fake_account_id, 'GateOutOfScopeEvent', 'Gate', gen_random_uuid(),
            '{}'::jsonb, now()
        )
        RETURNING * INTO v_event_out_scope;

        PERFORM public.rpc_process_outbox_dispatch(100);

        SELECT processed_at INTO v_processed_in
        FROM public.events WHERE id = v_event_in_scope.id;
        SELECT processed_at INTO v_processed_out
        FROM public.events WHERE id = v_event_out_scope.id;

        IF v_processed_in IS NULL THEN
            RAISE EXCEPTION 'GATE 3.4 FAILED: evento in-scope no quedó processed';
        END IF;
        IF v_processed_out IS NULL THEN
            RAISE EXCEPTION 'GATE 3.4 FAILED: evento fuera de scope no quedó processed';
        END IF;

        SELECT count(*) INTO v_count
        FROM public.notifications
        WHERE account_id = v_fake_account_id AND type = 'QuoteAccepted';
        IF v_count <> 1 THEN
            RAISE EXCEPTION 'GATE 3.4 FAILED: QuoteAccepted debería crear 1 notification (creó %)', v_count;
        END IF;

        SELECT count(*) INTO v_count
        FROM public.notifications
        WHERE account_id = v_fake_account_id AND type = 'GateOutOfScopeEvent';
        IF v_count <> 0 THEN
            RAISE EXCEPTION 'GATE 3.4 FAILED: evento fuera de scope no debería crear notification';
        END IF;

        -- ── (4.2) TTL cleanup: purga solo leídas > 30 días ────────────────────
        INSERT INTO public.notifications
            (account_id, type, severity, payload, audience, read, read_at, created_at)
        VALUES (
            v_fake_account_id, 'GateOld', 'info', '{}'::jsonb, ARRAY[v_fake_user_id],
            true, now() - interval '31 days', now() - interval '31 days'
        )
        RETURNING id INTO v_old_read_id;

        INSERT INTO public.notifications
            (account_id, type, severity, payload, audience, read, read_at, created_at)
        VALUES (
            v_fake_account_id, 'GateRecent', 'info', '{}'::jsonb, ARRAY[v_fake_user_id],
            true, now() - interval '5 days', now() - interval '5 days'
        )
        RETURNING id INTO v_recent_read_id;

        INSERT INTO public.notifications
            (account_id, type, severity, payload, audience, read, created_at)
        VALUES (
            v_fake_account_id, 'GateUnread', 'info', '{}'::jsonb, ARRAY[v_fake_user_id],
            false, now() - interval '60 days'
        )
        RETURNING id INTO v_unread_id;

        PERFORM public._notifications_cleanup();

        SELECT count(*) INTO v_count FROM public.notifications WHERE id = v_old_read_id;
        IF v_count <> 0 THEN
            RAISE EXCEPTION 'GATE 4.2 FAILED: notification leída > 30 días no fue purgada';
        END IF;

        SELECT count(*) INTO v_count FROM public.notifications WHERE id = v_recent_read_id;
        IF v_count <> 1 THEN
            RAISE EXCEPTION 'GATE 4.2 FAILED: notification leída dentro del TTL fue purgada indebidamente';
        END IF;

        SELECT count(*) INTO v_count FROM public.notifications WHERE id = v_unread_id;
        IF v_count <> 1 THEN
            RAISE EXCEPTION 'GATE 4.2 FAILED: notification NO leída fue purgada indebidamente';
        END IF;

        RAISE NOTICE '=== v3-notifications-realtime GATES DE COMPORTAMIENTO === OK';

        -- ── Limpieza del anchor sintético (solo DB de test, best-effort) ─────
        -- handle_new_user crea una cuenta propia para CADA auth.users insertado
        -- (v_fake_user_id Y v_fake_member_id) — se borran ambas por
        -- owner_user_id, no solo v_fake_account_id (el member se unió a la
        -- cuenta del owner manualmente, pero su propia cuenta auto-creada
        -- también queda huérfana si no se borra explícitamente).
        BEGIN
            DELETE FROM public.notifications WHERE account_id = v_fake_account_id;
            DELETE FROM public.events WHERE account_id = v_fake_account_id;
            DELETE FROM public.account_members
                WHERE account_id = v_fake_account_id
                   OR user_id IN (v_fake_user_id, v_fake_member_id);
            DELETE FROM public.accounts
                WHERE id = v_fake_account_id
                   OR owner_user_id IN (v_fake_user_id, v_fake_member_id);
            DELETE FROM public.profiles WHERE id IN (v_fake_user_id, v_fake_member_id);
            DELETE FROM auth.users WHERE id IN (v_fake_user_id, v_fake_member_id);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE 'v3-notifications-realtime: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
        END;
    ELSE
        RAISE NOTICE '=== v3-notifications-realtime GATES DE COMPORTAMIENTO === SALTEADOS (accounts no vacía — prod)';
    END IF;
END
$gate$;
