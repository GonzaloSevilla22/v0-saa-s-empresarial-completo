-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-22, vía
-- pg_get_functiondef(oid) — task 1.1 de delete-guard-ledgers.
-- MAX(version) al momento de la captura: 20261004000002.

CREATE OR REPLACE FUNCTION public.c30_register_customer_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_acc           public.customer_accounts%ROWTYPE;
  v_balance_after numeric(15,2);
  v_movement_id   uuid;
BEGIN
  -- D1: lock de fila de cabecera para serializar (FOR UPDATE)
  SELECT * INTO v_acc
  FROM public.customer_accounts
  WHERE id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'customer_account_not_found: %', p_account_id
      USING ERRCODE = 'P0404';
  END IF;

  v_balance_after := v_acc.balance + p_amount;

  -- OQ-1 (RESUELTO): invariante balance >= 0 — guard explícito antes del INSERT
  IF v_balance_after < 0 THEN
    RAISE EXCEPTION 'overpayment: el pago (%) excede el saldo deudor (%)',
      ABS(p_amount), v_acc.balance
      USING ERRCODE = 'P0409';
  END IF;

  -- INSERT append-only en el ledger
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, reference_id, created_by)
  VALUES
    (p_account_id, v_acc.account_id, p_amount, v_balance_after, p_type, p_reference_id, auth.uid())
  RETURNING id INTO v_movement_id;

  -- UPDATE de la cabecera (UPDATE-then-INSERT bajo FOR UPDATE, D1/gotcha #2)
  UPDATE public.customer_accounts
  SET balance = v_balance_after
  WHERE id = p_account_id;

  RETURN v_movement_id;
END;
$function$
