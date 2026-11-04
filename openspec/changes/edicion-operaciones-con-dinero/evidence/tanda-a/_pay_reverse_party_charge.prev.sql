CREATE OR REPLACE FUNCTION public._pay_reverse_party_charge(p_account_id uuid, p_party_kind text, p_party_account_id uuid, p_amount numeric, p_reference_id uuid, p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_movement_id uuid;
BEGIN
  IF p_party_kind = 'customer' THEN

    BEGIN
      v_movement_id := public.c30_register_customer_account_movement(
        p_party_account_id, -p_amount, 'credit_note', p_reference_id
      );
    EXCEPTION
      WHEN SQLSTATE 'P0409' THEN
        RAISE EXCEPTION 'reversal_would_go_negative: el cliente ya canceló esta venta — registrá primero la devolución del pago antes de borrar la operación.'
          USING ERRCODE = 'P0425';
    END;

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'CustomerAccountChargeReversed',
      'CustomerAccount',
      p_party_account_id,
      jsonb_build_object(
        'account_id',          p_account_id,
        'customer_account_id', p_party_account_id,
        'reference_id',        p_reference_id,
        'operation_id',        p_operation_id,
        'amount',              -p_amount,
        'occurred_at',         now()
      ),
      now()
    );

  ELSIF p_party_kind = 'supplier' THEN

    BEGIN
      v_movement_id := public.c30_register_supplier_account_movement(
        p_party_account_id, -p_amount, 'debit_note', p_reference_id
      );
    EXCEPTION
      WHEN SQLSTATE 'P0409' THEN
        RAISE EXCEPTION 'reversal_would_go_negative: el proveedor ya cobró esta compra — registrá primero la devolución del pago antes de borrar la operación.'
          USING ERRCODE = 'P0425';
    END;

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'SupplierAccountChargeReversed',
      'SupplierAccount',
      p_party_account_id,
      jsonb_build_object(
        'account_id',          p_account_id,
        'supplier_account_id', p_party_account_id,
        'reference_id',        p_reference_id,
        'operation_id',        p_operation_id,
        'amount',              -p_amount,
        'occurred_at',         now()
      ),
      now()
    );

  ELSE
    RAISE EXCEPTION 'invalid_party_kind: % (esperado customer|supplier)', p_party_kind
      USING ERRCODE = 'P0400';
  END IF;

  RETURN v_movement_id;
END;
$function$

