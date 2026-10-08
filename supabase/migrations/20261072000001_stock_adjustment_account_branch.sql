-- =============================================================================
-- stock-adjustment-historial-invisible — hotfix (2026-10-08).
-- Governance MEDIA (escribe el ledger de stock; no mueve dinero ni cambia el
-- saldo de nadie). Alcance acotado y aprobado por el PO: ESTO y nada más.
--
-- EL BUG (verificado en prod, sólo lectura, 2026-10-08)
-- -----------------------------------------------------
-- public.rpc_stock_adjustment —el ajuste manual del modal de /stock y de su
-- importador CSV, llamada por el navegador vía PostgREST— inserta en
-- public.stock_movements SIN account_id ni branch_id, aunque ya tiene
-- calculados v_account_id y v_target_branch (los usa para mover branch_stock).
-- La policy de lectura stock_movements_account_select exige
--   account_id IN (SELECT current_account_ids())
-- así que esas filas son INVISIBLES en el historial de movimientos
-- (frontend/components/stock/stock-movements-panel.tsx lee la tabla por
-- supabase-js sin filtros propios). El saldo SÍ se movió en cada caso: sólo
-- falta el sello. En prod hay 29 filas así (3 cuentas, de 2026-06-13 a
-- 2026-10-08); todas son resolubles: la cuenta sale de products.account_id y
-- las 3 cuentas tienen una sola sucursal activa.
--
-- LA CAUSA. La última definición de la RPC es la de
-- 20260625000001_c26_branch_as_root.sql (c26 agregó account_id/branch_id al
-- ledger y tocó los demás escritores, pero el INSERT de esta RPC quedó sin las
-- columnas). La definición viva de prod es idéntica a ese archivo.
--
-- QUÉ HACE ESTA MIGRACIÓN
-- -----------------------
-- 1. Reescribe rpc_stock_adjustment con CREATE OR REPLACE FUNCTION y la MISMA
--    firma de 7 argumentos: así conserva la ACL viva
--    {postgres, authenticated, service_role} y no hay overload. NUNCA
--    DROP FUNCTION (resetea las ACLs y deja la RPC sin EXECUTE para
--    authenticated: rompería el modal de /stock y su importador; gotcha
--    registrado del proyecto, 42725/ACL). No hay COMMENT vivo que preservar.
--    El cuerpo parte del pg_get_functiondef VIVO de prod. El ÚNICO cambio de
--    comportamiento: el INSERT INTO public.stock_movements suma las columnas
--    account_id y branch_id con v_account_id y v_target_branch (los mismos
--    valores con los que ya se mueve branch_stock). Guards, tipos y mensajes:
--    intactos.
--
-- 2. Backfill de las filas históricas con la forma del bug. La cuenta sale de
--    products.account_id; la sucursal, de c26_default_branch(cuenta) (la
--    default operativa: la más antigua activa; NULL si la cuenta no tiene
--    sucursal, y el COALESCE lo tolera dejando branch_id en NULL). Una fila
--    cuyo producto ya no existe (product_id NULL por ON DELETE SET NULL) o
--    cuyo producto no tiene cuenta no es resoluble y queda como está. Es
--    idempotente por construcción: el WHERE account_id IS NULL hace que
--    reaplicada la migración afecte 0 filas. stock_movements no tiene
--    triggers; el UPDATE corre como el dueño de la migración (sin RLS), igual
--    que el resto de los backfills del proyecto.
--
-- FUERA DE ALCANCE (declarado)
-- ----------------------------
-- El guard legacy products.user_id = auth.uid() de la RPC y la ausencia de rol
-- y de motivo obligatorio en el ajuste manual NO se tocan: son del candidato
-- `stock-ledger-solo-rpc`, pendiente de sign-off del PO. Tampoco el borde de
-- una cuenta SIN ninguna sucursal: el helper c21_apply_branch_stock_delta crea
-- "Casa Central" al vuelo, pero v_target_branch se calculó antes y el
-- movimiento quedaría con branch_id NULL (la visibilidad, que es el bug, la da
-- account_id y queda cubierta).
--
-- Sin superficie frontend (declarado): la firma no cambia, el modal y el
-- importador siguen llamando igual; el historial simplemente deja de perder
-- las filas. frontend/lib/database.types.ts no cambia.
--
-- Gate: supabase/tests/test_stock_adjustment_account_branch.sql (ejecuta la RPC
-- como authenticated por tres caminos del cálculo, verifica la visibilidad bajo
-- RLS con control negativo y la ACL/overload).
-- =============================================================================


-- ── 1. rpc_stock_adjustment: el INSERT al ledger sella cuenta y sucursal ────
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
    reference_id, reference_type,
    account_id, branch_id
    -- operation_group_id intentionally NULL: single-movement operation
  ) VALUES (
    v_uid, p_product_id, v_product.name, p_type,
    v_delta, v_qty_before, v_qty_after,
    p_reason, p_notes, v_uid,
    p_reference_id,
    CASE WHEN p_reference_id IS NOT NULL THEN 'adjustment' ELSE NULL END,
    v_account_id, v_target_branch
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


-- ── 2. Backfill idempotente de las filas históricas sin sello ───────────────
-- Reaplicada, afecta 0 filas (WHERE sm.account_id IS NULL).
UPDATE public.stock_movements sm
SET    account_id = p.account_id,
       branch_id  = COALESCE(sm.branch_id, public.c26_default_branch(p.account_id))
FROM   public.products p
WHERE  sm.account_id IS NULL
  AND  p.id = sm.product_id
  AND  p.account_id IS NOT NULL;
