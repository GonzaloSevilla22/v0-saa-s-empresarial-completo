-- =============================================================================
-- MIGRATION: 20260625000001_c26_branch_as_root.sql
-- CHANGE:    C-26 v21-branch-as-root — Branch como Aggregate Root
--
-- Implementa (design.md, OQs resueltas por el PO 2026-06-12):
--   1. Lifecycle operacional de Branch: status ('active'|'closed') + opened_at/
--      closed_at + rpc_open_branch/rpc_close_branch (D1). Cierre bloqueado con
--      stock o si es la última operativa (OQ-B/D4).
--   2. Invariante onHand >= 0: CHECK en branch_stock + gate per-branch para
--      operaciones con branch explícita; sin branch, gate contra la default
--      operativa (OQ-A/D2 + Resolved Decisions).
--   3. StockTransfer como entidad: tabla stock_transfers + stock_movements.
--      transfer_id; rpc_transfer_stock la crea atómicamente (D3).
--   4. Operar contra branch cerrada → P0422 branch_closed (D6).
--   5. rpc_apply_product_stock_delta: p_allow_negative cambia de semántica a
--      "floor a 0 trazable" (OQ-C; firma conservada — sin ventana de
--      incompatibilidad con el backend).
--
-- Nuevos helpers:
--   - c26_default_branch(account_id): branch default OPERATIVA (la más antigua
--     activa+abierta; fallback a la más antigua). REVOKE total.
--   - c21_apply_branch_stock_delta: actualizado para resolver el destino vía
--     c26_default_branch.
--
-- Nota: las compras (sin branch en la firma) siguen registrando
--   quantity_before/after sobre Σ; en mono-branch ≡ per-branch. Se alinearán
--   cuando las compras acepten branch (C-29).
--
-- GOVERNANCE: ALTO — proposal + design aprobados por el PO ("dale con lo
--   recomendado", 2026-06-12). ERRCODEs: 5 chars (convención 20260624000001).
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- ROLLBACK:
--   DROP CHECK branch_stock_quantity_non_negative; DROP rpc_open_branch/
--   rpc_close_branch/c26_default_branch; restaurar rpc_transfer_stock,
--   rpc_create_sale_operation(_v2), rpc_stock_adjustment,
--   rpc_apply_product_stock_delta, rpc_adjust_branch_stock y
--   c21_apply_branch_stock_delta desde pg_proc previo (20260623000001 +
--   20260624000001); ALTER stock_movements DROP COLUMN transfer_id;
--   DROP TABLE stock_transfers; ALTER branches DROP COLUMN status,
--   opened_at, closed_at.
-- =============================================================================


-- ============================================================
-- 1.1 GATE — 0 filas negativas antes del CHECK
-- ============================================================
DO $$
DECLARE
  v_neg integer;
BEGIN
  SELECT count(*) INTO v_neg FROM public.branch_stock WHERE quantity < 0;
  IF v_neg <> 0 THEN
    RAISE EXCEPTION 'C-26 ABORTADO: % filas de branch_stock con quantity < 0. Reconciliar antes del CHECK.', v_neg;
  END IF;
END $$;


-- ============================================================
-- 1.2 Lifecycle de branches
-- ============================================================
ALTER TABLE public.branches
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'closed')),
  ADD COLUMN IF NOT EXISTS opened_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS closed_at TIMESTAMPTZ;

UPDATE public.branches SET opened_at = created_at WHERE opened_at IS NULL;

COMMENT ON COLUMN public.branches.status IS
  'Estado OPERACIONAL (¿puede operar hoy?): active|closed. Independiente de is_active (existencia/soft-delete).';


-- ============================================================
-- 1.3 stock_transfers — la transferencia como entidad
-- ============================================================
CREATE TABLE IF NOT EXISTS public.stock_transfers (
  id             uuid          NOT NULL DEFAULT gen_random_uuid(),
  account_id     uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  product_id     uuid          NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  from_branch_id uuid          NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  to_branch_id   uuid          NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  quantity       numeric(15,4) NOT NULL CHECK (quantity > 0),
  status         text          NOT NULL DEFAULT 'completed' CHECK (status IN ('completed')),
  created_by     uuid          NOT NULL,
  created_at     timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT stock_transfers_pkey PRIMARY KEY (id),
  CONSTRAINT stock_transfers_distinct_branches CHECK (from_branch_id <> to_branch_id)
);

COMMENT ON TABLE public.stock_transfers IS
  'C-26: transferencia de stock entre sucursales como entidad de primer nivel. '
  'status nace con un solo valor (completed: transferencia atómica); el enum '
  'habilita in-transit en el futuro sin migrar.';

CREATE INDEX IF NOT EXISTS stock_transfers_account_idx
  ON public.stock_transfers (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS stock_transfers_from_branch_idx
  ON public.stock_transfers (from_branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS stock_transfers_to_branch_idx
  ON public.stock_transfers (to_branch_id, created_at DESC);

ALTER TABLE public.stock_transfers ENABLE ROW LEVEL SECURITY;

-- SELECT: cualquier miembro de la cuenta. Escritura: SOLO vía RPC definer
-- (sin policies de INSERT/UPDATE/DELETE = denegado por RLS).
DROP POLICY IF EXISTS "stock_transfers_member_select" ON public.stock_transfers;
CREATE POLICY "stock_transfers_member_select" ON public.stock_transfers
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()));


-- ============================================================
-- 1.4 stock_movements.transfer_id
-- ============================================================
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS transfer_id uuid NULL REFERENCES public.stock_transfers(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS stock_movements_transfer_idx
  ON public.stock_movements (transfer_id) WHERE transfer_id IS NOT NULL;


-- ============================================================
-- 1.5 Invariante físico: branch_stock.quantity >= 0 (OQ-A)
-- ============================================================
ALTER TABLE public.branch_stock
  DROP CONSTRAINT IF EXISTS branch_stock_quantity_non_negative;
ALTER TABLE public.branch_stock
  ADD CONSTRAINT branch_stock_quantity_non_negative CHECK (quantity >= 0);


-- ============================================================
-- 2. Helper: c26_default_branch — default OPERATIVA de la cuenta
-- ============================================================
CREATE OR REPLACE FUNCTION public.c26_default_branch(p_account_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT b.id FROM public.branches b
      WHERE b.account_id = p_account_id AND b.is_active AND b.status = 'active'
      ORDER BY b.created_at ASC LIMIT 1),
    (SELECT b.id FROM public.branches b
      WHERE b.account_id = p_account_id
      ORDER BY b.created_at ASC LIMIT 1)
  );
$$;

REVOKE ALL ON FUNCTION public.c26_default_branch(uuid) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.c26_default_branch IS
  'C-26: branch default operativa de una cuenta (la más antigua activa+abierta; '
  'fallback a la más antigua a secas). Uso interno de los RPCs definer.';


-- ============================================================
-- 3. c21_apply_branch_stock_delta — destino vía c26_default_branch
-- ============================================================
CREATE OR REPLACE FUNCTION public.c21_apply_branch_stock_delta(
  p_account_id uuid,
  p_product_id uuid,
  p_branch_id  uuid,
  p_delta      numeric
)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_branch_id uuid := p_branch_id;
BEGIN
  IF p_account_id IS NULL OR p_product_id IS NULL
     OR p_delta IS NULL OR p_delta = 0 THEN
    RETURN;
  END IF;

  -- C-26: branch destino = la indicada, o la default OPERATIVA de la cuenta.
  IF v_branch_id IS NULL THEN
    v_branch_id := public.c26_default_branch(p_account_id);
  END IF;

  -- Cuenta sin branches (cuentas nuevas): lazy-create de la default.
  IF v_branch_id IS NULL THEN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (p_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    v_branch_id := public.c26_default_branch(p_account_id);
  END IF;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (p_account_id, p_product_id, v_branch_id, p_delta)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity + EXCLUDED.quantity;
END;
$$;


-- ============================================================
-- 4. Lifecycle RPCs: rpc_open_branch / rpc_close_branch
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_open_branch(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        uuid;
  v_account_id uuid;
  v_branch     RECORD;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can open a branch'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'active' THEN
    RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'active', 'changed', false);
  END IF;

  UPDATE public.branches
  SET    status = 'active', opened_at = now()
  WHERE  id = p_branch_id;

  RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'active', 'changed', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_close_branch(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_branch       RECORD;
  v_stock        numeric;
  v_other_active integer;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can close a branch'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'closed', 'changed', false);
  END IF;

  -- OQ-B: cierre bloqueado si la sucursal tiene stock (transferir primero)
  SELECT COALESCE(SUM(quantity), 0) INTO v_stock
  FROM   public.branch_stock
  WHERE  branch_id = p_branch_id;

  IF v_stock > 0 THEN
    RAISE EXCEPTION 'branch_has_stock: la sucursal tiene % unidades — transferí el stock antes de cerrarla', v_stock
      USING ERRCODE = 'P0409';
  END IF;

  -- D6: debe quedar al menos una sucursal operativa en la cuenta
  SELECT count(*) INTO v_other_active
  FROM   public.branches
  WHERE  account_id = v_account_id AND is_active = TRUE
    AND  status = 'active' AND id <> p_branch_id;

  IF v_other_active = 0 THEN
    RAISE EXCEPTION 'last_active_branch: no se puede cerrar la única sucursal operativa de la cuenta'
      USING ERRCODE = 'P0409';
  END IF;

  UPDATE public.branches
  SET    status = 'closed', closed_at = now()
  WHERE  id = p_branch_id;

  RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'closed', 'changed', true);
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_open_branch(uuid)  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_open_branch(uuid)  FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_open_branch(uuid)  TO authenticated;
REVOKE ALL     ON FUNCTION public.rpc_close_branch(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_close_branch(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_close_branch(uuid) TO authenticated;


-- ============================================================
-- 5. rpc_transfer_stock — crea StockTransfer + valida lifecycle
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_transfer_stock(p_product_id uuid, p_from_branch_id uuid, p_to_branch_id uuid, p_quantity numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_from           RECORD;
  v_to             RECORD;
  v_from_qty       numeric(15,4);
  v_to_qty         numeric(15,4);
  v_product_name   text;
  v_transfer_id    uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can transfer stock'
      USING ERRCODE = 'P0401';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
  END IF;

  IF p_from_branch_id = p_to_branch_id THEN
    RAISE EXCEPTION 'same_branch_transfer_not_allowed' USING ERRCODE = 'P0400';
  END IF;

  -- Ambas branches de la cuenta, existentes y OPERATIVAS (C-26)
  SELECT id, status INTO v_from
  FROM   public.branches
  WHERE  id = p_from_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: origin branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_from.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de origen está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT id, status INTO v_to
  FROM   public.branches
  WHERE  id = p_to_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: destination branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_to.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de destino está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Lock de las filas de ledger (origen primero, destino si existe)
  SELECT quantity INTO v_from_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_from_branch_id
  FOR UPDATE;

  SELECT quantity INTO v_to_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_to_branch_id
  FOR UPDATE;

  v_from_qty := COALESCE(v_from_qty, 0);
  v_to_qty   := COALESCE(v_to_qty, 0);

  IF v_from_qty < p_quantity THEN
    RAISE EXCEPTION 'insufficient_branch_stock: origin has %, requested %',
      v_from_qty, p_quantity
      USING ERRCODE = 'P0409';
  END IF;

  -- C-26 (D3): la transferencia es una entidad con identidad propia
  INSERT INTO public.stock_transfers (
    account_id, product_id, from_branch_id, to_branch_id, quantity, status, created_by
  ) VALUES (
    v_account_id, p_product_id, p_from_branch_id, p_to_branch_id, p_quantity, 'completed', v_uid
  )
  RETURNING id INTO v_transfer_id;

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_out',
    -p_quantity, v_from_qty, v_from_qty - p_quantity,
    'transfer', v_uid, p_from_branch_id, v_transfer_id
  );

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_in',
    p_quantity, v_to_qty, v_to_qty + p_quantity,
    'transfer', v_uid, p_to_branch_id, v_transfer_id
  );

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_from_branch_id, GREATEST(0, v_from_qty - p_quantity))
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity - p_quantity;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_to_branch_id, p_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity + p_quantity;

  RETURN jsonb_build_object(
    'transfer_id',          v_transfer_id,
    'from_branch_id',       p_from_branch_id,
    'to_branch_id',         p_to_branch_id,
    'product_id',           p_product_id,
    'quantity_transferred', p_quantity
  );
END;
$function$;


-- ============================================================
-- 6. rpc_adjust_branch_stock — + validación de branch operativa
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_adjust_branch_stock(p_product_id uuid, p_branch_id uuid, p_new_quantity numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_branch       RECORD;
  v_old_quantity numeric(15,4);
  v_product_name text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa'
      USING ERRCODE = 'P0403';
  END IF;

  -- Only owner/admin can adjust stock
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can adjust branch stock'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validate new quantity
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RAISE EXCEPTION 'New quantity must be >= 0' USING ERRCODE = 'P0400';
  END IF;

  -- Verify branch belongs to this account and is operative (C-26)
  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or unauthorized'
      USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Verify product exists
  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Get current quantity (default 0 if no row exists)
  SELECT quantity INTO v_old_quantity
  FROM   public.branch_stock
  WHERE  product_id = p_product_id
    AND  branch_id  = p_branch_id;

  v_old_quantity := COALESCE(v_old_quantity, 0);

  -- Insert adjustment stock_movement
  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, notes
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'adjustment',
    p_new_quantity - v_old_quantity, v_old_quantity, p_new_quantity,
    'adjustment', v_uid, p_branch_id, p_reason
  );

  -- UPSERT branch_stock
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_branch_id, p_new_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = p_new_quantity;

  RETURN jsonb_build_object(
    'product_id',   p_product_id,
    'branch_id',    p_branch_id,
    'old_quantity', v_old_quantity,
    'new_quantity', p_new_quantity
  );
END;
$function$;


-- ============================================================
-- 7. rpc_apply_product_stock_delta — branch operativa + floor (OQ-C)
--    Firma CONSERVADA: p_allow_negative=TRUE ahora significa "floor a 0
--    trazable" (el CHECK prohíbe negativos físicos).
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_apply_product_stock_delta(
  p_product_id     uuid,
  p_delta          numeric,
  p_branch_id      uuid    DEFAULT NULL,
  p_reason         text    DEFAULT NULL,
  p_log_movement   boolean DEFAULT TRUE,
  p_allow_negative boolean DEFAULT FALSE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           uuid;
  v_account_id    uuid;
  v_product       RECORD;
  v_branch        RECORD;
  v_target_branch uuid;
  v_branch_qty    numeric(15,4);
  v_applied       numeric(15,4);
  v_before        numeric(15,4);
  v_after         numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'p_delta must be non-zero' USING ERRCODE = 'P0400';
  END IF;

  -- Lock de la fila del producto = mutex por producto
  SELECT id, name, account_id INTO v_product
  FROM   public.products
  WHERE  id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  IF v_product.account_id IS DISTINCT FROM v_account_id THEN
    RAISE EXCEPTION 'Permission denied to product: %', p_product_id USING ERRCODE = 'P0403';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch destino resuelta (explícita o default operativa)
  v_target_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_target_branch;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  v_applied := p_delta;

  IF p_delta < 0 AND v_branch_qty + p_delta < 0 THEN
    IF p_allow_negative THEN
      -- OQ-C: floor a 0 trazable — se aplica solo lo disponible y se registra
      -- el ajuste explícito (caso típico: reversa de compra ya vendida).
      v_applied := -v_branch_qty;
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reason, notes, performed_by, branch_id
      ) VALUES (
        v_uid, v_account_id, p_product_id, v_product.name, 'adjustment',
        v_applied, v_branch_qty, 0,
        'floor_on_purchase_delete',
        format('Reversa solicitada: %s, aplicada: %s (stock ya vendido)', p_delta, v_applied),
        v_uid, v_target_branch
      );
    ELSE
      RAISE EXCEPTION 'Stock insuficiente. Disponible: %, delta: %', v_branch_qty, p_delta
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  v_before := v_branch_qty;
  v_after  := v_branch_qty + v_applied;

  IF v_applied <> 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(
      v_account_id, p_product_id, v_target_branch, v_applied);
  END IF;

  IF p_log_movement AND v_applied <> 0 THEN
    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reason, performed_by, branch_id
    ) VALUES (
      v_uid, v_account_id, p_product_id, v_product.name, 'adjustment',
      v_applied, v_before, v_after,
      p_reason, v_uid, v_target_branch
    );
  END IF;

  RETURN jsonb_build_object(
    'product_id',      p_product_id,
    'branch_id',       v_target_branch,
    'quantity_before', v_before,
    'quantity_after',  v_after,
    'quantity_delta',  v_applied,
    'floored',         (v_applied <> p_delta)
  );
END;
$function$;


-- ============================================================
-- 8. rpc_stock_adjustment — gate contra la default operativa
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_stock_adjustment(p_product_id uuid, p_quantity_delta numeric DEFAULT NULL::numeric, p_type text DEFAULT 'adjustment'::text, p_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_reference_id uuid DEFAULT NULL::uuid, p_target_quantity numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_product      RECORD;
  v_account_id   uuid;
  v_stock_sum    numeric(15,4);
  v_target_branch uuid;
  v_branch_qty   numeric(15,4);
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_delta        numeric;
  v_movement_id  uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_type NOT IN (
    'adjustment', 'physical_count', 'loss', 'damage',
    'expiry', 'transfer_in', 'transfer_out'
  ) THEN
    RAISE EXCEPTION
      'Tipo de movimiento no válido para ajuste manual: %. '
      'Permitidos: adjustment, physical_count, loss, damage, expiry, transfer_in, transfer_out',
      p_type
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_quantity_delta IS NULL AND p_target_quantity IS NULL THEN
    RAISE EXCEPTION 'Se requiere p_quantity_delta o p_target_quantity'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Lock row BEFORE computing delta (critical for physical_count).
  SELECT id, name, stock_control_type, account_id
  INTO   v_product
  FROM   public.products
  WHERE  id = p_product_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado o acceso denegado'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_product.stock_control_type IN ('variant_only', 'untracked') THEN
    RAISE EXCEPTION
      'Este producto no permite ajuste manual de stock (stock_control_type = %). '
      'Los productos "variant_only" se gestionan a través de sus variantes; '
      'los "untracked" no tienen stock físico.',
      v_product.stock_control_type
      USING ERRCODE = 'check_violation';
  END IF;

  v_account_id := COALESCE(
    v_product.account_id,
    (SELECT cai FROM current_account_ids() AS cai LIMIT 1)
  );

  SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
  FROM   public.branch_stock
  WHERE  product_id = p_product_id;

  IF p_type = 'physical_count' AND p_target_quantity IS NOT NULL THEN
    v_delta := p_target_quantity - v_stock_sum;
  ELSE
    v_delta := p_quantity_delta;
    IF v_delta = 0 THEN
      RAISE EXCEPTION 'quantity_delta no puede ser cero para tipo %', p_type
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_qty_before := v_stock_sum;
  v_qty_after  := v_stock_sum + v_delta;

  IF v_qty_after < 0 THEN
    RAISE EXCEPTION
      'Stock insuficiente. Disponible: %, solicitado quitar: %',
      v_qty_before, ABS(v_delta)
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- C-26: el ajuste global aplica sobre la default operativa; con stock
  -- repartido en sucursales, el delta negativo no puede exceder lo que hay
  -- en ella (usar el ajuste por sucursal en ese caso).
  v_target_branch := public.c26_default_branch(v_account_id);

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_target_branch;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  IF v_delta < 0 AND v_branch_qty + v_delta < 0 THEN
    RAISE EXCEPTION
      'El ajuste excede el stock de la sucursal principal (% disponibles). Usá el ajuste por sucursal.',
      v_branch_qty
      USING ERRCODE = 'P0409';
  END IF;

  IF v_delta != 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(
      v_account_id, p_product_id, v_target_branch, v_delta);
  END IF;

  INSERT INTO public.stock_movements (
    user_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reason, notes, performed_by,
    reference_id, reference_type
    -- operation_group_id intentionally NULL: single-movement operation
  ) VALUES (
    v_uid, p_product_id, v_product.name, p_type,
    v_delta, v_qty_before, v_qty_after,
    p_reason, p_notes, v_uid,
    p_reference_id,
    CASE WHEN p_reference_id IS NOT NULL THEN 'adjustment' ELSE NULL END
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',     v_movement_id,
    'product_id',      p_product_id,
    'product_name',    v_product.name,
    'quantity_before', v_qty_before,
    'quantity_after',  v_qty_after,
    'quantity_delta',  v_delta,
    'type',            p_type
  );
END;
$function$;


-- ============================================================
-- 9a. rpc_create_sale_operation (wrapper + legacy) — gate per-branch
--     + validación de sucursal cerrada (C-26)
-- ============================================================
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
          SELECT id, user_id, is_variant, name INTO v_product
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

          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id, branch_id
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
            -v_qty_norm, v_qty_before, v_qty_after,
            v_new_sale_id, 'sale', v_uid,
            v_new_op_id, p_branch_id
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


-- ============================================================
-- 9b. rpc_create_sale_operation_v2 — gate per-branch + branch cerrada (C-26)
-- ============================================================
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
      SELECT id, user_id, is_variant, name INTO v_product
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

      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity
      );

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, p_branch_id
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
$function$;


-- =============================================================================
-- VERIFICATION (post-push):
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='branches' AND column_name IN ('status','opened_at','closed_at'); -- 3
--   SELECT count(*) FROM pg_proc WHERE proname IN ('rpc_open_branch','rpc_close_branch','c26_default_branch'); -- 3
--   SELECT conname FROM pg_constraint WHERE conrelid='public.branch_stock'::regclass AND contype='c'; -- incluye non_negative
--   -- Smoke: transferencia crea stock_transfers + 2 movements con transfer_id;
--   --        venta con branch sin stock local → P0409; venta en branch cerrada → P0422;
--   --        close con stock → P0409 branch_has_stock.
-- =============================================================================
