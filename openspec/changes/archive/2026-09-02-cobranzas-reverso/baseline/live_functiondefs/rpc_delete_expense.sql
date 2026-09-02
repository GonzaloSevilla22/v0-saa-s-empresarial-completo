-- Volcado vivo COMPLETO de prod (gxdhpxvdjjkmxhdkkwyb), capturado 2026-09-02 en el
-- checkpoint 1.3 del apply de cobranzas-reverso, vía mcp__supabase__execute_sql (SELECT).
-- md5 verificado en checkpoint 1.2: 4d78ee3b241bea2f4df34ceb0afb7cce (6498 chars). PASA.
-- Molde de compensación multi-libro para rpc_reverse_payment_received/_made (grupos 3-4).
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

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  -- Copiado del baseline de rpc_delete_sale_operation (20261005000001:1205-1234)
  -- CON UNA INVERSIÓN OBLIGATORIA Y EXPLÍCITA DEL GUARD DE SIGNO.
  --
  -- ⚠️⚠️ El original es `IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0`,
  -- porque los movimientos agrupados de una VENTA son de tipo 'sale' con
  -- importe POSITIVO. Los del GASTO son de tipo 'expense' con importe
  -- NEGATIVO (lo fija este mismo change: expense negativo, expense_reversal
  -- positivo). Copiado verbatim, `v_cash_amount > 0` es FALSO PARA TODO GASTO:
  -- se saltearía el bloque entero, no se registraría el expense_reversal,
  -- NUNCA se lanzaría P0426 y el DELETE procedería igual — se reintroduciría
  -- exactamente el borrado inseguro que motivó delete-guard-ledgers, desde el
  -- change que dice cerrarlo. Y sin levantar un solo error.
  --
  -- Por eso el guard correcto NO es el positivo del original, y por eso el
  -- gate tiene un CONTROL NEGATIVO obligatorio (5.4b): un test que sólo
  -- assertara "no hubo error" quedaría verde por omisión.
  --
  -- ⚠️ Y por eso tampoco es `v_cash_amount < 0`: esa forma sigue dependiendo
  -- de una invariante que vive en OTRA función (que el alta nunca acepte un
  -- importe no positivo). El guard es `<> 0`: **existe movimiento de caja del
  -- gasto ⇒ SIEMPRE se compensa**, cualquiera sea el signo. Con `< 0`, un solo
  -- movimiento 'expense' positivo —el que producía el alta antes del guard de
  -- P0400, o cualquier camino futuro— hacía que el DELETE procediera sin
  -- compensar y SIN levantar un error. El SELECT de abajo ya filtra
  -- `movement_type = 'expense'`, así que las reversas no se autocompensan.
  -- Gate: sección 8.5, que inyecta a mano el estado corrupto.
  --
  -- La sesión ORIGINAL nunca se toca: el ledger de caja es append-only. El
  -- contra-movimiento va SIEMPRE a la sesión abierta actual de la MISMA caja,
  -- con el mismo criterio que ya rige para el borrado de una venta en efectivo.
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

    -- El movimiento del gasto es NEGATIVO (lo garantiza el guard de importe
    -- positivo del alta), así que -v_cash_amount da el INGRESO positivo que
    -- repone la plata en el cajón. Si por cualquier camino el movimiento
    -- fuera positivo, la contra-partida sale negativa y compensa igual: la
    -- reversa es siempre el opuesto exacto de lo que se posteó.
    v_cash_reversal_id := public.c28_register_cash_movement(
      -- qa-integral-modulos (G16/H11): la reversa lleva el motivo del gasto
      -- borrado (mismo criterio que el alta y que el backfill de la seccion 3).
      v_open_session_id, -v_cash_amount, 'expense_reversal', p_expense_id,
      v_expense.description
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled ───────────
  -- Loop calcado del de rpc_delete_sale_operation. Se usa _register_bank_movement
  -- (el escritor crudo) y NO _pay_register_operation_bank_movement: la reversa
  -- no tiene que volver a resolver la cuenta ni volver a evaluar el guard de
  -- período conciliado — va contra la MISMA cuenta del movimiento original.
  -- Es el único uso autorizado del escritor crudo en este change (D2).
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
      -- qa-integral-modulos (G16/H11): el espejo nombra al gasto borrado.
      -- El marcador 'Reversión por borrado de gasto' se CONSERVA: el gate
      -- test_gastos_forma_pago (5.5/5.7) lo exige como ancla del contrato.
      'Reversión por borrado de gasto' || COALESCE(': ' || v_expense.description, '')
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  -- ── El borrado, DESPUÉS de las dos compensaciones ────────────────────────
  DELETE FROM public.expenses WHERE id = p_expense_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'deleted',           true,
    'cash_reversal_id',  v_cash_reversal_id,
    'bank_reversals',    v_bank_reversals
  );
END;
$function$
