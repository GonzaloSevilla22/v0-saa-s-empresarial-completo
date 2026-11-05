-- =============================================================================
-- productos-padre-variantes — TANDA A (DB + backend), governance MEDIO con un
-- tramo ALTO (la salida del guard de unidad base, sección 3).
--
-- Qué hace (design.md D3, D5, D6, D8, D9):
--   1. product_round_price(numeric): la UNA definición SQL del redondeo de precios
--      a pesos enteros (mitad hacia afuera del cero). La comparte, por tabla de
--      casos, con frontend/lib/product-pricing.ts (tanda B).
--   2. Padre sin precio/costo: backfill AUDITADO de los padres variant_only con
--      precio o costo (price = 0, cost = NULL; una fila product.parent_price_cleared
--      por producto con los valores anteriores) y CHECK
--      products_variant_only_no_price_cost. Sin herencia de precio/costo.
--   3. fn_product_base_unit_guard: re-derivado del cuerpo VIVO de prod, con UN
--      corte nuevo (GUC local products.unit_relabel_root atado a la raíz).
--   4. rpc_relabel_product_unit: corrección de la unidad de una familia SIN
--      convertir cantidades (relabel), con dry-run, rol, auditoría y conflicto.
--   5. rpc_bulk_adjust_prices: modificación de precios en lote con dry-run.
--   6. rpc_bulk_upsert_products: la rama Padre del importador fuerza
--      price = 0 y cost = NULL (el CHECK de 2 no admite otra cosa).
--
-- Reaplicable (idempotente): CREATE OR REPLACE / DROP IF EXISTS + CREATE, el
-- backfill sólo toca filas que aún no cumplen y el CHECK se agrega sólo si falta.
-- El gate supabase/tests/test_productos_padre_variantes.sql la reaplica con \i.
--
-- Rollback (design.md, Migration Plan §4): DROP CONSTRAINT del CHECK; DROP
-- FUNCTION de las dos RPCs y del helper; restaurar el cuerpo previo del guard
-- (el de 20261069000001_remitos_venta.sql) y el del importador (el de
-- 20261086000001). El backfill no se revierte: los valores anteriores quedan en
-- audit_logs (action = 'product.parent_price_cleared').
-- =============================================================================

-- =============================================================================
-- 1. Redondeo de precios (D9)
-- =============================================================================
DROP FUNCTION IF EXISTS public.product_round_price(numeric);
CREATE FUNCTION public.product_round_price(p_value numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $function$
  SELECT round(p_value, 0)
$function$;

COMMENT ON FUNCTION public.product_round_price(numeric) IS
  $c$productos-padre-variantes (D9): UNA sola definición SQL del redondeo de precios a pesos enteros — round(numeric, 0), la mitad se aleja del cero (0,5 -> 1; 2,5 -> 3; -0,5 -> -1). Su par en TypeScript es roundToPesos (frontend/lib/product-pricing.ts); la paridad la sostiene supabase/tests/fixtures/product_round_price_cases.json. La usa rpc_bulk_adjust_prices; ningún otro camino redondea precios por su cuenta.$c$;

REVOKE ALL ON FUNCTION public.product_round_price(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_round_price(numeric) TO authenticated, service_role;

-- =============================================================================
-- 2. Padre sin precio ni costo (D3): backfill auditado + CHECK
-- =============================================================================
-- Incluye las filas borradas (deleted_at no nulo) para que el CHECK valide sin
-- NOT VALID. No reescribe ninguna línea de venta, compra ni presupuesto.
DO $backfill$
BEGIN
  INSERT INTO public.audit_logs (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  SELECT p.account_id, NULL, 'product.parent_price_cleared', 'product', p.id,
         jsonb_build_object(
           'price_before', p.price,
           'cost_before',  p.cost,
           'was_deleted',  p.deleted_at IS NOT NULL,
           'source',       'migration:20261093000001_productos_padre_variantes'),
         now()
    FROM public.products p
   WHERE p.stock_control_type = 'variant_only'
     AND (p.price IS DISTINCT FROM 0 OR p.cost IS NOT NULL);

  UPDATE public.products
     SET price = 0,
         cost  = NULL
   WHERE stock_control_type = 'variant_only'
     AND (price IS DISTINCT FROM 0 OR cost IS NOT NULL);
END
$backfill$;

DO $check$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.products'::regclass
                    AND conname = 'products_variant_only_no_price_cost') THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_variant_only_no_price_cost
      CHECK (stock_control_type IS DISTINCT FROM 'variant_only' OR (price = 0 AND cost IS NULL));
  END IF;
END
$check$;

COMMENT ON CONSTRAINT products_variant_only_no_price_cost ON public.products IS
  $c$productos-padre-variantes (D3): un producto padre variant_only no lleva precio ni costo — price = 0 y cost NULL para cualquier escritor (API, PostgREST, importador, función futura). El precio y el costo viven en cada variante; NO se heredan del padre. El servidor traduce el 23514 a 422 parent_field_not_allowed.$c$;
