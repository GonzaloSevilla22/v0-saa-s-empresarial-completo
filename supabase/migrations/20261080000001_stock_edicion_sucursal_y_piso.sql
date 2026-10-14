-- =============================================================================
-- MIGRATION: 20261080000001_stock_edicion_sucursal_y_piso.sql
-- FIX AD-HOC: stock-edicion-sucursal-piso (2026-10-14) — governance MEDIA con un tramo
--         ALTO: reescribe cuatro funciones que mueven el ledger de stock (la edición de
--         ventas y de compras, la reversa del borrado y su aritmética de saldo). Pedido
--         directo del PO tras la auditoría del movimiento de stock del 2026-10-13
--         («corregí todo lo que encontraste»). Cambios mínimos a propósito: el change
--         `edicion-operaciones-con-dinero` va a reescribir estas mismas RPCs de edición.
--
-- PROBLEMAS (reproducidos en el stack local —smoke_stock.sql S7b/S7c/S7e y repro R5—):
--   R2  rpc_atomic_update_sale_operation validaba el stock con Σ branch_stock de TODAS las
--       sucursales y aplicaba el descuento en UNA (la efectiva de la venta). Con el total
--       alcanzando y la sucursal no, pasaba el gate y explotaba después con 23514
--       (branch_stock_quantity_non_negative), que el backend devolvía como un 422 genérico
--       («Los datos no cumplen las restricciones»). rpc_atomic_update_purchase_operation:
--       editar una compra cuya mercadería ya se vendió terminaba en el mismo 23514 (la pata
--       REVERSE resta del stock lo que la compra había sumado y la sucursal no alcanza).
--   R4  Borrar una compra ya vendida aplica el piso en cero, pero lo registraba DOS veces:
--       _stock_apply_delta insertaba un ajuste `floor_on_purchase_delete` y, además,
--       rpc_reverse_stock_movement insertaba el contramovimiento `purchase_return`, los dos
--       con el mismo delta, para un único cambio de saldo. Σ deltas del libro = el doble de
--       lo que el saldo se movió: el historial dejaba de reconciliar con branch_stock.
--   R5  Editar una venta cuya sucursal fue DESACTIVADA devolvía el stock a esa sucursal
--       (invisible: no se lista ni se vende) y volvía a descontar de ella; el borrado ya caía
--       a la principal operativa (stock-movimientos-sucursal-origen, D6), la edición no.
--       Reproducido: venta de 2 en B, B vaciada y desactivada, editar 2 → 1: B termina con 1
--       unidad que nadie ve y la principal no recupera nada.
--
-- QUÉ HACE (D1-D4):
--   D1  rpc_atomic_update_sale_operation: el gate de stock es POR SUCURSAL, sobre la misma
--       sucursal en la que se descuenta (v_final_branch_id), igual que el alta
--       (rpc_create_sale_operation_v2, C-26 OQ-A). Rechaza con el MISMO P0409 del alta:
--       `insufficient_branch_stock for product <id>` con sucursal explícita y
--       `Insufficient stock for product <id>` sin ella — los literales que el frontend ya
--       traduce (lib/operation-errors.ts STOCK_ERROR). La transacción entera se revierte,
--       incluida la pata REVERSE.
--   D2  rpc_atomic_update_purchase_operation: chequeo previo en la pata REVERSE. Si la sucursal
--       (la de la fila, o la principal si la fila no tenía) no tiene stock para restar lo que la
--       compra había sumado, rechaza con P0409 `purchase_edit_stock_consumed: de <producto> en
--       la sucursal quedan X y la edición necesita restar Y`. NO cambia qué ediciones prosperan:
--       las que fallaban con 23514 fallan con este mensaje (incluida la que sólo cambia el
--       precio y la que, en neto, dejaría el stock en positivo pero cuya reversa intermedia no
--       cabe: el orden REVERSE-antes-que-APPLY es el de siempre y reordenarlo es del change que
--       reescribe estas RPCs). El borrado de la compra, que aplica el piso, sigue siendo la salida.
--   D3  _stock_apply_delta deja de insertar el ajuste de piso. Con p_allow_negative = TRUE y el
--       faltante, aplica sólo lo disponible y lo informa en el retorno (`floored`, delta
--       efectivo). rpc_reverse_stock_movement deja la traza del piso en SU contramovimiento —
--       el único movimiento del cambio de saldo—: metadata `floored`, `requested_quantity_delta`
--       y `floor_reason`, y la nota «Reversa solicitada: X, aplicada: Y (stock ya vendido)».
--       Un cambio de saldo = un movimiento; Σ deltas = el movimiento real del saldo.
--   D4  rpc_atomic_update_sale_operation: una sucursal vigente DESACTIVADA (is_active = false) no
--       se preserva (cae en la principal operativa por el bloque de resolución que ya existía) y
--       la pata REVERSE de una fila cuya sucursal está desactivada devuelve el stock a la
--       principal operativa (sucursal nula = c26_default_branch dentro de op_stock_movement), con
--       `fallback_from_branch_id` y `fallback_reason = 'branch_inactive'` en la metadata del
--       movimiento: mismas claves y mismo criterio que rpc_reverse_stock_movement. Una sucursal
--       cerrada y activa sigue como hoy.
--
-- DECISIONES QUE CAMBIAN COMPORTAMIENTO VISIBLE (declaradas):
--   · Editar una venta con la sucursal sin stock suficiente (aunque otra sucursal lo tenga) da un
--     409 legible de stock insuficiente en vez de un 422 genérico.
--   · Editar una compra ya vendida da un 409 legible (`purchase_edit_stock_consumed`) en vez de un
--     422 genérico.
--   · Borrar una compra ya vendida deja UN movimiento (el contramovimiento, marcado `floored`) y ya
--     no el par ajuste + contramovimiento. Los ajustes `floor_on_purchase_delete` ya escritos
--     (ledger append-only) quedan como están: la auditoría de datos del PO decide si se compensan.
--   · Editar una venta de una sucursal desactivada la deja en la principal operativa (antes la
--     dejaba en la desactivada, con el stock devuelto allí).
--
-- QUÉ NO TOCA. El borrado de ventas y de compras (rpc_delete_*), el alta (rpc_create_*), las RPCs
-- públicas de ajuste, c21_apply_branch_stock_delta, op_stock_movement, c26_default_branch, las ACL, el
-- orden global de locks ni el resto de las reglas de edición (guards fiscales, de caja, de cuenta
-- corriente, tri-estado de contexto). Ningún dato se modifica.
--
-- CUERPOS DE PARTIDA (md5 de prosrc sin \r, verificados el 2026-10-14 contra producción
-- gxdhpxvdjjkmxhdkkwyb —327 migraciones, max(version)=20261078000001, sólo SELECT— y contra la base
-- local construida desde los archivos: IDÉNTICOS; los COMMENT también):
--   _stock_apply_delta                    b3f6edd5ea68b0904ff2b5e29bce9843  (20261074000001_stock_ledger_nucleo_ajuste_manual.sql)
--   rpc_reverse_stock_movement            ae1ec5de1a6faedf3246013b6dc7f2fd  (20261077000001_reversa_stock_sucursal_desactivada.sql)
--   rpc_atomic_update_sale_operation      52acb873d8c446c24abb19b79eb43c75  (20261075000001_ventas_sucursal_por_defecto.sql)
--   rpc_atomic_update_purchase_operation  2d4c92f6fd3dbfd52d2225edb0a82827  (20261076000001_compras_gastos_sucursal_por_defecto.sql)
-- Los helpers que invocan (md5 de pg_get_functiondef sin \r, idénticos a los locales, 2026-10-14):
-- op_stock_movement 70bb90494341b7a505d52624f592da49, c21_apply_branch_stock_delta
-- 8d98227d6d6556e3a2f3f545dae2b231, c26_default_branch 5fa1096b4c1481b36d6e04c8eaadbfdc.
--
-- Reescritura con CREATE OR REPLACE y la MISMA firma (sin DROP, sin overload, sin 42725): las ACL vivas
-- se conservan y se re-emiten idénticas (las dos de edición: authenticated + service_role; las dos
-- internas: sólo service_role). Los COMMENT conservan su texto y suman la regla de este fix. El diff de
-- cada cuerpo contra el vivo es EXACTAMENTE lo de D1-D4 más un comentario `-- stock-edicion-sucursal-piso (Dn):`
-- en cada punto tocado.
--
-- CADENA DE REAPLICACIÓN (KPI_Validation.yml): este PR RETIRA los bloques de reaplicación de
-- 20261075000001 (las tres funciones de venta), 20261076000001 (las tres de compra y gasto) y
-- 20261077000001 (la reversa), y conserva los de datos 20261075000002 y 20261077000002 (sus reglas, en cada
-- cabecera: «una migración posterior que redefina cualquiera de estas funciones tiene que retirar el bloque en
-- el mismo PR»: sus preflight abortarían contra los cuerpos de esta migración). Esta migración se reaplica AL
-- FINAL de la cadena y sus cuatro cuerpos son los que verifican los bloques (0) de
-- test_ventas_sucursal_por_defecto.sql, test_compras_gastos_sucursal_por_defecto.sql y
-- test_stock_movimientos_sucursal_origen.sql (md5 actualizados a los de acá).
--
-- ROLLBACK (no hay datos que deshacer): CREATE OR REPLACE de los cuatro cuerpos de partida y sus COMMENT. Los
-- movimientos ya escritos son ledger append-only.
--
-- Idempotente: preflight por md5 (acepta el cuerpo de partida o el que esta migración deja), CREATE OR REPLACE,
-- REVOKE/GRANT y COMMENT repetidos.
--
-- REGLA PARA EL PR SIGUIENTE: una migración posterior que redefina cualquiera de estas cuatro funciones (p. ej.
-- edicion-operaciones-con-dinero) tiene que RETIRAR el bloque de reaplicación de 20261080000001 en
-- KPI_Validation.yml en el mismo PR y apuntar los md5 de los tres bloques (0) de arriba al cuerpo que contenga la
-- lógica.
--
-- Gate: supabase/tests/test_stock_edicion_sucursal_piso.sql (ejecuta las RPCs como authenticated). Frontend:
-- lib/operation-errors.ts traduce `purchase_edit_stock_consumed`.
-- =============================================================================

-- ─── 0. Preflight: integridad de función ───────────────────────────────────────
-- Cada cuerpo se reescribe desde su cuerpo VIVO. Si el del stack que aplica esta migración no es ni el de partida
-- ni el que ella deja (una migración intermedia que nadie reconcilió), se ABORTA en vez de pisarlo en silencio —
-- regla de integridad de función (20261060000001, molde de 20261076000001).
DO $$
DECLARE
  v_expected jsonb := jsonb_build_object(
    '_stock_apply_delta',                   'b3f6edd5ea68b0904ff2b5e29bce9843',
    'rpc_reverse_stock_movement',           'ae1ec5de1a6faedf3246013b6dc7f2fd',
    'rpc_atomic_update_sale_operation',     '52acb873d8c446c24abb19b79eb43c75',
    'rpc_atomic_update_purchase_operation', '2d4c92f6fd3dbfd52d2225edb0a82827'
  );
  -- Cuerpo que ESTA migración deja (reaplicación). Medidos de pg_proc en el stack local después de aplicar este archivo.
  v_rewritten jsonb := jsonb_build_object(
    '_stock_apply_delta',                   'ef8444bdd04904990e13f1377cef7a19',
    'rpc_reverse_stock_movement',           '987fe085021d2207b5351f535d5dfada',
    'rpc_atomic_update_sale_operation',     '40c02ca228e5efd81e5d514f8e1a030c',
    'rpc_atomic_update_purchase_operation', 'eaa00301336564d1f8e12eb6cdb673f7'
  );
  v_fn  text;
  v_md5 text;
  v_bad text[] := '{}';
  v_n_partida      integer := 0;
  v_n_reaplicacion integer := 0;
BEGIN
  FOR v_fn IN SELECT jsonb_object_keys(v_expected) LOOP
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_md5 = (v_expected ->> v_fn) THEN
      v_n_partida := v_n_partida + 1;
    ELSIF v_md5 = (v_rewritten ->> v_fn) THEN
      v_n_reaplicacion := v_n_reaplicacion + 1;
      RAISE NOTICE 'stock-edicion-sucursal-piso: % ya es el cuerpo de esta migración (reaplicación)', v_fn;
    ELSE
      v_bad := v_bad || format('%s: esperado %s (partida) o %s (reaplicación), vivo %s',
        v_fn, v_expected ->> v_fn, v_rewritten ->> v_fn, COALESCE(v_md5, '(no existe)'));
    END IF;
  END LOOP;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'stock-edicion-sucursal-piso: el cuerpo vivo de partida difiere del verificado contra prod el 2026-10-14 — reconciliar antes de reescribir: %',
      array_to_string(v_bad, '; ');
  END IF;
  RAISE NOTICE 'stock-edicion-sucursal-piso: % cuerpos reescritos desde el cuerpo de partida verificado por md5, % ya reaplicados',
    v_n_partida, v_n_reaplicacion;
END $$;

-- ─── 1. _stock_apply_delta (D3, R4): el piso ya no escribe un ajuste aparte ──────────

CREATE OR REPLACE FUNCTION public._stock_apply_delta(p_account_id uuid, p_product_id uuid, p_delta numeric, p_branch_id uuid, p_allow_negative boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           uuid;
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

  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'p_delta must be non-zero' USING ERRCODE = 'P0400';
  END IF;

  -- Lock de la fila del producto = mutex por producto, FILTRADO POR CUENTA: un
  -- producto ajeno no se bloquea ni se encuentra (P0404, sin distinguir "no
  -- existe" de "es de otra cuenta").
  SELECT id, name INTO v_product
  FROM   public.products
  WHERE  id = p_product_id AND account_id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = p_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch destino resuelta (explícita o default operativa)
  v_target_branch := COALESCE(p_branch_id, public.c26_default_branch(p_account_id));

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_target_branch;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  v_applied := p_delta;

  IF p_delta < 0 AND v_branch_qty + p_delta < 0 THEN
    IF p_allow_negative THEN
      -- OQ-C: floor a 0 trazable — se aplica solo lo disponible (caso típico: reversa
      -- de compra ya vendida). stock-edicion-sucursal-piso (D3): ESTA función ya NO
      -- escribe un ajuste «floor_on_purchase_delete» por el piso. Lo escribía ADEMÁS
      -- del contramovimiento del llamador, con el mismo delta, así que un único cambio
      -- de saldo quedaba registrado dos veces y el libro dejaba de reconciliar con
      -- branch_stock (Σ deltas = el doble de lo que el saldo se movió). La traza del
      -- piso viaja en el retorno ('floored' + el delta efectivamente aplicado) y el
      -- llamador la deja en SU movimiento: un cambio de saldo = un movimiento.
      v_applied := -v_branch_qty;
    ELSE
      RAISE EXCEPTION 'Stock insuficiente. Disponible: %, delta: %', v_branch_qty, p_delta
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  v_before := v_branch_qty;
  v_after  := v_branch_qty + v_applied;

  IF v_applied <> 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(
      p_account_id, p_product_id, v_target_branch, v_applied);
  END IF;

  -- Una cuenta sin sucursales recibe su "Casa Central" perezosamente dentro de
  -- c21_apply_branch_stock_delta: se re-resuelve para que el movimiento que
  -- escribe el llamador la selle (cierra el borde declarado de #617).
  IF v_target_branch IS NULL THEN
    v_target_branch := public.c26_default_branch(p_account_id);
  END IF;

  RETURN jsonb_build_object(
    'branch_id',       v_target_branch,
    'quantity_before', v_before,
    'quantity_after',  v_after,
    'quantity_delta',  v_applied,
    'floored',         (v_applied <> p_delta)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._stock_apply_delta(uuid, uuid, numeric, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._stock_apply_delta(uuid, uuid, numeric, uuid, boolean) TO service_role;

COMMENT ON FUNCTION public._stock_apply_delta(uuid, uuid, numeric, uuid, boolean) IS
  $sesp$stock-ledger-solo-rpc (tanda B, D4): aritmética del saldo por sucursal (lock del producto filtrado por cuenta, validación de sucursal, default operativa, piso en cero trazable o P0409, c21_apply_branch_stock_delta). Recibe la cuenta por parámetro. NUNCA escribe movimientos: los escribe quien la llama. stock-edicion-sucursal-piso (D3): con p_allow_negative y faltante aplica sólo lo disponible y lo informa en el retorno (floored + delta efectivo); ya NO inserta el ajuste floor_on_purchase_delete (duplicaba el cambio de saldo del contramovimiento). INTERNA, SECURITY INVOKER: sin EXECUTE para anon/authenticated; la invocan _stock_manual_adjustment y rpc_reverse_stock_movement.$sesp$;

-- ─── 2. rpc_reverse_stock_movement (D3, R4): el contramovimiento lleva la traza del piso ──────────

CREATE OR REPLACE FUNCTION public.rpc_reverse_stock_movement(p_reference_id uuid, p_reference_type text, p_reason text DEFAULT NULL::text)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_movement     RECORD;
  v_new_type     text;
  v_new_ref_type text;
  v_delta_result jsonb;
  v_new_row      public.stock_movements;
  -- stock-movimientos-sucursal-origen (D6): sucursal sobre la que se aplica la
  -- reversa, estado de la original y sucursal efectiva del respaldo.
  v_apply_branch uuid;
  v_orig_active  boolean;
  v_eff_branch   uuid;
  v_fell_back    boolean;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_reference_type NOT IN ('purchase', 'sale') THEN
    RAISE EXCEPTION 'rpc_reverse_stock_movement: p_reference_type debe ser purchase o sale (recibido: %)', p_reference_type
      USING ERRCODE = 'P0400';
  END IF;

  v_new_type     := CASE p_reference_type WHEN 'purchase' THEN 'purchase_return' ELSE 'sale_return' END;
  v_new_ref_type := p_reference_type || '_reversal';

  -- Scope explícito por cuenta (defensa en profundidad — la RPC es SECURITY
  -- DEFINER, no depende de RLS, pero tampoco debe tocar movimientos de otra
  -- cuenta si p_reference_id colisionara).
  FOR v_movement IN
    SELECT *
    FROM public.stock_movements
    WHERE reference_id   = p_reference_id
      AND reference_type = p_reference_type
      AND account_id     = v_account_id
      AND product_id IS NOT NULL
      AND quantity_delta IS NOT NULL
  LOOP
    -- stock-movimientos-sucursal-origen (D6): una sucursal DESACTIVADA no se
    -- lista ni se vende, y el stock que entrara ahí quedaría invisible. Si la
    -- sucursal del movimiento original está desactivada, la reversa se aplica con
    -- sucursal nula, o sea en la principal operativa vigente (c26_default_branch).
    -- Una sucursal cerrada y activa NO entra acá: sigue rechazando con P0422
    -- branch_closed en _stock_apply_delta (se reabre). Una sucursal que no se
    -- encuentra en la cuenta tampoco: _stock_apply_delta la rechaza con P0404.
    v_apply_branch := v_movement.branch_id;
    IF v_movement.branch_id IS NOT NULL THEN
      SELECT b.is_active INTO v_orig_active
      FROM public.branches b
      WHERE b.id = v_movement.branch_id AND b.account_id = v_account_id;
      IF FOUND AND NOT v_orig_active THEN
        v_apply_branch := NULL;
      END IF;
    END IF;

    -- Reutiliza el helper INTERNO _stock_apply_delta para la aritmética de stock
    -- (lock de producto filtrado por cuenta, floor-a-cero trazable si ya se
    -- vendió, validación de sucursal). ESTA función es la dueña del movimiento
    -- que se registra (necesita su propio type/reference_type/metadata, no el
    -- genérico 'adjustment' del ajuste manual): el helper nunca lo escribe. Ya no
    -- pasa por la RPC pública rpc_apply_product_stock_delta, que exige rol y
    -- motivo y rechaza p_log_movement = false / p_allow_negative = true.
    v_delta_result := public._stock_apply_delta(
      v_account_id, v_movement.product_id, -v_movement.quantity_delta, v_apply_branch, TRUE
    );

    -- stock-movimientos-sucursal-origen (D6): hubo respaldo sólo si se pidió la
    -- principal (la original estaba desactivada) Y el stock efectivamente entró
    -- en otra sucursal. Sin ninguna sucursal operativa la principal puede ser la
    -- misma desactivada: ahí no hubo respaldo y el contramovimiento queda como hoy.
    v_eff_branch := (v_delta_result->>'branch_id')::uuid;
    v_fell_back  := v_apply_branch IS NULL
                    AND v_movement.branch_id IS NOT NULL
                    AND v_eff_branch IS DISTINCT FROM v_movement.branch_id;

    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reference_id, reference_type, reason, notes, performed_by, branch_id, metadata
    ) VALUES (
      v_uid, v_account_id, v_movement.product_id, v_movement.product_name, v_new_type,
      (v_delta_result->>'quantity_delta')::numeric,
      (v_delta_result->>'quantity_before')::numeric,
      (v_delta_result->>'quantity_after')::numeric,
      p_reference_id, v_new_ref_type,
      COALESCE(p_reason, format('Reversa de %s', p_reference_type)),
      format('Contramovimiento de %s (movimiento original %s)', p_reference_type, v_movement.id)
        -- stock-edicion-sucursal-piso (D3): si el piso en cero recortó la reversa (la
        -- mercadería ya se había vendido), el contramovimiento lo dice: es el ÚNICO
        -- movimiento del cambio de saldo y lleva lo solicitado y lo aplicado.
        || CASE WHEN COALESCE((v_delta_result->>'floored')::boolean, FALSE)
                THEN format('. Reversa solicitada: %s, aplicada: %s (stock ya vendido)',
                            -v_movement.quantity_delta, v_delta_result->>'quantity_delta')
                ELSE '' END,
      v_uid,
      -- stock-movimientos-sucursal-origen (D6): con respaldo, la sucursal donde
      -- efectivamente entró o salió el stock; sin respaldo, la original (un nulo
      -- queda nulo).
      CASE WHEN v_fell_back THEN v_eff_branch ELSE v_movement.branch_id END,
      jsonb_build_object('reverses_movement_id', v_movement.id)
        || CASE WHEN COALESCE((v_delta_result->>'floored')::boolean, FALSE)
                THEN jsonb_build_object('floored', TRUE,
                                        'requested_quantity_delta', -v_movement.quantity_delta,
                                        'floor_reason', 'floor_on_purchase_delete')
                ELSE '{}'::jsonb END
        || CASE WHEN v_fell_back
                THEN jsonb_build_object('fallback_from_branch_id', v_movement.branch_id,
                                        'fallback_reason', 'branch_inactive')
                ELSE '{}'::jsonb END
    )
    RETURNING * INTO v_new_row;

    RETURN NEXT to_jsonb(v_new_row);
  END LOOP;

  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) TO service_role;

COMMENT ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) IS
  $sesp$v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): reversa de stock por eliminación de compra/venta SIN borrar del ledger — stock_movements tiene policies DELETE/UPDATE con qual=false (deny explícito, append-only por diseño). Inserta el contramovimiento (type purchase_return/sale_return, reference_type purchase_reversal/sale_reversal) con metadata.reverses_movement_id apuntando al original, que permanece. El historial no "olvida" el movimiento anulado: aparece el contramovimiento. stock-ledger-solo-rpc: tanda A (20261073000001) la hizo INTERNA (sin EXECUTE para anon/authenticated; sólo la invocan rpc_delete_sale_operation y rpc_delete_purchase_operation, SECURITY DEFINER); tanda B (20261074000001) hace que use el helper interno _stock_apply_delta en lugar de la RPC pública rpc_apply_product_stock_delta, que ahora exige rol y motivo y rechaza los parámetros internos. stock-movimientos-sucursal-origen (D6): si la sucursal del movimiento original está desactivada (is_active = false), la reversa se aplica en la sucursal principal operativa (c26_default_branch) y el contramovimiento registra esa sucursal, con fallback_from_branch_id y fallback_reason = branch_inactive en metadata; una sucursal cerrada sigue rechazando con P0422 branch_closed y un movimiento sin sucursal sigue cayendo en la principal vigente. stock-edicion-sucursal-piso (D3): con el piso en cero (la mercadería ya se vendió) el contramovimiento es el ÚNICO movimiento del cambio de saldo: lleva floored, requested_quantity_delta y floor_reason en la metadata y lo solicitado y lo aplicado en la nota; ya no hay un ajuste floor_on_purchase_delete aparte.$sesp$;

-- ─── 3. rpc_atomic_update_sale_operation (D1 + D4, R2 + R5): gate por sucursal y respaldo de la desactivada ──────────

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
  v_branch_qty     numeric(15,4);   -- stock-edicion-sucursal-piso (D1): saldo de la sucursal donde se aplica
  v_rev_branch     uuid;            -- stock-edicion-sucursal-piso (D4): sucursal donde se devuelve la pata REVERSE
  v_rev_meta       jsonb;
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
    -- stock-edicion-sucursal-piso (D4): una sucursal vigente que fue DESACTIVADA no se
    -- preserva — no se lista ni se vende, y el stock que se devolviera o descontara ahí
    -- quedaría invisible. Se trata como una fila sin sucursal: cae en la principal
    -- operativa por el bloque de abajo (el mismo respaldo que ya tiene el borrado, D6
    -- de stock-movimientos-sucursal-origen). Una sucursal cerrada y activa no entra
    -- acá: se preserva como hasta hoy.
    IF v_final_branch_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id AND is_active = FALSE
    ) THEN
      v_final_branch_id := NULL;
    END IF;
  END IF;

  -- ventas-sucursal-por-defecto (D5, OQ-7): para la VENTA, NULL significa "la
  -- principal". Ni la intención de desimputar (p_branch_provided con NULL) ni una
  -- fila vigente sin sucursal (residuo histórico) se preservan: se resuelve a la
  -- principal operativa ANTES del REVERSE, igual que la validación de arriba (gate
  -- 2.9 de edicion-preserva-contexto: una edición inválida no revierte ni
  -- reaplica stock). Una sucursal vigente no nula se preserva sin revalidar, como
  -- hoy; una explícita inválida sigue dando P0422 branch_invalid. El REVERSE de
  -- una fila NULL ya caía en la principal vigente (op_stock_movement) y el APPLY
  -- descuenta de esa misma sucursal: el neto es cero. Compra y gasto conservan
  -- las tres intenciones del contrato tri-estado.
  IF v_final_branch_id IS NULL THEN
    v_final_branch_id := public.c26_default_branch(v_account_id);
    IF v_final_branch_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id
        AND is_active = TRUE AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la venta'
        USING ERRCODE = 'P0422';
    END IF;
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
      -- stock-edicion-sucursal-piso (D4): si la sucursal de la venta fue DESACTIVADA, el
      -- stock se devuelve a la principal operativa (sucursal nula = c26_default_branch
      -- dentro de op_stock_movement) y el movimiento deja la sucursal original en la
      -- metadata — mismo respaldo y mismas claves que rpc_reverse_stock_movement. Antes
      -- volvía a la desactivada, donde nadie lo ve ni lo puede vender.
      v_rev_branch := v_old_sale.branch_id;
      v_rev_meta   := NULL;
      IF v_old_sale.branch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = v_old_sale.branch_id AND account_id = v_account_id AND is_active = FALSE
      ) THEN
        v_rev_branch := NULL;
        v_rev_meta   := jsonb_build_object('fallback_from_branch_id', v_old_sale.branch_id,
                                           'fallback_reason', 'branch_inactive');
      END IF;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_sale.product_id, v_old_product_name,
        v_rev_branch,
        COALESCE(v_reverse_delta,
                 public._uom_normalize_quantity(v_old_sale.product_id, v_old_sale.unit_id, v_old_sale.quantity)),
        'sale_return',
        v_old_sale.id, 'sale_update', v_old_sale.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', v_rev_meta
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

      -- stock-edicion-sucursal-piso (D1): gate de stock POR SUCURSAL, la misma donde se
      -- aplica el descuento (v_final_branch_id), igual que el alta (rpc_create_sale_
      -- operation_v2, C-26 OQ-A). Antes el gate era Σ branch_stock de TODAS las
      -- sucursales pero el descuento caía en UNA: con el total alcanzando y la
      -- sucursal no, la edición pasaba el gate y explotaba después con 23514
      -- (branch_stock_quantity_non_negative), que el backend devolvía como un 422
      -- genérico. Ahora rechaza con el mismo P0409 de stock insuficiente que el alta
      -- (el literal que el frontend ya traduce), antes de escribir la línea nueva — la
      -- transacción entera se revierte, incluida la pata REVERSE.
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id AND branch_id = v_final_branch_id;
      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_apply_qty_norm THEN
        IF p_branch_provided AND p_branch_id IS NOT NULL THEN
          RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        ELSE
          RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        END IF;
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

REVOKE ALL ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) IS
  $sesp$edicion-preserva-contexto: preserva branch_id/canal/unit_id al editar (F1, tri-estado para branch_id/canal), bloquea la edición de una operación facturada con P0423 (F2), acepta quantity decimal (F3), y re-apunta sales_orders promovida sin comprobante al operation_id nuevo (F1 §D9). Base: #415 (líneas) + #417 (espejo de stock) + #419 (forma de pago). ventas-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la principal. stock-edicion-sucursal-piso: el gate de stock es POR SUCURSAL (la misma donde se descuenta; P0409 insufficient_branch_stock / Insufficient stock, ya no 23514) y una sucursal vigente DESACTIVADA no se preserva ni recibe la reversa: cae en la principal operativa, con fallback_from_branch_id en la metadata del movimiento.$sesp$;

-- ─── 4. rpc_atomic_update_purchase_operation (D2, R2): rechazo legible de la edición de una compra ya vendida ──────────

CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_supplier_id uuid DEFAULT NULL::uuid, p_supplier_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
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
  v_reverse_delta     numeric;         -- ventas-unidades-conversion (D6)
  v_apply_qty_norm    numeric(15,4);   -- ventas-unidades-conversion (D1)
  v_old_payment_method_id   uuid;
  v_final_payment_method_id uuid;
  v_old_branch_id      uuid;
  v_old_supplier_id    uuid;
  v_old_cost_center_id uuid;
  v_final_branch_id    uuid;
  v_branch             RECORD;
  v_final_supplier_id    uuid;
  v_final_cost_center_id uuid;
  v_old_kind             text;
  v_final_kind           text;
  -- stock-edicion-sucursal-piso (D2): chequeo previo de la pata REVERSE.
  v_rev_qty              numeric;
  v_rev_branch           uuid;
  v_rev_branch_qty       numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

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

  -- pagos-cableados-restantes (D6, task 9.3): inmutabilidad por cargo de
  -- cuenta corriente posteado.
  IF EXISTS (
    SELECT 1
    FROM public.supplier_account_movements sam
    WHERE sam.reference_id IN (
      SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_account_charge_immutable: compra con cargo en cuenta corriente del proveedor posteado — borrá esta compra (revierte el cargo y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.2): inmutabilidad por movimiento
  -- bancario posteado.
  IF EXISTS (
    SELECT 1
    FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'purchase'
      AND bm.source_doc_ref IN (
        SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_bank_movement_immutable: la operación tiene un movimiento bancario posteado y no puede editarse — registrá el ajuste en el ledger bancario y una compra nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- caja-compras-cobranzas (D8): tercer término del guard P0423 — la compra
  -- que ya descontó de la caja también pasa a ser inmutable. Antes de este
  -- change este caso era INALCANZABLE (ningún camino de alta producía un
  -- movimiento de caja de compra), así que agregarlo no cambia el
  -- comportamiento de ninguna compra existente.
  IF EXISTS (
    SELECT 1
    FROM public.cash_movements cm
    WHERE cm.movement_type = 'purchase_payment'
      AND cm.reference_id IN (
        SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_cash_movement_immutable: la compra descontó de la caja y no puede editarse — borrá esta compra (revierte la caja y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

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

  SELECT payment_method_id INTO v_old_payment_method_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
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

  SELECT branch_id, supplier_id, cost_center_id
  INTO   v_old_branch_id, v_old_supplier_id, v_old_cost_center_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
  LIMIT  1;

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

  -- compras-gastos-sucursal-por-defecto (D2/D5): para la COMPRA, NULL significa "la
  -- principal". Ni la intención de desimputar (p_branch_provided con NULL) ni una fila
  -- vigente sin sucursal (compra histórica) se preservan: se resuelve a la principal
  -- operativa ANTES del REVERSE, igual que la validación de arriba (gate 2.9 de
  -- edicion-preserva-contexto: una edición inválida no revierte ni reaplica stock).
  -- Una sucursal vigente no nula se preserva sin revalidar, como hoy; una explícita
  -- inválida sigue dando P0422 branch_invalid. El REVERSE de una fila NULL ya caía en la
  -- principal vigente (op_stock_movement) y el APPLY suma en esa misma sucursal: el neto
  -- es cero. El gasto aplica la misma regla en rpc_update_expense.
  IF v_final_branch_id IS NULL THEN
    v_final_branch_id := public.c26_default_branch(v_account_id);
    IF v_final_branch_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id
        AND is_active = TRUE AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la compra'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  IF p_supplier_provided THEN
    IF p_supplier_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.suppliers
        WHERE id = p_supplier_id AND account_id = v_account_id AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'supplier_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_supplier_id := p_supplier_id;
  ELSE
    v_final_supplier_id := v_old_supplier_id;
  END IF;

  IF p_cost_center_provided THEN
    IF p_cost_center_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.cost_centers
        WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
      ) THEN
        RAISE EXCEPTION 'cost_center_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_cost_center_id := p_cost_center_id;
  ELSE
    v_final_cost_center_id := v_old_cost_center_id;
  END IF;

  SELECT kind INTO v_final_kind
  FROM   public.payment_methods
  WHERE  id = v_final_payment_method_id;

  SELECT kind INTO v_old_kind
  FROM   public.payment_methods
  WHERE  id = v_old_payment_method_id;

  IF (p_payment_method_provided OR p_supplier_provided)
     AND v_final_kind = 'credit'
     AND v_final_supplier_id IS NULL
  THEN
    RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_payment_method_provided
     AND v_final_kind = 'credit'
     AND v_old_kind IS DISTINCT FROM 'credit'
  THEN
    RAISE EXCEPTION 'credit_transition_not_allowed: la edición no postea cargos en cuenta corriente — borrá esta compra y volvé a cargarla como compra a crédito'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  FOR v_old_purchase IN
    SELECT id, product_id, quantity, unit_id, branch_id, operation_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_purchase.product_id;

      -- ventas-unidades-conversion (D6): la pata REVERSE devuelve EXACTAMENTE
      -- lo que el movimiento original sumó (quantity_delta, ya en unidad base
      -- del producto). Sin movimiento cae a la definición única.
      SELECT unit_cost_snapshot, -quantity_delta INTO v_reverse_unit_cost, v_reverse_delta
      FROM   public.stock_movements
      WHERE  reference_id = v_old_purchase.id AND reference_type = 'purchase'
      ORDER  BY created_at DESC
      LIMIT  1;

      v_rev_qty := COALESCE(v_reverse_delta,
                 -public._uom_normalize_quantity(v_old_purchase.product_id, v_old_purchase.unit_id, v_old_purchase.quantity));

      -- stock-edicion-sucursal-piso (D2): la pata REVERSE RESTA del stock lo que la compra
      -- había sumado. Si esa mercadería ya se vendió, la sucursal no alcanza y la resta
      -- violaba el CHECK branch_stock_quantity_non_negative (23514), que el backend
      -- devolvía como un 422 genérico («Los datos no cumplen las restricciones»). Se
      -- rechaza ANTES con un P0409 legible que dice cuánto queda y cuánto habría que
      -- restar. No cambia qué ediciones prosperan (las que fallaban con 23514 fallan con
      -- este mensaje): el borrado de la compra, que sí aplica el piso en cero, queda como
      -- la salida. La transacción entera se revierte: ninguna línea previa queda reversada.
      v_rev_branch := COALESCE(v_old_purchase.branch_id, public.c26_default_branch(v_account_id));
      SELECT COALESCE(quantity, 0) INTO v_rev_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_old_purchase.product_id AND branch_id = v_rev_branch;
      v_rev_branch_qty := COALESCE(v_rev_branch_qty, 0);
      IF v_rev_branch_qty + v_rev_qty < 0 THEN
        RAISE EXCEPTION 'purchase_edit_stock_consumed: de % en la sucursal quedan % y la edición necesita restar %',
          COALESCE(v_old_product_name, v_old_purchase.product_id::text), v_rev_branch_qty, -v_rev_qty
          USING ERRCODE = 'P0409';
      END IF;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_purchase.product_id, v_old_product_name,
        v_old_purchase.branch_id,
        v_rev_qty,
        'purchase_return',
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
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
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

      -- ventas-unidades-conversion (D1): cantidad de la línea nueva en unidad
      -- base del producto para la pata APPLY.
      v_apply_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id,
         name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id,
         v_line_snap->>'name_snapshot',
         v_line_snap->>'sku_snapshot',
         (v_line_snap->>'unit_cost_snapshot')::numeric,
         (v_line_snap->>'iva_rate_snapshot')::numeric)
      RETURNING id INTO v_new_purchase_id;

      IF v_flag_on THEN
        INSERT INTO public.purchase_items (
          purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_purchase_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, v_apply_qty_norm, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) IS
  $sesp$caja-compras-cobranzas (D8): el guard P0423 suma un tercer EXISTS contra
  cash_movements (movement_type=purchase_payment) — una compra con caja
  posteada también pasa a ser inmutable. Mismo predicado en el derivado de
  lectura del listado (backend/repositories/purchase_repository.py).
  stock-edicion-sucursal-piso (D2): chequeo previo de la pata REVERSE — si la mercadería de la compra ya se vendió, rechaza con P0409 purchase_edit_stock_consumed (cuánto queda y cuánto habría que restar) en vez de 23514.$sesp$;

-- ─── 5. Introspección ───────────────────────────────────────────────────────────
DO $$
DECLARE
  v_fn  text;
  v_oid oid;
  v_def text;
  v_bad text[] := '{}';
  v_n   integer;
BEGIN
  FOR v_fn IN SELECT unnest(ARRAY['_stock_apply_delta', 'rpc_reverse_stock_movement',
                                  'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation']) LOOP
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_n <> 1 THEN v_bad := v_bad || format('%s tiene %s firmas (debía ser 1)', v_fn, v_n); END IF;
  END LOOP;

  -- _stock_apply_delta: INVOKER, interna, sin el INSERT del ajuste de piso.
  v_oid := 'public._stock_apply_delta(uuid, uuid, numeric, uuid, boolean)'::regprocedure;
  v_def := pg_get_functiondef(v_oid);
  IF position('INSERT INTO public.stock_movements' in v_def) > 0 THEN v_bad := v_bad || '_stock_apply_delta todavía inserta un movimiento (el ajuste de piso)'::text; END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN v_bad := v_bad || '_stock_apply_delta debía seguir SECURITY INVOKER'::text; END IF;
  IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    v_bad := v_bad || '_stock_apply_delta: ACL interna (sin authenticated/anon, con service_role)'::text;
  END IF;

  -- rpc_reverse_stock_movement: DEFINER, interna, con la traza del piso en su movimiento.
  v_oid := 'public.rpc_reverse_stock_movement(uuid, text, text)'::regprocedure;
  v_def := pg_get_functiondef(v_oid);
  IF position('requested_quantity_delta' in v_def) = 0 OR position('floor_on_purchase_delete' in v_def) = 0 THEN
    v_bad := v_bad || 'rpc_reverse_stock_movement no deja la traza del piso en su contramovimiento'::text;
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN v_bad := v_bad || 'rpc_reverse_stock_movement debía seguir SECURITY DEFINER'::text; END IF;
  IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    v_bad := v_bad || 'rpc_reverse_stock_movement: ACL interna (sin authenticated/anon, con service_role)'::text;
  END IF;

  -- La edición de venta: gate por sucursal (sin Σ de todas) y respaldo de la desactivada.
  v_oid := 'public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)'::regprocedure;
  v_def := pg_get_functiondef(v_oid);
  IF position('SUM(quantity)' in v_def) > 0 OR position('v_rev_branch' in v_def) = 0 OR position('v_branch_qty' in v_def) = 0 THEN
    v_bad := v_bad || 'rpc_atomic_update_sale_operation: gate global todavía presente o sin respaldo de la sucursal desactivada'::text;
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    v_bad := v_bad || 'rpc_atomic_update_sale_operation: DEFINER, con EXECUTE para authenticated y sin él para anon'::text;
  END IF;
  IF position('stock-edicion-sucursal-piso' in COALESCE(obj_description(v_oid, 'pg_proc'), '')) = 0 THEN
    v_bad := v_bad || 'el COMMENT de rpc_atomic_update_sale_operation no declara la regla'::text;
  END IF;

  -- La edición de compra: chequeo previo de la reversa.
  v_oid := 'public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure;
  v_def := pg_get_functiondef(v_oid);
  IF position('purchase_edit_stock_consumed' in v_def) = 0 THEN
    v_bad := v_bad || 'rpc_atomic_update_purchase_operation: sin el chequeo previo de la reversa'::text;
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    v_bad := v_bad || 'rpc_atomic_update_purchase_operation: DEFINER, con EXECUTE para authenticated y sin él para anon'::text;
  END IF;
  IF position('stock-edicion-sucursal-piso' in COALESCE(obj_description(v_oid, 'pg_proc'), '')) = 0 THEN
    v_bad := v_bad || 'el COMMENT de rpc_atomic_update_purchase_operation no declara la regla'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'stock-edicion-sucursal-piso (introspección) FAILED: %', array_to_string(v_bad, ' | ');
  END IF;
  RAISE NOTICE 'stock-edicion-sucursal-piso (introspección) OK: cuatro cuerpos con una firma, gate por sucursal, respaldo de la desactivada, chequeo previo de la reversa, piso sin ajuste aparte, ACL y COMMENT';
END $$;
