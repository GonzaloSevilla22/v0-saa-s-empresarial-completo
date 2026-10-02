-- =============================================================================
-- 20261068000001_presupuestos_conversion_venta.sql
-- presupuestos-modulo, TANDA B (governance MEDIA con tramo ALTO: escribe stock,
-- caja, banco y cuenta corriente a través del núcleo del POS, que NO se toca;
-- sign-off del PO 2026-10-01, OQ-P1..P16 por su recomendación). Ver
-- openspec/changes/presupuestos-modulo/design.md D6, D11, D12 y D14.
--
-- Qué hace:
--
--   1. _quote_accept_core(p_quote_id, p_branch_id): el cuerpo VIVO de
--      rpc_accept_quote (pg_get_functiondef de prod 2026-10-02, md5 sin CR
--      ad7ff20f…, idéntico al local) con SÓLO dos cambios (D6):
--        (1) SELECT … FOR UPDATE en la lectura del presupuesto (cierra la doble
--            aceptación concurrente);
--        (2) la sucursal pasa a ser COALESCE(p_branch_id, v_quote.branch_id,
--            c26_default_branch(...)), con p_branch_id validado contra la
--            cuenta, activo y no cerrado (P0404 branch_not_found / P0422
--            branch_closed).
--      SECURITY DEFINER, sin EXECUTE para los roles de aplicación (convención
--      `_*`, chequeo (4) de test_function_acl_gate.sql).
--   2. rpc_accept_quote(p_quote_id): wrapper de una línea
--      (RETURN _quote_accept_core(p_quote_id, NULL)), misma firma, mismo
--      resultado y mismo COMMENT vivo (re-declarado). Su EXECUTE ya se revocó
--      en la tanda A (revisión adversarial F2); acá se re-revoca (nunca se
--      re-otorga) para que la cadena de reaplicación de CI —que reaplica
--      20261045000001, la que le otorgaba EXECUTE— reconverja al estado
--      correcto.
--   3. rpc_convert_quote_to_sale(...): la conversión atómica (D6, pasos 1-7 y
--      3b): entrada -> lock del presupuesto -> idempotencia leída bajo el lock
--      -> estado / vencimiento / versión sobre la fila bloqueada -> guards de
--      convertibilidad (producto vivo de la cuenta y no padre, cliente no dado
--      de baja) -> núcleo de aceptación -> núcleo de venta del POS (SIN TOCAR)
--      -> un replay del núcleo de venta (misma clave, otro presupuesto, en
--      paralelo) se convierte en P0409 idempotency_key_conflict y revierte todo.
--      SECURITY DEFINER, sin anon, con EXECUTE para authenticated.
--   4. Bloque DO de introspección al final.
--
-- Orden de locks (regla global sales -> sales_orders -> fiscal_documents ->
-- resto): la conversión toma PRIMERO quotes (FOR UPDATE), después los productos
-- de sus líneas por id ASCENDENTE (paso 4a: el núcleo los toma por
-- sales_order_items.id, aleatorio por orden, y dos conversiones con los mismos
-- dos productos terminaban en 40P01) y recién ahí el núcleo de venta; no
-- bloquea filas existentes de sales ni de sales_orders (las crea), y quotes no
-- participa de ningún otro camino que tome los locks de venta, así que no
-- invierte el orden global.
--
-- Idempotente (auto-apply de Supabase GitHub y cadena de reaplicación de CI):
-- CREATE OR REPLACE con firmas fijas (rpc_accept_quote conserva la suya; las
-- otras dos son nuevas, sin overload previo, sin riesgo de 42725), REVOKE/GRANT
-- y COMMENT re-ejecutables.
--
-- Gates: supabase/tests/test_presupuesto_a_venta.sql (EJECUTA la conversión,
-- el núcleo y el wrapper) + supabase/tests/test_presupuesto_a_venta_race.sh
-- (dos conexiones reales).
-- =============================================================================


-- =============================================================================
-- 1. Núcleo de aceptación (cuerpo vivo de rpc_accept_quote + los 2 cambios de D6)
-- =============================================================================
CREATE OR REPLACE FUNCTION public._quote_accept_core(p_quote_id uuid, p_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_quote          public.quotes%ROWTYPE;
  v_item           RECORD;
  v_sales_order_id uuid;
  v_branch_id      uuid;
  v_branch         RECORD;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cargar el quote y validar tenencia
  SELECT * INTO v_quote
  FROM public.quotes
  WHERE id = p_quote_id
  FOR UPDATE;  -- presupuestos-modulo (D6, cambio 1 de 2): cierra la doble aceptación

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

  -- OQ-4: validación defensiva on-read de expiración.
  -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE (UTC del
  -- servidor) — evita marcar "vencido" un quote válido hasta hoy(ART) cuando
  -- se lo lee entre las 21:00 y las 23:59:59 ART.
  IF v_quote.valid_until IS NOT NULL AND v_quote.valid_until < public.reporting_local_today() THEN
    RAISE EXCEPTION 'quote_expired: valid_until % ya pasó', v_quote.valid_until
      USING ERRCODE = 'P0409';
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, RONDA 1 — finding MAJOR):
  -- v_quote.client_id se copia a sales_orders.client_id (tabla EN ALCANCE de
  -- este change) sin validar tenencia. `quotes` nace desde POST /quotes con
  -- un INSERT directo que tampoco valida (backend/repositories/
  -- quote_repository.py) — así que un quote con client_id ajeno es
  -- alcanzable sin ningún flag ni rol especial. Mismo predicado, mismo
  -- ERRCODE, mismo literal que (a)/(b)/(c): un id ajeno y uno inexistente
  -- deben ser indistinguibles. ANTES de la primera escritura (INSERT INTO
  -- sales_orders, más abajo).
  IF v_quote.client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = v_quote.client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', v_quote.client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- presupuestos-modulo (D6, cambio 2 de 2): la sucursal indicada por la
  -- conversión (validada contra la cuenta, activa y no cerrada) tiene
  -- precedencia sobre la del presupuesto y la default.
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found: la sucursal no pertenece a la cuenta o no está activa'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- Resolver branch: la indicada, si no la del quote, si no la default
  v_branch_id := COALESCE(
    p_branch_id,
    v_quote.branch_id,
    public.c26_default_branch(v_account_id)
  );

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Crear la SalesOrder en estado draft (sin tocar stock aún)
  -- limpiezas-pagos-admin (D7): ya no escribe el literal 'other' en la
  -- columna de texto (retirada) — un draft nace sin forma de pago imputada
  -- (payment_method_id NULL); se decide recién en el confirm.
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, source_quote_id, status,
     total, created_by)
  VALUES
    (v_account_id, v_branch_id, v_quote.client_id, p_quote_id, 'draft',
     v_quote.total, v_uid)
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
$function$;

REVOKE ALL ON FUNCTION public._quote_accept_core(uuid, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._quote_accept_core(uuid, uuid) IS
  'presupuestos-modulo (D6): núcleo de aceptación de un presupuesto, compartido por rpc_accept_quote y '
  'rpc_convert_quote_to_sale. Cuerpo vivo de rpc_accept_quote (C-29 + snapshots + historial + QuoteAccepted + '
  'guard de cliente de operacion-party-guard) con dos cambios: FOR UPDATE sobre el presupuesto y la sucursal '
  'COALESCE(p_branch_id validada, la del presupuesto, la default). Crea la SalesOrder en draft con source_quote_id '
  'y las líneas con sus snapshots, registra el historial de los dos documentos y emite QuoteAccepted. No toca '
  'stock ni caja. Interna: sin EXECUTE para los roles de aplicación.';


-- =============================================================================
-- 2. rpc_accept_quote como wrapper del núcleo (misma firma, mismo COMMENT)
-- =============================================================================
-- Sin endpoint desde la tanda A (POST /quotes/{id}/accept se retiró) y sin
-- EXECUTE para los roles de aplicación: se conserva por compatibilidad y como
-- regresión del núcleo (bloque (s) de test_presupuesto_a_venta.sql y (2b) de
-- test_operacion_party_guard.sql, que la ejecutan como postgres con claims).
CREATE OR REPLACE FUNCTION public.rpc_accept_quote(p_quote_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public._quote_accept_core(p_quote_id, NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_accept_quote(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.rpc_accept_quote IS
  'C-29 (D3) + v3-snapshot-pattern + v3-document-status-history + v3-notifications-realtime: acepta un Quote (draft|sent + no expirado) y crea un SalesOrder en draft con los mismos ítems, propagando los snapshots congelados. Registra en document_status_history la creación de la SalesOrder (RN-A2) y la transición del quote a accepted (RN-A1). Emite QuoteAccepted al outbox (5.3; seller_id=created_by como proxy). No toca stock ni caja — eso es SalesOrder.confirm(). Atómico.';


-- =============================================================================
-- 3. rpc_convert_quote_to_sale — conversión atómica (D6)
-- =============================================================================
-- Pasos (todo en una transacción; cualquier fallo revierte todo y el
-- presupuesto queda en su estado anterior, sin orden draft):
--   1  auth.uid(), clave no vacía (P0400), forma de pago obligatoria (P0400
--      payment_method_required: la conversión no usa el camino legacy por
--      texto) y versión esperada obligatoria (P0400 quote_revision_required);
--   2  lock del presupuesto filtrado por las cuentas del usuario (P0404
--      quote_not_found: inexistente y ajeno indistinguibles) + writer (P0401) +
--      rol CAN_QUOTE (P0403, D11);
--   3  idempotencia leída DESPUÉS del lock: si la clave ya existe y su
--      operación es la venta de ESTE presupuesto -> replay {…, replayed:true}
--      sin escribir; si es de otra operación -> P0409 idempotency_key_conflict;
--   3b estado draft|sent (P0409 quote_invalid_state), vencimiento (P0409
--      quote_expired) y versión (P0409 quote_changed) sobre la fila bloqueada,
--      antes de los guards de convertibilidad;
--   4  productos vivos de la cuenta (P0404 quote_product_unavailable: <nombre>)
--      y no padres (P0400 product_is_parent); cliente no dado de baja (P0404
--      quote_client_unavailable); un cliente de otra cuenta lo rechaza el
--      núcleo de aceptación con client_not_found;
--   5  núcleo de aceptación (orden draft + accepted + QuoteAccepted);
--   6  núcleo de venta del POS (stock, caja, cuenta corriente, banco,
--      SaleConfirmed, draft -> confirmed), tipo de comprobante NULL; con kind
--      cash exige la sesión (cash_requires_session). Si devuelve replayed=true
--      es la misma clave usada en paralelo sobre OTRO presupuesto: P0409
--      idempotency_key_conflict, que revierte la aceptación y la orden;
--   7  {quote_id, quote_number, sales_order_id, operation_id, total, replayed}.
-- Los comentarios del cuerpo no nombran a los núcleos ni a la tabla de
-- idempotencia fuera de orden: el gate (u) verifica el orden de sus apariciones.
CREATE OR REPLACE FUNCTION public.rpc_convert_quote_to_sale(
  p_idempotency_key   text,
  p_quote_id          uuid,
  p_expected_revision integer,
  p_payment_method_id uuid,
  p_branch_id         uuid DEFAULT NULL,
  p_cash_session_id   uuid DEFAULT NULL,
  p_bank_account_id   uuid DEFAULT NULL,
  p_canal             text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_quote        public.quotes%ROWTYPE;
  v_existing_op  uuid;
  v_order        RECORD;
  v_item         RECORD;
  v_product      RECORD;
  v_accept       jsonb;
  v_sales_order  uuid;
  v_sale         jsonb;
BEGIN
  -- 1. Entrada
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;
  IF p_payment_method_id IS NULL THEN
    RAISE EXCEPTION 'payment_method_required: la conversión exige una forma de pago del catálogo'
      USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'quote_revision_required: falta la versión del presupuesto que se confirmó'
      USING ERRCODE = 'P0400';
  END IF;

  -- 2. Lock del documento de origen primero
  SELECT * INTO v_quote
  FROM public.quotes
  WHERE id = p_quote_id
    AND account_id IN (SELECT public.current_account_ids())
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found' USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._quote_assert_can_write(v_quote.account_id);

  -- 3. Idempotencia, leída bajo el lock: el doble clic sobre el mismo
  -- presupuesto espera el lock de arriba y hace replay.
  SELECT operation_id INTO v_existing_op
  FROM public.operation_idempotency
  WHERE user_id = v_uid
    AND operation_kind = 'sale'
    AND idempotency_key = p_idempotency_key;

  IF FOUND THEN
    SELECT so.id, so.total INTO v_order
    FROM public.sales_orders so
    WHERE so.sale_operation_id = v_existing_op
      AND so.source_quote_id = p_quote_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
        USING ERRCODE = 'P0409';
    END IF;
    RETURN jsonb_build_object(
      'quote_id',       p_quote_id,
      'quote_number',   v_quote.number,
      'sales_order_id', v_order.id,
      'operation_id',   v_existing_op,
      'total',          v_order.total,
      'replayed',       true
    );
  END IF;

  -- 3b. Estado, vencimiento (día ART) y versión, sobre la fila bloqueada y
  -- antes de los guards de convertibilidad.
  IF v_quote.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'quote_invalid_state: estado % no es convertible', v_quote.status
      USING ERRCODE = 'P0409';
  END IF;
  IF v_quote.valid_until IS NOT NULL AND v_quote.valid_until < public.reporting_local_today() THEN
    RAISE EXCEPTION 'quote_expired: valid_until % ya pasó', v_quote.valid_until
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision <> v_quote.revision THEN
    RAISE EXCEPTION 'quote_changed: el presupuesto cambió mientras se confirmaba la venta (versión %, vigente %)',
      p_expected_revision, v_quote.revision
      USING ERRCODE = 'P0409';
  END IF;

  -- 4a. Lock de los productos de las líneas por id ASCENDENTE, antes del
  -- núcleo. El núcleo de venta (que no se toca) los bloquea en el orden de
  -- sales_order_items.id, un uuid aleatorio por orden: dos órdenes con los
  -- mismos dos productos los toman en orden inverso y una de las dos termina en
  -- deadlock (40P01). Tomándolos acá todas las conversiones los toman en el
  -- mismo orden y el FOR UPDATE del núcleo pasa a ser un no-op sobre filas ya
  -- propias. Sólo productos de la cuenta: uno ajeno cae en el guard de abajo
  -- (P0404). El guard lee ya con el lock puesto: un producto no se da de baja
  -- entre el chequeo y la venta.
  PERFORM 1
  FROM public.products p
  WHERE p.account_id = v_quote.account_id
    AND p.id IN (
      SELECT qi.product_id FROM public.quote_items qi
      WHERE qi.quote_id = p_quote_id AND qi.product_id IS NOT NULL
    )
  ORDER BY p.id
  FOR UPDATE;

  -- 4. Guards de convertibilidad, antes de escribir nada. El núcleo de venta
  -- no filtra deleted_at: sin este guard un producto dado de baja se vendería.
  FOR v_item IN
    SELECT qi.product_id, qi.name_snapshot
    FROM public.quote_items qi
    WHERE qi.quote_id = p_quote_id
      AND qi.product_id IS NOT NULL
    ORDER BY qi.line_no NULLS LAST, qi.id
  LOOP
    SELECT p.id, p.name, p.stock_control_type INTO v_product
    FROM public.products p
    WHERE p.id = v_item.product_id
      AND p.account_id = v_quote.account_id
      AND p.deleted_at IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'quote_product_unavailable: %', COALESCE(v_item.name_snapshot, v_item.product_id::text)
        USING ERRCODE = 'P0404';
    END IF;
    IF v_product.stock_control_type = 'variant_only' OR EXISTS (
      SELECT 1 FROM public.products c WHERE c.parent_id = v_item.product_id AND c.deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'product_is_parent: "%" se vende a través de sus variantes', v_product.name
        USING ERRCODE = 'P0400';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.clients c
    WHERE c.id = v_quote.client_id
      AND c.account_id = v_quote.account_id
      AND c.deleted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'quote_client_unavailable: el cliente fue dado de baja: editá el presupuesto y elegí un cliente vigente'
      USING ERRCODE = 'P0404';
  END IF;

  -- 5. Aceptación (orden draft con source_quote_id, accepted, QuoteAccepted).
  v_accept := public._quote_accept_core(p_quote_id, p_branch_id);
  v_sales_order := (v_accept->>'sales_order_id')::uuid;

  -- 6. Confirmación con el núcleo de la venta rápida del POS, sin tipo de
  -- comprobante (facturar es una acción posterior explícita).
  v_sale := public._c29_confirm_order_core(
    p_idempotency_key,
    v_sales_order,
    NULL,
    p_cash_session_id,
    NULL,
    NULL,
    p_canal,
    p_payment_method_id,
    p_bank_account_id
  );

  -- La misma clave usada en paralelo sobre OTRO presupuesto: el núcleo esperó
  -- el ON CONFLICT y devolvió la operación ajena sin confirmar esta orden.
  IF COALESCE((v_sale->>'replayed')::boolean, false) THEN
    RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
      USING ERRCODE = 'P0409';
  END IF;

  -- 7. Resultado
  RETURN jsonb_build_object(
    'quote_id',       p_quote_id,
    'quote_number',   v_quote.number,
    'sales_order_id', v_sales_order,
    'operation_id',   (v_sale->>'operation_id')::uuid,
    'total',          (v_sale->>'total')::numeric,
    'replayed',       false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_convert_quote_to_sale(text, uuid, integer, uuid, uuid, uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_convert_quote_to_sale(text, uuid, integer, uuid, uuid, uuid, uuid, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_convert_quote_to_sale(text, uuid, integer, uuid, uuid, uuid, uuid, text) IS
  'presupuestos-modulo (D6): convierte un presupuesto draft|sent vigente en una venta confirmada en UNA transacción. '
  'Lock del presupuesto (P0404 quote_not_found) + writer/CAN_QUOTE (P0401/P0403); idempotencia leída bajo el lock '
  '(replay de la misma venta o P0409 idempotency_key_conflict); estado, vencimiento y versión sobre la fila bloqueada '
  '(P0409 quote_invalid_state / quote_expired / quote_changed); productos vivos y no padres (P0404 '
  'quote_product_unavailable / P0400 product_is_parent) y cliente no dado de baja (P0404 quote_client_unavailable); '
  'luego _quote_accept_core y _c29_confirm_order_core (stock por sucursal, caja, cuenta corriente con vencimiento por '
  'cascada, banco, SaleConfirmed) con el precio del presupuesto. Forma de pago del catálogo obligatoria (P0400 '
  'payment_method_required). Cualquier fallo revierte todo. Expuesta como POST /quotes/{id}/convert.';


-- =============================================================================
-- 4. Introspección (corre siempre, también en prod)
-- =============================================================================
DO $$
DECLARE
  v_bad text[] := '{}';
  v_fn  text;
  v_n   integer;
  v_def text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['_quote_accept_core', 'rpc_accept_quote', 'rpc_convert_quote_to_sale'] LOOP
    SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_n <> 1 THEN v_bad := v_bad || format('%s tiene %s definiciones', v_fn, v_n); END IF;
  END LOOP;

  v_def := pg_get_functiondef('public.rpc_accept_quote(uuid)'::regprocedure);
  IF position('_quote_accept_core(p_quote_id, NULL)' in v_def) = 0 OR v_def ~* 'INSERT\s+INTO' THEN
    v_bad := v_bad || 'rpc_accept_quote no es el wrapper del núcleo'::text;
  END IF;
  IF COALESCE(obj_description('public.rpc_accept_quote(uuid)'::regprocedure, 'pg_proc'), '') NOT LIKE 'C-29 (D3) + v3-snapshot-pattern%' THEN
    v_bad := v_bad || 'rpc_accept_quote perdió su COMMENT vivo'::text;
  END IF;

  FOREACH v_fn IN ARRAY ARRAY['public._quote_accept_core(uuid, uuid)', 'public.rpc_accept_quote(uuid)'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE') OR has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por un rol de aplicación', v_fn);
    END IF;
  END LOOP;
  v_fn := 'public.rpc_convert_quote_to_sale(text, uuid, integer, uuid, uuid, uuid, uuid, text)';
  IF has_function_privilege('anon', v_fn, 'EXECUTE') OR NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
    v_bad := v_bad || format('ACL de %s', v_fn);
  END IF;
  IF NOT (SELECT bool_and(prosecdef) FROM pg_proc WHERE oid IN (
            'public._quote_accept_core(uuid, uuid)'::regprocedure,
            'public.rpc_accept_quote(uuid)'::regprocedure,
            v_fn::regprocedure)) THEN
    v_bad := v_bad || 'alguna función de la tanda B no es SECURITY DEFINER'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'presupuestos-modulo tanda B (introspección) FAILED:\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'presupuestos-modulo tanda B (introspección): OK — una definición de _quote_accept_core, rpc_accept_quote (wrapper, COMMENT vivo) y rpc_convert_quote_to_sale; núcleo y wrapper sin EXECUTE para la API; conversión sin anon y con authenticated.';
END $$;
