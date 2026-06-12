-- ============================================================
-- C-21 v20-inventory-unification — Checkpoint #1 aprobado por el PO (2026-06-12)
-- DROP definitivo del Sistema B: inventory_stock, inventory_movements, warehouses
--
-- Contexto:
--   - Los guards de verificación quedan documentados en 20260620000003
--     (no destructivo, ya aplicado en prod como no-op — NO reutilizar ese archivo).
--   - Las 19 filas de inventory_stock, 22 de inventory_movements y 6 de warehouses
--     son duplicados stale: su información ya vive en branch_stock desde el cutover
--     de 2026-06-12 (Migración A + backfill de account_id, PR #157).
--   - 0 consumidores externos: ningún código de frontend ni backend referencia
--     estas tablas tras la migración de lecturas (Grupos 4 y 5 del apply).
--   - Rollback: restaurar desde backup de Supabase de la fecha del DROP.
--     NO re-insertar en branch_stock (los datos de Sistema B eran stale).
--
-- NUNCA aplicar vía MCP apply_migration — siempre npx supabase db push.
-- ============================================================

DO $$
DECLARE
  v_view_exists       boolean;
  v_divergentes       integer;
  v_fk_externas       integer;
BEGIN

  -- ── Guard 1: la vista de compatibilidad existe (nuevo camino de lectura) ──────
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.views
    WHERE table_schema = 'public'
      AND table_name   = 'v_products_with_stock'
  ) INTO v_view_exists;

  IF NOT v_view_exists THEN
    RAISE EXCEPTION
      'Guard fallido: la vista v_products_with_stock no existe. '
      'El nuevo camino de lectura de stock no está instalado. '
      'Aplicar primero la Migración A (20260620000001).';
  END IF;

  -- ── Guard 2: 0 divergentes products.stock vs Σ branch_stock ──────────────────
  -- En una DB de CI recién inicializada (stubs vacíos) esta suma es trivialmente 0.
  -- En prod debe ser 0 desde el cutover del 2026-06-12.
  SELECT COUNT(*) INTO v_divergentes
  FROM public.products p
  WHERE p.deleted_at IS NULL
    AND p.stock <> COALESCE(
      (SELECT SUM(bs.quantity)
       FROM public.branch_stock bs
       WHERE bs.product_id = p.id),
      0
    );

  IF v_divergentes > 0 THEN
    RAISE EXCEPTION
      'Guard fallido: % productos con products.stock <> Σ branch_stock. '
      'El backfill de reconciliación no está completo. '
      'Verificar Migración A y el período de observación (Grupo 7) antes del DROP.',
      v_divergentes;
  END IF;

  -- ── Guard 3: ninguna FK externa apunta a las tablas del Sistema B ─────────────
  -- Excluimos las FK entre las propias tablas del trío (inventory_stock ↔ warehouses,
  -- inventory_movements ↔ warehouses) para no auto-bloquearnos.
  SELECT COUNT(*) INTO v_fk_externas
  FROM information_schema.referential_constraints rc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = rc.constraint_name
   AND kcu.constraint_schema = rc.constraint_schema
  JOIN information_schema.key_column_usage kcu_ref
    ON kcu_ref.constraint_name       = rc.unique_constraint_name
   AND kcu_ref.constraint_schema     = rc.unique_constraint_schema
   AND kcu_ref.ordinal_position      = kcu.position_in_unique_constraint
  WHERE kcu_ref.table_schema = 'public'
    AND kcu_ref.table_name   IN ('inventory_stock', 'inventory_movements', 'warehouses')
    -- excluir FK internas al propio trío
    AND kcu.table_name NOT IN ('inventory_stock', 'inventory_movements', 'warehouses');

  IF v_fk_externas > 0 THEN
    RAISE EXCEPTION
      'Guard fallido: % FK externas apuntan a tablas del Sistema B. '
      'Existen dependencias no migradas. Revisar y eliminar antes del DROP.',
      v_fk_externas;
  END IF;

END $$;

-- ── DROP en orden seguro respecto a dependencias entre el trío ────────────────
-- inventory_stock referencia warehouses y product_variants
-- inventory_movements referencia warehouses
-- warehouses no tiene referencias entrantes fuera del trío (guard 3 lo confirma)
--
-- CASCADE barre únicamente los objetos propios de estas tablas
-- (triggers, índices, políticas RLS, secuencias internas).
-- El guard 3 garantizó que no hay FK externas que CASCADE pueda silenciosamente
-- invalidar.

DROP TABLE IF EXISTS public.inventory_stock CASCADE;
DROP TABLE IF EXISTS public.inventory_movements CASCADE;
DROP TABLE IF EXISTS public.warehouses CASCADE;

-- ── DROP de la función trigger del Sistema B ──────────────────────────────────
-- update_inventory_stock() era el trigger function de Sistema B:
-- disparaba en INSERT/UPDATE sobre inventory_movements y hacía upsert en
-- inventory_stock. Al DROP de inventory_movements el trigger ya no existe,
-- pero la función sigue en catálogo hasta que se elimine explícitamente.
DROP FUNCTION IF EXISTS public.update_inventory_stock() CASCADE;

-- ── Post-DROP (pasos manuales a cargo del PO tras el merge) ───────────────────
-- 1. Confirmar 0 errores en Render + Vercel post-deploy.
-- 2. Regenerar tipos TypeScript:
--    npx supabase gen types typescript --project-id gxdhpxvdjjkmxhdkkwyb \
--      > frontend/lib/database.types.ts
-- 3. Correr get_advisors (security + performance) en el proyecto prod.
-- 4. Marcar tasks 8.3/8.4/8.5 como [x] en tasks.md y avanzar al Checkpoint #2.
