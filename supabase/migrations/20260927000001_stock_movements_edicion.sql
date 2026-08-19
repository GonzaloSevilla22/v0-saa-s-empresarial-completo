-- =============================================================================
-- 20260927000001_stock_movements_edicion.sql
--
-- stock-movements-edicion — Grupos 1-4 autónomos (governance MEDIUM, sign-off
-- PO 2026-08-19 solo para los grupos 5/backfill y 6/huérfanos, que van en
-- scripts/sql/ aparte y NO corren en esta migración).
--
-- ── El hallazgo (proposal.md / design.md, OQ-B de edicion-operaciones-lineas) ─
-- rpc_atomic_update_sale_operation / rpc_atomic_update_purchase_operation
-- mueven branch_stock (REVERSE y APPLY, vía c21_apply_branch_stock_delta) pero
-- NUNCA escriben una fila en stock_movements. El cableado existió
-- (20260527000002_wire_movements_to_rpcs.sql, 117 filas en prod entre
-- 2026-05-27 y 2026-06-05) y se perdió en una redefinición posterior.
--
-- Consecuencia medida en prod (gxdhpxvdjjkmxhdkkwyb, 2026-08-19, solo SELECTs):
-- SalesRepository.delete_by_id / PurchaseRepository.delete_by_id derivan la
-- reversa de stock LEYENDO stock_movements (reference_id = <sale|purchase>.id,
-- reference_type = 'sale'|'purchase') — es el contrato de inventory-single-
-- ledger, pensado para que la reposición sea independiente de la ruta de
-- creación. Como la edición hace DELETE del header e INSERT con id NUEVO sin
-- emitir movimiento, la operación editada queda sin movimiento de referencia:
-- al eliminarla, rpc_reverse_stock_movement recorre 0 filas, el DELETE corre
-- igual, y el stock NUNCA vuelve — en silencio, sin error. 204 operaciones
-- vivas (112 ventas + 92 compras) están hoy en ese estado.
--
-- ── Decisión: espejo (REVERSE + APPLY), no neto (design.md §D1/§D2) ─────────
-- Cada línea editada deja DOS filas en stock_movements, no una de diferencia:
--   · REVERSE → type='sale_return'/'purchase_return', reference_id = id
--     VIEJO, reference_type='sale_update'/'purchase_update'.
--   · APPLY   → type='sale'/'purchase', reference_id = id NUEVO,
--     reference_type='sale'/'purchase' — INDISTINGUIBLE del movimiento que
--     emite la creación. Es la condición literal que rpc_reverse_stock_
--     movement filtra: sin esto, la operación editada seguiría siendo
--     delete-insegura (de hecho 13/112 ventas de mayo ya arrastran ese bug
--     con reference_type='sale_update' en AMBAS patas — el diseño de 2026-05).
-- Un neto rompería la eliminación (ver design.md §D1, ejemplo del -2 sobre una
-- venta de 3 unidades). Es también la semántica que usó el cableado original
-- (117 filas en prod lo demuestran) y la que el panel de /stock ya sabe
-- renderizar (MOVEMENT_META ya tiene sale/purchase/sale_return/purchase_return).
--
-- ── Helper canónico op_stock_movement (design.md §D3) ────────────────────────
-- Reemplaza los 4 PERFORM c21_apply_branch_stock_delta(...) sueltos de las dos
-- RPCs de edición por PERFORM op_stock_movement(...), que hace lo mismo (la
-- aritmética NO cambia, incluido el lazy-create de sucursal) y además calcula
-- quantity_before/quantity_after (una sola lectura de branch_stock DESPUÉS de
-- aplicar el delta: after := quantity actual, before := after - delta —
-- exacto, inmune al lazy-create) y escribe el movimiento.
--
-- Por qué NO se reusa rpc_apply_product_stock_delta (que sí devuelve before/
-- after): valida stock POR SUCURSAL y lanza P0409 si no alcanza. Las RPCs de
-- edición gatean con Σ branch_stock GLOBAL (OQ-D, deliberadamente fuera de
-- alcance) — sustituirlo haría fallar ediciones que hoy pasan, un cambio de
-- comportamiento encubierto.
--
-- Por qué NO se reusa rpc_reverse_stock_movement para la pata REVERSE: esa
-- función DERIVA la reversa de los movimientos existentes; para las 112
-- operaciones que hoy no tienen ninguno devolvería 0 filas y dejaría de
-- reponer stock en la edición misma — una regresión inmediata sobre datos
-- reales (design.md §D4). STEP 1 sigue alimentado por sales.quantity/
-- purchases.quantity (el header es la verdad del delta); el ledger la
-- registra, no la define.
--
-- ── unit_cost_snapshot (design.md §D5) ───────────────────────────────────────
-- La pata APPLY reusa el mismo v_line_snap que ya resuelve op_line_snapshot
-- (PR #415) para sale_items/purchase_items — CERO lógica de acarreo
-- duplicada. Se movió el cálculo de v_line_snap FUERA del `IF v_flag_on` en
-- la RPC de venta (en la de compra ya era incondicional, D5 del PR #415)
-- porque el movimiento se emite SIEMPRE, gobernado o no por el kill-switch de
-- líneas — el kill-switch apaga sale_items/purchase_items, no el ledger.
-- La pata REVERSE copia el unit_cost_snapshot del movimiento ORIGINAL
-- (buscado en stock_movements por reference_id=id viejo, reference_type=
-- 'sale'|'purchase') si existe, si no NULL — no se inventa costo histórico
-- para las operaciones que todavía no tienen movimiento de referencia (las
-- 204 delete-inseguras, hasta que corra el backfill gateado del grupo 5).
--
-- ── Qué NO cambia ─────────────────────────────────────────────────────────
-- Firmas exactas de las dos RPCs (sin DROP, sin gotcha 42725, ACLs re-
-- emitidas), guards, códigos de error, gate de stock (Σ global, OQ-D), orden
-- REVERSE→DELETE→APPLY, el acarreo de snapshots de línea del PR #415 (base
-- vigente: 20260926000001, verificado MAX(version) en prod = 20260926000001
-- antes de crear este archivo). Sin cambio en el CHECK de reference_type:
-- sale_update/purchase_update/sale_reversal/purchase_reversal ya están
-- admitidos desde 20260527000001 / 20260828000001 (verificado en prod).
--
-- ── Backfill y huérfanos — GATEADOS, NO en esta migración ────────────────────
-- Las 204 operaciones vivas ya delete-inseguras y los 139 movimientos
-- huérfanos históricos NO se tocan acá (design.md §D6/§D7) — requieren
-- sign-off del PO y viven en scripts/sql/ (solo INSERT, nunca tocan
-- branch_stock, que ya está correcto).
--
-- ── Rollback ────────────────────────────────────────────────────────────────
-- Re-aplicar la definición de 20260926000001 para las dos RPCs (el helper
-- op_stock_movement queda huérfano e inocuo, SECURITY DEFINER + REVOKE ALL,
-- sin superficie de ataque). No hay estado nuevo que revertir: el ledger es
-- append-only y los movimientos ya emitidos son correctos aunque se revierta
-- el código.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Helper único: aplica el delta a branch_stock (aritmética sin cambios,
--    vía c21_apply_branch_stock_delta) Y escribe el movimiento espejo en la
--    misma llamada (design §D3). SECURITY DEFINER porque hace I/O (INSERT/
--    UPDATE) — a diferencia de op_line_snapshot (puro, SECURITY INVOKER).
--    REVOKE ALL: solo invocable desde dentro de las RPCs SECURITY DEFINER
--    dueñas (rpc_atomic_update_sale_operation / rpc_atomic_update_purchase_
--    operation), que ejecutan con el owner elevado — no despierta
--    test_function_acl_gate.sql (esa allowlist es sobre superficie
--    anon/authenticated).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.op_stock_movement(
  p_account_id        uuid,
  p_uid                uuid,
  p_product_id         uuid,
  p_product_name       text,
  p_branch_id          uuid,
  p_delta              numeric,
  p_type               text,
  p_reference_id       uuid,
  p_reference_type     text,
  p_operation_group_id uuid,
  p_unit_cost          numeric,
  p_reason             text,
  p_metadata           jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_branch  uuid;
  v_after   numeric;
  v_before  numeric;
  v_id      uuid;
BEGIN
  -- Aritmética sin cambios respecto de los PERFORM c21_apply_branch_stock_delta
  -- sueltos que reemplaza: incluye el lazy-create de sucursal para cuentas sin
  -- branches.
  PERFORM public.c21_apply_branch_stock_delta(p_account_id, p_product_id, p_branch_id, p_delta);

  -- Resolver DESPUÉS del PERFORM: si c21 acaba de lazy-crear la sucursal
  -- default, esta lectura ya la encuentra.
  v_branch := COALESCE(p_branch_id, public.c26_default_branch(p_account_id));

  SELECT quantity INTO v_after
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_branch;
  v_after  := COALESCE(v_after, 0);
  v_before := v_after - p_delta;

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_id, reference_type, performed_by,
    operation_group_id, branch_id, unit_cost_snapshot,
    reason, metadata
  ) VALUES (
    p_uid, p_account_id, p_product_id, p_product_name, p_type,
    p_delta, v_before, v_after,
    p_reference_id, p_reference_type, p_uid,
    p_operation_group_id, v_branch, p_unit_cost,
    p_reason, COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.op_stock_movement(
  uuid, uuid, uuid, text, uuid, numeric, text, uuid, text, uuid, numeric, text, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.op_stock_movement(
  uuid, uuid, uuid, text, uuid, numeric, text, uuid, text, uuid, numeric, text, jsonb
) FROM anon, authenticated;

COMMENT ON FUNCTION public.op_stock_movement(
  uuid, uuid, uuid, text, uuid, numeric, text, uuid, text, uuid, numeric, text, jsonb
) IS
  'stock-movements-edicion (D3): punto único de escritura del ledger para las '
  'RPCs de edición de operaciones — aplica el delta a branch_stock vía '
  'c21_apply_branch_stock_delta (aritmética sin cambios) y escribe el '
  'movimiento espejo (before/after derivados de una sola lectura posterior). '
  'SECURITY DEFINER + REVOKE ALL: solo invocable desde dentro de las RPCs '
  'dueñas.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2. rpc_atomic_update_sale_operation — misma firma exacta. Cuerpo vigente
--    (20260926000001) preservado, con el diff acotado a: (a) STEP 1 agrega
--    id/operation_id al SELECT y emite el movimiento REVERSE por cada línea
--    con producto; (b) STEP 3 mueve el cálculo de v_line_snap fuera del `IF
--    v_flag_on` (el movimiento se emite siempre) y reemplaza el PERFORM
--    c21_apply_branch_stock_delta final por PERFORM op_stock_movement con la
--    pata APPLY.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb)
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

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — id vieja
  -- es el reference_id de la pata REVERSE, operation_id agrupa el movimiento
  -- bajo la operación a la que pertenecía la fila que se está reemplazando.
  FOR v_old_sale IN
    SELECT id, product_id, quantity, branch_id, operation_id
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      -- Nombre actual del producto para el movimiento (congelar el nombre no
      -- es el contrato de este movimiento — el name_snapshot vive en la
      -- línea, no acá — se usa el mismo patrón que la creación: products.name
      -- vigente al momento de la operación).
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_sale.product_id;

      -- design §D5: la pata REVERSE copia el unit_cost_snapshot del
      -- movimiento ORIGINAL (el que dejó la creación o la edición anterior)
      -- si existe; si la operación todavía no tiene movimiento de referencia
      -- (una de las 204 delete-inseguras, hasta el backfill gateado del
      -- grupo 5), queda NULL — no se inventa costo histórico.
      SELECT unit_cost_snapshot INTO v_reverse_unit_cost
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
        v_old_sale.branch_id, v_old_sale.quantity, 'sale_return',
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

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

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

      -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      IF v_stock_sum < v_item.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
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
        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, NULL, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default).
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='sale',
      -- reference_id=id NUEVO, reference_type='sale' (indistinguible de la
      -- creación — el contrato del que depende la reversa al eliminar).
      -- unit_cost_snapshot reusa v_line_snap, la misma decisión de acarreo
      -- que la línea (sin re-valuar al costo actual).
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        NULL, -v_item.quantity, 'sale', v_new_sale_id, 'sale',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb) IS
  'edicion-operaciones-lineas: REVERSE → DELETE → APPLY preservado (D1). '
  'Acarrea/re-congela sale_items keyed por product_id (D2, helper '
  'op_line_snapshot D4), gobernado por el flag sale_items_rpc_v2 (D3, mismo '
  'interruptor que la creación). stock-movements-edicion: cada pata REVERSE/'
  'APPLY deja su movimiento espejo en stock_movements vía op_stock_movement '
  '— la pata APPLY es indistinguible del movimiento de creación '
  '(reference_type=''sale''), lo que restaura la reversa de stock al eliminar '
  'una operación editada. SECURITY DEFINER.';

-- ─────────────────────────────────────────────────────────────────────────
-- 3. rpc_atomic_update_purchase_operation — mismo diff que la venta, signos
--    invertidos. v_line_snap ya se calculaba incondicionalmente (D5 del PR
--    #415, header siempre poblado), así que solo cambia el PERFORM final.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_old_purchase    RECORD;
  v_item            RECORD;
  v_product         RECORD;
  v_new_op_id       uuid;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_flag_on         boolean;
  v_old_snapshots   jsonb;
  v_prev_snap       jsonb;
  v_line_snap       jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
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

  IF array_length(p_purchase_ids, 1) IS NULL OR array_length(p_purchase_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No purchase IDs provided' USING ERRCODE = 'P0400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.purchases
    WHERE id = ANY(p_purchase_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: purchase belongs to another user' USING ERRCODE = 'P0403';
  END IF;

  IF (SELECT COUNT(*) FROM public.purchases WHERE id = ANY(p_purchase_ids))
      != array_length(p_purchase_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- edicion-operaciones-lineas (D3): mismo flag_key y mismo patrón que venta.
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  -- edicion-operaciones-lineas (D2/D5): acarreo de snapshot keyed por
  -- product_id. Para compra el snapshot puede vivir en purchase_items, en el
  -- header purchases, o en ambos — se acarrea desde purchase_items cuando
  -- hay fila y, si no, cae al header (COALESCE(pi.*, p.*)).
  SELECT COALESCE(jsonb_object_agg(t.product_id::text, t.snap), '{}'::jsonb)
  INTO   v_old_snapshots
  FROM (
    SELECT DISTINCT ON (p.product_id)
           p.product_id,
           jsonb_build_object(
             'name_snapshot',       COALESCE(pi.name_snapshot, p.name_snapshot),
             'sku_snapshot',        COALESCE(pi.sku_snapshot, p.sku_snapshot),
             'unit_cost_snapshot',  COALESCE(pi.unit_cost_snapshot, p.unit_cost_snapshot),
             'iva_rate_snapshot',   COALESCE(pi.iva_rate_snapshot, p.iva_rate_snapshot),
             'snapshot_backfilled', COALESCE(pi.snapshot_backfilled, p.snapshot_backfilled, false)
           ) AS snap
    FROM   public.purchases p
    LEFT JOIN public.purchase_items pi
           ON pi.purchase_id = p.id AND pi.product_id = p.product_id
    WHERE  p.id = ANY(p_purchase_ids)
      AND  p.product_id IS NOT NULL
      AND  (COALESCE(pi.unit_cost_snapshot, p.unit_cost_snapshot) IS NOT NULL
            OR COALESCE(pi.name_snapshot, p.name_snapshot) IS NOT NULL)
    ORDER BY p.product_id, p.id
  ) t;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — espejo de
  -- la venta, signos invertidos.
  FOR v_old_purchase IN
    SELECT id, product_id, quantity, branch_id, operation_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_purchase.product_id;

      SELECT unit_cost_snapshot INTO v_reverse_unit_cost
      FROM   public.stock_movements
      WHERE  reference_id = v_old_purchase.id AND reference_type = 'purchase'
      ORDER  BY created_at DESC
      LIMIT  1;

      -- C-21 checkpoint #2: revertir de la branch original de la compra (o default).
      -- stock-movements-edicion (D2/D3): pata REVERSE — type='purchase_return',
      -- reference_id=id VIEJO, reference_type='purchase_update', delta
      -- NEGATIVO (revierte la entrada de stock que aplicó la compra original).
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_purchase.product_id, v_old_product_name,
        v_old_purchase.branch_id, -v_old_purchase.quantity, 'purchase_return',
        v_old_purchase.id, 'purchase_update', v_old_purchase.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock).
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
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- edicion-operaciones-lineas (D2/D4/D5): misma decisión de snapshot que
      -- la venta, aplicada AL HEADER siempre (D5 — el write path real).
      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id,
         name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_line_snap->>'name_snapshot',
         v_line_snap->>'sku_snapshot',
         (v_line_snap->>'unit_cost_snapshot')::numeric,
         (v_line_snap->>'iva_rate_snapshot')::numeric)
      RETURNING id INTO v_new_purchase_id;

      -- edicion-operaciones-lineas (D3): purchase_items condicionado por el
      -- mismo flag que la venta y que la creación de compra.
      IF v_flag_on THEN
        INSERT INTO public.purchase_items (
          purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_purchase_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, NULL, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default).
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='purchase',
      -- reference_id=id NUEVO, reference_type='purchase' (indistinguible de
      -- la creación). unit_cost_snapshot reusa v_line_snap.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        NULL, v_item.quantity, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb) IS
  'edicion-operaciones-lineas: REVERSE → DELETE → APPLY preservado (D1). '
  'Acarrea/re-congela purchase_items Y los *_snapshot del header purchases '
  '(D2/D5, helper op_line_snapshot D4), header incondicional y línea '
  'gobernada por el flag sale_items_rpc_v2 (D3). stock-movements-edicion: '
  'cada pata REVERSE/APPLY deja su movimiento espejo en stock_movements vía '
  'op_stock_movement, signos invertidos respecto de la venta. SECURITY '
  'DEFINER.';
