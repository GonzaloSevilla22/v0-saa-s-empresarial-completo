CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_supplier_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_uid        uuid;
    v_account_id uuid;
BEGIN
    v_uid := (SELECT auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT cai INTO v_account_id
    FROM   current_account_ids() AS cai
    LIMIT  1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
            USING ERRCODE = 'P0403';
    END IF;

    -- remitos-compra (D8): wrapper de la misma firma, ACL y rechazo sin sesión. TODA la lógica
    -- vive en _purchase_operation_core; acá NO hay ningún parámetro de origen de remito.
    RETURN public._purchase_operation_core(
        v_account_id, p_idempotency_key, p_date, p_description, p_items,
        p_branch_id, p_cost_center_id, p_payment_method_id, p_bank_account_id,
        p_supplier_id, p_cash_session_id, p_due_date, NULL);
END;
$function$
;
-- COMMENT: remitos-compra (D8): wrapper público de la compra directa, de la misma firma, ACL y rechazo sin sesión (42501) que antes. Resuelve la cuenta (current_account_ids() LIMIT 1) y llama a _purchase_operation_core con origen nulo: TODA la lógica de la compra (idempotencia DEC-06, validaciones, stock, caja, banco, cuenta corriente, evento) vive en el núcleo. No acepta ningún parámetro de origen de remito.
-- ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- md5(prosrc sin CR): 98e045e69109fe903aedd7ca2d78e448

