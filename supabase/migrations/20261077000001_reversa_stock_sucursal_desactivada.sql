-- =============================================================================
-- MIGRATION: 20261077000001_reversa_stock_sucursal_desactivada.sql
-- CHANGE: stock-movimientos-sucursal-origen (2026-10-11) — governance ALTA:
--         reescribe rpc_reverse_stock_movement, la función que repone o descuenta
--         stock en TODO borrado de venta y de compra. Va ANTES que la migración
--         de datos (20261077000002), que completa la sucursal de origen de los
--         movimientos históricos y puede dejar movimientos registrados en una
--         sucursal desactivada: primero entra el fallback, después los datos.
--         Numeración: la propuesta reservó 20261077000001/2 (20261076… quedó para
--         el hermano compras-gastos-sucursal-por-defecto).
--
-- DECISIÓN DEL PO (2026-10-11, «vamos con todo lo recomendado»): OQ-D (a) — la
-- reversa de un movimiento registrado en una sucursal DESACTIVADA se aplica en la
-- sucursal principal operativa, y el contramovimiento deja anotado de dónde venía.
-- (OQ-A (a), OQ-B (a) y OQ-C (a) rigen la migración de datos 20261077000002.)
--
-- PROBLEMA (design D6): _stock_apply_delta, con sucursal explícita, la busca por
-- id y cuenta y sólo rechaza status = 'closed' (P0422 branch_closed); NO mira
-- is_active. Hoy borrar una venta o una compra cuyo movimiento está en una
-- sucursal desactivada devuelve (o descuenta) el stock en esa sucursal, que no se
-- lista ni se vende: la misma clase del incidente del 22-08. Pasa hoy con toda
-- operación hecha en una sucursal que después se dio de baja, y pasaría con los
-- movimientos que la migración de datos completa con la sucursal original de la
-- cuenta del incidente.
--
-- QUÉ HACE (design D6). Antes de aplicar el delta, si el movimiento original
-- tiene sucursal y esa sucursal de la cuenta está DESACTIVADA (is_active = false),
-- la reversa se aplica con sucursal nula, o sea en c26_default_branch (la
-- principal operativa vigente), y el contramovimiento:
--   - registra en branch_id la sucursal EFECTIVAMENTE usada (la que devuelve
--     _stock_apply_delta), no la original;
--   - suma a metadata fallback_from_branch_id (la original) y fallback_reason =
--     'branch_inactive'.
-- Lo que NO cambia:
--   - una sucursal CERRADA y activa sigue rechazando con P0422 branch_closed (se
--     reabre; es el contrato de C-26). Si la sucursal está desactivada Y cerrada,
--     manda la baja: respaldo, no P0422;
--   - un movimiento sin sucursal sigue cayendo en la principal vigente y su
--     contramovimiento sigue con branch_id nulo;
--   - una sucursal operativa: el stock vuelve ahí, sin cambios;
--   - una sucursal que no se encuentra en la cuenta sigue levantando P0404 en
--     _stock_apply_delta (no se la trata como desactivada);
--   - si la cuenta no tiene NINGUNA sucursal operativa, c26_default_branch
--     devuelve la más antigua a secas (puede ser la misma desactivada): el stock
--     entra donde ya entraba un movimiento sin sucursal, sin error nuevo, y el
--     contramovimiento conserva la sucursal original y NO suma fallback_* (no
--     hubo respaldo).
-- Alcanza a ventas y a compras (es la misma función). El piso en cero trazable
-- de una compra (floor_on_purchase_delete) también cae en la sucursal efectiva.
--
-- CUERPO DE PARTIDA (md5 de prosrc sin \r, verificado el 2026-10-11 contra
-- producción gxdhpxvdjjkmxhdkkwyb —323 migraciones, max(version)=20261075000002,
-- sólo SELECT— y contra la base local construida desde estos archivos:
-- IDÉNTICOS):
--   rpc_reverse_stock_movement   3af74d58ee4bc40691d066d8d4860d7a  (20261074000001_stock_ledger_nucleo_ajuste_manual.sql)
--
-- Reescritura con CREATE OR REPLACE y la MISMA firma (sin DROP, sin overload, sin
-- 42725). El diff contra el cuerpo vivo es EXACTAMENTE: las variables nuevas, la
-- resolución de la sucursal a aplicar, el branch_id y la metadata del
-- contramovimiento, y un comentario `-- stock-movimientos-sucursal-origen (D6):`
-- en cada punto tocado. El COMMENT vivo se conserva completo y se le suma la
-- frase del fallback. ACL re-emitida idéntica a la viva (INTERNA: sólo postgres y
-- service_role; sin EXECUTE para PUBLIC, anon ni authenticated).
--
-- Orden global de locks intacto (sales FOR UPDATE por id ascendente → sales_orders
-- → fiscal_documents → resto): la lectura de branches no toma ningún lock.
--
-- ROLLBACK (sólo con decisión del PO): una migración nueva que re-declare el
-- cuerpo de partida con su COMMENT y su ACL, y que retire en el mismo PR la
-- reaplicación de ESTA migración en KPI_Validation.yml y ajuste el bloque (A0)
-- del gate (sobre una base reconvergida el preflight tomaría la rama de
-- reescritura). Si los movimientos ya fueron completados por 20261077000002 con
-- sucursales desactivadas, volver la función atrás reabre el riesgo de D6: se
-- revierten primero los datos (UPDATE por ids de la auditoría).
--
-- Gate: supabase/tests/test_stock_movimientos_sucursal_origen.sql (parte A)
-- EJECUTA rpc_delete_sale_operation y rpc_delete_purchase_operation. El bloque
-- (9b) de test_ventas_sucursal_por_defecto.sql cambia a propósito. KPI_Validation.yml
-- los cablea y reaplica esta migración AL FINAL de la cadena, después de
-- 20261075000002: su preflight toma la rama «ya es el cuerpo de esta migración».
-- Una migración posterior que redefina rpc_reverse_stock_movement tiene que
-- retirar ese bloque en el mismo PR.
-- =============================================================================

-- ─── 0. Preflight: integridad de función ───────────────────────────────────────
-- La función se reescribe desde su cuerpo VIVO. Si el del stack que aplica esta
-- migración no es ni el de partida ni el que ella deja (una migración
-- intermedia que nadie reconcilió), se ABORTA en vez de pisarlo en silencio —
-- regla de integridad de función (20261060000001, molde de 20261075000001).
DO $$
DECLARE
  v_expected  constant text := '3af74d58ee4bc40691d066d8d4860d7a';
  -- Cuerpo que ESTA migración deja (reaplicación). Medido de pg_proc en el stack
  -- local después de aplicar este archivo.
  v_rewritten constant text := 'ae1ec5de1a6faedf3246013b6dc7f2fd';
  v_n   integer;
  v_md5 text;
BEGIN
  SELECT COUNT(*), md5(replace(MIN(p.prosrc), E'\r', ''))
    INTO v_n, v_md5
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_reverse_stock_movement';

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'stock-movimientos-sucursal-origen: rpc_reverse_stock_movement tiene % firmas (debía haber una) — reconciliar antes de reescribir', v_n;
  END IF;

  IF v_md5 = v_expected THEN
    RAISE NOTICE 'stock-movimientos-sucursal-origen: rpc_reverse_stock_movement se reescribe desde el cuerpo de partida verificado por md5';
  ELSIF v_md5 = v_rewritten THEN
    RAISE NOTICE 'stock-movimientos-sucursal-origen: rpc_reverse_stock_movement ya es el cuerpo de esta migración (reaplicación)';
  ELSE
    RAISE EXCEPTION 'stock-movimientos-sucursal-origen: el cuerpo vivo de rpc_reverse_stock_movement difiere del verificado contra prod el 2026-10-11 — reconciliar antes de reescribir: esperado % (partida) o % (reaplicación), vivo %',
      v_expected, v_rewritten, COALESCE(v_md5, '(no existe)');
  END IF;
END $$;

-- ─── 1. rpc_reverse_stock_movement ─────────────────────────────────────────────
-- Desde su cuerpo vivo (== el de 20261074000001_stock_ledger_nucleo_ajuste_manual.sql).
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
      format('Contramovimiento de %s (movimiento original %s)', p_reference_type, v_movement.id),
      v_uid,
      -- stock-movimientos-sucursal-origen (D6): con respaldo, la sucursal donde
      -- efectivamente entró o salió el stock; sin respaldo, la original (un nulo
      -- queda nulo).
      CASE WHEN v_fell_back THEN v_eff_branch ELSE v_movement.branch_id END,
      jsonb_build_object('reverses_movement_id', v_movement.id)
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

-- ─── 2. COMMENT y ACL ──────────────────────────────────────────────────────────
-- COMMENT: el vivo completo más la frase del fallback (D6).
COMMENT ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) IS
  'v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): reversa de stock por eliminación de compra/venta SIN borrar del ledger — stock_movements tiene policies DELETE/UPDATE con qual=false (deny explícito, append-only por diseño). Inserta el contramovimiento (type purchase_return/sale_return, reference_type purchase_reversal/sale_reversal) con metadata.reverses_movement_id apuntando al original, que permanece. El historial no "olvida" el movimiento anulado: aparece el contramovimiento. stock-ledger-solo-rpc: tanda A (20261073000001) la hizo INTERNA (sin EXECUTE para anon/authenticated; sólo la invocan rpc_delete_sale_operation y rpc_delete_purchase_operation, SECURITY DEFINER); tanda B (20261074000001) hace que use el helper interno _stock_apply_delta en lugar de la RPC pública rpc_apply_product_stock_delta, que ahora exige rol y motivo y rechaza los parámetros internos. stock-movimientos-sucursal-origen (D6): si la sucursal del movimiento original está desactivada (is_active = false), la reversa se aplica en la sucursal principal operativa (c26_default_branch) y el contramovimiento registra esa sucursal, con fallback_from_branch_id y fallback_reason = branch_inactive en metadata; una sucursal cerrada sigue rechazando con P0422 branch_closed y un movimiento sin sucursal sigue cayendo en la principal vigente.';

-- ACL: la de CREATE OR REPLACE se conserva; se re-emite idéntica a la viva (INTERNA:
-- sólo postgres y service_role con EXECUTE; la invocan las funciones SECURITY DEFINER
-- de borrado, nunca anon ni authenticated).
REVOKE EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) FROM PUBLIC, anon, authenticated;

-- ─── 3. Introspección ──────────────────────────────────────────────────────────
-- El md5 vivo es el `v_rewritten` del preflight, hay una sola firma, la ACL no
-- cambió (sin EXECUTE para anon/authenticated) y el COMMENT suma la frase del
-- fallback. Si algo no cierra, la migración ABORTA.
DO $$
DECLARE
  v_rewritten constant text := 'ae1ec5de1a6faedf3246013b6dc7f2fd';
  v_n    integer;
  v_md5  text;
  v_oid  oid;
  v_bad  text[] := '{}';
BEGIN
  SELECT COUNT(*), md5(replace(MIN(p.prosrc), E'\r', '')), MIN(p.oid)::oid
    INTO v_n, v_md5, v_oid
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_reverse_stock_movement';
  IF v_n <> 1 THEN
    v_bad := v_bad || format('%s firmas (debía haber una)', v_n);
  ELSE
    IF v_md5 IS DISTINCT FROM v_rewritten THEN
      v_bad := v_bad || format('md5 vivo %s, esperado %s', v_md5, v_rewritten);
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'anon o authenticated tienen EXECUTE (la reversa es interna)';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'service_role perdió EXECUTE';
    END IF;
    IF position('stock-movimientos-sucursal-origen (D6)' IN COALESCE(obj_description(v_oid, 'pg_proc'), '')) = 0 THEN
      v_bad := v_bad || 'COMMENT sin la frase del fallback';
    END IF;
  END IF;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'stock-movimientos-sucursal-origen (introspección) FAILED: %', array_to_string(v_bad, ' | ');
  END IF;
  RAISE NOTICE 'stock-movimientos-sucursal-origen (introspección) OK: cuerpo con el respaldo de sucursal desactivada, una firma, ACL interna y COMMENT conservados';
END $$;
