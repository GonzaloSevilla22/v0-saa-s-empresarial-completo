-- =============================================================================
-- MIGRATION: 20260800000001_v22_fiscal_profiles_delegation.sql
-- CHANGE:    v22-afip-delegation-billing
-- Design ref: D6 (flag de delegación — atestación, no verificación)
--             Gate 0 sign-off PO 2026-06-23 (OQ-2, OQ-4)
--
-- Agrega `delegacion_autorizada BOOLEAN NOT NULL DEFAULT FALSE` a fiscal_profiles.
-- Este flag es una ATESTACIÓN del usuario (no una verificación programática):
--   - TRUE = el usuario dice haber autorizado al representante en ARCA Adm. de Relaciones
--   - La verdad la da AFIP al intentar FECAESolicitar (attempt-and-surface, D6/OQ-4)
--   - El flag NUNCA bloquea la emisión; solo sirve para UX (advertencia pre-intento)
--
-- RLS: Hereda las policies de fiscal_profiles (INSERT/UPDATE: is_account_writer → solo
-- owner/admin). Los members pueden hacer SELECT pero NO modificar el flag.
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — CLAUDE.md regla)
-- ROLLBACK: ALTER TABLE public.fiscal_profiles DROP COLUMN IF EXISTS delegacion_autorizada;
-- =============================================================================

-- ─── Agregar columna (aditiva, no destructiva) ────────────────────────────────
ALTER TABLE public.fiscal_profiles
    ADD COLUMN IF NOT EXISTS delegacion_autorizada BOOLEAN NOT NULL DEFAULT FALSE;

-- ── RLS: heredada de las policies existentes de fiscal_profiles ────────────────
-- Las policies actuales de fiscal_profiles ya cubren esta columna:
--   - fiscal_profiles_member_select: todos los miembros de la cuenta pueden SELECT
--   - fiscal_profiles_writer_insert: solo owner/admin pueden INSERT (is_account_writer)
--   - fiscal_profiles_writer_update: solo owner/admin pueden UPDATE (is_account_writer)
-- No se necesitan policies adicionales para esta columna.

-- ── Comentarios ───────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.fiscal_profiles.delegacion_autorizada IS
    'v22: flag de atestación de delegación ARCA. TRUE = el usuario declaró haber '
    'autorizado al representante de la plataforma (CUIT configurado en AFIP_PLATFORM_CUIT) '
    'en ARCA → Administrador de Relaciones → Facturación Electrónica. '
    'NO es una verificación — la confirmación real la da FECAESolicitar (attempt-and-surface). '
    'Solo editable por owner/admin (RLS vía is_account_writer). DEFAULT FALSE.';

-- ── Verificación (post-push) ──────────────────────────────────────────────────
-- SELECT column_name, data_type, column_default, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name = 'fiscal_profiles'
--   AND column_name = 'delegacion_autorizada';
-- → 1 fila: delegacion_autorizada | boolean | false | NO
