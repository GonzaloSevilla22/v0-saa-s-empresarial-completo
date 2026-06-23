-- Migration: wsaa_access_tickets
-- Change: v21-wsfe-production-hardening (C-31 follow-up)
-- Design ref: D5 (PO sign-off 2026-06-23: Postgres TA cache)
--
-- Tabla de cache del Ticket de Acceso (TA) de WSAA.
-- El adapter WSFEAdapter la usa para reusar el TA vigente entre invocaciones del relay
-- (pg_cron + background = procesos separados; in-process no alcanza).
-- Llave compuesta: (account_id, cuit, ambiente) — un TA por cuenta/CUIT/ambiente.
--
-- NOTA: Esta migración solo crea el objeto — NO la apliques directamente en producción
-- con el MCP `apply_migration`. Usar siempre: npx supabase db push
-- (ver CLAUDE.md regla NUNCA usar apply_migration en producción).

CREATE TABLE IF NOT EXISTS public.wsaa_access_tickets (
    account_id   uuid        NOT NULL,
    cuit         text        NOT NULL,
    ambiente     text        NOT NULL CHECK (ambiente IN ('homologacion', 'produccion')),
    token        text        NOT NULL,
    sign         text        NOT NULL,
    expires_at   timestamptz NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT wsaa_access_tickets_pkey PRIMARY KEY (account_id, cuit, ambiente)
);

-- Índice en expires_at para facilitar limpieza de tickets expirados (futuro cron)
CREATE INDEX IF NOT EXISTS wsaa_access_tickets_expires_at_idx
    ON public.wsaa_access_tickets (expires_at);

-- ── RLS ──────────────────────────────────────────────────────────────────────
-- El adapter lee/escribe con service_role (aislamiento DEC-13 — mismo que el
-- cert-read del bucket afip-certs). RLS by account_id = defensa en profundidad.

ALTER TABLE public.wsaa_access_tickets ENABLE ROW LEVEL SECURITY;

-- Policy: lectura/escritura restringida al account_id propio.
-- En prod el adapter usa service_role (BYPASSRLS), pero RLS protege ante cualquier
-- acceso accidental con JWT de usuario.
CREATE POLICY "wsaa_tickets_owner_only" ON public.wsaa_access_tickets
    USING  (account_id = (auth.jwt() ->> 'account_id')::uuid)
    WITH CHECK (account_id = (auth.jwt() ->> 'account_id')::uuid);

-- ── Comentarios ───────────────────────────────────────────────────────────────
COMMENT ON TABLE public.wsaa_access_tickets IS
    'Cache del Ticket de Acceso (TA) de WSAA por (account_id, CUIT, ambiente). '
    'Usado por WSFEAdapter para reusar el TA entre invocaciones del relay (D5). '
    'El TA dura ~12h; WSAA rechaza loginCms repetido con ''el CUIT ya posee un TA valido''.';

COMMENT ON COLUMN public.wsaa_access_tickets.account_id IS 'Cuenta propietaria del certificado AFIP';
COMMENT ON COLUMN public.wsaa_access_tickets.cuit        IS 'CUIT del emisor (de fiscal_profiles.cuit)';
COMMENT ON COLUMN public.wsaa_access_tickets.ambiente    IS 'homologacion | produccion';
COMMENT ON COLUMN public.wsaa_access_tickets.token       IS 'Campo Token del TA de WSAA';
COMMENT ON COLUMN public.wsaa_access_tickets.sign        IS 'Campo Sign del TA de WSAA';
COMMENT ON COLUMN public.wsaa_access_tickets.expires_at  IS 'expirationTime del TA (del XML de WSAA)';
COMMENT ON COLUMN public.wsaa_access_tickets.updated_at  IS 'Ultima vez que se actualizo el TA en la cache';
