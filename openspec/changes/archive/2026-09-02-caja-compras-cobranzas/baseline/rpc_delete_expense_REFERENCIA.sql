-- Procedencia: pg_get_functiondef(oid) VIVO en producción (gxdhpxvdjjkmxhdkkwyb),
-- capturado 2026-09-01 vía mcp__supabase__execute_sql (SELECT, read-only).
-- md5:    4d78ee3b241bea2f4df34ceb0afb7cce
-- length: 6498
-- REFERENCIA — NO SE TOCA. Es el MOLDE LITERAL de la compensación de caja
-- por borrado (disparo por EXISTENCIA, nunca por signo; P0426 si no hay
-- sesión abierta en esa caja) que la task 5.x copia a
-- rpc_delete_purchase_operation. Bloque marcado con "── CAJA (MOLDE) ──".

CREATE OR REPLACE FUNCTION public.rpc_delete_expense(p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_expense          RECORD;
  v_cashbox_id       uuid;
  v_cash_amount      numeric(12,2);
  v_open_session_id  uuid;
  v_cash_reversal_id uuid;
  v_bank_row         RECORD;
  v_reversed_type    text;
  v_bank_reversals   integer := 0;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede borrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── CAJA (MOLDE) — contra-movimiento en la sesión abierta actual, P0426 si no hay ──
  -- ⚠️ Guard es `<> 0`, NUNCA `> 0` ni `< 0`: existe movimiento de caja de la
  -- operación ⇒ SIEMPRE se compensa, cualquiera sea el signo. Condicionar al
  -- signo esperado deja pasar el borrado sin compensar y SIN levantar error
  -- (el modo de falla exacto que motivó delete-guard-ledgers).
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = p_expense_id AND movement_type = 'expense'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount <> 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar este gasto'
        USING ERRCODE = 'P0426';
    END IF;

    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'expense_reversal', p_expense_id,
      v_expense.description
    );
  END IF;
  -- ── FIN CAJA ───────────────────────────────────────────────────────────────

  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'expense' AND source_doc_ref = p_expense_id
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'expense', p_expense_id, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de gasto' || COALESCE(': ' || v_expense.description, '')
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  DELETE FROM public.expenses WHERE id = p_expense_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'deleted',           true,
    'cash_reversal_id',  v_cash_reversal_id,
    'bank_reversals',    v_bank_reversals
  );
END;
$function$
;
