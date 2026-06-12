-- ============================================================
-- C-21 v20-inventory-unification: Migración A (no destructiva)
-- Push 1 — NO aplicar sin aprobación del PO
-- ============================================================
-- Incluye:
--   Grupo 1: Branch por defecto para cuentas sin branch
--   Grupo 2: Reconciliación products.stock → branch_stock
--   Grupo 3: Vista de compatibilidad v_products_with_stock
--
-- NUNCA aplicar vía MCP apply_migration.
-- Usar: npx supabase db push (proyecto gxdhpxvdjjkmxhdkkwyb)
--
-- Rollback (si es necesario antes del DROP de products.stock):
--   DROP VIEW IF EXISTS v_products_with_stock;
--   -- Los datos de branch_stock insertados en esta migración se pueden
--   -- quitar con: DELETE FROM branch_stock WHERE created_at >= '<timestamp>';
--   -- No afecta los datos preexistentes.
-- ============================================================

-- ─── Grupo 1: Branch por defecto ──────────────────────────────────────────────
--
-- Test/gate 1.1: tras la migración, toda cuenta tiene ≥ 1 branch
--   Verificar con: SELECT count(*) FROM accounts a
--     WHERE NOT EXISTS (SELECT 1 FROM branches b WHERE b.account_id = a.id)
--   Debe ser 0.
--
-- Test/gate 1.2: idempotencia — re-ejecutar no duplica branches
--   Verificar con: SELECT account_id, count(*) FROM branches GROUP BY account_id HAVING count(*) > 1
--   Debe retornar 0 filas.
--
-- Decisión OQ-A (resuelta 2026-06-12):
--   - 12 cuentas con "Principal" → la conservan como branch por defecto (sin is_default column).
--   - 14 cuentas sin branch → se les crea "Casa Central".
--   - NO se agrega columna is_default (diferido a C-26).

INSERT INTO branches (account_id, name, is_active)
SELECT a.id, 'Casa Central', true
FROM accounts a
WHERE NOT EXISTS (
    SELECT 1 FROM branches b WHERE b.account_id = a.id
);

-- ─── Grupo 2: Reconciliación products.stock → branch_stock ───────────────────
--
-- Test/gate 2.1 (RED → GREEN):
--   Antes: SELECT count(*) FROM products p
--     WHERE p.deleted_at IS NULL
--       AND p.stock <> COALESCE((SELECT SUM(quantity) FROM branch_stock bs WHERE bs.product_id = p.id), 0)
--   Arranca en 636 (RED). Debe quedar en 0 (GREEN) tras este bloque.
--
-- Test/gate 2.2: producto con products.stock > 0 y sin fila branch_stock
--   → tiene fila en (product, branch por defecto) con quantity = products.stock
--
-- Test/gate 2.3: idempotencia — re-ejecutar deja Σ branch_stock idéntico
--   (upsert ON CONFLICT DO UPDATE solo actualiza si el valor cambió)
--
-- Decisión OQ-B (resuelta 2026-06-12):
--   products.stock es autoritativo. Se ajusta la fila de la default branch para que
--   Σ branch_stock == products.stock (preserva el stock visible hoy).
--   Para los 7 con fila existente pero suma diferente: se usa SET quantity = products.stock
--   (trata products.stock como total autoritativo; reemplaza el valor stale del Sistema B).
--
-- La "branch por defecto" de una cuenta = la única branch de la cuenta (convención C-21).
-- Si una cuenta tiene varias branches, se elige la de menor created_at (la más antigua = la original).

WITH default_branch AS (
    -- Una branch por cuenta: la más antigua (o la única)
    SELECT DISTINCT ON (account_id)
        account_id,
        id AS branch_id
    FROM branches
    ORDER BY account_id, created_at ASC
),
divergentes AS (
    -- Productos no borrados cuyo products.stock ≠ Σ branch_stock
    SELECT
        p.id           AS product_id,
        p.account_id,
        p.stock        AS target_quantity
    FROM products p
    WHERE p.deleted_at IS NULL
      AND p.stock <> COALESCE(
          (SELECT SUM(quantity) FROM branch_stock bs WHERE bs.product_id = p.id),
          0
      )
)
INSERT INTO branch_stock (account_id, product_id, branch_id, quantity, min_stock)
SELECT
    d.account_id,
    d.product_id,
    db.branch_id,
    d.target_quantity,
    COALESCE(p.min_stock, 0)
FROM divergentes d
JOIN default_branch db ON db.account_id = d.account_id
JOIN products p        ON p.id = d.product_id
ON CONFLICT (product_id, branch_id)
    DO UPDATE SET
        quantity  = EXCLUDED.quantity,
        min_stock = EXCLUDED.min_stock;

-- ─── Validación post-reconciliación (assertion) ───────────────────────────────
-- Test/gate 2.5: si esta query retorna > 0, la migración falla.
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT count(*) INTO v_count
    FROM products p
    WHERE p.deleted_at IS NULL
      AND p.stock <> COALESCE(
          (SELECT SUM(quantity) FROM branch_stock bs WHERE bs.product_id = p.id),
          0
      );
    IF v_count > 0 THEN
        RAISE EXCEPTION
            'C-21 assertion failed: % productos siguen con products.stock ≠ Σ branch_stock tras reconciliación. Rollback.',
            v_count;
    END IF;
END $$;

-- ─── Grupo 2.6: Índices de soporte ───────────────────────────────────────────
-- Los índices (product_id, branch_id) y (account_id, branch_id) ya existen en branch_stock:
--   branch_stock_product_branch_idx  → (product_id, branch_id)
--   branch_stock_account_branch_idx  → (account_id, branch_id)
-- No se requieren índices adicionales.

-- ─── Grupo 3: Vista de compatibilidad ────────────────────────────────────────
--
-- Test/gate 3.1: un usuario solo ve sus propios productos/stock vía la vista
--   (RLS respetada por security_invoker — NO bypasea RLS como lo haría SECURITY DEFINER)
--
-- Test/gate 3.2: para un producto con stock en 2 branches, la vista devuelve SUM correcto
--
-- Decisión OQ-C (resuelta 2026-06-12):
--   El campo se expone como "stock" (drop-in: los consumidores solo cambian
--   la tabla, no el nombre del campo).
--
-- security_invoker = true: crítico — sin esto la vista bypassea RLS y expone datos
--   cross-tenant. El security advisor de Supabase lo marca explícitamente.
--
-- La vista sobrevive al DROP de products.stock (Grupo 9): la columna stock de products
--   no participa en la definición; el stock se calcula desde branch_stock.

DROP VIEW IF EXISTS v_products_with_stock;

CREATE VIEW v_products_with_stock
WITH (security_invoker = true)
AS
SELECT
    p.*,
    COALESCE(
        (SELECT SUM(bs.quantity)
         FROM branch_stock bs
         WHERE bs.product_id = p.id),
        0
    ) AS stock
FROM products p;

COMMENT ON VIEW v_products_with_stock IS
    'C-21: Vista de compatibilidad — expone products.* con stock = COALESCE(Σ branch_stock.quantity, 0). '
    'security_invoker = true (no bypasea RLS). '
    'Sobrevive al DROP de products.stock (C-21 Grupo 9). '
    'Campo stock es drop-in: consumidores solo cambian .from(''products'') por .from(''v_products_with_stock'').';

-- ─── Verificación final de la vista ─────────────────────────────────────────
-- Confirmar que la vista existe y tiene security_invoker activo.
-- (No hay assertion SQL directa para security_invoker en PG; se verifica con get_advisors
--  tras el push o con: SELECT viewname, definition FROM pg_views WHERE viewname = 'v_products_with_stock')
