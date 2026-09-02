-- Procedencia: pg_get_functiondef(oid) VIVO en producción (gxdhpxvdjjkmxhdkkwyb),
-- capturado 2026-09-01 vía mcp__supabase__execute_sql (SELECT, read-only).
-- md5:    c8f2ef987a6efe06ba0303e93d367d6a
-- length: 12701
-- REFERENCIA — NO SE TOCA. Es el MOLDE LITERAL del bloque de opt-in de caja
-- (3 condiciones) que la task 3.x copia a rpc_create_purchase_operation.
-- Bloque del opt-in de caja marcado más abajo con "── OPT-IN DE CAJA (MOLDE) ──".
-- Nótese: p_date es `date` (no timestamptz) y se compara DIRECTO contra
-- reporting_local_today() — PROHIBIDO castear a timestamptz (ver design.md D2).

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

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

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

  IF v_kind = 'credit' THEN
    RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
      USING ERRCODE = 'P0400';
  END IF;

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

  IF p_cost_center_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.cost_centers
      WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'cost_center_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

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

  INSERT INTO public.expenses
    (user_id, account_id, category, amount, description, date,
     branch_id, cost_center_id, payment_method_id)
  VALUES
    (v_uid, v_account_id, p_category, p_amount, p_description, p_date,
     v_gate_branch, p_cost_center_id, p_payment_method_id)
  RETURNING id INTO v_expense_id;

  -- ── OPT-IN DE CAJA (MOLDE) — 3 condiciones verificadas en servidor ────────
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
      p_cash_session_id, -p_amount, 'expense', v_expense_id, p_description
    );
  END IF;
  -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

  v_bank_movement_id := public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    p_amount, 'out', 'expense', v_expense_id,
    p_date, v_gate_branch, p_description
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
;
