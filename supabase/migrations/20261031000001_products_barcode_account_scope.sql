-- =============================================================================
-- MIGRATION: 20261031000001_products_barcode_account_scope.sql
-- CHANGE:    Candidato heredado de `productos-categorias-sku` (task 4.5) —
--            "idx_products_barcode_unique alcanzado por user_id" (ver
--            CLAUDE.md §"Candidatos para el próximo /opsx:propose" y
--            CHANGES.md, ítem 24).
--
-- QUÉ HACE
--   Repite para `products.barcode` exactamente el mismo swap de alcance que
--   `20261023000001_productos_categorias_sku.sql` (§5) ya hizo para el SKU:
--   el índice único parcial de código de barras pasa de estar alcanzado por
--   `user_id` a estarlo por `account_id`. El catálogo de productos es de la
--   CUENTA, no del usuario individual — dos miembros de la misma cuenta hoy
--   podrían crear dos productos vivos con el mismo código de barras sin que
--   el índice lo impida (mismo residuo de tenencia que tenía el SKU antes de
--   ese change).
--
--   1. Verificación defensiva: si con el criterio nuevo (account_id, barcode)
--      hay colisiones entre filas vivas, ABORTA ruidosamente antes de tocar
--      el índice — molde exacto de la verificación de SKU (§5a de la
--      migración de referencia). Medido en prod 2026-09-07: 192 códigos de
--      barras activos, 0 colisiones por cuenta, 0 repetidos entre cuentas
--      → el cambio es seguro, pero el DO $$ defensivo se deja igual (nunca
--      confiar en una medición pasada como garantía de un futuro reapply).
--   2. Índice nuevo `idx_products_barcode_account_unique` UNIQUE
--      (account_id, barcode) WHERE barcode IS NOT NULL AND barcode <> '' AND
--      deleted_at IS NULL — mismo predicado que el índice viejo (no se toca
--      la semántica de "vacío/NULL no es código de barras", ni la de soft
--      delete ya vigente desde 20260811000001).
--   3. `DROP INDEX IF EXISTS idx_products_barcode_unique` — no conviven dos
--      reglas de unicidad discrepantes para la misma columna (mismo
--      razonamiento que §5c de la migración de referencia para el SKU).
--
--   Nota: a diferencia del SKU, la comparación de barcode NO es
--   case-insensitive (nunca lo fue — el índice viejo tampoco usaba
--   `lower()`), así que este cambio NO introduce `lower(barcode)`: sólo
--   mueve el alcance de `user_id` a `account_id`, sin tocar ningún otro eje.
--
-- QUÉ NO TOCA
--   `rpc_bulk_upsert_products` no usa `ON CONFLICT ON CONSTRAINT` sobre este
--   índice (INSERT/UPDATE plano con excepción atrapada aparte) — verificado
--   por grep, cero referencias por nombre al índice viejo en SQL. La
--   traducción del 23505 a un 409 legible en
--   `backend/services/products.py::_translate_unique_violation` SÍ compara
--   `constraint_name` contra el nombre del índice — se actualiza en el mismo
--   PR (no es superficie SQL, pero es el único otro lugar del repo que
--   conocía el nombre viejo). `product_repository.py::search_by_barcode` ya
--   filtraba por `account_id` desde antes — no requiere cambios.
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE
--   La integración GitHub de Supabase auto-aplica y puede reaplicar: el DO $$
--   defensivo vuelve a medir contra el estado vivo (si la primera corrida ya
--   dropeó el índice viejo, la segunda corrida encuentra 0 colisiones igual,
--   `CREATE UNIQUE INDEX IF NOT EXISTS` y `DROP INDEX IF EXISTS` son no-ops).
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
-- ROLLBACK: recrear `idx_products_barcode_unique` (criterio más laxo, no
--   puede fallar) y dropear `idx_products_barcode_account_unique`.
-- =============================================================================

-- 1. Verificación defensiva: colisiones por cuenta con el criterio nuevo.
DO $$
DECLARE
  v_collisions integer;
  v_detail     text;
BEGIN
  SELECT COUNT(*), string_agg(format('%s/%s (%s)', c.account_id, c.barcode, c.n), '; ')
    INTO v_collisions, v_detail
    FROM (
      SELECT account_id, barcode, COUNT(*) AS n
        FROM public.products
       WHERE barcode IS NOT NULL AND barcode <> '' AND deleted_at IS NULL
       GROUP BY account_id, barcode
      HAVING COUNT(*) > 1
    ) c;

  IF v_collisions > 0 THEN
    RAISE EXCEPTION 'products-barcode-account-scope: % colisiones de código de barras por cuenta impiden crear idx_products_barcode_account_unique — resolver a mano antes de reaplicar: %',
      v_collisions, v_detail;
  END IF;
END $$;

-- 2. Índice nuevo (account_id, barcode) sobre filas vivas con código de barras.
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_barcode_account_unique
    ON public.products (account_id, barcode)
    WHERE barcode IS NOT NULL AND barcode <> '' AND deleted_at IS NULL;

-- 3. El índice viejo por user_id se retira: no conviven dos reglas de
--    unicidad discrepantes. `idx_products_barcode` (no único, búsqueda de
--    scan-to-cart) se conserva intacto.
DROP INDEX IF EXISTS public.idx_products_barcode_unique;
