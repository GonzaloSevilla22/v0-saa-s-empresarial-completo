-- =============================================================================
-- MIGRATION: 20260702000001_c29_quote_salesorder.sql
-- CHANGE:    C-29 v21-quote-salesorder — Quote / SalesOrder / quickSale POS
--
-- Implementa (design.md, OQs resueltas por el PO 2026-06-17):
--   1. ADD COLUMN IF NOT EXISTS a public.events (outbox reshape — OQ-5).
--   2. Tablas: quotes, quote_items, sales_orders, sales_order_items.
--   3. RLS en las 4 tablas nuevas:
--      - SELECT en las 4 (account_id IN (SELECT current_account_ids()))
--      - INSERT/UPDATE en quotes/quote_items (escritura directa del repo, D3)
--      - NO INSERT/UPDATE en sales_orders/sales_order_items (solo RPC, D2)
--   4. RPCs SECURITY DEFINER:
--      - rpc_accept_quote: transiciona Quote→accepted + crea SalesOrder + items
--      - rpc_confirm_sales_order: hot path transaccional (stock+caja+fiscal+outbox)
--      - rpc_quick_sale: crea+confirma en un paso (POS)
--   5. Gates SQL (DO block — RED→GREEN) con ROLLBACK total.
--
-- Decisiones clave:
--   OQ-1: comprobante explícito y NULLABLE (quickSale puede confirmar sin fiscal)
--   OQ-2: payment_method = cash | other (crédito→C-30)
--   OQ-3: branch_id NOT NULL en sales_orders (DEC-19); RPC resuelve default
--   OQ-4: expire() = comando + cómputo defensivo on-read; sin pg_cron
--   OQ-5: ADD COLUMN IF NOT EXISTS sobre el stub events; INSERT en commit
--
-- ERRCODEs (5 chars):
--   P0400 — payload inválido (cash sin session, idempotency_key vacío, etc.)
--   P0401 — sin permiso de escritura (is_account_writer)
--   P0403 — sin cuenta activa
--   P0404 — entidad no encontrada
--   P0409 — stock insuficiente, sesión de caja cerrada, quote ya aceptado
--   P0422 — branch cerrada, PV ambiguo
--
-- GOVERNANCE: MEDIO.
-- APPLY:  npx supabase db push  (NUNCA MCP apply_migration — desincroniza history)
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS
--     public.rpc_quick_sale(text, uuid, jsonb, text, uuid, text, uuid, uuid, text),
--     public.rpc_confirm_sales_order(text, uuid, text, uuid, text, uuid, uuid, text),
--     public.rpc_accept_quote(uuid);
--   DROP TABLE IF EXISTS
--     public.sales_order_items,
--     public.sales_orders,
--     public.quote_items,
--     public.quotes;
--   (orden inverso de FKs; las columnas añadidas a events pueden quedar inertes
--    o dropearse manualmente: sin pérdida de datos — feature nueva, 0 filas)
-- =============================================================================


-- ============================================================
-- 2.1 Outbox reshape: ADD COLUMN IF NOT EXISTS sobre public.events
--     El stub (id, company_id, title, created_at) queda intacto.
--     Estos campos permiten a C-25 consumir SaleConfirmed sin re-migrar.
-- ============================================================
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS account_id     uuid,
  ADD COLUMN IF NOT EXISTS event_type     text,
  ADD COLUMN IF NOT EXISTS aggregate_type text,
  ADD COLUMN IF NOT EXISTS aggregate_id   uuid,
  ADD COLUMN IF NOT EXISTS payload        jsonb,
  ADD COLUMN IF NOT EXISTS occurred_at    timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS processed_at  timestamptz;

-- Policy SELECT para events por account_id (RLS ya habilitada en stub migration)
DROP POLICY IF EXISTS "Users can access their events" ON public.events;
CREATE POLICY events_select
  ON public.events
  FOR SELECT
  USING (
    account_id IN (SELECT public.current_account_ids())
  );

COMMENT ON TABLE public.events IS
  'Outbox transaccional. Stub original (company_id, title) preservado para CI-compat. '
  'C-29 agrega columnas de dominio: account_id, event_type, aggregate_*, payload, occurred_at, processed_at. '
  'C-25 activará el relay de consumers sobre esta tabla.';


-- ============================================================
-- 2.2 TABLE: quotes
-- ============================================================
CREATE TABLE IF NOT EXISTS public.quotes (
  id            uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id    uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  branch_id     uuid        REFERENCES public.branches(id) ON DELETE SET NULL,
  client_id     uuid        REFERENCES public.clients(id) ON DELETE SET NULL,
  status        text        NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft','sent','accepted','expired','rejected')),
  valid_until   date,
  total         numeric(15,2) NOT NULL DEFAULT 0,
  created_by    uuid        NOT NULL REFERENCES auth.users(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS quotes_account_id_created_at_idx
  ON public.quotes (account_id, created_at DESC);

COMMENT ON TABLE public.quotes IS
  'C-29: Presupuesto/cotización. Ciclo de vida: draft→sent→accepted|expired|rejected. '
  'No toca stock ni caja. accept() materializa un SalesOrder.';

-- RLS
ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;

CREATE POLICY quotes_select
  ON public.quotes
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- D3: escritura directa del repo → políticas INSERT/UPDATE (espejo de fiscal_profiles)
CREATE POLICY quotes_insert
  ON public.quotes
  FOR INSERT
  WITH CHECK (public.is_account_writer(account_id));

CREATE POLICY quotes_update
  ON public.quotes
  FOR UPDATE
  USING (account_id IN (SELECT public.current_account_ids()))
  WITH CHECK (public.is_account_writer(account_id));


-- ============================================================
-- 2.2b TABLE: quote_items (desnormaliza account_id para RLS directa)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.quote_items (
  id          uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  quote_id    uuid          NOT NULL REFERENCES public.quotes(id) ON DELETE CASCADE,
  account_id  uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  product_id  uuid          REFERENCES public.products(id) ON DELETE SET NULL,
  unit_id     uuid          REFERENCES public.units_of_measure(id) ON DELETE SET NULL,
  quantity    numeric(15,4) NOT NULL CHECK (quantity > 0),
  price       numeric(15,2) NOT NULL CHECK (price >= 0),
  subtotal    numeric(15,2) NOT NULL CHECK (subtotal >= 0)
);

CREATE INDEX IF NOT EXISTS quote_items_quote_id_idx
  ON public.quote_items (quote_id);

COMMENT ON TABLE public.quote_items IS
  'C-29: Líneas del presupuesto. account_id desnormalizado para RLS directa. '
  'product_id nullable (líneas de servicio). No afecta branch_stock.';

-- RLS
ALTER TABLE public.quote_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY quote_items_select
  ON public.quote_items
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- D3: escritura directa del repo
CREATE POLICY quote_items_insert
  ON public.quote_items
  FOR INSERT
  WITH CHECK (public.is_account_writer(account_id));

CREATE POLICY quote_items_update
  ON public.quote_items
  FOR UPDATE
  USING (account_id IN (SELECT public.current_account_ids()))
  WITH CHECK (public.is_account_writer(account_id));


-- ============================================================
-- 2.3 TABLE: sales_orders
--     branch_id NOT NULL (OQ-3 / DEC-19): el RPC resuelve default branch.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sales_orders (
  id                  uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id          uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  branch_id           uuid        NOT NULL REFERENCES public.branches(id),
  client_id           uuid        REFERENCES public.clients(id) ON DELETE SET NULL,
  source_quote_id     uuid        REFERENCES public.quotes(id) ON DELETE SET NULL,
  status              text        NOT NULL DEFAULT 'draft'
                                  CHECK (status IN ('draft','confirmed','canceled')),
  payment_method      text        NOT NULL DEFAULT 'other'
                                  CHECK (payment_method IN ('cash','other')),
  total               numeric(15,2) NOT NULL DEFAULT 0,
  sale_operation_id   uuid,          -- puente: operation_id de la venta legacy generada
  fiscal_document_id  uuid        REFERENCES public.fiscal_documents(id) ON DELETE SET NULL,
  created_by          uuid        NOT NULL REFERENCES auth.users(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sales_orders_account_id_created_at_idx
  ON public.sales_orders (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS sales_orders_source_quote_id_idx
  ON public.sales_orders (source_quote_id)
  WHERE source_quote_id IS NOT NULL;

COMMENT ON TABLE public.sales_orders IS
  'C-29: Orden de venta. confirm() es transaccional (stock+caja+fiscal+outbox en un commit). '
  'branch_id NOT NULL (DEC-19). Escritura SOLO vía RPCs SECURITY DEFINER (D2). '
  'sale_operation_id = puente de retrocompat con la tabla sales legacy.';

-- RLS: solo SELECT (escritura por RPC SECURITY DEFINER, D2)
ALTER TABLE public.sales_orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY sales_orders_select
  ON public.sales_orders
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));


-- ============================================================
-- 2.3b TABLE: sales_order_items (desnormaliza account_id para RLS)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sales_order_items (
  id              uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  sales_order_id  uuid          NOT NULL REFERENCES public.sales_orders(id) ON DELETE CASCADE,
  account_id      uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  product_id      uuid          REFERENCES public.products(id) ON DELETE SET NULL,
  unit_id         uuid          REFERENCES public.units_of_measure(id) ON DELETE SET NULL,
  quantity        numeric(15,4) NOT NULL CHECK (quantity > 0),
  price           numeric(15,2) NOT NULL CHECK (price >= 0),
  subtotal        numeric(15,2) NOT NULL CHECK (subtotal >= 0)
);

CREATE INDEX IF NOT EXISTS sales_order_items_sales_order_id_idx
  ON public.sales_order_items (sales_order_id);

COMMENT ON TABLE public.sales_order_items IS
  'C-29: Líneas de la orden de venta. account_id desnormalizado. '
  'Escritura SOLO vía RPCs SECURITY DEFINER (D2).';

-- RLS: solo SELECT (escritura por RPC, D2)
ALTER TABLE public.sales_order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY sales_order_items_select
  ON public.sales_order_items
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));


-- ============================================================
-- 3.1 RPC: rpc_accept_quote
--     Transiciona Quote a accepted y crea SalesOrder+items atómicamente.
--     No toca stock ni caja.
-- ============================================================
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

  -- Copiar quote_items → sales_order_items
  FOR v_item IN
    SELECT * FROM public.quote_items WHERE quote_id = p_quote_id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal);
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

REVOKE ALL    ON FUNCTION public.rpc_accept_quote(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_accept_quote(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_accept_quote IS
  'C-29 (D3): acepta un Quote (draft|sent + no expirado) y crea un SalesOrder en draft '
  'con los mismos ítems. No toca stock ni caja — eso es SalesOrder.confirm(). Atómico.';


-- ============================================================
-- 3.2 INTERNAL HELPER: _c29_confirm_order_core
--     Hot path transaccional compartido entre rpc_confirm_sales_order y rpc_quick_sale.
--     SECURITY DEFINER: puede invocar c28_register_cash_movement (revocado de PUBLIC).
--     NO es llamable externamente — REVOKE de PUBLIC.
-- ============================================================
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
      -- Lock del producto para serializar
      SELECT id, user_id, name INTO v_product
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

      -- stock_movements (reference_type='sale')
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy
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

-- REVOKE: helper interno — NO callable desde rol authenticated
REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._c29_confirm_order_core IS
  'C-29 (D1): helper interno compartido por rpc_confirm_sales_order y rpc_quick_sale. '
  'SECURITY DEFINER para poder invocar c28_register_cash_movement (revocado de PUBLIC). '
  'No callable externamente. Atómico: un fallo aborta todo el commit.';


-- ============================================================
-- 3.2 PUBLIC RPC: rpc_confirm_sales_order
--     Thin wrapper sobre _c29_confirm_order_core.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_confirm_sales_order(
  p_idempotency_key   text,
  p_sales_order_id    uuid,
  p_payment_method    text,
  p_cash_session_id   uuid   DEFAULT NULL,
  p_comprobante_type  text   DEFAULT NULL,
  p_point_of_sale_id  uuid   DEFAULT NULL,
  p_branch_id         uuid   DEFAULT NULL,   -- ignorado (branch ya en la orden)
  p_canal             text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    p_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.rpc_confirm_sales_order(text,uuid,text,uuid,text,uuid,uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_confirm_sales_order(text,uuid,text,uuid,text,uuid,uuid,text) TO authenticated;

COMMENT ON FUNCTION public.rpc_confirm_sales_order IS
  'C-29: Confirma una SalesOrder existente en draft. '
  'Hot path transaccional: stock + caja + fiscal + outbox en un commit. '
  'Idempotente por idempotency_key (DEC-06).';


-- ============================================================
-- 3.3 PUBLIC RPC: rpc_quick_sale (POS — crea + confirma en un paso)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_quick_sale(
  p_idempotency_key   text,
  p_client_id         uuid   DEFAULT NULL,
  p_items             jsonb  DEFAULT '[]'::jsonb,
  p_payment_method    text   DEFAULT 'other',
  p_cash_session_id   uuid   DEFAULT NULL,
  p_comprobante_type  text   DEFAULT NULL,
  p_point_of_sale_id  uuid   DEFAULT NULL,
  p_branch_id         uuid   DEFAULT NULL,
  p_canal             text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_sales_order_id uuid;
  v_item           RECORD;
  v_total          numeric(15,2) := 0;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar items
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch
  v_branch_id := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular total inicial
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'quantity debe ser > 0' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.price IS NULL OR v_item.price < 0 THEN
      RAISE EXCEPTION 'price debe ser >= 0' USING ERRCODE = 'P0400';
    END IF;
    v_total := v_total + COALESCE(v_item.subtotal, v_item.price * v_item.quantity);
  END LOOP;

  -- Crear SalesOrder en draft
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, status, payment_method, total, created_by)
  VALUES
    (v_account_id, v_branch_id, p_client_id, 'draft', p_payment_method, v_total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- Crear sales_order_items
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price,
       COALESCE(v_item.subtotal, v_item.price * v_item.quantity));
  END LOOP;

  -- Confirmar inline (hot path transaccional)
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    v_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.rpc_quick_sale(text,uuid,jsonb,text,uuid,text,uuid,uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_quick_sale(text,uuid,jsonb,text,uuid,text,uuid,uuid,text) TO authenticated;

COMMENT ON FUNCTION public.rpc_quick_sale IS
  'C-29: Crea y confirma una SalesOrder en un solo paso (POS). '
  'Idempotente por idempotency_key. Internamente usa _c29_confirm_order_core.';


-- ============================================================
-- 3.4 Gates SQL (RED→GREEN validados — ROLLBACK total al final)
-- Patrón C-28 §1.9: SAVEPOINTs con ROLLBACK total al final.
-- ============================================================
DO $$
DECLARE
  v_got_cash_no_session  boolean := false;
  v_got_check_method     boolean := false;
  v_got_check_qty        boolean := false;
  v_got_check_status     boolean := false;
BEGIN

  -- (a) payment_method='cash' sin session_id → P0400
  -- Verificamos el CHECK de la columna status y el CHECK de payment_method
  BEGIN
    INSERT INTO public.sales_orders
      (account_id, branch_id, status, payment_method, total, created_by)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), 'draft', 'credit', 0, gen_random_uuid());
    RAISE EXCEPTION 'GATE a FAILED: debería haber violado CHECK payment_method';
  EXCEPTION
    WHEN check_violation THEN
      v_got_check_method := true;
  END;

  IF NOT v_got_check_method THEN
    RAISE EXCEPTION 'GATE a: CHECK payment_method no rechazó credit';
  END IF;

  -- (b) status inválido → CHECK violation
  BEGIN
    INSERT INTO public.sales_orders
      (account_id, branch_id, status, payment_method, total, created_by)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), 'invalid_status', 'other', 0, gen_random_uuid());
    RAISE EXCEPTION 'GATE b FAILED: debería haber violado CHECK status';
  EXCEPTION
    WHEN check_violation THEN
      v_got_check_status := true;
  END;

  IF NOT v_got_check_status THEN
    RAISE EXCEPTION 'GATE b: CHECK status no rechazó invalid_status';
  END IF;

  -- (c) quote_items quantity <= 0 → CHECK violation
  BEGIN
    INSERT INTO public.quote_items
      (quote_id, account_id, quantity, price, subtotal)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), 0, 100, 0);
    RAISE EXCEPTION 'GATE c FAILED: debería haber violado CHECK quantity > 0';
  EXCEPTION
    WHEN check_violation THEN
      v_got_check_qty := true;
  END;

  IF NOT v_got_check_qty THEN
    RAISE EXCEPTION 'GATE c: CHECK quantity no rechazó 0';
  END IF;

  RAISE NOTICE 'C-29 SQL gates: (a) CHECK payment_method OK, (b) CHECK status OK, (c) CHECK quantity OK';
  RAISE NOTICE 'C-29 SQL gates: tablas, índices, RLS y RPCs creados exitosamente';
END $$;


-- ============================================================
-- 3.5 VERIFICATION block (post-push)
-- Estas consultas pueden correrse manualmente después del push
-- para confirmar que todos los objetos existen:
--
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public'
--     AND table_name IN ('quotes','quote_items','sales_orders','sales_order_items')
--   ORDER BY table_name;
--
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name IN ('rpc_accept_quote','rpc_confirm_sales_order','rpc_quick_sale',
--                          '_c29_confirm_order_core')
--   ORDER BY routine_name;
--
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema = 'public' AND table_name = 'events'
--     AND column_name IN ('account_id','event_type','payload','occurred_at')
--   ORDER BY column_name;
-- ============================================================
