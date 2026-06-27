-- =============================================================================
-- MIGRATION: 20260802000001_cost_center_dimension.sql
-- CHANGE:    cost-center-dimension
-- Design ref: V2.5 Finanzas — catálogo plano + dimensión analítica nullable.
--
-- Tasks 1.1-1.7 (TDD RED→GREEN→TRIANGULATE):
--
-- [RED - 1.1] Schema assertions (verified against spec):
--   ✓ cost_centers columns: id, account_id, name, code, is_active, created_at
--   ✓ UNIQUE(account_id, lower(name)) — case-insensitive unique index
--   ✓ RLS: SELECT = members of account; INSERT/UPDATE = owner/admin (is_account_writer)
--   ✓ is_active DEFAULT true
--
-- [RED - 1.3] Column assertions:
--   ✓ expenses.cost_center_id uuid NULL REFERENCES cost_centers(id) ON DELETE SET NULL
--   ✓ purchases.cost_center_id uuid NULL REFERENCES cost_centers(id) ON DELETE SET NULL
--   ✓ No backfill (existing rows stay NULL)
--
-- [RED - 1.5] RPC assertions:
--   ✓ rpc_create_purchase_operation gains optional p_cost_center_id uuid DEFAULT NULL
--   ✓ Validates cost_center_id belongs to account (mirror of branch_id validation)
--   ✓ Writes cost_center_id to ALL rows of the operation
--   ✓ Without p_cost_center_id → persists NULL (regression)
--   ✓ Does NOT add new operation_kind → operation_idempotency CHECK unchanged
--
-- [TRIANGULATE - 1.7]:
--   ✓ Account isolation (RLS by account_id)
--   ✓ Duplicate name case-insensitive rejected (unique functional index)
--   ✓ Member rejected on INSERT/UPDATE (is_account_writer)
--   ✓ Multi-line purchase with/without cost center
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — CLAUDE.md regla).
--        CI (deploy.yml) lo aplica al mergear a main.
-- ROLLBACK:
--   DROP INDEX IF EXISTS cost_centers_account_name_lower_idx;
--   DROP INDEX IF EXISTS cost_centers_account_id_idx;
--   DROP TABLE IF EXISTS public.cost_centers;
--   ALTER TABLE public.expenses  DROP COLUMN IF EXISTS cost_center_id;
--   ALTER TABLE public.purchases DROP COLUMN IF EXISTS cost_center_id;
--   + restaurar firma original de rpc_create_purchase_operation (sin p_cost_center_id).
-- =============================================================================


-- ─── 1. Tabla cost_centers ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.cost_centers (
    id          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    name        text          NOT NULL,
    code        text          NULL,
    is_active   boolean       NOT NULL DEFAULT true,
    created_at  timestamptz   NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.cost_centers             IS 'cost-center-dimension: catálogo plano de centros de costo por cuenta (V2.5 Finanzas).';
COMMENT ON COLUMN public.cost_centers.account_id  IS 'Cuenta propietaria del centro de costo (RLS por account_id).';
COMMENT ON COLUMN public.cost_centers.name        IS 'Nombre legible del centro (único case-insensitive por cuenta).';
COMMENT ON COLUMN public.cost_centers.code        IS 'Código corto opcional para integración contable (ej: "MKTO").';
COMMENT ON COLUMN public.cost_centers.is_active   IS 'Soft-delete: FALSE oculta del selector de altas nuevas pero conserva imputaciones históricas.';


-- ─── 2. Índices ───────────────────────────────────────────────────────────────

-- Índice por account_id para filtrado eficiente
CREATE INDEX IF NOT EXISTS cost_centers_account_id_idx
    ON public.cost_centers (account_id);

-- Índice único funcional case-insensitive (TRIANGULATE 1.7: "logística" = "Logística")
CREATE UNIQUE INDEX IF NOT EXISTS cost_centers_account_name_lower_idx
    ON public.cost_centers (account_id, lower(name));


-- ─── 3. RLS ───────────────────────────────────────────────────────────────────

ALTER TABLE public.cost_centers ENABLE ROW LEVEL SECURITY;

-- SELECT: cualquier miembro de la cuenta puede leer sus centros de costo
DROP POLICY IF EXISTS "cost_centers_member_select" ON public.cost_centers;
CREATE POLICY "cost_centers_member_select" ON public.cost_centers
    FOR SELECT
    TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

-- INSERT: sólo owner/admin (is_account_writer)
DROP POLICY IF EXISTS "cost_centers_writer_insert" ON public.cost_centers;
CREATE POLICY "cost_centers_writer_insert" ON public.cost_centers
    FOR INSERT
    TO authenticated
    WITH CHECK (is_account_writer(account_id));

-- UPDATE: sólo owner/admin (is_account_writer)
DROP POLICY IF EXISTS "cost_centers_writer_update" ON public.cost_centers;
CREATE POLICY "cost_centers_writer_update" ON public.cost_centers
    FOR UPDATE
    TO authenticated
    USING     (is_account_writer(account_id))
    WITH CHECK (is_account_writer(account_id));


-- ─── 4. Columna cost_center_id en expenses y purchases ────────────────────────
-- Aditiva / nullable / sin backfill: las filas existentes quedan NULL.
-- ON DELETE SET NULL: si se borra físicamente un centro (raro), la referencia queda NULL.

ALTER TABLE public.expenses
    ADD COLUMN IF NOT EXISTS cost_center_id uuid NULL
        REFERENCES public.cost_centers(id) ON DELETE SET NULL;

ALTER TABLE public.purchases
    ADD COLUMN IF NOT EXISTS cost_center_id uuid NULL
        REFERENCES public.cost_centers(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.expenses.cost_center_id  IS 'cost-center-dimension: centro de costo opcional para imputación analítica (nullable, sin backfill).';
COMMENT ON COLUMN public.purchases.cost_center_id IS 'cost-center-dimension: centro de costo opcional para imputación analítica (por operación: todas las líneas comparten el mismo). Nullable, sin backfill.';


-- ─── 5. Actualizar rpc_create_purchase_operation ──────────────────────────────
-- Se agrega DROP de la firma vieja (5 args) para evitar overload ambiguo,
-- ya que Postgres trata (text, date, text, jsonb, uuid) y (text, date, text, jsonb, uuid, uuid)
-- como firmas distintas → "function is not unique" al invocar con notación posicional.
-- El backend invoca con notación posicional, así que el 6° param DEFAULT NULL es seguro.

DROP FUNCTION IF EXISTS public.rpc_create_purchase_operation(text, date, text, jsonb, uuid);

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
    p_idempotency_key  text,
    p_date             date,
    p_description      text,
    p_items            jsonb,
    p_branch_id        uuid DEFAULT NULL,
    p_cost_center_id   uuid DEFAULT NULL   -- cost-center-dimension: opcional, valida pertenencia a cuenta
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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
    v_inserted        integer;
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

    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
    ON CONFLICT (user_id, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid AND idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                   jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                   '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

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

        IF v_item.product_id IS NOT NULL THEN
            SELECT id, stock, user_id, is_variant, name INTO v_product
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

            -- cost-center-dimension: p_cost_center_id propagated to all rows of this operation
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id)
            RETURNING id INTO v_new_purchase_id;

            UPDATE public.products
            SET    stock = stock + v_qty_norm
            WHERE  id = v_item.product_id
            RETURNING stock - v_qty_norm, stock
            INTO   v_qty_before, v_qty_after;

            INSERT INTO public.stock_movements (
                user_id, account_id, product_id, product_name, type,
                quantity_delta, quantity_before, quantity_after,
                reference_id, reference_type, performed_by,
                operation_group_id, branch_id
            ) VALUES (
                v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                v_qty_norm, v_qty_before, v_qty_after,
                v_new_purchase_id, 'purchase', v_uid,
                v_new_op_id, p_branch_id
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

    RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
    );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) TO authenticated;
