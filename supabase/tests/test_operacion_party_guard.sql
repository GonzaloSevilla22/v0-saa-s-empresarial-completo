-- =============================================================================
-- GATE: test_operacion_party_guard.sql (11 bloques: (1)(2)(2b)(3)(4)(5)(6)(7)
-- (8)(9)(10) — RONDA 2: v_blocks_run cuenta los PASS realmente ejercitados y
-- assertea 11/11 antes del resumen final, para que una degradación temprana
-- silenciosa (ver "Degrade-don't-fail" más abajo) no quede en verde.
-- CHANGE: operacion-party-guard (fix ad-hoc, 2026-09-10) — último candidato
-- de código del programa "cero candidatos" del PO. Cierra OQ-4 de
-- cuenta-corriente-party-guard (archivada 2026-08-23): la venta/compra AL
-- CONTADO con client_id/supplier_id AJENO no tenía guard — no crea saldo ni
-- asiento contra un tercero (eso ya lo cerraba el choke point de crédito de
-- cuenta-corriente-party-guard), pero dejaba una fila mala en
-- sales/purchases/sales_orders.
--
-- Por qué "al contado" y no "a crédito": test_cuenta_corriente_party_guard.sql
-- (2.5/2.6) ya prueba que una venta a CRÉDITO con client_id ajeno se rechaza
-- con P0404 — pero por el choke point c30_get_or_create_customer_account, que
-- sólo se invoca cuando el kind derivado es 'credit' (vía
-- _pay_register_party_charge, DESPUÉS de insertar en `sales`; el rechazo
-- revierte igual porque toda la RPC corre en una sola transacción). Para
-- cualquier OTRO kind (cash/transfer/card/wallet/other/sin imputar) ese choke
-- point nunca se invoca: el client_id ajeno se escribía en `sales.client_id`
-- sin ningún chequeo y la fila quedaba. Este gate ejercita exactamente ESE
-- camino — sin payment_method_id, sin kind — para no depender del choke point
-- de crédito en ninguno de los asserts de rechazo.
--
--   (1) rpc_create_sale_operation_v2 (FORMULARIO) + cliente ajeno, SIN
--       payment_method_id (kind derivado = NULL, no 'credit') → P0404 y cero
--       filas nuevas en sales / sale_items / stock_movements / events. El
--       mensaje se assertea contra el literal 'client_not_found:' (RONDA 1,
--       finding NIT) — SQLSTATE solo no alcanza para probar que el rechazo
--       vino del guard nuevo y no de otro P0404 de la misma función.
--   (2) rpc_quick_sale (POS, vía _c29_confirm_order_core) + cliente ajeno,
--       payment_method='other' (kind ≠ credit) → P0404 y ninguna sales_order
--       con ese client_id.
--   (2b) rpc_accept_quote (PRESUPUESTO → ACEPTAR) + cliente ajeno [RONDA 1,
--       MAJOR] — reproduce el camino completo: un quote con client_id ajeno
--       (quotes no valida tenencia al crearse) se acepta con
--       rpc_accept_quote → debía dejar una fila sales_orders cross-tenant
--       antes de este fix; ahora P0404, cero sales_orders con ese client_id
--       y el quote queda intacto (status sin transicionar a 'accepted').
--   (3) rpc_atomic_update_sale_operation (EDICIÓN) + cliente ajeno sobre una
--       venta PROPIA existente → P0404, y la venta original queda intacta
--       (mismo client_id, mismo total de filas — el REVERSE+APPLY nunca
--       arrancó).
--   (4) rpc_create_purchase_operation + proveedor ajeno → sigue P0404 (D6 de
--       compras-proveedor-cuenta-corriente, VERIFICADO, no tocado por este
--       fix) — control de no regresión del lado compra.
--   (5) id INEXISTENTE (ghost) → mismo P0404 y MISMO texto que "ajeno" (no
--       filtra qué ids existen en otros tenants). Mismo candado de mensaje
--       que (1): el texto tiene que empezar con 'client_not_found:'.
--   (6) CONTROL POSITIVO — cliente propio ACTIVO, cliente propio DADO DE
--       BAJA (deleted_at) y client_id NULL: los tres siguen funcionando (el
--       guard no sobre-bloquea; un cliente de baja se acepta, mismo criterio
--       que el choke point c30_get_or_create_customer_account, que tampoco
--       filtra deleted_at).
--   (7) CANDADO DE CUERPO — el literal 'client_not_found' está presente en
--       las 4 funciones (RONDA 1: se suma rpc_accept_quote) y su posición
--       cae ANTES de la primera escritura real (INSERT en
--       operation_idempotency para (1)/(2), INSERT en sales para (3), INSERT
--       en sales_orders para (2b)) — sin este candado, el guard podría
--       borrarse y (1)-(3)/(2b) seguirían verdes si alguien reintrodujera el
--       choke-point-only por otro camino.
--   (8) ACL — {postgres, authenticated, service_role}, SIN anon, en las 4
--       funciones (CREATE OR REPLACE no debe haber cambiado el proacl).
--   (9) BARRIDO GLOBAL — cero sales/sales_orders/purchases/quotes cuyo
--       client_id (o supplier_id) pertenezca a otro tenant, en toda la base
--       (no sólo en los caminos que este gate ejercita). [RONDA 2, finding
--       MINOR] la cuarta consulta (quotes) es la contención del guard de
--       QuoteRepository.client_belongs_to_account, que vive en PYTHON (no en
--       una RPC) porque quotes no es una de las 3 tablas en alcance de este
--       change — sin este barrido, si ese guard se afloja el hueco vuelve en
--       silencio y este gate SQL no lo vería.
--   (10) CANDADO DE FLAG [RONDA 1, MINOR] — la rama ELSE legacy de
--       rpc_create_sale_operation (activada por account_feature_flags con
--       flag_key='sale_items_rpc_v2' en false) tiene el MISMO hueco sin
--       guardar y no se toca (regla del brief: nunca el wrapper). Candado
--       barato: 0 cuentas con ese flag en false — si algún día deja de ser
--       cero, el hueco se reabre y hay que decidir qué hacer, no descubrirlo
--       en producción.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, o si no hay sucursal sembrada, el gate emite
-- NOTICE (prefijo grepeable 'GATE DEGRADED:') y no aborta (mismo patrón que
-- test_cuenta_corriente_party_guard.sql). RONDA 2 (finding NIT): una
-- degradación temprana antes dejaba el gate en verde sin haber ejercitado un
-- solo assert — v_blocks_run cuenta los 11 PASS y el bloque final falla
-- explícitamente si no llegó a 11, así que degradar ya no puede reportarse
-- como éxito.
--
-- Cleanup: DO block separado al final, mismo patrón que
-- test_cuenta_corriente_party_guard.sql — resuelve por email, no por
-- variable heredada, para limpiar también las corridas que degradaron a
-- mitad de camino. RONDA 1 (finding MINOR): el cleanup dejaba huérfanos los
-- hijos del provisioning seed (branches/payment_methods/product_categories)
-- porque `session_replication_role = replica` desactiva también las FK
-- ON DELETE CASCADE (se implementan como triggers) — la cascada que el
-- comentario original daba por hecha nunca corría bajo `replica`. Corregido:
-- DELETE explícito de esos 3 hijos ANTES de activar `replica` (que sigue
-- haciendo falta sólo para `branches`, por trg_guard_branch_decommission).
-- =============================================================================

DO $$
DECLARE
  -- ── Tenant A (el que opera) ───────────────────────────────────────────────
  v_anchor_a_email   text := 'operacion-party-guard-a@test.local';
  v_user_a           uuid := gen_random_uuid();
  v_account_a        uuid;
  v_branch_a         uuid;
  v_product_a        uuid;
  v_client_a         uuid;  -- propio, activo
  v_client_a_deleted uuid;  -- propio, dado de baja (deleted_at)

  -- ── Tenant B (la víctima: sus ids se usan desde la sesión de A) ───────────
  v_anchor_b_email   text := 'operacion-party-guard-b@test.local';
  v_user_b           uuid := gen_random_uuid();
  v_account_b        uuid;
  v_client_b         uuid;
  v_supplier_b       uuid;

  -- ── Scratch ───────────────────────────────────────────────────────────────
  v_ghost            uuid := gen_random_uuid();
  v_rejected         boolean;
  v_sqlstate         text;
  v_msg_foreign      text;
  v_msg_ghost        text;
  v_def              text;
  v_pos_guard        integer;
  v_pos_write        integer;
  v_result           jsonb;
  v_count            integer;
  v_op_id            uuid;
  v_sale_id          uuid;
  v_sale_ids         uuid[];
  v_n_sales          integer;
  v_n_sale_items     integer;
  v_n_stock_movs     integer;
  v_n_events         integer;
  v_n_purchases      integer;
  v_n_purchase_items integer;
  -- RONDA 1: (2b) quote→accept, (7)/(8) candado de rpc_accept_quote,
  -- (10) candado de flag.
  v_quote_id         uuid;
  v_n_sales_orders   integer;
  v_quote_status     text;
  v_n_flag_off       integer;
  -- RONDA 2 (finding NIT, degrade-don't-fail): contador de bloques
  -- efectivamente ejercitados. Un RETURN temprano de degradación (anchor sin
  -- cuenta, segundo tenant no provisionado, sucursal no sembrada, auth.uid()
  -- sin resolver) deja el gate en verde sin haber corrido un solo assert —
  -- este contador convierte esa degradación silenciosa en un FAIL explícito.
  v_blocks_run       integer := 0;
BEGIN
  -- ── Anchor sintético del tenant A ─────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_anchor_a_email, now(), now(),
          jsonb_build_object('name', 'Gate Operacion Party Guard A'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudo resolver cuenta para el anchor sintético A — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Anchor sintético del tenant B (SEGUNDO tenant, la víctima) ────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_anchor_b_email, now(), now(),
          jsonb_build_object('name', 'Gate Operacion Party Guard B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_b IS NULL OR v_account_b = v_account_a THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudo provisionar un SEGUNDO tenant independiente para el anchor B — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  IF v_branch_a IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: sucursal no sembrada para el anchor A — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_opg_product__', 1000, 400, 'GATE-OPG-1')
  RETURNING id INTO v_product_a;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a, v_product_a, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_a, v_account_a, '__gate_opg_client_a__', 'active')
  RETURNING id INTO v_client_a;

  INSERT INTO public.clients (user_id, account_id, name, status, deleted_at)
  VALUES (v_user_a, v_account_a, '__gate_opg_client_a_deleted__', 'active', now())
  RETURNING id INTO v_client_a_deleted;

  -- Parte del tenant B: existe, es válida, pero NO pertenece a la cuenta A.
  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_b, v_account_b, '__gate_opg_client_b__', 'active')
  RETURNING id INTO v_client_b;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_b, '__gate_opg_supplier_b__')
  RETURNING id INTO v_supplier_b;

  -- ── Sesión sintética del tenant A (request.jwt.claims) ────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE DEGRADED: auth.uid() no resuelve al anchor A con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ══════ (1, ESTRELLA) FORMULARIO — venta AL CONTADO con cliente ajeno ═════
  -- Sin payment_method_id: v_kind queda NULL (no 'credit'), así que el choke
  -- point de cuenta corriente NUNCA se invoca — el único guard posible es el
  -- explícito que agrega este fix.
  SELECT COUNT(*) INTO v_n_sales      FROM public.sales           WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_sale_items FROM public.sale_items      WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_stock_movs FROM public.stock_movements WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_events     FROM public.events          WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key => 'gate-opg-1',
      p_client_id       => v_client_b,
      p_date            => public.reporting_local_today(),
      p_currency        => 'ARS',
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
      p_branch_id       => v_branch_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_foreign := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (1, ESTRELLA): una venta AL CONTADO (sin payment_method_id, kind != credit) del FORMULARIO con un cliente de OTRO tenant debería fallar con P0404 — hoy escribe la fila sin preguntar nada (OQ-4 de cuenta-corriente-party-guard).';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales WHERE account_id = v_account_a;
  IF v_count <> v_n_sales THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (1-sales): el rechazo dejó % filas en sales, esperaba % (sin cambios).', v_count, v_n_sales;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE account_id = v_account_a;
  IF v_count <> v_n_sale_items THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (1-sale_items): el rechazo dejó % filas en sale_items, esperaba %.', v_count, v_n_sale_items;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE account_id = v_account_a;
  IF v_count <> v_n_stock_movs THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (1-stock): el rechazo dejó % movimientos de stock, esperaba % — el descuento de kardex no debe sobrevivir al rechazo.', v_count, v_n_stock_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_a;
  IF v_count <> v_n_events THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (1-events): el rechazo dejó % eventos, esperaba %.', v_count, v_n_events;
  END IF;

  -- RONDA 1 (finding NIT): SQLSTATE solo no prueba que el rechazo vino del
  -- guard nuevo — rpc_create_sale_operation_v2 emite P0404 en al menos otros
  -- cuatro lugares (payment_method_not_found, branch_not_found, unit not
  -- found, product not found). Si el mensaje no empieza con
  -- 'client_not_found:' el guard no se ejercitó de verdad.
  IF v_msg_foreign NOT LIKE 'client_not_found:%' THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (1-mensaje): el P0404 no vino del guard de client_id, vino de: %', v_msg_foreign;
  END IF;
  RAISE NOTICE 'PASS (1, ESTRELLA): venta AL CONTADO del formulario con cliente ajeno → P0404 (client_not_found) y cero filas nuevas en sales/sale_items/stock_movements/events.';
  v_blocks_run := v_blocks_run + 1;

  -- ══════════ (2, ESTRELLA) POS — quick sale con cliente ajeno ══════════════
  -- payment_method='other', sin payment_method_id: mismo razonamiento que (1).
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key => 'gate-opg-2',
      p_client_id       => v_client_b,
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method  => 'other',
      p_branch_id       => v_branch_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (2, ESTRELLA): una venta AL CONTADO del POS con un cliente de OTRO tenant debería fallar con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales_orders WHERE client_id = v_client_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (2-orden): el rechazo dejó % sales_orders contra el cliente ajeno, esperaba 0 — la fila draft que inserta rpc_quick_sale debe revertir con el resto de la transacción.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.sales WHERE account_id = v_account_a;
  IF v_count <> v_n_sales THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (2-sales): el rechazo del POS dejó % filas en sales, esperaba % (sin cambios).', v_count, v_n_sales;
  END IF;
  RAISE NOTICE 'PASS (2, ESTRELLA): venta AL CONTADO del POS con cliente ajeno → P0404 y ninguna sales_order confirmada.';
  v_blocks_run := v_blocks_run + 1;

  -- ═══ (2b, ESTRELLA) PRESUPUESTO → ACEPTAR — cliente ajeno [RONDA 1, MAJOR] ═
  -- `quotes` no valida tenencia al crearse (POST /quotes hace un INSERT
  -- directo — QuoteRepository.create_quote — sin chequear client_id). Este
  -- INSERT reproduce EXACTAMENTE ese molde: un usuario normal, sin flags ni
  -- roles especiales, puede tener un quote propio con client_id ajeno.
  -- rpc_accept_quote copiaba ese client_id a sales_orders.client_id (tabla EN
  -- ALCANCE de este change) sin ningún guard — antes del fix, esto dejaba una
  -- fila cross-tenant que rompía el bloque (9) de este mismo gate.
  SELECT COUNT(*) INTO v_n_sales_orders FROM public.sales_orders WHERE account_id = v_account_a;

  INSERT INTO public.quotes (account_id, branch_id, client_id, status, total, created_by)
  VALUES (v_account_a, v_branch_a, v_client_b, 'draft', 1000, v_user_a)
  RETURNING id INTO v_quote_id;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_accept_quote(p_quote_id => v_quote_id);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (2b, ESTRELLA): aceptar un presupuesto con cliente de OTRO tenant debería fallar con P0404 — antes de este fix dejaba una fila sales_orders cross-tenant sin preguntar nada.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales_orders WHERE account_id = v_account_a AND client_id = v_client_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (2b-orden): el rechazo dejó % sales_orders contra el cliente ajeno, esperaba 0.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.sales_orders WHERE account_id = v_account_a;
  IF v_count <> v_n_sales_orders THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (2b-conteo): el rechazo dejó % sales_orders en total, esperaba % (sin cambios) — el INSERT INTO sales_orders debe revertir con el resto de la transacción.', v_count, v_n_sales_orders;
  END IF;

  SELECT status INTO v_quote_status FROM public.quotes WHERE id = v_quote_id;
  IF v_quote_status <> 'draft' THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (2b-quote): el quote debía quedar en status draft (rechazo revertido), quedó en %.', v_quote_status;
  END IF;
  RAISE NOTICE 'PASS (2b, ESTRELLA): aceptar un presupuesto con cliente ajeno → P0404, cero sales_orders nuevas, el quote queda intacto en draft.';
  v_blocks_run := v_blocks_run + 1;

  -- RONDA 2 (finding MINOR, bloque (9) suma `quotes` al barrido global): este
  -- quote es un FIXTURE PROPIO de (2b) — insertado a propósito con
  -- client_id de OTRO tenant para ejercitar el guard de rpc_accept_quote,
  -- no una fuga real. Sin este DELETE quedaría vivo hasta la fase de
  -- cleanup (DO block separado, al final del archivo) y el barrido (9),
  -- que corre DENTRO de este mismo DO block, lo confundiría con una
  -- violación real y haría fallar el gate contra su propio fixture.
  DELETE FROM public.quotes WHERE id = v_quote_id;

  -- ══════════ (3) EDICIÓN — reasignar a un cliente ajeno ════════════════════
  -- Primero una venta PROPIA real (cliente A), para editarla después.
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key => 'gate-opg-3-setup',
    p_client_id       => v_client_a,
    p_date            => public.reporting_local_today(),
    p_currency        => 'ARS',
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
    p_branch_id       => v_branch_a
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op_id AND account_id = v_account_a;
  IF v_sale_id IS NULL THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (3-setup): no se pudo crear la venta propia de base para el test de edición.';
  END IF;
  v_sale_ids := ARRAY[v_sale_id];

  SELECT COUNT(*) INTO v_n_sales FROM public.sales WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      p_sale_ids => v_sale_ids,
      p_client_id => v_client_b,
      p_date      => public.reporting_local_today(),
      p_currency  => 'ARS',
      p_items     => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1, 'unit_id', NULL))
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (3): editar una venta propia reasignándole un cliente de OTRO tenant debería fallar con P0404 — p_client_id es obligatorio y se escribía sin validar tenencia.';
  END IF;

  -- La venta original queda INTACTA: mismo client_id, mismo id, sin REVERSE.
  SELECT COUNT(*) INTO v_count FROM public.sales WHERE id = v_sale_id AND client_id = v_client_a;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (3-intacta): la venta original debía seguir existiendo con client_id=% sin tocar; hay % filas que matchean.', v_client_a, v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.sales WHERE account_id = v_account_a;
  IF v_count <> v_n_sales THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (3-conteo): el rechazo de la edición dejó % filas en sales, esperaba % (sin REVERSE ni APPLY).', v_count, v_n_sales;
  END IF;
  RAISE NOTICE 'PASS (3): editar una venta propia con un client_id ajeno → P0404, la venta original queda intacta (mismo client_id, sin filas nuevas ni perdidas).';
  v_blocks_run := v_blocks_run + 1;

  -- ══ (4) COMPRA — control de no regresión (D6, ya guardado, no tocado) ═════
  SELECT COUNT(*) INTO v_n_purchases      FROM public.purchases      WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_purchase_items FROM public.purchase_items WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      p_idempotency_key => 'gate-opg-4',
      p_date            => public.reporting_local_today(),
      p_description     => 'gate opg compra ajena',
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 500, 'quantity', 1)),
      p_branch_id       => v_branch_a,
      p_supplier_id     => v_supplier_b
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (4): una compra con proveedor de OTRO tenant debería seguir fallando con P0404 (D6 de compras-proveedor-cuenta-corriente, verificado y NO tocado por este fix) — posible regresión real.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.purchases WHERE account_id = v_account_a;
  IF v_count <> v_n_purchases THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (4-purchases): el rechazo dejó % filas en purchases, esperaba %.', v_count, v_n_purchases;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE account_id = v_account_a;
  IF v_count <> v_n_purchase_items THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (4-purchase_items): el rechazo dejó % filas en purchase_items, esperaba %.', v_count, v_n_purchase_items;
  END IF;
  RAISE NOTICE 'PASS (4): rpc_create_purchase_operation sigue rechazando el proveedor ajeno con P0404 (D6 intacto) — sin filas nuevas.';
  v_blocks_run := v_blocks_run + 1;

  -- ═══════ (5) id INEXISTENTE → mismo P0404 y MISMO texto que "ajeno" ═══════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key => 'gate-opg-5',
      p_client_id       => v_ghost,
      p_date            => public.reporting_local_today(),
      p_currency        => 'ARS',
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
      p_branch_id       => v_branch_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_ghost := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (5): un client_id inexistente debería fallar con P0404.';
  END IF;

  IF replace(v_msg_ghost, v_ghost::text, '<id>') IS DISTINCT FROM replace(v_msg_foreign, v_client_b::text, '<id>') THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (5-mensaje): el error de "cliente ajeno" (%) y el de "cliente inexistente" (%) deben ser indistinguibles salvo por el UUID.', v_msg_foreign, v_msg_ghost;
  END IF;

  -- RONDA 1 (finding NIT), espejo de (1-mensaje): sin este candado, un ghost
  -- que cayera en OTRO P0404 (p.ej. branch_not_found, que no lleva UUID)
  -- también pasaría la comparación de arriba sin haber ejercitado el guard.
  IF v_msg_ghost NOT LIKE 'client_not_found:%' THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (5-mensaje-guard): el P0404 del id inexistente no vino del guard de client_id, vino de: %', v_msg_ghost;
  END IF;
  RAISE NOTICE 'PASS (5): id ajeno e id inexistente producen el MISMO P0404 (client_not_found) con el MISMO texto.';
  v_blocks_run := v_blocks_run + 1;

  -- ══════ (6) CONTROL POSITIVO — propio activo, propio de baja, NULL ════════
  SELECT COUNT(*) INTO v_n_sales FROM public.sales WHERE account_id = v_account_a;

  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key => 'gate-opg-6a',
    p_client_id       => v_client_a,
    p_date            => public.reporting_local_today(),
    p_currency        => 'ARS',
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
    p_branch_id       => v_branch_a
  ) INTO v_result;
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (6a): venta con cliente PROPIO activo debería registrar de verdad (replayed=false).';
  END IF;

  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key => 'gate-opg-6b',
    p_client_id       => v_client_a_deleted,
    p_date            => public.reporting_local_today(),
    p_currency        => 'ARS',
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
    p_branch_id       => v_branch_a
  ) INTO v_result;
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (6b): venta con cliente PROPIO dado de baja debería seguir registrando (mismo criterio que el choke point c30_get_or_create_customer_account, que tampoco filtra deleted_at) — el guard no debe sobre-bloquear.';
  END IF;

  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key => 'gate-opg-6c',
    p_client_id       => NULL,
    p_date            => public.reporting_local_today(),
    p_currency        => 'ARS',
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
    p_branch_id       => v_branch_a
  ) INTO v_result;
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (6c): venta con client_id NULL debería seguir registrando (client_id sigue siendo opcional).';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales WHERE account_id = v_account_a;
  IF v_count <> v_n_sales + 3 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (6-conteo): esperaba % ventas nuevas (activo + de baja + NULL), hay %.', v_n_sales + 3, v_count;
  END IF;
  RAISE NOTICE 'PASS (6): control positivo — cliente propio ACTIVO, cliente propio DADO DE BAJA y client_id NULL siguen funcionando; el guard no sobre-bloquea.';
  v_blocks_run := v_blocks_run + 1;

  -- ══ (7) CANDADO DE CUERPO — el guard existe y corre ANTES de la 1ª escritura ══
  v_def := pg_get_functiondef('public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)'::regprocedure);
  v_pos_guard := position('client_not_found' in v_def);
  v_pos_write := position('INSERT INTO public.operation_idempotency' in v_def);
  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-v2-cuerpo): rpc_create_sale_operation_v2 perdió el guard explícito (no aparece client_not_found en el cuerpo vivo).';
  END IF;
  IF v_pos_write = 0 OR NOT (v_pos_guard < v_pos_write) THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-v2-orden): el guard de client_id debe ir ANTES del INSERT en operation_idempotency. Posiciones: guard=%, idempotencia=%.', v_pos_guard, v_pos_write;
  END IF;

  v_def := pg_get_functiondef('public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid)'::regprocedure);
  v_pos_guard := position('client_not_found' in v_def);
  v_pos_write := position('INSERT INTO public.operation_idempotency' in v_def);
  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-core-cuerpo): _c29_confirm_order_core perdió el guard explícito.';
  END IF;
  IF v_pos_write = 0 OR NOT (v_pos_guard < v_pos_write) THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-core-orden): el guard de client_id debe ir ANTES del INSERT en operation_idempotency. Posiciones: guard=%, idempotencia=%.', v_pos_guard, v_pos_write;
  END IF;

  v_def := pg_get_functiondef('public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)'::regprocedure);
  v_pos_guard := position('client_not_found' in v_def);
  -- RONDA 2 (finding NIT): la PRIMERA escritura real de esta función es el
  -- `DELETE FROM public.sales` que revierte las líneas viejas — el
  -- `INSERT INTO public.sales` de la reaplicación va DESPUÉS. Anclar sólo en
  -- el INSERT dejaba pasar un guard movido a cualquier punto entre el DELETE
  -- y el INSERT (después de borrar, antes de reinsertar) sin que el mensaje
  -- lo reflejara. El ancla es el mínimo no nulo entre los dos.
  v_pos_write := LEAST(
    COALESCE(NULLIF(position('DELETE FROM' in v_def), 0), 2147483647),
    COALESCE(NULLIF(position('INSERT INTO public.sales' in v_def), 0), 2147483647)
  );
  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-update-cuerpo): rpc_atomic_update_sale_operation perdió el guard explícito.';
  END IF;
  IF v_pos_write = 2147483647 OR NOT (v_pos_guard < v_pos_write) THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-update-orden): el guard de client_id debe ir ANTES de la primera escritura real (DELETE de reversa o INSERT en sales). Posiciones: guard=%, escritura=%.', v_pos_guard, v_pos_write;
  END IF;

  -- RONDA 1 (finding MAJOR, candado de cuerpo del guard nuevo en rpc_accept_quote).
  v_def := pg_get_functiondef('public.rpc_accept_quote(uuid)'::regprocedure);
  v_pos_guard := position('client_not_found' in v_def);
  v_pos_write := position('INSERT INTO public.sales_orders' in v_def);
  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-quote-cuerpo): rpc_accept_quote perdió el guard explícito (no aparece client_not_found en el cuerpo vivo).';
  END IF;
  IF v_pos_write = 0 OR NOT (v_pos_guard < v_pos_write) THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (7-quote-orden): el guard de client_id debe ir ANTES del INSERT en sales_orders. Posiciones: guard=%, insert=%.', v_pos_guard, v_pos_write;
  END IF;
  RAISE NOTICE 'PASS (7): las 4 funciones conservan el guard explícito de client_id, ubicado ANTES de la primera escritura real.';
  v_blocks_run := v_blocks_run + 1;

  -- ═══════════════════════ (8) ACL — sin cambios ════════════════════════════
  IF has_function_privilege('anon', 'public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_accept_quote(uuid)'::regprocedure, 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (8-acl): ninguna de las 4 funciones debe ser EXECUTE-able por anon.';
  END IF;
  IF NOT (has_function_privilege('authenticated', 'public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('authenticated', 'public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.rpc_accept_quote(uuid)'::regprocedure, 'EXECUTE'))
  THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (8-acl-authenticated): las 4 funciones deben seguir siendo EXECUTE-ables por authenticated (CREATE OR REPLACE no debe haber tocado el proacl).';
  END IF;
  RAISE NOTICE 'PASS (8): ACL sin cambios en las 4 funciones — EXECUTE para authenticated/service_role/postgres, sin anon.';
  v_blocks_run := v_blocks_run + 1;

  -- ══ (9) BARRIDO GLOBAL — coherencia (account_id, client_id) en toda la base ══
  SELECT COUNT(*) INTO v_count
  FROM public.sales s
  JOIN public.clients c ON c.id = s.client_id
  WHERE c.account_id IS DISTINCT FROM s.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (9-sales): hay % filas de sales cuyo cliente pertenece a otro tenant — el invariante está roto en la base entera.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.sales_orders so
  JOIN public.clients c ON c.id = so.client_id
  WHERE c.account_id IS DISTINCT FROM so.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (9-sales_orders): hay % filas de sales_orders cuyo cliente pertenece a otro tenant.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.purchases p
  JOIN public.suppliers s ON s.id = p.supplier_id
  WHERE s.account_id IS DISTINCT FROM p.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (9-purchases): hay % filas de purchases cuyo proveedor pertenece a otro tenant.', v_count;
  END IF;

  -- RONDA 2 (finding MINOR): `quotes` NO es una de las 3 tablas en alcance de
  -- este change (sales/sales_orders/purchases) y su guard vive en PYTHON
  -- (QuoteRepository.client_belongs_to_account, backend/services/quotes.py),
  -- no en una RPC — el resto de este archivo no lo ejercita. Sin este quinto
  -- barrido, si mañana ese guard de Python se afloja o algún otro camino
  -- INSERTa en quotes sin pasar por el service, el hueco vuelve en silencio y
  -- este mismo gate SQL seguiría en verde (nunca lo habría cubierto). Cuesta
  -- 5 líneas y hoy da 0 en local y en prod.
  SELECT COUNT(*) INTO v_count
  FROM public.quotes q
  JOIN public.clients c ON c.id = q.client_id
  WHERE c.account_id IS DISTINCT FROM q.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (9-quotes): hay % filas de quotes cuyo cliente pertenece a otro tenant — el guard de QuoteRepository.client_belongs_to_account (Python) no está cerrando el hueco.', v_count;
  END IF;

  RAISE NOTICE 'PASS (9): barrido global — cero sales/sales_orders/purchases/quotes con la parte de otro tenant en toda la base.';
  v_blocks_run := v_blocks_run + 1;

  -- ══ (10) CANDADO DE FLAG [RONDA 1, MINOR] — rama ELSE legacy sigue muerta ══
  -- rpc_create_sale_operation (wrapper, nunca tocado por este fix) tiene una
  -- rama ELSE gateada por este flag con el MISMO hueco sin guardar — medido
  -- en prod 2026-09-10: 0 de 35 cuentas. Este candado no arregla la rama (eso
  -- exigiría tocar el wrapper, fuera de regla), pero evita que activar el
  -- flag reabra el hueco en silencio: si esto deja de ser 0, el hallazgo
  -- vuelve a estar vivo y hay que decidir qué hacer ANTES de que CI lo deje
  -- pasar en verde sin que nadie lo note.
  -- JOIN contra accounts (no COUNT(*) crudo sobre account_feature_flags): la
  -- base local compartida tiene filas huérfanas de OTROS gates que también
  -- usan `session_replication_role = replica` para borrar accounts (mismo
  -- mecanismo que el finding de arriba — no cascadea, deja
  -- account_feature_flags apuntando a una cuenta que ya no existe).
  -- Contarlas como "cuenta con el flag en false" sería un falso positivo de
  -- este candado por basura ajena, no por el hallazgo que vino a cerrar.
  SELECT COUNT(*) INTO v_n_flag_off
  FROM public.account_feature_flags aff
  JOIN public.accounts a ON a.id = aff.account_id
  WHERE aff.flag_key = 'sale_items_rpc_v2' AND aff.enabled = false;

  IF v_n_flag_off <> 0 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (10-flag): % cuenta(s) tienen sale_items_rpc_v2=false — la rama ELSE legacy de rpc_create_sale_operation está ACTIVA y NO tiene el guard de client_id (OQ-4 reabierta para esas cuentas). Ver CHANGES.md §operacion-party-guard, candidato "rama ELSE legacy".', v_n_flag_off;
  END IF;
  RAISE NOTICE 'PASS (10): 0 cuentas con sale_items_rpc_v2=false — la rama ELSE legacy sin guard sigue muerta en la práctica.';
  v_blocks_run := v_blocks_run + 1;

  -- RONDA 2 (finding NIT, degrade-don't-fail): sin este candado, cualquiera
  -- de los 4 RETURN tempranos de arriba (cuenta A no resuelta, segundo
  -- tenant no provisionado, sucursal no sembrada, auth.uid() sin resolver)
  -- deja el gate en verde sin haber ejercitado un solo assert. 11 bloques:
  -- (1)(2)(2b)(3)(4)(5)(6)(7)(8)(9)(10).
  IF v_blocks_run <> 11 THEN
    RAISE EXCEPTION 'GATE OPERACION-PARTY-GUARD FAILED (conteo): se ejercitaron % de 11 bloques esperados — el gate degradó a mitad de camino sin abortar (ver NOTICE ''GATE DEGRADED:'' más arriba) y no puede reportarse verde.', v_blocks_run;
  END IF;

  RAISE NOTICE 'GATE OPERACION-PARTY-GUARD OK: venta AL CONTADO con cliente ajeno rechazada por FORMULARIO, POS, PRESUPUESTO→ACEPTAR y EDICIÓN (P0404 client_not_found, cero filas nuevas), compra ya guardada sin regresión, ghost/ajeno indistinguibles, control positivo (activo/de baja/NULL) intacto, candado de cuerpo y ACL congelados en las 4 funciones, barrido global limpio, rama ELSE legacy sigue muerta, 11/11 bloques ejercitados.';
END $$;

-- ── Fase de cleanup ──────────────────────────────────────────────────────────
-- Mismo patrón que test_cuenta_corriente_party_guard.sql: DO block separado,
-- resuelve por email (no por variable heredada) para limpiar también las
-- corridas que degradaron a mitad de camino.
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users
  WHERE email IN ('operacion-party-guard-a@test.local',
                  'operacion-party-guard-b@test.local');

  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE OPERACION-PARTY-GUARD: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.stock_movements          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sale_items               WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales                    WHERE account_id = ANY(v_accounts);
    -- RONDA 1 (finding MAJOR/2b): el quote de "(2b, ESTRELLA)" queda en
    -- draft (el rechazo NO lo revierte — sólo revierte el INSERT en
    -- sales_orders, que corre DESPUÉS del guard, dentro de la misma llamada
    -- a rpc_accept_quote). quote_items primero por la FK a quotes.
    DELETE FROM public.quote_items qi USING public.quotes q
      WHERE qi.quote_id = q.id AND q.account_id = ANY(v_accounts);
    DELETE FROM public.quotes                   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales_order_items i USING public.sales_orders o
      WHERE i.sales_order_id = o.id AND o.account_id = ANY(v_accounts);
    DELETE FROM public.sales_orders             WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchase_items           WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchases                WHERE account_id = ANY(v_accounts);
    DELETE FROM public.events                   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock             WHERE account_id = ANY(v_accounts);
    DELETE FROM public.products                 WHERE account_id = ANY(v_accounts);
    DELETE FROM public.clients                  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers                WHERE account_id = ANY(v_accounts);
    -- RONDA 1 (finding MINOR/residuos): estos 3 hijos del provisioning seed
    -- (2 branches/14 payment_methods/14 product_categories por corrida,
    -- medido) SÓLO tienen FK a accounts (ON DELETE CASCADE) — no a branches
    -- — así que un DELETE explícito acá los limpia sin depender del bypass
    -- de más abajo. product_categories va DESPUÉS de products (FK
    -- ON DELETE RESTRICT de products.category_id).
    DELETE FROM public.payment_methods          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.product_categories       WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cost_centers             WHERE account_id = ANY(v_accounts);
    -- RONDA 1 (mismo hallazgo, mismo mecanismo): v3-provisioning-seed
    -- también siembra 1 cashbox ("Caja Principal") por cada branch default —
    -- cashboxes_branch_id_fkey es CASCADE, así que quedaría igual de
    -- huérfana que branches si no se borra explícito ANTES del DELETE de
    -- branches bajo `replica` (mismo mecanismo exacto que el finding: la
    -- cascada no corre bajo replica). Sin bypass — cashboxes no tiene
    -- trigger que la bloquee.
    DELETE FROM public.cashboxes
    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY(v_accounts));
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches
  -- (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe
  -- TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el
  -- cleanup del fixture sintetico. session_replication_role solo lo puede
  -- fijar un rol con privilegio de superusuario (postgres en CI); no abre
  -- ningun camino para authenticated/anon via PostgREST.
  -- RONDA 1 (finding MINOR) — CORRECCIÓN DE CAUSA RAÍZ: el comentario
  -- original asumía que `DELETE FROM accounts` cascadea a `branches` bajo
  -- `replica`, pero `replica` desactiva TAMBIÉN las FK ON DELETE CASCADE (se
  -- implementan como triggers) — la cascada nunca corría, y `branches`
  -- quedaba huérfana (+2 filas por corrida, medido). Por eso ahora `branches`
  -- se borra EXPLÍCITO acá, bajo el mismo bypass (necesario sólo por
  -- trg_guard_branch_decommission, no por la FK) — nunca dependiendo de la
  -- cascada de `accounts`.
  SET session_replication_role = replica;
  DELETE FROM public.branches              WHERE account_id = ANY(v_accounts);
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  DELETE FROM public.email_logs
   WHERE user_id = ANY(v_users)
      OR recipient IN ('operacion-party-guard-a@test.local',
                       'operacion-party-guard-b@test.local');
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE OPERACION-PARTY-GUARD: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
