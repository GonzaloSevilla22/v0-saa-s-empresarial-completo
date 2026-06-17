-- =============================================================================
-- MIGRATION: 20260702000002_c29_hotfix_events_outbox_nullable.sql
-- HOTFIX C-29: el INSERT al outbox de SalesOrder.confirm()/quickSale() fallaba
--              en prod con 23502 "null value in column company_id ... violates
--              not-null constraint" (y luego entity_type), rompiendo TODA venta.
--
-- Root cause + DRIFT de schema (importante):
--   La tabla public.events de PROD NO coincide con la que producen las migraciones.
--   * En PROD (schema original, fuera del historial de migraciones): events tiene
--       company_id uuid NOT NULL  y  entity_type text NOT NULL  (diseño de eventos
--       viejo basado en company). El INSERT del outbox V2 (20260702000001) provee
--       event_type/payload/account_id/aggregate_type/aggregate_id/occurred_at pero
--       NO company_id ni entity_type -> 23502.
--   * En CI (Supabase fresco desde migraciones): events viene del stub
--       20260517000000_ci_compat_stubs.sql = (id, company_id[NULLABLE], title,
--       created_at). NO existe entity_type, y company_id ya es nullable. Por eso
--       C-29 pasó validate-kpis pero rompió en prod (el bug solo se ve en prod).
--
-- Por el drift, esta migración debe ser TOLERANTE: solo afloja columnas que
--   existan y estén NOT NULL. Idempotente y segura en ambos entornos.
--   `events` no tiene productores/consumers en el código de la app (verificado por
--   grep); el modelo V2 la trata como outbox vacío a activar (C-25, que leerá
--   aggregate_*). company_id/entity_type quedan como columnas legacy nullable.
--
-- TODO C-25: reconciliar el drift de `events` prod vs migraciones (formalizar el
--   schema único del outbox en el historial de migraciones).
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'events'
      AND column_name = 'company_id' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.events ALTER COLUMN company_id DROP NOT NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'events'
      AND column_name = 'entity_type' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.events ALTER COLUMN entity_type DROP NOT NULL;
  END IF;
END $$;
