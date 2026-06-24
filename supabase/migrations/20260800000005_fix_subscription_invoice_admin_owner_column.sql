-- =============================================================================
-- HOTFIX v22: rpc_emit_subscription_payment_cae — columna de owner incorrecta
--
-- BUG: la versión original (migración 20260724000002) resolvía el perfil fiscal
-- del admin de plataforma con un JOIN a `accounts.owner_id`, pero esa columna
-- NO existe — la columna real es `accounts.owner_user_id`. En tiempo de
-- ejecución Postgres lanzaba `42703 undefined_column`, que no está mapeado como
-- código de negocio en el backend (backend/core/errors.py) y degradaba a un
-- 500 genérico "Error interno de base de datos." al apretar "Enviar al ARCA"
-- en admin/pagos (Recibos de Pago).
--
-- No se detectó en los tests porque mockean el RPC; un typo de columna a nivel
-- SQL solo se ve contra la DB real.
--
-- FIX: CREATE OR REPLACE con la única corrección `a.owner_id` → `a.owner_user_id`.
-- Validado contra prod: el JOIN corregido resuelve a UN único perfil fiscal
-- (el del admin, CUIT 20-42266245-7, ambiente producción).
--
-- APPLY: npx supabase db push (NUNCA MCP apply_migration). El CI (deploy.yml)
-- lo aplica automáticamente al mergear a main.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_emit_subscription_payment_cae(
  p_receipt_id        text,       -- billing_events.id (UUID as text)
  p_point_of_sale_id  uuid        DEFAULT NULL,
  p_receptor_doc_tipo integer     DEFAULT 99,  -- 80=CUIT, 96=DNI, 99=sin identificar
  p_receptor_doc_nro  text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_receipt          RECORD;
  v_profile          RECORD;
  v_pv               RECORD;
  v_effective_pv_id  uuid;
  v_active_pv_count  integer;
  v_doc_number       bigint;
  v_doc_id           uuid;
  v_receipt_uuid     uuid;
BEGIN
  -- Parse receipt_id as UUID
  BEGIN
    v_receipt_uuid := p_receipt_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'receipt_not_found: receipt_id is not a valid UUID: %', p_receipt_id
      USING ERRCODE = 'P0404';
  END;

  -- Look up the billing_event (subscription payment receipt)
  SELECT be.id, be.amount, be.user_id, be.to_plan
  INTO   v_receipt
  FROM   billing_events be
  WHERE  be.id = v_receipt_uuid
    AND  be.event_type = 'plan_upgraded';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'receipt_not_found: no se encontró el recibo de pago: %', p_receipt_id
      USING ERRCODE = 'P0404';
  END IF;

  -- Idempotency guard at DB level (belt + suspenders; service checks first)
  IF EXISTS (
    SELECT 1 FROM fiscal_documents
    WHERE  subscription_payment_id = p_receipt_id
  ) THEN
    RAISE EXCEPTION 'already_emitted: ya existe un comprobante para el recibo: %', p_receipt_id
      USING ERRCODE = 'P0409';
  END IF;

  -- Find the platform admin fiscal_profile.
  -- The platform admin (Aliadata) has their fiscal_profile in fiscal_profiles.
  -- We look up the profile of the account whose owner has role = 'admin' in profiles.
  -- This assumes a single platform-admin account (current architecture: 1 admin user).
  -- FIX (20260800000005): la columna de owner en `accounts` es `owner_user_id`,
  -- no `owner_id` (que no existe). El typo causaba 42703 → 500 genérico.
  SELECT fp.id, fp.iva_condition, fp.ambiente, fp.account_id
  INTO   v_profile
  FROM   fiscal_profiles fp
  JOIN   accounts a ON a.id = fp.account_id
  JOIN   profiles pr ON pr.id = a.owner_user_id
  WHERE  pr.role = 'admin'
  LIMIT  1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_profile_not_found: la cuenta admin no tiene perfil fiscal configurado'
      USING ERRCODE = 'P0404';
  END IF;

  -- Resolve point of sale (same logic as rpc_emit_pending_cae, D11)
  IF p_point_of_sale_id IS NOT NULL THEN
    SELECT id, numero INTO v_pv
    FROM   points_of_sale
    WHERE  id = p_point_of_sale_id
      AND  account_id = v_profile.account_id
      AND  is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'point_of_sale_not_found_or_inactive: el punto de venta no existe o está inactivo'
        USING ERRCODE = 'P0404';
    END IF;
    v_effective_pv_id := v_pv.id;

  ELSE
    SELECT count(*) INTO v_active_pv_count
    FROM   points_of_sale
    WHERE  account_id = v_profile.account_id AND is_active = TRUE;

    IF v_active_pv_count = 0 THEN
      RAISE EXCEPTION 'no_active_point_of_sale: la cuenta no tiene puntos de venta activos'
        USING ERRCODE = 'P0404';
    ELSIF v_active_pv_count > 1 THEN
      RAISE EXCEPTION 'ambiguous_point_of_sale: la cuenta tiene % puntos de venta activos — especificá point_of_sale_id', v_active_pv_count
        USING ERRCODE = 'P0422';
    ELSE
      SELECT id, numero INTO v_pv
      FROM   points_of_sale
      WHERE  account_id = v_profile.account_id AND is_active = TRUE;
      v_effective_pv_id := v_pv.id;
    END IF;
  END IF;

  -- Factura C (monotributista emisor — always for Aliadata)
  v_doc_number := public.rpc_next_document_number(v_effective_pv_id, 'factura_c');

  -- Insert fiscal_document with subscription_payment_id for idempotency
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    total, status,
    subscription_payment_id
  ) VALUES (
    v_profile.account_id, v_profile.id, v_effective_pv_id,
    'factura_c', v_pv.numero, v_doc_number,
    COALESCE(v_receipt.amount, 0), 'pending_cae',
    p_receipt_id
  )
  RETURNING id INTO v_doc_id;

  RETURN jsonb_build_object(
    'fiscal_document_id',       v_doc_id,
    'point_of_sale_id',         v_effective_pv_id,
    'punto_de_venta',           v_pv.numero,
    'comprobante_type',         'factura_c',
    'number',                   v_doc_number,
    'status',                   'pending_cae',
    'subscription_payment_id',  p_receipt_id,
    'total',                    COALESCE(v_receipt.amount, 0)
  );
END;
$function$;

-- Re-aplicar grants (idempotente; persisten tras CREATE OR REPLACE pero se
-- re-emiten por seguridad).
REVOKE ALL     ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) TO service_role;

-- ── VERIFICATION (post-push) ─────────────────────────────────────────────────
--   SELECT count(*) FROM pg_proc WHERE proname='rpc_emit_subscription_payment_cae'; -- 1
--   -- El JOIN corregido debe resolver al perfil fiscal del admin:
--   SELECT fp.id FROM fiscal_profiles fp
--     JOIN accounts a ON a.id = fp.account_id
--     JOIN profiles pr ON pr.id = a.owner_user_id
--     WHERE pr.role='admin'; -- 1 row
-- =============================================================================
