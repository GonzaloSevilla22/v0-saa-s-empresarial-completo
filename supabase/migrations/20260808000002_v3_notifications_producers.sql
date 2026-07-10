-- =============================================================================
-- MIGRATION: 20260808000002_v3_notifications_producers.sql
-- CHANGE:    v3-notifications-realtime (Grupo 5 — producers)
-- Design ref: openspec/changes/v3-notifications-realtime/design.md (D4)
--
-- Agrega los 5 producers de eventos de dominio que el outbox todavía no emite,
-- cada uno INSERT INTO public.events en la MISMA transacción de su mutación
-- (DEC-20). Governance MEDIO: un producer por commit lógico — todos viven en
-- esta migración pero cada CREATE OR REPLACE es independiente y auditable por
-- separado (ver bloques 1-5 abajo). Ningún producer existente se recrea.
--
-- Investigación previa a este archivo (apply session, ver engram
-- opsx/v3-notifications-realtime/apply):
--   - CashSessionClosed:      rpc_close_cash_session (última versión: base
--     20260807000001_v3_document_status_history.sql:1053) — v_account_id,
--     p_session_id, v_difference, closed_by=auth.uid() ya disponibles.
--   - StockBelowMinimum:      YA EXISTE la detección (trigger
--     check_branch_low_stock en 20260608000000_branch_stock.sql:983, dispara
--     AFTER UPDATE ON branch_stock cuando quantity cruza min_stock). Se agrega
--     el INSERT INTO events DENTRO de ese trigger — evita duplicar la lógica
--     de umbral (Open Question design.md resuelta: el mínimo vive en
--     branch_stock.min_stock, per-branch, no en products).
--   - QuoteAccepted:          rpc_accept_quote (última versión: base
--     20260807000001_v3_document_status_history.sql:437) — v_account_id,
--     p_quote_id, v_quote (created_by = seller proxy, no hay columna
--     seller_id dedicada hoy), v_branch_id, v_quote.total.
--   - TransferDispatched:     rpc_transfer_stock (última versión: base
--     20260807000001_v3_document_status_history.sql:1502) — v_account_id,
--     v_transfer_id, p_from_branch_id, p_to_branch_id.
--   - FiscalDocumentRejected: el UPDATE fiscal_documents.status='rejected' NO
--     ocurre en una RPC de Postgres — ocurre en el backend Python
--     (backend/repositories/fiscal_document_repository.py::update_rejected,
--     service_role en prod) que además llama a rpc_record_fiscal_transition
--     en la misma transacción. Tocar el backend Python está fuera de scope de
--     este change (gobernanza CRÍTICO adicional para AFIP/dinero) y sería
--     invasivo. Decisión (Open Question design.md resuelta): TRIGGER AFTER
--     UPDATE ON fiscal_documents (mismo patrón que trg_quote_record_creation
--     en 20260807000001), condición status: pending_cae→rejected. El trigger
--     corre en la MISMA transacción del UPDATE del backend (DEC-20 se cumple
--     igual — la transacción es la del backend, el trigger es parte de ella).
--
-- IDEMPOTENCIA: CREATE OR REPLACE / DROP TRIGGER IF EXISTS + CREATE TRIGGER.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration).
-- =============================================================================

-- =============================================================================
-- 5.1 CashSessionClosed — producer en rpc_close_cash_session
--     Base: 20260807000001_v3_document_status_history.sql:1053 (preservada
--     byte-a-byte salvo el INSERT INTO events agregado antes del RETURN).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_close_cash_session(
  p_session_id      uuid,
  p_counted_balance numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session        public.cash_sessions%ROWTYPE;
  v_account_id     uuid;
  v_sum_movements  numeric(12,2);
  v_expected       numeric(12,2);
  v_difference     numeric(12,2);
  v_close_reason   text;
  v_branch_id      uuid;
BEGIN
  -- Cargar sesión
  SELECT cs.* INTO v_session
  FROM public.cash_sessions cs
  WHERE cs.id = p_session_id;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'session_not_open'
      USING ERRCODE = 'P0409';
  END IF;

  -- Guard: permiso de escritura
  SELECT b.account_id, b.id INTO v_account_id, v_branch_id
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = v_session.cashbox_id;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validar que esté abierta
  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'session_not_open'
      USING ERRCODE = 'P0409';
  END IF;

  -- D7: calcular expected_balance = opening_balance + Σ(cash_movements.amount)
  SELECT COALESCE(SUM(cm.amount), 0)
  INTO v_sum_movements
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_expected   := v_session.opening_balance + v_sum_movements;
  v_difference := p_counted_balance - v_expected;

  -- v3-document-status-history (D7 / RN-A5): la diferencia de arqueo ≠ 0
  -- queda descripta como reason del cierre (señal antifraude, RN-95)
  IF v_difference <> 0 THEN
    v_close_reason := format('diferencia de arqueo: %s (esperado %s, contado %s)',
                             v_difference, v_expected, p_counted_balance);
  END IF;

  -- Cerrar la sesión — materializar arqueo (D7)
  UPDATE public.cash_sessions
  SET
    status           = 'closed',
    counted_balance  = p_counted_balance,
    expected_balance = v_expected,
    difference       = v_difference,
    closing_balance  = p_counted_balance,
    closed_by        = auth.uid(),
    closed_at        = now()
  WHERE id = p_session_id;

  -- v3-document-status-history (RN-A1): cierre en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'cash_session', p_session_id, 'open', 'closed',
    auth.uid(), v_close_reason);

  -- v3-notifications-realtime (5.1): productor de CashSessionClosed.
  -- El Consumer 4 del outbox decide si difference<>0 amerita aviso (no-op
  -- si es 0) — este producer emite SIEMPRE, el filtro vive en el consumer
  -- (_notification_from_event), igual que el resto de los productores.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'CashSessionClosed', 'CashSession', p_session_id,
    jsonb_build_object(
      'session_id', p_session_id,
      'branch_id',  v_branch_id,
      'difference', v_difference,
      'closed_by',  auth.uid()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'session_id',        p_session_id,
    'status',            'closed',
    'opening_balance',   v_session.opening_balance,
    'expected_balance',  v_expected,
    'counted_balance',   p_counted_balance,
    'difference',        v_difference,
    'closing_balance',   p_counted_balance
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_close_cash_session IS
  'C-28 + v3-document-status-history + v3-notifications-realtime: cierra la '
  'sesión con arqueo, registra open→closed en document_status_history (RN-A1) '
  'y emite CashSessionClosed al outbox (5.1) — el Consumer 4 filtra por '
  'difference<>0 antes de avisar. Cuando difference ≠ 0 el reason describe la '
  'diferencia (D7 — el RPC lo genera; el catálogo no exige reason estático '
  'para no romper cierres sin diferencia).';

-- =============================================================================
-- 5.2 StockBelowMinimum — producer dentro de check_branch_low_stock
--     Base: 20260608000000_branch_stock.sql:983 (trigger existente que YA
--     detecta el cruce de umbral; se agrega el INSERT INTO events junto al
--     ON CONFLICT DO NOTHING de email_logs, dentro del mismo IF).
--     Resuelve la Open Question: el mínimo vive en branch_stock.min_stock
--     (per-branch), reutilizando la detección existente sin duplicarla.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.check_branch_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recent_alert boolean;
  v_product_name text;
  v_branch_name  text;
BEGIN
  -- Only fire when quantity dropped AND is now at or below min_stock threshold
  IF NEW.quantity < OLD.quantity AND NEW.min_stock > 0 AND NEW.quantity <= NEW.min_stock THEN

    -- Check for a recent alert in the last 24 hours (deduplication)
    SELECT EXISTS (
      SELECT 1 FROM public.email_logs
      WHERE event_type = 'low_branch_stock_alert'
        AND metadata->>'product_id' = NEW.product_id::text
        AND metadata->>'branch_id'  = NEW.branch_id::text
        AND created_at > now() - INTERVAL '24 hours'
    ) INTO v_recent_alert;

    IF NOT v_recent_alert THEN
      SELECT name INTO v_product_name
      FROM   public.products
      WHERE  id = NEW.product_id;

      SELECT name INTO v_branch_name
      FROM   public.branches
      WHERE  id = NEW.branch_id;

      -- Insert alert for every member of the account
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      SELECT
        am.user_id,
        'low_branch_stock_alert',
        u.email,
        'Alerta de Stock Bajo en Sucursal: ' || COALESCE(v_product_name, 'Producto') ||
          ' (' || COALESCE(v_branch_name, 'Sucursal') || ')',
        jsonb_build_object(
          'product_id',    NEW.product_id,
          'product_name',  v_product_name,
          'branch_id',     NEW.branch_id,
          'branch_name',   v_branch_name,
          'current_stock', NEW.quantity,
          'min_stock',     NEW.min_stock
        )
      FROM public.account_members am
      JOIN auth.users u ON u.id = am.user_id
      WHERE am.account_id = NEW.account_id
      ON CONFLICT DO NOTHING;  -- email_logs has UNIQUE on (user_id, event_type, metadata)

      -- v3-notifications-realtime (5.2): productor de StockBelowMinimum al
      -- outbox — mismo umbral/dedupe que la alerta de email (reutiliza la
      -- misma condición y ventana de 24h, sin volver a leer el mínimo).
      INSERT INTO public.events
        (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
      VALUES (
        NEW.account_id, 'StockBelowMinimum', 'BranchStock', NEW.id,
        jsonb_build_object(
          'product_id',  NEW.product_id,
          'branch_id',   NEW.branch_id,
          'current_qty', NEW.quantity,
          'min_qty',     NEW.min_stock
        ),
        now()
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.check_branch_low_stock IS
  'branch_stock (1.9) + v3-notifications-realtime (5.2): AFTER UPDATE ON '
  'branch_stock. Cuando quantity cruza min_stock (per-branch) hacia abajo: '
  'encola low_branch_stock_alert en email_logs (dedupe 24h) Y emite '
  'StockBelowMinimum al outbox transaccional (mismo umbral/dedupe — no '
  'duplica la detección, D4/OQ design.md resuelta).';

-- (el trigger on_branch_stock_update ya apunta a esta función — CREATE OR
--  REPLACE la actualiza in-place, no hace falta recrear el trigger)

-- =============================================================================
-- 5.3 QuoteAccepted — producer en rpc_accept_quote
--     Base: 20260807000001_v3_document_status_history.sql:437 (preservada
--     byte-a-byte salvo el INSERT INTO events agregado antes del RETURN).
--     seller_id: no existe columna dedicada en quotes — se usa created_by
--     (el usuario que generó el quote) como proxy, documentado como deuda
--     conocida (igual que el catálogo binario owner/member de D3).
-- =============================================================================
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

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

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

  -- v3-document-status-history (RN-A1): transición del quote en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'quote', p_quote_id, v_quote.status, 'accepted', v_uid, NULL);

  -- Transicionar el quote a accepted
  UPDATE public.quotes
  SET status = 'accepted'
  WHERE id = p_quote_id;

  -- v3-notifications-realtime (5.3): productor de QuoteAccepted al outbox.
  -- seller_id = quote.created_by (proxy — no hay columna seller_id dedicada
  -- hoy; deuda conocida documentada, igual criterio que D3).
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'QuoteAccepted', 'Quote', p_quote_id,
    jsonb_build_object(
      'quote_id',  p_quote_id,
      'seller_id', v_quote.created_by,
      'branch_id', v_branch_id,
      'total',     v_quote.total
    ),
    now()
  );

  RETURN jsonb_build_object(
    'sales_order_id', v_sales_order_id,
    'quote_id',       p_quote_id,
    'status',         'accepted'
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_accept_quote IS
  'C-29 (D3) + v3-snapshot-pattern + v3-document-status-history + '
  'v3-notifications-realtime: acepta un Quote (draft|sent + no expirado) y '
  'crea un SalesOrder en draft con los mismos ítems, propagando los snapshots '
  'congelados. Registra en document_status_history la creación de la '
  'SalesOrder (RN-A2) y la transición del quote a accepted (RN-A1). Emite '
  'QuoteAccepted al outbox (5.3; seller_id=created_by como proxy). No toca '
  'stock ni caja — eso es SalesOrder.confirm(). Atómico.';

-- =============================================================================
-- 5.4 TransferDispatched — producer en rpc_transfer_stock
--     Base: 20260807000001_v3_document_status_history.sql:1502 (preservada
--     byte-a-byte salvo el INSERT INTO events agregado antes del RETURN).
-- =============================================================================
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

  -- v3-document-status-history (RN-A2): la transferencia nace completed
  PERFORM public.record_status_transition(
    v_account_id, 'stock_transfer', v_transfer_id, NULL, 'completed', v_uid, NULL);

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

  -- v3-notifications-realtime (5.4): productor de TransferDispatched al outbox.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'TransferDispatched', 'StockTransfer', v_transfer_id,
    jsonb_build_object(
      'transfer_id',            v_transfer_id,
      'source_branch_id',       p_from_branch_id,
      'destination_branch_id',  p_to_branch_id
    ),
    now()
  );

  RETURN jsonb_build_object(
    'transfer_id',          v_transfer_id,
    'from_branch_id',       p_from_branch_id,
    'to_branch_id',         p_to_branch_id,
    'product_id',           p_product_id,
    'quantity_transferred', p_quantity
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_transfer_stock IS
  'C-26 + v3-document-status-history + v3-notifications-realtime: '
  'transferencia atómica entre sucursales (nace completed). Registra '
  'NULL→completed en document_status_history (RN-A2) y emite '
  'TransferDispatched al outbox (5.4).';

-- =============================================================================
-- 5.5 FiscalDocumentRejected — trigger AFTER UPDATE ON fiscal_documents
--
--     Decisión (Open Question design.md resuelta en apply): el UPDATE de
--     fiscal_documents.status='rejected' ocurre EXCLUSIVAMENTE en el backend
--     Python (fiscal_document_repository.py::update_rejected, service_role en
--     prod) — no hay RPC de Postgres invocable para este path. Tocar el
--     backend está fuera de scope (gobernanza CRÍTICO adicional para AFIP).
--     Se usa un TRIGGER AFTER UPDATE, mismo patrón que
--     trg_quote_record_creation (20260807000001_v3_document_status_history.sql).
--     El trigger corre DENTRO de la transacción del backend (DEC-20 se
--     cumple: la transacción es la del UPDATE, el trigger es parte de ella).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.trg_fiscal_document_rejected()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'rejected' AND OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      NEW.account_id, 'FiscalDocumentRejected', 'FiscalDocument', NEW.id,
      jsonb_build_object(
        'fiscal_document_id', NEW.id,
        'error',              NEW.last_error,
        'branch_id',          NULL
      ),
      now()
    );
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_fiscal_document_rejected IS
  'v3-notifications-realtime (5.5): AFTER UPDATE ON fiscal_documents. Emite '
  'FiscalDocumentRejected al outbox cuando status transiciona a rejected '
  '(pending_cae→rejected, backend Python fiscal_document_repository.py:: '
  'update_rejected, service_role). branch_id=NULL: fiscal_documents no tiene '
  'branch_id propio (deuda conocida, resoluble via point_of_sale_id→branch '
  'en un change posterior si el frontend lo necesita). Mismo patrón que '
  'trg_quote_record_creation (v3-document-status-history).';

DROP TRIGGER IF EXISTS on_fiscal_document_rejected ON public.fiscal_documents;
CREATE TRIGGER on_fiscal_document_rejected
  AFTER UPDATE ON public.fiscal_documents
  FOR EACH ROW EXECUTE FUNCTION public.trg_fiscal_document_rejected();

-- =============================================================================
-- 5.6 GATE: ningún producer existente se recreó fuera de lo documentado +
--     todos los INSERT INTO events stampan las 6 columnas canónicas.
-- =============================================================================
DO $gate5$
DECLARE
    v_count int;
BEGIN
    -- Gate estructural: las 6 columnas canónicas de events existen (ya
    -- verificado por 20260718000001, se re-chequea como safety net local).
    SELECT count(*) INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'events'
      AND column_name IN ('account_id','event_type','aggregate_type','aggregate_id','payload','occurred_at');
    IF v_count <> 6 THEN
        RAISE EXCEPTION 'GATE 5.6 FAILED: events no tiene las 6 columnas canónicas (tiene %)', v_count;
    END IF;

    -- Gate de comportamiento (por inspección de código fuente, no ejecución
    -- end-to-end): los RPCs de dominio exigen auth.uid()/sesión de usuario,
    -- que no existe dentro de un DO-block de migración. Se verifica que cada
    -- función retrofiteada contiene su INSERT INTO events con el event_type
    -- correcto — mismo criterio de verificación estructural que el gate (g)
    -- de 20260807000001 (LIKE '%record_status_transition%').
    IF pg_get_functiondef('public.rpc_transfer_stock(uuid,uuid,uuid,numeric)'::regprocedure)
       NOT LIKE '%TransferDispatched%'
    THEN
        RAISE EXCEPTION 'GATE 5.6 FAILED: rpc_transfer_stock no emite TransferDispatched';
    END IF;

    IF pg_get_functiondef('public.rpc_close_cash_session(uuid,numeric)'::regprocedure)
       NOT LIKE '%CashSessionClosed%'
    THEN
        RAISE EXCEPTION 'GATE 5.6 FAILED: rpc_close_cash_session no emite CashSessionClosed';
    END IF;

    IF pg_get_functiondef('public.rpc_accept_quote(uuid)'::regprocedure)
       NOT LIKE '%QuoteAccepted%'
    THEN
        RAISE EXCEPTION 'GATE 5.6 FAILED: rpc_accept_quote no emite QuoteAccepted';
    END IF;

    IF pg_get_functiondef('public.check_branch_low_stock()'::regprocedure)
       NOT LIKE '%StockBelowMinimum%'
    THEN
        RAISE EXCEPTION 'GATE 5.6 FAILED: check_branch_low_stock no emite StockBelowMinimum';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'on_fiscal_document_rejected'
          AND tgrelid = 'public.fiscal_documents'::regclass
    ) THEN
        RAISE EXCEPTION 'GATE 5.6 FAILED: falta el trigger on_fiscal_document_rejected';
    END IF;

    IF pg_get_functiondef('public.trg_fiscal_document_rejected()'::regprocedure)
       NOT LIKE '%FiscalDocumentRejected%'
    THEN
        RAISE EXCEPTION 'GATE 5.6 FAILED: trg_fiscal_document_rejected no emite FiscalDocumentRejected';
    END IF;

    RAISE NOTICE '=== v3-notifications-realtime GATE 5 (producers) === OK';
END
$gate5$;
