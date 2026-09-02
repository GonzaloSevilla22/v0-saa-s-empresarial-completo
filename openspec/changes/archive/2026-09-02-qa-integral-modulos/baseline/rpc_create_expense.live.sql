CREATE OR REPLACE FUNCTION public.rpc_create_expense(p_category text, p_amount numeric, p_date date, p_description text DEFAULT NULL::text, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_expense_id          uuid;
  v_branch              RECORD;
  v_gate_branch         uuid;
  v_kind                text;
  v_cash_movement_id    uuid;
  v_bank_movement_id    uuid;
  v_cash_session_status text;
  v_cash_session_branch uuid;
BEGIN
  -- ── (a) Autenticación, tenant desde la SESIÓN y rol de escritura ──────────
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede registrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── IMPORTE POSITIVO — la precondición de la que depende TODO lo de abajo ─
  -- COPIADO VERBATIM de los dos baselines de los que este RPC toma sus otros
  -- predicados (rpc_create_sale_operation_v2 L154 y rpc_create_purchase_
  -- operation L239: 'Amount must be greater than zero', P0400). La primera
  -- versión de este archivo se trajo el bloque de opt-in de caja y la llamada
  -- bancaria y dejó afuera esta línea, y sin ella:
  --   · la pata de caja registra `-p_amount`, o sea que con p_amount = -5000
  --     escribe un movimiento 'expense' de +5000 — un "gasto" que SUMA plata
  --     al cajón que después se arquea y se firma;
  --   · el guard de signo del borrado (sección 4, `v_cash_amount < 0`) queda
  --     FALSO sobre ese movimiento positivo, así que el DELETE procede SIN
  --     registrar el expense_reversal y la plata fantasma queda sin ningún
  --     documento que la respalde ni forma de rastrearla (el gasto ya no
  --     existe). Es el modo de falla exacto de delete-guard-ledgers —204
  --     operaciones backfilleadas— reintroducido por el change que dice
  --     cerrarlo;
  --   · la pata bancaria produce un 'transfer_out' que AUMENTA el saldo y se
  --     va a la conciliación contra el extracto real.
  -- Se rechaza en el SERVIDOR aunque la UI ya lo limite, por la misma doctrina
  -- que D3: la API no puede ser un bypass del formulario. Gate: sección 8.
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Derivación del kind desde el catálogo ─────────────────────────────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2: el kind se
  -- DERIVA del catálogo, nunca se acepta como texto del cliente, y el mismo
  -- predicado (id + account_id + is_active + deleted_at) cubre de una vez la
  -- forma de pago ajena, la inactiva y la borrada.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = v_account_id
      AND is_active = TRUE AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ── D3: credit NO aplica a un gasto ───────────────────────────────────────
  -- expenses no tiene contraparte (ni supplier_id ni client_id): no hay cuenta
  -- corriente que cargar. Se rechaza en el servidor además de ocultarse en la
  -- UI, para que la API no sea un bypass del selector.
  IF v_kind = 'credit' THEN
    RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Sucursal: mismo predicado y mismo COALESCE que la venta (C-26 / D6) ───
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  -- ── Centro de costo: mismo predicado que la edición de compra ─────────────
  -- (rpc_atomic_update_purchase_operation). El INSERT plano que este RPC
  -- reemplaza aceptaba cualquier cost_center_id, incluido el de otra cuenta:
  -- la FK no está scopeada por tenant.
  IF p_cost_center_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.cost_centers
      WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'cost_center_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ── D5: la cuenta bancaria deja de fallar en silencio EN EL GASTO ─────────
  -- BLOQUEANTE DE PRODUCTO MEDIDO: payment_methods con bank_account_id
  -- configurado = 0 de 37 cuentas. Con la cuenta sin resolver,
  -- _pay_register_operation_bank_movement retorna NULL SIN ERROR — o sea que,
  -- tal cual está, el pedido literal del PO ("que estos movimientos concilien
  -- banco") fallaría en silencio para el 100% de los tenants.
  --
  -- El guard vive ACÁ, en el caller, y NO en el helper: la spec bank-movement
  -- tiene un escenario explícito —"sin cuenta resuelta la venta sigue
  -- funcionando igual que antes"— y el helper es punto de paso de venta,
  -- compra y POS. El endurecimiento asimétrico es deliberado: el gasto NACE
  -- con este contrato, las ventas no.
  --
  -- CONDICIONADO a que la organización tenga al menos una cuenta bancaria
  -- activa: un guard incondicional dejaría a 33 de 37 tenants sin poder
  -- registrar un gasto por transferencia hasta que carguen una cuenta — un
  -- bloqueo de registro por un problema de configuración, el mismo error que
  -- D1 evita en caja.
  --
  -- La resolución se hace con el MISMO helper que usará después
  -- _pay_register_operation_bank_movement (override → default → NULL), así que
  -- no hay una segunda definición de "qué cuenta corresponde"; y si la cuenta
  -- informada es ajena, inactiva o borrada, el propio helper ya levanta P0412
  -- desde acá.
  IF v_kind IN ('transfer', 'card', 'check', 'wallet')
     AND public._pay_resolve_bank_account(v_account_id, p_payment_method_id, p_bank_account_id) IS NULL
     AND EXISTS (
       SELECT 1 FROM public.bank_accounts
       WHERE account_id = v_account_id AND is_active = TRUE AND deleted_at IS NULL
     )
  THEN
    RAISE EXCEPTION 'bank_account_required_for_expense: elegí la cuenta bancaria de la que sale el dinero — sin ella el gasto no aparecería nunca en la conciliación bancaria'
      USING ERRCODE = 'P0412';
  END IF;

  -- ── (b) El gasto ──────────────────────────────────────────────────────────
  -- D6: branch_id se persiste RESUELTO (COALESCE con la default), no crudo:
  -- el escenario de spec exige que un gasto sin sucursal informada quede con
  -- la sucursal por defecto de la cuenta. RN-93 estaba incumplida al 100%
  -- para gastos (0 de 175).
  INSERT INTO public.expenses
    (user_id, account_id, category, amount, description, date,
     branch_id, cost_center_id, payment_method_id)
  VALUES
    (v_uid, v_account_id, p_category, p_amount, p_description, p_date,
     v_gate_branch, p_cost_center_id, p_payment_method_id)
  RETURNING id INTO v_expense_id;

  -- ── (c) PATA DE CAJA — opt-in explícito con las tres condiciones ──────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2 (bloque
  -- "pagos-cableados-restantes OQ-C/D4"), con las dos ÚNICAS adaptaciones que
  -- D1 autoriza:
  --   (a) p_date se declara `date` y se compara DIRECTO contra
  --       reporting_local_today(). ⚠️ PROHIBIDO `p_date timestamptz` con
  --       `p_date::date`: ese cast se resuelve en el TimeZone de la SESIÓN
  --       (UTC en este servidor) mientras reporting_local_today() es
  --       (now() AT TIME ZONE 'America/Argentina/Mendoza')::date, así que un
  --       gasto legítimo de hoy cargado entre las 21:00 y las 23:59 ART
  --       (= 00:00-02:59 UTC del día siguiente) se rechazaría con P0422 justo
  --       en la franja en que el microemprendedor cierra el día. Con `date` el
  --       resultado es invariante por construcción — y lo que ya viaja por el
  --       payload es una fecha pura (ExpenseCreate.date: datetime.date).
  --   (b) c28_register_cash_movement(sesión, -p_amount, 'expense', id_del_gasto):
  --       signo NEGATIVO (egreso) y el gasto como referencia.
  --
  -- La ausencia de p_cash_session_id es NO-OP: bloquear el alta porque no hay
  -- caja abierta convertiría un problema de arqueo en un problema de registro
  -- (D1). El helper aporta gratis P0409 (sesión abierta), P0401 (tenencia,
  -- agregada por tenancy-guard-caja-outbox — el gasto es exactamente el
  -- "caller futuro" que ese guard fue escrito para cubrir), P0422 (sucursal
  -- activa), balance_after serializado y created_by.
  IF p_cash_session_id IS NOT NULL THEN
    IF v_kind IS DISTINCT FROM 'cash' THEN
      RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
        USING ERRCODE = 'P0422';
    END IF;

    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cs.id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva del gasto'
        USING ERRCODE = 'P0422';
    END IF;

    IF p_date <> public.reporting_local_today() THEN
      RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja un gasto fechado hoy (%)', public.reporting_local_today()
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      p_cash_session_id, -p_amount, 'expense', v_expense_id
    );
  END IF;

  -- ── PATA BANCARIA — llamada INCONDICIONAL al helper compartido ────────────
  -- CALCADA de la de rpc_create_purchase_operation (baseline), que ya despacha
  -- un EGRESO con este mismo helper. Sin ningún IF previo: el helper decide.
  -- Aporta gratis el predicado kind IN ('transfer','card','check','wallet'),
  -- la resolución override→default→NULL, la validación de la cuenta (P0412),
  -- el rechazo de cuenta bancaria sobre kind no bancario (P0400), el mapa
  -- kind→movement_type (card→card_settlement, resto out→transfer_out), el
  -- signo y el guard de período conciliado (P0424), que revierte la operación
  -- ENTERA si la fecha cae dentro de una reconciliation_sessions cerrada.
  --
  -- p_value_date = p_date, que ya es `date` (D1) y por lo tanto no arrastra
  -- ningún cast dependiente de la zona de la sesión. Va SÍ O SÍ: con NULL el
  -- movimiento caería en created_at y la sugerencia automática de conciliación
  -- (monto exacto, ventana ±3 días) se desalinearía del extracto.
  --
  -- p_branch_id = v_gate_branch: la sucursal EFECTIVA, la misma que se
  -- persistió en el gasto.
  v_bank_movement_id := public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    p_amount, 'out', 'expense', v_expense_id,
    p_date, v_gate_branch, NULL
  );

  RETURN jsonb_build_object(
    'expense_id',       v_expense_id,
    'branch_id',        v_gate_branch,
    'payment_method_kind', v_kind,
    'cash_movement_id', v_cash_movement_id,
    'bank_movement_id', v_bank_movement_id
  );
END;
$function$
