-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-29, via
-- pg_get_functiondef(oid) -- task 1.6 de gastos-forma-pago.
-- MAX(version) al momento de la captura: 20261014000001 (263 migraciones).
-- md5(pg_get_functiondef) = 0a9dcc86484b07a7bf66a52c64b213d0 - length = 1488.
-- Rol en el change: REUSO SIN TOCAR: resolucion override -> default -> NULL. Es el que devuelve NULL en silencio y motiva el guard P0412 en el caller de gasto (D5).
--
-- Procedencia del byte exacto: el cuerpo se materializo desde el stack local
-- (supabase db reset sobre las mismas 263 migraciones) y se verifico contra PROD
-- por md5 EXACTO del pg_get_functiondef vivo. El stack local guarda CR embebidos
-- (los .sql del working tree estan en CRLF por core.autocrlf=true), por eso el
-- hash se calcula sobre replace(def, chr(13), '') -- que da byte-identico a PROD.

CREATE OR REPLACE FUNCTION public._pay_resolve_bank_account(p_account_id uuid, p_payment_method_id uuid, p_bank_account_id_override uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_resolved uuid;
  v_ba       public.bank_accounts%ROWTYPE;
BEGIN
  -- D2 regla 1: override explícito de la operación gana sobre todo.
  IF p_bank_account_id_override IS NOT NULL THEN
    v_resolved := p_bank_account_id_override;
  -- D2 regla 2: default configurado en la forma de pago imputada.
  ELSIF p_payment_method_id IS NOT NULL THEN
    SELECT bank_account_id INTO v_resolved
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = p_account_id;
  END IF;

  -- D2 regla 3: ninguna cuenta resuelta → NULL, camino silencioso y válido.
  IF v_resolved IS NULL THEN
    RETURN NULL;
  END IF;

  -- La cuenta resuelta SHALL validarse siempre: existe, pertenece a la
  -- cuenta, is_active, deleted_at IS NULL. Falla cualquiera → P0412 (mismo
  -- código que ya usan C1/C2 para cuenta inexistente o inactiva).
  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = v_resolved
    AND account_id = p_account_id
    AND is_active = TRUE
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found_or_inactive: % no pertenece a la cuenta, no existe, está inactiva o borrada', v_resolved
      USING ERRCODE = 'P0412';
  END IF;

  RETURN v_resolved;
END;
$function$
