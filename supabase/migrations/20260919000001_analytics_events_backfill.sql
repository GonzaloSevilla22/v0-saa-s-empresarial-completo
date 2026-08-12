-- =============================================================================
-- MIGRATION: 20260919000001_analytics_events_backfill.sql
-- CHANGE:    analytics-events-revival (backfill — grupo 6 de tasks.md)
--
-- QUÉ HACE:
--   OQ-2 (design.md "Open Questions") fue aprobada por el PO 2026-08-12:
--   Opción A — backfill histórico. Sin esto, `rpc_admin_retention_30d` no
--   tiene cohortes de las rutas modernas (emisión revivida en PR #383,
--   20260914000001) y los usuarios existentes quedarían fuera de toda
--   cohorte de retención PARA SIEMPRE, no sólo durante la transición.
--
--   1. Backfill de `operation_created`: un evento por cada fila histórica de
--      `sales`/`purchases`/`expenses`, con `created_at` = el de la operación
--      (columna `created_at` de cada tabla — el mismo momento que hubiera
--      usado el trigger si hubiera estado vivo), `event_data.source =
--      'backfill'`, `entity_id`/`entity_type` en el mismo formato canónico
--      que usa el trigger (`analytics_emit_operation_event()`,
--      20260914000001).
--   2. Backfill de `first_operation`: uno por usuario, en su operación
--      histórica más antigua entre las tres tablas.
--   3. OQ-3 (aprobada junto con OQ-2): índice único parcial para
--      `umv_reached`, mismo patrón que `ux_analytics_first_operation_user`
--      (D9 del design) — cierra la misma clase de carrera en
--      `rpc_atomic_log_ai_insight` (la RPC viva real; el design la nombra
--      `rpc_create_insight`, ver hallazgo 1.5 de tasks.md).
--
--   Deduplicación (task 6.4 de tasks.md):
--     - Contra el propio backfill / los triggers ya emitidos: los dos
--       índices únicos parciales de 20260914000001
--       (`ux_analytics_operation_entity` sobre `entity_id`,
--       `ux_analytics_first_operation_user` sobre `user_id`) + `ON CONFLICT
--       DO NOTHING` en cada INSERT — cubre toda operación que ya haya
--       disparado el trigger (verificado en prod: 2 eventos `source=trigger`
--       al momento de escribir esta migración).
--     - Contra los eventos LEGACY preexistentes (previos a este change, que
--       usan las claves `sale_id`/`purchase_id`/`expense_id` en vez de
--       `entity_id` — verificado en prod: 102 `sale_id`, 72 `purchase_id`,
--       44 `expense_id`): esas claves NO caen bajo el índice único por
--       `entity_id` (jsonb key distinta), así que cada bloque de backfill
--       lleva su propio `WHERE NOT EXISTS` contra la clave legacy
--       correspondiente para no duplicar.
--
--   NO se tocan ni se borran los eventos legacy existentes (instrucción
--   explícita del apply). `first_operation` no necesita una comprobación de
--   clave legacy: el índice único `(user_id) WHERE event_name =
--   'first_operation'` ya cubre cualquier formato de clave histórica —
--   ON CONFLICT (user_id) descarta el backfill para cualquier usuario que ya
--   tenga uno, sin importar si la fila existente usa `sale_id`/`expense_id`
--   (legacy) o `entity_id` (trigger).
--
-- GOVERNANCE: MEDIO — igual que 20260914000001. No toca dinero ni auth; el
--   dato que produce es telemetría derivada de operaciones ya existentes
--   (exacta, no estimada: cada fila de `sales`/`purchases`/`expenses` mapea
--   1:1 a lo sumo un `operation_created` de backfill).
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE: la integración GitHub de Supabase auto-
--   aplica migraciones al mergear a main ANTES del `db push` de Actions →
--   esta migración puede correr más de una vez.
--     - Los tres INSERT...SELECT de operation_created son idempotentes por
--       partida doble: el WHERE NOT EXISTS contra la clave legacy y el
--       ON CONFLICT DO NOTHING contra el índice único por entity_id. Una
--       segunda corrida no inserta ninguna fila nueva (verificado por gate
--       en supabase/tests/test_analytics_events.sql).
--     - El INSERT de first_operation es idempotente por ON CONFLICT
--       (user_id) DO NOTHING.
--     - La limpieza de duplicados de umv_reached es un DELETE condicionado
--       por ROW_NUMBER(): en la segunda corrida no quedan duplicados, no
--       borra nada. CREATE UNIQUE INDEX IF NOT EXISTS para el índice.
--
-- APPLY: vía CI al mergear a main (GitHub Actions: build + deploy + db
--   push). NUNCA aplicar con el MCP `apply_migration`.
--
-- ROLLBACK: las filas de backfill son identificables y borrables por
--   `event_data->>'source' = 'backfill'` (ver design.md "Rollback") — no se
--   provee un DOWN automático porque borrar telemetría ya consumida por
--   paneles admin no es un rollback seguro por defecto; queda como comando
--   manual si alguna vez hace falta:
--     DELETE FROM analytics_events WHERE event_data->>'source' = 'backfill';
--   El índice `ux_analytics_umv_reached_user` puede quedar (inerte, no
--   rompe nada) o borrarse con `DROP INDEX ux_analytics_umv_reached_user`.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Backfill de operation_created — ventas
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
SELECT
  s.user_id,
  s.account_id,
  'operation_created',
  jsonb_build_object(
    'entity_id',   s.id,
    'entity_type', 'sale',
    'source',      'backfill'
  ),
  s.created_at
FROM public.sales s
WHERE NOT EXISTS (
  SELECT 1 FROM public.analytics_events ae
  WHERE ae.event_data->>'sale_id' = s.id::text
)
ON CONFLICT (event_name, (event_data->>'entity_id'))
  WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill de operation_created — compras
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
SELECT
  p.user_id,
  p.account_id,
  'operation_created',
  jsonb_build_object(
    'entity_id',   p.id,
    'entity_type', 'purchase',
    'source',      'backfill'
  ),
  p.created_at
FROM public.purchases p
WHERE NOT EXISTS (
  SELECT 1 FROM public.analytics_events ae
  WHERE ae.event_data->>'purchase_id' = p.id::text
)
ON CONFLICT (event_name, (event_data->>'entity_id'))
  WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Backfill de operation_created — gastos
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
SELECT
  e.user_id,
  e.account_id,
  'operation_created',
  jsonb_build_object(
    'entity_id',   e.id,
    'entity_type', 'expense',
    'source',      'backfill'
  ),
  e.created_at
FROM public.expenses e
WHERE NOT EXISTS (
  SELECT 1 FROM public.analytics_events ae
  WHERE ae.event_data->>'expense_id' = e.id::text
)
ON CONFLICT (event_name, (event_data->>'entity_id'))
  WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Backfill de first_operation — una por usuario, en su operación
--    histórica más antigua entre sales/purchases/expenses. ON CONFLICT
--    (user_id) cubre cualquier first_operation preexistente sin importar el
--    formato de su clave (legacy sale_id/expense_id o entity_id).
-- ─────────────────────────────────────────────────────────────────────────────
WITH historical_ops AS (
  SELECT user_id, account_id, id AS entity_id, 'sale'::text AS entity_type, created_at
  FROM public.sales
  UNION ALL
  SELECT user_id, account_id, id, 'purchase', created_at
  FROM public.purchases
  UNION ALL
  SELECT user_id, account_id, id, 'expense', created_at
  FROM public.expenses
),
earliest_per_user AS (
  SELECT user_id, account_id, entity_id, entity_type, created_at,
         ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at ASC, entity_id ASC) AS rn
  FROM historical_ops
)
INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
SELECT
  user_id,
  account_id,
  'first_operation',
  jsonb_build_object(
    'entity_id',   entity_id,
    'entity_type', entity_type,
    'source',      'backfill'
  ),
  created_at
FROM earliest_per_user
WHERE rn = 1
ON CONFLICT (user_id)
  WHERE event_name = 'first_operation'
DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. OQ-3 — índice único parcial para umv_reached (mismo patrón que D4/D9)
--    Limpieza idempotente previa: conserva el created_at más antiguo por
--    user_id, borra el resto (no-op si no hay duplicados — verificado en
--    prod, task de verificación previa: 0 usuarios con umv_reached
--    duplicado al momento de escribir esta migración).
-- ─────────────────────────────────────────────────────────────────────────────
DELETE FROM public.analytics_events ae
USING (
  SELECT id,
         ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at ASC, id ASC) AS rn
  FROM   public.analytics_events
  WHERE  event_name = 'umv_reached'
    AND  user_id IS NOT NULL
) dedup
WHERE ae.id = dedup.id
  AND dedup.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS ux_analytics_umv_reached_user
  ON public.analytics_events (user_id)
  WHERE event_name = 'umv_reached';

-- =============================================================================
-- END OF MIGRATION 20260919000001_analytics_events_backfill.sql
-- =============================================================================
