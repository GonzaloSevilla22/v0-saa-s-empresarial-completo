-- =============================================================================
-- 20261070000001_remitos_venta_conversion.sql — remitos-venta, TANDA B
-- (governance MEDIA con tramo ALTO: reescribe tres funciones del camino del
-- dinero y del stock desde sus cuerpos VIVOS y suma la conversión).
--
-- Qué hace (design.md §D1, §D3, §D7, §D9, §D16):
--   1. sales_orders.source_delivery_note_id (FK NO ACTION) + índice único
--      parcial (a lo sumo una orden viva por remito; una orden cancelada no
--      impide reconvertir) + las filas issued -> converted y
--      converted -> issued del catálogo delivery_note_sale.
--   2. _c29_confirm_order_core, desde su pg_get_functiondef vivo: SÓLO la rama
--      v_from_delivery_note. Con origen de remito revalida el remito y el
--      multiconjunto de líneas (P0409 delivery_note_order_mismatch) y, en el
--      loop, saltea el FOR UPDATE del producto, la normalización, el gate, el
--      delta y el movimiento; sale_items toma los cuatro snapshots de la línea
--      de la orden. La decisión la toma la columna persistida de la orden,
--      nunca un parámetro: la firma no cambia. Caja, cuenta corriente, banco,
--      fiscal, outbox, historial y UPDATE de la orden: sin cambios.
--   3. rpc_convert_delivery_note_to_sale (nueva), molde de
--      rpc_convert_quote_to_sale: lock del remito -> idempotencia bajo el lock
--      -> estado / versión / cliente vivo / sucursal activa y no cerrada ->
--      orden + líneas copiadas del remito (precios y snapshots del remito, sin
--      re-leer el maestro) -> núcleo (que deja el remito converted). FOR KEY SHARE
--      de los productos del remito en orden ascendente de id ANTES de insertar
--      líneas (sin FOR UPDATE: la conversión no mueve stock), para que las FK de
--      las líneas no tomen esos locks en el orden del remito y se crucen con
--      una emisión que los toma por id (revisión adversarial 8.5, RB-01).
--   4. rpc_delete_sale_operation, desde su cuerpo vivo: con origen de remito,
--      la sucursal del remito (FOR SHARE) tiene que estar activa y no cerrada
--      ANTES del guard fiscal y de cualquier compensación (P0422
--      delivery_note_branch_inactive, cero efectos); salto explícito de la
--      reversa de stock; y el remito vuelve a issued (lock al final:
--      sales -> sales_orders -> fiscal_documents -> delivery_notes).
--   5. rpc_atomic_update_sale_operation, desde su cuerpo vivo: P0423
--      delivery_note_sale_locked después del lock de sales y del guard de
--      cliente, ANTES de la anulación fiscal.
--   6. _delivery_note_payload (tanda A): converted_sales_order_id /
--      converted_operation_id pasan de NULL fijo a derivarse de la orden viva
--      del remito (desvío aditivo declarado: la tanda A los dejó anunciados
--      para esta tanda).
--   7. _branch_assert_empty (tanda A): el RAISE de P0428 branch_has_pending_delivery_notes
--      ofrece "convertilos en venta o anulalos" (6.0b); sólo cambia el texto.
--
-- Orden de locks: la conversión toma delivery_notes PRIMERO y después sólo
-- CREA filas de venta (no bloquea filas existentes de sales), así que no
-- invierte el orden global sales -> sales_orders -> fiscal_documents. El
-- borrado de la venta toma el remito AL FINAL. Sin ciclo: la conversión nunca
-- espera un lock de sales, y ante un remito converted falla de inmediato.
--
-- Cuerpos de partida (checkpoint 6.1, re-verificado 2026-10-03 contra prod,
-- md5 de pg_get_functiondef sin \r): _c29_confirm_order_core
-- bbe8ac0f9cedc5873dbeb6c81a661aed, rpc_delete_sale_operation
-- b7ca24c74058c427cdfd6dca2e9102c3, rpc_atomic_update_sale_operation
-- 954a5c8fb31202259c82485d0c6e05b9 (= base local tras db reset). El diff de
-- cada reescritura contra su cuerpo vivo está en
-- openspec/changes/remitos-venta/evidence/tanda-b/. CREATE OR REPLACE con la
-- misma firma conserva la ACL; el COMMENT vivo se re-declara idéntico.
--
-- Idempotente (CI la reaplica al final de la cadena, después de
-- 20261069000001): ADD COLUMN IF NOT EXISTS, FK guardada contra pg_constraint,
-- CREATE UNIQUE INDEX IF NOT EXISTS, catálogo con ON CONFLICT DO NOTHING,
-- CREATE OR REPLACE con firmas fijas, REVOKE/GRANT y COMMENT re-emitidos.
-- =============================================================================


-- =============================================================================
-- 1. Puente remito -> venta (D1) y catálogo de la tanda B (D3)
-- =============================================================================
ALTER TABLE public.sales_orders ADD COLUMN IF NOT EXISTS source_delivery_note_id uuid;

-- NO ACTION (no RESTRICT): se verifica al final de la sentencia, así que no
-- traba un borrado de cuenta que cascadea a la vez sobre delivery_notes y
-- sales_orders. En la práctica equivale a RESTRICT: el remito nunca se borra.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sales_orders_source_delivery_note_id_fkey'
      AND conrelid = 'public.sales_orders'::regclass
  ) THEN
    ALTER TABLE public.sales_orders
      ADD CONSTRAINT sales_orders_source_delivery_note_id_fkey
      FOREIGN KEY (source_delivery_note_id) REFERENCES public.delivery_notes (id) ON DELETE NO ACTION;
  END IF;
END $$;

-- A lo sumo una orden VIVA por remito (1 remito -> 1 venta, R8). Una orden
-- cancelada (venta borrada) no impide reconvertir (R5).
CREATE UNIQUE INDEX IF NOT EXISTS sales_orders_source_delivery_note_id_uq
  ON public.sales_orders (source_delivery_note_id)
  WHERE source_delivery_note_id IS NOT NULL AND status <> 'canceled';

COMMENT ON COLUMN public.sales_orders.source_delivery_note_id IS
  'remitos-venta (D1/D7): remito de venta del que nació la orden. Lo escribe sólo rpc_convert_delivery_note_to_sale. '
  'Con valor, _c29_confirm_order_core NO mueve stock (el remito ya lo descontó) y revalida el remito y sus líneas; '
  'rpc_delete_sale_operation no repone stock y devuelve el remito a issued; rpc_atomic_update_sale_operation '
  'rechaza la edición (P0423 delivery_note_sale_locked).';

-- Filas de la tanda B (regla del seed: cada una con su productor en esta migración).
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_sale', 'issued', 'converted', false, false, ARRAY['seller', 'cashier', 'admin', 'owner'])
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;

-- Sin rol (tercera exención de record_status_transition): la dispara sólo el
-- borrado de la venta, que ya exige admin/owner por sales_order
-- confirmed -> canceled, registrada antes en la misma transacción.
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_sale', 'converted', 'issued', false, false, NULL)
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;


-- =============================================================================
-- 2. _c29_confirm_order_core desde el cuerpo vivo: SÓLO la rama v_from_delivery_note (D7)
-- =============================================================================
CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid DEFAULT NULL::uuid, p_comprobante_type text DEFAULT NULL::text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- pos-catalogo-pagos (D2/D3): resolución de kind y cuenta corriente.
  v_kind                 text;
  v_pm_is_active         boolean;
  -- tenancy-guard-caja-outbox (h1, capa 1): mismos nombres que en
  -- rpc_create_sale_operation_v2, de donde se copia el predicado.
  v_cash_session_status  text;
  v_cash_session_branch  uuid;
  -- remitos-venta (D7): la orden nació de un remito — lo decide la columna
  -- persistida de la orden (sales_orders.source_delivery_note_id), NUNCA un
  -- parámetro: la firma no cambia.
  v_from_delivery_note   boolean := false;
  v_dn                   RECORD;
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

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): mismo guard que
  -- rpc_create_sale_operation_v2 (20261045000001) — cubre POS
  -- (rpc_quick_sale), rpc_confirm_sales_order y rpc_accept_quote una vez
  -- confirmado: v_order.client_id se valida contra el tenant ANTES de
  -- cualquier escritura (idempotencia incluida, más abajo). Si viene de
  -- rpc_quick_sale, el INSERT en sales_orders corre en la MISMA
  -- transacción que esta RPC — el rechazo de acá revierte también esa fila.
  IF v_order.client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = v_order.client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', v_order.client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ╔═══ remitos-venta (D7): orden nacida de un remito ═════════════════════╗
  -- El remito YA descontó el stock al emitirse: esta orden no lo vuelve a
  -- mover (rama del loop de más abajo). Antes de la primera escritura se
  -- revalida TODO, de forma autosuficiente (un guard que delega no es guard):
  -- una orden fabricada con un source_delivery_note_id válido pero con otro
  -- cliente, otra sucursal u otras líneas, o apuntando a un remito ajeno,
  -- anulado o ya convertido, rebota acá en lugar de regalar mercadería.
  -- El FOR UPDATE es un no-op si la conversión ya tiene el remito.
  IF v_order.source_delivery_note_id IS NOT NULL THEN
    SELECT * INTO v_dn
    FROM public.delivery_notes
    WHERE id = v_order.source_delivery_note_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_dn.account_id <> v_account_id
       OR v_dn.direction <> 'sale'
       OR v_dn.status <> 'issued'
       OR v_dn.client_id IS DISTINCT FROM v_order.client_id
       OR v_dn.branch_id <> v_order.branch_id THEN
      RAISE EXCEPTION 'delivery_note_order_mismatch: la orden % no corresponde a un remito de venta pendiente de la misma cuenta, cliente y sucursal', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;

    -- Multiconjunto de líneas (producto, unidad, cantidad) idéntico al del
    -- remito: dos EXCEPT ALL vacíos.
    IF EXISTS (
         SELECT soi.product_id, soi.unit_id, soi.quantity
         FROM public.sales_order_items soi
         WHERE soi.sales_order_id = p_sales_order_id
         EXCEPT ALL
         SELECT dni.product_id, dni.unit_id, dni.quantity
         FROM public.delivery_note_items dni
         WHERE dni.delivery_note_id = v_dn.id
       )
       OR EXISTS (
         SELECT dni.product_id, dni.unit_id, dni.quantity
         FROM public.delivery_note_items dni
         WHERE dni.delivery_note_id = v_dn.id
         EXCEPT ALL
         SELECT soi.product_id, soi.unit_id, soi.quantity
         FROM public.sales_order_items soi
         WHERE soi.sales_order_id = p_sales_order_id
       ) THEN
      RAISE EXCEPTION 'delivery_note_order_mismatch: las líneas de la orden % no son las del remito', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;

    v_from_delivery_note := true;
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- ─── pos-catalogo-pagos (D2): resolver el kind — el cliente no elige la
  -- taxonomía, la RPC la deriva del catálogo y no le cree al texto que
  -- venga junto. Va con los demás guards de entrada, antes de tocar stock.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind, is_active INTO v_kind, v_pm_is_active
    FROM public.payment_methods
    WHERE id = p_payment_method_id
      AND account_id = v_account_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found: % no pertenece a la cuenta o no existe', p_payment_method_id
        USING ERRCODE = 'P0404';
    END IF;

    IF NOT v_pm_is_active THEN
      RAISE EXCEPTION 'payment_method_inactive: % está desactivada', p_payment_method_id
        USING ERRCODE = 'P0400';
    END IF;

    IF p_payment_method IS NOT NULL AND p_payment_method <> v_kind THEN
      RAISE EXCEPTION 'payment_method_mismatch: el texto % no coincide con el kind % de la forma de pago', p_payment_method, v_kind
        USING ERRCODE = 'P0400';
    END IF;
  ELSE
    -- Camino legacy (D2, limpiezas-pagos-admin): sin payment_method_id, el
    -- kind es el texto recibido (o 'other' si viene NULL). A diferencia del
    -- comportamiento anterior (que dejaba el kind viviendo solo en la
    -- columna de texto sales_orders.payment_method, ahora retirada), se
    -- intenta resolver la forma de pago viva y activa de la cuenta con ese
    -- kind (desempate por sort_order, luego id) para imputar
    -- p_payment_method_id. Si no hay ninguna forma de pago sembrada de ese
    -- kind (p.ej. 'check', ver OQ-1), la orden queda sin imputar — no
    -- aborta, es el mismo criterio "sin especificar" que ya contempla la
    -- capability payment-method.
    v_kind := COALESCE(p_payment_method, 'other');

    SELECT id INTO p_payment_method_id
    FROM public.payment_methods
    WHERE account_id = v_account_id
      AND kind = v_kind
      AND is_active = true
      AND deleted_at IS NULL
    ORDER BY sort_order, id
    LIMIT 1;
  END IF;

  -- D6: validación cash sin session → P0400 (ramifica sobre v_kind, no sobre
  -- el texto crudo — D4).
  IF v_kind = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ╔═══ tenancy-guard-caja-outbox (h1, CAPA 1 — invariante de SUCURSAL) ════╗
  -- El p_cash_session_id llega del payload y hasta acá NADIE lo validaba: sólo
  -- se chequeaba IS NULL (arriba) y se lo pasaba crudo a
  -- c28_register_cash_movement, que no mira account_id. Una sesión de caja de
  -- OTRO TENANT se confirmaba y le dejaba un ingreso fantasma en el arqueo.
  -- El predicado se COPIA de rpc_create_sale_operation_v2 (el formulario, que
  -- ya lo cumplía): sesión abierta Y de la sucursal efectiva de la venta.
  -- Mismo ERRCODE y MISMO mensaje literal: que dos caminos den errores
  -- distintos para la misma condición es deuda, no feature.
  -- PARIDAD PARCIAL, A PROPÓSITO. Sobre el MISMO parámetro el formulario
  -- aplica tres guards, y acá se replica UNO — el de tenencia. Los otros dos
  -- NO se replican: `cash_optin_requires_cash_kind` (rechaza el id de sesión
  -- si el kind no es cash) y `cash_optin_requires_today`. Son higiene de
  -- input, no tenencia: con kind no-cash el id se descarta sin tocar caja
  -- (el consumo vive dentro de `IF v_kind = 'cash'`), y la fecha de la venta
  -- del POS la fija reporting_local_today() en el propio INSERT, así que la
  -- condición se cumple por construcción. Replicarlos agrandaría el BREAKING
  -- de un change CRÍTICO sobre payloads que ninguna superficie del producto
  -- genera, a cambio de cero seguridad. Queda anotado como candidato en
  -- design.md D2. Lo que sí está cubierto y es lo que importa: el guard de
  -- tenencia es AGNÓSTICO DEL KIND — una sesión ajena rebota igual con
  -- `transfer` (assert 2.6 del gate).
  -- Ubicación (D2): junto a las demás validaciones de payload, inmediatamente
  -- después de cash_requires_session y ANTES de la primera escritura (el
  -- INSERT en operation_idempotency, más abajo). Se compara contra
  -- v_order.branch_id porque `v_gate_branch := v_order.branch_id` se asigna
  -- unas líneas más abajo: es el mismo valor, y mover esa asignación habría
  -- introducido una diferencia contra el baseline vivo que no es el guard.
  -- EL GUARD ES AUTOSUFICIENTE — única diferencia deliberada contra el
  -- predicado copiado del formulario, y está acá por una revisión adversarial
  -- (2026-08-24). En el formulario `v_gate_branch` ya viene validada como
  -- perteneciente al tenant antes del bloque; en el core NO: la sucursal de la
  -- orden la elige el atacante en el camino de rpc_quick_sale
  -- (`COALESCE(p_branch_id, c26_default_branch(...))` va al INSERT en
  -- sales_orders sin chequeo de cuenta) y la validación de tenencia de la
  -- sucursal —el `AND account_id = v_account_id` del `branch_not_found`—
  -- ocurre unas líneas MÁS ABAJO. Con sólo `cb.branch_id = v_order.branch_id`,
  -- mandar la sucursal de la víctima junto con su sesión de caja SATISFACE el
  -- guard, y lo único que frena la escritura pasa a ser un chequeo ajeno a
  -- este change que ningún test congela (medido: ese payload rebotaba con
  -- P0404, no con P0422). Por eso el SELECT JOINea `branches` y exige
  -- `b.account_id = v_account_id`: el guard establece por sí solo los DOS
  -- invariantes —caja de la sucursal de la venta Y del tenant que llama— sin
  -- depender de nada de más abajo. Si la sesión no cumple, el SELECT no
  -- devuelve fila, las dos variables quedan NULL y el IS DISTINCT FROM de
  -- abajo dispara el P0422. Candados: asserts (2.7) y (2.8) del gate.
  IF p_cash_session_id IS NOT NULL THEN
    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches   b  ON b.id  = cb.branch_id
    WHERE cs.id = p_cash_session_id
      AND b.account_id = v_account_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_order.branch_id THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- pos-catalogo-pagos (D3): restaurar el guard credit_requires_client del
  -- bloque C-30 (20260720000001), ANTES de tocar stock — junto con los
  -- demás guards de entrada.
  IF v_kind = 'credit' AND v_order.client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id en la orden'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method (D4: vocabulario completo del catálogo, los 7 kind)
  IF v_kind NOT IN ('cash', 'transfer', 'card', 'check', 'wallet', 'credit', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', v_kind
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
    -- (v3-document-status-history: el return temprano garantiza que el replay
    -- NO inserta historial duplicado). La forma de pago del replay se ignora
    -- (pos-catalogo-pagos: mismo criterio, ahora también para payment_method_id).
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
      -- remitos-venta (D7): con origen de remito se saltean el FOR UPDATE del
      -- producto, la normalización, el gate, el delta y el movimiento — no hay
      -- stock que proteger (el remito ya lo descontó) y un FOR UPDATE sólo
      -- sumaría superficie de interbloqueo contra otros remitos (los locks de
      -- FK de las líneas ya los tomó rpc_convert_delivery_note_to_sale, por id,
      -- antes de insertarlas: acá se vuelven a tomar sin esperar). La existencia del
      -- producto la garantiza la FK de delivery_note_items. Se conservan la
      -- fila legacy sales y sale_items, que toma los CUATRO snapshots de la
      -- línea de la orden (copiados del remito, sin re-leer el maestro:
      -- nombre y SKU del remito aunque el producto se haya renombrado, costo
      -- congelado al salir la mercadería — OQ-RV3/OQ-RV4).
      IF v_from_delivery_note THEN
        INSERT INTO public.sales
          (user_id, account_id, client_id, product_id, amount, quantity,
           unit_id, total, currency, date, operation_id, branch_id, canal,
           payment_method_id)
        VALUES
          (v_uid, v_account_id, v_order.client_id, v_item.product_id,
           v_item.price, v_item.quantity,
           v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
           v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
        RETURNING id INTO v_new_sale_id;

        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
          v_item.name_snapshot, v_item.sku_snapshot, v_item.unit_cost_snapshot, v_item.iva_rate_snapshot
        );

        CONTINUE;
      END IF;

      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
      SELECT id, user_id, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      -- ventas-unidades-conversion (D1/D2): el POS descontaba la cantidad
      -- CRUDA de la línea; ahora normaliza por la misma definición única que
      -- el formulario (unidad base del producto). sales_order_items.unit_id
      -- viaja con la línea desde rpc_quick_sale / rpc_confirm_sales_order.
      v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

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

      -- Insertar fila legacy sales (retrocompat D4). app-timezone-argentina
      -- (task 5): día argentino, no CURRENT_DATE (UTC del servidor).
      -- pos-catalogo-pagos: cada fila legacy nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
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
      -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
      -- pos-catalogo-pagos: también nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  -- pos-catalogo-pagos (D4): ramifica sobre v_kind, no sobre el texto crudo.
  IF v_kind = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── pagos-cableados-restantes (D2): cuenta corriente del cliente — el
  -- bloque inline restaurado por pos-catalogo-pagos (D3) se REEMPLAZA por
  -- la llamada al helper compartido _pay_register_party_charge (D1), la
  -- misma definición que usa el formulario de venta (rpc_create_sale_
  -- operation_v2). client_id ya validado arriba (credit_requires_client
  -- antes del descuento de stock). El helper posta el cargo C-30 y emite
  -- CustomerAccountCharged en la misma operación atómica — nada de esto
  -- se relaja, sólo deja de estar duplicado.
  IF v_kind = 'credit' THEN
    PERFORM public._pay_register_party_charge(
      v_account_id, 'customer', v_order.client_id, v_total, p_sales_order_id, v_new_op_id
    );
  END IF;

  -- ─── pos-banco-movimientos (D5): movimiento bancario operativo — después
  -- de caja/cuenta corriente, ANTES del bloque fiscal (task 4.1). NULL si no
  -- corresponde escribir (kind no bancario, o bancario sin cuenta resuelta —
  -- D2). value_date = día ART (D4, el POS nunca dispara P0424: opera siempre
  -- sobre hoy).
  PERFORM public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    v_total, 'in', 'sale', p_sales_order_id,
    public.reporting_local_today(), v_gate_branch, NULL
  );

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  -- GATE OQ-G: bloque fiscal copiado SIN TOCAR NI UNA LÍNEA desde la
  -- definición viva capturada 2026-08-19. No modificar sin sign-off del PO.
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
  -- pos-catalogo-pagos: el payload lleva el kind EFECTIVO (v_kind), no el
  -- texto crudo del cliente — coherente con lo que persiste sales_orders.
  -- limpiezas-pagos-admin (D1 de design.md): esta clave NO cambia — el
  -- consumidor (_journal_post_from_event) lee el PAYLOAD, nunca la columna.
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
      'payment_method',  v_kind,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- v3-document-status-history (RN-A1): transición draft→confirmed en la
  -- misma transacción atómica (junto con stock, caja, fiscal y outbox)
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', p_sales_order_id, 'draft', 'confirmed', v_uid, NULL);

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  -- limpiezas-pagos-admin (G1b): la columna de texto payment_method fue
  -- retirada — la orden persiste únicamente payment_method_id (resuelto
  -- arriba, explícito o vía la resolución legacy D2). El kind efectivo
  -- (v_kind) sigue viajando en el payload del evento SaleConfirmed.
  UPDATE public.sales_orders
  SET
    status              = 'confirmed',
    payment_method_id   = p_payment_method_id,
    total               = v_total,
    sale_operation_id   = v_new_op_id,
    fiscal_document_id  = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  -- remitos-venta (D7, revisión adversarial 8.5 RB-02): el remito de origen
  -- queda `converted` EN EL NÚCLEO, en la misma transacción que la confirmación,
  -- y no en la RPC de conversión. Una orden idéntica al remito confirmada por
  -- cualquier camino (rpc_confirm_sales_order, llamada directa al núcleo) dejaría
  -- si no el remito `issued` con la venta viva: anulable (reponiendo stock) y,
  -- al borrar la venta, repuesto dos veces. No sube la revisión (no cambia el
  -- contenido). Un replay no llega acá: devolvió antes de confirmar.
  IF v_from_delivery_note THEN
    PERFORM public.record_status_transition(
      v_account_id, 'delivery_note_sale', v_dn.id, 'issued', 'converted', v_uid, NULL);
    UPDATE public.delivery_notes
    SET status = 'converted', updated_at = now(), updated_by = v_uid
    WHERE id = v_dn.id;
  END IF;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$function$;

COMMENT ON FUNCTION public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid) IS
  'C-29 (sales-order): core transaccional de la confirmación de una SalesOrder — lo comparten los dos wrappers públicos del POS, rpc_quick_sale y rpc_confirm_sales_order. tenancy-guard-caja-outbox (h1, capa 1): valida la TENENCIA del p_cash_session_id con el mismo predicado de sesión abierta + sucursal efectiva que el formulario de venta (rpc_create_sale_operation_v2) — no con sus otros dos guards sobre ese parámetro (cash_optin_requires_cash_kind y cash_optin_requires_today), que son higiene de input y no se replican a propósito — y falla con P0422 cash_optin_requires_open_session. Antes sólo chequeaba IS NULL y pasaba el id crudo a c28_register_cash_movement, así que una sesión de caja de OTRO TENANT (o de otra sucursal del mismo tenant) se confirmaba y dejaba un ingreso fantasma en el arqueo de la víctima. El guard va entre cash_requires_session y la primera escritura (D2); los dos wrappers lo HEREDAN y por eso no se tocan. Backstop de tenant en c28_register_cash_movement (P0401). Candado: supabase/tests/test_tenancy_guard_caja_outbox.sql.';


-- =============================================================================
-- 3. rpc_convert_delivery_note_to_sale (D7)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_convert_delivery_note_to_sale(
  p_idempotency_key   text,
  p_delivery_note_id  uuid,
  p_expected_revision integer,
  p_payment_method_id uuid,
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
  v_dn           public.delivery_notes%ROWTYPE;
  v_existing_op  uuid;
  v_order        RECORD;
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
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se convierte'
      USING ERRCODE = 'P0400';
  END IF;

  -- 2. Lock del documento de origen primero (ajeno = inexistente), después el
  -- rol de la transición issued -> converted del catálogo.
  SELECT * INTO v_dn
  FROM public.delivery_notes
  WHERE id = p_delivery_note_id
    AND account_id IN (SELECT public.current_account_ids())
    AND direction = 'sale'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role(v_dn.account_id, 'convert');

  -- 3. Idempotencia, leída bajo el lock: el doble clic sobre el mismo remito
  -- espera el lock de arriba y hace replay (ya converted: responde antes de
  -- mirar el estado).
  SELECT operation_id INTO v_existing_op
  FROM public.operation_idempotency
  WHERE user_id = v_uid
    AND operation_kind = 'sale'
    AND idempotency_key = p_idempotency_key;

  IF FOUND THEN
    SELECT so.id, so.total INTO v_order
    FROM public.sales_orders so
    WHERE so.sale_operation_id = v_existing_op
      AND so.source_delivery_note_id = p_delivery_note_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
        USING ERRCODE = 'P0409';
    END IF;
    RETURN jsonb_build_object(
      'delivery_note_id',     p_delivery_note_id,
      'delivery_note_number', v_dn.number,
      'sales_order_id',       v_order.id,
      'operation_id',         v_existing_op,
      'total',                v_order.total,
      'replayed',             true
    );
  END IF;

  -- 4. Estado y versión, sobre la fila bloqueada.
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede convertir', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  -- 5. Guards autosuficientes (no delegan en el guard de baja de sucursal).
  -- Cliente vivo: una venta a crédito postearía deuda contra un cliente que
  -- cobranzas excluye. Los productos dados de baja después de emitir SE
  -- CONVIERTEN (OQ-RV3): la mercadería ya se entregó.
  IF NOT EXISTS (
    SELECT 1 FROM public.clients c
    WHERE c.id = v_dn.client_id
      AND c.account_id = v_dn.account_id
      AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'delivery_note_client_unavailable: el cliente del remito fue dado de baja: editá el remito y elegí un cliente vigente'
      USING ERRCODE = 'P0404';
  END IF;
  -- Sucursal del remito activa y no cerrada (el núcleo sólo rechaza 'closed').
  IF NOT EXISTS (
    SELECT 1 FROM public.branches b
    WHERE b.id = v_dn.branch_id
      AND b.account_id = v_dn.account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'branch_closed: la sucursal del remito está desactivada o cerrada — reactivala para convertir el remito'
      USING ERRCODE = 'P0422';
  END IF;

  -- 5b. Locks de FK de las líneas, en orden ascendente de id (revisión
  -- adversarial 8.5, RB-01). Insertar líneas toma FOR KEY SHARE de cada producto
  -- por la FK, en el orden de las líneas del remito; la emisión, edición y
  -- anulación de remitos toman FOR UPDATE por id ascendente, y KEY SHARE bloquea
  -- a FOR UPDATE: con dos productos en común y orden inverso es un ciclo (40P01).
  -- Tomando acá los mismos locks, antes y por id, quedan en el mismo orden global
  -- que el resto (remito -> productos por id -> núcleo). Es KEY SHARE y no FOR
  -- UPDATE porque la conversión no mueve stock ni modifica productos. Sin filtro
  -- de baja: la FK los toma igual y un producto dado de baja se convierte.
  PERFORM 1
  FROM public.products p
  WHERE p.account_id = v_dn.account_id
    AND p.id = ANY (ARRAY(SELECT i.product_id FROM public.delivery_note_items i
                          WHERE i.delivery_note_id = v_dn.id))
  ORDER BY p.id
  FOR KEY SHARE;

  -- 6. Orden draft con origen de remito, en la sucursal del remito (de donde
  -- salió el stock), y sus líneas copiadas del remito con precios y snapshots
  -- (sin re-leer el maestro, OQ-RV13).
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, source_delivery_note_id, status, total, created_by)
  VALUES
    (v_dn.account_id, v_dn.branch_id, v_dn.client_id, v_dn.id, 'draft', v_dn.total, v_uid)
  RETURNING id INTO v_sales_order;

  PERFORM public.record_status_transition(
    v_dn.account_id, 'sales_order', v_sales_order, NULL, 'draft', v_uid, NULL);

  INSERT INTO public.sales_order_items
    (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
     name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
  SELECT v_sales_order, v_dn.account_id, i.product_id, i.unit_id, i.quantity, i.price, i.subtotal,
         i.name_snapshot, i.sku_snapshot, i.unit_cost_snapshot, i.iva_rate_snapshot
  FROM public.delivery_note_items i
  WHERE i.delivery_note_id = v_dn.id
  ORDER BY i.line_no, i.id;

  -- 7. Confirmación con el núcleo del POS, sin tipo de comprobante (facturar
  -- es una acción posterior explícita). El núcleo ve source_delivery_note_id,
  -- revalida el remito, NO mueve stock y deja el remito converted (8.5, RB-02).
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

  -- La misma clave usada en paralelo sobre OTRO documento: el núcleo esperó el
  -- ON CONFLICT y devolvió la operación ajena sin confirmar esta orden.
  IF COALESCE((v_sale->>'replayed')::boolean, false) THEN
    RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
      USING ERRCODE = 'P0409';
  END IF;

  -- 8. Resultado (la transición issued -> converted ya la hizo el núcleo, en
  -- la misma transacción).
  RETURN jsonb_build_object(
    'delivery_note_id',     v_dn.id,
    'delivery_note_number', v_dn.number,
    'sales_order_id',       v_sales_order,
    'operation_id',         (v_sale->>'operation_id')::uuid,
    'total',                (v_sale->>'total')::numeric,
    'replayed',             false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_convert_delivery_note_to_sale(text, uuid, integer, uuid, uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_convert_delivery_note_to_sale(text, uuid, integer, uuid, uuid, uuid, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_convert_delivery_note_to_sale(text, uuid, integer, uuid, uuid, uuid, text) IS
  'remitos-venta (D7, R8): convierte un remito de venta issued en una venta con un toque, SIN doble descuento. '
  'Lock del remito (ajeno = P0404 delivery_note_not_found) -> rol issued->converted del catálogo '
  '({seller,cashier,admin,owner}, P0401/P0403) -> idempotencia bajo el lock (replay; otra operación -> P0409 '
  'idempotency_key_conflict) -> estado (P0409 delivery_note_invalid_state) y versión (P0409 delivery_note_changed) '
  '-> cliente vivo (P0404 delivery_note_client_unavailable) -> sucursal del remito activa y no cerrada (P0422 '
  'branch_closed) -> orden draft con source_delivery_note_id en la sucursal del remito y líneas copiadas con sus '
  'precios y snapshots -> _c29_confirm_order_core (que con ese origen no mueve stock y deja el remito converted). '
  'Toma FOR KEY SHARE de los productos del remito por id ascendente antes de insertar líneas (sin FOR UPDATE). Devuelve {delivery_note_id, delivery_note_number, sales_order_id, operation_id, total, replayed}.';


-- =============================================================================
-- 4. rpc_delete_sale_operation desde el cuerpo vivo (D9)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_delete_sale_operation(p_sale_id uuid DEFAULT NULL::uuid, p_operation_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_sale_ids             uuid[];
  v_sales_order_id       uuid;
  v_so_status             text;
  v_reference_ids        uuid[];
  v_row                  RECORD;
  v_customer_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_cash_session_id      uuid;
  v_cash_amount          numeric(12,2);
  v_cashbox_id           uuid;
  v_open_session_id      uuid;
  v_bank_row             RECORD;
  v_reversed_type        text;
  v_voided_doc           jsonb;   -- venta-editable-sin-cae
  -- remitos-venta (D9): venta nacida de un remito.
  v_source_dn            uuid;
  v_so_branch_id         uuid;
  v_dn_label             text;
  v_dn_status            text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_sale_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_sale_operation: se requiere p_sale_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Resolver el conjunto de filas + la clave de operación (D2) ───────────
  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_sale_ids
    FROM public.sales
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.sales
    WHERE id = p_sale_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_sale_ids
      FROM public.sales
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      -- Legacy: sin operation_id — la fila es su propia operación.
      v_operation_key := p_sale_id;
      v_sale_ids := ARRAY[p_sale_id];
    END IF;
  END IF;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción,
  -- mismo ancla y mismo orden que la edición (sales → sales_orders →
  -- fiscal_documents). Las filas se toman ANTES de resolver la orden: si una
  -- promoción las tiene, se espera a que commitee y la orden que creó se ve
  -- (y se cancela) más abajo; si otra edición o borrado ganó, el conjunto
  -- se recalcula bajo el lock y, vacío, no hay nada que borrar.
  SELECT array_agg(l.id ORDER BY l.id) INTO v_sale_ids
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(v_sale_ids)
      AND  s.account_id = v_account_id
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- sales_order asociada (camino POS) — misma convención que el guard P0423.
  SELECT id, status INTO v_sales_order_id, v_so_status
  FROM public.sales_orders
  WHERE sale_operation_id = v_operation_key;

  v_reference_ids := ARRAY[v_operation_key];
  IF v_sales_order_id IS NOT NULL THEN
    v_reference_ids := v_reference_ids || v_sales_order_id;
  END IF;

  -- ── remitos-venta (D9): venta nacida de un remito ─────────────────────────
  -- La sucursal del remito (= la de la orden) tiene que estar activa y no
  -- cerrada ANTES de cualquier efecto: el guard de baja de sucursal no cuenta
  -- los remitos converted, así que una sucursal se puede vaciar y desactivar
  -- con un remito convertido; sin este guard, borrar la venta devolvería el
  -- remito a issued en una sucursal muerta (la conversión lo rechazaría y la
  -- anulación devolvería stock a una sucursal que no opera). FOR SHARE: una
  -- desactivación concurrente espera a este commit.
  IF v_sales_order_id IS NOT NULL THEN
    SELECT so.source_delivery_note_id, so.branch_id INTO v_source_dn, v_so_branch_id
    FROM public.sales_orders so
    WHERE so.id = v_sales_order_id;
  END IF;

  IF v_source_dn IS NOT NULL THEN
    SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'del remito') INTO v_dn_label
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn;

    PERFORM 1
    FROM public.branches b
    WHERE b.id = v_so_branch_id
      AND b.account_id = v_account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito % está desactivada o cerrada — reactivala antes de eliminar la venta', v_dn_label
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- ── Guard fiscal (P0423) — MISMO helper que rpc_atomic_update_sale_operation ──
  -- venta-editable-sin-cae (D2): un comprobante pendiente que NO salió hacia
  -- ARCA se ANULA acá mismo (misma transacción que el borrado), para que el
  -- relay no lo facture después. authorized, marcado y congelado siguen
  -- bloqueando con P0423. Sigue siendo el PRIMER guard, antes de compensar
  -- cuenta corriente (P0425), caja (P0426), banco y de revertir stock — si
  -- levanta, no se tocó ningún libro.
  -- Una sola definición de la regla, compartida con la edición: dos copias
  -- divergirían y una de las dos terminaría anulando un comprobante enviado.
  v_voided_doc := public._fiscal_void_pending_for_sale_edit(
    v_sales_order_id, v_account_id, v_uid,
    format('Anulado por borrado de la venta (operación %s)', v_operation_key)
  );

  -- ── Cuenta corriente de cliente: reversión del cargo (credit_note, P0425 si negativo) ──
  SELECT customer_account_id, SUM(amount)
  INTO v_customer_account_id, v_charge_amount
  FROM public.customer_account_movements
  WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
  GROUP BY customer_account_id;

  IF v_customer_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'customer', v_customer_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder anular esta venta'
        USING ERRCODE = 'P0426';
    END IF;

    PERFORM public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'sale_reversal', v_operation_key
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled (D6) ─────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'sale' AND source_doc_ref = ANY(v_reference_ids)
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'sale', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  -- remitos-venta (D9): una venta nacida de un remito NO repone stock: la
  -- mercadería quedó entregada con el remito, que vuelve a pendiente más
  -- abajo (para devolverla al stock se anula el remito). El salto es
  -- explícito: no depende de que esas filas sales no tengan movimientos.
  IF v_source_dn IS NULL THEN
    FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
      PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
    END LOOP;
  END IF;

  -- ── Contable: emitir SaleOperationDeleted (async, vía outbox) ────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationDeleted', 'SaleOperation', v_operation_key,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_operation_key,
      'sales_order_id', v_sales_order_id,
      'occurred_at',    now()
    ),
    now()
  );

  -- ── POS: cancelar la sales_order en la misma transacción (D8) ────────────
  IF v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    UPDATE public.sales_orders
    SET status = 'canceled', sale_operation_id = NULL
    WHERE id = v_sales_order_id;

    PERFORM public.record_status_transition(
      v_account_id, 'sales_order', v_sales_order_id, 'confirmed', 'canceled',
      v_uid, COALESCE(p_reason, 'Venta eliminada')
    );
  END IF;

  -- ── remitos-venta (D9, R5): el remito vuelve a pendiente ─────────────────
  -- Lock del remito AL FINAL (sales -> sales_orders -> fiscal_documents ->
  -- delivery_notes). La orden ya pasó a canceled, así que el índice único
  -- parcial queda libre y el remito se puede volver a convertir. La
  -- transición converted -> issued no tiene rol propio: este borrado ya
  -- registró sales_order confirmed -> canceled, que exige admin/owner.
  IF v_source_dn IS NOT NULL AND v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    SELECT dn.status INTO v_dn_status
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn
    FOR UPDATE;

    IF v_dn_status = 'converted' THEN
      PERFORM public.record_status_transition(
        v_account_id, 'delivery_note_sale', v_source_dn, 'converted', 'issued',
        v_uid, format('Venta eliminada (operación %s)', v_operation_key)
      );

      UPDATE public.delivery_notes
      SET status = 'issued', updated_at = now(), updated_by = v_uid
      WHERE id = v_source_dn;
    END IF;
  END IF;

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(v_sale_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) IS
  'delete-guard-ledgers: RPC atómica de borrado de venta — guard fiscal (P0423), compensa cuenta corriente (P0425), caja (P0426) y banco, revierte stock (#417), emite SaleOperationDeleted, cancela la sales_order del POS. Acepta p_sale_id (delete_by_id) o p_operation_id (delete_by_operation).';


-- =============================================================================
-- 5. rpc_atomic_update_sale_operation desde el cuerpo vivo (D9)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_canal text DEFAULT NULL::text, p_canal_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_old_sale       RECORD;
  v_item           RECORD;
  v_product        RECORD;
  v_new_op_id      uuid;
  v_new_sale_id    uuid;
  v_stock_sum      numeric(15,4);
  v_result_items   jsonb := '[]'::jsonb;
  v_flag_on        boolean;
  v_old_snapshots  jsonb;
  v_prev_snap      jsonb;
  v_line_snap      jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
  v_reverse_delta     numeric;         -- ventas-unidades-conversion (D6)
  v_apply_qty_norm    numeric(15,4);   -- ventas-unidades-conversion (D1)
  v_old_payment_method_id   uuid;  -- metodos-pago-operaciones (D5)
  v_final_payment_method_id uuid;  -- metodos-pago-operaciones (D5)
  -- edicion-preserva-contexto (F1):
  v_old_operation_id uuid;         -- §D9: para re-apuntar sales_orders
  v_old_branch_id    uuid;         -- §D1/§D3
  v_old_canal        text;         -- §D1/§D3
  v_final_branch_id  uuid;         -- §D3/§D8: sucursal EFECTIVA (reimputada o vieja)
  v_final_canal      text;         -- §D3
  v_canal_clean      text;
  v_branch           RECORD;
  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable de la operación editada en vez de bloquear la edición.
  v_total_sum          numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
  v_kind_final          text;
  v_pending_event_id    uuid;
  v_pending_event_type  text;
  v_pending_payload     jsonb;
  v_has_posted_entry    boolean := false;
  -- venta-editable-sin-cae: la anulación del comprobante pendiente NO enviado.
  v_void_rec            RECORD;   -- (sales_order_id, operation_id) a anular
  v_voided_doc          jsonb;    -- descriptor del último comprobante anulado
  -- venta-editable-vs-promocion-legacy (20261061000001):
  v_locked              integer;  -- filas de la operación tomadas con FOR UPDATE
  v_resync_id           uuid;     -- orden re-apuntada que se recalcula (N3)
  v_dn_label            text;     -- remitos-venta (D9): remito de origen de la venta
BEGIN
  -- Identity always comes from the JWT — never from caller input
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Account scoping (C-05 D7) ────────────────────────────────────────────
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede actualizar la operación'
      USING ERRCODE = 'P0403';
  END IF;

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P0400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.sales
    WHERE id = ANY(p_sale_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: sale belongs to another user' USING ERRCODE = 'P0403';
  END IF;

  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids))
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción.
  -- Las filas de sales de la operación son lo único que existe ANTES que la
  -- orden, así que son el ancla común: la promoción, la edición y el borrado
  -- las toman PRIMERO, con FOR UPDATE y en orden ascendente de id. Orden
  -- global de locks: sales → sales_orders → fiscal_documents → resto.
  -- Sin este lock, el enumerador de órdenes de más abajo leía SIN lock, no
  -- veía la orden que una promoción concurrente estaba creando, y la venta
  -- quedaba editada con un comprobante pendiente VIVO por importes viejos.
  -- Recuento bajo el lock: si otra edición o un borrado ganó y se llevó
  -- alguna fila mientras se esperaba, se aborta acá, antes de revertir stock
  -- o de tocar cualquier libro (doble "Guardar" incluido).
  SELECT count(*) INTO v_locked
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(p_sale_ids)
      AND  s.user_id = v_uid
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_locked <> array_length(p_sale_ids, 1) THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): la edición también puede reasignar el
  -- client_id de la operación (p_client_id es obligatorio, sin contrato
  -- tri-estado _provided — el llamador siempre lo reenvía) y hoy lo
  -- escribe sin validar tenencia, igual que rpc_create_sale_operation_v2
  -- antes de este fix. Mismo predicado, mismo ERRCODE, ANTES de cualquier
  -- guard de inmutabilidad/reversa.
  IF p_client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = p_client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- remitos-venta (D9): una venta nacida de un remito NO se edita. El editor
  -- siempre reemplaza líneas (REVERSE + APPLY) y la REVERSE, sin movimiento
  -- propio de esas filas sales, cae a la normalización de la línea y
  -- REPONDRÍA stock que el remito sigue reteniendo (la APPLY lo descontaría
  -- de nuevo; una reducción dejaría reposición de más que la anulación del
  -- remito duplicaría). Va ANTES del bloque fiscal para no anular un
  -- comprobante pendiente por una edición que igual se rechaza, y bloquea la
  -- operación entera (también la cabecera).
  SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'de origen') INTO v_dn_label
  FROM   public.sales s
  JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
  JOIN   public.delivery_notes dn ON dn.id = so.source_delivery_note_id
  WHERE  s.id = ANY(p_sale_ids)
  LIMIT  1;

  IF FOUND THEN
    RAISE EXCEPTION 'delivery_note_sale_locked: la venta nació del remito %: para corregirla, eliminá la venta, editá el remito y volvé a convertirlo', v_dn_label
      USING ERRCODE = 'P0423';
  END IF;

  -- edicion-preserva-contexto (F2, design §D5) + venta-editable-sin-cae (D2):
  -- guard fiscal — SHALL correr antes de cualquier reversa/eliminación/
  -- reaplicación, de modo que una operación bloqueada quede intacta si el
  -- guard dispara. Resuelto por JOIN (sales.operation_id →
  -- sales_orders.sale_operation_id → sales_orders.fiscal_document_id →
  -- fiscal_documents), nunca por una columna denormalizada de "facturado"
  -- (segunda fuente de verdad).
  --
  -- venta-editable-sin-cae: el predicado deja de ser "¿HAY comprobante?" y
  -- pasa a ser "¿el comprobante YA SALIÓ hacia ARCA?". Un pending_cae SIN
  -- marca de envío ya no bloquea: se ANULA (voided) en ESTA MISMA
  -- transacción, para que el relay no lo facture después con los importes
  -- viejos. authorized, marcado y congelado siguen bloqueando con P0423
  -- (tres tokens distintos — ver _fiscal_void_pending_for_sale_edit, que es
  -- la ÚNICA definición de esta regla y la comparte con el borrado).
  -- rejected y voided no bloquean ni se tocan.
  -- asiento-venta-formulario: el guard fiscal sigue siendo el PRIMERO.
  --
  -- Esta query NO filtra por `so.fiscal_document_id IS NOT NULL` (red team
  -- 2026-09-22, M1): ese filtro se evalúa SIN lock, así que con una emisión
  -- abierta en otra conexión devolvía cero filas, el helper no se llamaba
  -- NUNCA, y la venta se editaba dejando vivo el comprobante que la emisión
  -- estaba por commitear. Quién decide "hay comprobante" es el helper, con la
  -- fila de la orden BLOQUEADA. Acá sólo se enumeran las órdenes de la
  -- operación (a lo sumo una: sale_operation_id tiene índice único parcial).
  FOR v_void_rec IN
    SELECT DISTINCT so.id AS sales_order_id, s.operation_id AS operation_id
    FROM   public.sales s
    JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
    WHERE  s.id = ANY(p_sale_ids)
  LOOP
    v_voided_doc := public._fiscal_void_pending_for_sale_edit(
      v_void_rec.sales_order_id, v_account_id, v_uid,
      format('Anulado por edición de la venta (operación %s)', v_void_rec.operation_id)
    );
  END LOOP;

  -- pagos-cableados-restantes (D6): inmutabilidad de operaciones con cargo
  -- de cuenta corriente o movimiento de caja posteado. Bloquea la operación
  -- ENTERA (no sólo monto/método — editar la fecha desplazaría la
  -- atribución temporal del movimiento). reference_id de ambas tablas puede
  -- apuntar a sales_orders.id (camino POS, vía _pay_register_party_charge /
  -- c28_register_cash_movement dentro de _c29_confirm_order_core, p_reference_id
  -- = p_sales_order_id) o directamente a sales.operation_id (camino
  -- formulario, rpc_create_sale_operation_v2) — se cubren ambos.
  -- asiento-venta-formulario: guards de cuenta corriente/caja/banco SIN CAMBIOS.
  IF EXISTS (
    SELECT 1
    FROM public.customer_account_movements cam
    WHERE cam.reference_id IN (
      SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
      UNION
      SELECT so.id FROM public.sales_orders so
      JOIN public.sales s ON s.operation_id = so.sale_operation_id
      WHERE s.id = ANY(p_sale_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_account_charge_immutable: la operación tiene un cargo de cuenta corriente posteado y no puede editarse — emití una nota de crédito y registrá una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cash_movements cm
    WHERE cm.reference_id IN (
      SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
      UNION
      SELECT so.id FROM public.sales_orders so
      JOIN public.sales s ON s.operation_id = so.sale_operation_id
      WHERE s.id = ANY(p_sale_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_cash_movement_immutable: la operación tiene un movimiento de caja posteado y no puede editarse — emití una nota de crédito y registrá una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.1): tercer EXISTS — bank_movements
  -- entra al mismo bloqueo P0423, misma doble referencia. El ledger
  -- bancario es append-only (C1) y el movimiento puede estar ya `matched`
  -- dentro de una sesión de conciliación cerrada: editarlo destruiría una
  -- conciliación firmada.
  IF EXISTS (
    SELECT 1
    FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'sale'
      AND bm.source_doc_ref IN (
        SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
        UNION
        SELECT so.id FROM public.sales_orders so
        JOIN public.sales s ON s.operation_id = so.sale_operation_id
        WHERE s.id = ANY(p_sale_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_bank_movement_immutable: la operación tiene un movimiento bancario posteado y no puede editarse — registrá el ajuste en el ledger bancario y una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- edicion-operaciones-lineas (D3): mismo flag_key y mismo patrón
  -- COALESCE-después-del-SELECT que rpc_create_sale_operation — ausencia de
  -- fila = v2 (escribe línea).
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  -- edicion-operaciones-lineas (D2): acarreo de snapshot keyed por
  -- product_id, capturado ANTES del DELETE — el CASCADE se lleva puesto
  -- sale_items en STEP 2. DISTINCT ON (product_id) ORDER BY product_id, id:
  -- determinístico ante colisión (dos filas viejas de header con el mismo
  -- producto — la forma legacy 1-operación:N-filas, 23 ventas en prod).
  SELECT COALESCE(jsonb_object_agg(t.product_id::text, t.snap), '{}'::jsonb)
  INTO   v_old_snapshots
  FROM (
    SELECT DISTINCT ON (si.product_id)
           si.product_id,
           jsonb_build_object(
             'name_snapshot',       si.name_snapshot,
             'sku_snapshot',        si.sku_snapshot,
             'unit_cost_snapshot',  si.unit_cost_snapshot,
             'iva_rate_snapshot',   si.iva_rate_snapshot,
             'snapshot_backfilled', si.snapshot_backfilled
           ) AS snap
    FROM   public.sale_items si
    WHERE  si.sale_id = ANY(p_sale_ids)
      AND  si.product_id IS NOT NULL
    ORDER BY si.product_id, si.id
  ) t;

  -- metodos-pago-operaciones (D5): capturar el payment_method_id vigente de
  -- la operación ANTES del DELETE — mismo momento que v_old_snapshots. Por
  -- operación (D3): cualquier fila alcanza (todas comparten el valor).
  SELECT payment_method_id INTO v_old_payment_method_id
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
  LIMIT  1;

  IF p_payment_method_provided THEN
    IF p_payment_method_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old_payment_method_id;
  END IF;

  -- edicion-preserva-contexto (F1, design §D1): capturar el contexto vigente
  -- del header ANTES del DELETE, junto al resto de lo que se acarrea.
  -- LIMIT 1 es correcto: branch_id/canal/operation_id son de la operación,
  -- no de la línea — todas las filas del mismo operation_id los comparten
  -- (misma justificación que payment_method_id, D3 de #419).
  SELECT operation_id, branch_id, canal
  INTO   v_old_operation_id, v_old_branch_id, v_old_canal
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
  LIMIT  1;

  -- asiento-venta-formulario (D7, override del PO): resolver el rastro
  -- contable de v_old_operation_id ANTES del REVERSE/DELETE — no se
  -- rechaza la edición, se ajusta el rastro más abajo. Caso B: se toma el
  -- lock ACÁ, sobre el evento pendiente (SaleOperationCreated apuntando a
  -- esta operación, o SaleOperationAdjusted cuyo new_operation_id es esta
  -- operación), para no competir con el dispatcher a mitad de camino. Bajo
  -- READ COMMITTED, SELECT ... FOR UPDATE re-evalúa el WHERE contra la
  -- versión más reciente de la fila al tomar el lock: si el dispatcher ya
  -- la marcó processed_at mientras se esperaba el lock, Postgres la excluye
  -- automáticamente del resultado — no hace falta un re-chequeo manual.
  IF v_old_operation_id IS NOT NULL THEN
    SELECT id, event_type, payload
    INTO   v_pending_event_id, v_pending_event_type, v_pending_payload
    FROM   public.events
    WHERE  processed_at IS NULL
      AND  (
             (event_type = 'SaleOperationCreated' AND aggregate_id = v_old_operation_id)
          OR (event_type = 'SaleOperationAdjusted' AND (payload->>'new_operation_id')::uuid = v_old_operation_id)
           )
    ORDER BY occurred_at
    LIMIT 1
    FOR UPDATE;

    -- Caso C: sin evento pendiente reemplazable — ¿hay un asiento ya posteado?
    IF v_pending_event_id IS NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_old_operation_id
          AND status = 'posted'
      ) INTO v_has_posted_entry;
    END IF;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para branch_id —
  -- espejo exacto del contrato de payment_method_id. provided=false →
  -- preservar; provided=true + NULL → desimputar; provided=true + valor →
  -- reimputar, previa validación de pertenencia a la cuenta y sucursal
  -- operativa (mismo guard que rpc_create_sale_operation_v2, C-26). La
  -- validación corre ACÁ, antes del REVERSE (gate 2.9: una reimputación
  -- inválida no debe revertir ni reaplicar stock).
  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM   public.branches
      WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old_branch_id;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para canal —
  -- mismo contrato. Sin conjunto cerrado en el schema (sales.canal es texto
  -- libre, sin CHECK) — se valida longitud igual que rpc_create_sale_operation_v2.
  IF p_canal_provided THEN
    v_canal_clean := NULLIF(trim(COALESCE(p_canal, '')), '');
    IF v_canal_clean IS NOT NULL AND length(v_canal_clean) > 40 THEN
      RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
    END IF;
    v_final_canal := v_canal_clean;
  ELSE
    v_final_canal := v_old_canal;
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — id vieja
  -- es el reference_id de la pata REVERSE, operation_id agrupa el movimiento
  -- bajo la operación a la que pertenecía la fila que se está reemplazando.
  -- La pata REVERSE sigue devolviendo a la sucursal VIEJA de cada fila
  -- (v_old_sale.branch_id) — no cambia con F1 (§D8: REVERSE = sucursal vieja).
  FOR v_old_sale IN
    SELECT id, product_id, quantity, unit_id, branch_id, operation_id
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      -- Nombre actual del producto para el movimiento (congelar el nombre no
      -- es el contrato de este movimiento — el name_snapshot vive en la
      -- línea, no acá — se usa el mismo patrón que la creación: products.name
      -- vigente al momento de la operación).
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_sale.product_id;

      -- design §D5 (stock-movements-edicion): la pata REVERSE copia el
      -- unit_cost_snapshot del movimiento ORIGINAL si existe; si no, NULL.
      -- ventas-unidades-conversion (D6): la pata REVERSE devuelve EXACTAMENTE
      -- lo que el movimiento original descontó (quantity_delta, ya en unidad
      -- base del producto), nunca la cantidad cruda de la línea. Sin
      -- movimiento (fila anterior al ledger C-21) cae a la definición única.
      SELECT unit_cost_snapshot, -quantity_delta INTO v_reverse_unit_cost, v_reverse_delta
      FROM   public.stock_movements
      WHERE  reference_id = v_old_sale.id AND reference_type = 'sale'
      ORDER  BY created_at DESC
      LIMIT  1;

      -- C-21 checkpoint #2: devolver a la branch original de la venta (o default).
      -- stock-movements-edicion (D2/D3): op_stock_movement aplica el delta
      -- (misma aritmética que antes) Y emite el movimiento espejo REVERSE:
      -- type='sale_return', reference_id=id VIEJO, reference_type='sale_update'.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_sale.product_id, v_old_product_name,
        v_old_sale.branch_id,
        COALESCE(v_reverse_delta,
                 public._uom_normalize_quantity(v_old_sale.product_id, v_old_sale.unit_id, v_old_sale.quantity)),
        'sale_return',
        v_old_sale.id, 'sale_update', v_old_sale.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  -- sale_items.sale_id tiene FK ON DELETE CASCADE: este DELETE es lo que
  -- borraba la línea sin recrearla (el hallazgo de edicion-operaciones-lineas).
  -- El acarreo de arriba ya capturó lo necesario antes de perderlo.
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  -- edicion-preserva-contexto (F3, design §D7): quantity pasa de integer a
  -- numeric — único eslabón entero de una cadena que ya es numeric(15,4) de
  -- punta a punta. unit_id se suma al recordset (igual forma que la
  -- creación) para escribirlo real en vez de NULL explícito (§D7 último
  -- párrafo).
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    -- asiento-venta-formulario: acumular el total nuevo (mismo patrón que
    -- rpc_create_sale_operation_v2) para el ajuste contable de más abajo.
    v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock).
      -- edicion-operaciones-lineas: se agrega name/sku/cost a la misma
      -- lectura para resolver el snapshot fresco sin una consulta extra.
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- ventas-unidades-conversion (D1): cantidad de la línea nueva en unidad
      -- base del producto — gate de stock y pata APPLY usan este valor.
      v_apply_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      IF v_stock_sum < v_apply_qty_norm THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal = v_final_* (F1 §D3),
      -- unit_id = v_item.unit_id (F1 §D7, viaja con la línea).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- edicion-operaciones-lineas (D2/D4): la línea sigue al header.
      -- product_id presente en el mapa viejo → acarrea (una corrección de
      -- cantidad/precio no re-precifica); ausente → snapshot fresco
      -- (producto nuevo, ítem agregado, u operación que nunca tuvo línea).
      -- stock-movements-edicion: v_line_snap se calcula SIEMPRE (antes vivía
      -- adentro del IF v_flag_on) porque el movimiento de stock lo necesita
      -- exista o no la línea — el kill-switch apaga sale_items, no el ledger.
      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      IF v_flag_on THEN
        -- edicion-preserva-contexto: unit_id = v_item.unit_id en vez de NULL
        -- explícito (F1 §D7 último párrafo).
        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock.
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='sale',
      -- reference_id=id NUEVO, reference_type='sale' (indistinguible de la
      -- creación — el contrato del que depende la reversa al eliminar).
      -- unit_cost_snapshot reusa v_line_snap, la misma decisión de acarreo
      -- que la línea (sin re-valuar al costo actual).
      -- edicion-preserva-contexto (F1 §D8): la sucursal pasa a ser
      -- v_final_branch_id (la efectiva) en vez de NULL — editar deja de
      -- mudar stock a la sucursal default.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, -v_apply_qty_norm, 'sale', v_new_sale_id, 'sale',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal/unit_id preservados/reimputados igual.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
  -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
  -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
  -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
  -- venta de 665,334 y una factura de round(Σ) = 665,33.
  v_total_sum := round(v_total_sum, 2);

  -- edicion-preserva-contexto (F1, design §D9): la orden promovida SIN
  -- comprobante "real" se re-apunta al operation_id nuevo, en la misma
  -- transacción — cierra en su causa raíz la OQ-C de edicion-operaciones-
  -- lineas (3 órdenes colgadas en prod hoy, no reconstruibles
  -- retroactivamente: nada registró antes el mapeo operation_id viejo→nuevo
  -- de esas ediciones — ver design §D10).
  --
  -- "no tiene comprobante fiscal asociado" usa la MISMA definición que el
  -- guard F2 de arriba (§D5): fiscal_document_id NULL, o apuntando a un
  -- comprobante 'rejected' (nunca existió fiscalmente) — no solo NULL a
  -- secas. Sin este matiz, una orden cuyo único comprobante quedó rejected
  -- SÍ pasa el guard F2 (rejected no bloquea, D5) y SÍ se edita, pero
  -- fiscal_document_id sigue NOT NULL apuntando al doc rejected → un
  -- `WHERE fiscal_document_id IS NULL` a secas la deja huérfana (gate 2.8,
  -- descubierto en RED contra esta migración: no era redundante con F2, F2
  -- ya deja pasar exactamente este caso).
  --
  -- venta-editable-vs-promocion-legacy (N3): la orden re-apuntada SIGUE a la
  -- operación también en importes. Re-apuntar sólo sale_operation_id dejaba
  -- total, cliente y líneas VIEJOS: la re-facturación después de anular (D5
  -- de venta-editable-sin-cae) y el "Facturar" de una venta del POS editada
  -- emitían por el importe anterior. El recálculo vive en UN solo lugar,
  -- compartido con la promoción: _sales_order_sync_from_operation. El
  -- predicado del re-apuntado no cambia; el helper de anulación ya corrió
  -- arriba, así que acá sólo llegan órdenes sin comprobante o con uno
  -- rechazado/anulado (a lo sumo una: índice único parcial).
  UPDATE public.sales_orders so
  SET    sale_operation_id = v_new_op_id
  WHERE  so.sale_operation_id = v_old_operation_id
    AND  NOT EXISTS (
      SELECT 1 FROM public.fiscal_documents fd
      WHERE fd.id = so.fiscal_document_id
        AND fd.status IN ('pending_cae', 'authorized')
    )
  RETURNING so.id INTO v_resync_id;

  IF v_resync_id IS NOT NULL THEN
    PERFORM public._sales_order_sync_from_operation(v_resync_id, v_new_op_id, v_account_id);
  END IF;

  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable AHORA que v_new_op_id/v_total_sum/v_final_payment_method_id
  -- son finales. v_pending_event_id / v_has_posted_entry ya fueron
  -- resueltos ANTES del REVERSE/DELETE (con el lock tomado en el momento
  -- correcto) — acá sólo se actúa sobre lo ya resuelto.
  IF v_final_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind_final
    FROM public.payment_methods
    WHERE id = v_final_payment_method_id;
  ELSE
    v_kind_final := NULL;
  END IF;

  IF v_pending_event_id IS NOT NULL THEN
    -- Caso B (D7): reemplazar el evento pendiente EN EL LUGAR — el
    -- dispatcher, cuando lo procese, genera un solo asiento final,
    -- correcto, referenciando v_new_op_id. No se emite un segundo evento.
    IF v_pending_event_type = 'SaleOperationCreated' THEN
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = jsonb_build_object(
               'account_id',     v_account_id,
               'operation_id',   v_new_op_id,
               'total',          v_total_sum,
               'payment_method', v_kind_final,
               'client_id',      p_client_id,
               'sale_date',      p_date,
               'occurred_at',    now()
             )
      WHERE  id = v_pending_event_id;
    ELSE
      -- 'SaleOperationAdjusted' todavía pendiente (edición encadenada antes
      -- de que el relay procese la anterior): se actualiza el destino
      -- (new_operation_id) y los valores nuevos, pero se PRESERVA
      -- old_operation_id — la referencia al asiento a revertir no cambia,
      -- sigue siendo el mismo asiento original, todavía no tocado. Esto
      -- colapsa N ediciones-antes-de-procesar en un solo evento final.
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = v_pending_payload
                        || jsonb_build_object(
                             'new_operation_id', v_new_op_id,
                             'total',            v_total_sum,
                             'payment_method',   v_kind_final,
                             'client_id',        p_client_id,
                             'sale_date',        p_date,
                             'occurred_at',      now()
                           )
      WHERE  id = v_pending_event_id;
    END IF;
  ELSIF v_has_posted_entry THEN
    -- Caso C (D7): el asiento ya fue posteado — emitir el evento de
    -- ajuste. INSERT plano, SIN bloque EXCEPTION (D6): swallowear el
    -- fallo reproduciría en silencio el bug que este change arregla.
    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      v_account_id, 'SaleOperationAdjusted', 'SaleOperation', v_new_op_id,
      jsonb_build_object(
        'old_operation_id', v_old_operation_id,
        'new_operation_id', v_new_op_id,
        'account_id',       v_account_id,
        'total',            v_total_sum,
        'payment_method',   v_kind_final,
        'client_id',        p_client_id,
        'sale_date',        p_date,
        'occurred_at',      now()
      ),
      now()
    );
  END IF;
  -- Caso A (D7): ni v_pending_event_id ni v_has_posted_entry — no-op contable
  -- (operación anterior al productor, o que nunca tuvo evento).

  -- venta-editable-sin-cae: el descriptor del comprobante anulado viaja en la
  -- respuesta para que el toast diga "se anuló el comprobante 0003-00000005"
  -- con lo que dice el SERVIDOR, nunca con lo que el cliente creía.
  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items,
                            'voided_fiscal_document', v_voided_doc);
END;
$function$;

COMMENT ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) IS
  'edicion-preserva-contexto: preserva branch_id/canal/unit_id al editar (F1, tri-estado para branch_id/canal), bloquea la edición de una operación facturada con P0423 (F2), acepta quantity decimal (F3), y re-apunta sales_orders promovida sin comprobante al operation_id nuevo (F1 §D9). Base: #415 (líneas) + #417 (espejo de stock) + #419 (forma de pago).';


-- =============================================================================
-- 6. _delivery_note_payload: la venta generada pasa a derivarse (tanda A -> B)
-- =============================================================================
CREATE OR REPLACE FUNCTION public._delivery_note_payload(p_dn_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT to_jsonb(dn)
         || jsonb_build_object(
              'document_type', 'delivery_note_' || dn.direction,
              'client_name',   (SELECT c.name FROM public.clients c WHERE c.id = dn.client_id),
              'client_phone',  (SELECT c.phone FROM public.clients c WHERE c.id = dn.client_id),
              'client_deleted', (SELECT c.deleted_at IS NOT NULL FROM public.clients c WHERE c.id = dn.client_id),
              'branch_name',   (SELECT b.name FROM public.branches b WHERE b.id = dn.branch_id),
              -- remitos-venta tanda B: la orden VIVA nacida del remito (a lo
              -- sumo una, índice único parcial); NULL si no está convertido.
              'converted_sales_order_id', (SELECT so.id FROM public.sales_orders so
                                           WHERE so.source_delivery_note_id = dn.id
                                             AND so.account_id = dn.account_id
                                             AND so.status <> 'canceled'),
              'converted_operation_id',   (SELECT so.sale_operation_id FROM public.sales_orders so
                                           WHERE so.source_delivery_note_id = dn.id
                                             AND so.account_id = dn.account_id
                                             AND so.status <> 'canceled'),
              'items', COALESCE((
                SELECT jsonb_agg(to_jsonb(i)
                                 || jsonb_build_object(
                                      'unit_symbol', (SELECT u.symbol FROM public.units_of_measure u WHERE u.id = i.unit_id),
                                      'product_deleted', (SELECT p.deleted_at IS NOT NULL FROM public.products p WHERE p.id = i.product_id))
                                 ORDER BY i.line_no, i.id)
                FROM public.delivery_note_items i
                WHERE i.delivery_note_id = dn.id), '[]'::jsonb),
              'history', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                         'from_status', h.from_status, 'to_status', h.to_status,
                         'performed_by', h.performed_by, 'reason', h.reason, 'occurred_at', h.occurred_at)
                       ORDER BY h.occurred_at, h.id)
                FROM public.document_status_history h
                WHERE h.document_type = 'delivery_note_' || dn.direction
                  AND h.document_id = dn.id
                  AND h.account_id = dn.account_id), '[]'::jsonb))
  FROM public.delivery_notes dn
  WHERE dn.id = p_dn_id;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_payload(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_payload(uuid) IS
  'remitos-venta: fila de delivery_notes + document_type, nombres de cliente y sucursal, líneas en orden de '
  'carga (con símbolo de unidad y si el producto fue dado de baja) e historial de estados. '
  'converted_sales_order_id/converted_operation_id: la orden VIVA (no cancelada) nacida del remito (tanda B), '
  'NULL si no está convertido. Interna.';


-- =============================================================================
-- 6b. _branch_assert_empty: el texto de baja ofrece convertir o anular (6.0b)
-- =============================================================================
-- Desde su cuerpo vivo (== el de 20261069000001, md5 verificado contra el stack
-- local y prod): UNICO cambio, el mensaje del RAISE de
-- branch_has_pending_delivery_notes, que desde esta tanda ofrece la salida de
-- "convertilos en venta" ademas de anularlos. El token, el errcode P0428, las
-- tres condiciones previas y el COMMENT vivo no cambian (CREATE OR REPLACE con
-- la misma firma conserva ACL y COMMENT). CI reaplica 20261069000001 antes que
-- esta migracion, que vuelve a dejar este cuerpo.
CREATE OR REPLACE FUNCTION public._branch_assert_empty(p_branch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_content RECORD;
  v_pending_delivery_notes bigint;
BEGIN
  SELECT * INTO v_content
  FROM public._branch_blocking_content(p_branch_id);

  -- Orden de evaluación D2: 1) existencias, 2) caja abierta, 3) transferencias.
  IF v_content.total_qty <> 0 THEN
    IF v_content.other_active_branches = 0 THEN
      -- La única sucursal activa de la cuenta: no hay a dónde transferir.
      RAISE EXCEPTION
        'branch_has_stock: la sucursal tiene % unidades en % producto(s) y es la única sucursal activa de la cuenta — creá otra sucursal para poder transferirle el stock antes de darla de baja',
        v_content.total_qty, v_content.product_count
        USING ERRCODE = 'P0428';
    ELSE
      RAISE EXCEPTION
        'branch_has_stock: la sucursal tiene % unidades en % producto(s) — transferí el stock a otra sucursal antes de darla de baja',
        v_content.total_qty, v_content.product_count
        USING ERRCODE = 'P0428';
    END IF;
  END IF;

  IF v_content.cash_session_open THEN
    RAISE EXCEPTION
      'branch_has_open_cash_session: la sucursal tiene una sesión de caja abierta — cerrala antes de darla de baja'
      USING ERRCODE = 'P0428';
  END IF;

  IF v_content.pending_transfers > 0 THEN
    RAISE EXCEPTION
      'branch_has_pending_transfers: la sucursal tiene % transferencia(s) de stock sin completar — esperá a que terminen antes de darla de baja',
      v_content.pending_transfers
      USING ERRCODE = 'P0428';
  END IF;

  -- remitos-venta (D10): 4) remitos pendientes, sin importar el sentido. Una
  -- sucursal dada de baja con un remito issued dejaría a la conversión sin
  -- sucursal y a la anulación reponiendo stock en una sucursal que no opera.
  v_pending_delivery_notes := public._branch_pending_delivery_notes(p_branch_id);
  IF v_pending_delivery_notes > 0 THEN
    RAISE EXCEPTION
      'branch_has_pending_delivery_notes: la sucursal tiene % remito(s) pendiente(s) — convertilos en venta o anulalos (un administrador o el dueño) antes de darla de baja',
      v_pending_delivery_notes
      USING ERRCODE = 'P0428';
  END IF;

  -- Nada bloquea: la baja puede proceder.
END;
$function$;


-- =============================================================================
-- 7. Introspección final
-- =============================================================================
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_sig  text;
  v_src  text;
  v_acl  text;
BEGIN
  -- Columna, FK NO ACTION e índice único parcial.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'sales_orders'
                   AND column_name = 'source_delivery_note_id' AND data_type = 'uuid' AND is_nullable = 'YES') THEN
    v_bad := v_bad || 'sales_orders.source_delivery_note_id (uuid NULL)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'sales_orders_source_delivery_note_id_fkey'
                   AND conrelid = 'public.sales_orders'::regclass AND contype = 'f'
                   AND confrelid = 'public.delivery_notes'::regclass AND confdeltype = 'a') THEN
    v_bad := v_bad || 'FK sales_orders_source_delivery_note_id_fkey ON DELETE NO ACTION'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND indexname = 'sales_orders_source_delivery_note_id_uq'
                   AND indexdef LIKE 'CREATE UNIQUE INDEX%'
                   AND indexdef LIKE '%source_delivery_note_id IS NOT NULL%'
                   AND indexdef LIKE '%<> ''canceled''%') THEN
    v_bad := v_bad || 'índice único parcial sales_orders_source_delivery_note_id_uq'::text;
  END IF;

  -- Catálogo: las dos filas de esta tanda, por presencia y atributos (la
  -- introspección de la tanda A valida las suyas del mismo modo).
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_sale' AND from_status = 'issued' AND to_status = 'converted'
                   AND NOT is_terminal_to AND NOT requires_reason
                   AND allowed_role @> ARRAY['seller', 'cashier', 'admin', 'owner']
                   AND allowed_role <@ ARRAY['seller', 'cashier', 'admin', 'owner']) THEN
    v_bad := v_bad || 'catálogo delivery_note_sale issued->converted {seller,cashier,admin,owner}'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_sale' AND from_status = 'converted' AND to_status = 'issued'
                   AND allowed_role IS NULL AND NOT is_terminal_to AND NOT requires_reason) THEN
    v_bad := v_bad || 'catálogo delivery_note_sale converted->issued (sistema, sin rol)'::text;
  END IF;

  -- Una sola definición de cada función reescrita o nueva.
  FOREACH v_sig IN ARRAY ARRAY['_c29_confirm_order_core', 'rpc_delete_sale_operation',
                               'rpc_atomic_update_sale_operation', 'rpc_convert_delivery_note_to_sale',
                               '_delivery_note_payload'] LOOP
    IF (SELECT count(*) FROM pg_proc WHERE proname = v_sig AND pronamespace = 'public'::regnamespace) <> 1 THEN
      v_bad := v_bad || format('una sola definición de %s', v_sig);
    END IF;
  END LOOP;

  -- ACL idéntica a la previa en las tres reescritas (checkpoint 6.1), la de la
  -- RPC nueva (authenticated sí, anon/PUBLIC no) y el payload interno.
  FOR v_sig, v_acl IN
    SELECT * FROM (VALUES
      ('public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)', 'authenticated,postgres,service_role'),
      ('public.rpc_delete_sale_operation(uuid,uuid,text)', 'authenticated,postgres,service_role'),
      ('public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)', 'authenticated,postgres,service_role'),
      ('public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)', 'authenticated,postgres,service_role'),
      ('public._delivery_note_payload(uuid)', 'postgres,service_role')
    ) AS t(sig, acl)
  LOOP
    IF (SELECT string_agg(r.rolname, ',' ORDER BY r.rolname)
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(p.proacl) a
        JOIN pg_roles r ON r.oid = a.grantee
        WHERE p.oid = v_sig::regprocedure AND a.privilege_type = 'EXECUTE') IS DISTINCT FROM v_acl
       OR EXISTS (SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
                  WHERE p.oid = v_sig::regprocedure AND a.grantee = 0) THEN
      v_bad := v_bad || format('ACL de %s (se esperaba EXECUTE para %s, sin PUBLIC)', v_sig, v_acl);
    END IF;
  END LOOP;

  -- Cuerpos: la rama del núcleo, el salto y el guard del borrado, el P0423 de
  -- la edición y el orden de la conversión.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)'::regprocedure;
  IF position('v_order.source_delivery_note_id IS NOT NULL' IN v_src) = 0
     OR position('delivery_note_order_mismatch' IN v_src) = 0
     OR position('IF v_from_delivery_note THEN' IN v_src) = 0
     OR position('IF v_from_delivery_note THEN' IN v_src) > position('FROM public.products' IN v_src)
     OR position('v_item.iva_rate_snapshot' IN v_src) = 0
     OR position('''issued'', ''converted''' IN v_src) = 0
     OR position('''issued'', ''converted''' IN v_src) < position('sale_operation_id   = v_new_op_id' IN v_src) THEN
    v_bad := v_bad || '_c29_confirm_order_core sin la rama v_from_delivery_note o sin dejar el remito converted tras confirmar la orden'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_delete_sale_operation(uuid,uuid,text)'::regprocedure;
  IF position('delivery_note_branch_inactive' IN v_src) = 0
     OR position('delivery_note_branch_inactive' IN v_src) > position('public._fiscal_void_pending_for_sale_edit(' IN v_src)
     OR position('IF v_source_dn IS NULL THEN' IN v_src) = 0
     OR position('IF v_source_dn IS NULL THEN' IN v_src) > position('PERFORM public.rpc_reverse_stock_movement' IN v_src)
     OR position('''converted'', ''issued''' IN v_src) = 0 THEN
    v_bad := v_bad || 'rpc_delete_sale_operation sin el guard de sucursal, el salto de la reversa o la reapertura'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)'::regprocedure;
  IF position('delivery_note_sale_locked' IN v_src) = 0
     OR position('delivery_note_sale_locked' IN v_src) > position('public._fiscal_void_pending_for_sale_edit(' IN v_src) THEN
    v_bad := v_bad || 'rpc_atomic_update_sale_operation sin el P0423 delivery_note_sale_locked antes del bloque fiscal'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)'::regprocedure;
  IF NOT (position('FOR UPDATE' IN v_src) > 0
          AND position('FOR UPDATE' IN v_src) < position('FROM public.operation_idempotency' IN v_src)
          AND position('FROM public.operation_idempotency' IN v_src) < position('FROM public.products p' IN v_src)
          AND position('FROM public.products p' IN v_src) < position('INSERT INTO public.sales_orders' IN v_src)
          AND position('INSERT INTO public.sales_orders' IN v_src) < position('public._c29_confirm_order_core(' IN v_src))
     OR position('FOR KEY SHARE;' IN v_src) = 0
     OR v_src ~ 'FROM public\.products p[^;]*FOR UPDATE'
     OR position('''issued'', ''converted''' IN v_src) > 0 THEN
    v_bad := v_bad || 'rpc_convert_delivery_note_to_sale fuera del orden remito -> idempotencia -> productos por id (FOR KEY SHARE, nunca FOR UPDATE) -> orden -> núcleo, o hace él la transición que es del núcleo'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._delivery_note_payload(uuid)'::regprocedure;
  IF position('so.source_delivery_note_id = dn.id' IN v_src) = 0 THEN
    v_bad := v_bad || '_delivery_note_payload no deriva la venta generada'::text;
  END IF;

  -- _branch_assert_empty: el texto nuevo, el token y el errcode, y el COMMENT vivo.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._branch_assert_empty(uuid)'::regprocedure;
  IF position('convertilos en venta o anulalos (un administrador o el dueño)' IN v_src) = 0
     OR position('branch_has_pending_delivery_notes' IN v_src) = 0
     OR position('public._branch_pending_delivery_notes(p_branch_id)' IN v_src) = 0
     OR position('branch_has_stock' IN v_src) = 0
     OR position('branch_has_open_cash_session' IN v_src) = 0
     OR position('branch_has_pending_transfers' IN v_src) = 0
     OR obj_description('public._branch_assert_empty(uuid)'::regprocedure, 'pg_proc') NOT LIKE 'sucursal-guard-vaciado-auditoria%' THEN
    v_bad := v_bad || '_branch_assert_empty sin el texto "convertilos en venta o anulalos" o sin sus cuatro condiciones'::text;
  END IF;

  -- Los COMMENT vivos de las tres reescritas siguen siendo los mismos.
  IF md5(COALESCE(obj_description('public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)'::regprocedure, 'pg_proc'), '')) <> 'dac0f029b9ce6f0dad97549f1f6de9d3'
     OR md5(COALESCE(obj_description('public.rpc_delete_sale_operation(uuid,uuid,text)'::regprocedure, 'pg_proc'), '')) <> 'b3bafc6d5c0a20bbd42b006af8769513'
     OR md5(COALESCE(obj_description('public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)'::regprocedure, 'pg_proc'), '')) <> '1675d3824b79fccd3efba3b256adf89e' THEN
    v_bad := v_bad || 'el COMMENT vivo de una función reescrita cambió'::text;
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'remitos-venta tanda B (introspección) FAILED: %', array_to_string(v_bad, ' | ');
  END IF;
  RAISE NOTICE 'remitos-venta tanda B (introspección): OK — columna/FK/índice, catálogo (issued->converted, converted->issued), una definición y ACL previa de las tres reescritas, rama del núcleo, guard y salto del borrado, P0423 de la edición, orden de la conversión, payload y COMMENT vivos.';
END $$;
