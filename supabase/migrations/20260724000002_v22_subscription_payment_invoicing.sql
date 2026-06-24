-- =============================================================================
-- v22-afip-delegation-billing: Subscription Payment Invoicing (Admin)
--
-- Adds subscription_payment_id to fiscal_documents + a new RPC
-- rpc_emit_subscription_payment_cae that emits a Factura C for a SaaS
-- subscription payment receipt on behalf of the platform admin (Aliadata,
-- CUIT 20422662457, monotributista).
--
-- Design decisions (PO sign-off 2026-06-24):
--   - The platform admin (Aliadata) has their OWN fiscal_profile in the DB.
--   - A receipt is a billing_events row with event_type = 'plan_upgraded'.
--   - The receptor is identified by CUIT (DocTipo=80) or DNI (DocTipo=96)
--     captured in the admin dialog at emission time (not consumidor_final).
--   - Idempotency: unique constraint on fiscal_documents.subscription_payment_id.
--   - Governance: CRÍTICO — only authenticated admin can call this RPC via
--     the service (backend already enforces require_role admin).
--
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.rpc_emit_subscription_payment_cae CASCADE;
--   ALTER TABLE public.fiscal_documents DROP COLUMN IF EXISTS subscription_payment_id;
-- =============================================================================


-- ── 1. Add subscription_payment_id to fiscal_documents ───────────────────────

ALTER TABLE public.fiscal_documents
  ADD COLUMN IF NOT EXISTS subscription_payment_id text NULL;

-- Unique constraint: one fiscal_document per subscription payment receipt.
-- Prevents double-invoicing the same receipt.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fiscal_documents_subscription_payment_id_key'
      AND conrelid = 'public.fiscal_documents'::regclass
  ) THEN
    ALTER TABLE public.fiscal_documents
      ADD CONSTRAINT fiscal_documents_subscription_payment_id_key
      UNIQUE (subscription_payment_id);
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS fiscal_documents_subscription_payment_id_idx
  ON public.fiscal_documents (subscription_payment_id)
  WHERE subscription_payment_id IS NOT NULL;

COMMENT ON COLUMN public.fiscal_documents.subscription_payment_id IS
  'v22-admin: FK to billing_events.id (text) for subscription payment invoicing. '
  'Unique — prevents double-invoicing the same receipt. NULL for regular sales documents.';


-- ── 2. rpc_emit_subscription_payment_cae ─────────────────────────────────────
--
-- Emits a Factura C for a subscription payment receipt.
-- Called by the platform admin (Aliadata) via POST /fiscal/documents/emit-subscription-payment.
--
-- Unlike rpc_emit_pending_cae (org-scoped via current_account_ids()),
-- this RPC resolves the fiscal_profile of the PLATFORM ADMIN (identified
-- by a fixed CUIT in config or, pragmatically, the first/only 'admin' profile).
--
-- Idempotency: if a fiscal_document already exists for this receipt_id,
-- returns an error (the service layer handles the idempotency check BEFORE
-- calling this RPC to avoid a unique-violation error).
--
-- Security model:
--   SECURITY DEFINER — the admin JWT is validated by the backend service
--   (require_role admin), which then calls this RPC. The definer gives us
--   cross-account read of billing_events + write to fiscal_documents on behalf
--   of the platform account.
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
  SELECT fp.id, fp.iva_condition, fp.ambiente, fp.account_id
  INTO   v_profile
  FROM   fiscal_profiles fp
  JOIN   accounts a ON a.id = fp.account_id
  JOIN   profiles pr ON pr.id = a.owner_id
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

REVOKE ALL     ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) FROM anon;
-- Grant to authenticated (backend validates admin role before calling)
GRANT  EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) TO authenticated;
-- Grant to service_role (for background tasks that open service connections)
GRANT  EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) TO service_role;

COMMENT ON FUNCTION public.rpc_emit_subscription_payment_cae IS
  'v22-admin: emite Factura C para un pago de suscripción SaaS. '
  'Resuelve el perfil fiscal del admin de plataforma (Aliadata). '
  'Idempotencia: UNIQUE(subscription_payment_id) previene doble facturación. '
  'Llamada exclusivamente desde el endpoint admin POST /fiscal/documents/emit-subscription-payment. '
  'El receptor se identifica con CUIT (DocTipo=80) o DNI (DocTipo=96), nunca sin identificar.';


-- ── 3. VERIFICATION (post-push) ──────────────────────────────────────────────
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='fiscal_documents' AND column_name='subscription_payment_id'; -- 1 row
--   SELECT proname FROM pg_proc WHERE proname='rpc_emit_subscription_payment_cae'; -- 1 row
-- =============================================================================
