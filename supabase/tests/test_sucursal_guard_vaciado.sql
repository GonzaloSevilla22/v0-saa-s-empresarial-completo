-- =============================================================================
-- GATE: test_sucursal_guard_vaciado.sql
-- CHANGE: sucursal-guard-vaciado-auditoria (G1 guard de vaciado, G2 autoría)
--
-- Ejercita de VERDAD (fixture sintético que se auto-limpia de hijo a padre,
-- lección de PRs #268/#269) el disparador BEFORE UPDATE OR DELETE sobre
-- public.branches y la autoría de alta/baja.
--
-- TENANT PRINCIPAL (v_account): dos sucursales activas — v_branch1 (la
-- default 'Casa Central' que crea handle_new_user al signup — sirve para
-- probar que el alta de SISTEMA deja created_by NULL) y v_branch2 (creada
-- explícitamente para tener a dónde transferir). La mayoría de los asserts
-- corren acá.
--
-- TENANT SECUNDARIO (v_account_solo): UNA sola sucursal activa con stock —
-- existe únicamente para el assert 3.10 (mensaje distinto cuando no hay a
-- dónde transferir). Aislado en su propio tenant para no tener que apagar
-- transitoriamente v_branch2 del tenant principal (que dispararía el propio
-- disparador de auditoría con ruido ajeno al assert).
--
--   (3.2) Desactivar CON existencias → P0428, mensaje con las unidades.
--   (3.3) Desactivar SIN existencias → pasa.
--   (3.4) Transferir y LUEGO desactivar → pasa (el recorrido completo del
--         incidente real del 22→24-08, en verde).
--   (3.5) Cerrar con existencias → P0428, conserva el token de texto
--         `branch_has_stock` que el cliente ya traduce por texto.
--   (3.6) Los CUATRO caminos rechazan: rpc_deactivate_branch,
--         rpc_close_branch, UPDATE directo sobre la tabla, DELETE directo.
--   (3.7) Borrar una sucursal VACÍA también falla (D4, incondicional).
--   (3.8) Sesión de caja abierta bloquea (discriminada de existencias).
--         Transferencias sin completar: el predicado está ESCRITO y
--         verificado por candado de texto contra el cuerpo vivo — hoy
--         estructuralmente inejercitable con datos reales porque
--         stock_transfers.status tiene CHECK (status IN ('completed')); ver
--         nota en el propio assert.
--   (3.9) MATRIZ DE EVASIÓN — el guard mira la TRANSICIÓN, no el estado:
--         renombrar con stock pasa, cambiar dirección con stock pasa,
--         reactivar con stock pasa; quantity negativa BLOQUEA (predicado
--         `<> 0`, no `> 0`).
--   (3.10) La sucursal ÚNICA de la cuenta con stock recibe el mensaje que
--          manda a crear otra sucursal, no a transferir.
--   (3.11) Anti-overload: una sola definición viva de cada función tocada,
--          misma lista de parámetros que antes.
--   G2   — el alta por la interfaz registra created_by; el alta de sistema
--          (handle_new_user) lo deja NULL; la baja registra
--          deactivated_at/deactivated_by; el ciclo de vida deja rastro en
--          audit_logs (entity_type='branch') sin generar notificaciones.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve cuenta, o si el
-- plan de la cuenta no habilita el módulo de sucursales (rpc_create_branch
-- devolvería branch_limit_exceeded), el/los assert(s) dependientes emiten
-- NOTICE y se SALTAN sin abortar el resto del gate — mismo criterio que
-- test_tenancy_guard_caja_outbox.sql para su fixture de kind=transfer.
--
-- Cleanup: DO block separado al final que resuelve por email (cubre
-- corridas cortadas por un camino degrade-don't-fail) y borra los dos
-- tenants sintéticos y todo lo que cuelga de ellos, hijo→padre. Verificado:
-- el gate corre VERDE dos veces seguidas.
-- =============================================================================

DO $$
DECLARE
  -- ── Tenant principal ───────────────────────────────────────────────────
  v_email          text := 'sucursal-guard-vaciado@test.local';
  v_user           uuid := gen_random_uuid();
  v_account        uuid;
  v_branch1        uuid;  -- default 'Casa Central' (alta de SISTEMA)
  v_branch2        uuid;  -- creada explícita, destino de transferencia
  v_cashbox1       uuid;
  v_product        uuid;

  -- ── Tenant secundario: UNA sola sucursal con stock (assert 3.10) ───────
  v_email_solo     text := 'sucursal-guard-vaciado-solo@test.local';
  v_user_solo      uuid := gen_random_uuid();
  v_account_solo   uuid;
  v_branch_solo    uuid;
  v_product_solo   uuid;

  -- ── Scratch ──────────────────────────────────────────────────────────
  v_rejected       boolean;
  v_sqlstate       text;
  v_message        text;
  v_result         jsonb;
  v_count          integer;
  v_qty            numeric;
  v_created_by     uuid;
  v_deact_at       timestamptz;
  v_deact_by       uuid;
  v_def            text;
  v_branch_created uuid;
  v_session        uuid;
  v_name_check     text;
  v_address_check  text;
BEGIN
  -- ── Anchor sintético del tenant principal ───────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', v_email, now(), now(),
          jsonb_build_object('name', 'Gate Sucursal Guard'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;

  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE SUCURSAL-GUARD: no se pudo resolver cuenta para el anchor sintético — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id, created_by INTO v_branch1, v_created_by
  FROM public.branches WHERE account_id = v_account ORDER BY created_at ASC LIMIT 1;

  IF v_branch1 IS NULL THEN
    RAISE NOTICE 'GATE SUCURSAL-GUARD: la sucursal default no se sembró para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  -- ══ G2 (alta de sistema): la sucursal default nace con created_by NULL ═══
  IF v_created_by IS NOT NULL THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (G2-sistema): la sucursal default sembrada por handle_new_user (alta de SISTEMA) tiene created_by = %, esperaba NULL — no hay una persona detrás de esa alta.', v_created_by;
  END IF;
  RAISE NOTICE 'PASS (G2-sistema): la sucursal default de handle_new_user nace con created_by NULL.';

  -- ── Sesión sintética (request.jwt.claims) ────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user THEN
    RAISE NOTICE 'GATE SUCURSAL-GUARD: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan RPCs autenticadas.';
    RETURN;
  END IF;

  -- ══ G2 (alta por interfaz): rpc_create_branch completa created_by ═══════
  -- Degradable: si el plan de la cuenta sintética no trae el módulo de
  -- sucursales, rpc_create_branch devuelve branch_limit_exceeded (P0403) —
  -- no es lo que este assert prueba, así que se SALTEA sin abortar el resto
  -- del gate (que usa v_branch2 creada por INSERT directo más abajo).
  BEGIN
    SELECT (public.rpc_create_branch(v_account, '__gate_sgv_branch2__', 'Dirección de prueba')).id
    INTO v_branch_created;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0403' THEN
        v_branch_created := NULL;
        RAISE NOTICE 'SKIP (G2-interfaz): el plan de la cuenta sintética no habilita el módulo de sucursales (branch_limit_exceeded) — rpc_create_branch no se pudo ejercitar. El resto del gate sigue con una sucursal creada por INSERT directo.';
      ELSE
        RAISE;
      END IF;
  END;

  IF v_branch_created IS NOT NULL THEN
    SELECT created_by INTO v_created_by FROM public.branches WHERE id = v_branch_created;
    IF v_created_by IS DISTINCT FROM v_user THEN
      RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (G2-interfaz): rpc_create_branch debería completar created_by = % (identidad en curso), quedó en %.', v_user, v_created_by;
    END IF;
    RAISE NOTICE 'PASS (G2-interfaz): rpc_create_branch completa created_by con la identidad en curso.';
    -- Se usa como v_branch2 si se pudo crear — evita un INSERT redundante.
    v_branch2 := v_branch_created;
  ELSE
    INSERT INTO public.branches (account_id, name, created_by)
    VALUES (v_account, '__gate_sgv_branch2_fallback__', v_user)
    RETURNING id INTO v_branch2;
  END IF;

  -- ── Resto del fixture: caja + producto + stock ──────────────────────────
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch1, '__gate_sgv_cashbox__') RETURNING id INTO v_cashbox1;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user, v_account, '__gate_sgv_product__', 500, 200, 'GATE-SGV-1')
  RETURNING id INTO v_product;

  -- ═══════════ (3.2) Desactivar CON existencias → P0428 ═════════════════════
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account, v_branch1, v_product, 585)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 585;

  v_message := NULL;
  BEGIN
    PERFORM public.rpc_deactivate_branch(v_branch1);
  EXCEPTION
    WHEN OTHERS THEN v_message := SQLERRM; v_sqlstate := SQLSTATE;
  END;

  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.2): desactivar una sucursal con 585 unidades debería fallar con P0428, falló con % (%).', COALESCE(v_sqlstate, 'NINGÚN error'), v_message;
  END IF;
  IF v_message NOT LIKE '%585%' OR v_message NOT LIKE '%branch_has_stock%' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.2-mensaje): el rechazo debe nombrar las 585 unidades y conservar el token branch_has_stock, el mensaje fue: %', v_message;
  END IF;

  SELECT is_active INTO v_rejected FROM public.branches WHERE id = v_branch1;
  IF v_rejected IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.2-efectos): el rechazo debe dejar is_active en TRUE, quedó en %.', v_rejected;
  END IF;
  RAISE NOTICE 'PASS (3.2): desactivar una sucursal con 585 unidades falla con P0428 y el mensaje las nombra.';

  -- ═══════════ (3.4) Transferir y LUEGO desactivar → pasa ════════════════════
  -- El recorrido COMPLETO del incidente real, en verde.
  PERFORM public.rpc_transfer_stock(v_product, v_branch1, v_branch2, 585);

  SELECT COALESCE(SUM(quantity), 0) INTO v_qty FROM public.branch_stock WHERE branch_id = v_branch1;
  IF v_qty <> 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.4-transferencia): tras transferir las 585 unidades, v_branch1 debería quedar en 0, quedó en %.', v_qty;
  END IF;

  PERFORM public.rpc_deactivate_branch(v_branch1);

  SELECT is_active, deactivated_at, deactivated_by INTO v_rejected, v_deact_at, v_deact_by
  FROM public.branches WHERE id = v_branch1;

  IF v_rejected IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.4): tras vaciar la sucursal, desactivarla debería funcionar; is_active quedó en %.', v_rejected;
  END IF;
  RAISE NOTICE 'PASS (3.3/3.4): desactivar una sucursal vacía funciona — el recorrido completo transferir→desactivar queda en verde.';

  -- ══ G2 (baja): deactivated_at/deactivated_by quedan escritos ═══════════════
  IF v_deact_by IS DISTINCT FROM v_user OR v_deact_at IS NULL THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (G2-baja): tras desactivar, deactivated_by debería ser % y deactivated_at no-NULL; quedaron (%, %).', v_user, v_deact_by, v_deact_at;
  END IF;
  RAISE NOTICE 'PASS (G2-baja): la desactivación registra deactivated_at y deactivated_by.';

  -- Reactivar v_branch1 para el resto del gate (necesita las dos sucursales activas).
  UPDATE public.branches SET is_active = TRUE WHERE id = v_branch1;

  -- ══ (3.9c) Reactivar una sucursal con existencias sigue funcionando ═══════
  -- (v_branch1 ya está vacía en este punto — se ejercita el caso "inactiva
  -- CON existencias" por separado más abajo, junto con el resto de la
  -- matriz de evasión, sobre v_branch2.)

  -- ═══════════ (3.5) Cerrar CON existencias → P0428, token conservado ═══════
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account, v_branch2, v_product, 40)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 40;

  v_message := NULL;
  BEGIN
    PERFORM public.rpc_close_branch(v_branch2);
  EXCEPTION
    WHEN OTHERS THEN v_message := SQLERRM; v_sqlstate := SQLSTATE;
  END;

  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.5): cerrar una sucursal con stock debería fallar con P0428 (unificado, antes P0409), falló con % (%).', COALESCE(v_sqlstate, 'NINGÚN error'), v_message;
  END IF;
  IF v_message NOT LIKE '%branch_has_stock%' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.5-token): el cierre debe conservar el token branch_has_stock para que la traducción existente del cliente siga funcionando; el mensaje fue: %', v_message;
  END IF;
  RAISE NOTICE 'PASS (3.5): cerrar una sucursal con stock falla con P0428 conservando el token branch_has_stock.';

  -- ═══ (3.6) LOS CUATRO CAMINOS rechazan ═════════════════════════════════════
  -- (a) rpc_deactivate_branch — re-verificado explícito acá con v_branch2.
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_deactivate_branch(v_branch2);
  EXCEPTION WHEN OTHERS THEN v_sqlstate := SQLSTATE;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.6a): rpc_deactivate_branch con stock debería fallar con P0428, falló con %.', COALESCE(v_sqlstate, 'NINGÚN error');
  END IF;

  -- (b) rpc_close_branch — ya verificado en (3.5); repetido acá por completitud del punto 3.6.
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_close_branch(v_branch2);
  EXCEPTION WHEN OTHERS THEN v_sqlstate := SQLSTATE;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.6b): rpc_close_branch con stock debería fallar con P0428, falló con %.', COALESCE(v_sqlstate, 'NINGÚN error');
  END IF;

  -- (c) UPDATE DIRECTO sobre la tabla — sin pasar por NINGÚN comando. Esto es
  -- lo que el incidente real necesitaba y no tenía: el choke point real.
  v_sqlstate := NULL;
  BEGIN
    UPDATE public.branches SET is_active = FALSE WHERE id = v_branch2;
  EXCEPTION WHEN OTHERS THEN v_sqlstate := SQLSTATE;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.6c): un UPDATE directo sobre la tabla (is_active=FALSE) con stock debería fallar con P0428 vía el disparador, falló con %. Este es EXACTAMENTE el camino del incidente real (BranchRepository.update / escritura directa del navegador).', COALESCE(v_sqlstate, 'NINGÚN error');
  END IF;
  RAISE NOTICE 'PASS (3.6a-c): los tres caminos por UPDATE (comando de desactivación, comando de cierre, UPDATE directo) rechazan con P0428.';

  -- ═══════════ (3.7) DELETE físico — SIEMPRE prohibido (D4) ═════════════════
  -- (d) DELETE directo sobre una sucursal CON contenido.
  v_sqlstate := NULL;
  BEGIN
    DELETE FROM public.branches WHERE id = v_branch2;
  EXCEPTION WHEN OTHERS THEN v_sqlstate := SQLSTATE;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.6d/3.7-con-contenido): borrar físicamente una sucursal CON contenido debería fallar con P0428, falló con %.', COALESCE(v_sqlstate, 'NINGÚN error');
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.branches WHERE id = v_branch2;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.7-efectos): el rechazo del DELETE debe dejar la fila viva, hay % filas con ese id.', v_count;
  END IF;

  -- DELETE de una sucursal VACÍA — también debe fallar (D4, incondicional).
  UPDATE public.branch_stock SET quantity = 0 WHERE branch_id = v_branch2 AND product_id = v_product;

  v_message := NULL;
  BEGIN
    DELETE FROM public.branches WHERE id = v_branch2;
  EXCEPTION WHEN OTHERS THEN v_message := SQLERRM; v_sqlstate := SQLSTATE;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.7-vacia): borrar físicamente una sucursal VACÍA también debe fallar (D4, incondicional), falló con %.', COALESCE(v_sqlstate, 'NINGÚN error');
  END IF;
  IF v_message NOT LIKE '%branch_delete_forbidden%' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.7-mensaje): el rechazo del borrado debe nombrar branch_delete_forbidden y la desactivación como vía correcta; el mensaje fue: %', v_message;
  END IF;
  RAISE NOTICE 'PASS (3.7): el borrado físico está prohibido SIEMPRE, con o sin contenido — la sucursal sigue existiendo en ambos casos.';

  -- ═══ (3.8a) Sesión de caja abierta bloquea (discriminada de existencias) ═══
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox1, 'open', 0, v_user)
  RETURNING id INTO v_session;

  v_message := NULL;
  BEGIN
    PERFORM public.rpc_deactivate_branch(v_branch1); -- v_branch1 está SIN stock en este punto
  EXCEPTION WHEN OTHERS THEN v_message := SQLERRM; v_sqlstate := SQLSTATE;
  END;

  IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.8a): desactivar una sucursal SIN stock pero CON sesión de caja abierta debería fallar con P0428, falló con %.', COALESCE(v_sqlstate, 'NINGÚN error');
  END IF;
  IF v_message NOT LIKE '%branch_has_open_cash_session%' OR v_message LIKE '%branch_has_stock%' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.8a-motivo): el motivo informado debe ser la sesión de caja (branch_has_open_cash_session), NO las existencias; el mensaje fue: %', v_message;
  END IF;
  RAISE NOTICE 'PASS (3.8a): una sesión de caja abierta bloquea la baja, con el motivo discriminado de las existencias.';

  UPDATE public.cash_sessions SET status = 'closed', closed_at = now() WHERE cashbox_id = v_cashbox1 AND status = 'open';

  -- (3.8b) Transferencias sin completar — CANDADO DE TEXTO, no ejercitable
  -- con datos reales: stock_transfers.status tiene CHECK (status IN
  -- ('completed')) desde 20260625000001 ("el enum habilita in-transit en el
  -- futuro sin migrar"). Se verifica que el predicado está ESCRITO en el
  -- cuerpo vivo de _branch_blocking_content, no que bloquee con una fila real
  -- (estructuralmente imposible de construir hoy sin violar el CHECK).
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_branch_blocking_content';
  IF position('stock_transfers' in v_def) = 0 OR position('pending_transfers' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.8b-candado): _branch_blocking_content no lee stock_transfers para el predicado de transferencias en vuelo.';
  END IF;
  RAISE NOTICE 'SKIP-CANDADO (3.8b): stock_transfers.status sólo admite ''completed'' hoy (CHECK) — no se puede construir una transferencia en vuelo real. Verificado por candado de texto que el predicado está escrito y forward-looking.';

  -- ═══════════ (3.9) MATRIZ DE EVASIÓN ═══════════════════════════════════════
  -- v_branch2 sigue con stock=0 en este punto (se vació en 3.7). Le devolvemos
  -- contenido para probar que renombrar/cambiar dirección/reactivar NO se ven
  -- afectados por tenerlo.
  UPDATE public.branch_stock SET quantity = 77 WHERE branch_id = v_branch2 AND product_id = v_product;

  -- (a) Renombrar con stock: pasa.
  UPDATE public.branches SET name = '__gate_sgv_branch2_renamed__' WHERE id = v_branch2;
  -- (b) Cambiar dirección con stock: pasa.
  UPDATE public.branches SET address = 'Nueva dirección de prueba' WHERE id = v_branch2;

  SELECT name, address INTO v_name_check, v_address_check FROM public.branches WHERE id = v_branch2;
  IF v_name_check <> '__gate_sgv_branch2_renamed__' OR v_address_check <> 'Nueva dirección de prueba' THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.9a-b): renombrar/cambiar dirección de una sucursal CON existencias (77 unidades) debería aplicarse sin que el guard lo bloquee; quedaron (name=%, address=%).', v_name_check, v_address_check;
  END IF;

  -- (c) Reactivar una sucursal INACTIVA con stock: pasa. Se desactiva primero
  -- v_branch1 (que está vacía) para tener una fila is_active=FALSE con la
  -- que simular "inactiva con stock" sin pasar por el guard de baja: se le
  -- agrega stock DESPUÉS de desactivarla (vía UPDATE directo — no dispara el
  -- guard, que sólo mira la transición de is_active/status, no branch_stock).
  PERFORM public.rpc_deactivate_branch(v_branch1);
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account, v_branch1, v_product, 15)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 15;

  UPDATE public.branches SET is_active = TRUE WHERE id = v_branch1;

  SELECT name, address, is_active INTO v_message, v_message, v_rejected FROM public.branches WHERE id = v_branch2;
  SELECT is_active INTO v_rejected FROM public.branches WHERE id = v_branch1;
  IF v_rejected IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.9c): reactivar una sucursal inactiva CON existencias (15 unidades) debería funcionar; is_active quedó en %.', v_rejected;
  END IF;
  RAISE NOTICE 'PASS (3.9a-c): renombrar, cambiar dirección y reactivar una sucursal con existencias siguen funcionando — el guard mira la transición, no el estado.';

  -- (d) quantity NEGATIVA bloquea (predicado `<> 0`, no `> 0`) — CANDADO DE
  -- TEXTO, no ejercitable con una fila real: branch_stock tiene el CHECK
  -- branch_stock_quantity_non_negative (quantity >= 0), así que un UPDATE con
  -- -3 nunca llega a evaluar el guard — revienta antes con una violación de
  -- CHECK (23514), que NO es lo que este assert prueba. El predicado del
  -- guard está escrito para no depender de ese CHECK (defensa ante una
  -- anomalía futura que lo sortee, p.ej. una carga masiva) — se verifica que
  -- la comparación es `<> 0` en el cuerpo vivo, literal.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_branch_blocking_content';
  IF position('quantity <> 0' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.9d-candado): _branch_blocking_content debe filtrar por quantity <> 0 (no > 0) — una cantidad negativa por anomalía debe bloquear la baja, nunca autorizarla en silencio. No se encontró el literal en el cuerpo vivo.';
  END IF;
  IF position('quantity > 0' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.9d-candado): _branch_blocking_content NO debe usar quantity > 0 en ninguna parte de su predicado de existencias.';
  END IF;
  RAISE NOTICE 'SKIP-CANDADO (3.9d): branch_stock_quantity_non_negative (CHECK quantity >= 0) impide construir una fila negativa real hoy. Verificado por candado de texto que el predicado usa <> 0, nunca > 0.';

  -- Dejar v_branch1/v_branch2 en 0 para no interferir con el cleanup ni con
  -- otra corrida del gate contra la misma base.
  UPDATE public.branch_stock SET quantity = 0 WHERE branch_id IN (v_branch1, v_branch2) AND product_id = v_product;

  -- ═══ (3.11) ANTI-OVERLOAD — una sola definición viva por función tocada ═══
  SELECT COUNT(*) INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname IN ('rpc_deactivate_branch', 'rpc_close_branch', 'rpc_create_branch',
                     '_branch_blocking_content', '_branch_assert_empty',
                     'fn_guard_branch_decommission', 'fn_audit_branch_lifecycle');
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.11): esperaba exactamente 7 definiciones (una por función), hay % — overload fantasma.', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.11): una sola definición viva de cada función tocada por este change.';

  -- ═══ G2 — audit_logs recibe el ciclo de vida, sin notificaciones ═════════
  SELECT COUNT(*) INTO v_count
  FROM public.audit_logs
  WHERE entity_type = 'branch' AND entity_id = v_branch2 AND action = 'branch.updated';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (G2-audit-edicion): renombrar/cambiar dirección de v_branch2 debería haber dejado al menos 1 fila branch.updated en audit_logs, hay %.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.audit_logs
  WHERE entity_type = 'branch' AND entity_id = v_branch1 AND action = 'branch.deactivated';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (G2-audit-baja): desactivar v_branch1 debería haber dejado al menos 1 fila branch.deactivated en audit_logs, hay %.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.audit_logs
  WHERE entity_type = 'branch' AND entity_id = v_branch1 AND action = 'branch.reactivated';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (G2-audit-reactivacion): reactivar v_branch1 debería haber dejado al menos 1 fila branch.reactivated en audit_logs, hay %.', v_count;
  END IF;

  -- audit_logs no tiene columna que dispare notificaciones — se verifica que
  -- la tabla notifications no ganó filas nuevas atribuibles a esta cuenta
  -- durante todo el gate (control negativo).
  SELECT COUNT(*) INTO v_count FROM public.notifications WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (G2-sin-notificaciones): registrar el ciclo de vida de sucursales en audit_logs NO debe generar notificaciones al usuario; hay % filas en notifications para esta cuenta.', v_count;
  END IF;
  RAISE NOTICE 'PASS (G2-audit): el ciclo de vida (edición/baja/reactivación) queda en audit_logs con entity_type=branch, sin generar notificaciones.';

  -- ═══════════ TENANT SECUNDARIO — (3.10) sucursal ÚNICA de la cuenta ═══════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_solo, 'authenticated', 'authenticated', v_email_solo, now(), now(),
          jsonb_build_object('name', 'Gate Sucursal Guard Solo'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_solo FROM public.account_members WHERE user_id = v_user_solo ORDER BY created_at LIMIT 1;

  IF v_account_solo IS NULL OR v_account_solo = v_account THEN
    RAISE NOTICE 'SKIP (3.10): no se pudo provisionar un SEGUNDO tenant independiente para el assert de sucursal única.';
  ELSE
    SELECT id INTO v_branch_solo FROM public.branches WHERE account_id = v_account_solo ORDER BY created_at ASC LIMIT 1;

    IF v_branch_solo IS NULL THEN
      RAISE NOTICE 'SKIP (3.10): la sucursal default del segundo tenant no se sembró.';
    ELSE
      INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
      VALUES (v_user_solo, v_account_solo, '__gate_sgv_product_solo__', 100, 40, 'GATE-SGV-SOLO')
      RETURNING id INTO v_product_solo;

      INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
      VALUES (v_account_solo, v_branch_solo, v_product_solo, 12)
      ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 12;

      v_message := NULL;
      BEGIN
        -- SECURITY DEFINER: no depende de sesión — se llama directo (mismo
        -- patrón que otros gates cuando alcanza con el helper interno,
        -- documentado explícito acá porque NO se resuelve auth.uid() para
        -- este segundo tenant en la misma transacción).
        PERFORM public._branch_assert_empty(v_branch_solo);
      EXCEPTION
        WHEN OTHERS THEN v_message := SQLERRM; v_sqlstate := SQLSTATE;
      END;

      IF v_sqlstate IS DISTINCT FROM 'P0428' THEN
        RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.10): la sucursal ÚNICA de una cuenta con stock debería bloquear la baja con P0428, falló con %.', COALESCE(v_sqlstate, 'NINGÚN error');
      END IF;
      IF v_message LIKE '%transferí el stock a otra sucursal%' OR v_message NOT LIKE '%única sucursal activa%' THEN
        RAISE EXCEPTION 'GATE SUCURSAL-GUARD FAILED (3.10-mensaje): con una sola sucursal activa el mensaje debe mandar a CREAR otra sucursal, no a transferir (no hay a dónde); el mensaje fue: %', v_message;
      END IF;
      RAISE NOTICE 'PASS (3.10): la sucursal única de la cuenta con stock recibe el mensaje que manda a crear otra sucursal, no a transferir.';
    END IF;
  END IF;

  RAISE NOTICE 'GATE SUCURSAL-GUARD-VACIADO-AUDITORIA OK: los 4 caminos de baja rechazan con P0428 (existencias/caja/DELETE), el borrado físico está SIEMPRE prohibido, la matriz de evasión no se ve afectada, la autoría de alta/baja queda escrita, y el ciclo de vida completo queda en audit_logs sin notificaciones.';
END $$;

-- ── Fase de cleanup ──────────────────────────────────────────────────────────
-- DO block SEPARADO que resuelve por email (cubre corridas cortadas por un
-- camino degrade-don't-fail) y borra los dos tenants sintéticos hijo→padre.
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users
  WHERE email IN ('sucursal-guard-vaciado@test.local', 'sucursal-guard-vaciado-solo@test.local');

  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE SUCURSAL-GUARD: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.stock_movements st USING public.branches b
      WHERE st.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.stock_transfers st USING public.branches b
      WHERE (st.from_branch_id = b.id OR st.to_branch_id = b.id) AND b.account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock WHERE account_id = ANY(v_accounts);
    DELETE FROM public.products     WHERE account_id = ANY(v_accounts);
    DELETE FROM public.audit_logs   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.notifications WHERE account_id = ANY(v_accounts);
    -- Bypass del propio guard (D4: el borrado físico está SIEMPRE prohibido)
    -- para poder limpiar el fixture sintético. session_replication_role sólo
    -- lo puede fijar un rol con privilegio de superusuario/owner (postgres en
    -- CI) — no abre ningún camino para authenticated/anon vía PostgREST.
    SET session_replication_role = replica;
    DELETE FROM public.branches     WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts        WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles        WHERE id = ANY(v_users);
  DELETE FROM public.email_logs
   WHERE user_id = ANY(v_users)
      OR recipient IN ('sucursal-guard-vaciado@test.local', 'sucursal-guard-vaciado-solo@test.local');
  DELETE FROM auth.users             WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE SUCURSAL-GUARD: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
