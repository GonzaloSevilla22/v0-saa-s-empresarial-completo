-- =============================================================================
-- MIGRATION: 20260800000002_v22_platform_wsaa_tickets.sql
-- CHANGE:    v22-afip-delegation-billing
-- Design ref: D5 (caché del TA de plataforma — una entrada por ambiente)
--             Gate 0 sign-off PO 2026-06-23 (OQ-3)
--
-- Crea la tabla `platform_wsaa_tickets` para cachear el Ticket de Acceso (TA)
-- del representante de la plataforma. A diferencia de `wsaa_access_tickets`
-- (per-cuenta, per-CUIT), esta tabla tiene UNA fila por ambiente:
--   - Key: ambiente ∈ {homologacion, produccion}
--   - Sin account_id: es estado de PLATAFORMA, no de cuenta
--   - Sin RLS por account: acceso restringido al backend via service_role
--
-- Relación con wsaa_access_tickets (tabla anterior per-CUIT, C-31):
--   Las filas existentes en wsaa_access_tickets quedan INERTES — el adapter
--   deja de consultarlas para el TA del representante. No se eliminan (reversibilidad).
--   Para truncarlas manualmente (opcional): TRUNCATE public.wsaa_access_tickets;
--
-- El TA del representante es compartido entre TODOS los CUIT representados para
-- un ambiente dado. Todos los relay points (process-pending, process-pending-cron,
-- process_doc_by_id_background) lo leen desde aquí via PlatformPostgresTicketCache.
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- ROLLBACK: DROP TABLE IF EXISTS public.platform_wsaa_tickets;
-- =============================================================================

-- ─── Tabla: platform_wsaa_tickets ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.platform_wsaa_tickets (
    ambiente     text        NOT NULL
        CHECK (ambiente IN ('homologacion', 'produccion')),
    token        text        NOT NULL,
    sign         text        NOT NULL,
    expires_at   timestamptz NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT platform_wsaa_tickets_pkey PRIMARY KEY (ambiente)
);

-- Índice en expires_at para limpieza futura (cron de tickets expirados)
CREATE INDEX IF NOT EXISTS platform_wsaa_tickets_expires_at_idx
    ON public.platform_wsaa_tickets (expires_at);

-- ── RLS ──────────────────────────────────────────────────────────────────────
-- Esta tabla es estado de PLATAFORMA, no de cuenta.
-- El backend la lee/escribe con service_role (BYPASSRLS — DEC-13).
-- Se activa RLS como defensa en profundidad; NO se crea policy de usuario
-- (con service_role la tabla es accesible; con JWT de usuario, nunca).
ALTER TABLE public.platform_wsaa_tickets ENABLE ROW LEVEL SECURITY;

-- Sin policies de usuario — el acceso es EXCLUSIVO via service_role (BYPASSRLS).
-- Cualquier intento de acceso con JWT de usuario autenticado devuelve vacío.

-- ── Comentarios ───────────────────────────────────────────────────────────────
COMMENT ON TABLE public.platform_wsaa_tickets IS
    'v22: caché del Ticket de Acceso (TA) de WSAA del representante de la plataforma. '
    'Una fila por ambiente (homologacion/produccion). '
    'En el modelo de delegación el representante tiene UN solo TA por ambiente, '
    'compartido entre todos los CUIT representados. '
    'Acceso EXCLUSIVO via service_role (BYPASSRLS). '
    'Las filas de wsaa_access_tickets (tabla anterior per-cuenta/CUIT de C-31) '
    'quedan inertes — el adapter ya no las consulta para el TA del representante.';

COMMENT ON COLUMN public.platform_wsaa_tickets.ambiente    IS 'homologacion | produccion — PK de la tabla';
COMMENT ON COLUMN public.platform_wsaa_tickets.token       IS 'Campo Token del TA del representante (WSAA loginCms)';
COMMENT ON COLUMN public.platform_wsaa_tickets.sign        IS 'Campo Sign del TA del representante (WSAA loginCms)';
COMMENT ON COLUMN public.platform_wsaa_tickets.expires_at  IS 'expirationTime del TA (del XML de respuesta de WSAA)';
COMMENT ON COLUMN public.platform_wsaa_tickets.updated_at  IS 'Última vez que se actualizó el TA en la caché';

-- ── Verificación (post-push) ──────────────────────────────────────────────────
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public' AND table_name = 'platform_wsaa_tickets';
-- → 1 fila
--
-- SELECT column_name FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'platform_wsaa_tickets';
-- → ambiente, token, sign, expires_at, updated_at
