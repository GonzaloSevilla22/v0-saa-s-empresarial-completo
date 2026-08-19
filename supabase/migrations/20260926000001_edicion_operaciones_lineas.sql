-- =============================================================================
-- 20260926000001_edicion_operaciones_lineas.sql
--
-- edicion-operaciones-lineas — sign-off PO 2026-08-19 (incluye Grupo 6 backfill,
-- ejecutado aparte como script, ver scripts/sql/backfill_operation_lines.sql).
--
-- ── El hallazgo (proposal.md / design.md) ──────────────────────────────────
-- rpc_atomic_update_sale_operation y rpc_atomic_update_purchase_operation
-- implementan la edición como REVERSE → DELETE FROM sales|purchases → INSERT
-- de filas nuevas. sale_items.sale_id y purchase_items.purchase_id tienen FK
-- ON DELETE CASCADE, así que el DELETE de STEP 2 borra las líneas existentes
-- y el INSERT de STEP 3 nunca las recrea: toda edición deja la operación SIN
-- línea, la tuviera o no antes. Evidencia en prod (2026-08-18): 119/663 ventas
-- y 190/427 compras sin línea; 62 stock_movements huérfanos; 6/120
-- sales_orders con sale_operation_id colgando (ver proposal.md).
--
-- ── Desviación documentada respecto de design.md ───────────────────────────
-- design.md ancla la definición vigente de ambas RPCs en
-- supabase/migrations/20260623000001_c21_checkpoint2_drop_products_stock.sql.
-- Verificado FALSO contra prod (pg_get_functiondef, 2026-08-19) y contra el
-- stack local reseteado a MAX(version)=20260925000001: el cuerpo vigente usa
-- ERRCODE de 5 caracteres ('P0403', 'P0400', 'P0404', 'P0409', 'P0422'), no
-- los de 4 caracteres ('P403', 'P400', ...) que trae el archivo
-- 20260623000001. La migración 20260624000001_fix_invalid_errcodes_5char.sql
-- reescribió ambas RPCs con CREATE OR REPLACE después — es esa versión (con
-- los códigos de 5 caracteres) la que corre hoy en prod y la base real de
-- este change. El cuerpo es idéntico byte a byte salvo los ERRCODE.
--
-- ── Política de snapshot en edición (design.md §D2) ────────────────────────
-- Antes del DELETE, se captura un mapa keyed por product_id con los
-- snapshots de las líneas viejas (DISTINCT ON (product_id) ORDER BY
-- product_id, id — determinístico ante colisión: dos filas de header con el
-- mismo producto, la forma legacy 1-operación:N-filas). Al insertar cada
-- línea nueva:
--   · product_id presente en el mapa → HEREDA name/sku/unit_cost/iva_rate y
--     snapshot_backfilled de la línea vieja; quantity/price/subtotal se
--     recalculan desde el payload. Corregir una cantidad o un precio no
--     re-precifica el margen histórico con el costo de hoy.
--   · product_id ausente (producto cambiado, ítem agregado, u operación que
--     nunca tuvo línea) → snapshot FRESCO de products, leído en el mismo
--     SELECT ... FOR UPDATE que la RPC ya hacía (sin lecturas nuevas).
--   · product_id IS NULL (línea de servicio) → sin línea, igual que la
--     creación.
-- La decisión de snapshot vive en una única función (D4, evita repetirla 4
-- veces): public.op_line_snapshot(p_prev, p_name, p_sku, p_cost).
--
-- ── Compras — línea Y header (design.md §D5) ───────────────────────────────
-- rpc_create_purchase_operation congela name_snapshot/sku_snapshot/
-- unit_cost_snapshot/iva_rate_snapshot en el header purchases (es el write
-- path real de compra) además de purchase_items. La edición no escribía
-- ninguno de los dos; este change repara ambos con la misma regla de D2. El
-- mapa de "snapshot viejo" de la compra se arma desde purchase_items cuando
-- existe fila, y si no, cae al header (COALESCE(pi.*, p.*)): en prod hoy hay
-- 179/186 compras sin purchase_items pero CON snapshot ya congelado en el
-- header — editarlas no debe re-precificarlas a costo actual solo porque la
-- línea nunca se escribió. Esto va un paso más allá de la lectura literal de
-- D2 (que habla solo de "líneas") pero cumple al pie de la letra el
-- requirement ADDED del spec document-snapshots ("Una edición NO SHALL
-- re-precificar con el costo actual una línea cuyo producto no cambió") y el
-- Scenario "la compra preserva también el snapshot de su header".
-- El INSERT del header lleva los *_snapshot SIEMPRE (igual que la creación);
-- el INSERT de purchase_items queda condicionado al flag (D3), igual que en
-- rpc_create_purchase_operation.
--
-- ── Un solo interruptor (design.md §D3) ────────────────────────────────────
-- Mismo flag_key 'sale_items_rpc_v2' que la creación, mismo patrón
-- COALESCE-después-del-SELECT (ausencia de fila = v2, ver
-- 20260924000001_activate_sale_items_rpc_v2.sql). Editar y crear conmutan
-- juntos: no puede quedar la creación escribiendo línea y la edición no.
--
-- ── Qué NO cambia ───────────────────────────────────────────────────────────
-- Firmas exactas (sin cambio), guards, códigos de error, gate de stock
-- (Σ branch_stock — no el gate per-branch de C-26: estas dos RPCs de edición
-- nunca migraron a ese gate, y este change no las migra tampoco: fuera de
-- alcance, ver OQ-D), tenancy, orden REVERSE→DELETE→APPLY. No se toca
-- branch_id/canal/unit_id/cost_center_id (OQ-D), ni se emite stock_movements
-- en la edición (OQ-B, no lo hacía antes tampoco), ni se bloquea editar una
-- operación ya facturada (OQ-C). quantity sigue siendo `integer` en el
-- jsonb_to_recordset de ambas RPCs (OQ-G, preexistente — no se toca acá
-- porque cambiaría el resultado del header, no solo la línea).
--
-- ── Rollback ────────────────────────────────────────────────────────────────
-- UPDATE public.account_feature_flags SET enabled = false
--   WHERE flag_key = 'sale_items_rpc_v2';
-- (apaga línea en creación Y edición para toda cuenta, sin redeploy) o
-- re-aplicar la definición previa de las dos RPCs (20260624000001).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Helper único: qué snapshot usar (D4). IMMUTABLE, SECURITY INVOKER, sin
--    I/O — recibe del maestro lo que la RPC ya leyó en su SELECT ... FOR
--    UPDATE. Se invoca únicamente desde dentro de las RPCs SECURITY DEFINER
--    (dueñas del EXECUTE); REVOKE ALL no agrega superficie ni despierta
--    test_function_acl_gate.sql (esa allowlist es sobre SECURITY DEFINER).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.op_line_snapshot(
  p_prev jsonb,
  p_name text,
  p_sku  text,
  p_cost numeric
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN p_prev IS NOT NULL THEN jsonb_build_object(
      'name_snapshot',       p_prev->>'name_snapshot',
      'sku_snapshot',        p_prev->>'sku_snapshot',
      'unit_cost_snapshot',  (p_prev->>'unit_cost_snapshot')::numeric,
      'iva_rate_snapshot',   (p_prev->>'iva_rate_snapshot')::numeric,
      'snapshot_backfilled', COALESCE((p_prev->>'snapshot_backfilled')::boolean, false)
    )
    ELSE jsonb_build_object(
      'name_snapshot',       p_name,
      'sku_snapshot',        p_sku,
      'unit_cost_snapshot',  p_cost,
      'iva_rate_snapshot',   NULL::numeric,
      'snapshot_backfilled', false
    )
  END;
$$;

REVOKE ALL ON FUNCTION public.op_line_snapshot(jsonb, text, text, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.op_line_snapshot(jsonb, text, text, numeric) FROM anon, authenticated;

COMMENT ON FUNCTION public.op_line_snapshot(jsonb, text, text, numeric) IS
  'edicion-operaciones-lineas (D4): decisión única de snapshot acarreado vs '
  'fresco, reusada por las RPCs de creación/edición de venta y compra. '
  'p_prev = snapshot de la línea vieja para ese product_id (NULL si no había '
  'o si el producto cambió). SECURITY INVOKER + REVOKE ALL: solo invocable '
  'desde dentro de una RPC SECURITY DEFINER.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2. rpc_atomic_update_sale_operation — misma firma exacta. Cuerpo vigente
--    (20260624000001) preservado byte a byte salvo: (a) resolución del flag
--    sale_items_rpc_v2, (b) captura del mapa de snapshots viejos ANTES del
--    DELETE, (c) INSERT de sale_items condicionado por el flag, reusando el
--    SELECT ... FOR UPDATE de products ya existente (se le agregan
--    name/sku/cost a la lista de columnas leídas).
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
  FOR v_old_sale IN
    SELECT product_id, quantity, branch_id
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: devolver a la branch original de la venta (o default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_old_sale.product_id, v_old_sale.branch_id, v_old_sale.quantity);
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  -- sale_items.sale_id tiene FK ON DELETE CASCADE: este DELETE es lo que
  -- borraba la línea sin recrearla (el hallazgo de este change). El acarreo
  -- de arriba ya capturó lo necesario antes de perderlo.
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
      -- Gobernado por el mismo flag que la creación (D3).
      IF v_flag_on THEN
        v_prev_snap := v_old_snapshots -> v_item.product_id::text;
        v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

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

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, NULL, -v_item.quantity);

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
  'interruptor que la creación). SECURITY DEFINER.';

-- ─────────────────────────────────────────────────────────────────────────
-- 3. rpc_atomic_update_purchase_operation — misma firma exacta. Mismo patrón
--    que la venta, más el poblado incondicional de los *_snapshot del header
--    purchases (D5) — el write path real de compra.
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
  -- hay fila y, si no, cae al header (COALESCE(pi.*, p.*)): en prod hay
  -- compras sin purchase_items pero con snapshot ya congelado en el header
  -- (flag apagado al crearse, o anteriores a v3-snapshot-pattern) y editarlas
  -- no debe re-precificarlas a costo actual solo porque la línea nunca se
  -- escribió. El filtro final descarta las filas sin NINGÚN snapshot
  -- genuino (ni header ni línea) para que esos productos caigan al snapshot
  -- fresco, no a un objeto con campos NULL que op_line_snapshot leería como
  -- "acarreado".
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
  FOR v_old_purchase IN
    SELECT product_id, quantity, branch_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: revertir de la branch original de la compra (o default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_old_purchase.product_id, v_old_purchase.branch_id, -v_old_purchase.quantity);
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

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, NULL, v_item.quantity);

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
  'gobernada por el flag sale_items_rpc_v2 (D3). SECURITY DEFINER.';
