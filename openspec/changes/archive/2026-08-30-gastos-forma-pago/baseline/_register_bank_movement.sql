-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-29, via
-- pg_get_functiondef(oid) -- task 1.6 de gastos-forma-pago.
-- MAX(version) al momento de la captura: 20261014000001 (263 migraciones).
-- md5(pg_get_functiondef) = 6005feacb6c1a62bb1918f8f4d47949e - length = 1943.
-- Rol en el change: REUSO SIN TOCAR: escritor crudo, reservado EXCLUSIVAMENTE para la reversa por borrado (D8).
--
-- Procedencia del byte exacto: el cuerpo se materializo desde el stack local
-- (supabase db reset sobre las mismas 263 migraciones) y se verifico contra PROD
-- por md5 EXACTO del pg_get_functiondef vivo. El stack local guarda CR embebidos
-- (los .sql del working tree estan en CRLF por core.autocrlf=true), por eso el
-- hash se calcula sobre replace(def, chr(13), '') -- que da byte-identico a PROD.

CREATE OR REPLACE FUNCTION public._register_bank_movement(p_bank_account_id uuid, p_amount numeric, p_type text, p_source_doc_type text DEFAULT NULL::text, p_source_doc_ref uuid DEFAULT NULL::uuid, p_value_date date DEFAULT NULL::date, p_branch_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ba              public.bank_accounts%ROWTYPE;
  v_prev_balance    numeric(14,2);
  v_balance_after   numeric(14,2);
  v_movement_id     uuid;
BEGIN
  -- D4: FOR UPDATE sobre la fila de bank_accounts para serializar el cálculo
  -- de balance_after (mismo patrón que c28_register_cash_movement sobre cash_sessions)
  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  -- Calcular saldo previo: opening_balance + suma de los amounts de los movimientos previos.
  -- (SUM(amount), NO MAX(balance_after): el saldo corriente puede bajar tras un egreso,
  --  y MAX devolvería un saldo previo incorrecto. FOR UPDATE arriba serializa el cálculo.)
  SELECT v_ba.opening_balance + COALESCE(SUM(bm.amount), 0)
  INTO v_prev_balance
  FROM public.bank_movements bm
  WHERE bm.bank_account_id = p_bank_account_id;

  v_balance_after := v_prev_balance + p_amount;

  -- INSERT append-only; copia account_id de la cabecera (D2 — inmutable)
  INSERT INTO public.bank_movements
    (bank_account_id, account_id, amount, balance_after, movement_type,
     value_date, branch_id, source_doc_type, source_doc_ref, description)
  VALUES
    (p_bank_account_id, v_ba.account_id, p_amount, v_balance_after, p_type,
     p_value_date, p_branch_id, p_source_doc_type, p_source_doc_ref, p_description)
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$function$
