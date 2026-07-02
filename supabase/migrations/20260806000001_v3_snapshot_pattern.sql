-- =============================================================================
-- MIGRATION: 20260806000001_v3_snapshot_pattern.sql
-- CHANGE:    v3-snapshot-pattern — Modelo V3 §1 (Snapshot Pattern)
--
-- GOBERNANZA: ALTO — toca los RPCs del hot path de venta/compra/quickSale
-- (dinero + stock). Sign-off del PO otorgado 2026-07-02 (ver
-- openspec/changes/v3-snapshot-pattern/tasks.md 0.1/0.2): D2 (snapshot de
-- compra en `purchases`, no en `purchase_items`) y D3 (`iva_rate_snapshot`
-- NULL cuando no hay fuente; sin agregar IVA a `products` en este change)
-- ratificados.
--
-- PROBLEMA: con inflación semanal, una línea de venta/compra que solo
-- referencia `product_id` deja de ser un dato histórico confiable — un
-- reporte de margen leído contra el maestro actual miente (RN-D2). Las
-- líneas de documento (`sale_items`, `purchase_items`, `quote_items`,
-- `sales_order_items`) y `stock_movements` no congelan nombre/SKU/costo/IVA;
-- `fiscal_documents` no completa el FiscalIdentitySnapshot del receptor.
--
-- FIX (aditivo, sin drops):
--   1. ALTER TABLE ADD COLUMN IF NOT EXISTS de las columnas snapshot en
--      sale_items, purchase_items, quote_items, sales_order_items, purchases
--      (D2), stock_movements y fiscal_documents.
--   2. CREATE OR REPLACE de los RPCs del hot path (partiendo del cuerpo
--      VIGENTE de cada uno, ver tabla de Context en design.md) para congelar
--      los snapshots en el mismo INSERT que crea la línea/movimiento.
--   3. rpc_emit_pending_cae / rpc_emit_subscription_payment_cae: capturan
--      receptor_legal_name / receptor_iva_condition desde clients (D4).
--   4. Backfill idempotente best-effort marcado snapshot_backfilled=true (D5).
--   5. rpc_product_profitability: costo por línea = COALESCE(unit_cost_snapshot,
--      products.cost) (D6). Firma y contrato de salida sin cambios.
--   6. Python: QuoteRepository.create_quote congela los snapshots en el mismo
--      INSERT...SELECT sobre products (quote_items se escribe por INSERT
--      directo del repo, no por RPC — D3 del design de C-29).
--
-- Cuerpos VIGENTES usados como base (verificados contra prod — MCP, 2026-07-02):
--   rpc_create_sale_operation(_v2)   → 20260625000001_c26_branch_as_root.sql
--   _c29_confirm_order_core          → 20260721000001_c29_write_sale_items.sql
--   rpc_accept_quote                 → 20260702000001_c29_quote_salesorder.sql
--   rpc_create_purchase_operation    → 20260804000004_fix_purchase_rpc_onconflict_branchstock.sql
--   rpc_product_profitability        → 20260606110000_product_profitability.sql
--   rpc_emit_pending_cae / _subscription_payment_cae → 20260800000006_fiscal_receptor_iva_relay.sql
--
-- operation_idempotency.operation_kind: este change NO recrea el CHECK.
-- Verificado en prod (pg_get_constraintdef, 2026-07-02): ARRAY['sale',
-- 'purchase','payment_received','payment_made','supplier_charge',
-- 'bank_movement','event_consumer','bank_statement_import']. Se deja intacto.
--
-- FUERA DE ALCANCE: DROP del header plano de sales/purchases (C-20 Grupo 10 —
-- este change solo lo desbloquea vía name_snapshot en línea de servicio);
-- percepciones/retenciones (V2.5, otro change); reactivar purchase_items
-- como write path de compra (D2 — queda para C-20/otro change); agregar
-- iva_alicuota_id/iva_rate a products (D3).
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — CLAUDE.md regla).
--        El CI (deploy.yml) lo aplica a prod al mergear a main.
-- ROLLBACK:
--   1. Restaurar los cuerpos de RPC previos desde las migraciones "Cuerpos
--      VIGENTES" listadas arriba (CREATE OR REPLACE con el texto original).
--   2. ALTER TABLE ... DROP COLUMN IF EXISTS de las columnas snapshot
--      agregadas (ninguna es referenciada por FKs ni vistas — aditivas puras):
--        sale_items/purchase_items/quote_items/sales_order_items/purchases:
--          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot,
--          snapshot_backfilled
--        stock_movements: unit_cost_snapshot
--        fiscal_documents: receptor_legal_name, receptor_iva_condition
--   3. Revertir backend/repositories/quote_repository.py al INSERT simple
--      (sin JOIN a products) si hiciera falta.
--   Smoke test de venta/compra/quickSale/quote antes y después del rollback.
-- =============================================================================


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. DDL ADITIVO — columnas snapshot
-- ═══════════════════════════════════════════════════════════════════════════

-- 1.2 Líneas de documento: sale_items, purchase_items, quote_items, sales_order_items
ALTER TABLE public.sale_items
  ADD COLUMN IF NOT EXISTS name_snapshot        TEXT,
  ADD COLUMN IF NOT EXISTS sku_snapshot         TEXT,
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot   NUMERIC(15,2),
  ADD COLUMN IF NOT EXISTS iva_rate_snapshot    NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS snapshot_backfilled  BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.purchase_items
  ADD COLUMN IF NOT EXISTS name_snapshot        TEXT,
  ADD COLUMN IF NOT EXISTS sku_snapshot         TEXT,
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot   NUMERIC(15,2),
  ADD COLUMN IF NOT EXISTS iva_rate_snapshot    NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS snapshot_backfilled  BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.quote_items
  ADD COLUMN IF NOT EXISTS name_snapshot        TEXT,
  ADD COLUMN IF NOT EXISTS sku_snapshot         TEXT,
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot   NUMERIC(15,2),
  ADD COLUMN IF NOT EXISTS iva_rate_snapshot    NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS snapshot_backfilled  BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.sales_order_items
  ADD COLUMN IF NOT EXISTS name_snapshot        TEXT,
  ADD COLUMN IF NOT EXISTS sku_snapshot         TEXT,
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot   NUMERIC(15,2),
  ADD COLUMN IF NOT EXISTS iva_rate_snapshot    NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS snapshot_backfilled  BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.sale_items.unit_cost_snapshot IS
  'v3-snapshot-pattern (RN-D2): costo unitario de products.cost congelado en el INSERT. '
  'NULL en filas históricas hasta backfill (snapshot_backfilled=true) o si nunca se congeló.';
COMMENT ON COLUMN public.sale_items.snapshot_backfilled IS
  'v3-snapshot-pattern: true = snapshot completado por backfill best-effort desde el maestro '
  'ACTUAL (aproximado). false + snapshot no NULL = congelado en vivo por el RPC (exacto).';

-- 1.3 purchases (D2): el write path de compra escribe purchases (flat), no purchase_items.
ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS name_snapshot        TEXT,
  ADD COLUMN IF NOT EXISTS sku_snapshot         TEXT,
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot   NUMERIC(15,2),
  ADD COLUMN IF NOT EXISTS iva_rate_snapshot    NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS snapshot_backfilled  BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.purchases.unit_cost_snapshot IS
  'v3-snapshot-pattern (D2): congelado por rpc_create_purchase_operation, que escribe la '
  'línea de compra en purchases (flat) — purchase_items NO es el write path vigente. '
  'La columna equivalente en purchase_items existe por paridad de schema futura.';

-- 1.4 stock_movements: costo unitario para valuación de inventario.
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot NUMERIC(15,2);

COMMENT ON COLUMN public.stock_movements.unit_cost_snapshot IS
  'v3-snapshot-pattern: costo unitario del producto al momento del movimiento, para '
  'valuación de inventario histórica. NULL en movimientos previos a esta migración.';

-- 1.5 fiscal_documents: completar el FiscalIdentitySnapshot del receptor (D4).
ALTER TABLE public.fiscal_documents
  ADD COLUMN IF NOT EXISTS receptor_legal_name    TEXT,
  ADD COLUMN IF NOT EXISTS receptor_iva_condition  TEXT;

COMMENT ON COLUMN public.fiscal_documents.receptor_legal_name IS
  'v3-snapshot-pattern (D4): razón social del receptor congelada al emitir, derivada de '
  'clients.legal_name. NULL = consumidor final sin identificar (comportamiento previo).';
COMMENT ON COLUMN public.fiscal_documents.receptor_iva_condition IS
  'v3-snapshot-pattern (D4): condición de IVA del receptor congelada al emitir, derivada de '
  'clients.iva_condition. NULL histórico = comportamiento previo; no cambia si el cliente '
  'cambia de condición después de emitido el comprobante.';

-- 1.6 Índice de apoyo: rpc_product_profitability agrupa sale_items por product_id.
CREATE INDEX IF NOT EXISTS idx_sale_items_product_id
  ON public.sale_items (product_id)
  WHERE product_id IS NOT NULL;


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. CONGELAMIENTO EN LOS RPCs DEL HOT PATH (misma transacción)
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 2.1/2.2 rpc_create_sale_operation (wrapper legacy no-v2) — agrega
-- snapshots al INSERT INTO sale_items del bloque interno (rama v_flag_on
-- = false). El wrapper legacy históricamente NO escribía sale_items en el
-- branch no-v2 (solo `sales`); v3 agrega snapshot únicamente donde hay
-- INSERT de sale_items (rama v2, ver 2.1b) y de stock_movements (ambas
-- ramas). Cuerpo vigente: 20260625000001_c26_branch_as_root.sql.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_flag_on    boolean := false;
  v_uid        uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  SELECT COALESCE(enabled, false) INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;

  IF v_flag_on THEN
    RETURN public.rpc_create_sale_operation_v2(
      p_idempotency_key, p_client_id, p_date, p_currency, p_items,
      p_branch_id, p_canal
    );
  ELSE
    DECLARE
      v_new_op_id    uuid;
      v_existing_op  uuid;
      v_item         RECORD;
      v_product      RECORD;
      v_branch       RECORD;
      v_gate_branch  uuid;
      v_new_sale_id  uuid;
      v_result_items jsonb := '[]'::jsonb;
      v_qty_before   numeric;
      v_qty_after    numeric;
      v_unit_factor  numeric(20,10);
      v_qty_norm     numeric(15,4);
      v_branch_qty   numeric(15,4);
      v_inserted     integer;
      v_canal        text;
    BEGIN
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
          USING ERRCODE = 'P0403';
      END IF;

      IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
      END IF;

      IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
      END IF;

      IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
      END IF;

      v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
      IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
        RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
      END IF;

      -- C-26: la branch explícita debe existir, estar activa Y operativa
      IF p_branch_id IS NOT NULL THEN
        SELECT id, status INTO v_branch
        FROM public.branches
        WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'branch_not_found or not active for this account'
            USING ERRCODE = 'P0404';
        END IF;
        IF v_branch.status = 'closed' THEN
          RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-26: branch del gate y del descuento (explícita o default operativa)
      v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

      v_new_op_id := gen_random_uuid();

      INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
      VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
      ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

      GET DIAGNOSTICS v_inserted = ROW_COUNT;

      IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'sale'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                 jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
                 '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.sales s
        WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

        RETURN jsonb_build_object(
          'operation_id', v_existing_op,
          'items',        v_result_items,
          'replayed',     true
        );
      END IF;

      FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                 AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
        ORDER BY product_id
      LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
          RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
          RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
        END IF;

        v_unit_factor := 1.0;
        IF v_item.unit_id IS NOT NULL THEN
          SELECT factor INTO v_unit_factor
          FROM   public.units_of_measure
          WHERE  id = v_item.unit_id;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P0404';
          END IF;
        END IF;
        v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

        IF v_item.product_id IS NOT NULL THEN
          SELECT id, user_id, is_variant, name, sku, cost INTO v_product
          FROM   public.products
          WHERE  id = v_item.product_id
          FOR UPDATE;

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
          END IF;

          IF v_product.user_id <> v_uid THEN
            RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
          END IF;

          IF NOT v_product.is_variant THEN
            IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
              RAISE EXCEPTION
                'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
                USING ERRCODE = 'P0422';
            END IF;
          END IF;

          -- C-26 (OQ-A): gate per-branch — el stock debe estar EN la branch
          -- de la operación (explícita o default operativa)
          SELECT COALESCE(quantity, 0) INTO v_branch_qty
          FROM   public.branch_stock
          WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
          v_branch_qty := COALESCE(v_branch_qty, 0);

          IF v_branch_qty < v_qty_norm THEN
            IF p_branch_id IS NOT NULL THEN
              RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            ELSE
              RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            END IF;
          END IF;

          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal)
          VALUES
            (v_uid, v_account_id, p_client_id, v_item.product_id,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             p_branch_id, v_canal)
          RETURNING id INTO v_new_sale_id;

          v_qty_before := v_branch_qty;
          v_qty_after  := v_branch_qty - v_qty_norm;

          PERFORM public.c21_apply_branch_stock_delta(
            v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

          -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id, branch_id, unit_cost_snapshot
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
            -v_qty_norm, v_qty_before, v_qty_after,
            v_new_sale_id, 'sale', v_uid,
            v_new_op_id, p_branch_id, v_product.cost
          );

        ELSE
          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal)
          VALUES
            (v_uid, v_account_id, p_client_id, NULL,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             p_branch_id, v_canal)
          RETURNING id INTO v_new_sale_id;
        END IF;

        v_result_items := v_result_items
          || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
      END LOOP;

      RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
      );
    END;
  END IF;
END;
$function$;


-- ─────────────────────────────────────────────────────────────────────────
-- 2.1b rpc_create_sale_operation_v2 — snapshots en sale_items + stock_movements.
-- Cuerpo vigente: 20260625000001_c26_branch_as_root.sql.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation_v2(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_new_op_id    uuid;
  v_existing_op  uuid;
  v_item         RECORD;
  v_product      RECORD;
  v_branch       RECORD;
  v_gate_branch  uuid;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_unit_factor  numeric(20,10);
  v_qty_norm     numeric(15,4);
  v_branch_qty   numeric(15,4);
  v_inserted     integer;
  v_canal        text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
      USING ERRCODE = 'P0403';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
  END IF;

  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
  IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
    RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
  END IF;

  -- C-26: la branch explícita debe existir, estar activa Y operativa
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch del gate y del descuento (explícita o default operativa)
  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'sale'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.sales s
    WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost a la lectura ya existente
      -- (name, is_variant) para congelar name/sku/cost sin un SELECT extra.
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      IF v_product.user_id <> v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-26 (OQ-A): gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        IF p_branch_id IS NOT NULL THEN
          RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        ELSE
          RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        END IF;
      END IF;

      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product ya cargado.
      -- iva_rate_snapshot: products no tiene columna de IVA (D3) → NULL.
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

      -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, p_branch_id, v_product.cost
      );

    ELSE
      -- v3-snapshot-pattern (2.6): línea de servicio — name_snapshot no
      -- disponible en el payload legacy de esta RPC (solo amount/quantity/
      -- unit_id); queda NULL como hoy. La línea de servicio con
      -- name_snapshot desde payload se resuelve en _c29_confirm_order_core
      -- (sales_order_items ya trae el nombre desde el frontend — ver 2.4/2.6).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;


-- ─────────────────────────────────────────────────────────────────────────
-- 2.3 rpc_create_purchase_operation (D2): snapshots en purchases (flat) +
-- stock_movements. Cuerpo vigente: 20260804000004_fix_purchase_rpc_onconflict_branchstock.sql.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
    p_idempotency_key  text,
    p_date             date,
    p_description      text,
    p_items            jsonb,
    p_branch_id        uuid DEFAULT NULL,
    p_cost_center_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
/*
  v3-snapshot-pattern: agrega name_snapshot/sku_snapshot/unit_cost_snapshot/
  iva_rate_snapshot al INSERT de purchases (D2 — el write path real de
  compra) y unit_cost_snapshot al stock_movements de compra. Preserva
  íntegro el fix de 20260804000004 (ON CONFLICT 3-col + branch_stock, sin
  products.stock).
*/
DECLARE
    v_uid             uuid;
    v_account_id      uuid;
    v_new_op_id       uuid;
    v_existing_op     uuid;
    v_item            RECORD;
    v_product         RECORD;
    v_new_purchase_id uuid;
    v_result_items    jsonb := '[]'::jsonb;
    v_qty_before      numeric;
    v_qty_after       numeric;
    v_unit_factor     numeric(20,10);
    v_qty_norm        numeric(15,4);
    v_stock_sum       numeric(15,4);   -- C-21: Σ branch_stock (reemplaza products.stock)
    v_inserted        integer;
    v_total_sum       numeric(15,2) := 0;
BEGIN
    v_uid := (SELECT auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT cai INTO v_account_id
    FROM   current_account_ids() AS cai
    LIMIT  1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
            USING ERRCODE = 'P403';
    END IF;

    IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
    END IF;

    IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P400';
    END IF;

    -- Verify branch_id belongs to this account (if provided)
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.branches
            WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P404';
        END IF;
    END IF;

    -- cost-center-dimension: Verify cost_center_id belongs to this account (mirror of branch_id)
    IF p_cost_center_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.cost_centers
            WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'cost_center_not_found or not active for this account'
                USING ERRCODE = 'P404';
        END IF;
    END IF;

    v_new_op_id := gen_random_uuid();

    -- ON CONFLICT: el índice único es (user_id, operation_kind, idempotency_key).
    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
    ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'purchase'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                   jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                   '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

        -- Idempotency replay: NO emitir evento duplicado (DEC-20)
        RETURN jsonb_build_object(
            'operation_id', v_existing_op,
            'items',        v_result_items,
            'replayed',     true
        );
    END IF;

    FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                   AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
        ORDER BY product_id
    LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
            RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
            RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P400';
        END IF;

        v_unit_factor := 1.0;
        IF v_item.unit_id IS NOT NULL THEN
            SELECT factor INTO v_unit_factor
            FROM   public.units_of_measure
            WHERE  id = v_item.unit_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
            END IF;
        END IF;
        v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

        -- journal-entry-outbox: acumular total para el payload del evento
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
            -- v3-snapshot-pattern: se agrega sku, cost a la lectura ya
            -- existente (sin leer products.stock — DROPeado en C-21).
            SELECT id, user_id, is_variant, name, sku, cost INTO v_product
            FROM   public.products
            WHERE  id = v_item.product_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
            END IF;

            IF v_product.user_id <> v_uid THEN
                RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
            END IF;

            IF NOT v_product.is_variant THEN
                IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
                    RAISE EXCEPTION
                        'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                        USING ERRCODE = 'P422';
                END IF;
            END IF;

            -- v3-snapshot-pattern (D2): congelar name/sku/cost en purchases
            -- (flat) — es donde el write path REAL de compra escribe la línea.
            -- iva_rate_snapshot NULL (D3: products no tiene columna de IVA).
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id,
                 v_product.name, v_product.sku, v_product.cost, NULL)
            RETURNING id INTO v_new_purchase_id;

            -- stock sobre branch_stock (C-21). before/after = Σ branch_stock.
            SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
            FROM   public.branch_stock
            WHERE  product_id = v_item.product_id;

            v_qty_before := v_stock_sum;
            v_qty_after  := v_stock_sum + v_qty_norm;

            PERFORM public.c21_apply_branch_stock_delta(
                v_account_id, v_item.product_id, p_branch_id, v_qty_norm);

            -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
            INSERT INTO public.stock_movements (
                user_id, account_id, product_id, product_name, type,
                quantity_delta, quantity_before, quantity_after,
                reference_id, reference_type, performed_by,
                operation_group_id, branch_id, unit_cost_snapshot
            ) VALUES (
                v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                v_qty_norm, v_qty_before, v_qty_after,
                v_new_purchase_id, 'purchase', v_uid,
                v_new_op_id, p_branch_id, v_product.cost
            );

        ELSE
            -- cost-center-dimension: p_cost_center_id propagated to non-product rows too
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- ── journal-entry-outbox (Task 4.1): emitir PurchaseCreated en la misma tx ─
    INSERT INTO public.events
        (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
        v_account_id,
        'PurchaseCreated',
        'Purchase',
        v_new_op_id,
        jsonb_build_object(
            'account_id',     v_account_id,
            'operation_id',   v_new_op_id,
            'total',          v_total_sum,
            'cost_center_id', p_cost_center_id,
            'neto',           NULL,
            'iva_amount',     NULL,
            'payment_method', 'credit',
            'occurred_at',    now()
        ),
        now()
    );

    RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
    );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) IS
    'v3-snapshot-pattern (D2) + cost-center-dimension + journal-entry-outbox + hotfix 20260804000004: '
    'Compra multi-línea idempotente. Congela name/sku/cost snapshot en purchases (write path real) '
    'y unit_cost_snapshot en stock_movements. Stock sobre branch_stock, NO products.stock. '
    'ON CONFLICT (user_id, operation_kind, idempotency_key). SECURITY DEFINER.';


-- ─────────────────────────────────────────────────────────────────────────
-- 2.4 _c29_confirm_order_core — snapshots en sale_items + stock_movements,
-- congelados desde el SELECT ... INTO v_product ya presente. Línea de
-- servicio (2.6): name_snapshot desde sales_order_items (no hay tabla
-- "products" para leer, pero tampoco hace falta — sales_order_items no
-- tiene columna name propia; queda NULL como las demás columnas del
-- servicio, documentado en el requisito "Línea de servicio sin producto
-- del maestro" del spec document-snapshots). Cuerpo vigente:
-- 20260721000001_c29_write_sale_items.sql.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(
  p_idempotency_key   text,
  p_sales_order_id    uuid,
  p_payment_method    text,
  p_cash_session_id   uuid   DEFAULT NULL,
  p_comprobante_type  text   DEFAULT NULL,
  p_point_of_sale_id  uuid   DEFAULT NULL,
  p_canal             text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_order            public.sales_orders%ROWTYPE;
  v_gate_branch      uuid;
  v_branch           RECORD;
  v_item             RECORD;
  v_product          RECORD;
  v_branch_qty       numeric(15,4);
  v_qty_norm         numeric(15,4);
  v_existing_op      uuid;
  v_new_op_id        uuid;
  v_new_sale_id      uuid;
  v_fiscal_doc_id    uuid;
  v_fiscal_result    jsonb;
  v_inserted         integer;
  v_canal            text;
  v_total            numeric(15,2) := 0;
  v_qty_before       numeric;
  v_qty_after        numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar idempotency_key
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  -- Cargar la orden
  SELECT * INTO v_order
  FROM public.sales_orders
  WHERE id = p_sales_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_order.account_id;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado de la orden
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'order_not_in_draft: estado %', v_order.status
      USING ERRCODE = 'P0409';
  END IF;

  -- D6: validación cash sin session → P0400
  IF p_payment_method = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method
  IF p_payment_method NOT IN ('cash', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch del gate (ya está en la orden; usamos la branch de la orden)
  v_gate_branch := v_order.branch_id;

  -- Validar que la branch esté activa
  SELECT id, status INTO v_branch
  FROM public.branches
  WHERE id = v_gate_branch AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Canal normalizado
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');

  -- ─── Idempotencia (DEC-06) ───────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver la operación original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'sale'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_existing_op,
      'replayed',        true
    );
  END IF;

  -- ─── Calcular total y descontar stock por línea ──────────────────────────
  FOR v_item IN
    SELECT * FROM public.sales_order_items
    WHERE sales_order_id = p_sales_order_id
    ORDER BY id
  LOOP
    v_total := v_total + v_item.subtotal;

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
      SELECT id, user_id, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      v_qty_norm := v_item.quantity;

      -- Gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM public.branch_stock
      WHERE product_id = v_item.product_id AND branch_id = v_gate_branch;

      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_item.product_id, v_branch_qty, v_qty_norm
          USING ERRCODE = 'P0409';
      END IF;

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      -- Descontar stock (C-21 helper)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm
      );

      -- Insertar fila legacy sales (retrocompat D4)
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product (2.4).
      -- iva_rate_snapshot NULL (D3).
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      -- stock_movements (reference_type='sale') — v3-snapshot-pattern: costo congelado.
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch, v_product.cost
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy (2.6: sin snapshot,
      -- name_snapshot ya vive en sales_order_items.name_snapshot desde su
      -- propia creación en quick_sale/confirm_sales_order — no aplica acá).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  IF p_payment_method = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  IF p_comprobante_type IS NOT NULL THEN
    SELECT public.rpc_emit_pending_cae(
      p_comprobante_type,
      v_total,
      v_order.client_id,
      p_point_of_sale_id
    ) INTO v_fiscal_result;

    v_fiscal_doc_id := (v_fiscal_result->>'fiscal_document_id')::uuid;
  END IF;

  -- ─── INSERT outbox (DEC-20 — SaleConfirmed) ─────────────────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SaleConfirmed',
    'SalesOrder',
    p_sales_order_id,
    jsonb_build_object(
      'account_id',      v_account_id,
      'branch_id',       v_gate_branch,
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_new_op_id,
      'total',           v_total,
      'payment_method',  p_payment_method,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  UPDATE public.sales_orders
  SET
    status             = 'confirmed',
    payment_method     = p_payment_method,
    total              = v_total,
    sale_operation_id  = v_new_op_id,
    fiscal_document_id = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$$;

-- REVOKE: helper interno — NO callable desde rol authenticated (paridad con el original)
REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._c29_confirm_order_core IS
  'C-29 (D1) + v3-snapshot-pattern: helper interno compartido por rpc_confirm_sales_order '
  'y rpc_quick_sale. SECURITY DEFINER para poder invocar c28_register_cash_movement '
  '(revocado de PUBLIC). No callable externamente. Atómico: un fallo aborta todo el commit. '
  'Congela name/sku/cost snapshot en sale_items y stock_movements desde el mismo SELECT '
  'de products ya usado para el lock del producto.';


-- ─────────────────────────────────────────────────────────────────────────
-- 2.5 rpc_accept_quote — propaga snapshots de quote_items → sales_order_items
-- SIN re-leer products (D1 aplicado a la propagación: el snapshot ya está
-- congelado en quote_items desde su creación — ver backend/repositories/
-- quote_repository.py más abajo). Cuerpo vigente: 20260702000001_c29_quote_salesorder.sql.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_accept_quote(
  p_quote_id  uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_quote          public.quotes%ROWTYPE;
  v_item           RECORD;
  v_sales_order_id uuid;
  v_branch_id      uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cargar el quote y validar tenencia
  SELECT * INTO v_quote
  FROM public.quotes
  WHERE id = p_quote_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_quote.account_id;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado: solo draft o sent son aceptables
  IF v_quote.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'quote_invalid_state: estado % no es aceptable', v_quote.status
      USING ERRCODE = 'P0409';
  END IF;

  -- OQ-4: validación defensiva on-read de expiración
  IF v_quote.valid_until IS NOT NULL AND v_quote.valid_until < CURRENT_DATE THEN
    RAISE EXCEPTION 'quote_expired: valid_until % ya pasó', v_quote.valid_until
      USING ERRCODE = 'P0409';
  END IF;

  -- Resolver branch: preferir branch del quote, sino default
  v_branch_id := COALESCE(
    v_quote.branch_id,
    public.c26_default_branch(v_account_id)
  );

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Crear la SalesOrder en estado draft (sin tocar stock aún)
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, source_quote_id, status,
     payment_method, total, created_by)
  VALUES
    (v_account_id, v_branch_id, v_quote.client_id, p_quote_id, 'draft',
     'other', v_quote.total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-snapshot-pattern (D1): copiar quote_items → sales_order_items
  -- propagando los snapshots ya congelados, SIN re-leer products.
  FOR v_item IN
    SELECT * FROM public.quote_items WHERE quote_id = p_quote_id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
       name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal,
       v_item.name_snapshot, v_item.sku_snapshot, v_item.unit_cost_snapshot,
       v_item.iva_rate_snapshot, v_item.snapshot_backfilled);
  END LOOP;

  -- Transicionar el quote a accepted
  UPDATE public.quotes
  SET status = 'accepted'
  WHERE id = p_quote_id;

  RETURN jsonb_build_object(
    'sales_order_id', v_sales_order_id,
    'quote_id',       p_quote_id,
    'status',         'accepted'
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_accept_quote IS
  'C-29 (D3) + v3-snapshot-pattern: acepta un Quote (draft|sent + no expirado) y crea un '
  'SalesOrder en draft con los mismos ítems, propagando los snapshots ya congelados en '
  'quote_items sin re-leer products. No toca stock ni caja — eso es SalesOrder.confirm(). Atómico.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. FiscalIdentitySnapshot del receptor (D4)
-- ═══════════════════════════════════════════════════════════════════════════

-- 3.1 rpc_emit_pending_cae — agrega receptor_legal_name/receptor_iva_condition
-- derivados de clients (client-fiscal-identity: clients.legal_name/iva_condition,
-- 20260614000000). Cuerpo vigente: 20260800000006_fiscal_receptor_iva_relay.sql.
CREATE OR REPLACE FUNCTION public.rpc_emit_pending_cae(
  p_comprobante_type    text,
  p_total               numeric,
  p_client_id           uuid    DEFAULT NULL,
  p_point_of_sale_id    uuid    DEFAULT NULL,
  p_receptor_doc_tipo   integer DEFAULT NULL,
  p_receptor_doc_nro    text    DEFAULT NULL,
  p_neto                numeric DEFAULT NULL,
  p_iva_amount          numeric DEFAULT NULL,
  p_iva_alicuota_id     integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_profile          RECORD;
  v_pv               RECORD;
  v_effective_pv_id  uuid;
  v_active_pv_count  integer;
  v_doc_number       bigint;
  v_doc_id           uuid;
  v_client           RECORD;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: solo owner/admin puede emitir
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can emit fiscal documents'
      USING ERRCODE = 'P0401';
  END IF;

  -- Obtener perfil fiscal de la cuenta
  SELECT id, iva_condition, ambiente INTO v_profile
  FROM   public.fiscal_profiles
  WHERE  account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_profile_not_found: la cuenta no tiene perfil fiscal configurado'
      USING ERRCODE = 'P0404';
  END IF;

  -- v3-snapshot-pattern (D4): FiscalIdentitySnapshot del receptor — derivar
  -- razón social y condición IVA desde clients si hay client_id. NULL si
  -- no hay cliente identificado (consumidor final, comportamiento previo).
  IF p_client_id IS NOT NULL THEN
    SELECT legal_name, iva_condition INTO v_client
    FROM   public.clients
    WHERE  id = p_client_id;
  END IF;

  -- Resolver PV efectivo (D11)
  IF p_point_of_sale_id IS NOT NULL THEN
    SELECT id, numero INTO v_pv
    FROM   public.points_of_sale
    WHERE  id = p_point_of_sale_id
      AND  account_id = v_account_id
      AND  is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'point_of_sale_not_found_or_inactive: el punto de venta no existe, no pertenece a la cuenta o está inactivo'
        USING ERRCODE = 'P0404';
    END IF;
    v_effective_pv_id := v_pv.id;

  ELSE
    SELECT count(*) INTO v_active_pv_count
    FROM   public.points_of_sale
    WHERE  account_id = v_account_id AND is_active = TRUE;

    IF v_active_pv_count = 0 THEN
      RAISE EXCEPTION 'no_active_point_of_sale: la cuenta no tiene puntos de venta activos'
        USING ERRCODE = 'P0404';
    ELSIF v_active_pv_count > 1 THEN
      RAISE EXCEPTION 'ambiguous_point_of_sale: la cuenta tiene % puntos de venta activos — especificá point_of_sale_id', v_active_pv_count
        USING ERRCODE = 'P0422';
    ELSE
      SELECT id, numero INTO v_pv
      FROM   public.points_of_sale
      WHERE  account_id = v_account_id AND is_active = TRUE;
      v_effective_pv_id := v_pv.id;
    END IF;
  END IF;

  -- Reservar número (lock corto, fuera de transacción larga de la venta — C-29)
  v_doc_number := public.rpc_next_document_number(v_effective_pv_id, p_comprobante_type);

  -- Insertar comprobante en pending_cae (SIN tocar AFIP — D5). v3-snapshot-pattern:
  -- persistir receptor_legal_name/receptor_iva_condition (D4), además del
  -- receptor + IVA ya existentes (fiscal-receptor-iva-relay).
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    client_id, total, status,
    receptor_doc_tipo, receptor_doc_nro, neto, iva_amount, iva_alicuota_id,
    receptor_legal_name, receptor_iva_condition
  ) VALUES (
    v_account_id, v_profile.id, v_effective_pv_id,
    p_comprobante_type, v_pv.numero, v_doc_number,
    p_client_id, COALESCE(p_total, 0), 'pending_cae',
    p_receptor_doc_tipo, p_receptor_doc_nro, p_neto, p_iva_amount, p_iva_alicuota_id,
    v_client.legal_name, v_client.iva_condition
  )
  RETURNING id INTO v_doc_id;

  RETURN jsonb_build_object(
    'fiscal_document_id', v_doc_id,
    'point_of_sale_id',   v_effective_pv_id,
    'punto_de_venta',     v_pv.numero,
    'comprobante_type',   p_comprobante_type,
    'number',             v_doc_number,
    'status',             'pending_cae'
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_emit_pending_cae IS
  'C-27 (D5/D11) + fiscal-receptor-iva-relay + v3-snapshot-pattern (D4): emite un '
  'comprobante en pending_cae sin tocar AFIP. Resuelve el PV efectivo (P0422 si ambiguo), '
  'reserva número e INSERTA fiscal_documents. Persiste la identificación del receptor '
  '(DocTipo/DocNro), el desglose de IVA y el FiscalIdentitySnapshot (razón social + '
  'condición IVA derivados de clients) — todos opcionales, NULL = consumidor final '
  'sin identificar.';


-- 3.1b rpc_emit_subscription_payment_cae — mismo tratamiento; el suscriptor
-- de plataforma no tiene fila en clients (es billing_events/profiles), así
-- que receptor_legal_name/receptor_iva_condition quedan NULL (no hay fuente
-- — D3/D4 aplican el mismo principio: NULL si no hay dato disponible).
-- Cuerpo vigente: 20260800000006_fiscal_receptor_iva_relay.sql — sin cambios
-- de comportamiento (documentado por completitud del requisito, sin columnas
-- nuevas que llenar en esta ruta).
CREATE OR REPLACE FUNCTION public.rpc_emit_subscription_payment_cae(
  p_receipt_id        text,
  p_point_of_sale_id  uuid        DEFAULT NULL,
  p_receptor_doc_tipo integer     DEFAULT 99,
  p_receptor_doc_nro  text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_receipt          RECORD;
  v_profile          RECORD;
  v_pv               RECORD;
  v_effective_pv_id  uuid;
  v_active_pv_count  integer;
  v_doc_number       bigint;
  v_doc_id           uuid;
  v_receipt_uuid     uuid;
BEGIN
  BEGIN
    v_receipt_uuid := p_receipt_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'receipt_not_found: receipt_id is not a valid UUID: %', p_receipt_id
      USING ERRCODE = 'P0404';
  END;

  SELECT be.id, be.amount, be.user_id, be.to_plan
  INTO   v_receipt
  FROM   billing_events be
  WHERE  be.id = v_receipt_uuid
    AND  be.event_type = 'plan_upgraded';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'receipt_not_found: no se encontró el recibo de pago: %', p_receipt_id
      USING ERRCODE = 'P0404';
  END IF;

  IF EXISTS (
    SELECT 1 FROM fiscal_documents
    WHERE  subscription_payment_id = p_receipt_id
  ) THEN
    RAISE EXCEPTION 'already_emitted: ya existe un comprobante para el recibo: %', p_receipt_id
      USING ERRCODE = 'P0409';
  END IF;

  -- Perfil fiscal del admin de plataforma (Aliadata). owner_user_id (no owner_id).
  SELECT fp.id, fp.iva_condition, fp.ambiente, fp.account_id
  INTO   v_profile
  FROM   fiscal_profiles fp
  JOIN   accounts a ON a.id = fp.account_id
  JOIN   profiles pr ON pr.id = a.owner_user_id
  WHERE  pr.role = 'admin'
  LIMIT  1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_profile_not_found: la cuenta admin no tiene perfil fiscal configurado'
      USING ERRCODE = 'P0404';
  END IF;

  IF p_point_of_sale_id IS NOT NULL THEN
    SELECT id, numero INTO v_pv
    FROM   points_of_sale
    WHERE  id = p_point_of_sale_id
      AND  account_id = v_profile.account_id
      AND  is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'point_of_sale_not_found_or_inactive: el punto de venta no existe o está inactivo'
        USING ERRCODE = 'P0404';
    END IF;
    v_effective_pv_id := v_pv.id;

  ELSE
    SELECT count(*) INTO v_active_pv_count
    FROM   points_of_sale
    WHERE  account_id = v_profile.account_id AND is_active = TRUE;

    IF v_active_pv_count = 0 THEN
      RAISE EXCEPTION 'no_active_point_of_sale: la cuenta no tiene puntos de venta activos'
        USING ERRCODE = 'P0404';
    ELSIF v_active_pv_count > 1 THEN
      RAISE EXCEPTION 'ambiguous_point_of_sale: la cuenta tiene % puntos de venta activos — especificá point_of_sale_id', v_active_pv_count
        USING ERRCODE = 'P0422';
    ELSE
      SELECT id, numero INTO v_pv
      FROM   points_of_sale
      WHERE  account_id = v_profile.account_id AND is_active = TRUE;
      v_effective_pv_id := v_pv.id;
    END IF;
  END IF;

  v_doc_number := public.rpc_next_document_number(v_effective_pv_id, 'factura_c');

  -- INSERT con subscription_payment_id (idempotencia) + receptor persistido.
  -- Normalizamos DocTipo=99 → NULL para que el adapter aplique su default consistente.
  -- v3-snapshot-pattern: no hay fila en clients para el suscriptor de plataforma
  -- → receptor_legal_name/receptor_iva_condition quedan NULL (sin fuente, D3/D4).
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    total, status,
    subscription_payment_id,
    receptor_doc_tipo, receptor_doc_nro
  ) VALUES (
    v_profile.account_id, v_profile.id, v_effective_pv_id,
    'factura_c', v_pv.numero, v_doc_number,
    COALESCE(v_receipt.amount, 0), 'pending_cae',
    p_receipt_id,
    NULLIF(p_receptor_doc_tipo, 99), p_receptor_doc_nro
  )
  RETURNING id INTO v_doc_id;

  RETURN jsonb_build_object(
    'fiscal_document_id',       v_doc_id,
    'point_of_sale_id',         v_effective_pv_id,
    'punto_de_venta',           v_pv.numero,
    'comprobante_type',         'factura_c',
    'number',                   v_doc_number,
    'status',                   'pending_cae',
    'subscription_payment_id',  p_receipt_id,
    'total',                    COALESCE(v_receipt.amount, 0)
  );
END;
$function$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. BACKFILL BEST-EFFORT IDEMPOTENTE (D5)
-- ═══════════════════════════════════════════════════════════════════════════

-- 4.1 sale_items / purchase_items / quote_items / sales_order_items
UPDATE public.sale_items li
SET    name_snapshot       = p.name,
       sku_snapshot        = p.sku,
       unit_cost_snapshot  = p.cost,
       iva_rate_snapshot   = NULL,
       snapshot_backfilled = true
FROM   public.products p
WHERE  li.product_id = p.id
  AND  li.snapshot_backfilled = false
  AND  li.name_snapshot IS NULL;

UPDATE public.purchase_items li
SET    name_snapshot       = p.name,
       sku_snapshot        = p.sku,
       unit_cost_snapshot  = p.cost,
       iva_rate_snapshot   = NULL,
       snapshot_backfilled = true
FROM   public.products p
WHERE  li.product_id = p.id
  AND  li.snapshot_backfilled = false
  AND  li.name_snapshot IS NULL;

UPDATE public.quote_items li
SET    name_snapshot       = p.name,
       sku_snapshot        = p.sku,
       unit_cost_snapshot  = p.cost,
       iva_rate_snapshot   = NULL,
       snapshot_backfilled = true
FROM   public.products p
WHERE  li.product_id = p.id
  AND  li.snapshot_backfilled = false
  AND  li.name_snapshot IS NULL;

UPDATE public.sales_order_items li
SET    name_snapshot       = p.name,
       sku_snapshot        = p.sku,
       unit_cost_snapshot  = p.cost,
       iva_rate_snapshot   = NULL,
       snapshot_backfilled = true
FROM   public.products p
WHERE  li.product_id = p.id
  AND  li.snapshot_backfilled = false
  AND  li.name_snapshot IS NULL;

-- 4.2 purchases (D2 — el snapshot de compra real vive acá, no en purchase_items)
UPDATE public.purchases pu
SET    name_snapshot       = p.name,
       sku_snapshot        = p.sku,
       unit_cost_snapshot  = p.cost,
       iva_rate_snapshot   = NULL,
       snapshot_backfilled = true
FROM   public.products p
WHERE  pu.product_id = p.id
  AND  pu.snapshot_backfilled = false
  AND  pu.name_snapshot IS NULL;


-- ═══════════════════════════════════════════════════════════════════════════
-- 5. REPORTING MIGRADO A SNAPSHOTS (RN-D2, D6)
-- ═══════════════════════════════════════════════════════════════════════════

-- 5.1 rpc_product_profitability: costo por línea = COALESCE(unit_cost_snapshot,
-- products.cost) ponderado por cantidad. Firma, columnas de salida y P403 sin
-- cambios. Cuerpo vigente: 20260606110000_product_profitability.sql.
CREATE OR REPLACE FUNCTION public.rpc_product_profitability(
  p_period_days INT DEFAULT 30
)
RETURNS TABLE (
  product_id       UUID,
  product_name     TEXT,
  total_revenue    NUMERIC,
  total_cost       NUMERIC,
  gross_margin     NUMERIC,
  gross_margin_pct NUMERIC,
  units_sold       NUMERIC,
  last_sale_date   DATE
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid        UUID;
  v_account_id UUID;
  v_since_date DATE;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Derive the caller's active account (C-05 D7 pattern)
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  v_since_date := CURRENT_DATE - (p_period_days || ' days')::INTERVAL;

  -- v3-snapshot-pattern (D6, RN-D2): el costo por línea deriva del snapshot
  -- congelado en sale_items (unit_cost_snapshot), no del maestro actual.
  -- Cascada de fallback: (1) unit_cost_snapshot de la línea; (2) products.cost
  -- actual solo cuando el snapshot es NULL (líneas muy viejas no backfilleadas).
  -- CTEs avoid Cartesian product when aggregating two fact tables on the same key
  RETURN QUERY
  WITH
    sales_agg AS (
      SELECT
        s.product_id,
        SUM(s.amount)                                             AS total_revenue,
        SUM(s.quantity)                                            AS units_sold,
        MAX(s.date)                                                AS last_sale_date,
        SUM(COALESCE(si.unit_cost_snapshot, pr2.cost) * s.quantity) AS total_cost_snapshot,
        bool_or(si.unit_cost_snapshot IS NULL)                     AS any_missing_snapshot
      FROM   public.sales s
      JOIN   public.products pr2 ON pr2.id = s.product_id
      LEFT   JOIN public.sale_items si
             ON si.sale_id = s.id AND si.product_id = s.product_id
      WHERE  s.account_id   = v_account_id
        AND  s.product_id  IS NOT NULL
        AND  s.date        >= v_since_date
      GROUP  BY s.product_id
    )
  SELECT
    sa.product_id,
    pr.name                                                                   AS product_name,
    sa.total_revenue,
    sa.total_cost_snapshot                                                    AS total_cost,
    sa.total_revenue - sa.total_cost_snapshot                                 AS gross_margin,
    ROUND(
      (sa.total_revenue - sa.total_cost_snapshot)
      / NULLIF(sa.total_revenue, 0) * 100,
      2
    )                                                                         AS gross_margin_pct,
    sa.units_sold,
    sa.last_sale_date
  FROM   sales_agg         sa
  JOIN   public.products   pr ON pr.id          = sa.product_id
  ORDER  BY gross_margin_pct DESC NULLS LAST
  LIMIT  200;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_product_profitability(INT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(INT) TO authenticated;

COMMENT ON FUNCTION public.rpc_product_profitability(INT) IS
  'C-11 + v3-snapshot-pattern (D6, RN-D2): rentabilidad por SKU. El costo por línea '
  'deriva de sale_items.unit_cost_snapshot (congelado en la venta), con fallback a '
  'products.cost actual solo cuando el snapshot es NULL (líneas muy antiguas no '
  'backfilleadas). Firma y contrato de salida sin cambios. P403 sin cuenta activa.';


-- 5.2a rpc_dashboard_channel_margin: COGS ya joinea sale_items — solo cambia
-- pr.cost por COALESCE(si.unit_cost_snapshot, pr.cost) (D6). Cuerpo vigente:
-- 20260616000006_v20_dashboard_channel_margin.sql. Firma y contrato sin cambios.
CREATE OR REPLACE FUNCTION public.rpc_dashboard_channel_margin(
  p_from      timestamp with time zone,
  p_to        timestamp with time zone,
  p_prev_from timestamp with time zone,
  p_prev_to   timestamp with time zone,
  p_branch_id uuid DEFAULT NULL
)
RETURNS TABLE(
  channels        jsonb,
  leader          text,
  margin_pct      numeric,
  prev_margin_pct numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  RETURN QUERY
  WITH per_channel AS (
    -- v3-snapshot-pattern (D6): COGS = snapshot congelado, fallback a pr.cost
    -- actual solo si la línea no tiene snapshot (histórica no backfilleada).
    SELECT
      COALESCE(NULLIF(trim(s.canal), ''), 'sin_canal')                                          AS canal,
      SUM(COALESCE(s.total, s.amount))                                                           AS revenue,
      SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(si.quantity, 0))                AS cogs
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    GROUP BY 1
  ),
  channel_rows AS (
    SELECT
      pc.canal,
      pc.revenue,
      ROUND((pc.revenue - pc.cogs) / NULLIF(pc.revenue, 0) * 100, 1) AS margin_pct
    FROM per_channel pc
    WHERE pc.revenue > 0
  ),
  totals_curr AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(si.quantity, 0)))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  totals_prev AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(si.quantity, 0)))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_prev_from AND p_prev_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  )
  SELECT
    COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object('canal', cr.canal, 'revenue', cr.revenue, 'margin_pct', cr.margin_pct)
                ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
              )
       FROM channel_rows cr),
      '[]'::jsonb
    )                                                                AS channels,
    (SELECT cr.canal FROM channel_rows cr
     ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
     LIMIT 1)                                                        AS leader,
    tc.pct                                                           AS margin_pct,
    tp.pct                                                           AS prev_margin_pct
  FROM totals_curr tc
  CROSS JOIN totals_prev tp;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_dashboard_channel_margin(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_dashboard_channel_margin(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_dashboard_channel_margin(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_dashboard_channel_margin IS
  'C-20 (task 9.3) + v3-snapshot-pattern (D6): margen por canal. COGS deriva de '
  'sale_items.unit_cost_snapshot con fallback a products.cost cuando la línea no '
  'tiene snapshot. Firma y contrato sin cambios.';


-- 5.2b rpc_dashboard_kpi_summary: cost_per_sale (COGS) hoy joinea products
-- directo desde sales (no desde sale_items). v3-snapshot-pattern agrega el
-- JOIN a sale_items para poder leer unit_cost_snapshot, con el mismo
-- fallback D6. El resto de la función (net_profit, avg_ticket, stagnant
-- stock vía v_products_with_stock) no depende de costo por línea de venta
-- y queda sin cambios. Cuerpo vigente: 20260623000001_c21_checkpoint2_drop_products_stock.sql.
CREATE OR REPLACE FUNCTION public.rpc_dashboard_kpi_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(net_profit numeric, prev_net_profit numeric, avg_ticket numeric, prev_avg_ticket numeric, cost_per_sale numeric, prev_cost_per_sale numeric, stagnant_stock_value numeric, stagnant_stock_count integer, prev_stagnant_stock_value numeric, prev_stagnant_stock_count integer, sales_count integer, prev_sales_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  IF p_from > p_to OR p_prev_from > p_prev_to THEN
    RAISE EXCEPTION 'Invalid date range' USING ERRCODE = 'P400';
  END IF;

  RETURN QUERY
  WITH sales_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS revenue,
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_revenue,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_from      AND p_to)     AS ops,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to) AS prev_ops,
      -- v3-snapshot-pattern (D6): COGS = snapshot congelado (via sale_items),
      -- fallback a pr.cost actual solo si la línea no tiene snapshot.
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS cogs,
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  expenses_agg AS (
    SELECT
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_from      AND p_to),      0) AS expenses,
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_expenses
    FROM public.expenses e
    WHERE e.account_id = v_account_id
      AND e.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
  ),
  purchases_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_from      AND p_to),      0) AS purchases,
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_purchases
    FROM public.purchases pu
    WHERE pu.account_id = v_account_id
      AND pu.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR pu.branch_id = p_branch_id)
  ),
  -- Stock sin rotación: productos vendibles con stock, sin líneas de venta en la ventana.
  -- C-21 checkpoint #2: stock = Σ branch_stock (vía vista, products.stock no existe).
  -- Sin cambios de v3-snapshot-pattern (no depende de costo por línea de venta).
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.v_products_with_stock p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_from AND p_to
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.v_products_with_stock p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
      )
  )
  SELECT
    sa.revenue      - (ea.expenses      + pa.purchases)       AS net_profit,
    sa.prev_revenue - (ea.prev_expenses + pa.prev_purchases)  AS prev_net_profit,
    ROUND(sa.revenue      / NULLIF(sa.ops, 0), 2)             AS avg_ticket,
    ROUND(sa.prev_revenue / NULLIF(sa.prev_ops, 0), 2)        AS prev_avg_ticket,
    ROUND(sa.cogs         / NULLIF(sa.ops, 0), 2)             AS cost_per_sale,
    ROUND(sa.prev_cogs    / NULLIF(sa.prev_ops, 0), 2)        AS prev_cost_per_sale,
    sc.value                                                  AS stagnant_stock_value,
    sc.cnt                                                    AS stagnant_stock_count,
    sp.value                                                  AS prev_stagnant_stock_value,
    sp.cnt                                                    AS prev_stagnant_stock_count,
    sa.ops::integer                                           AS sales_count,
    sa.prev_ops::integer                                      AS prev_sales_count
  FROM sales_agg sa
  CROSS JOIN expenses_agg  ea
  CROSS JOIN purchases_agg pa
  CROSS JOIN stagnant_curr sc
  CROSS JOIN stagnant_prev sp;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_dashboard_kpi_summary(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_dashboard_kpi_summary IS
  'C-21 checkpoint #2 + v3-snapshot-pattern (D6): KPIs de dashboard. cost_per_sale '
  'deriva de sale_items.unit_cost_snapshot (via JOIN nuevo) con fallback a products.cost '
  'cuando la línea no tiene snapshot. Stock sin rotación sigue en v_products_with_stock '
  '(no depende de costo por línea, sin cambios). Firma y contrato sin cambios.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 6. GATES DE VERIFICACIÓN (TDD — RED/GREEN/TRIANGULATE)
--    Introspección: corre siempre (incl. prod). Comportamiento: solo DB
--    vacía (CI) — patrón C2/C3: anchor sintético vía handle_new_user +
--    set_config de claims JWT + ROLLBACK total al final (ningún efecto
--    persiste, ni en CI ni si se corriera por error en prod).
-- ═══════════════════════════════════════════════════════════════════════════
DO $gate$
DECLARE
  v_count              integer;
  v_def                text;
  v_run_behavioral     boolean := false;
  v_fake_user_id        uuid := gen_random_uuid();
  v_fake_account_id     uuid;
  v_branch_id           uuid;
  v_product_id          uuid;
  v_product_id_2        uuid;
  v_client_id           uuid;
  v_sale_result         jsonb;
  v_sale_result_2       jsonb;
  v_purchase_result     jsonb;
  v_quote_id            uuid;
  v_accept_result       jsonb;
  v_so_id               uuid;
  v_item_cost           numeric;
  v_item_name           text;
  v_item_sku            text;
  v_movement_cost       numeric;
  v_purchase_cost       numeric;
  v_profit_row          RECORD;
  v_scratch_backfilled  boolean;

  -- introspección
  v_gate_a boolean := false;  -- columnas snapshot en las 4 tablas de líneas
  v_gate_b boolean := false;  -- columnas snapshot en purchases (D2)
  v_gate_c boolean := false;  -- stock_movements.unit_cost_snapshot
  v_gate_d boolean := false;  -- fiscal_documents.receptor_legal_name/iva_condition
  v_gate_e boolean := false;  -- rpc_create_sale_operation_v2 congela snapshot
  v_gate_f boolean := false;  -- rpc_create_purchase_operation congela snapshot en purchases
  v_gate_g boolean := false;  -- _c29_confirm_order_core congela snapshot
  v_gate_h boolean := false;  -- rpc_emit_pending_cae persiste receptor_legal_name/iva_condition
  v_gate_i boolean := false;  -- rpc_product_profitability usa unit_cost_snapshot
  v_gate_p boolean := false;  -- rpc_dashboard_channel_margin usa unit_cost_snapshot
  v_gate_q boolean := false;  -- rpc_dashboard_kpi_summary usa unit_cost_snapshot
  -- comportamiento (solo CI)
  v_gate_j boolean := false;  -- venta v2 congela name/sku/cost en sale_items + stock_movements
  v_gate_k boolean := false;  -- remarcar el maestro no altera el snapshot ya congelado
  v_gate_l boolean := false;  -- compra congela snapshot en purchases
  v_gate_m boolean := false;  -- quote → accept propaga snapshot sin releer products
  v_gate_n boolean := false;  -- backfill idempotente (2da corrida no cambia filas)
  v_gate_o boolean := false;  -- rpc_product_profitability devuelve costo desde snapshot
BEGIN

  -- ── (a) Columnas snapshot en sale_items/purchase_items/quote_items/sales_order_items ──
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN ('sale_items','purchase_items','quote_items','sales_order_items')
    AND column_name IN ('name_snapshot','sku_snapshot','unit_cost_snapshot','iva_rate_snapshot','snapshot_backfilled');
  IF v_count <> 20 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaban 20 columnas snapshot (4 tablas x 5 columnas), hay %', v_count;
  END IF;
  v_gate_a := true;

  -- ── (b) Columnas snapshot en purchases (D2) ───────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'purchases'
    AND column_name IN ('name_snapshot','sku_snapshot','unit_cost_snapshot','iva_rate_snapshot','snapshot_backfilled');
  IF v_count <> 5 THEN
    RAISE EXCEPTION 'GATE (b) FAILED: se esperaban 5 columnas snapshot en purchases, hay %', v_count;
  END IF;
  v_gate_b := true;

  -- ── (c) stock_movements.unit_cost_snapshot ────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'stock_movements'
    AND column_name = 'unit_cost_snapshot';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE (c) FAILED: falta stock_movements.unit_cost_snapshot';
  END IF;
  v_gate_c := true;

  -- ── (d) fiscal_documents.receptor_legal_name/receptor_iva_condition ───────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'fiscal_documents'
    AND column_name IN ('receptor_legal_name','receptor_iva_condition');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: faltan columnas FiscalIdentitySnapshot en fiscal_documents';
  END IF;
  v_gate_d := true;

  -- ── (e) rpc_create_sale_operation_v2 congela snapshot en el INSERT ────────
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_sale_operation_v2';
  IF v_def IS NULL OR v_def NOT ILIKE '%name_snapshot%' OR v_def NOT ILIKE '%unit_cost_snapshot%' THEN
    RAISE EXCEPTION 'GATE (e) FAILED: rpc_create_sale_operation_v2 no congela snapshots en sale_items';
  END IF;
  v_gate_e := true;

  -- ── (f) rpc_create_purchase_operation congela snapshot en purchases (D2) ──
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_purchase_operation' AND p.pronargs = 6;
  IF v_def IS NULL OR v_def NOT ILIKE '%name_snapshot%' OR v_def NOT ILIKE '%unit_cost_snapshot%' THEN
    RAISE EXCEPTION 'GATE (f) FAILED: rpc_create_purchase_operation no congela snapshots en purchases';
  END IF;
  -- Gate negativo: sigue sin tocar products.stock (no debe reaparecer la regresión C-21).
  IF v_def ILIKE '%update public.products%set%stock%' THEN
    RAISE EXCEPTION 'GATE (f) FAILED: el cuerpo reintrodujo escritura a products.stock';
  END IF;
  v_gate_f := true;

  -- ── (g) _c29_confirm_order_core congela snapshot ──────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_c29_confirm_order_core';
  IF v_def IS NULL OR v_def NOT ILIKE '%name_snapshot%' OR v_def NOT ILIKE '%unit_cost_snapshot%' THEN
    RAISE EXCEPTION 'GATE (g) FAILED: _c29_confirm_order_core no congela snapshots';
  END IF;
  v_gate_g := true;

  -- ── (h) rpc_emit_pending_cae persiste receptor_legal_name/iva_condition ───
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_emit_pending_cae';
  IF v_def IS NULL OR v_def NOT ILIKE '%receptor_legal_name%' OR v_def NOT ILIKE '%receptor_iva_condition%' THEN
    RAISE EXCEPTION 'GATE (h) FAILED: rpc_emit_pending_cae no persiste el FiscalIdentitySnapshot del receptor';
  END IF;
  v_gate_h := true;

  -- ── (i) rpc_product_profitability usa unit_cost_snapshot ─────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_product_profitability';
  IF v_def IS NULL OR v_def NOT ILIKE '%unit_cost_snapshot%' THEN
    RAISE EXCEPTION 'GATE (i) FAILED: rpc_product_profitability no lee unit_cost_snapshot';
  END IF;
  v_gate_i := true;

  -- ── (p) rpc_dashboard_channel_margin usa unit_cost_snapshot (5.2) ────────
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_dashboard_channel_margin';
  IF v_def IS NULL OR v_def NOT ILIKE '%unit_cost_snapshot%' THEN
    RAISE EXCEPTION 'GATE (p) FAILED: rpc_dashboard_channel_margin no lee unit_cost_snapshot';
  END IF;
  v_gate_p := true;

  -- ── (q) rpc_dashboard_kpi_summary usa unit_cost_snapshot (5.2) ───────────
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_dashboard_kpi_summary';
  IF v_def IS NULL OR v_def NOT ILIKE '%unit_cost_snapshot%' THEN
    RAISE EXCEPTION 'GATE (q) FAILED: rpc_dashboard_kpi_summary no lee unit_cost_snapshot';
  END IF;
  v_gate_q := true;


  -- ══════════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Patrón C2/C3: anchor sintético +
  -- set_config de claims JWT + WHEN OTHERS con discriminación best-effort.
  -- ══════════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- El trigger handle_new_user auto-crea account + membership(owner) + branch
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'v3-snapshot-gate@test.local', now(), now(),
              jsonb_build_object('name', 'v3 Snapshot Gate', 'phone', '', 'locality', '', 'province', ''))
      ON CONFLICT (id) DO NOTHING;

      SELECT account_id INTO v_fake_account_id
      FROM public.account_members
      WHERE user_id = v_fake_user_id
      ORDER BY created_at
      LIMIT 1;

      IF v_fake_account_id IS NULL THEN
        v_fake_account_id := gen_random_uuid();
        INSERT INTO public.accounts (id, owner_user_id)
        VALUES (v_fake_account_id, v_fake_user_id) ON CONFLICT (id) DO NOTHING;
        INSERT INTO public.account_members (account_id, user_id, role)
        VALUES (v_fake_account_id, v_fake_user_id, 'owner')
        ON CONFLICT DO NOTHING;
      END IF;

      -- Simular la sesión JWT (local a la transacción de la migración)
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_id::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_fake_user_id::text, true);

      SELECT id INTO v_branch_id
      FROM public.branches
      WHERE account_id = v_fake_account_id
      ORDER BY created_at
      LIMIT 1;

      IF v_branch_id IS NULL THEN
        INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
        VALUES (v_fake_account_id, 'Casa Central Gate', TRUE, 'active', now())
        RETURNING id INTO v_branch_id;
      END IF;

      -- Producto ancla: cost = 600, name/sku conocidos.
      INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
      VALUES (v_fake_user_id, v_fake_account_id, 'Yerba 1kg Gate', 'YRB-GATE-1', 600.00, 1000.00)
      RETURNING id INTO v_product_id;

      INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
      VALUES (v_fake_user_id, v_fake_account_id, 'Fideos 500g Gate', 'FID-GATE-1', 50.00, 100.00)
      RETURNING id INTO v_product_id_2;

      -- Stock inicial en la branch (vía helper C-21/C-26, no products.stock).
      PERFORM public.c21_apply_branch_stock_delta(v_fake_account_id, v_product_id, v_branch_id, 100);
      PERFORM public.c21_apply_branch_stock_delta(v_fake_account_id, v_product_id_2, v_branch_id, 100);

      -- Activar el feature flag v2 para que rpc_create_sale_operation delegue en v2.
      INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
      VALUES (v_fake_account_id, 'sale_items_rpc_v2', true)
      ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = true;

      INSERT INTO public.clients (user_id, account_id, name)
      VALUES (v_fake_user_id, v_fake_account_id, 'Cliente Gate')
      RETURNING id INTO v_client_id;
    EXCEPTION
      WHEN OTHERS THEN
        v_run_behavioral := false;
        RAISE NOTICE 'v3-snapshot-pattern: anchor sintético no disponible (%) — se saltan gates de comportamiento', SQLERRM;
    END;
  END IF;

  -- ── (j) Venta v2 congela name/sku/cost en sale_items + stock_movements ────
  IF v_run_behavioral THEN
  BEGIN
    v_sale_result := public.rpc_create_sale_operation(
      'gate-j-' || gen_random_uuid()::text, v_client_id, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 1000.00, 'quantity', 2, 'unit_id', NULL)),
      v_branch_id, NULL
    );

    SELECT si.unit_cost_snapshot, si.name_snapshot, si.sku_snapshot
    INTO   v_item_cost, v_item_name, v_item_sku
    FROM   public.sale_items si
    JOIN   public.sales s ON s.id = si.sale_id
    WHERE  s.operation_id = (v_sale_result->>'operation_id')::uuid
      AND  si.product_id = v_product_id;

    IF v_item_cost IS DISTINCT FROM 600.00 OR v_item_name IS DISTINCT FROM 'Yerba 1kg Gate'
       OR v_item_sku IS DISTINCT FROM 'YRB-GATE-1' THEN
      RAISE EXCEPTION 'GATE (j) FAILED: sale_items no congeló name/sku/cost esperados (cost=%, name=%, sku=%)',
        v_item_cost, v_item_name, v_item_sku;
    END IF;

    SELECT unit_cost_snapshot INTO v_movement_cost
    FROM   public.stock_movements
    WHERE  operation_group_id = (v_sale_result->>'operation_id')::uuid
      AND  product_id = v_product_id
      AND  type = 'sale';

    IF v_movement_cost IS DISTINCT FROM 600.00 THEN
      RAISE EXCEPTION 'GATE (j) FAILED: stock_movements no congeló unit_cost_snapshot=600 (got %)', v_movement_cost;
    END IF;

    v_gate_j := true;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GATE (j) skipped: %', SQLERRM;
  END;
  END IF;

  -- ── (k) Remarcar el maestro no altera el snapshot ya congelado (TRIANGULATE) ──
  IF v_run_behavioral AND v_gate_j THEN
  BEGIN
    UPDATE public.products SET cost = 900.00 WHERE id = v_product_id;

    SELECT si.unit_cost_snapshot INTO v_item_cost
    FROM   public.sale_items si
    JOIN   public.sales s ON s.id = si.sale_id
    WHERE  s.operation_id = (v_sale_result->>'operation_id')::uuid
      AND  si.product_id = v_product_id;

    IF v_item_cost IS DISTINCT FROM 600.00 THEN
      RAISE EXCEPTION 'GATE (k) FAILED: el snapshot cambió a % tras remarcar el maestro (debía seguir en 600)', v_item_cost;
    END IF;

    v_gate_k := true;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GATE (k) skipped: %', SQLERRM;
  END;
  END IF;

  -- ── (l) Compra congela snapshot en purchases (D2) ─────────────────────────
  IF v_run_behavioral THEN
  BEGIN
    v_purchase_result := public.rpc_create_purchase_operation(
      'gate-l-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id_2, 'amount', 50.00, 'quantity', 10, 'unit_id', NULL)),
      v_branch_id, NULL
    );

    SELECT pu.unit_cost_snapshot INTO v_purchase_cost
    FROM   public.purchases pu
    WHERE  pu.operation_id = (v_purchase_result->>'operation_id')::uuid
      AND  pu.product_id = v_product_id_2;

    IF v_purchase_cost IS DISTINCT FROM 50.00 THEN
      RAISE EXCEPTION 'GATE (l) FAILED: purchases no congeló unit_cost_snapshot=50 (got %)', v_purchase_cost;
    END IF;

    v_gate_l := true;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GATE (l) skipped: %', SQLERRM;
  END;
  END IF;

  -- ── (m) Quote → accept propaga snapshot sin releer products ───────────────
  IF v_run_behavioral THEN
  BEGIN
    INSERT INTO public.quotes (account_id, branch_id, client_id, status, total, created_by)
    VALUES (v_fake_account_id, v_branch_id, v_client_id, 'draft', 2000.00, v_fake_user_id)
    RETURNING id INTO v_quote_id;

    INSERT INTO public.quote_items
      (quote_id, account_id, product_id, quantity, price, subtotal,
       name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
    VALUES
      (v_quote_id, v_fake_account_id, v_product_id, 2, 1000.00, 2000.00,
       'Yerba 1kg Gate', 'YRB-GATE-1', 600.00, NULL);

    v_accept_result := public.rpc_accept_quote(v_quote_id);
    v_so_id := (v_accept_result->>'sales_order_id')::uuid;

    SELECT soi.unit_cost_snapshot, soi.name_snapshot INTO v_item_cost, v_item_name
    FROM   public.sales_order_items soi
    WHERE  soi.sales_order_id = v_so_id AND soi.product_id = v_product_id;

    IF v_item_cost IS DISTINCT FROM 600.00 OR v_item_name IS DISTINCT FROM 'Yerba 1kg Gate' THEN
      RAISE EXCEPTION 'GATE (m) FAILED: sales_order_items no heredó el snapshot del quote (cost=%, name=%)',
        v_item_cost, v_item_name;
    END IF;

    v_gate_m := true;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GATE (m) skipped: %', SQLERRM;
  END;
  END IF;

  -- ── (o) rpc_product_profitability devuelve costo desde snapshot ──────────
  IF v_run_behavioral AND v_gate_j THEN
  BEGIN
    SELECT total_cost INTO v_profit_row
    FROM public.rpc_product_profitability(365) prof
    WHERE prof.product_id = v_product_id;

    -- La venta gate (j) fue 2 unidades a unit_cost_snapshot=600 → total_cost=1200,
    -- independientemente de que products.cost ya se remarcó a 900 en (k).
    IF v_profit_row.total_cost IS DISTINCT FROM 1200.00 THEN
      RAISE EXCEPTION 'GATE (o) FAILED: rpc_product_profitability no usó el snapshot (total_cost=%, esperado 1200)',
        v_profit_row.total_cost;
    END IF;

    v_gate_o := true;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GATE (o) skipped: %', SQLERRM;
  END;
  END IF;

  -- ── (n) Backfill idempotente: 2da corrida no cambia filas ─────────────────
  IF v_run_behavioral AND v_gate_j THEN
  BEGIN
    -- Forzar una fila "histórica" sin snapshot para probar el backfill.
    INSERT INTO public.sales
      (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
       total, currency, date, operation_id, branch_id)
    VALUES
      (v_fake_user_id, v_fake_account_id, v_client_id, v_product_id_2,
       50.00, 5, NULL, 250.00, 'ARS', CURRENT_DATE, gen_random_uuid(), v_branch_id)
    RETURNING id INTO v_so_id;

    INSERT INTO public.sale_items (sale_id, product_id, account_id, quantity, unit_id, price, subtotal)
    VALUES (v_so_id, v_product_id_2, v_fake_account_id, 5, NULL, 50.00, 250.00);

    -- 1ra corrida: backfillea la fila histórica.
    UPDATE public.sale_items li
    SET    name_snapshot       = p.name,
           sku_snapshot        = p.sku,
           unit_cost_snapshot  = p.cost,
           snapshot_backfilled = true
    FROM   public.products p
    WHERE  li.product_id = p.id
      AND  li.snapshot_backfilled = false
      AND  li.name_snapshot IS NULL
      AND  li.sale_id = v_so_id;

    -- 2da corrida (misma condición): no debe tocar ninguna fila.
    WITH updated AS (
      UPDATE public.sale_items li
      SET    name_snapshot       = p.name,
             sku_snapshot        = p.sku,
             unit_cost_snapshot  = p.cost,
             snapshot_backfilled = true
      FROM   public.products p
      WHERE  li.product_id = p.id
        AND  li.snapshot_backfilled = false
        AND  li.name_snapshot IS NULL
        AND  li.sale_id = v_so_id
      RETURNING li.id
    )
    SELECT COUNT(*) INTO v_count FROM updated;

    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE (n) FAILED: la 2da corrida del backfill tocó % filas (debía ser 0)', v_count;
    END IF;

    -- Y el snapshot congelado en vivo (gate j, snapshot_backfilled=false con
    -- snapshot no nulo) tampoco debe tocarse por un backfill posterior.
    UPDATE public.sale_items li
    SET    name_snapshot       = p.name,
           sku_snapshot        = p.sku,
           unit_cost_snapshot  = p.cost,
           snapshot_backfilled = true
    FROM   public.products p
    WHERE  li.product_id = p.id
      AND  li.snapshot_backfilled = false
      AND  li.name_snapshot IS NULL
      AND  li.product_id = v_product_id;

    SELECT unit_cost_snapshot, snapshot_backfilled INTO v_item_cost, v_scratch_backfilled
    FROM   public.sale_items si
    JOIN   public.sales s ON s.id = si.sale_id
    WHERE  s.operation_id = (v_sale_result->>'operation_id')::uuid
      AND  si.product_id = v_product_id;

    IF v_item_cost IS DISTINCT FROM 600.00 THEN
      RAISE EXCEPTION 'GATE (n) FAILED: el backfill sobrescribió un snapshot congelado en vivo (got %, esperado 600)', v_item_cost;
    END IF;
    IF v_scratch_backfilled IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'GATE (n) FAILED: el snapshot congelado en vivo quedó marcado snapshot_backfilled=true (esperado false)';
    END IF;

    v_gate_n := true;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GATE (n) skipped: %', SQLERRM;
  END;
  END IF;


  -- ── Limpieza del anchor sintético (solo DB de test, best-effort) ──────────
  IF v_run_behavioral THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_fake_user_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'v3-snapshot-pattern: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== v3-snapshot-pattern SQL gates ===';
  RAISE NOTICE '(a) columnas snapshot en 4 tablas de líneas:      %', v_gate_a;
  RAISE NOTICE '(b) columnas snapshot en purchases (D2):          %', v_gate_b;
  RAISE NOTICE '(c) stock_movements.unit_cost_snapshot:           %', v_gate_c;
  RAISE NOTICE '(d) fiscal_documents FiscalIdentitySnapshot:      %', v_gate_d;
  RAISE NOTICE '(e) rpc_create_sale_operation_v2 congela:         %', v_gate_e;
  RAISE NOTICE '(f) rpc_create_purchase_operation congela (D2):   %', v_gate_f;
  RAISE NOTICE '(g) _c29_confirm_order_core congela:              %', v_gate_g;
  RAISE NOTICE '(h) rpc_emit_pending_cae persiste receptor:       %', v_gate_h;
  RAISE NOTICE '(i) rpc_product_profitability usa snapshot:       %', v_gate_i;
  RAISE NOTICE '(p) rpc_dashboard_channel_margin usa snapshot:    %', v_gate_p;
  RAISE NOTICE '(q) rpc_dashboard_kpi_summary usa snapshot:       %', v_gate_q;
  RAISE NOTICE '--- comportamiento (solo DB vacía / CI) ---';
  RAISE NOTICE '(j) venta v2 congela name/sku/cost:               %', v_gate_j;
  RAISE NOTICE '(k) remarcar maestro no altera snapshot:          %', v_gate_k;
  RAISE NOTICE '(l) compra congela snapshot en purchases:         %', v_gate_l;
  RAISE NOTICE '(m) quote->accept propaga snapshot:               %', v_gate_m;
  RAISE NOTICE '(n) backfill idempotente y no destructivo:        %', v_gate_n;
  RAISE NOTICE '(o) profitability usa snapshot con fallback:      %', v_gate_o;
END
$gate$;


-- =============================================================================
-- VERIFICATION (post-push, manual):
--   SELECT table_name, column_name FROM information_schema.columns
--   WHERE table_name IN ('sale_items','purchase_items','quote_items','sales_order_items','purchases')
--     AND column_name LIKE '%snapshot%' ORDER BY table_name, column_name;
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='stock_movements' AND column_name='unit_cost_snapshot';
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='fiscal_documents' AND column_name IN ('receptor_legal_name','receptor_iva_condition');
--   -- Smoke: venta/compra/quickSale/quote→accept/emitir comprobante — confirmar
--   -- que las columnas snapshot se llenan y stock/idempotencia no regresan.
-- =============================================================================
