-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-23, vía
-- pg_get_functiondef(oid) — task 1.4 de cuenta-corriente-party-guard.
-- MAX(version) al momento de la captura: 20261007000001.
-- md5(pg_get_functiondef) = 61c54436467afaf6b43afdbd5a5fa1ad · length = 2222.

CREATE OR REPLACE FUNCTION public._pay_register_party_charge(p_account_id uuid, p_party_kind text, p_party_id uuid, p_amount numeric, p_reference_id uuid, p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_party_account_id uuid;
BEGIN
  IF p_party_kind = 'customer' THEN
    v_party_account_id := public.c30_get_or_create_customer_account(p_account_id, p_party_id);

    PERFORM public.c30_register_customer_account_movement(
      v_party_account_id, p_amount, 'sale', p_reference_id
    );

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'CustomerAccountCharged',
      'CustomerAccount',
      v_party_account_id,
      jsonb_build_object(
        'account_id',          p_account_id,
        'customer_account_id', v_party_account_id,
        'client_id',           p_party_id,
        'sales_order_id',      p_reference_id,
        'operation_id',        p_operation_id,
        'amount',              p_amount,
        'occurred_at',         now()
      ),
      now()
    );

  ELSIF p_party_kind = 'supplier' THEN
    v_party_account_id := public.c30_get_or_create_supplier_account(p_account_id, p_party_id);

    PERFORM public.c30_register_supplier_account_movement(
      v_party_account_id, p_amount, 'purchase', p_reference_id
    );

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'SupplierAccountCharged',
      'SupplierAccount',
      v_party_account_id,
      jsonb_build_object(
        'account_id',           p_account_id,
        'supplier_account_id',  v_party_account_id,
        'supplier_id',          p_party_id,
        'reference_id',         p_reference_id,
        'operation_id',         p_operation_id,
        'amount',               p_amount,
        'occurred_at',          now()
      ),
      now()
    );

  ELSE
    RAISE EXCEPTION 'invalid_party_kind: % (esperado customer|supplier)', p_party_kind
      USING ERRCODE = 'P0400';
  END IF;

  RETURN v_party_account_id;
END;
$function$
