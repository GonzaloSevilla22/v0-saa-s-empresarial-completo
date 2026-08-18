-- =============================================================================
-- 20260925000001_cleanup_analytics_and_line_account_id.sql
--
-- deudas-menores-agosto (G4) — sign-off PO 2026-08-18.
--
-- (a) Limpieza idempotente de analytics_events (event_name='operation_created'):
--     - Huérfanos: la clave de entidad no tiene fila en sales/purchases/
--       expenses. La clave contempla las DOS formas de payload que conviven
--       en los datos históricos: la canónica (entity_id) y la del emisor
--       legacy retirado (sale_id/purchase_id/expense_id + type) — de ahí el
--       COALESCE. NOT EXISTS contra las tablas de operaciones cubre el
--       soft delete: una fila soft-deleted SIGUE EXISTIENDO como fila, así
--       que su evento no se toca (design.md §D4).
--     - Duplicados: más de un evento para la misma clave de entidad —
--       conserva el de created_at más antiguo. No-op hoy (0 duplicados
--       verificados 2026-08-18), se incluye igual por corrección: la
--       migración re-deriva contra el estado real, no contra lo observado.
--     No hardcodea ids ni conteos esperados — todo se re-deriva al correr.
--     RAISE NOTICE con el conteo real de cada paso.
--
-- (b) Backfill determinístico e idempotente de account_id en sale_items /
--     purchase_items desde su venta/compra padre. Sin NOT NULL (fuera de
--     alcance) — si el padre no tiene account_id, la línea queda igual.
--     Idempotente por construcción: el WHERE ya filtra account_id IS NULL,
--     así que una segunda corrida afecta 0 filas.
--
-- Estado verificado en prod antes de esta migración (2026-08-18, SELECT):
--   58 operation_created huérfanos (41 purchase, 12 sale, 5 expense) · 0
--   duplicados · 23 sale_items con account_id nulo · 18 purchase_items con
--   account_id nulo.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- (a) analytics_events: huérfanos + duplicados de operation_created.
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_orphans_deleted integer;
  v_dupes_deleted   integer;
BEGIN
  -- Huérfanos: clave de entidad (cualquiera de las dos formas de payload)
  -- sin fila en sales, purchases NI expenses.
  WITH keyed AS (
    SELECT id,
           COALESCE(
             event_data->>'entity_id',
             event_data->>'sale_id',
             event_data->>'purchase_id',
             event_data->>'expense_id'
           ) AS entity_key
    FROM   public.analytics_events
    WHERE  event_name = 'operation_created'
  ),
  orphans AS (
    SELECT k.id
    FROM   keyed k
    WHERE  k.entity_key IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM public.sales     s WHERE s.id::text = k.entity_key)
      AND  NOT EXISTS (SELECT 1 FROM public.purchases p WHERE p.id::text = k.entity_key)
      AND  NOT EXISTS (SELECT 1 FROM public.expenses  e WHERE e.id::text = k.entity_key)
  )
  DELETE FROM public.analytics_events ae
  USING  orphans o
  WHERE  ae.id = o.id;

  GET DIAGNOSTICS v_orphans_deleted = ROW_COUNT;
  RAISE NOTICE 'deudas-menores-agosto (G4a): % eventos operation_created huérfanos borrados', v_orphans_deleted;

  -- Duplicados: más de un evento por clave de entidad → conservar el más
  -- antiguo (created_at ASC, desempate por id para determinismo).
  WITH keyed AS (
    SELECT id, created_at,
           COALESCE(
             event_data->>'entity_id',
             event_data->>'sale_id',
             event_data->>'purchase_id',
             event_data->>'expense_id'
           ) AS entity_key
    FROM   public.analytics_events
    WHERE  event_name = 'operation_created'
  ),
  ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY entity_key ORDER BY created_at ASC, id ASC) AS rn
    FROM   keyed
    WHERE  entity_key IS NOT NULL
  ),
  dupes AS (
    SELECT id FROM ranked WHERE rn > 1
  )
  DELETE FROM public.analytics_events ae
  USING  dupes d
  WHERE  ae.id = d.id;

  GET DIAGNOSTICS v_dupes_deleted = ROW_COUNT;
  RAISE NOTICE 'deudas-menores-agosto (G4a): % eventos operation_created duplicados por clave de entidad borrados (conservado el más antiguo por clave)', v_dupes_deleted;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- (b) Backfill de account_id en sale_items / purchase_items desde el padre.
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_sale_items_backfilled     integer;
  v_purchase_items_backfilled integer;
BEGIN
  UPDATE public.sale_items si
  SET    account_id = s.account_id
  FROM   public.sales s
  WHERE  s.id = si.sale_id
    AND  si.account_id IS NULL
    AND  s.account_id IS NOT NULL;

  GET DIAGNOSTICS v_sale_items_backfilled = ROW_COUNT;
  RAISE NOTICE 'deudas-menores-agosto (G4b): % filas de sale_items backfilleadas con el account_id de su venta padre', v_sale_items_backfilled;

  UPDATE public.purchase_items pi
  SET    account_id = p.account_id
  FROM   public.purchases p
  WHERE  p.id = pi.purchase_id
    AND  pi.account_id IS NULL
    AND  p.account_id IS NOT NULL;

  GET DIAGNOSTICS v_purchase_items_backfilled = ROW_COUNT;
  RAISE NOTICE 'deudas-menores-agosto (G4b): % filas de purchase_items backfilleadas con el account_id de su compra padre', v_purchase_items_backfilled;
END;
$$;
