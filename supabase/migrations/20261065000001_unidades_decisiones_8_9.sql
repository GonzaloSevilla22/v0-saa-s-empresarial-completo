-- =============================================================================
-- 20261065000001_unidades_decisiones_8_9.sql
--
-- Migración de DATOS (sin DDL, no toca funciones, ACLs ni COMMENTs) que ejecuta
-- las decisiones 8 y 9 del sign-off de `ventas-unidades-conversion`
-- (openspec/changes/archive/2026-09-26-ventas-unidades-conversion/design.md,
-- tabla "Sign-off del PO", filas 8 y 9, y OQ-1). El PO las había diferido el
-- 2026-09-26; el 2026-09-27 pidió ejecutarlas: "el 9 hacelo vos; el 8 yo no
-- puedo porque no tengo acceso a la cuenta (es de un usuario)". Va como
-- migración versionada — el camino normal del proyecto para un cambio de datos
-- con sign-off: `supabase db push` la aplica en prod al mergear.
--
-- Idempotente y reaplicable sin efectos (la reaplica la cadena de
-- KPI_Validation.yml y la ejecuta dos veces su gate,
-- supabase/tests/test_unidades_decisiones_8_9.sql). Nunca aborta el deploy por
-- una fila: un P0409 del guard de unidad base se captura por producto y se
-- informa con NOTICE.
--
-- ─── Decisión 9 (OQ-1): Kilogramo como unidad base de los productos que se
-- venden por kilo y no tienen unidad ───────────────────────────────────────
-- Candidato = producto
--   · sin borrar (deleted_at IS NULL);
--   · sin unidad base EFECTIVA: ni propia ni heredada del padre (misma regla que
--     _uom_normalize_quantity, v_products_with_stock y fn_product_base_unit_guard);
--   · con al menos una línea de VENTA (sales o sale_items) en el Kilogramo de
--     sistema (00000000-0000-0000-0001-000000000002);
--   · sin ninguna línea con una unidad EXPLÍCITA distinta de ese Kilogramo en
--     NINGUNA de las seis tablas de líneas que mira el guard
--     (fn_product_base_unit_guard, rama "asignar", cuarta revisión): sales,
--     purchases, sale_items, purchase_items, sales_order_items, quote_items.
--     Las líneas SIN unidad no declaran ninguna y no excluyen (misma regla que
--     el guard);
--   · sin variantes vivas que HEREDEN su unidad base: asignársela a un padre
--     cambiaría también la unidad efectiva de esas variantes, y de ellas no hay
--     evidencia de que se vendan por kilo. En prod son 0 (medido 2026-09-27);
--     se excluyen igual para que la migración no decida por ellas.
-- Medido en prod el 2026-09-27 (SELECT): 45 productos, todos de UNA cuenta,
-- todos variantes cuyo padre tampoco tiene unidad, todos con stock <> 0. El
-- producto ac5ae409-8b2d-41ae-82c4-204afd8965ba (vendido en kg Y en mL) queda
-- afuera por la línea en mL — es el de la decisión 8.
-- Como el predicado espeja la regla del guard, el trigger lo deja pasar; si
-- entre la medición y el deploy entra una línea en otra unidad, el trigger
-- rechaza con P0409 y ese producto se omite (NOTICE), el resto sigue.
-- La asignación no toca stock ni movimientos: el stock que estaba "en unidades
-- sin nombre" pasa a leerse en kg, que es la unidad en que se venía cargando
-- (D11: asignar la unidad en que ya se cargaba está permitido).
--
-- ─── Decisión 8: ajuste de −0,3806 sobre ac5ae409… (cuenta 192b9efe…) ─────
-- La venta c1628447-5399-430a-aa47-998199be8c65 (cargada el 22-09) se registró
-- como 0,381 mL sobre un producto sin unidad base: el POS de entonces
-- convirtió mL → L y descontó 0,0004 (movimiento
-- cf4550c0-cf36-4f88-aeba-bdf2cd8bb423) en vez de 0,381 (kg). Corrección: un
-- movimiento de ajuste de −0,3806 (= −0,381 − (−0,0004)).
-- Espeja el camino REAL con que la app ajusta stock desde /stock: el PATCH de
-- producto de FastAPI (ProductRepository.update) llama a
-- rpc_apply_product_stock_delta(p_product_id, p_delta, NULL, 'Ajuste manual de
-- stock', true, false) — NO a rpc_adjust_branch_stock, que en prod no escribió
-- ninguno de los ajustes de este producto (todos tienen reference_type NULL y
-- reason 'Ajuste manual de stock', que es lo que inserta
-- rpc_apply_product_stock_delta; rpc_adjust_branch_stock inserta
-- reference_type 'adjustment'). De esa RPC (cuerpo vivo leído el 2026-09-27):
-- FOR UPDATE de la fila del producto, sucursal destino =
-- c26_default_branch(cuenta) cuando no se indica, cantidad vigente de
-- branch_stock, rechazo si quedaría negativa (P0409 sin p_allow_negative),
-- c21_apply_branch_stock_delta para el stock y un stock_movements con
-- type 'adjustment', quantity_before/after, reason, performed_by = user_id =
-- el usuario, branch_id, product_name y account_id (movement_number y
-- metadata por DEFAULT). Como la migración no tiene auth.uid(), el usuario es
-- el dueño de la cuenta (accounts.owner_user_id — el mismo que cargó la venta).
-- Diferencias deliberadas con la RPC: metadata lleva la marca de idempotencia
-- y el movimiento corregido; notes explica el ajuste. reference_id queda NULL
-- a propósito (como en todo ajuste): apuntarlo a la venta haría que una
-- compensación futura de esa venta lo confunda con su propio movimiento.
-- Sucursal: la del movimiento corregido; si es NULL (lo es: la venta no tenía
-- sucursal y la descontó de la default), c26_default_branch de la cuenta — la
-- misma de la que salió el 0,0004 (en prod, 5dd596fe… "Casa Central", única
-- sucursal de la cuenta).
-- Es un DELTA, no un valor absoluto: si al aplicar el stock ya no es 6999,4276
-- (hubo ventas después), el ajuste sigue siendo −0,3806 sobre el valor vigente.
-- Idempotencia: se aplica sólo si existe el movimiento cf4550c0… con su delta
-- original (−0,0004, type 'sale') y NO existe ya un movimiento con
-- metadata->>'fix' = 'ventas-unidades-conversion-decision-8'.
-- Residuo conocido (anotado en CHANGES.md): si más adelante se BORRA esa venta,
-- su compensación devuelve el delta guardado (+0,0004, D6) y este ajuste queda;
-- el stock quedaría 0,3806 por debajo — mismo tratamiento manual que cualquier
-- ajuste previo a un borrado.
-- =============================================================================

-- ─── Decisión 9 ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_kg        constant uuid := '00000000-0000-0000-0001-000000000002';
  v_prod      record;
  v_assigned  integer := 0;
  v_skipped   integer := 0;
  v_rows      integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure u
                  WHERE u.id = v_kg AND u.is_system AND u.account_id IS NULL
                    AND u.type = 'weight' AND u.base_unit_id IS NULL) THEN
    RAISE NOTICE 'decisión 9: no existe el Kilogramo de sistema (%); nada que asignar.', v_kg;
    RETURN;
  END IF;

  FOR v_prod IN
    SELECT p.id, p.account_id, p.name
      FROM public.products p
      LEFT JOIN public.products pp ON pp.id = p.parent_id
     WHERE p.deleted_at IS NULL
       AND p.base_unit_id IS NULL
       AND pp.base_unit_id IS NULL
       AND (   EXISTS (SELECT 1 FROM public.sales s      WHERE s.product_id  = p.id AND s.unit_id  = v_kg)
            OR EXISTS (SELECT 1 FROM public.sale_items si WHERE si.product_id = p.id AND si.unit_id = v_kg))
       AND NOT EXISTS (SELECT 1 FROM public.sales s              WHERE s.product_id   = p.id AND s.unit_id   IS NOT NULL AND s.unit_id   <> v_kg)
       AND NOT EXISTS (SELECT 1 FROM public.purchases pu         WHERE pu.product_id  = p.id AND pu.unit_id  IS NOT NULL AND pu.unit_id  <> v_kg)
       AND NOT EXISTS (SELECT 1 FROM public.sale_items si        WHERE si.product_id  = p.id AND si.unit_id  IS NOT NULL AND si.unit_id  <> v_kg)
       AND NOT EXISTS (SELECT 1 FROM public.purchase_items pi    WHERE pi.product_id  = p.id AND pi.unit_id  IS NOT NULL AND pi.unit_id  <> v_kg)
       AND NOT EXISTS (SELECT 1 FROM public.sales_order_items so WHERE so.product_id  = p.id AND so.unit_id  IS NOT NULL AND so.unit_id  <> v_kg)
       AND NOT EXISTS (SELECT 1 FROM public.quote_items qi       WHERE qi.product_id  = p.id AND qi.unit_id  IS NOT NULL AND qi.unit_id  <> v_kg)
       AND NOT EXISTS (SELECT 1 FROM public.products v
                        WHERE v.parent_id = p.id AND v.base_unit_id IS NULL AND v.deleted_at IS NULL)
     ORDER BY p.id
  LOOP
    BEGIN
      UPDATE public.products
         SET base_unit_id = v_kg
       WHERE id = v_prod.id
         AND base_unit_id IS NULL;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_assigned := v_assigned + v_rows;
    EXCEPTION WHEN SQLSTATE 'P0409' THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'decisión 9: % (%) omitido (%)', v_prod.id, v_prod.name, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'decisión 9 (ventas-unidades-conversion): % productos con Kilogramo asignado como unidad base, % omitidos por el guard.',
    v_assigned, v_skipped;
END $$;

-- ─── Decisión 8 ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_marker     constant text    := 'ventas-unidades-conversion-decision-8';
  v_mov_id     constant uuid    := 'cf4550c0-cf36-4f88-aeba-bdf2cd8bb423';
  v_delta      constant numeric := -0.3806;
  v_mov        record;
  v_prod       record;
  v_owner      uuid;
  v_branch     uuid;
  v_before     numeric(15,4);
  v_after      numeric(15,4);
  v_check      numeric(15,4);
BEGIN
  SELECT sm.id, sm.product_id, sm.account_id, sm.branch_id, sm.type, sm.quantity_delta
    INTO v_mov
    FROM public.stock_movements sm
   WHERE sm.id = v_mov_id;
  IF NOT FOUND THEN
    RAISE NOTICE 'decisión 8: no existe el movimiento %; nada que corregir.', v_mov_id;
    RETURN;
  END IF;
  IF v_mov.type IS DISTINCT FROM 'sale' OR v_mov.quantity_delta IS DISTINCT FROM -0.0004::numeric
     OR v_mov.product_id IS NULL OR v_mov.account_id IS NULL THEN
    RAISE NOTICE 'decisión 8: el movimiento % no es el esperado (type=%, delta=%); no se corrige.',
      v_mov_id, v_mov.type, v_mov.quantity_delta;
    RETURN;
  END IF;

  -- Mutex por producto, como rpc_apply_product_stock_delta. La marca se mira
  -- DESPUÉS del lock: dos aplicaciones concurrentes no pueden duplicar el ajuste.
  SELECT p.id, p.name, p.account_id INTO v_prod
    FROM public.products p
   WHERE p.id = v_mov.product_id
   FOR UPDATE;
  IF NOT FOUND OR v_prod.account_id IS DISTINCT FROM v_mov.account_id THEN
    RAISE NOTICE 'decisión 8: el producto % del movimiento % ya no existe en su cuenta; no se corrige.',
      v_mov.product_id, v_mov_id;
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM public.stock_movements sm
              WHERE sm.product_id = v_mov.product_id
                AND sm.metadata->>'fix' = v_marker) THEN
    RAISE NOTICE 'decisión 8: el ajuste ya estaba aplicado (marca %); nada que hacer.', v_marker;
    RETURN;
  END IF;

  SELECT a.owner_user_id INTO v_owner FROM public.accounts a WHERE a.id = v_mov.account_id;
  IF v_owner IS NULL THEN
    RAISE NOTICE 'decisión 8: la cuenta % no tiene dueño; no se corrige.', v_mov.account_id;
    RETURN;
  END IF;

  v_branch := COALESCE(v_mov.branch_id, public.c26_default_branch(v_mov.account_id));
  IF v_branch IS NULL THEN
    RAISE NOTICE 'decisión 8: la cuenta % no tiene sucursal; no se corrige.', v_mov.account_id;
    RETURN;
  END IF;

  SELECT bs.quantity INTO v_before
    FROM public.branch_stock bs
   WHERE bs.product_id = v_mov.product_id AND bs.branch_id = v_branch
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE NOTICE 'decisión 8: no hay fila de stock del producto % en la sucursal %; no se corrige.',
      v_mov.product_id, v_branch;
    RETURN;
  END IF;
  IF v_before + v_delta < 0 THEN
    RAISE NOTICE 'decisión 8: el stock vigente (%) no alcanza para el ajuste de %; no se corrige.', v_before, v_delta;
    RETURN;
  END IF;
  v_after := v_before + v_delta;

  PERFORM public.c21_apply_branch_stock_delta(v_mov.account_id, v_mov.product_id, v_branch, v_delta);

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reason, notes, performed_by, branch_id, metadata
  ) VALUES (
    v_owner, v_mov.account_id, v_mov.product_id, v_prod.name, 'adjustment',
    v_delta, v_before, v_after,
    'Corrección: venta cargada en mL (ventas-unidades-conversion, decisión 8)',
    format('La venta del 22-09 se cargó como 0,381 mL y descontó 0,0004 (movimiento %s) en vez de 0,381 kg. Ajuste de %s con OK del PO (2026-09-27).',
           v_mov_id, v_delta),
    v_owner, v_branch,
    jsonb_build_object('fix', v_marker, 'corrects_movement', v_mov_id,
                       'migration', '20261065000001')
  );

  SELECT bs.quantity INTO v_check
    FROM public.branch_stock bs
   WHERE bs.product_id = v_mov.product_id AND bs.branch_id = v_branch;
  IF v_check IS DISTINCT FROM v_after THEN
    RAISE EXCEPTION 'decisión 8: el stock quedó en % y se esperaba % (antes %, ajuste %)', v_check, v_after, v_before, v_delta;
  END IF;

  RAISE NOTICE 'decisión 8 (ventas-unidades-conversion): ajuste de % aplicado al producto % en la sucursal % (stock % → %).',
    v_delta, v_mov.product_id, v_branch, v_before, v_after;
END $$;
