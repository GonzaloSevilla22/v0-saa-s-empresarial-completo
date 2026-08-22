-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-22, vía
-- pg_get_functiondef(oid) — task 1.1 de delete-guard-ledgers.
-- MAX(version) al momento de la captura: 20261004000002.

CREATE OR REPLACE FUNCTION public._pay_register_operation_bank_movement(p_account_id uuid, p_kind text, p_payment_method_id uuid, p_bank_account_id uuid, p_amount_abs numeric, p_direction text, p_source_doc_type text, p_source_doc_ref uuid, p_value_date date, p_branch_id uuid, p_description text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_resolved_account uuid;
  v_movement_type    text;
  v_signed_amount    numeric;
  v_is_bank_kind     boolean;
  v_closed_sessions  integer;
BEGIN
  v_is_bank_kind := p_kind IS NOT NULL AND p_kind IN ('transfer', 'card', 'check', 'wallet');

  -- D2: informar una cuenta bancaria explícita junto a un kind NO bancario
  -- es un error del cliente — se rechaza, no se ignora en silencio.
  IF p_bank_account_id IS NOT NULL AND NOT v_is_bank_kind THEN
    RAISE EXCEPTION 'bank_account_requires_bank_kind: se informó una cuenta bancaria explícita para un kind no bancario (%)', COALESCE(p_kind, 'NULL')
      USING ERRCODE = 'P0400';
  END IF;

  -- cash | credit | other (o NULL, camino sin imputación): etiqueta, sin
  -- efecto bancario. No es un error — es el default de toda forma de pago.
  IF NOT v_is_bank_kind THEN
    RETURN NULL;
  END IF;

  IF p_direction NOT IN ('in', 'out') THEN
    RAISE EXCEPTION 'invalid_direction: % (esperado in|out)', p_direction
      USING ERRCODE = 'P0400';
  END IF;

  v_resolved_account := public._pay_resolve_bank_account(p_account_id, p_payment_method_id, p_bank_account_id);

  -- D2 regla 3: sin cuenta resuelta (ni override ni default) → no escribe,
  -- la operación sigue su curso normal. La validación de la cuenta (P0412),
  -- si la hubiera, ya la disparó el helper de arriba.
  IF v_resolved_account IS NULL THEN
    RETURN NULL;
  END IF;

  -- D3: mapa kind → movement_type. card se asienta bruto con el mismo
  -- movement_type en ambas direcciones (el signo distingue venta/compra);
  -- transfer/check/wallet se ramifican transfer_in / transfer_out.
  IF p_kind = 'card' THEN
    v_movement_type := 'card_settlement';
  ELSIF p_direction = 'in' THEN
    v_movement_type := 'transfer_in';
  ELSE
    v_movement_type := 'transfer_out';
  END IF;

  v_signed_amount := CASE p_direction WHEN 'in' THEN p_amount_abs ELSE -p_amount_abs END;

  -- D4: guard de período conciliado — rechaza la operación ENTERA (RAISE
  -- propaga y revierte todo, no sólo el movimiento) si value_date cae dentro
  -- del período de una sesión CLOSED de esta cuenta.
  SELECT count(*) INTO v_closed_sessions
  FROM public.reconciliation_sessions rs
  WHERE rs.bank_account_id = v_resolved_account
    AND rs.status = 'closed'
    AND p_value_date BETWEEN rs.period_from AND rs.period_to;

  IF v_closed_sessions > 0 THEN
    RAISE EXCEPTION 'bank_period_reconciled: la fecha % cae dentro de un período ya conciliado y cerrado de la cuenta bancaria — registrá el ajuste como movimiento bancario manual', p_value_date
      USING ERRCODE = 'P0424';
  END IF;

  RETURN public._register_bank_movement(
    v_resolved_account,
    v_signed_amount,
    v_movement_type,
    p_source_doc_type,
    p_source_doc_ref,
    p_value_date,
    p_branch_id,
    p_description
  );
END;
$function$
