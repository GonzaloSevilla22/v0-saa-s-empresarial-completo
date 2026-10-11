CREATE OR REPLACE FUNCTION public.rpc_commercial_issuer(p_account_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF p_account_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.current_account_ids() AS cai WHERE cai = p_account_id
  ) THEN
    RAISE EXCEPTION 'account_not_found: %', p_account_id USING ERRCODE = 'P0404';
  END IF;

  SELECT jsonb_build_object(
           'nombre_fantasia',     fp.nombre_fantasia,
           'razon_social',        fp.razon_social,
           'cuit',                fp.cuit,
           'domicilio_comercial', fp.domicilio_comercial,
           'business_name',       pr.business_name,
           'phone',               pr.phone)
  INTO   v_result
  FROM   public.accounts a
  LEFT JOIN public.fiscal_profiles fp ON fp.account_id = a.id
  LEFT JOIN public.profiles pr        ON pr.id = a.owner_user_id
  WHERE  a.id = p_account_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'account_not_found: %', p_account_id USING ERRCODE = 'P0404';
  END IF;
  RETURN v_result;
END;
$function$
