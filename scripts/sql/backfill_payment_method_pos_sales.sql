-- =============================================================================
-- backfill_payment_method_pos_sales.sql
--
-- metodos-pago-operaciones (OQ-5) — sign-off PO 2026-08-19: SÍ backfillear
-- las ventas nacidas en el POS, porque el dato YA está declarado por el
-- usuario en su orden (`sales_orders.payment_method`), no se inventa nada.
--
-- QUÉ HACE
--   UPDATE public.sales.payment_method_id para las filas cuya OPERACIÓN nació
--   en el POS (via sales_orders.sale_operation_id = sales.operation_id),
--   mapeando el texto legacy de la orden a la forma de pago sembrada con ese
--   `kind` EN LA MISMA CUENTA: cash → Efectivo, other → Otro. Sólo toca filas
--   con payment_method_id IS NULL (nunca pisa una imputación explícita).
--
-- NO ES UNA MIGRACIÓN. El merge a main aplica migraciones automáticamente y
-- este backfill de datos firmado por el PO no puede viajar en ese tren — se
-- ejecuta a mano UNA sola vez, con los conteos a la vista, contra el proyecto
-- prod real (gxdhpxvdjjkmxhdkkwyb) vía MCP execute_sql, o localmente con:
--   psql "$DATABASE_URL" -f scripts/sql/backfill_payment_method_pos_sales.sql
--
-- ALCANCE ESPERADO (verificado por SELECT el 2026-08-19)
--   63 sales_orders con payment_method='cash' + 57 con 'other' = 120. Cada
--   orden corresponde a 1 operación de venta (sale_operation_id), y cada
--   operación puede tener 1+ filas en `sales` (todas comparten el mismo
--   operation_id) — el UPDATE alcanza a TODAS las filas de esa operación,
--   consistente con D3 (la forma de pago es por operación, no por línea).
--
-- TOLERANCIA — 3 sales_orders sin operación viva (decisión PO 2026-08-19)
--   3 sales_orders cuelgan de un sale_operation_id que ya no tiene ninguna
--   fila en `sales` (huérfanas de un borrado previo). El JOIN normal las
--   salta en silencio — no son un error de este script, y NO se crea nada
--   para "resolverlas". El conteo de abajo las hace visibles sin bloquear.
--
-- IDEMPOTENTE
--   El UPDATE sólo toca payment_method_id IS NULL — re-ejecutar el script no
--   vuelve a tocar las filas ya backfilleadas (0 filas afectadas la 2da vez).
--
-- ROLLBACK
--   UPDATE public.sales SET payment_method_id = NULL
--   WHERE operation_id IN (
--     SELECT so.sale_operation_id FROM public.sales_orders so
--     WHERE so.payment_method IN ('cash','other')
--   );
--   (vuelve todo a "Sin especificar" — no destruye ningún otro dato).
-- =============================================================================

-- ── Conteos ANTES (dry-run) ──────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM public.sales_orders WHERE payment_method = 'cash')  AS ordenes_cash,
  (SELECT count(*) FROM public.sales_orders WHERE payment_method = 'other') AS ordenes_other,
  (SELECT count(*) FROM public.sales s
     JOIN public.sales_orders so ON so.sale_operation_id = s.operation_id
     WHERE so.payment_method IN ('cash','other') AND s.payment_method_id IS NULL)
    AS filas_sales_a_actualizar,
  (SELECT count(*) FROM public.sales_orders so
     WHERE so.payment_method IN ('cash','other')
       AND NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.operation_id = so.sale_operation_id))
    AS ordenes_huerfanas_sin_operacion_viva_tolerado_PO_20260819;

BEGIN;

UPDATE public.sales s
SET    payment_method_id = pm.id
FROM   public.sales_orders so
JOIN   public.payment_methods pm
       ON pm.account_id = s.account_id
      AND pm.kind        = so.payment_method
      AND pm.deleted_at  IS NULL
WHERE  so.sale_operation_id = s.operation_id
  AND  so.payment_method IN ('cash', 'other')
  AND  s.payment_method_id IS NULL;

COMMIT;

-- ── Conteos DESPUÉS (esperado: 0 pendientes; re-ejecución también da 0) ─────
SELECT
  (SELECT count(*) FROM public.sales s
     JOIN public.sales_orders so ON so.sale_operation_id = s.operation_id
     WHERE so.payment_method IN ('cash','other') AND s.payment_method_id IS NULL)
    AS filas_sales_pendientes,
  (SELECT count(*) FROM public.sales s
     JOIN public.sales_orders so ON so.sale_operation_id = s.operation_id
     JOIN public.payment_methods pm ON pm.id = s.payment_method_id
     WHERE so.payment_method = 'cash' AND pm.kind = 'cash')
    AS filas_sales_backfilleadas_efectivo,
  (SELECT count(*) FROM public.sales s
     JOIN public.sales_orders so ON so.sale_operation_id = s.operation_id
     JOIN public.payment_methods pm ON pm.id = s.payment_method_id
     WHERE so.payment_method = 'other' AND pm.kind = 'other')
    AS filas_sales_backfilleadas_otro;
