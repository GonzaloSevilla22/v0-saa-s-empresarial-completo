-- =============================================================================
-- MIGRATION: 20260702000002_c29_hotfix_events_outbox_nullable.sql
-- HOTFIX C-29: el INSERT al outbox de SalesOrder.confirm()/quickSale() fallaba
--              en prod con 23502 "null value in column company_id ... violates
--              not-null constraint" (y luego entity_type), rompiendo TODA venta.
--
-- Root cause:
--   La tabla public.events NO era el stub simple (id, company_id, title) que
--   asumió C-29 (ese CREATE TABLE IF NOT EXISTS fue no-op porque la tabla ya
--   existía con otra forma). La tabla real (schema original) tiene columnas
--   NOT NULL heredadas de un diseño de eventos viejo basado en company:
--     - company_id  uuid  NOT NULL   ← concepto retirado en V2 (tenancy = account_id)
--     - entity_type text  NOT NULL   ← C-29 usa aggregate_type en su lugar
--   El INSERT del hot path (20260702000001) provee event_type/payload/account_id/
--   aggregate_type/aggregate_id/occurred_at pero NO company_id ni entity_type.
--   pytest mockea asyncpg y no lo detectó; lo cazó el smoke transaccional en prod.
--
-- Fix: hacer nullables las dos columnas vestigiales. `events` no tiene productores
--   ni consumers en el código de la app (verificado por grep), y el modelo V2 la
--   trata como outbox vacío a activar (C-25). El outbox V2 usa
--   (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at).
--   company_id/entity_type/entity_id quedan como columnas legacy nullable; C-25
--   leerá aggregate_*.
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- =============================================================================

ALTER TABLE public.events ALTER COLUMN company_id  DROP NOT NULL;
ALTER TABLE public.events ALTER COLUMN entity_type DROP NOT NULL;
