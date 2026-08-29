-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-29, via
-- pg_get_functiondef(oid) -- task 1.6 de gastos-forma-pago.
-- MAX(version) al momento de la captura: 20261014000001 (263 migraciones).
-- md5(pg_get_functiondef) = 1b0692ad5ba614f267389b335e4d366a - length = 4413.
-- Rol en el change: REUSO SIN TOCAR: pata de caja. Aporta P0409 (sesion abierta), P0401 (tenencia), P0422 (sucursal activa), balance_after y created_by.
--
-- Procedencia del byte exacto: el cuerpo se materializo desde el stack local
-- (supabase db reset sobre las mismas 263 migraciones) y se verifico contra PROD
-- por md5 EXACTO del pg_get_functiondef vivo. El stack local guarda CR embebidos
-- (los .sql del working tree estan en CRLF por core.autocrlf=true), por eso el
-- hash se calcula sobre replace(def, chr(13), '') -- que da byte-identico a PROD.

CREATE OR REPLACE FUNCTION public.c28_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_session      public.cash_sessions%ROWTYPE;
  v_branch_status text;
  v_prev_balance  numeric(12,2);
  v_balance_after numeric(12,2);
  v_movement_id   uuid;
  v_user_id       uuid;
  -- tenancy-guard-caja-outbox (h1, capa 2): cuenta dueña de la sesión.
  v_owner_account_id uuid;
BEGIN
  -- D3: lock de fila de la sesión para serializar cálculo de balance_after
  SELECT * INTO v_session
  FROM public.cash_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  -- Validar que la sesión esté open
  IF v_session.id IS NULL OR v_session.status <> 'open' THEN
    RAISE EXCEPTION 'no_open_session'
      USING ERRCODE = 'P0409';
  END IF;

  -- ╔═══ tenancy-guard-caja-outbox (h1, CAPA 2 — backstop de TENANT) ════════╗
  -- Este helper es el choke point de TODA escritura en caja y era SECURITY
  -- INVOKER sin una sola mención a account_id: cualquier caller SECURITY
  -- DEFINER (corren como postgres, la RLS no interviene) podía imputarle un
  -- movimiento a la caja de otro tenant pasándole el id de su sesión. Lo
  -- explotaba _c29_confirm_order_core; el guard de acá cubre además a todo
  -- caller FUTURO, que es lo que la capa 1 no puede hacer.
  -- El SELECT de resolución se COPIA de rpc_register_cash_movement
  -- (20261006000001 §4): misma cadena de FKs, no una consulta nueva. Por eso
  -- la firma no cambia — el tenant es derivable de lo que ya se recibe.
  -- MEMBRESÍA (current_account_ids), NO is_account_writer: es un backstop de
  -- tenencia dentro de operaciones ya autorizadas; exigir permiso de escritura
  -- acá endurecería en silencio el rol del camino del formulario (D1 iii).
  -- Se usa `IN (SELECT public.current_account_ids())`, la forma canónica del
  -- proyecto (la función devuelve SETOF uuid, no un array: `= ANY(...)` falla
  -- con "op ANY/ALL (array) requires array on right side").
  -- Falla cerrado si la cuenta no resuelve (inalcanzable: los FKs
  -- cash_sessions→cashboxes→branches son NOT NULL y la sesión ya existe).
  -- ERRCODE P0401, el mismo que rpc_register_cash_movement usa para este
  -- predicado. NO puede ser P0001: abortaría el gate embebido de
  -- 20260804000003 §(b), cuyo handler matchea sólo ese código (ver cabecera).
  SELECT b.account_id INTO v_owner_account_id
  FROM public.cash_sessions cs
  JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
  JOIN public.branches b   ON b.id  = cb.branch_id
  WHERE cs.id = p_session_id;

  IF v_owner_account_id IS NULL
     OR v_owner_account_id NOT IN (SELECT public.current_account_ids()) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- Validar que la sucursal esté activa
  SELECT b.status INTO v_branch_status
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = v_session.cashbox_id;

  IF v_branch_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'branch_closed'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular el saldo previo = opening_balance + SUM(amount de los movimientos previos).
  -- (SUM(amount), NO MAX(balance_after): el saldo corriente puede BAJAR tras un egreso,
  --  y MAX devolvería el pico histórico, no el saldo actual. El FOR UPDATE de arriba
  --  serializa el cálculo, así que SUM es seguro. Mismo patrón que _register_bank_movement.)
  SELECT v_session.opening_balance + COALESCE(SUM(cm.amount), 0)
  INTO v_prev_balance
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_balance_after := v_prev_balance + p_amount;

  -- Resolver el usuario actual del JWT
  v_user_id := auth.uid();

  -- Insertar el movimiento (append-only). banco-caja-historial-ajustes:
  -- suma description — cash_movements_adjustment_needs_reason rechaza un
  -- adjustment sin motivo no vacío, sin código nuevo acá.
  INSERT INTO public.cash_movements
    (session_id, amount, movement_type, reference_id, balance_after, created_by, description)
  VALUES
    (p_session_id, p_amount, p_type, p_reference_id, v_balance_after, v_user_id, p_description)
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$function$
