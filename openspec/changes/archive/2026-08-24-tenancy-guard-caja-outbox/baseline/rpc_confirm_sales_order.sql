-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-24, vía
-- pg_get_functiondef(oid) — task 1.5 de tenancy-guard-caja-outbox (tramo h1).
-- MAX(version) al momento de la captura: 20261012000001 (261 migraciones).
-- md5(pg_get_functiondef) = 38f2902380018ef717ff5b04cc711d20 · length = 777.
-- REFERENCIA — no se toca: wrapper fino, hereda el guard del core.
-- prosecdef = true · anon=false · authenticated=true · service_role=true.

CREATE OR REPLACE FUNCTION public.rpc_confirm_sales_order(p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid DEFAULT NULL::uuid, p_comprobante_type text DEFAULT NULL::text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    p_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal,
    p_payment_method_id,
    p_bank_account_id
  );
END;
$function$
