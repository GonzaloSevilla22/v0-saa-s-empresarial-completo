-- =============================================================================
-- MIGRATION: 20260509213410_drop_rpc_integer_overloads.sql
-- DESCRIPTION: Etapa 2 — Limpieza de overloads integer residuales
--
-- Después de 20260509213302 (INTEGER → NUMERIC), quedaron 3 overloads por función
-- en pg_proc: 2 con p_quantity integer sin date y 1 con p_user_id extra.
-- Esta migración los elimina dejando exactamente 1 firma limpia por función.
--
-- Firmas eliminadas:
--   rpc_atomic_create_sale(uuid, uuid, numeric, integer, text)
--   rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid, text)
--   rpc_atomic_create_purchase(uuid, numeric, integer, text)
--   rpc_atomic_create_purchase(uuid, numeric, integer, uuid, text)
--
-- Firma canónica resultante (1 por función):
--   rpc_atomic_create_sale(uuid, uuid, numeric, numeric, text, date)
--   rpc_atomic_create_purchase(uuid, numeric, numeric, text, date)
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509213410
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, text);
DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid, text);
DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, integer, text);
DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, integer, uuid, text);
