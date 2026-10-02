-- =============================================================================
-- test_presupuestos_modulo.sql — Gate de comportamiento de la TANDA A de
-- `presupuestos-modulo` (migración 20261067000001_presupuestos_modulo.sql).
--
-- Regla del proyecto: toda RPC nueva necesita un gate que la EJECUTE de
-- verdad. Este archivo ejecuta, contra Postgres real y con usuarios reales
-- (owner, seller, cashier y viewer con membresía en account_members y roles en
-- account_member_roles), las seis RPCs nuevas (rpc_create_quote,
-- rpc_update_quote, rpc_transition_quote, rpc_delete_quote,
-- rpc_set_default_quote_validity, rpc_commercial_issuer), el barrido
-- _expire_overdue_quotes y el backfill defensivo
-- _quotes_backfill_number_and_validity.
--
-- Bloques (tasks.md 1.1):
--   (a) numeración interna correlativa por cuenta (D3): independiente entre
--       cuentas; un alta fallida no consume número; número explícito
--       duplicado -> 23505; número explícito mayor avanza la secuencia; INSERT
--       sin valid_until sale con el default de la cuenta; el disparador es el
--       genérico trg_assign_internal_document_number('quote'); la numeración
--       fiscal (document_sequences) no cambia.
--   (b) alta (D2): sin cliente -> P0400; cliente ajeno o dado de baja ->
--       P0404 client_not_found; producto ajeno -> P0404 product_not_found sin
--       snapshot ajeno; padre con variantes -> P0400 product_is_parent; unidad
--       incompatible -> unit_type_mismatch; unidad de otra cuenta en una línea
--       de servicio -> P0404; servicio sin descripción -> P0400; total del
--       servidor; validez por defecto; validez pasada -> P0400; sucursal ajena
--       -> P0404 / cerrada -> P0422.
--   (c) crear y editar NO tocan branch_stock, cash_movements,
--       customer_account_movements ni bank_movements.
--   (d) edición (D5): reemplazo, snapshots re-tomados, updated_at/by,
--       revision + 1, estado intacto; versión vieja -> P0409 quote_changed;
--       sin validez -> P0400 quote_valid_until_required; expired/rejected se
--       reabren a draft con historial; accepted -> P0423
--       quote_locked_converted; ampliar la validez de un abierto vencido;
--       atomicidad.
--   (e) rpc_transition_quote: draft->sent fija sent_at e historial; sent->sent
--       no-op; ->rejected con motivo; ->accepted / ->expired -> P0400.
--   (f) rpc_delete_quote: draft nunca enviado se borra; sent y draft
--       reabierto con sent_at -> P0409 quote_not_deletable; candado de cuerpo
--       (FOR UPDATE + predicado de estado en el DELETE).
--   (g) roles: cashier -> P0403 insufficient_role (antes de escribir);
--       viewer (sin rol de escritura) -> P0401; seller OK.
--   (h) SET LOCAL ROLE authenticated: INSERT/UPDATE directo sobre quotes /
--       quote_items rechazado; la RPC sí funciona con ese rol.
--   (i) _expire_overdue_quotes EJECUTADO: vence draft/sent pasados con actor
--       uuid cero y motivo, idempotente, no toca accepted.
--   (j) rpc_set_default_quote_validity: 0/366 -> P0400; seller -> P0403;
--       owner OK (y el alta siguiente usa el valor nuevo).
--   (l) regresiones: baja de un producto en un presupuesto draft -> P0B04;
--       el alta registra NULL -> draft con el creador.
--   (n) rpc_commercial_issuer como un vendedor que NO es el dueño (SET LOCAL
--       ROLE authenticated): recibe business_name y teléfono del dueño; otra
--       cuenta -> P0404; sólo las 6 claves del emisor.
--   (o) backfill: un presupuesto insertado sin disparadores queda numerado y
--       con validez; una segunda ejecución no cambia nada.
--   (k) y (m) van en bloques DO aparte, sin fixtures: ACLs y catálogo.
--
-- Patrón del proyecto: fallas acumuladas en text[], un solo RAISE al final;
-- anchors sintéticos vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod); limpieza de TODA fila con account_id de las cuentas del
-- gate y residuo cero ASERTADO.
--
-- Corre en CI: KPI_Validation.yml ("Run presupuestos modulo gate").
-- =============================================================================

CREATE OR REPLACE FUNCTION pg_temp.pm_as(p_uid uuid) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_uid IS NULL THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
  ELSE
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  END IF;
END;
$f$;

-- Línea de producto (precio unitario y subtotal explícitos).
CREATE OR REPLACE FUNCTION pg_temp.pm_line(p_product uuid, p_qty numeric, p_price numeric,
                                           p_subtotal numeric, p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', p_product, 'unit_id', p_unit, 'quantity', p_qty,
                            'price', p_price, 'subtotal', p_subtotal, 'description', NULL);
$f$;

-- Línea de servicio (sin producto).
CREATE OR REPLACE FUNCTION pg_temp.pm_service(p_description text, p_qty numeric, p_price numeric,
                                              p_subtotal numeric, p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', NULL, 'unit_id', p_unit, 'quantity', p_qty,
                            'price', p_price, 'subtotal', p_subtotal, 'description', p_description);
$f$;

DO $$
DECLARE
  v_failures      text[] := '{}';
  v_fail_before   integer;

  -- Usuarios
  v_owner_a       uuid := gen_random_uuid();
  v_owner_b       uuid := gen_random_uuid();
  v_seller        uuid := gen_random_uuid();
  v_cashier       uuid := gen_random_uuid();
  v_viewer        uuid := gen_random_uuid();
  v_users         uuid[];
  v_accounts      uuid[];

  v_account_a     uuid;
  v_account_b     uuid;
  v_member        uuid;

  -- Catálogo A
  v_branch_a      uuid;
  v_branch_closed uuid;
  v_client_a      uuid;
  v_client_a2     uuid;
  v_client_dead   uuid;
  v_p1            uuid;
  v_p2            uuid;
  v_parent        uuid;
  v_variant       uuid;
  v_p_unit        uuid;   -- base 'u'
  v_kg            uuid;
  v_g             uuid;
  v_u             uuid;

  -- Catálogo B
  v_branch_b      uuid;
  v_client_b      uuid;
  v_product_b     uuid;
  v_unit_b        uuid;

  v_today         date := public.reporting_local_today();
  v_result        jsonb;
  v_q             uuid;
  v_q2            uuid;
  v_q3            uuid;
  v_qx            uuid;
  v_e1            uuid;
  v_e2            uuid;
  v_e3            uuid;
  v_e4            uuid;
  v_n             bigint;
  v_n2            bigint;
  v_val           numeric;
  v_text          text;
  v_date          date;
  v_ts            timestamptz;
  v_ts2           timestamptz;
  v_state         text;
  v_msg           text;
  v_table         text;
  v_def           text;
  v_rev           integer;
  v_docseq_before bigint;
  v_stock_before  numeric;
  v_cash_before   bigint;
  v_cam_before    bigint;
  v_bank_before   bigint;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_owner_b, v_seller, v_cashier, v_viewer];

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'presupuestos-modulo-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate Presupuestos ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_owner_b, 'owner-b'), (v_seller, 'seller'),
               (v_cashier, 'cashier'), (v_viewer, 'viewer')) AS u(id, tag);

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;

  -- Todas las cuentas que el alta de los 5 usuarios provisionó (para la limpieza).
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  -- seller / cashier / viewer: empleados de A con UNA sola membresía (se quita
  -- la de la cuenta que handle_new_user les provisionó), así current_account_ids()
  -- es determinista para ellos. Bajo replica no corre el invariante de owner.
  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
  WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id IN (v_seller, v_cashier, v_viewer));
  DELETE FROM public.account_members WHERE user_id IN (v_seller, v_cashier, v_viewer);
  SET session_replication_role = DEFAULT;

  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_cashier, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'cashier');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_viewer, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'viewer');

  UPDATE public.profiles SET business_name = 'Negocio Gate Dueño A', phone = '2615550101' WHERE id = v_owner_a;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at, created_at)
  VALUES (v_account_a, 'Sucursal Gate PM Cerrada', TRUE, 'closed', now(), now(), now() + interval '1 minute')
  RETURNING id INTO v_branch_closed;

  INSERT INTO public.clients (user_id, account_id, name, phone) VALUES (v_owner_a, v_account_a, 'Cliente Gate PM', '2615550202') RETURNING id INTO v_client_a;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_account_a, 'Cliente Gate PM 2') RETURNING id INTO v_client_a2;
  INSERT INTO public.clients (user_id, account_id, name, deleted_at) VALUES (v_owner_a, v_account_a, 'Cliente Gate PM Baja', now()) RETURNING id INTO v_client_dead;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_b, v_account_b, 'Cliente Gate PM B') RETURNING id INTO v_client_b;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Kilogramo PM', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Gramo PM', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Unidad PM', 'u', 'unit', 1, false) RETURNING id INTO v_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_b, 'Unidad PM B', 'u', 'unit', 1, false) RETURNING id INTO v_unit_b;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PM Producto 1', 'GPM-P1', 500, 1000) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PM Producto 2', 'GPM-P2', 40, 100) RETURNING id INTO v_p2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
  VALUES (v_owner_a, v_account_a, 'Gate PM Padre', 'GPM-PADRE', 0, 0, 'variant_only') RETURNING id INTO v_parent;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_owner_a, v_account_a, 'Gate PM Variante', 'GPM-VAR', 10, 20, v_parent, true) RETURNING id INTO v_variant;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate PM Por Unidad', 'GPM-U', 10, 20, v_u) RETURNING id INTO v_p_unit;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'GPM SECRETO DE B', 'GPM-SECRETO-B', 777, 999) RETURNING id INTO v_product_b;

  -- Stock en A (para (c): el presupuesto no lo toca aunque pida más).
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_a, 3);

  -- ═══════════════════════════════════════════════════════════════════════
  -- (b) Alta: guards y cálculo
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT COUNT(*) INTO v_docseq_before FROM public.document_sequences;
  SELECT COALESCE(SUM(quantity), 0) INTO v_stock_before FROM public.branch_stock WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_cash_before FROM public.cash_movements;
  SELECT COUNT(*) INTO v_cam_before FROM public.customer_account_movements WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_bank_before FROM public.bank_movements WHERE account_id = v_account_a;

  PERFORM pg_temp.pm_as(v_owner_a);

  -- Feliz: producto (5 u de un producto con stock 3) + servicio. El cliente no
  -- manda total: lo calcula el servidor (100,00 + 50,50 = 150,50).
  v_result := public.rpc_create_quote(
    p_client_id => v_client_a, p_branch_id => v_branch_a, p_valid_until => NULL,
    p_notes => 'Entrega a convenir',
    p_items => jsonb_build_array(pg_temp.pm_line(v_p1, 5, 20, 100.00),
                                 pg_temp.pm_service('Instalación', 1, 50.5, 50.50)));
  v_q := (v_result->>'id')::uuid;
  IF v_q IS NULL THEN
    v_failures := v_failures || 'FAIL (b): rpc_create_quote no devolvió id'::text;
  END IF;
  IF (v_result->>'number')::bigint IS DISTINCT FROM 1 THEN
    v_failures := v_failures || format('FAIL (a): el primer presupuesto de A debía ser el 1, es %s', v_result->>'number');
  END IF;
  SELECT total, valid_until, status, revision, notes INTO v_val, v_date, v_state, v_rev, v_text FROM public.quotes WHERE id = v_q;
  IF v_val IS DISTINCT FROM 150.50 THEN
    v_failures := v_failures || format('FAIL (b): total del servidor debía ser 150.50, es %s', v_val);
  END IF;
  IF v_date IS DISTINCT FROM v_today + 15 THEN
    v_failures := v_failures || format('FAIL (b): validez por defecto debía ser hoy+15 (%s), es %s', v_today + 15, v_date);
  END IF;
  IF v_state <> 'draft' OR v_rev <> 1 OR v_text IS DISTINCT FROM 'Entrega a convenir' THEN
    v_failures := v_failures || format('FAIL (b): estado/revisión/notas inesperados: %s / %s / %s', v_state, v_rev, v_text);
  END IF;
  IF jsonb_array_length(COALESCE(v_result->'items', '[]'::jsonb)) <> 2 THEN
    v_failures := v_failures || format('FAIL (b): el resultado debía traer 2 líneas, trae %s', v_result->'items');
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.quote_items
  WHERE quote_id = v_q AND product_id = v_p1 AND name_snapshot = 'Gate PM Producto 1'
    AND sku_snapshot = 'GPM-P1' AND unit_cost_snapshot = 500;
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (b): la línea de producto no congeló nombre/SKU/costo del maestro'::text;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.quote_items
  WHERE quote_id = v_q AND product_id IS NULL AND name_snapshot = 'Instalación';
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (b): la línea de servicio debía guardar su descripción en name_snapshot'::text;
  END IF;
  -- (l) historial de creación con el creador.
  SELECT COUNT(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'quote' AND document_id = v_q AND from_status IS NULL AND to_status = 'draft' AND performed_by = v_owner_a;
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (l): el alta debía registrar NULL -> draft con el creador'::text;
  END IF;

  -- Sin cliente -> P0400.
  BEGIN
    PERFORM public.rpc_create_quote(NULL, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): alta sin cliente debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'quote_client_required%' THEN
      v_failures := v_failures || format('FAIL (b): alta sin cliente -> P0400 quote_client_required, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Cliente de otra cuenta y cliente dado de baja -> P0404 client_not_found.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_b, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): alta con cliente ajeno debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0404' OR v_msg NOT LIKE 'client_not_found%' THEN
      v_failures := v_failures || format('FAIL (b): cliente ajeno -> P0404 client_not_found, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  BEGIN
    PERFORM public.rpc_create_quote(v_client_dead, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): alta con cliente dado de baja debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0404' OR v_msg NOT LIKE 'client_not_found%' THEN
      v_failures := v_failures || format('FAIL (b): cliente dado de baja -> P0404 client_not_found, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Producto de otra cuenta -> P0404 product_not_found, sin snapshot ajeno.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL,
      jsonb_build_array(pg_temp.pm_line(v_p1, 1, 10, 10), pg_temp.pm_line(v_product_b, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): alta con producto ajeno debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0404' OR v_msg NOT LIKE 'product_not_found%' THEN
      v_failures := v_failures || format('FAIL (b): producto ajeno -> P0404 product_not_found, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  SELECT COUNT(*) INTO v_n FROM public.quote_items
  WHERE name_snapshot = 'GPM SECRETO DE B' OR sku_snapshot = 'GPM-SECRETO-B' OR product_id = v_product_b;
  IF v_n <> 0 THEN
    v_failures := v_failures || format('FAIL (b): %s línea(s) con datos del producto de otra cuenta', v_n);
  END IF;

  -- Padre con variantes -> P0400 product_is_parent.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_parent, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): alta con un padre con variantes debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'product_is_parent%' THEN
      v_failures := v_failures || format('FAIL (b): padre -> P0400 product_is_parent, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Unidad incompatible: gramos sobre un producto cuya base es la unidad.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p_unit, 500, 1, 500, v_g)));
    v_failures := v_failures || 'FAIL (b): alta con unidad incompatible debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'unit_type_mismatch%' THEN
      v_failures := v_failures || format('FAIL (b): unidad incompatible -> P0400 unit_type_mismatch, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Unidad de otra cuenta en una línea de servicio -> P0404 (el helper de
  -- unidades sale temprano sin producto: el guard es propio de la RPC).
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_service('Flete', 1, 10, 10, v_unit_b)));
    v_failures := v_failures || 'FAIL (b): servicio con unidad de otra cuenta debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0404' OR v_msg NOT LIKE 'Unit of measure not found%' THEN
      v_failures := v_failures || format('FAIL (b): unidad ajena en servicio -> P0404 Unit of measure not found, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Servicio sin descripción -> P0400.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_service('   ', 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): servicio sin descripción debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'quote_service_line_description_required%' THEN
      v_failures := v_failures || format('FAIL (b): servicio sin descripción -> P0400, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Validez en el pasado -> P0400.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, v_today - 1, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): validez pasada debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'quote_valid_until_in_past%' THEN
      v_failures := v_failures || format('FAIL (b): validez pasada -> P0400 quote_valid_until_in_past, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Sucursal ajena -> P0404; cerrada -> P0422.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, v_branch_b, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): sucursal ajena debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0404' THEN
      v_failures := v_failures || format('FAIL (b): sucursal ajena -> P0404, salió %s', v_state);
    END IF;
  END;
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, v_branch_closed, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 1, 10, 10)));
    v_failures := v_failures || 'FAIL (b): sucursal cerrada debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0422' THEN
      v_failures := v_failures || format('FAIL (b): sucursal cerrada -> P0422, salió %s', v_state);
    END IF;
  END;

  -- Payload de líneas vacío -> P0400.
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL, '[]'::jsonb);
    v_failures := v_failures || 'FAIL (b): presupuesto sin líneas debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0400' THEN
      v_failures := v_failures || format('FAIL (b): sin líneas -> P0400, salió %s', v_state);
    END IF;
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (b): alta con guards de cliente/producto/padre/unidad/servicio/validez/sucursal, total del servidor y snapshots de la cuenta.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) Numeración
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  -- Las altas fallidas de (b) no consumieron número: la siguiente es la 2.
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_q2 := (v_result->>'id')::uuid;
  IF (v_result->>'number')::bigint IS DISTINCT FROM 2 THEN
    v_failures := v_failures || format('FAIL (a): tras altas fallidas el siguiente debía ser 2, es %s', v_result->>'number');
  END IF;

  -- Otra cuenta: su primer presupuesto es el 1.
  PERFORM pg_temp.pm_as(v_owner_b);
  v_result := public.rpc_create_quote(v_client_b, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_product_b, 1, 999, 999)));
  IF (v_result->>'number')::bigint IS DISTINCT FROM 1 THEN
    v_failures := v_failures || format('FAIL (a): el primer presupuesto de B debía ser el 1, es %s', v_result->>'number');
  END IF;
  PERFORM pg_temp.pm_as(v_owner_a);

  -- Número explícito duplicado -> unique_violation (escritor directo, como postgres).
  BEGIN
    INSERT INTO public.quotes (account_id, client_id, status, total, created_by, number)
    VALUES (v_account_a, v_client_a, 'draft', 0, v_owner_a, 1);
    v_failures := v_failures || 'FAIL (a): un número explícito duplicado debía fallar'::text;
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- Número explícito mayor avanza la secuencia; el INSERT sin validez sale con el default.
  INSERT INTO public.quotes (account_id, client_id, status, total, created_by, number)
  VALUES (v_account_a, v_client_a, 'draft', 0, v_owner_a, 10)
  RETURNING id, valid_until INTO v_qx, v_date;
  IF v_date IS DISTINCT FROM v_today + 15 THEN
    v_failures := v_failures || format('FAIL (a): INSERT sin valid_until debía salir con hoy+15, salió %s', v_date);
  END IF;
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_q3 := (v_result->>'id')::uuid;
  IF (v_result->>'number')::bigint IS DISTINCT FROM 11 THEN
    v_failures := v_failures || format('FAIL (a): tras el explícito 10 el siguiente debía ser 11, es %s', v_result->>'number');
  END IF;
  SELECT last_number INTO v_n FROM public.internal_document_sequences WHERE account_id = v_account_a AND document_type = 'quote';
  IF v_n IS DISTINCT FROM 11 THEN
    v_failures := v_failures || format('FAIL (a): internal_document_sequences de A debía quedar en 11, está en %s', v_n);
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.document_sequences;
  IF v_n <> v_docseq_before THEN
    v_failures := v_failures || 'FAIL (a): la numeración interna tocó document_sequences (fiscal)'::text;
  END IF;

  -- El disparador de numeración es el genérico con 'quote' como argumento.
  SELECT COUNT(*) INTO v_n
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.quotes'::regclass AND NOT t.tgisinternal
    AND t.tgfoid = 'public.trg_assign_internal_document_number'::regproc
    AND encode(t.tgargs, 'escape') = 'quote\000';
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (a): quotes no tiene el disparador genérico trg_assign_internal_document_number(''quote'')'::text;
  END IF;

  -- Tipo fuera del conjunto cerrado -> CHECK.
  BEGIN
    INSERT INTO public.internal_document_sequences (account_id, document_type, last_number) VALUES (v_account_a, 'factura', 0);
    v_failures := v_failures || 'FAIL (a): un document_type fuera del conjunto cerrado debía rechazarse'::text;
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (a): numeración correlativa por cuenta, sin consumir en altas fallidas, explícito duplicado 23505, explícito mayor avanza, default de validez y disparador genérico.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (d) Edición
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  -- El maestro cambia después de cotizar: la edición re-congela.
  UPDATE public.products SET name = 'Gate PM Producto 1 (renombrado)', cost = 600 WHERE id = v_p1;

  PERFORM pg_temp.pm_as(v_seller);
  v_result := public.rpc_update_quote(
    p_quote_id => v_q, p_expected_revision => 1, p_client_id => v_client_a2, p_branch_id => NULL,
    p_valid_until => v_today + 20, p_notes => NULL,
    p_items => jsonb_build_array(pg_temp.pm_line(v_p1, 7, 20, 140.00)));
  SELECT status, revision, total, client_id, valid_until, notes, updated_by, updated_at
  INTO v_state, v_rev, v_val, v_q2, v_date, v_text, v_q3, v_ts
  FROM public.quotes WHERE id = v_q;
  -- (v_q2/v_q3 se reusan como temporales: se restauran abajo.)
  IF v_state <> 'draft' OR v_rev <> 2 OR v_val <> 140.00 OR v_q2 <> v_client_a2 OR v_date <> v_today + 20
     OR v_text IS NOT NULL OR v_q3 IS DISTINCT FROM v_seller OR v_ts IS NULL THEN
    v_failures := v_failures || format('FAIL (d): edición en draft: estado %s rev %s total %s cliente %s validez %s notas %s updated_by %s updated_at %s',
      v_state, v_rev, v_val, v_q2, v_date, v_text, v_q3, v_ts);
  END IF;
  IF (v_result->>'revision')::int IS DISTINCT FROM 2 THEN
    v_failures := v_failures || 'FAIL (d): el resultado de la edición debía traer revision = 2'::text;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.quote_items WHERE quote_id = v_q;
  SELECT COUNT(*) INTO v_n2 FROM public.quote_items
  WHERE quote_id = v_q AND name_snapshot = 'Gate PM Producto 1 (renombrado)' AND unit_cost_snapshot = 600 AND quantity = 7;
  IF v_n <> 1 OR v_n2 <> 1 THEN
    v_failures := v_failures || format('FAIL (d): reemplazo de líneas / snapshots re-tomados: %s líneas, %s con el maestro vigente', v_n, v_n2);
  END IF;
  -- Restaurar temporales.
  SELECT id INTO v_q2 FROM public.quotes WHERE account_id = v_account_a AND number = 2;
  SELECT id INTO v_q3 FROM public.quotes WHERE account_id = v_account_a AND number = 11;

  -- Versión vieja -> P0409 quote_changed sin cambios.
  BEGIN
    PERFORM public.rpc_update_quote(v_q, 1, v_client_a, NULL, v_today + 5, 'pisada', jsonb_build_array(pg_temp.pm_line(v_p2, 1, 1, 1)));
    v_failures := v_failures || 'FAIL (d): edición con versión vieja debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0409' OR v_msg NOT LIKE 'quote_changed%' THEN
      v_failures := v_failures || format('FAIL (d): versión vieja -> P0409 quote_changed, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  SELECT revision, notes INTO v_rev, v_text FROM public.quotes WHERE id = v_q;
  IF v_rev <> 2 OR v_text IS NOT NULL THEN
    v_failures := v_failures || 'FAIL (d): la edición con versión vieja modificó el presupuesto'::text;
  END IF;

  -- Sin validez -> P0400 quote_valid_until_required.
  BEGIN
    PERFORM public.rpc_update_quote(v_q, 2, v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 1, 1)));
    v_failures := v_failures || 'FAIL (d): edición sin validez debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'quote_valid_until_required%' THEN
      v_failures := v_failures || format('FAIL (d): sin validez -> P0400 quote_valid_until_required, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  -- Atomicidad: la tercera línea es inválida (producto ajeno) -> nada cambia.
  BEGIN
    PERFORM public.rpc_update_quote(v_q, 2, v_client_a, NULL, v_today + 5, 'x',
      jsonb_build_array(pg_temp.pm_line(v_p2, 1, 1, 1), pg_temp.pm_line(v_p2, 2, 1, 2), pg_temp.pm_line(v_product_b, 1, 1, 1)));
    v_failures := v_failures || 'FAIL (d): edición con una línea ajena debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  SELECT COUNT(*) INTO v_n FROM public.quote_items WHERE quote_id = v_q AND product_id = v_p1 AND quantity = 7;
  SELECT revision INTO v_rev FROM public.quotes WHERE id = v_q;
  IF v_n <> 1 OR v_rev <> 2 THEN
    v_failures := v_failures || 'FAIL (d): una edición fallida dejó cambios a medias'::text;
  END IF;

  -- sent: editar no cambia el estado y updated_at queda posterior a sent_at.
  PERFORM public.rpc_transition_quote(v_q, 'sent', NULL);
  UPDATE public.quotes SET sent_at = now() - interval '1 hour' WHERE id = v_q;
  PERFORM public.rpc_update_quote(v_q, 2, v_client_a, v_branch_a, v_today + 20, 'reenviar',
    jsonb_build_array(pg_temp.pm_line(v_p1, 7, 20, 140.00), pg_temp.pm_line(v_p2, 1, 100, 100)));
  SELECT status, revision, updated_at, sent_at INTO v_state, v_rev, v_ts, v_ts2 FROM public.quotes WHERE id = v_q;
  IF v_state <> 'sent' OR v_rev <> 3 OR NOT (v_ts > v_ts2) THEN
    v_failures := v_failures || format('FAIL (d): editar un sent: estado %s rev %s updated_at %s sent_at %s', v_state, v_rev, v_ts, v_ts2);
  END IF;

  -- Abierto vencido sin barrer: sólo se edita ampliando la validez.
  UPDATE public.quotes SET valid_until = v_today - 1 WHERE id = v_q;
  BEGIN
    PERFORM public.rpc_update_quote(v_q, 3, v_client_a, NULL, v_today - 1, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 1, 1, 1)));
    v_failures := v_failures || 'FAIL (d): editar manteniendo una validez pasada debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'quote_valid_until_in_past%' THEN
      v_failures := v_failures || format('FAIL (d): validez pasada en la edición -> P0400, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  PERFORM public.rpc_update_quote(v_q, 3, v_client_a, NULL, v_today + 10, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 7, 20, 140.00)));
  SELECT status, valid_until INTO v_state, v_date FROM public.quotes WHERE id = v_q;
  IF v_state <> 'sent' OR v_date <> v_today + 10 THEN
    v_failures := v_failures || format('FAIL (d): ampliar la validez de un abierto vencido: estado %s validez %s', v_state, v_date);
  END IF;

  -- rejected -> la edición lo reabre a draft con historial (actor = editor).
  PERFORM public.rpc_transition_quote(v_q, 'rejected', 'precio alto');
  PERFORM public.rpc_update_quote(v_q, 4, v_client_a, NULL, v_today + 10, NULL, jsonb_build_array(pg_temp.pm_line(v_p1, 7, 20, 140.00)));
  SELECT status, revision INTO v_state, v_rev FROM public.quotes WHERE id = v_q;
  SELECT COUNT(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'quote' AND document_id = v_q AND from_status = 'rejected' AND to_status = 'draft' AND performed_by = v_seller;
  IF v_state <> 'draft' OR v_rev <> 5 OR v_n <> 1 THEN
    v_failures := v_failures || format('FAIL (d): editar un rejected debía reabrirlo a draft con historial: estado %s rev %s historial %s', v_state, v_rev, v_n);
  END IF;

  -- expired -> la edición lo reabre a draft con historial.
  UPDATE public.quotes SET status = 'expired' WHERE id = v_q2;
  SELECT revision INTO v_rev FROM public.quotes WHERE id = v_q2;
  PERFORM public.rpc_update_quote(v_q2, v_rev, v_client_a, NULL, v_today + 10, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 2, 100, 200)));
  SELECT status INTO v_state FROM public.quotes WHERE id = v_q2;
  SELECT COUNT(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'quote' AND document_id = v_q2 AND from_status = 'expired' AND to_status = 'draft' AND performed_by = v_seller;
  IF v_state <> 'draft' OR v_n <> 1 THEN
    v_failures := v_failures || format('FAIL (d): editar un expired debía reabrirlo a draft con historial: estado %s historial %s', v_state, v_n);
  END IF;

  -- accepted -> P0423 quote_locked_converted, sin cambios.
  UPDATE public.quotes SET status = 'accepted' WHERE id = v_q3;
  SELECT revision INTO v_rev FROM public.quotes WHERE id = v_q3;
  BEGIN
    PERFORM public.rpc_update_quote(v_q3, v_rev, v_client_a, NULL, v_today + 10, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 9, 1, 9)));
    v_failures := v_failures || 'FAIL (d): editar un accepted debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0423' OR v_msg NOT LIKE 'quote_locked_converted%' THEN
      v_failures := v_failures || format('FAIL (d): accepted -> P0423 quote_locked_converted, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  SELECT COUNT(*) INTO v_n FROM public.quote_items WHERE quote_id = v_q3 AND quantity = 9;
  IF v_n <> 0 THEN
    v_failures := v_failures || 'FAIL (d): la edición rechazada de un accepted cambió sus líneas'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (d): edición con reemplazo atómico, snapshots re-tomados, revisión, quote_changed, validez obligatoria, reapertura de rejected/expired y P0423 en accepted.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (e) Transiciones
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.pm_as(v_owner_a);
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_e1 := (v_result->>'id')::uuid;
  v_result := public.rpc_transition_quote(v_e1, 'sent', NULL);
  SELECT status, sent_at, revision INTO v_state, v_ts, v_rev FROM public.quotes WHERE id = v_e1;
  SELECT COUNT(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'quote' AND document_id = v_e1 AND from_status = 'draft' AND to_status = 'sent';
  IF v_state <> 'sent' OR v_ts IS NULL OR v_n <> 1 OR v_rev <> 1 THEN
    v_failures := v_failures || format('FAIL (e): draft->sent: estado %s sent_at %s historial %s revision %s', v_state, v_ts, v_n, v_rev);
  END IF;
  PERFORM public.rpc_transition_quote(v_e1, 'sent', NULL);
  SELECT COUNT(*) INTO v_n FROM public.document_status_history WHERE document_type = 'quote' AND document_id = v_e1;
  IF v_n <> 2 THEN
    v_failures := v_failures || format('FAIL (e): sent->sent debía ser no-op sin historial nuevo (hay %s filas)', v_n);
  END IF;
  PERFORM public.rpc_transition_quote(v_e1, 'rejected', 'eligió otro proveedor');
  SELECT COUNT(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'quote' AND document_id = v_e1 AND from_status = 'sent' AND to_status = 'rejected' AND reason = 'eligió otro proveedor';
  SELECT status, revision INTO v_state, v_rev FROM public.quotes WHERE id = v_e1;
  IF v_n <> 1 OR v_state <> 'rejected' OR v_rev <> 1 THEN
    v_failures := v_failures || 'FAIL (e): ->rejected debía registrar el motivo y no tocar la revisión'::text;
  END IF;
  -- ->accepted y ->expired no son destinos de la API.
  BEGIN
    PERFORM public.rpc_transition_quote(v_q2, 'accepted', NULL);
    v_failures := v_failures || 'FAIL (e): ->accepted por la API debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'quote_transition_not_allowed%' THEN
      v_failures := v_failures || format('FAIL (e): ->accepted -> P0400 quote_transition_not_allowed, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  BEGIN
    PERFORM public.rpc_transition_quote(v_q2, 'expired', NULL);
    v_failures := v_failures || 'FAIL (e): ->expired por la API debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0400' OR v_msg NOT LIKE 'quote_transition_not_allowed%' THEN
      v_failures := v_failures || format('FAIL (e): ->expired -> P0400 quote_transition_not_allowed, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  -- Un rechazado no se envía (debe reabrirse editándolo).
  BEGIN
    PERFORM public.rpc_transition_quote(v_e1, 'sent', NULL);
    v_failures := v_failures || 'FAIL (e): enviar un rejected debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0409' OR v_msg NOT LIKE 'quote_invalid_state%' THEN
      v_failures := v_failures || format('FAIL (e): enviar un rejected -> P0409 quote_invalid_state, salió %s / %s', v_state, v_msg);
    END IF;
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (e): draft->sent con sent_at e historial, sent->sent no-op, ->rejected con motivo, ->accepted/->expired P0400.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (f) Borrado
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL,
    jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100), pg_temp.pm_service('Flete', 1, 10, 10)));
  v_e2 := (v_result->>'id')::uuid;
  PERFORM public.rpc_delete_quote(v_e2);
  SELECT COUNT(*) INTO v_n FROM public.quotes WHERE id = v_e2;
  SELECT COUNT(*) INTO v_n2 FROM public.quote_items WHERE quote_id = v_e2;
  IF v_n <> 0 OR v_n2 <> 0 THEN
    v_failures := v_failures || 'FAIL (f): el borrador nunca enviado debía borrarse con sus líneas'::text;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.document_status_history WHERE document_type = 'quote' AND document_id = v_e2;
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (f): el historial del presupuesto borrado debía conservarse'::text;
  END IF;
  -- sent -> quote_not_deletable.
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_e3 := (v_result->>'id')::uuid;
  PERFORM public.rpc_transition_quote(v_e3, 'sent', NULL);
  BEGIN
    PERFORM public.rpc_delete_quote(v_e3);
    v_failures := v_failures || 'FAIL (f): borrar un sent debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0409' OR v_msg NOT LIKE 'quote_not_deletable%' THEN
      v_failures := v_failures || format('FAIL (f): sent -> P0409 quote_not_deletable, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  -- draft reabierto que ya se envió (v_q: sent -> rejected -> draft) -> quote_not_deletable.
  BEGIN
    PERFORM public.rpc_delete_quote(v_q);
    v_failures := v_failures || 'FAIL (f): borrar un draft reabierto con sent_at debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0409' OR v_msg NOT LIKE 'quote_not_deletable%' THEN
      v_failures := v_failures || format('FAIL (f): draft reabierto -> P0409 quote_not_deletable, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  SELECT COUNT(*) INTO v_n FROM public.quotes WHERE id IN (v_e3, v_q);
  IF v_n <> 2 THEN
    v_failures := v_failures || 'FAIL (f): un borrado rechazado eliminó el presupuesto'::text;
  END IF;
  -- Candado de cuerpo: lock y predicado de estado en el propio DELETE.
  v_def := pg_get_functiondef('public.rpc_delete_quote(uuid)'::regprocedure);
  IF v_def !~ 'FOR UPDATE'
     OR v_def !~* 'DELETE\s+FROM\s+public\.quotes[^;]*status\s*=\s*''draft''[^;]*sent_at\s+IS\s+NULL' THEN
    v_failures := v_failures || 'FAIL (f): rpc_delete_quote debe tomar FOR UPDATE y borrar con status = ''draft'' AND sent_at IS NULL en el DELETE'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (f): borrado sólo de borradores nunca enviados, bajo lock y con el predicado de estado en el DELETE.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g) Roles
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT COUNT(*) INTO v_n2 FROM public.quotes WHERE account_id = v_account_a;
  PERFORM pg_temp.pm_as(v_cashier);
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
    v_failures := v_failures || 'FAIL (g): el cashier no debía crear'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0403' OR v_msg NOT LIKE 'insufficient_role%' THEN
      v_failures := v_failures || format('FAIL (g): cashier crea -> P0403 insufficient_role, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  SELECT revision INTO v_rev FROM public.quotes WHERE id = v_q;
  BEGIN
    PERFORM public.rpc_update_quote(v_q, v_rev, v_client_a, NULL, v_today + 3, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
    v_failures := v_failures || 'FAIL (g): el cashier no debía editar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0403' OR v_msg NOT LIKE 'insufficient_role%' THEN
      v_failures := v_failures || format('FAIL (g): cashier edita -> P0403 insufficient_role, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  BEGIN
    PERFORM public.rpc_delete_quote(v_q2);
    v_failures := v_failures || 'FAIL (g): el cashier no debía borrar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0403' OR v_msg NOT LIKE 'insufficient_role%' THEN
      v_failures := v_failures || format('FAIL (g): cashier borra -> P0403 insufficient_role, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  BEGIN
    PERFORM public.rpc_transition_quote(v_q2, 'sent', NULL);
    v_failures := v_failures || 'FAIL (g): el cashier no debía enviar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0403' THEN
      v_failures := v_failures || format('FAIL (g): cashier envía -> P0403, salió %s', v_state);
    END IF;
  END;
  PERFORM pg_temp.pm_as(v_viewer);
  BEGIN
    PERFORM public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
    v_failures := v_failures || 'FAIL (g): el viewer no debía crear'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0401' THEN
      v_failures := v_failures || format('FAIL (g): viewer crea -> P0401, salió %s', v_state);
    END IF;
  END;
  -- Un usuario de otra cuenta no ve el presupuesto: P0404 (indistinguible).
  PERFORM pg_temp.pm_as(v_owner_b);
  BEGIN
    PERFORM public.rpc_update_quote(v_q2, 1, v_client_b, NULL, v_today + 3, NULL, jsonb_build_array(pg_temp.pm_line(v_product_b, 1, 1, 1)));
    v_failures := v_failures || 'FAIL (g): otra cuenta no debía editar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0404' OR v_msg NOT LIKE 'quote_not_found%' THEN
      v_failures := v_failures || format('FAIL (g): otra cuenta edita -> P0404 quote_not_found, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  BEGIN
    PERFORM public.rpc_delete_quote(v_q2);
    v_failures := v_failures || 'FAIL (g): otra cuenta no debía borrar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0404' THEN
      v_failures := v_failures || format('FAIL (g): otra cuenta borra -> P0404, salió %s', v_state);
    END IF;
  END;
  SELECT COUNT(*) INTO v_n FROM public.quotes WHERE account_id = v_account_a;
  IF v_n <> v_n2 THEN
    v_failures := v_failures || 'FAIL (g): un rechazo por rol/tenencia dejó escrito un presupuesto'::text;
  END IF;
  -- El seller sí crea.
  PERFORM pg_temp.pm_as(v_seller);
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  IF v_result->>'id' IS NULL THEN
    v_failures := v_failures || 'FAIL (g): el seller debía poder crear'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (g): cashier P0403 en crear/editar/borrar/enviar, viewer P0401, otra cuenta P0404, seller crea.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (c) Sin efectos sobre stock, caja, cuenta corriente ni banco
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT COALESCE(SUM(quantity), 0) INTO v_val FROM public.branch_stock WHERE account_id = v_account_a;
  IF v_val <> v_stock_before THEN
    v_failures := v_failures || format('FAIL (c): branch_stock cambió (%s -> %s)', v_stock_before, v_val);
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.cash_movements;
  IF v_n <> v_cash_before THEN
    v_failures := v_failures || 'FAIL (c): cash_movements cambió'::text;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.customer_account_movements WHERE account_id = v_account_a;
  IF v_n <> v_cam_before THEN
    v_failures := v_failures || 'FAIL (c): customer_account_movements cambió'::text;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.bank_movements WHERE account_id = v_account_a;
  IF v_n <> v_bank_before THEN
    v_failures := v_failures || 'FAIL (c): bank_movements cambió'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (c): crear y editar presupuestos (incluso por encima del stock) no tocan stock, caja, cuenta corriente ni banco.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (h) Escritura directa por la API de datos
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.pm_as(v_owner_a);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO public.quotes (account_id, client_id, status, total, created_by) VALUES (v_account_a, v_client_a, 'draft', 0, v_owner_a);
    EXECUTE 'RESET ROLE';
    v_failures := v_failures || 'FAIL (h): INSERT directo sobre quotes como authenticated debía rechazarse'::text;
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
  END;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO public.quote_items (quote_id, account_id, product_id, quantity, price, subtotal)
    VALUES (v_q, v_account_a, v_p2, 1, 1, 1);
    EXECUTE 'RESET ROLE';
    v_failures := v_failures || 'FAIL (h): INSERT directo sobre quote_items como authenticated debía rechazarse'::text;
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
  END;
  SELECT total INTO v_val FROM public.quotes WHERE id = v_q;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE public.quotes SET total = 1 WHERE id = v_q;
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
  END;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE public.quote_items SET price = 0 WHERE quote_id = v_q;
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
  END;
  SELECT COUNT(*) INTO v_n FROM public.quote_items WHERE quote_id = v_q AND price = 0;
  IF (SELECT total FROM public.quotes WHERE id = v_q) <> v_val OR v_n <> 0 THEN
    v_failures := v_failures || 'FAIL (h): un UPDATE directo como authenticated modificó quotes/quote_items'::text;
  END IF;
  -- Revisión adversarial F2: `rpc_accept_quote` no tiene consumidores en la
  -- tanda A (se retiró POST /quotes/{id}/accept) y por PostgREST dejaba al
  -- presupuesto "convertido" (accepted: inmutable, P0423) con una orden draft
  -- que ninguna pantalla muestra. Se le revoca el EXECUTE: la API de datos se
  -- rechaza por permisos, sin orden nueva y sin cambiar el estado.
  SELECT COUNT(*) INTO v_n FROM public.sales_orders WHERE account_id = v_account_a;
  SELECT status INTO v_state FROM public.quotes WHERE id = v_q;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.rpc_accept_quote(v_q);
    EXECUTE 'RESET ROLE';
    v_failures := v_failures || 'FAIL (h): rpc_accept_quote como authenticated debía rechazarse por permisos'::text;
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
  END;
  IF (SELECT COUNT(*) FROM public.sales_orders WHERE account_id = v_account_a) <> v_n
     OR (SELECT status FROM public.quotes WHERE id = v_q) IS DISTINCT FROM v_state THEN
    v_failures := v_failures || 'FAIL (h): rpc_accept_quote como authenticated dejó una orden o cambió el estado del presupuesto'::text;
  END IF;
  -- La RPC sí funciona con el rol de la API de datos (el payload se arma antes
  -- de cambiar de rol: las funciones pg_temp del gate son de postgres).
  v_result := jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100));
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, v_result);
    EXECUTE 'RESET ROLE';
    IF v_result->>'id' IS NULL THEN
      v_failures := v_failures || 'FAIL (h): rpc_create_quote como authenticated no devolvió el presupuesto'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    EXECUTE 'RESET ROLE';
    v_failures := v_failures || format('FAIL (h): rpc_create_quote como authenticated falló: %s / %s', v_state, v_msg);
  END;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (h): INSERT/UPDATE directos de authenticated rechazados; la RPC sí es invocable.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (i) Barrido de vencimiento
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_e1 := (v_result->>'id')::uuid;
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_e2 := (v_result->>'id')::uuid;
  PERFORM public.rpc_transition_quote(v_e2, 'sent', NULL);
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_e3 := (v_result->>'id')::uuid;
  UPDATE public.quotes SET status = 'accepted' WHERE id = v_e3;
  v_result := public.rpc_create_quote(v_client_a, NULL, v_today + 1, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  v_e4 := (v_result->>'id')::uuid;
  UPDATE public.quotes SET valid_until = v_today - 1 WHERE id IN (v_e1, v_e2, v_e3);

  v_n := public._expire_overdue_quotes();
  IF v_n < 2 THEN
    v_failures := v_failures || format('FAIL (i): el barrido debía vencer al menos 2 presupuestos, venció %s', v_n);
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.quotes WHERE id IN (v_e1, v_e2) AND status = 'expired';
  IF v_n <> 2 THEN
    v_failures := v_failures || 'FAIL (i): el draft y el sent vencidos debían quedar expired'::text;
  END IF;
  IF (SELECT status FROM public.quotes WHERE id = v_e3) <> 'accepted' THEN
    v_failures := v_failures || 'FAIL (i): el barrido tocó un accepted'::text;
  END IF;
  IF (SELECT status FROM public.quotes WHERE id = v_e4) <> 'draft' THEN
    v_failures := v_failures || 'FAIL (i): el barrido venció un presupuesto todavía válido'::text;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'quote' AND document_id IN (v_e1, v_e2) AND to_status = 'expired'
    AND performed_by = '00000000-0000-0000-0000-000000000000'::uuid AND reason = 'vencimiento automático';
  IF v_n <> 2 THEN
    v_failures := v_failures || format('FAIL (i): el historial del vencimiento debía llevar el actor uuid cero y el motivo (%s filas)', v_n);
  END IF;
  v_n := public._expire_overdue_quotes();
  SELECT COUNT(*) INTO v_n2 FROM public.document_status_history
  WHERE document_type = 'quote' AND document_id IN (v_e1, v_e2) AND to_status = 'expired';
  IF v_n <> 0 OR v_n2 <> 2 THEN
    v_failures := v_failures || format('FAIL (i): la segunda corrida debía ser no-op (venció %s, historial %s)', v_n, v_n2);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (i): _expire_overdue_quotes vence draft/sent pasados con actor uuid cero y motivo, es idempotente y no toca accepted.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (j) Validez por defecto
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.pm_as(v_owner_a);
  BEGIN
    PERFORM public.rpc_set_default_quote_validity(0);
    v_failures := v_failures || 'FAIL (j): 0 días debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0400' THEN v_failures := v_failures || format('FAIL (j): 0 días -> P0400, salió %s', v_state); END IF;
  END;
  BEGIN
    PERFORM public.rpc_set_default_quote_validity(366);
    v_failures := v_failures || 'FAIL (j): 366 días debía fallar'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0400' THEN v_failures := v_failures || format('FAIL (j): 366 días -> P0400, salió %s', v_state); END IF;
  END;
  PERFORM pg_temp.pm_as(v_seller);
  BEGIN
    PERFORM public.rpc_set_default_quote_validity(30);
    v_failures := v_failures || 'FAIL (j): el seller no debía cambiar la validez por defecto'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0403' OR v_msg NOT LIKE 'insufficient_role%' THEN
      v_failures := v_failures || format('FAIL (j): seller -> P0403 insufficient_role, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  IF (SELECT default_quote_validity_days FROM public.accounts WHERE id = v_account_a) <> 15 THEN
    v_failures := v_failures || 'FAIL (j): un intento rechazado cambió la validez por defecto'::text;
  END IF;
  PERFORM pg_temp.pm_as(v_owner_a);
  PERFORM public.rpc_set_default_quote_validity(30);
  IF (SELECT default_quote_validity_days FROM public.accounts WHERE id = v_account_a) <> 30 THEN
    v_failures := v_failures || 'FAIL (j): el owner debía poder fijar 30 días'::text;
  END IF;
  v_result := public.rpc_create_quote(v_client_a, NULL, NULL, NULL, jsonb_build_array(pg_temp.pm_line(v_p2, 1, 100, 100)));
  IF (v_result->>'valid_until')::date IS DISTINCT FROM v_today + 30 THEN
    v_failures := v_failures || format('FAIL (j): el alta siguiente debía usar la validez nueva (hoy+30), usó %s', v_result->>'valid_until');
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (j): rpc_set_default_quote_validity valida 1..365, exige owner/admin y el alta usa el valor nuevo.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (l) Regresión: baja de un producto incluido en un presupuesto draft
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  -- v_q está en draft (reabierto) con el producto 1; se le saca el stock primero.
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_a, -3);
  BEGIN
    UPDATE public.products SET deleted_at = now() WHERE id = v_p1;
    v_failures := v_failures || 'FAIL (l): la baja de un producto en un presupuesto draft debía rechazarse'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0B04' THEN
      v_failures := v_failures || format('FAIL (l): baja de producto en draft -> P0B04, salió %s', v_state);
    END IF;
  END;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_a, 3);
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (l): la baja de un producto incluido en un presupuesto draft sigue rechazándose con P0B04; el alta registró NULL -> draft con el creador.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (n) Emisor comercial para un vendedor que no es el dueño
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.pm_as(v_seller);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- Con la lectura directa el perfil del dueño no es visible para el vendedor.
    SELECT COUNT(*) INTO v_n FROM public.profiles WHERE id = v_owner_a AND business_name IS NOT NULL;
    v_result := public.rpc_commercial_issuer(v_account_a);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    EXECUTE 'RESET ROLE';
    v_result := NULL;
    v_failures := v_failures || format('FAIL (n): rpc_commercial_issuer como seller falló: %s / %s', v_state, v_msg);
  END;
  IF v_result IS NOT NULL THEN
    IF v_result->>'business_name' IS DISTINCT FROM 'Negocio Gate Dueño A' OR v_result->>'phone' IS DISTINCT FROM '2615550101' THEN
      v_failures := v_failures || format('FAIL (n): el seller debía recibir el negocio y el teléfono del dueño, recibió %s', v_result);
    END IF;
    SELECT string_agg(k, ',' ORDER BY k) INTO v_text FROM jsonb_object_keys(v_result) AS k;
    IF v_text IS DISTINCT FROM 'business_name,cuit,domicilio_comercial,nombre_fantasia,phone,razon_social' THEN
      v_failures := v_failures || format('FAIL (n): rpc_commercial_issuer debe devolver sólo los 6 campos del emisor, devolvió %s', v_text);
    END IF;
  END IF;
  IF v_n <> 0 THEN
    RAISE NOTICE 'NOTA (n): la RLS de profiles dejó leer el perfil del dueño al vendedor (% fila) — la RPC sigue siendo la fuente.', v_n;
  END IF;
  PERFORM pg_temp.pm_as(v_owner_b);
  BEGIN
    PERFORM public.rpc_commercial_issuer(v_account_a);
    v_failures := v_failures || 'FAIL (n): un usuario de otra cuenta no debía leer el emisor de A'::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> 'P0404' OR v_msg NOT LIKE 'account_not_found%' THEN
      v_failures := v_failures || format('FAIL (n): otra cuenta -> P0404 account_not_found, salió %s / %s', v_state, v_msg);
    END IF;
  END;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (n): rpc_commercial_issuer devuelve al vendedor no dueño el negocio y el teléfono del dueño, sólo 6 campos, y P0404 a otra cuenta.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (o) Backfill defensivo
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.pm_as(NULL);
  SET session_replication_role = replica;
  INSERT INTO public.quotes (account_id, client_id, status, total, created_by, created_at)
  VALUES (v_account_b, v_client_b, 'draft', 0, v_owner_b, now() - interval '2 days')
  RETURNING id INTO v_qx;
  SET session_replication_role = DEFAULT;
  SELECT number, valid_until INTO v_n, v_date FROM public.quotes WHERE id = v_qx;
  IF v_n IS NOT NULL OR v_date IS NOT NULL THEN
    v_failures := v_failures || 'FAIL (o): el fixture sin disparadores debía nacer sin número ni validez'::text;
  END IF;
  v_n2 := public._quotes_backfill_number_and_validity();
  SELECT number, valid_until INTO v_n, v_date FROM public.quotes WHERE id = v_qx;
  IF v_n2 < 1 OR v_n IS DISTINCT FROM 2
     OR v_date IS DISTINCT FROM ((now() - interval '2 days') AT TIME ZONE 'America/Argentina/Mendoza')::date + 15 THEN
    v_failures := v_failures || format('FAIL (o): backfill: filas %s número %s validez %s', v_n2, v_n, v_date);
  END IF;
  v_n2 := public._quotes_backfill_number_and_validity();
  IF v_n2 <> 0 OR (SELECT number FROM public.quotes WHERE id = v_qx) IS DISTINCT FROM 2 THEN
    v_failures := v_failures || format('FAIL (o): la segunda ejecución del backfill debía ser no-op (%s filas)', v_n2);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (o): el backfill numera y completa la validez de un presupuesto sin disparadores, y una segunda ejecución no cambia nada.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Limpieza (toda fila con account_id de las cuentas del gate) y residuo cero
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.pm_as(NULL);
  SET session_replication_role = replica;
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
  FOR v_table IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
  END LOOP;
  DELETE FROM public.accounts              WHERE id = ANY (v_accounts);
  DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
  DELETE FROM public.profiles              WHERE id = ANY (v_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
  DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
  DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
  DELETE FROM auth.users                   WHERE id = ANY (v_users);
  SET session_replication_role = DEFAULT;

  SELECT COUNT(*) INTO v_n FROM public.quotes WHERE account_id = ANY (v_accounts);
  SELECT COUNT(*) INTO v_n2 FROM public.internal_document_sequences WHERE account_id = ANY (v_accounts);
  IF v_n <> 0 OR v_n2 <> 0
     OR EXISTS (SELECT 1 FROM public.document_status_history WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    v_failures := v_failures || 'FAIL (limpieza): quedaron filas del gate (quotes / secuencias / historial / cuentas / usuarios)'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE PRESUPUESTOS-MODULO FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE PRESUPUESTOS-MODULO PASSED: numeración, alta, edición, transiciones, borrado, roles, escritura directa, barrido, validez por defecto, emisor y backfill — residuo cero.';

EXCEPTION
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      EXECUTE 'RESET ROLE';
      SET session_replication_role = replica;
      IF v_accounts IS NOT NULL THEN
        DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
        FOR v_table IN
          SELECT c.table_name
          FROM   information_schema.columns c
          JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
          WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
            AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
        LOOP
          EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
        END LOOP;
        DELETE FROM public.accounts WHERE id = ANY (v_accounts);
      END IF;
      DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
      DELETE FROM public.profiles              WHERE id = ANY (v_users);
      DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
      DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
      DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
      DELETE FROM auth.users                   WHERE id = ANY (v_users);
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE EXCEPTION 'GATE PRESUPUESTOS-MODULO FAILED (abortó): % / %', v_state, v_msg;
END $$;

-- ── (k) ACLs (sin fixtures) ─────────────────────────────────────────────────
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_fn   text;
  v_internal text[] := ARRAY[
    'public._next_internal_document_number(uuid, text)',
    'public._assign_internal_document_number(uuid, text, bigint)',
    'public._expire_overdue_quotes()',
    'public._quotes_backfill_number_and_validity()',
    'public._quote_validate_items(uuid, jsonb)',
    'public._quote_insert_items(uuid, uuid, jsonb)',
    'public._quote_payload(uuid)',
    'public.trg_assign_internal_document_number()',
    'public.trg_quote_default_valid_until()',
    -- F2: sin consumidores hasta la tanda B (que la reemplaza por el núcleo
    -- interno de la conversión); nunca se re-otorga.
    'public.rpc_accept_quote(uuid)'
  ];
  v_public text[] := ARRAY[
    'public.rpc_create_quote(uuid, uuid, date, text, jsonb)',
    'public.rpc_update_quote(uuid, integer, uuid, uuid, date, text, jsonb)',
    'public.rpc_transition_quote(uuid, text, text)',
    'public.rpc_delete_quote(uuid)',
    'public.rpc_set_default_quote_validity(integer)',
    'public.rpc_commercial_issuer(uuid)'
  ];
BEGIN
  FOREACH v_fn IN ARRAY v_internal LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_fn);
    ELSIF has_function_privilege('authenticated', v_fn, 'EXECUTE') OR has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por authenticated/anon', v_fn);
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY v_public LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_fn);
    ELSIF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por anon', v_fn);
    ELSIF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s NO es ejecutable por authenticated', v_fn);
    ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_fn)) THEN
      v_bad := v_bad || format('%s no es SECURITY DEFINER', v_fn);
    END IF;
  END LOOP;
  IF has_table_privilege('anon', 'public.internal_document_sequences', 'SELECT')
     OR has_table_privilege('authenticated', 'public.internal_document_sequences', 'INSERT')
     OR has_table_privilege('authenticated', 'public.internal_document_sequences', 'UPDATE') THEN
    v_bad := v_bad || 'internal_document_sequences: anon lee o authenticated escribe'::text;
  END IF;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'GATE PRESUPUESTOS-MODULO FAILED (k):\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (k): helpers internos y disparadores sin EXECUTE para authenticated/anon; las 6 RPCs SECURITY DEFINER, sin anon y con authenticated; secuencias sin escritura de la API.';
END $$;

-- ── (m) Catálogo de transiciones (sin fixtures) ─────────────────────────────
DO $$
DECLARE
  v_n int;
BEGIN
  IF public.is_terminal_status('quote', 'expired') OR public.is_terminal_status('quote', 'rejected') THEN
    RAISE EXCEPTION 'GATE PRESUPUESTOS-MODULO FAILED (m): expired/rejected siguen marcados terminales para quote';
  END IF;
  IF NOT public.is_terminal_status('quote', 'accepted') THEN
    RAISE EXCEPTION 'GATE PRESUPUESTOS-MODULO FAILED (m): accepted debía ser terminal para quote';
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.document_status_transitions
  WHERE document_type = 'quote' AND from_status IN ('expired', 'rejected') AND to_status = 'draft'
    AND allowed_role @> ARRAY['seller', 'admin', 'owner'] AND cardinality(allowed_role) = 3
    AND NOT requires_reason AND NOT is_terminal_to;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'GATE PRESUPUESTOS-MODULO FAILED (m): faltan las filas de reapertura expired/rejected -> draft (hay %)', v_n;
  END IF;
  -- Invariante del seed (gate (e) de 20260807000001): ninguna transición sale
  -- de un estado terminal. Se exige para quote, el tipo de este change. El
  -- catálogo vivo YA lo viola fuera de quote — sales_order: draft->confirmed
  -- está marcada terminal y existe confirmed->canceled (v3-rbac-multirole
  -- parte B) —; preexistente, fuera de alcance: se informa, no se corrige acá.
  SELECT COUNT(*) INTO v_n FROM public.document_status_transitions t
  WHERE t.document_type = 'quote' AND t.from_status IS NOT NULL
    AND public.is_terminal_status(t.document_type, t.from_status);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE PRESUPUESTOS-MODULO FAILED (m): % transición(es) de quote salen de un estado terminal', v_n;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.document_status_transitions t
  WHERE t.document_type <> 'quote' AND t.from_status IS NOT NULL
    AND public.is_terminal_status(t.document_type, t.from_status);
  IF v_n <> 0 THEN
    RAISE NOTICE 'NOTA (m): % transición(es) fuera de quote salen de un estado terminal (preexistente: sales_order confirmed->canceled).', v_n;
  END IF;
  RAISE NOTICE 'PASS (m): quote tiene a accepted como único terminal, la reapertura expired|rejected -> draft está catalogada y ninguna transición de quote sale de un terminal.';
END $$;
