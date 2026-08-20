-- =============================================================================
-- backfill_asiento_venta_formulario.sql
--
-- asiento-venta-formulario — sign-off PO 2026-08-20 (pre-aprobado en el brief
-- de implementación, sin gate adicional): backfillear el histórico de ambos
-- lados via el CONSUMIDOR REAL, mismo patrón que la puesta al día de #248.
--
-- QUÉ HACE
--   Grupo A — INSERTa un evento `SaleOperationCreated` por cada operación de
--   VENTA del formulario (sales.operation_id) que no tenga sales_orders
--   asociada (nacida en el formulario, no en el POS) y que todavía no tenga
--   un evento de ese tipo. Payload idéntico al del productor vivo
--   (rpc_create_sale_operation_v2): total = SUMA de sales.total por
--   operation_id, payment_method = kind imputado (payment_methods.kind vía
--   payment_method_id, NULL si no hay imputación — 225 de 228 casos, D3),
--   client_id, sale_date = fecha de la operación en día ART
--   ((sales.date AT TIME ZONE 'America/Argentina/Mendoza')::date — MISMA
--   zona que ya usa reporting_local_today() y la rama D5 del consumidor).
--
--   Grupo B — INSERTa un evento `PurchaseCreated` por cada operación de
--   COMPRA (purchases.operation_id) que todavía no tenga un evento de ese
--   tipo. Payload idéntico al del productor vivo (rpc_create_purchase_
--   operation): total = SUMA de purchases.total por operation_id,
--   cost_center_id, neto/iva_amount = NULL (sin desglose, igual que el
--   productor), payment_method = COALESCE(kind imputado, 'credit') — MISMO
--   default histórico que usa el productor cuando no hay forma imputada.
--   Cero código de consumidor nuevo: la rama PurchaseCreated ya está en
--   producción con 39 asientos posteados.
--
--   Ambos grupos marcan `payload.source = 'backfill'` (identificable y
--   reversible como lote) y NO tocan `journal_entries`/`journal_lines`
--   directamente — el relay real (`rpc_process_outbox_dispatch`, pg_cron
--   cada minuto) los procesa exactamente como procesaría un evento nacido
--   hoy, produciendo el mismo asiento que produciría una venta/compra nueva.
--
-- ALCANCE ESPERADO (recontado el 2026-08-20, task 0.4 de asiento-venta-
-- formulario — coincide exacto con el design.md)
--   Grupo A: 228 operaciones de venta del formulario sin evento.
--   Grupo B: 40 operaciones de compra sin PurchaseCreated (39 anteriores al
--   alta del productor el 2026-06-29 + 1 anomalía del 2026-07-31).
--   18 filas de `sales` y 13 de `purchases` con operation_id IS NULL (legacy
--   pre-agrupación) quedan FUERA de alcance a propósito (OQ-4 — sin
--   operation_id no hay operación que referenciar).
--
-- NO ES UNA MIGRACIÓN. El merge a main aplica migraciones automáticamente y
-- este backfill de datos no puede viajar en ese tren — se ejecuta a mano UNA
-- sola vez, con los conteos a la vista, contra el proyecto prod real
-- (gxdhpxvdjjkmxhdkkwyb) vía MCP execute_sql, o localmente con:
--   psql "$DATABASE_URL" -f scripts/sql/backfill_asiento_venta_formulario.sql
--
-- IDEMPOTENTE
--   Ambos INSERTs sólo alcanzan operaciones SIN evento de ese tipo todavía
--   (WHERE NOT EXISTS) — re-ejecutar el script no inserta nada la segunda vez
--   (0 filas afectadas).
--
-- DESPUÉS DE CORRER ESTO
--   El relay (pg_cron, cada minuto, batch de 100) drena los eventos nuevos a
--   ~100/minuto — ~268 eventos ≈ 3 minutos hasta que journal_entries refleje
--   el total. Verificar con:
--     SELECT count(*) FROM public.events WHERE processed_at IS NULL;
--   (debe volver a 0 una vez que el relay termine).
--
-- ROLLBACK (revierte el LOTE completo, identificado por payload.source)
--   DELETE FROM public.events
--   WHERE payload->>'source' = 'backfill'
--     AND event_type IN ('SaleOperationCreated', 'PurchaseCreated');
--   -- Los asientos que el relay ya haya posteado a partir de esos eventos
--   -- (journal_entries.source_event_id apunta al evento) requieren revertirse
--   -- aparte si el relay ya corrió:
--   DELETE FROM public.journal_lines WHERE entry_id IN (
--     SELECT id FROM public.journal_entries WHERE source_event_id IN (
--       SELECT id FROM public.events WHERE payload->>'source' = 'backfill'
--     )
--   );
--   DELETE FROM public.journal_entries WHERE source_event_id IN (
--     SELECT id FROM public.events WHERE payload->>'source' = 'backfill'
--   );
-- =============================================================================

-- ── Conteos ANTES ─────────────────────────────────────────────────────────────
SELECT
  (SELECT count(DISTINCT s.operation_id) FROM public.sales s
     WHERE s.operation_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.sales_orders so WHERE so.sale_operation_id = s.operation_id)
       AND NOT EXISTS (SELECT 1 FROM public.events e WHERE e.event_type = 'SaleOperationCreated' AND e.aggregate_id = s.operation_id))
    AS grupo_a_ventas_formulario_sin_evento,
  (SELECT count(DISTINCT p.operation_id) FROM public.purchases p
     WHERE p.operation_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.events e WHERE e.event_type = 'PurchaseCreated' AND e.aggregate_id = p.operation_id))
    AS grupo_b_compras_sin_evento,
  (SELECT count(*) FROM public.journal_entries) AS journal_entries_total_antes,
  (SELECT count(*) FROM public.events WHERE processed_at IS NULL) AS eventos_pendientes_antes;

BEGIN;

-- ── Grupo A: SaleOperationCreated para ventas del formulario ────────────────
WITH sale_ops AS (
  SELECT
    sa.operation_id,
    (array_agg(sa.account_id))[1]        AS account_id,
    SUM(sa.total)                        AS total_sum,
    (array_agg((sa.date AT TIME ZONE 'America/Argentina/Mendoza')::date))[1] AS sale_date,
    (array_agg(sa.client_id))[1]         AS client_id,
    (array_agg(sa.payment_method_id))[1] AS payment_method_id
  FROM public.sales sa
  WHERE sa.operation_id IS NOT NULL
  GROUP BY sa.operation_id
)
INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
SELECT
  so.account_id,
  'SaleOperationCreated',
  'SaleOperation',
  so.operation_id,
  jsonb_build_object(
    'account_id',     so.account_id,
    'operation_id',   so.operation_id,
    'total',          so.total_sum,
    'payment_method', pm.kind,          -- crudo, NULL si no hay imputación (D6 del productor vivo)
    'client_id',       so.client_id,
    'sale_date',       so.sale_date,
    'occurred_at',     now(),
    'source',          'backfill'
  ),
  now()
FROM sale_ops so
LEFT JOIN public.payment_methods pm ON pm.id = so.payment_method_id
WHERE NOT EXISTS (
        SELECT 1 FROM public.sales_orders sord WHERE sord.sale_operation_id = so.operation_id
      )
  AND NOT EXISTS (
        SELECT 1 FROM public.events e
        WHERE e.event_type = 'SaleOperationCreated' AND e.aggregate_id = so.operation_id
      );

-- ── Grupo B: PurchaseCreated para compras históricas (cero rama nueva) ──────
WITH purchase_ops AS (
  SELECT
    p.operation_id,
    (array_agg(p.account_id))[1]        AS account_id,
    SUM(p.total)                        AS total_sum,
    (array_agg(p.cost_center_id))[1]    AS cost_center_id,
    (array_agg(p.payment_method_id))[1] AS payment_method_id
  FROM public.purchases p
  WHERE p.operation_id IS NOT NULL
  GROUP BY p.operation_id
)
INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
SELECT
  po.account_id,
  'PurchaseCreated',
  'Purchase',
  po.operation_id,
  jsonb_build_object(
    'account_id',     po.account_id,
    'operation_id',   po.operation_id,
    'total',          po.total_sum,
    'cost_center_id', po.cost_center_id,
    'neto',           NULL,
    'iva_amount',     NULL,
    'payment_method', COALESCE(pm.kind, 'credit'),  -- mismo default histórico que el productor vivo
    'occurred_at',    now(),
    'source',         'backfill'
  ),
  now()
FROM purchase_ops po
LEFT JOIN public.payment_methods pm ON pm.id = po.payment_method_id
WHERE NOT EXISTS (
        SELECT 1 FROM public.events e
        WHERE e.event_type = 'PurchaseCreated' AND e.aggregate_id = po.operation_id
      );

COMMIT;

-- ── Conteos DESPUÉS ───────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM public.events WHERE event_type = 'SaleOperationCreated' AND payload->>'source' = 'backfill') AS grupo_a_eventos_insertados,
  (SELECT count(*) FROM public.events WHERE event_type = 'PurchaseCreated'      AND payload->>'source' = 'backfill') AS grupo_b_eventos_insertados,
  (SELECT count(*) FROM public.events WHERE processed_at IS NULL) AS eventos_pendientes_despues;
