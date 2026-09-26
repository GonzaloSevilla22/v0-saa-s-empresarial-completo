-- =============================================================================
-- test_ventas_unidades_conversion.sql — Gate de comportamiento e introspección:
-- ventas-unidades-conversion (2026-09-24).
--
-- Verifica 20261062000001_ventas_unidades_conversion.sql:
--
--   (A) _uom_normalize_quantity es la ÚNICA definición de "cantidad de una línea
--       en la unidad en que se lleva el stock del producto": relativa a la
--       unidad base del PRODUCTO (D1), mismo type obligatorio (P0400
--       unit_type_mismatch), producto sin unidad base sólo admite unidades base
--       (P0400 unit_requires_base_unit, D3), línea sin unidad = factor 1.
--   (B) Los cinco caminos que escriben stock desde una operación la consumen y
--       (auditoría post-apply) también la rama legacy del kill-switch
--       sale_items_rpc_v2=false de rpc_create_sale_operation, y una variante
--       hereda la unidad base de su padre; la consumen y
--       descuentan/suman lo mismo para la misma línea: alta de venta
--       (formulario), POS (quickSale → _c29_confirm_order_core), edición de
--       venta (REVERSE por quantity_delta guardado + APPLY normalizada, D6),
--       alta de compra y edición de compra. Antes de este change el POS y las
--       dos ediciones movían la cantidad CRUDA (450 g descontaban 450 kg).
--   (C) Tipo cruzado rechazado en cada camino SIN rastro parcial; el borrado
--       revierte lo normalizado; invariante SUM(quantity_delta) = branch_stock
--       con unidades mixtas.
--   (D) branch_stock.min_stock numeric(15,4): un umbral de 0,5 kg se propaga y
--       dispara la alerta de stock bajo; un mínimo entero no cambia.
--   (E) Introspección de cuerpos vivos, ACLs, firmas y COMMENT ON FUNCTION de
--       las dos funciones con DROP + CREATE (mismas aserciones que el gate
--       embebido de la migración, para que una migración POSTERIOR que
--       redefina una de las funciones no pase por al lado).
--   (F) Camino REAL de prod: unidades de SISTEMA (is_system = true,
--       account_id NULL — el 100 % de las 1.030 líneas con unidad en prod).
--       El helper acepta 0,45 kg sobre un producto con base kg del sistema y
--       rpc_create_sale_operation normaliza 450 g del sistema a -0,45.
--   (G) Tenencia contra una cuenta REAL: una segunda cuenta creada por
--       handle_new_user con una unidad propia; usarla sobre un producto de la
--       cuenta A → P0404 en el helper y en la venta, sin rastro.
--   (I) (segunda revisión) Contrato de precio D-F: el precio de una línea es
--       por unidad DE LA LÍNEA (100 g a $1,80/g = $180; 1 Docena a $1.200 =
--       $1.200) y el reporting cuenta y costea en unidad BASE (ranking 0,1 kg,
--       COGS 60, margen por canal 66,7 %, costo por venta del Tablero 60).
--   (J) (segunda revisión) D6 distinguible: REVERSE = quantity_delta guardado
--       (movimiento legacy -450 / +2000) y fallback por el helper sin movimiento.
--   (K) (segunda revisión) precisión de 4 decimales, base PROPIA de una
--       variante gana sobre la del padre, factor <= 0 rechazado.
--   (L) (segunda revisión) trg_product_base_unit_guard: P0409 base_unit_locked
--       con stock/movimientos (también por PostgREST y por el grupo del padre),
--       asignar a quien no tenía se permite, P0404 con una unidad ajena;
--       (tercera revisión) también al re-parentar o desenganchar una variante
--       que hereda (L.8-L.10), y no al re-parentar sin cambio efectivo
--       (L.11-L.12).
--   (M) (tercera revisión) D-F′: el precio por unidad de la línea se guarda
--       sin redondear ($4.575/kg = $4,575/g; $1,23456/g) y el total es exacto
--       en POS, formulario, compra y edición (antes el POS grababa 4,58 y
--       editar sin cambios re-preciaba 2.058,75 → 2.061); docenas.
--   (N) (tercera revisión) check_low_margin: la alerta de margen por email
--       compara el importe de la línea contra el costo de la cantidad en
--       unidad base (antes 100 g a $1.800/kg con costo $1.200/kg daba
--       −6.666.567 % y 3 u a $100 con costo $50, −50 %).
--   (E) suma: la cantidad se normaliza DESPUÉS del FOR UPDATE del producto en
--       los seis caminos (TOCTOU; la carrera de punta a punta la fija
--       test_ventas_unidades_conversion_race.sh con dos conexiones), las seis
--       columnas de precio de línea sin escala, check_low_margin en unidad base
--       y el trigger observando parent_id.
--   (H) Residuo cero: después del cleanup, count(*) = 0 por cuenta/usuario del
--       fixture en products, branch_stock, stock_movements, sales, purchases,
--       sale_items, sales_order_items, units_of_measure y payment_methods.
--
-- Patrón del proyecto (test_edicion_preserva_contexto.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final. Anchor sintético vía
-- handle_new_user. Sesión simulada con set_config, LOCAL a la transacción de
-- este archivo — NUNCA usar este patrón contra prod. Las unidades de (A)–(D)
-- se crean por cuenta; las de SISTEMA de (F) se siembran con los MISMOS ids,
-- factores y bases que prod (medido el 2026-09-25) SÓLO si el stack no las
-- tiene (db reset no las siembra: el DDL/dato vivo de prod nunca se versionó,
-- ver 20260509211504), y el cleanup retira únicamente las que sembró.
--
-- Control negativo documentado (ejecutado el 2026-09-24 sobre el stack local):
-- con `v_qty_norm := v_item.quantity;` restaurado en _c29_confirm_order_core,
-- el bloque B.2 falla ("POS: delta esperado -0.45, obtuvo -450"), y con
-- `-v_item.quantity` restaurado en la pata APPLY de la edición, falla B.3.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures        text[] := '{}';
  -- Toda literal que se agrega va con ::text: text[] || 'literal' resuelve la
  -- literal como ARRAY y aborta con "malformed array literal" en vez de
  -- reportar el fallo (visto al correr los mutantes del 2026-09-25).
  v_fail_before     integer;

  v_email_a         text := 'ventas-unidades-conversion-a@test.local';
  v_user_a          uuid := gen_random_uuid();
  v_account_a       uuid;
  v_branch_a        uuid;
  v_client_a        uuid;

  -- Unidades por cuenta (espejo de las 10 de sistema que sólo viven en prod).
  v_u_kg            uuid;   -- weight, base (factor 1, base_unit_id NULL)
  v_u_g             uuid;   -- weight, factor 0.001 → kg
  v_u_tn            uuid;   -- weight, factor 1000 → kg
  v_u_l             uuid;   -- volume, base
  v_u_ml            uuid;   -- volume, factor 0.001 → L
  v_u_u             uuid;   -- unit, base
  v_u_doc           uuid;   -- unit, factor 12 → u

  -- Productos.
  v_p_kg            uuid;   -- base kg
  v_p_g             uuid;   -- base g (unidad base DERIVADA: la conversión es relativa al producto, D1)
  v_p_none          uuid;   -- sin unidad base
  v_p_u             uuid;   -- base u (entero, control de no-regresión)
  v_p_parent        uuid;   -- padre variant_only en kg (auditoría post-apply)
  v_p_var           uuid;   -- variante SIN base propia: hereda kg del padre
  v_u_alien         uuid;   -- unidad ni del sistema ni de la cuenta (guard de tenencia)

  -- (F) Unidades de SISTEMA: mismos ids que prod (00000000-0000-0000-0001-…).
  v_sys_kg          uuid := '00000000-0000-0000-0001-000000000002';  -- Kilogramo, weight, base
  v_sys_g           uuid := '00000000-0000-0000-0001-000000000010';  -- Gramo, weight, 0.001 → kg
  v_sys_seeded      uuid[] := '{}';  -- las que sembró ESTE gate (el cleanup sólo retira éstas)
  v_p_sys           uuid;   -- producto de la cuenta A con base = kg del SISTEMA

  -- (G) Segunda cuenta real (handle_new_user) con una unidad propia.
  v_email_b         text := 'ventas-unidades-conversion-b@test.local';
  v_user_b          uuid := gen_random_uuid();
  v_account_b       uuid;
  v_u_b             uuid;   -- Gramo de la cuenta B

  v_result          jsonb;
  v_op              uuid;
  v_op2             uuid;
  v_sale_id         uuid;
  v_purch_id        uuid;
  v_so_id           uuid;
  v_before          numeric;
  v_after           numeric;
  v_val             numeric;
  v_cnt             integer;
  v_cnt2            integer;
  v_txt             text;
  v_src             text;
  v_fn              text;
  v_bs_id           uuid;

  -- (I)–(L) segunda revisión del PR #584 (fix-round 2026-09-25).
  v_p_rep           uuid;   -- base kg, costo 600/kg: precio y reporting en unidad base
  v_p_b             uuid;   -- producto de la cuenta B (KPI del Tablero aislado)
  v_branch_b        uuid;
  v_p_parent2       uuid;   -- padre en kg cuya variante declara base propia 'u'
  v_p_var_u         uuid;   -- variante con base PROPIA (u): gana sobre la del padre
  v_p_free          uuid;   -- base kg sin stock ni movimientos: cambiar la base se permite
  v_u_neg           uuid;   -- unidad de la cuenta con factor -1 (policy uom_account_insert lo permite)
  v_u_zero          uuid;   -- unidad de la cuenta con factor 0
  v_mv_id           uuid;
  v_jsonb           jsonb;

  -- (M), (N) y L.8-L.12: tercera revisión del PR #584 (fix-round 2, 2026-09-25).
  v_p_prec          uuid;   -- base kg, $4.575/kg: el precio por gramo tiene 3 decimales
  v_p_prec5         uuid;   -- base kg, $1.234,56/kg: el precio por gramo tiene 5 decimales
  v_p_doc           uuid;   -- base u, costo 50 / precio 100: docenas y base con cantidad > 1
  v_p_margin        uuid;   -- base kg, costo $1.200/kg: alerta de margen en unidad base
  v_p_nocost        uuid;   -- sin costo cargado: la alerta de margen no aplica
  v_p_rp_k          uuid;   -- padre en kg (re-parent)
  v_p_rp_k2         uuid;   -- otro padre en kg (misma unidad efectiva)
  v_p_rp_u          uuid;   -- padre en u
  v_p_rp_v          uuid;   -- variante que HEREDA kg, con stock
  v_amount          numeric;
  v_total           numeric;
  v_qty             numeric;
  v_pos1            integer;
  v_pos2            integer;

  -- L.13-L.24, (O) y (P): cuarta revisión del PR #584 (fix-round 3, 2026-09-25).
  v_p_as_kg         uuid;   -- sin base, stock + historia en kg
  v_p_as_u          uuid;   -- sin base, stock + historia en u
  v_p_as_none       uuid;   -- sin base, stock + historia SIN unidad
  v_p_asp           uuid;   -- padre sin base cuya variante (historia en u) hereda
  v_p_asv           uuid;
  v_p_asp2          uuid;   -- padre sin base (re-parent a un padre en kg)
  v_p_asv2          uuid;
  v_p_dp            uuid;   -- padre en kg cuya variante con stock sobrevive al DELETE
  v_p_dv            uuid;
  v_p_dp3           uuid;   -- padre SIN base: su DELETE no le quita nada a la variante
  v_p_dv3           uuid;
  v_u_o_free        uuid;   -- unidad de la cuenta que nada referencia
  v_p_tot           uuid;   -- (P) total al centavo
  v_p_tot2          uuid;
  v_pm_credit       uuid;
  v_supplier        uuid;
  v_ids_p           uuid[];
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Ventas Unidades Conversion', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members
  WHERE  user_id = v_user_a
  ORDER  BY created_at
  LIMIT  1;
  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor — handle_new_user no corrió';
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  IF v_branch_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta no tiene sucursal default';
  END IF;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, 'Cliente Gate VUC')
  RETURNING id INTO v_client_a;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Kilogramo VUC', 'kg', 'weight', 1.0, false) RETURNING id INTO v_u_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Gramo VUC', 'g', 'weight', 0.001, v_u_kg, false) RETURNING id INTO v_u_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Tonelada VUC', 'tn', 'weight', 1000, v_u_kg, false) RETURNING id INTO v_u_tn;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Litro VUC', 'L', 'volume', 1.0, false) RETURNING id INTO v_u_l;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Mililitro VUC', 'mL', 'volume', 0.001, v_u_l, false) RETURNING id INTO v_u_ml;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Unidad VUC', 'u', 'unit', 1.0, false) RETURNING id INTO v_u_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Docena VUC', 'doc', 'unit', 12, v_u_u, false) RETURNING id INTO v_u_doc;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Tomate VUC (kg)', 'VUC-KG', 600.00, 1000.00, v_u_kg) RETURNING id INTO v_p_kg;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Azafrán VUC (g)', 'VUC-G', 10.00, 20.00, v_u_g) RETURNING id INTO v_p_g;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Papa VUC (sin unidad)', 'VUC-NONE', 100.00, 200.00) RETURNING id INTO v_p_none;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Huevo VUC (u)', 'VUC-U', 50.00, 100.00, v_u_u) RETURNING id INTO v_p_u;
  -- Auditoría post-apply: padre en kg con una variante que no declara unidad
  -- base (hereda la del padre), y una unidad "ajena" (account_id NULL, no
  -- del sistema) para el guard de tenencia del helper.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Queso VUC (padre kg)', 'VUC-PARENT', 800.00, 1500.00, v_u_kg, 'variant_only') RETURNING id INTO v_p_parent;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_a, v_account_a, 'Queso VUC — horma chica', 'VUC-VAR', 800.00, 1500.00, v_p_parent, true) RETURNING id INTO v_p_var;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (NULL, 'Gramo ajeno VUC', 'g', 'weight', 0.001, v_u_kg, false) RETURNING id INTO v_u_alien;

  -- (F) Unidades de SISTEMA como en prod (sólo si faltan; se recuerdan para el cleanup).
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure WHERE id = v_sys_kg) THEN
    INSERT INTO public.units_of_measure (id, account_id, name, symbol, type, factor, base_unit_id, is_system)
    VALUES (v_sys_kg, NULL, 'Kilogramo', 'kg', 'weight', 1.0, NULL, true);
    v_sys_seeded := v_sys_seeded || v_sys_kg;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure WHERE id = v_sys_g) THEN
    INSERT INTO public.units_of_measure (id, account_id, name, symbol, type, factor, base_unit_id, is_system)
    VALUES (v_sys_g, NULL, 'Gramo', 'g', 'weight', 0.001, v_sys_kg, true);
    v_sys_seeded := v_sys_seeded || v_sys_g;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure
                 WHERE id = v_sys_g AND is_system AND account_id IS NULL AND type = 'weight'
                   AND factor = 0.001 AND base_unit_id = v_sys_kg) THEN
    RAISE EXCEPTION 'SETUP FAILED: la unidad de sistema Gramo (%) no coincide con la de prod', v_sys_g;
  END IF;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Harina VUC (kg del sistema)', 'VUC-SYS', 300.00, 500.00, v_sys_kg) RETURNING id INTO v_p_sys;

  -- (G) Segunda cuenta REAL vía handle_new_user, con una unidad propia.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Ventas Unidades Conversion B', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;
  SELECT account_id INTO v_account_b
  FROM   public.account_members
  WHERE  user_id = v_user_b
  ORDER  BY created_at
  LIMIT  1;
  IF v_account_b IS NULL OR v_account_b = v_account_a THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó una segunda cuenta distinta (%)', v_account_b;
  END IF;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_b, 'Gramo de la cuenta B VUC', 'g', 'weight', 0.001, v_sys_kg, false) RETURNING id INTO v_u_b;

  -- Sesión sintética del anchor (owner por handle_new_user).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- Stock inicial vía rpc_adjust_branch_stock: deja movimiento 'adjustment',
  -- así el invariante SUM(quantity_delta) = branch_stock.quantity (C.3) es exacto.
  PERFORM public.rpc_adjust_branch_stock(v_p_kg,   v_branch_a, 10,    'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_g,    v_branch_a, 1000,  'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_none, v_branch_a, 10,    'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_u,    v_branch_a, 30,    'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_var,  v_branch_a, 5,     'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_sys,  v_branch_a, 10,    'seed gate VUC');

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A) La definición única, caso por caso
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  v_val := public._uom_normalize_quantity(v_p_kg, v_u_g, 450);
  IF v_val <> 0.45 THEN v_failures := v_failures || format('A.1 base kg + 450 g: esperaba 0.45, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_kg, v_u_kg, 0.45);
  IF v_val <> 0.45 THEN v_failures := v_failures || format('A.2 misma unidad que la base: esperaba 0.45, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_g, v_u_kg, 0.5);
  IF v_val <> 500 THEN v_failures := v_failures || format('A.3 base g + 0.5 kg (relativa al PRODUCTO, no al tipo): esperaba 500, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_kg, v_u_tn, 0.002);
  IF v_val <> 2 THEN v_failures := v_failures || format('A.4 base kg + 0.002 tn: esperaba 2, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_kg, NULL, 3);
  IF v_val <> 3 THEN v_failures := v_failures || format('A.5 línea sin unidad: esperaba 3, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_none, v_u_kg, 2);
  IF v_val <> 2 THEN v_failures := v_failures || format('A.6 sin base + unidad base (kg): esperaba 2, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(NULL, v_u_doc, 2);
  IF v_val <> 2 THEN v_failures := v_failures || format('A.7 línea de servicio (sin producto): esperaba 2 tal cual, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_u, v_u_doc, 2);
  IF v_val <> 24 THEN v_failures := v_failures || format('A.8 base u + 2 docenas: esperaba 24, obtuvo %s', v_val); END IF;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_none, v_u_ml, 0.381);
    v_failures := v_failures || 'A.9 sin base + mL (factor 0.001): no rechazó — es el accidente real del 2026-09-22'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_requires_base_unit' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('A.9 sin base + mL: esperaba P0400 unit_requires_base_unit, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, v_u_l, 1);
    v_failures := v_failures || 'A.10 tipo cruzado (kg vs L): no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('A.10 tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, v_u_g, 0.00004);
    v_failures := v_failures || format('A.11 cantidad que se anula al redondear: no rechazó (obtuvo %s)', v_val);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('quantity_below_precision' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('A.11 bajo precisión: esperaba P0400 quantity_below_precision, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, gen_random_uuid(), 1);
    v_failures := v_failures || 'A.12 unidad inexistente: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN
      v_failures := v_failures || format('A.12 unidad inexistente: esperaba P0404, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- Auditoría post-apply: la variante hereda la base (kg) de su padre.
  v_val := public._uom_normalize_quantity(v_p_var, v_u_g, 450);
  IF v_val <> 0.45 THEN v_failures := v_failures || format('A.13 variante de padre en kg + 450 g: esperaba 0.45 (hereda la base), obtuvo %s', v_val); END IF;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_var, v_u_l, 1);
    v_failures := v_failures || 'A.14 variante de padre en kg + L: no rechazó (sin herencia aceptaría cualquier unidad base)'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('A.14 variante tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- Auditoría post-apply: unidad ni del sistema ni de la cuenta → P0404 (no revela).
  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, v_u_alien, 450);
    v_failures := v_failures || 'A.15 unidad ajena a la cuenta: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN
      v_failures := v_failures || format('A.15 unidad ajena: esperaba P0404, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (A) definición única: 15/15'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (B) Los cinco caminos, misma línea (450 g sobre un producto en kg)
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  -- B.1 alta de venta (formulario) — ya convertía; sigue convirtiendo por la
  -- definición única (P0404 de unidad inexistente lo emite el helper).
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 450, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_before - v_after <> 0.45 THEN
    v_failures := v_failures || format('B.1 formulario: stock bajó %s, esperaba 0.45', v_before - v_after);
  END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -0.45 THEN v_failures := v_failures || format('B.1 formulario: quantity_delta %s, esperaba -0.45', v_val); END IF;
  SELECT quantity INTO v_val FROM public.sale_items WHERE sale_id = v_sale_id;
  IF v_val IS DISTINCT FROM 450 THEN v_failures := v_failures || format('B.1 formulario: la línea debe conservar 450 (g), tiene %s', v_val); END IF;
  SELECT count(*) INTO v_cnt FROM public.sale_items WHERE sale_id = v_sale_id AND unit_id = v_u_g;
  IF v_cnt <> 1 THEN v_failures := v_failures || 'B.1 formulario: la línea perdió su unit_id (g)'::text; END IF;

  -- B.2 POS (quickSale → _c29_confirm_order_core) — antes descontaba 450.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_quick_sale(
    p_idempotency_key => 'vuc-b2-' || gen_random_uuid()::text,
    p_client_id       => NULL,
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'quantity', 450, 'price', 1.00, 'subtotal', 450.00, 'unit_id', v_u_g)),
    p_payment_method  => 'other',
    p_branch_id       => v_branch_a
  );
  v_so_id := (v_result->>'sales_order_id')::uuid;
  v_op2   := (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_before - v_after <> 0.45 THEN
    v_failures := v_failures || format('B.2 POS: stock bajó %s, esperaba 0.45 (antes del change: 450)', v_before - v_after);
  END IF;
  SELECT quantity INTO v_val FROM public.sales_order_items WHERE sales_order_id = v_so_id;
  IF v_val IS DISTINCT FROM 450 THEN v_failures := v_failures || format('B.2 POS: la línea de la orden debe conservar 450, tiene %s', v_val); END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements sm JOIN public.sales s ON s.id = sm.reference_id
  WHERE s.operation_id = v_op2 AND sm.reference_type = 'sale' AND sm.product_id = v_p_kg ORDER BY sm.created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -0.45 THEN v_failures := v_failures || format('B.2 POS: quantity_delta %s, esperaba -0.45', v_val); END IF;

  -- B.3 edición de venta (la de B.1): 450 g → 300 g. REVERSE +0.45 por delta
  -- guardado (D6), APPLY -0.3 normalizada. Antes: +450 y -300.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 300, 'unit_id', v_u_g))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> 0.15 THEN
    v_failures := v_failures || format('B.3 edición venta: stock cambió %s, esperaba +0.15 (= +0.45 - 0.30)', v_after - v_before);
  END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM 0.45 THEN v_failures := v_failures || format('B.3 edición venta: pata REVERSE %s, esperaba +0.45', v_val); END IF;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -0.3 THEN v_failures := v_failures || format('B.3 edición venta: pata APPLY %s, esperaba -0.3', v_val); END IF;
  SELECT quantity INTO v_val FROM public.sale_items WHERE sale_id = v_sale_id;
  IF v_val IS DISTINCT FROM 300 THEN v_failures := v_failures || format('B.3 edición venta: la línea nueva debe tener 300 (g), tiene %s', v_val); END IF;

  -- B.4 alta de compra: 2000 g → +2.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_create_purchase_operation(
    'vuc-b4-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUC',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 2000, 'unit_id', v_u_g)),
    v_branch_a
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_id FROM public.purchases WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> 2 THEN
    v_failures := v_failures || format('B.4 compra: stock subió %s, esperaba 2', v_after - v_before);
  END IF;
  SELECT quantity INTO v_val FROM public.purchases WHERE id = v_purch_id;
  IF v_val IS DISTINCT FROM 2000 THEN v_failures := v_failures || format('B.4 compra: la línea debe conservar 2000 (g), tiene %s', v_val); END IF;

  -- B.5 edición de compra: 2000 g → 1500 g. REVERSE -2 (delta guardado), APPLY +1.5.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_id], CURRENT_DATE, 'Compra gate VUC editada',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 1500, 'unit_id', v_u_g))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> -0.5 THEN
    v_failures := v_failures || format('B.5 edición compra: stock cambió %s, esperaba -0.5 (= -2 + 1.5)', v_after - v_before);
  END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_purch_id AND reference_type = 'purchase_update' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -2 THEN v_failures := v_failures || format('B.5 edición compra: pata REVERSE %s, esperaba -2', v_val); END IF;
  SELECT id INTO v_purch_id FROM public.purchases WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_purch_id AND reference_type = 'purchase' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM 1.5 THEN v_failures := v_failures || format('B.5 edición compra: pata APPLY %s, esperaba +1.5', v_val); END IF;

  -- B.6 producto con base g vende 0.5 kg → -500 (relativa al producto, D1).
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_g AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b6-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_g, 'amount', 20.00, 'quantity', 0.5, 'unit_id', v_u_kg)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_g AND branch_id = v_branch_a;
  IF v_before - v_after <> 500 THEN
    v_failures := v_failures || format('B.6 base g + 0.5 kg: stock bajó %s, esperaba 500', v_before - v_after);
  END IF;

  -- B.7 producto sin unidad base: kg (factor 1) se acepta tal cual; mL se rechaza.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_none AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b7-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_none, 'amount', 200.00, 'quantity', 2, 'unit_id', v_u_kg)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_none AND branch_id = v_branch_a;
  IF v_before - v_after <> 2 THEN
    v_failures := v_failures || format('B.7 sin base + kg: stock bajó %s, esperaba 2', v_before - v_after);
  END IF;
  SELECT count(*) INTO v_cnt FROM public.stock_movements WHERE product_id = v_p_none;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      'vuc-b7b-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_none, 'amount', 200.00, 'quantity', 0.381, 'unit_id', v_u_ml)),
      v_branch_a, NULL
    );
    v_failures := v_failures || 'B.7 sin base + mL: la venta no se rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_requires_base_unit' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('B.7 sin base + mL: esperaba P0400 unit_requires_base_unit, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_cnt2 FROM public.stock_movements WHERE product_id = v_p_none;
  IF v_cnt2 <> v_cnt THEN v_failures := v_failures || 'B.7 sin base + mL: dejó movimiento de stock pese al rechazo'::text; END IF;

  -- B.6 (auditoría post-apply) variante de un padre en kg vendida en gramos por
  -- el formulario: hereda la base del padre → -0.45 (sin herencia: P0400
  -- unit_requires_base_unit, y la venta fallaba).
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_var AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b6-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_var, 'amount', 1.00, 'quantity', 450, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_var AND branch_id = v_branch_a;
  IF v_before - v_after <> 0.45 THEN
    v_failures := v_failures || format('B.6 variante (formulario): stock bajó %s, esperaba 0.45', v_before - v_after);
  END IF;

  -- B.7 (auditoría post-apply) sexto cuerpo: la rama legacy del kill-switch
  -- sale_items_rpc_v2=false de rpc_create_sale_operation conservaba la
  -- conversión inline (base del TIPO). Con el flag apagado para la cuenta,
  -- 450 g sobre el producto en kg descuentan 0.45 igual que la rama vigente.
  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
  VALUES (v_account_a, 'sale_items_rpc_v2', false);
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b7-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 450, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_before - v_after <> 0.45 THEN
    v_failures := v_failures || format('B.7 rama legacy (kill-switch): stock bajó %s, esperaba 0.45 (antes del fix: 450, base del tipo)', v_before - v_after);
  END IF;
  DELETE FROM public.account_feature_flags WHERE account_id = v_account_a AND flag_key = 'sale_items_rpc_v2';

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (B) seis caminos: 9/9'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (C) Tipo cruzado sin rastro en cada camino · borrado · invariante
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  SELECT count(*) INTO v_cnt  FROM public.stock_movements WHERE product_id = v_p_kg;
  SELECT count(*) INTO v_cnt2 FROM public.sales WHERE product_id = v_p_kg;

  -- C.1 formulario
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      'vuc-c1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 1, 'unit_id', v_u_l)),
      v_branch_a, NULL
    );
    v_failures := v_failures || 'C.1 formulario tipo cruzado: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.1 formulario tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- C.2 POS
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key => 'vuc-c2-' || gen_random_uuid()::text,
      p_client_id       => NULL,
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'quantity', 1, 'price', 1.00, 'subtotal', 1.00, 'unit_id', v_u_l)),
      p_payment_method  => 'other',
      p_branch_id       => v_branch_a
    );
    v_failures := v_failures || 'C.2 POS tipo cruzado: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.2 POS tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_val FROM public.sales_orders so JOIN public.sales_order_items soi ON soi.sales_order_id = so.id
  WHERE so.account_id = v_account_a AND soi.product_id = v_p_kg AND soi.unit_id = v_u_l;
  IF v_val <> 0 THEN v_failures := v_failures || 'C.2 POS tipo cruzado: quedó una orden con la línea rechazada'::text; END IF;

  -- C.3 edición de venta (la venta vigente de B.3, 300 g): reemplazo por L.
  SELECT count(*) INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update';
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 1, 'unit_id', v_u_l))
    );
    v_failures := v_failures || 'C.3 edición venta tipo cruzado: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.3 edición venta tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_cnt2 FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update';
  IF v_cnt2 <> v_val THEN v_failures := v_failures || 'C.3 edición venta tipo cruzado: dejó una pata REVERSE pese al rechazo'::text; END IF;
  SELECT count(*) INTO v_cnt2 FROM public.sales WHERE id = v_sale_id;
  IF v_cnt2 <> 1 THEN v_failures := v_failures || 'C.3 edición venta tipo cruzado: la venta vieja no quedó intacta'::text; END IF;

  -- C.4 alta de compra
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      'vuc-c4-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra cruzada VUC',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 1, 'unit_id', v_u_l)),
      v_branch_a
    );
    v_failures := v_failures || 'C.4 compra tipo cruzado: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.4 compra tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- C.5 edición de compra (la compra vigente de B.5, 1500 g)
  BEGIN
    PERFORM public.rpc_atomic_update_purchase_operation(
      ARRAY[v_purch_id], CURRENT_DATE, 'Compra cruzada VUC editada',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 1, 'unit_id', v_u_l))
    );
    v_failures := v_failures || 'C.5 edición compra tipo cruzado: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.5 edición compra tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_cnt2 FROM public.purchases WHERE id = v_purch_id;
  IF v_cnt2 <> 1 THEN v_failures := v_failures || 'C.5 edición compra tipo cruzado: la compra vieja no quedó intacta'::text; END IF;

  -- Cero rastro global sobre el producto en kg: ni movimientos ni ventas nuevas.
  SELECT count(*) INTO v_cnt2 FROM public.stock_movements WHERE product_id = v_p_kg;
  IF v_cnt2 <> v_cnt THEN v_failures := v_failures || format('C tipo cruzado: los rechazos dejaron %s movimientos de stock', v_cnt2 - v_cnt); END IF;

  -- C.6 borrado de la venta del POS (B.2, -0.45): la reversa devuelve lo normalizado.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  PERFORM public.rpc_delete_sale_operation(p_operation_id => v_op2);
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> 0.45 THEN
    v_failures := v_failures || format('C.6 borrado: stock cambió %s, esperaba +0.45', v_after - v_before);
  END IF;

  -- C.7 invariante SUM(quantity_delta) = branch_stock.quantity con unidades mixtas.
  SELECT COALESCE(SUM(quantity_delta), 0) INTO v_val FROM public.stock_movements WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_val <> v_after THEN v_failures := v_failures || format('C.7 invariante (kg): SUM(delta)=%s ≠ branch_stock=%s', v_val, v_after); END IF;
  SELECT COALESCE(SUM(quantity_delta), 0) INTO v_val FROM public.stock_movements WHERE product_id = v_p_g AND branch_id = v_branch_a;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_g AND branch_id = v_branch_a;
  IF v_val <> v_after THEN v_failures := v_failures || format('C.7 invariante (g): SUM(delta)=%s ≠ branch_stock=%s', v_val, v_after); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (C) rechazos sin rastro, borrado e invariante: 7/7'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (D) Umbral de stock mínimo fraccionario
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  v_result := public.rpc_set_product_min_stock(v_p_kg, 0.5);
  SELECT min_stock INTO v_val FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_val IS DISTINCT FROM 0.5 THEN v_failures := v_failures || format('D.1 min_stock 0.5 no se propagó: branch_stock.min_stock = %s', v_val); END IF;
  IF (v_result->>'min_stock')::numeric <> 0.5 THEN v_failures := v_failures || format('D.1 la RPC devolvió min_stock = %s', v_result->>'min_stock'); END IF;

  -- Dejar el stock en 0.6 y vender 200 g → 0.4 ≤ 0.5 dispara la alerta.
  PERFORM public.rpc_adjust_branch_stock(v_p_kg, v_branch_a, 0.6, 'ajuste gate VUC D');
  SELECT id INTO v_bs_id FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  PERFORM public.rpc_create_sale_operation(
    'vuc-d2-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 200, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after <> 0.4 THEN v_failures := v_failures || format('D.2 stock tras la venta = %s, esperaba 0.4', v_after); END IF;
  SELECT count(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'low_branch_stock_alert' AND metadata::text LIKE '%' || v_p_kg::text || '%';
  IF v_cnt < 1 THEN v_failures := v_failures || 'D.2 la alerta low_branch_stock_alert no se disparó con umbral 0.5 y stock 0.4'::text; END IF;
  SELECT count(*) INTO v_cnt FROM public.events
  WHERE account_id = v_account_a AND event_type = 'StockBelowMinimum' AND aggregate_id = v_bs_id;
  IF v_cnt < 1 THEN v_failures := v_failures || 'D.2 el evento StockBelowMinimum no se emitió'::text; END IF;
  SELECT public.get_dashboard_critical_stock(v_branch_a) INTO v_val;
  IF v_val < 1 THEN v_failures := v_failures || format('D.2 get_dashboard_critical_stock no cuenta el producto (%s)', v_val); END IF;
  SELECT count(*) INTO v_cnt FROM public.get_dashboard_critical_stock_items(v_branch_a, 50) i WHERE i.product_id = v_p_kg AND i.min_stock = 0.5;
  IF v_cnt <> 1 THEN v_failures := v_failures || 'D.2 get_dashboard_critical_stock_items no devuelve el producto con min_stock 0.5'::text; END IF;

  -- D.3 mínimo entero de un producto por unidad: intacto.
  PERFORM public.rpc_set_product_min_stock(v_p_u, 5);
  SELECT min_stock INTO v_val FROM public.branch_stock WHERE product_id = v_p_u AND branch_id = v_branch_a;
  IF v_val IS DISTINCT FROM 5 THEN v_failures := v_failures || format('D.3 min_stock entero cambió: %s', v_val); END IF;

  -- D.4 negativo → 0 (red del servidor; el 422 lo pone Pydantic).
  PERFORM public.rpc_set_product_min_stock(v_p_u, -1);
  SELECT min_stock INTO v_val FROM public.branch_stock WHERE product_id = v_p_u AND branch_id = v_branch_a;
  IF v_val IS DISTINCT FROM 0 THEN v_failures := v_failures || format('D.4 min_stock negativo no se saturó en 0: %s', v_val); END IF;

  -- D.5 la vista de compatibilidad expone el mínimo fraccionario.
  SELECT min_stock INTO v_val FROM public.v_products_with_stock WHERE id = v_p_kg;
  IF v_val IS DISTINCT FROM 0.5 THEN v_failures := v_failures || format('D.5 v_products_with_stock.min_stock = %s, esperaba 0.5', v_val); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (D) umbral fraccionario: 5/5'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (E) Introspección (espejo del gate embebido, para migraciones posteriores)
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  FOREACH v_fn IN ARRAY ARRAY[
    '_c29_confirm_order_core', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
    'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
    'rpc_create_sale_operation'
  ] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_src IS NULL THEN v_failures := v_failures || ('E ' || v_fn || ': no existe'); CONTINUE; END IF;
    IF position('public._uom_normalize_quantity(' IN v_src) = 0 THEN v_failures := v_failures || ('E ' || v_fn || ': no invoca _uom_normalize_quantity'); END IF;
    IF v_src ~ '\*\s*v_unit_factor' THEN v_failures := v_failures || ('E ' || v_fn || ': conserva la multiplicación inline'); END IF;
    IF position('v_qty_norm := v_item.quantity;' IN v_src) > 0 THEN v_failures := v_failures || ('E ' || v_fn || ': descuenta la cantidad cruda'); END IF;
  END LOOP;

  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_atomic_update_sale_operation';
  IF v_src ~ '-v_item\.quantity,\s*''sale''' OR v_src ~ 'v_old_sale\.quantity,\s*''sale_return''' THEN
    v_failures := v_failures || 'E rpc_atomic_update_sale_operation: alguna pata usa la cantidad cruda'::text;
  END IF;
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_atomic_update_purchase_operation';
  IF v_src ~ 'v_item\.quantity,\s*''purchase''' OR v_src ~ '-v_old_purchase\.quantity,\s*''purchase_return''' THEN
    v_failures := v_failures || 'E rpc_atomic_update_purchase_operation: alguna pata usa la cantidad cruda'::text;
  END IF;

  SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity';
  IF v_cnt <> 1 THEN v_failures := v_failures || format('E _uom_normalize_quantity: %s definiciones', v_cnt); END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity' AND p.prosecdef) THEN
    v_failures := v_failures || 'E _uom_normalize_quantity: es SECURITY DEFINER'::text;
  END IF;
  IF has_function_privilege('anon', 'public._uom_normalize_quantity(uuid, uuid, numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._uom_normalize_quantity(uuid, uuid, numeric)', 'EXECUTE') THEN
    v_failures := v_failures || 'E _uom_normalize_quantity: ejecutable por anon/authenticated'::text;
  END IF;

  SELECT count(*), max(pg_get_function_identity_arguments(p.oid)) INTO v_cnt, v_txt
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_set_product_min_stock';
  IF v_cnt <> 1 OR v_txt IS DISTINCT FROM 'p_product_id uuid, p_min_stock numeric' THEN
    v_failures := v_failures || format('E rpc_set_product_min_stock: %s firmas, "%s"', v_cnt, v_txt);
  END IF;
  IF has_function_privilege('anon', 'public.rpc_set_product_min_stock(uuid, numeric)', 'EXECUTE') THEN
    v_failures := v_failures || 'E rpc_set_product_min_stock: ejecutable por anon'::text;
  END IF;

  SELECT data_type || '/' || numeric_scale::text INTO v_txt FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'branch_stock' AND column_name = 'min_stock';
  IF v_txt IS DISTINCT FROM 'numeric/4' THEN v_failures := v_failures || format('E branch_stock.min_stock: %s', v_txt); END IF;

  SELECT count(*), max(pg_get_function_result(p.oid)) INTO v_cnt, v_txt
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_dashboard_critical_stock_items';
  IF v_cnt <> 1 OR v_txt !~ 'min_stock numeric' THEN v_failures := v_failures || format('E get_dashboard_critical_stock_items: %s firmas, "%s"', v_cnt, v_txt); END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_products_with_stock' AND c.relkind = 'v'
                   AND c.reloptions::text LIKE '%security_invoker=true%') THEN
    v_failures := v_failures || 'E v_products_with_stock: falta o sin security_invoker'::text;
  END IF;

  -- DROP + CREATE borra el COMMENT ON FUNCTION: tiene que re-emitirse.
  IF obj_description('public.get_dashboard_critical_stock_items(uuid, integer)'::regprocedure, 'pg_proc') IS NULL THEN
    v_failures := v_failures || 'E get_dashboard_critical_stock_items: sin COMMENT ON FUNCTION (DROP + CREATE lo borró)'::text;
  END IF;
  IF obj_description('public.rpc_set_product_min_stock(uuid, numeric)'::regprocedure, 'pg_proc') IS NULL THEN
    v_failures := v_failures || 'E rpc_set_product_min_stock: sin COMMENT ON FUNCTION (DROP + CREATE lo borró)'::text;
  END IF;

  -- Auditoría post-apply: herencia de la base del padre en la vista y en el helper.
  IF pg_get_viewdef('public.v_products_with_stock'::regclass) !~ 'pp\.base_unit_id' THEN
    v_failures := v_failures || 'E v_products_with_stock: base_unit_id no hereda del padre'::text;
  END IF;
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity';
  IF position('LEFT JOIN public.products pp' IN v_src) = 0 OR position('v_unit.is_system' IN v_src) = 0 THEN
    v_failures := v_failures || 'E _uom_normalize_quantity: perdió la herencia del padre o el guard de tenencia'::text;
  END IF;

  -- Segunda revisión: reporting en unidad base, guard de unidad base en la tabla.
  FOREACH v_fn IN ARRAY ARRAY['reporting_sales_lines_in_window', 'rpc_dashboard_kpi_summary', 'rpc_dashboard_channel_margin'] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_src IS NULL OR position('public._uom_quantity_for_reporting(' IN v_src) = 0 THEN
      v_failures := v_failures || ('E ' || v_fn || ': no cuenta en unidad base');
    END IF;
  END LOOP;
  IF has_function_privilege('authenticated', 'public._uom_quantity_for_reporting(uuid, uuid, numeric)', 'EXECUTE') THEN
    v_failures := v_failures || 'E _uom_quantity_for_reporting: ejecutable por authenticated'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = 'public.products'::regclass
                   AND t.tgname = 'trg_product_base_unit_guard' AND NOT t.tgisinternal) THEN
    v_failures := v_failures || 'E products: falta trg_product_base_unit_guard'::text;
  END IF;

  -- Tercera revisión (fix-round 2):
  -- (a) TOCTOU: en los seis caminos la cantidad se normaliza DESPUÉS de tomar
  --     la fila del producto FOR UPDATE — normalizar antes leía la unidad base
  --     commiteada mientras un cambio de unidad base seguía abierto, y la
  --     compra escribía 2 kg que se leían 2 u (reproducido con dos conexiones;
  --     el arnés de carrera lo fija de punta a punta).
  FOREACH v_fn IN ARRAY ARRAY[
    '_c29_confirm_order_core', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
    'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
    'rpc_create_sale_operation'
  ] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    -- Cuarta revisión: posiciones por regexp_instr (tolerante a espacios y
    -- saltos de línea), no por strpos del primer texto literal.
    v_pos1 := regexp_instr(v_src, 'FROM\s+public\.products\s+WHERE\s+id\s*=\s*v_item\.product_id\s+FOR\s+UPDATE');
    v_pos2 := regexp_instr(v_src, '_uom_normalize_quantity\s*\(\s*v_item\.product_id');
    IF v_pos1 = 0 OR v_pos2 = 0 OR v_pos2 < v_pos1 THEN
      v_failures := v_failures || format('E %s: normaliza la cantidad antes de tomar el producto FOR UPDATE (lock en %s, helper en %s)', v_fn, v_pos1, v_pos2);
    END IF;
  END LOOP;
  -- (b) D-F′: el precio por unidad de la línea no se redondea en ninguna
  --     columna de precio de línea (las otras cuatro ya eran numeric sin tope).
  --     Cuarta revisión: se cuentan las columnas VISTAS — si una tabla o una
  --     columna se renombra, el loop iteraba menos de seis y pasaba callado.
  v_cnt := 0;
  FOR v_txt, v_val IN
    SELECT c.table_name || '.' || c.column_name, c.numeric_scale
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND (c.table_name::text, c.column_name::text) IN (('sales_order_items', 'price'), ('quote_items', 'price'),
                                            ('sales', 'amount'), ('sale_items', 'price'),
                                            ('purchases', 'amount'), ('purchase_items', 'price'))
  LOOP
    v_cnt := v_cnt + 1;
    IF v_val IS NOT NULL THEN
      v_failures := v_failures || format('E %s: numeric con escala %s — redondea el precio por unidad de la línea (D-F′)', v_txt, v_val);
    END IF;
  END LOOP;
  IF v_cnt <> 6 THEN
    v_failures := v_failures || format('E D-F′: se vieron %s de las 6 columnas de precio de línea (¿una tabla o columna renombrada?)', v_cnt);
  END IF;
  -- (c) la alerta de margen costea la cantidad en unidad base.
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'check_low_margin';
  IF v_src IS NULL OR position('public._uom_quantity_for_reporting(' IN v_src) = 0 THEN
    v_failures := v_failures || 'E check_low_margin: no costea la cantidad en unidad base'::text;
  END IF;
  -- (d) el guard de unidad base también mira parent_id (re-parent de una variante).
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_attribute a ON a.attrelid = t.tgrelid AND a.attname = 'parent_id'
    WHERE t.tgrelid = 'public.products'::regclass AND t.tgname = 'trg_product_base_unit_guard'
      AND a.attnum = ANY (t.tgattr::int2[])
  ) THEN
    v_failures := v_failures || 'E trg_product_base_unit_guard: no observa parent_id'::text;
  END IF;
  -- Cuarta revisión:
  -- (e) el guard también dispara en DELETE (borrar el padre desenganchaba la
  --     variante con ON DELETE SET NULL y le quitaba la unidad heredada).
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                 WHERE t.tgrelid = 'public.products'::regclass AND t.tgname = 'trg_product_base_unit_guard'
                   AND (t.tgtype::int & 8) <> 0) THEN
    v_failures := v_failures || 'E trg_product_base_unit_guard: no dispara en DELETE'::text;
  END IF;
  -- (f) una unidad en uso no cambia de factor/tipo/base (units_of_measure).
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                 WHERE t.tgrelid = 'public.units_of_measure'::regclass AND t.tgname = 'trg_uom_in_use_guard' AND NOT t.tgisinternal) THEN
    v_failures := v_failures || 'E units_of_measure: falta trg_uom_in_use_guard'::text;
  ELSIF has_function_privilege('authenticated', 'public.fn_uom_in_use_guard()', 'EXECUTE') THEN
    v_failures := v_failures || 'E fn_uom_in_use_guard: ejecutable por authenticated'::text;
  END IF;
  -- (g) el total de dinero se redondea una vez (sin acumulador numeric(15,2))
  --     en los cuatro cuerpos que lo acumulan línea a línea.
  FOREACH v_fn IN ARRAY ARRAY[
    'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
    'rpc_atomic_update_sale_operation', 'rpc_create_sale_operation'
  ] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_src ~ 'v_total_sum\s+numeric\s*\(\s*15\s*,\s*2\s*\)'
       OR v_src !~ 'v_total_sum\s*:=\s*round\s*\(\s*v_total_sum\s*,\s*2\s*\)' THEN
      v_failures := v_failures || format('E %s: el total se acumula redondeando línea a línea (numeric(15,2)) en vez de round(Σ, 2) una vez', v_fn);
    END IF;
  END LOOP;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (E) introspección'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (F) Camino real de prod: unidades de SISTEMA
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_sys, v_sys_kg, 0.45);
    IF v_val IS DISTINCT FROM 0.45 THEN v_failures := v_failures || format('F.1 base kg del sistema + 0,45 kg del sistema: esperaba 0.45, obtuvo %s', v_val); END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('F.1 unidad de SISTEMA (la base misma) rechazada por el helper: %s %s', SQLSTATE, SQLERRM);
  END;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_sys, v_sys_g, 450);
    IF v_val IS DISTINCT FROM 0.45 THEN v_failures := v_failures || format('F.2 base kg del sistema + 450 g del sistema: esperaba 0.45, obtuvo %s', v_val); END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('F.2 unidad de SISTEMA rechazada por el helper: %s %s', SQLSTATE, SQLERRM);
  END;

  -- F.3 unidad del sistema sobre un producto cuya base es de la CUENTA (mismo tipo).
  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, v_sys_g, 450);
    IF v_val IS DISTINCT FROM 0.45 THEN v_failures := v_failures || format('F.3 base kg de la cuenta + 450 g del sistema: esperaba 0.45, obtuvo %s', v_val); END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('F.3 unidad de SISTEMA rechazada sobre base de la cuenta: %s %s', SQLSTATE, SQLERRM);
  END;

  -- F.4 alta de venta por el formulario con la unidad del sistema.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_sys AND branch_id = v_branch_a;
  BEGIN
    v_result := public.rpc_create_sale_operation(
      'vuc-f4-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_sys, 'amount', 1.00, 'quantity', 450, 'unit_id', v_sys_g)),
      v_branch_a, NULL
    );
    v_op := (v_result->>'operation_id')::uuid;
    SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p_sys;
    SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_sys AND branch_id = v_branch_a;
    IF v_before - v_after <> 0.45 THEN
      v_failures := v_failures || format('F.4 venta con g del sistema: stock bajó %s, esperaba 0.45', v_before - v_after);
    END IF;
    SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale' ORDER BY created_at DESC LIMIT 1;
    IF v_val IS DISTINCT FROM -0.45 THEN v_failures := v_failures || format('F.4 venta con g del sistema: quantity_delta %s, esperaba -0.45', v_val); END IF;
    SELECT count(*) INTO v_cnt FROM public.sale_items WHERE sale_id = v_sale_id AND unit_id = v_sys_g AND quantity = 450;
    IF v_cnt <> 1 THEN v_failures := v_failures || 'F.4 venta con g del sistema: la línea no conserva 450 g del sistema'::text; END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('F.4 venta con unidad de SISTEMA rechazada: %s %s', SQLSTATE, SQLERRM);
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (F) unidades de sistema: 4/4'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (G) Unidad de OTRA cuenta real (handle_new_user) → P0404 sin rastro
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, v_u_b, 450);
    v_failures := v_failures || format('G.1 unidad de la cuenta B sobre producto de A: el helper no rechazó (obtuvo %s)', v_val);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN
      v_failures := v_failures || format('G.1 unidad de otra cuenta: esperaba P0404, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  SELECT count(*) INTO v_cnt  FROM public.stock_movements WHERE product_id = v_p_kg;
  SELECT count(*) INTO v_cnt2 FROM public.sales WHERE product_id = v_p_kg;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      'vuc-g2-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 450, 'unit_id', v_u_b)),
      v_branch_a, NULL
    );
    v_failures := v_failures || 'G.2 venta de A con una unidad de la cuenta B: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN
      v_failures := v_failures || format('G.2 venta con unidad de otra cuenta: esperaba P0404, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_val FROM public.stock_movements WHERE product_id = v_p_kg;
  IF v_val <> v_cnt THEN v_failures := v_failures || 'G.2 venta con unidad de otra cuenta: dejó movimiento de stock'::text; END IF;
  SELECT count(*) INTO v_val FROM public.sales WHERE product_id = v_p_kg;
  IF v_val <> v_cnt2 THEN v_failures := v_failures || 'G.2 venta con unidad de otra cuenta: dejó una venta'::text; END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (G) unidad de otra cuenta: 2/2'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (I) Contrato de precio (D-F) y reporting en unidad BASE (segunda revisión)
  --     El precio de una línea es POR UNIDAD DE LA LÍNEA: total = amount ×
  --     quantity (como las 1.018 ventas históricas). El reporting, en cambio,
  --     cuenta unidades y costo en la unidad BASE del producto: antes sumaba
  --     "100" unidades y costeaba 100 × 600 = 60.000 por 100 g a 600/kg.
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Queso VUC reporting (kg)', 'VUC-REP', 600.00, 1800.00, v_u_kg) RETURNING id INTO v_p_rep;
  PERFORM public.rpc_adjust_branch_stock(v_p_rep, v_branch_a, 10, 'seed gate VUC I');

  -- I.1 formulario: 100 g a $1,80/g (= $1.800/kg) → total $180 y stock -0,1 kg.
  v_result := public.rpc_create_sale_operation(
    'vuc-i1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_rep, 'amount', 1.80, 'quantity', 100, 'unit_id', v_u_g)),
    v_branch_a, 'vuc-rep'
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT COALESCE(total, amount) INTO v_val FROM public.sales WHERE operation_id = v_op AND product_id = v_p_rep;
  IF v_val IS DISTINCT FROM 180 THEN v_failures := v_failures || format('I.1 formulario 100 g a $1,80/g: total %s, esperaba 180', v_val); END IF;
  SELECT quantity INTO v_val FROM public.branch_stock WHERE product_id = v_p_rep AND branch_id = v_branch_a;
  IF v_val IS DISTINCT FROM 9.9 THEN v_failures := v_failures || format('I.1 formulario: stock %s, esperaba 9.9', v_val); END IF;

  -- I.2 POS: 1 Docena a $1.200 la docena (= $100/u) → total $1.200 y stock -12 u.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_u AND branch_id = v_branch_a;
  v_result := public.rpc_quick_sale(
    p_idempotency_key => 'vuc-i2-' || gen_random_uuid()::text,
    p_client_id       => NULL,
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_u, 'quantity', 1, 'price', 1200.00, 'subtotal', 1200.00, 'unit_id', v_u_doc)),
    p_payment_method  => 'other',
    p_branch_id       => v_branch_a
  );
  SELECT SUM(COALESCE(s.total, s.amount)) INTO v_val FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  IF v_val IS DISTINCT FROM 1200 THEN v_failures := v_failures || format('I.2 POS 1 Docena a $1.200: total %s, esperaba 1200', v_val); END IF;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_u AND branch_id = v_branch_a;
  IF v_before - v_after <> 12 THEN v_failures := v_failures || format('I.2 POS 1 Docena: stock bajó %s, esperaba 12', v_before - v_after); END IF;

  -- I.3 la definición canónica de "línea de venta del período" en unidad base.
  SELECT SUM(l.quantity), SUM(l.unit_cost * l.quantity) INTO v_val, v_after
  FROM public.reporting_sales_lines_in_window(v_account_a, CURRENT_DATE, CURRENT_DATE, NULL, 'vuc-rep') l;
  IF v_val IS DISTINCT FROM 0.1 THEN v_failures := v_failures || format('I.3 reporting_sales_lines_in_window: quantity %s, esperaba 0.1 (kg), no 100', v_val); END IF;
  IF v_after IS DISTINCT FROM 60 THEN v_failures := v_failures || format('I.3 reporting_sales_lines_in_window: costo %s, esperaba 60 (0,1 kg × 600)', v_after); END IF;

  -- I.4 ranking (consume la definición canónica): unidades 0,1 y COGS 60.
  SELECT r.units, r.total_cost, r.revenue INTO v_val, v_after, v_before
  FROM public.rpc_product_ranking(v_account_a, CURRENT_DATE, CURRENT_DATE, 'units', false, NULL, 'vuc-rep') r
  WHERE r.product_id = v_p_rep;
  IF v_val IS DISTINCT FROM 0.1 OR v_after IS DISTINCT FROM 60 OR v_before IS DISTINCT FROM 180 THEN
    v_failures := v_failures || format('I.4 rpc_product_ranking: units=%s cost=%s revenue=%s, esperaba 0.1 / 60 / 180', v_val, v_after, v_before);
  END IF;

  -- I.5 margen por canal del Tablero (sale_items.quantity): (180 - 60) / 180 = 66,7 %.
  SELECT channels INTO v_jsonb
  FROM public.rpc_dashboard_channel_margin(CURRENT_DATE::timestamptz - interval '1 day', CURRENT_DATE::timestamptz + interval '1 day',
                                           CURRENT_DATE::timestamptz - interval '10 days', CURRENT_DATE::timestamptz - interval '9 days', NULL);
  SELECT (e->>'margin_pct')::numeric INTO v_val FROM jsonb_array_elements(v_jsonb) e WHERE e->>'canal' = 'vuc-rep';
  IF v_val IS DISTINCT FROM 66.7 THEN v_failures := v_failures || format('I.5 rpc_dashboard_channel_margin canal vuc-rep: margen %s, esperaba 66.7', v_val); END IF;

  -- I.6 KPI "costo por venta" del Tablero, aislado en la cuenta B (una sola venta).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_b::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_b::text, true);
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_b, v_account_b, 'Queso VUC B (kg del sistema)', 'VUC-B', 600.00, 1800.00, v_sys_kg) RETURNING id INTO v_p_b;
  PERFORM public.rpc_adjust_branch_stock(v_p_b, v_branch_b, 10, 'seed gate VUC I.6');
  PERFORM public.rpc_create_sale_operation(
    'vuc-i6-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_b, 'amount', 1.80, 'quantity', 100, 'unit_id', v_sys_g)),
    v_branch_b, NULL
  );
  SELECT k.cost_per_sale INTO v_val
  FROM public.rpc_dashboard_kpi_summary(CURRENT_DATE::timestamptz - interval '1 day', CURRENT_DATE::timestamptz + interval '1 day',
                                        CURRENT_DATE::timestamptz - interval '10 days', CURRENT_DATE::timestamptz - interval '9 days', NULL) k;
  IF v_val IS DISTINCT FROM 60 THEN v_failures := v_failures || format('I.6 rpc_dashboard_kpi_summary (cuenta B): cost_per_sale %s, esperaba 60', v_val); END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- I.7 el reporting nunca aborta por una línea histórica que HOY se rechazaría
  --     (la venta real del 2026-09-22 en mL sobre un producto sin base): se
  --     reporta tal como se grabó, sin P0400.
  BEGIN
    v_val := public._uom_quantity_for_reporting(v_p_none, v_u_ml, 0.381);
    IF v_val IS DISTINCT FROM 0.381 THEN v_failures := v_failures || format('I.7 línea histórica inconvertible: %s, esperaba 0.381 tal cual', v_val); END IF;
    v_val := public._uom_quantity_for_reporting(v_p_kg, v_u_g, 100);
    IF v_val IS DISTINCT FROM 0.1 THEN v_failures := v_failures || format('I.7 línea convertible: %s, esperaba 0.1', v_val); END IF;
    v_val := public._uom_quantity_for_reporting(v_p_kg, NULL, 3);
    IF v_val IS DISTINCT FROM 3 THEN v_failures := v_failures || format('I.7 línea sin unidad: %s, esperaba 3', v_val); END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('I.7 _uom_quantity_for_reporting: %s %s', SQLSTATE, SQLERRM);
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (I) precio por unidad de la línea y reporting en unidad base: 7/7'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (J) D6 distinguible: la REVERSE devuelve el quantity_delta GUARDADO, no lo
  --     que el helper recalcula hoy (en B.3/B.5 coinciden, así que ignorar el
  --     delta no rompía nada). Movimiento "legacy" como lo dejaba el POS viejo.
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  -- J.1 venta 450 g cuyo movimiento quedó en -450 (POS viejo) editada a 300 g.
  PERFORM public.rpc_adjust_branch_stock(v_p_kg, v_branch_a, 1000, 'ajuste gate VUC J');
  v_result := public.rpc_create_sale_operation(
    'vuc-j1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 450, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = (v_result->>'operation_id')::uuid AND product_id = v_p_kg;
  UPDATE public.stock_movements SET quantity_delta = -450 WHERE reference_id = v_sale_id AND reference_type = 'sale';
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  PERFORM public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 300, 'unit_id', v_u_g))
  );
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM 450 THEN v_failures := v_failures || format('J.1 edición venta con delta legacy -450: REVERSE %s, esperaba +450 (el delta guardado)', v_val); END IF;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> 449.7 THEN v_failures := v_failures || format('J.1 edición venta: stock cambió %s, esperaba +449.7 (= +450 - 0.3)', v_after - v_before); END IF;

  -- J.2 compra 2000 g cuyo movimiento quedó en +2000, editada a 1500 g.
  PERFORM public.rpc_adjust_branch_stock(v_p_kg, v_branch_a, 5000, 'ajuste gate VUC J.2');
  v_result := public.rpc_create_purchase_operation(
    'vuc-j2-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUC J.2',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 2000, 'unit_id', v_u_g)),
    v_branch_a
  );
  SELECT id INTO v_purch_id FROM public.purchases WHERE operation_id = (v_result->>'operation_id')::uuid AND product_id = v_p_kg;
  UPDATE public.stock_movements SET quantity_delta = 2000 WHERE reference_id = v_purch_id AND reference_type = 'purchase';
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  PERFORM public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_id], CURRENT_DATE, 'Compra gate VUC J.2 editada',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 1500, 'unit_id', v_u_g))
  );
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_purch_id AND reference_type = 'purchase_update' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -2000 THEN v_failures := v_failures || format('J.2 edición compra con delta legacy +2000: REVERSE %s, esperaba -2000 (el delta guardado)', v_val); END IF;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> -1998.5 THEN v_failures := v_failures || format('J.2 edición compra: stock cambió %s, esperaba -1998.5 (= -2000 + 1.5)', v_after - v_before); END IF;

  -- J.3 venta SIN movimiento (fila anterior al ledger): la REVERSE cae al helper.
  PERFORM public.rpc_adjust_branch_stock(v_p_kg, v_branch_a, 1000, 'ajuste gate VUC J.3');
  v_result := public.rpc_create_sale_operation(
    'vuc-j3-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 450, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = (v_result->>'operation_id')::uuid AND product_id = v_p_kg;
  DELETE FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale';
  PERFORM public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 300, 'unit_id', v_u_g))
  );
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM 0.45 THEN v_failures := v_failures || format('J.3 edición sin movimiento original: REVERSE %s, esperaba +0.45 (fallback por el helper)', v_val); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (J) D6 distinguible: 3/3'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (K) Reglas del helper que el gate no fijaba (mutantes sobrevivientes)
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  -- K.1 (A.16) precisión de 4 decimales: 5 g = 0,005 kg (con 2 decimales: 0,01).
  v_val := public._uom_normalize_quantity(v_p_kg, v_u_g, 5);
  IF v_val IS DISTINCT FROM 0.005 THEN v_failures := v_failures || format('K.1 5 g sobre base kg: %s, esperaba 0.005 (4 decimales)', v_val); END IF;

  -- K.2 (A.17) la base PROPIA de una variante gana sobre la del padre (hay 2 en prod).
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Huevos VUC (padre kg)', 'VUC-PARENT2', 1.00, 2.00, v_u_kg, 'variant_only') RETURNING id INTO v_p_parent2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Huevos VUC — por unidad', 'VUC-VAR-U', 50.00, 100.00, v_p_parent2, true, v_u_u) RETURNING id INTO v_p_var_u;
  BEGIN
    v_val := public._uom_normalize_quantity(v_p_var_u, v_u_doc, 2);
    IF v_val IS DISTINCT FROM 24 THEN v_failures := v_failures || format('K.2 variante con base propia u + 2 docenas: %s, esperaba 24', v_val); END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('K.2 variante con base propia u + 2 docenas: rechazó (%s %s) — ganó la base del padre', SQLSTATE, SQLERRM);
  END;
  BEGIN
    v_val := public._uom_normalize_quantity(v_p_var_u, v_u_kg, 1);
    v_failures := v_failures || 'K.2 variante con base propia u: aceptó kg (heredó la base del padre)'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('K.2 variante con base propia + kg: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- K.3 factor de la unidad de la LÍNEA <= 0 (una venta con factor -1 SUMABA stock).
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Kilo negativo VUC', 'akg', 'weight', -1, v_u_kg, false) RETURNING id INTO v_u_neg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Kilo cero VUC', 'zkg', 'weight', 0, v_u_kg, false) RETURNING id INTO v_u_zero;
  FOREACH v_mv_id IN ARRAY ARRAY[v_u_neg, v_u_zero] LOOP
    BEGIN
      v_val := public._uom_normalize_quantity(v_p_kg, v_mv_id, 5);
      v_failures := v_failures || format('K.3 unidad con factor <= 0: no rechazó (obtuvo %s)', v_val);
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE <> 'P0400' OR position('unit_factor_invalid' IN SQLERRM) = 0 THEN
        v_failures := v_failures || format('K.3 factor <= 0: esperaba P0400 unit_factor_invalid, obtuvo %s %s', SQLSTATE, SQLERRM);
      END IF;
    END;
  END LOOP;
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      'vuc-k3-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 5, 'unit_id', v_u_neg)),
      v_branch_a, NULL
    );
    v_failures := v_failures || 'K.3 venta con unidad de factor -1: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after <> v_before THEN v_failures := v_failures || format('K.3 venta con factor -1: el stock cambió %s (una venta SUMABA stock)', v_after - v_before); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (K) precisión, base propia de variante y factor inválido: 3/3'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (L) D-C en la base: products.base_unit_id no cambia debajo del stock
  --     (trigger, único punto de paso: FastAPI, PostgREST y cualquier escritor
  --     futuro), y la unidad base es del sistema o de la cuenta (P0404).
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  -- L.1 con stock y movimientos: cambiar kg → g se rechaza con P0409 base_unit_locked.
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_g WHERE id = v_p_kg;
    v_failures := v_failures || 'L.1 cambiar la unidad base de un producto con stock: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' OR position('base_unit_locked' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('L.1 esperaba P0409 base_unit_locked, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  -- L.2 también QUITARLA (kg → NULL) se rechaza.
  BEGIN
    UPDATE public.products SET base_unit_id = NULL WHERE id = v_p_kg;
    v_failures := v_failures || 'L.2 quitar la unidad base de un producto con stock: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.2 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- L.3 sin stock ni movimientos: se permite.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Producto libre VUC', 'VUC-FREE', 1.00, 2.00, v_u_kg) RETURNING id INTO v_p_free;
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_g WHERE id = v_p_free;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.3 producto sin stock ni movimientos: rechazó el cambio (%s %s)', SQLSTATE, SQLERRM);
  END;
  -- L.4 ASIGNAR a un producto que no tenía (NULL → kg) aunque tenga stock: se permite (D-C).
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_kg WHERE id = v_p_none;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.4 asignar la base a un producto que no tenía: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  -- L.5 grupo: el padre (kg) cuya variante hereda y tiene stock no cambia de base.
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_l WHERE id = v_p_parent;
    v_failures := v_failures || 'L.5 cambiar la base de un padre cuya variante tiene stock: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.5 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- L.6 tenencia: una unidad de la cuenta B como base de un producto de A → P0404.
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_b WHERE id = v_p_free;
    v_failures := v_failures || 'L.6 unidad base de otra cuenta: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN v_failures := v_failures || format('L.6 esperaba P0404, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- L.7 el camino PostgREST (rol authenticated + RLS products_writer_update) tampoco pasa.
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE public.products SET base_unit_id = v_u_g WHERE id = v_p_kg;
    RESET ROLE;
    v_failures := v_failures || 'L.7 PATCH por PostgREST (authenticated): cambió la base de un producto con stock'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.7 PostgREST: esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  RESET ROLE;
  SELECT base_unit_id::text INTO v_txt FROM public.products WHERE id = v_p_kg;
  IF v_txt IS DISTINCT FROM v_u_kg::text THEN v_failures := v_failures || format('L la base de v_p_kg quedó en %s', v_txt); END IF;

  -- L.8-L.12 (tercera revisión): la unidad base EFECTIVA de una variante que
  -- hereda también cambia si se la RE-PARENTA. `authenticated` tiene UPDATE
  -- sobre products.parent_id: re-parentar 5 kg a un padre en 'u' los dejaba
  -- leyéndose 5 u (reproducido por PostgREST). El trigger mira parent_id.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Queso VUC RP (padre kg)', 'VUC-RP-K', 1.00, 2.00, v_u_kg, 'variant_only') RETURNING id INTO v_p_rp_k;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Queso VUC RP (otro padre kg)', 'VUC-RP-K2', 1.00, 2.00, v_u_kg, 'variant_only') RETURNING id INTO v_p_rp_k2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Huevo VUC RP (padre u)', 'VUC-RP-U', 1.00, 2.00, v_u_u, 'variant_only') RETURNING id INTO v_p_rp_u;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_a, v_account_a, 'Queso VUC RP — horma', 'VUC-RP-V', 1.00, 2.00, v_p_rp_k, true) RETURNING id INTO v_p_rp_v;
  PERFORM public.rpc_adjust_branch_stock(v_p_rp_v, v_branch_a, 5, 'seed gate VUC L.8');

  -- L.8 re-parentar la variante (hereda kg, 5 de stock) a un padre en 'u' → P0409.
  BEGIN
    UPDATE public.products SET parent_id = v_p_rp_u WHERE id = v_p_rp_v;
    v_failures := v_failures || 'L.8 re-parentar una variante con stock a un padre en otra unidad: no rechazó (5 kg pasan a leerse 5 u)'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' OR position('base_unit_locked' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('L.8 esperaba P0409 base_unit_locked, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  -- L.9 lo mismo por PostgREST (authenticated + products_writer_update).
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE public.products SET parent_id = v_p_rp_u WHERE id = v_p_rp_v;
    RESET ROLE;
    v_failures := v_failures || 'L.9 re-parent por PostgREST (authenticated): aceptado'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.9 PostgREST: esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  RESET ROLE;
  -- L.10 desenganchar la variante (parent_id NULL) le QUITA la unidad efectiva → P0409.
  BEGIN
    UPDATE public.products SET parent_id = NULL WHERE id = v_p_rp_v;
    v_failures := v_failures || 'L.10 desenganchar una variante con stock (kg → sin unidad): no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.10 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- L.11 re-parentar a OTRO padre con la MISMA unidad efectiva (kg → kg): se permite.
  BEGIN
    UPDATE public.products SET parent_id = v_p_rp_k2 WHERE id = v_p_rp_v;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.11 re-parent a un padre con la misma unidad: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  SELECT parent_id::text INTO v_txt FROM public.products WHERE id = v_p_rp_v;
  IF v_txt IS DISTINCT FROM v_p_rp_k2::text THEN v_failures := v_failures || format('L.11 la variante quedó con padre %s', v_txt); END IF;
  -- L.12 una variante con base PROPIA (u) y stock no cambia de unidad efectiva al re-parentar: se permite.
  PERFORM public.rpc_adjust_branch_stock(v_p_var_u, v_branch_a, 3, 'seed gate VUC L.12');
  BEGIN
    UPDATE public.products SET parent_id = v_p_rp_u WHERE id = v_p_var_u;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.12 re-parent de una variante con base propia: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;

  -- L.13-L.24 (cuarta revisión, fix-round 3). ASIGNAR la unidad base a un
  -- producto que no tenía también reinterpreta si su stock y su historia se
  -- grabaron con una unidad EXPLÍCITA distinta: un producto sin base admite
  -- líneas en cualquier unidad base (kg, L, u). Con historia en kg, asignarle
  -- 'g' dejaba el stock 1000 veces menor; con historia en 'u', asignarle 'kg'
  -- hacía que el POS vendiera kg de algo contado en unidades
  -- (redteam-3a/30-assign-probe, 31-assign-same-type).
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Harina VUC AS (historia kg)', 'VUC-AS-KG', 100.00, 200.00) RETURNING id INTO v_p_as_kg;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Huevo VUC AS (historia u)', 'VUC-AS-U', 50.00, 100.00) RETURNING id INTO v_p_as_u;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Papa VUC AS (historia sin unidad)', 'VUC-AS-NONE', 100.00, 200.00) RETURNING id INTO v_p_as_none;
  PERFORM public.rpc_adjust_branch_stock(v_p_as_kg,   v_branch_a, 10, 'seed gate VUC L.13');
  PERFORM public.rpc_adjust_branch_stock(v_p_as_u,    v_branch_a, 10, 'seed gate VUC L.14');
  PERFORM public.rpc_adjust_branch_stock(v_p_as_none, v_branch_a, 10, 'seed gate VUC L.16');
  PERFORM public.rpc_create_sale_operation('vuc-l13-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_as_kg, 'amount', 200.00, 'quantity', 2, 'unit_id', v_u_kg)), v_branch_a, NULL);
  PERFORM public.rpc_create_sale_operation('vuc-l14-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_as_u, 'amount', 100.00, 'quantity', 3, 'unit_id', v_u_u)), v_branch_a, NULL);
  PERFORM public.rpc_create_sale_operation('vuc-l16-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_as_none, 'amount', 200.00, 'quantity', 1)), v_branch_a, NULL);

  -- L.13 historia en kg → asignar 'g' → P0409 (el stock 8 kg pasaría a leerse 8 g).
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_g WHERE id = v_p_as_kg;
    v_failures := v_failures || 'L.13 asignar g a un producto con stock e historia en kg: no rechazó (8 kg pasan a leerse 8 g)'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' OR position('base_unit_locked' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('L.13 esperaba P0409 base_unit_locked, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  -- L.14 historia en 'u' → asignar 'kg' → P0409.
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_kg WHERE id = v_p_as_u;
    v_failures := v_failures || 'L.14 asignar kg a un producto con stock e historia en u: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' OR position('base_unit_locked' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('L.14 esperaba P0409 base_unit_locked, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  -- L.15 historia en kg → asignar 'kg' → se permite (declara la unidad en que ya se cargaba:
  --      el backfill OQ-1 de los productos vendidos en kg sigue siendo posible).
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_kg WHERE id = v_p_as_kg;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.15 asignar kg a un producto con historia en kg: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  SELECT base_unit_id::text INTO v_txt FROM public.products WHERE id = v_p_as_kg;
  IF v_txt IS DISTINCT FROM v_u_kg::text THEN v_failures := v_failures || format('L.15 la base quedó en %s', v_txt); END IF;
  -- L.16 historia SIN unidad → asignar 'kg' → se permite (la línea sin unidad no declara ninguna).
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_kg WHERE id = v_p_as_none;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.16 asignar kg a un producto con historia sin unidad: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  -- L.17 el camino PostgREST (authenticated) tampoco asigna kg sobre historia en 'u'.
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE public.products SET base_unit_id = v_u_kg WHERE id = v_p_as_u;
    RESET ROLE;
    v_failures := v_failures || 'L.17 PATCH por PostgREST (authenticated): asignó kg sobre historia en u'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.17 PostgREST: esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  RESET ROLE;
  SELECT COALESCE(base_unit_id::text, 'NULL') INTO v_txt FROM public.products WHERE id = v_p_as_u;
  IF v_txt <> 'NULL' THEN v_failures := v_failures || format('L.14/L.17 la base de un producto con historia en u quedó en %s', v_txt); END IF;

  -- L.18 grupo: un PADRE sin base cuya variante (que hereda) tiene stock e historia
  --      en 'u' → asignarle 'kg' al padre → P0409 (la variante pasaría a heredar kg).
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Remera VUC AS (padre sin base)', 'VUC-ASP', 1.00, 2.00, 'variant_only') RETURNING id INTO v_p_asp;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_a, v_account_a, 'Remera VUC AS — talle M', 'VUC-ASV', 1.00, 2.00, v_p_asp, true) RETURNING id INTO v_p_asv;
  PERFORM public.rpc_adjust_branch_stock(v_p_asv, v_branch_a, 5, 'seed gate VUC L.18');
  PERFORM public.rpc_create_sale_operation('vuc-l18-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_asv, 'amount', 2.00, 'quantity', 1, 'unit_id', v_u_u)), v_branch_a, NULL);
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_kg WHERE id = v_p_asp;
    v_failures := v_failures || 'L.18 asignar kg al padre de una variante con historia en u: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.18 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- L.19 el mismo padre con la unidad en que la variante ya se cargaba ('u') → se permite.
  BEGIN
    UPDATE public.products SET base_unit_id = v_u_u WHERE id = v_p_asp;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.19 asignar u al padre de una variante con historia en u: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  -- L.20 re-parentar una variante sin unidad efectiva (historia en 'u', stock) a un
  --      padre en kg también es ASIGNAR → P0409.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Remera VUC AS2 (padre sin base)', 'VUC-ASP2', 1.00, 2.00, 'variant_only') RETURNING id INTO v_p_asp2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_a, v_account_a, 'Remera VUC AS2 — talle L', 'VUC-ASV2', 1.00, 2.00, v_p_asp2, true) RETURNING id INTO v_p_asv2;
  PERFORM public.rpc_adjust_branch_stock(v_p_asv2, v_branch_a, 5, 'seed gate VUC L.20');
  PERFORM public.rpc_create_sale_operation('vuc-l20-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_asv2, 'amount', 2.00, 'quantity', 1, 'unit_id', v_u_u)), v_branch_a, NULL);
  BEGIN
    UPDATE public.products SET parent_id = v_p_rp_k WHERE id = v_p_asv2;
    v_failures := v_failures || 'L.20 re-parentar a un padre en kg una variante con historia en u: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('L.20 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;

  -- L.21 DELETE físico del PADRE (kg) por PostgREST: products_parent_id_fkey es
  --      ON DELETE SET NULL, así que la variante con stock que lo hereda
  --      sobreviviría sin unidad ("5 kg" → "5 uds") → P0409, la variante conserva
  --      el padre. (redteam-3b/10-reparent-via-delete: el trigger no veía al
  --      padre ya borrado y lo tomaba como "sin unidad antes".)
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Queso VUC DP (padre kg)', 'VUC-DP', 1.00, 2.00, v_u_kg, 'variant_only') RETURNING id INTO v_p_dp;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_a, v_account_a, 'Queso VUC DP — horma', 'VUC-DV', 1.00, 2.00, v_p_dp, true) RETURNING id INTO v_p_dv;
  PERFORM public.rpc_adjust_branch_stock(v_p_dv, v_branch_a, 5, 'seed gate VUC L.21');
  BEGIN
    SET LOCAL ROLE authenticated;
    DELETE FROM public.products WHERE id = v_p_dp;
    RESET ROLE;
    v_failures := v_failures || 'L.21 DELETE del padre por PostgREST: aceptado (la variante con 5 kg quedó sin unidad)'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' OR position('base_unit_locked' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('L.21 esperaba P0409 base_unit_locked, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  RESET ROLE;
  SELECT parent_id::text INTO v_txt FROM public.products WHERE id = v_p_dv;
  IF v_txt IS DISTINCT FROM v_p_dp::text OR NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_p_dp) THEN
    v_failures := v_failures || format('L.21 la variante quedó con padre %s (el padre %s)', v_txt,
      CASE WHEN EXISTS (SELECT 1 FROM public.products WHERE id = v_p_dp) THEN 'sigue' ELSE 'se borró' END);
  END IF;
  -- L.22 borrar el padre JUNTO con su variante (nada sobrevive con la unidad
  --      perdida) → se permite: el guard protege a la variante que queda, no
  --      traba un borrado masivo.
  BEGIN
    DELETE FROM public.products WHERE id IN (v_p_dp, v_p_dv);
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.22 DELETE del padre con su variante en la misma sentencia: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  -- L.23 borrar un padre SIN unidad base: la variante que queda no pierde nada → se permite.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
  VALUES (v_user_a, v_account_a, 'Remera VUC DP3 (padre sin base)', 'VUC-DP3', 1.00, 2.00, 'variant_only') RETURNING id INTO v_p_dp3;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_a, v_account_a, 'Remera VUC DP3 — talle S', 'VUC-DV3', 1.00, 2.00, v_p_dp3, true) RETURNING id INTO v_p_dv3;
  PERFORM public.rpc_adjust_branch_stock(v_p_dv3, v_branch_a, 5, 'seed gate VUC L.23');
  BEGIN
    DELETE FROM public.products WHERE id = v_p_dp3;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('L.23 DELETE de un padre sin unidad base: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  SELECT COALESCE(parent_id::text, 'NULL') INTO v_txt FROM public.products WHERE id = v_p_dv3;
  IF v_txt <> 'NULL' THEN v_failures := v_failures || format('L.23 la variante quedó con padre %s', v_txt); END IF;
  -- L.24 el importador (rpc_bulk_upsert_products) también escribe parent_id: el
  --      re-parent de una variante con stock a un padre en otra unidad vuelve como
  --      ERROR DE FILA (base_unit_locked), el resto del lote sigue, nada cambia.
  v_jsonb := public.rpc_bulk_upsert_products(
    jsonb_build_array(jsonb_build_object('row_no', 7, 'sku', 'VUC-RP-V', 'name', 'Queso VUC RP — horma', 'parent_id', v_p_rp_u)),
    v_user_a);
  IF COALESCE((v_jsonb->>'updated')::int, -1) <> 0 OR jsonb_array_length(COALESCE(v_jsonb->'errors', '[]'::jsonb)) <> 1
     OR position('base_unit_locked' IN COALESCE(v_jsonb->'errors'->0->>'message', '')) = 0
     OR COALESCE((v_jsonb->'errors'->0->>'row')::int, -1) <> 7 THEN
    v_failures := v_failures || format('L.24 importador: esperaba 0 actualizados y 1 error de fila 7 con base_unit_locked, obtuvo %s', v_jsonb);
  END IF;
  SELECT parent_id::text INTO v_txt FROM public.products WHERE id = v_p_rp_v;
  IF v_txt IS DISTINCT FROM v_p_rp_k2::text THEN v_failures := v_failures || format('L.24 el importador re-parentó la variante a %s', v_txt); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (L) unidad base bloqueada debajo del stock: 24/24'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (M) D-F′ — el precio por unidad de la LÍNEA se guarda sin redondear y el
  --     total es exacto en todos los caminos (tercera revisión, fix-round 2).
  --     $4.575/kg re-expresado a gramos es $4,575/g: sales_order_items.price
  --     era numeric(15,2), así que el POS grababa 4,58 en sales.amount y en
  --     sale_items.price (amount × quantity ≠ total) y editar la venta SIN
  --     tocar nada la re-preciaba (2.058,75 → 2.061). Reproducido por la
  --     revisión (redteam-2/10-pos-price-precision).
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Jamón VUC (kg)', 'VUC-PREC', 3000.00, 4575.00, v_u_kg) RETURNING id INTO v_p_prec;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Salame VUC (kg)', 'VUC-PREC5', 800.00, 1234.56, v_u_kg) RETURNING id INTO v_p_prec5;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Factura VUC (u)', 'VUC-DOC', 50.00, 100.00, v_u_u) RETURNING id INTO v_p_doc;
  PERFORM public.rpc_adjust_branch_stock(v_p_prec,  v_branch_a, 50,  'seed gate VUC M');
  PERFORM public.rpc_adjust_branch_stock(v_p_prec5, v_branch_a, 50,  'seed gate VUC M');
  PERFORM public.rpc_adjust_branch_stock(v_p_doc,   v_branch_a, 200, 'seed gate VUC M');

  -- M.1 POS 100 g a $4,575/g → $457,50 exacto; el precio viaja sin redondear a las tres tablas.
  v_result := public.rpc_quick_sale(
    p_idempotency_key => 'vuc-m1-' || gen_random_uuid()::text,
    p_client_id       => NULL,
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_prec, 'quantity', 100, 'price', 4.575, 'subtotal', 457.50, 'unit_id', v_u_g)),
    p_payment_method  => 'other',
    p_branch_id       => v_branch_a
  );
  SELECT s.id, s.amount, s.total, s.quantity INTO v_sale_id, v_amount, v_total, v_qty
  FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  IF v_amount IS DISTINCT FROM 4.575 OR v_total IS DISTINCT FROM 457.5 OR v_amount * v_qty IS DISTINCT FROM v_total THEN
    v_failures := v_failures || format('M.1 POS 100 g a $4,575/g: amount=%s total=%s amount×quantity=%s, esperaba 4.575 / 457.5 / 457.5', v_amount, v_total, v_amount * v_qty);
  END IF;
  SELECT price INTO v_val FROM public.sale_items WHERE sale_id = v_sale_id;
  IF v_val IS DISTINCT FROM 4.575 THEN v_failures := v_failures || format('M.1 sale_items.price = %s, esperaba 4.575', v_val); END IF;
  SELECT price INTO v_val FROM public.sales_order_items WHERE sales_order_id = (v_result->>'sales_order_id')::uuid;
  IF v_val IS DISTINCT FROM 4.575 THEN v_failures := v_failures || format('M.1 sales_order_items.price = %s, esperaba 4.575 (numeric(15,2) lo redondeaba a 4.58)', v_val); END IF;

  -- M.2 POS 450 g a $4,575/g → $2.058,75, y editar SIN tocar nada no re-precia (antes 2.061).
  v_result := public.rpc_quick_sale(
    p_idempotency_key => 'vuc-m2-' || gen_random_uuid()::text,
    p_client_id       => NULL,
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_prec, 'quantity', 450, 'price', 4.575, 'subtotal', 2058.75, 'unit_id', v_u_g)),
    p_payment_method  => 'other',
    p_branch_id       => v_branch_a
  );
  v_so_id := (v_result->>'sales_order_id')::uuid;
  SELECT s.id, s.amount, s.total, s.quantity INTO v_sale_id, v_amount, v_total, v_qty
  FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  IF v_total IS DISTINCT FROM 2058.75 OR v_amount * v_qty IS DISTINCT FROM v_total THEN
    v_failures := v_failures || format('M.2 POS 450 g: total=%s amount×quantity=%s, esperaba 2058.75 las dos', v_total, v_amount * v_qty);
  END IF;
  -- La edición manda lo que el formulario rehidrata (use-sales.ts: unitPrice = Number(s.amount)).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_prec, 'amount', v_amount, 'quantity', v_qty, 'unit_id', v_u_g))
  );
  SELECT s.amount, s.total INTO v_amount, v_total FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  IF v_total IS DISTINCT FROM 2058.75 THEN
    v_failures := v_failures || format('M.2 editar la venta del POS sin cambios: total %s, esperaba 2058.75 (se re-precia con el precio redondeado)', v_total);
  END IF;
  SELECT soi.price, soi.subtotal INTO v_val, v_after FROM public.sales_order_items soi WHERE soi.sales_order_id = v_so_id;
  IF v_val IS DISTINCT FROM 4.575 OR v_after IS DISTINCT FROM 2058.75 THEN
    v_failures := v_failures || format('M.2 la orden re-sincronizada tras la edición: price=%s subtotal=%s, esperaba 4.575 / 2058.75', v_val, v_after);
  END IF;

  -- M.3 precio con 5 decimales ($1.234,56/kg → $1,23456/g): se guarda sin redondear; el total que
  --     se cobra es el subtotal al centavo (555,552 → 555,55) — la diferencia es menor a medio centavo.
  v_result := public.rpc_quick_sale(
    p_idempotency_key => 'vuc-m3-' || gen_random_uuid()::text,
    p_client_id       => NULL,
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_prec5, 'quantity', 450, 'price', 1.23456, 'subtotal', 555.552, 'unit_id', v_u_g)),
    p_payment_method  => 'other',
    p_branch_id       => v_branch_a
  );
  SELECT s.amount, s.total, s.quantity INTO v_amount, v_total, v_qty
  FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  IF v_amount IS DISTINCT FROM 1.23456 OR v_total IS DISTINCT FROM 555.55 OR abs(v_amount * v_qty - v_total) >= 0.005 THEN
    v_failures := v_failures || format('M.3 POS 450 g a $1,23456/g: amount=%s total=%s, esperaba 1.23456 / 555.55 (|amount×quantity − total| < 0,005)', v_amount, v_total);
  END IF;

  -- M.4 formulario de venta 100 g a $4,575/g → $457,50; la edición sin cambios lo conserva.
  v_result := public.rpc_create_sale_operation(
    'vuc-m4-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_prec, 'amount', 4.575, 'quantity', 100, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT s.id, s.amount, s.total, s.quantity INTO v_sale_id, v_amount, v_total, v_qty
  FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  IF v_total IS DISTINCT FROM 457.5 THEN v_failures := v_failures || format('M.4 formulario 100 g a $4,575/g: total %s, esperaba 457.5', v_total); END IF;
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_prec, 'amount', v_amount, 'quantity', v_qty, 'unit_id', v_u_g))
  );
  SELECT s.total INTO v_total FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  IF v_total IS DISTINCT FROM 457.5 THEN v_failures := v_failures || format('M.4 edición del formulario sin cambios: total %s, esperaba 457.5', v_total); END IF;

  -- M.5 compra 100 g a $4,575/g → $457,50; la edición sin cambios lo conserva.
  v_result := public.rpc_create_purchase_operation(
    'vuc-m5-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUC M.5',
    jsonb_build_array(jsonb_build_object('product_id', v_p_prec, 'amount', 4.575, 'quantity', 100, 'unit_id', v_u_g)),
    v_branch_a
  );
  SELECT p.id, p.amount, p.total, p.quantity INTO v_purch_id, v_amount, v_total, v_qty
  FROM public.purchases p WHERE p.operation_id = (v_result->>'operation_id')::uuid;
  IF v_total IS DISTINCT FROM 457.5 OR v_amount IS DISTINCT FROM 4.575 THEN
    v_failures := v_failures || format('M.5 compra 100 g a $4,575/g: amount=%s total=%s, esperaba 4.575 / 457.5', v_amount, v_total);
  END IF;
  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_id], CURRENT_DATE, 'Compra gate VUC M.5 editada',
    jsonb_build_array(jsonb_build_object('product_id', v_p_prec, 'amount', v_amount, 'quantity', v_qty, 'unit_id', v_u_g))
  );
  SELECT p.total INTO v_total FROM public.purchases p WHERE p.operation_id = (v_result->>'operation_id')::uuid;
  IF v_total IS DISTINCT FROM 457.5 THEN v_failures := v_failures || format('M.5 edición de la compra sin cambios: total %s, esperaba 457.5', v_total); END IF;

  -- M.6 docena: formulario 2 docenas a $1.200 → $2.400 y −24 u; compra 1 docena a $600 → $600 y +12 u.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_doc AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-m6-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_doc, 'amount', 1200.00, 'quantity', 2, 'unit_id', v_u_doc)),
    v_branch_a, NULL
  );
  SELECT s.total INTO v_total FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  v_result := public.rpc_create_purchase_operation(
    'vuc-m6b-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUC M.6',
    jsonb_build_array(jsonb_build_object('product_id', v_p_doc, 'amount', 600.00, 'quantity', 1, 'unit_id', v_u_doc)),
    v_branch_a
  );
  SELECT p.total INTO v_val FROM public.purchases p WHERE p.operation_id = (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_doc AND branch_id = v_branch_a;
  IF v_total IS DISTINCT FROM 2400 OR v_val IS DISTINCT FROM 600 OR v_after - v_before <> -12 THEN
    v_failures := v_failures || format('M.6 docenas: venta %s (esperaba 2400), compra %s (esperaba 600), stock %s (esperaba -24 + 12 = -12)', v_total, v_val, v_after - v_before);
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (M) precio por unidad de la línea sin redondear y total exacto: 6/6'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (N) check_low_margin (trigger on_sale_insert_margin_check → email
  --     "Alerta de margen crítico" al usuario) costea la cantidad en unidad
  --     BASE y compara contra el importe de la LÍNEA. Antes comparaba el
  --     precio UNITARIO contra costo × cantidad cruda: 100 g a $1,80/g con
  --     costo $1.200/kg daba margen −29.475.882 % (email absurdo), y 3 u a
  --     $100 con costo $50 daba −50 % (falso positivo preexistente).
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Queso VUC margen (kg)', 'VUC-MARGEN', 1200.00, 1800.00, v_u_kg) RETURNING id INTO v_p_margin;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Servicio VUC sin costo (u)', 'VUC-NOCOST', NULL, 100.00, v_u_u) RETURNING id INTO v_p_nocost;
  PERFORM public.rpc_adjust_branch_stock(v_p_margin, v_branch_a, 10, 'seed gate VUC N');
  PERFORM public.rpc_adjust_branch_stock(v_p_nocost, v_branch_a, 10, 'seed gate VUC N');

  -- N.1 100 g a $1,80/g ($1.800/kg), costo $1.200/kg: margen 33,3 % → sin alerta.
  v_result := public.rpc_create_sale_operation(
    'vuc-n1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_margin, 'amount', 1.80, 'quantity', 100, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT s.id INTO v_sale_id FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  SELECT count(*) INTO v_cnt FROM public.email_logs WHERE event_type = 'low_margin_alert' AND metadata->>'sale_id' = v_sale_id::text;
  IF v_cnt <> 0 THEN
    SELECT metadata->>'margin_percentage' INTO v_txt FROM public.email_logs WHERE event_type = 'low_margin_alert' AND metadata->>'sale_id' = v_sale_id::text LIMIT 1;
    v_failures := v_failures || format('N.1 100 g a $1.800/kg con costo $1.200/kg: disparó la alerta de margen (margen %s %%)', v_txt);
  END IF;

  -- N.2 100 g a $1,00/g ($1.000/kg): margen −20 % → alerta con importe 100, costo 120, margen −20.
  v_result := public.rpc_create_sale_operation(
    'vuc-n2-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_margin, 'amount', 1.00, 'quantity', 100, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT s.id INTO v_sale_id FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  SELECT count(*), max(metadata->>'margin_percentage'), max(metadata->>'cost_basis'), max(metadata->>'amount')
  INTO v_cnt, v_txt, v_src, v_fn
  FROM public.email_logs WHERE event_type = 'low_margin_alert' AND metadata->>'sale_id' = v_sale_id::text;
  IF v_cnt <> 1 OR v_txt::numeric IS DISTINCT FROM -20 OR v_src::numeric IS DISTINCT FROM 120 OR v_fn::numeric IS DISTINCT FROM 100 THEN
    v_failures := v_failures || format('N.2 100 g a $1.000/kg: %s alertas, margen %s, costo %s, importe %s — esperaba 1 / -20 / 120 / 100', v_cnt, v_txt, v_src, v_fn);
  END IF;

  -- N.3 unidad base con cantidad > 1: 3 u a $100 con costo $50 → margen 50 % → sin alerta.
  v_result := public.rpc_create_sale_operation(
    'vuc-n3-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_doc, 'amount', 100.00, 'quantity', 3, 'unit_id', v_u_u)),
    v_branch_a, NULL
  );
  SELECT s.id INTO v_sale_id FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  SELECT count(*) INTO v_cnt FROM public.email_logs WHERE event_type = 'low_margin_alert' AND metadata->>'sale_id' = v_sale_id::text;
  IF v_cnt <> 0 THEN v_failures := v_failures || 'N.3 3 u a $100 con costo $50 (margen 50 %): disparó la alerta de margen'::text; END IF;

  -- N.4 POS 100 g a $1,80/g: el trigger es de la tabla, vale para cualquier camino → sin alerta.
  v_result := public.rpc_quick_sale(
    p_idempotency_key => 'vuc-n4-' || gen_random_uuid()::text,
    p_client_id       => NULL,
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_margin, 'quantity', 100, 'price', 1.80, 'subtotal', 180.00, 'unit_id', v_u_g)),
    p_payment_method  => 'other',
    p_branch_id       => v_branch_a
  );
  SELECT s.id INTO v_sale_id FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  SELECT count(*) INTO v_cnt FROM public.email_logs WHERE event_type = 'low_margin_alert' AND metadata->>'sale_id' = v_sale_id::text;
  IF v_cnt <> 0 THEN v_failures := v_failures || 'N.4 POS 100 g a $1.800/kg con costo $1.200/kg: disparó la alerta de margen'::text; END IF;

  -- N.5 producto sin costo cargado: la alerta no aplica (no hay contra qué comparar).
  v_result := public.rpc_create_sale_operation(
    'vuc-n5-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_nocost, 'amount', 1.00, 'quantity', 1, 'unit_id', v_u_u)),
    v_branch_a, NULL
  );
  SELECT s.id INTO v_sale_id FROM public.sales s WHERE s.operation_id = (v_result->>'operation_id')::uuid;
  SELECT count(*) INTO v_cnt FROM public.email_logs WHERE event_type = 'low_margin_alert' AND metadata->>'sale_id' = v_sale_id::text;
  IF v_cnt <> 0 THEN v_failures := v_failures || 'N.5 producto sin costo: disparó la alerta de margen'::text; END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (N) alerta de margen en unidad base: 5/5'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (O) (cuarta revisión) units_of_measure: el factor, el tipo y la base de
  --     una unidad EN USO (unidad base de un producto o unidad de una línea)
  --     no cambian — P0409 unit_in_use. El reporting recalcula la cantidad
  --     base al leer (D13) con el factor VIGENTE, y la policy
  --     uom_account_update deja a `authenticated` editar las unidades de su
  --     cuenta: 12 → 6 en el factor de la Docena reinterpretaba hacia atrás
  --     unidades y costo del ranking mientras el stock quedaba como estaba
  --     (redteam-3a/33-uom-factor). Mismo riesgo que D-C cierra para
  --     products.base_unit_id.
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Libra VUC (sin uso)', 'lb', 'weight', 0.4536, v_u_kg, false) RETURNING id INTO v_u_o_free;

  -- O.1 factor de una unidad que es la BASE de productos (kg).
  BEGIN
    UPDATE public.units_of_measure SET factor = 2 WHERE id = v_u_kg;
    v_failures := v_failures || 'O.1 cambiar el factor de una unidad base de productos: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' OR position('unit_in_use' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('O.1 esperaba P0409 unit_in_use, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  -- O.2 factor de una unidad usada en LÍNEAS (Docena: B/M venden en docenas).
  BEGIN
    UPDATE public.units_of_measure SET factor = 6 WHERE id = v_u_doc;
    v_failures := v_failures || 'O.2 cambiar el factor de una unidad usada en líneas (12 → 6): no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('O.2 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- O.3 el tipo de una unidad en uso.
  BEGIN
    UPDATE public.units_of_measure SET type = 'volume' WHERE id = v_u_g;
    v_failures := v_failures || 'O.3 cambiar el tipo de una unidad en uso: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('O.3 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- O.4 la base (base_unit_id) de una unidad en uso.
  BEGIN
    UPDATE public.units_of_measure SET base_unit_id = NULL WHERE id = v_u_g;
    v_failures := v_failures || 'O.4 cambiar la base de una unidad en uso: no rechazó'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('O.4 esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  -- O.5 el camino PostgREST (authenticated + uom_account_update) tampoco pasa.
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE public.units_of_measure SET factor = 6 WHERE id = v_u_doc;
    RESET ROLE;
    v_failures := v_failures || 'O.5 PATCH por PostgREST (authenticated): cambió el factor de la Docena en uso'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0409' THEN v_failures := v_failures || format('O.5 PostgREST: esperaba P0409, obtuvo %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  RESET ROLE;
  SELECT factor INTO v_val FROM public.units_of_measure WHERE id = v_u_doc;
  IF v_val <> 12 THEN v_failures := v_failures || format('O el factor de la Docena quedó en %s', v_val); END IF;
  -- O.6 el nombre y el símbolo de una unidad en uso sí se editan (no reinterpretan nada).
  BEGIN
    UPDATE public.units_of_measure SET name = 'Docena VUC (renombrada)', symbol = 'dz' WHERE id = v_u_doc;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('O.6 renombrar una unidad en uso: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;
  -- O.7 una unidad que nada referencia se corrige libremente.
  BEGIN
    UPDATE public.units_of_measure SET factor = 0.45359237 WHERE id = v_u_o_free;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures || format('O.7 corregir el factor de una unidad sin uso: rechazó (%s %s)', SQLSTATE, SQLERRM);
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (O) unidad en uso inmutable en factor/tipo/base: 7/7'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (P) (cuarta revisión) el total de DINERO de una operación se redondea al
  --     centavo UNA vez, sobre Σ(amount × quantity) — no línea a línea. El
  --     acumulador era numeric(15,2): con dos líneas de 0,333 kg a $999
  --     (332,667 c/u) el cargo, la caja, el banco y el evento contable daban
  --     665,34 mientras la venta suma 665,334 y la factura round(Σ) = 665,33
  --     (redteam-3a/10-probe-head). Previo a este PR; D-F′ lo vuelve la norma
  --     (las líneas en g/mL tienen total sub-centavo casi siempre).
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT id INTO v_pm_credit FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'credit' AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  IF v_pm_credit IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta no tiene una forma de pago credit sembrada (v3-provisioning-seed)';
  END IF;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_a, 'Proveedor Gate VUC') RETURNING id INTO v_supplier;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Queso VUC P1 (kg)', 'VUC-TOT1', 600.00, 999.00, v_u_kg) RETURNING id INTO v_p_tot;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Queso VUC P2 (kg)', 'VUC-TOT2', 600.00, 999.00, v_u_kg) RETURNING id INTO v_p_tot2;
  PERFORM public.rpc_adjust_branch_stock(v_p_tot,  v_branch_a, 20, 'seed gate VUC P');
  PERFORM public.rpc_adjust_branch_stock(v_p_tot2, v_branch_a, 20, 'seed gate VUC P');
  v_jsonb := jsonb_build_array(
    jsonb_build_object('product_id', v_p_tot,  'amount', 999, 'quantity', 0.333, 'unit_id', v_u_kg),
    jsonb_build_object('product_id', v_p_tot2, 'amount', 999, 'quantity', 0.333, 'unit_id', v_u_kg));

  -- P.1 alta de venta a crédito (rpc_create_sale_operation_v2): cargo y evento = round(Σ) = 665,33.
  v_result := public.rpc_create_sale_operation('vuc-p1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    v_jsonb, v_branch_a, NULL, v_pm_credit);
  v_op := (v_result->>'operation_id')::uuid;
  SELECT round(sum(total), 2) INTO v_val FROM public.sales WHERE operation_id = v_op;
  SELECT sum(amount) INTO v_amount FROM public.customer_account_movements WHERE reference_id = v_op;
  SELECT (payload->>'total')::numeric INTO v_total FROM public.events WHERE aggregate_id = v_op AND event_type = 'SaleOperationCreated';
  IF v_val IS DISTINCT FROM 665.33 OR v_amount IS DISTINCT FROM 665.33 OR v_total IS DISTINCT FROM 665.33 THEN
    v_failures := v_failures || format('P.1 venta a crédito 2 × 0,333 kg a $999: round(Σ total)=%s cargo=%s evento=%s, esperaba 665.33 los tres', v_val, v_amount, v_total);
  END IF;
  -- P.2 la misma venta por la rama legacy del kill-switch (sale_items_rpc_v2=false):
  --     el cargo (la rama legacy no emite evento contable).
  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
  VALUES (v_account_a, 'sale_items_rpc_v2', false);
  v_result := public.rpc_create_sale_operation('vuc-p2-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    v_jsonb, v_branch_a, NULL, v_pm_credit);
  DELETE FROM public.account_feature_flags WHERE account_id = v_account_a AND flag_key = 'sale_items_rpc_v2';
  v_op := (v_result->>'operation_id')::uuid;
  SELECT sum(amount) INTO v_amount FROM public.customer_account_movements WHERE reference_id = v_op;
  IF v_amount IS DISTINCT FROM 665.33 THEN
    v_failures := v_failures || format('P.2 rama legacy a crédito: cargo=%s, esperaba 665.33', v_amount);
  END IF;
  -- P.3 alta de compra a crédito con proveedor: cargo al proveedor y evento = 665,33.
  v_result := public.rpc_create_purchase_operation('vuc-p3-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUC P.3',
    v_jsonb, v_branch_a, NULL, v_pm_credit, NULL, v_supplier);
  v_op := (v_result->>'operation_id')::uuid;
  SELECT sum(abs(amount)) INTO v_amount FROM public.supplier_account_movements WHERE reference_id = v_op;
  SELECT (payload->>'total')::numeric INTO v_total FROM public.events WHERE aggregate_id = v_op AND event_type = 'PurchaseCreated';
  IF v_amount IS DISTINCT FROM 665.33 OR v_total IS DISTINCT FROM 665.33 THEN
    v_failures := v_failures || format('P.3 compra a crédito: cargo al proveedor=%s evento=%s, esperaba 665.33 los dos', v_amount, v_total);
  END IF;
  -- P.4 edición de una venta SIN cambios: el evento pendiente se reescribe con round(Σ) = 665,33.
  v_result := public.rpc_create_sale_operation('vuc-p4-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    v_jsonb, v_branch_a, NULL);
  v_op := (v_result->>'operation_id')::uuid;
  SELECT array_agg(id ORDER BY id) INTO v_ids_p FROM public.sales WHERE operation_id = v_op;
  v_result := public.rpc_atomic_update_sale_operation(v_ids_p, NULL, CURRENT_DATE, 'ARS', v_jsonb);
  v_op2 := (v_result->>'operation_id')::uuid;
  SELECT (payload->>'total')::numeric INTO v_total FROM public.events WHERE aggregate_id = v_op2;
  SELECT round(sum(total), 2) INTO v_val FROM public.sales WHERE operation_id = v_op2;
  IF v_total IS DISTINCT FROM 665.33 OR v_val IS DISTINCT FROM 665.33 THEN
    v_failures := v_failures || format('P.4 edición sin cambios: evento=%s round(Σ total)=%s, esperaba 665.33 los dos', v_total, v_val);
  END IF;
  -- P.5 control: con importes al centavo nada cambia (2 × 1 kg a $999 = 1.998).
  v_result := public.rpc_create_sale_operation('vuc-p5-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_tot, 'amount', 999, 'quantity', 1, 'unit_id', v_u_kg),
                      jsonb_build_object('product_id', v_p_tot2, 'amount', 999, 'quantity', 1, 'unit_id', v_u_kg)),
    v_branch_a, NULL, v_pm_credit);
  SELECT sum(amount) INTO v_amount FROM public.customer_account_movements WHERE reference_id = (v_result->>'operation_id')::uuid;
  IF v_amount IS DISTINCT FROM 1998 THEN v_failures := v_failures || format('P.5 control al centavo: cargo=%s, esperaba 1998', v_amount); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (P) total de dinero redondeado una vez: 5/5'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Cleanup (DELETE FROM accounts cascadea; branches/accounts con guard →
  -- replica; events/email_logs/idempotency no cascadean por cuenta).
  -- ═══════════════════════════════════════════════════════════════════════
  DELETE FROM public.events                WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b)
                                              OR metadata::text LIKE '%' || v_account_a::text || '%'
                                              OR metadata::text LIKE '%' || v_account_b::text || '%';
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.units_of_measure      WHERE id = v_u_alien;
  SET session_replication_role = replica;
  -- sales_orders.created_by → auth.users sin cascade: las órdenes del POS
  -- (incluida la cancelada por el borrado de C.6) hay que retirarlas antes
  -- del usuario. El resto cascadea desde accounts.
  DELETE FROM public.document_status_history WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.sales_order_items     WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.sales_orders          WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.branches              WHERE account_id IN (v_account_a, v_account_b);
  -- Bajo replica la RI está apagada: nada cascadea desde accounts. Lo que no
  -- cuelga de auth.users por user_id se retira explícito (auditoría post-apply:
  -- dejaba 7 unidades, 7 formas de pago, 7 categorías y 3 audit_logs por corrida).
  DELETE FROM public.units_of_measure      WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.customer_account_movements WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.customer_accounts     WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.supplier_account_movements WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.supplier_accounts     WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.suppliers             WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.payment_methods       WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.product_categories    WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.audit_logs            WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
  -- El cascade desde auth.users (fuera de replica) dispara los triggers de
  -- auditoría de lo que borra: el rastro llega DESPUÉS del delete de arriba.
  DELETE FROM public.audit_logs            WHERE account_id IN (v_account_a, v_account_b);
  -- Unidades de SISTEMA: sólo las que sembró este gate (nada las referencia ya).
  DELETE FROM public.units_of_measure      WHERE id = ANY(v_sys_seeded);

  -- ═══════════════════════════════════════════════════════════════════════
  -- (H) Residuo cero: el cleanup no deja filas del fixture en ninguna tabla
  -- que el gate escribe (por cuenta Y por usuario — un borrado bajo replica
  -- no cascadea, así que lo que cuelga sólo de user_id también cuenta).
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  FOR v_txt, v_cnt IN
    SELECT 'products', count(*)::int FROM public.products
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'branch_stock', count(*)::int FROM public.branch_stock
      WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'stock_movements', count(*)::int FROM public.stock_movements
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'sales', count(*)::int FROM public.sales
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'purchases', count(*)::int FROM public.purchases
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'sale_items', count(*)::int FROM public.sale_items
      WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'sales_order_items', count(*)::int FROM public.sales_order_items
      WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'units_of_measure', count(*)::int FROM public.units_of_measure
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
         OR id = v_u_alien OR id = ANY(v_sys_seeded)
    UNION ALL SELECT 'payment_methods', count(*)::int FROM public.payment_methods
      WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'customer_account_movements', count(*)::int FROM public.customer_account_movements
      WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'supplier_account_movements', count(*)::int FROM public.supplier_account_movements
      WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'suppliers', count(*)::int FROM public.suppliers
      WHERE account_id IN (v_account_a, v_account_b)
  LOOP
    IF v_cnt <> 0 THEN
      v_failures := v_failures || format('H residuo: %s filas del fixture en %s tras el cleanup', v_cnt, v_txt);
    END IF;
  END LOOP;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (H) residuo cero: 12/12 tablas'; END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE ventas-unidades-conversion FAILED (% fallos):\n  %',
      array_length(v_failures, 1), array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE ventas-unidades-conversion: PASS';

EXCEPTION WHEN OTHERS THEN
  BEGIN
    DELETE FROM public.events                WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b)
                                                OR metadata::text LIKE '%' || v_account_a::text || '%'
                                                OR metadata::text LIKE '%' || v_account_b::text || '%';
    DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
    DELETE FROM public.units_of_measure      WHERE id = v_u_alien;
    SET session_replication_role = replica;
    DELETE FROM public.document_status_history WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.sales_order_items     WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.sales_orders          WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.branches              WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.units_of_measure      WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.customer_account_movements WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.customer_accounts     WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.supplier_account_movements WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.supplier_accounts     WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.suppliers             WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.payment_methods       WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.product_categories    WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.audit_logs            WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
    SET session_replication_role = DEFAULT;
    DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
    DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
    DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
    DELETE FROM public.audit_logs            WHERE account_id IN (v_account_a, v_account_b);
    DELETE FROM public.units_of_measure      WHERE id = ANY(v_sys_seeded);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RAISE;
END $$;
