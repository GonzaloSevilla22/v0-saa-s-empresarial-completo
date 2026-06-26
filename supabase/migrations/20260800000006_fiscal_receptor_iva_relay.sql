-- =============================================================================
-- MIGRATION: 20260800000006_fiscal_receptor_iva_relay.sql
-- CHANGE:    fiscal-receptor-iva-relay
-- Design ref: D1 (resolver receptor en emisión y persistir), D4 (aditiva, NULL=actual)
--             Gate 0 sign-off PO 2026-06-26 (OQ-1/2/3)
--
-- Cierra los Gaps 1+2 de la investigación del modelo de facturación (#355):
--   - fiscal_documents suma columnas para la identidad del receptor (DocTipo/DocNro)
--     y el desglose de IVA (neto/iva/alícuota). Todas NULLABLE.
--   - rpc_emit_pending_cae captura y persiste esos campos al emitir.
--   - rpc_emit_subscription_payment_cae DEJA DE DESCARTAR p_receptor_doc_tipo/nro
--     (bug latente: hoy los recibe pero no los persiste).
--
-- INVARIANTE (rollback-safe): un comprobante con columnas NULL se emite EXACTAMENTE
-- como hoy (DocTipo=99 sin identificar; Factura C sin array Iva). Ningún comprobante
-- existente cambia. Sin backfill.
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — CLAUDE.md regla).
--        El CI (deploy.yml) lo aplica al mergear a main.
-- ROLLBACK:
--   ALTER TABLE public.fiscal_documents
--     DROP COLUMN IF EXISTS receptor_doc_tipo, DROP COLUMN IF EXISTS receptor_doc_nro,
--     DROP COLUMN IF EXISTS neto, DROP COLUMN IF EXISTS iva_amount,
--     DROP COLUMN IF EXISTS iva_alicuota_id;
--   + restaurar el cuerpo previo de las RPC (migraciones 20260627000001 / 20260800000005).
-- =============================================================================

-- ─── 1. Columnas aditivas en fiscal_documents (NULLABLE, sin backfill) ────────
ALTER TABLE public.fiscal_documents
    ADD COLUMN IF NOT EXISTS receptor_doc_tipo  smallint      NULL,
    ADD COLUMN IF NOT EXISTS receptor_doc_nro   text          NULL,
    ADD COLUMN IF NOT EXISTS neto               numeric(15,2) NULL,
    ADD COLUMN IF NOT EXISTS iva_amount         numeric(15,2) NULL,
    ADD COLUMN IF NOT EXISTS iva_alicuota_id    smallint      NULL;

COMMENT ON COLUMN public.fiscal_documents.receptor_doc_tipo IS
    'fiscal-receptor-iva-relay: tipo de documento del receptor ante AFIP — 80=CUIT, 96=DNI, 99/NULL=sin identificar.';
COMMENT ON COLUMN public.fiscal_documents.receptor_doc_nro IS
    'fiscal-receptor-iva-relay: número de documento del receptor (sin guiones). NULL = sin identificar.';
COMMENT ON COLUMN public.fiscal_documents.neto IS
    'fiscal-receptor-iva-relay: importe neto gravado (para el array Iva de Factura A/B). NULL para Factura C.';
COMMENT ON COLUMN public.fiscal_documents.iva_amount IS
    'fiscal-receptor-iva-relay: importe de IVA discriminado (Factura A/B). NULL para Factura C.';
COMMENT ON COLUMN public.fiscal_documents.iva_alicuota_id IS
    'fiscal-receptor-iva-relay: id de alícuota AFIP (5 = 21%). NULL para Factura C.';


-- ─── 2. rpc_emit_pending_cae — captura receptor + IVA (cambia firma) ──────────
-- Se agrega DROP de la firma vieja (4 args) porque agregar params con DEFAULT crea
-- un overload nuevo y dejaría AMBAS firmas → "function name is not unique" al llamar
-- con 4 args nombrados. El backend ya invoca con notación nombrada (p_* => $n), así
-- que los params nuevos defaultean a NULL sin tocar el caller existente.
DROP FUNCTION IF EXISTS public.rpc_emit_pending_cae(text, numeric, uuid, uuid);

CREATE OR REPLACE FUNCTION public.rpc_emit_pending_cae(
  p_comprobante_type    text,
  p_total               numeric,
  p_client_id           uuid    DEFAULT NULL,
  p_point_of_sale_id    uuid    DEFAULT NULL,
  -- fiscal-receptor-iva-relay: identificación del receptor + desglose de IVA (opcionales)
  p_receptor_doc_tipo   integer DEFAULT NULL,  -- 80=CUIT, 96=DNI, NULL/99=sin identificar
  p_receptor_doc_nro    text    DEFAULT NULL,  -- sin guiones
  p_neto                numeric DEFAULT NULL,  -- neto gravado (Factura A/B)
  p_iva_amount          numeric DEFAULT NULL,  -- IVA discriminado (Factura A/B)
  p_iva_alicuota_id     integer DEFAULT NULL   -- id de alícuota AFIP (5 = 21%)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_profile          RECORD;
  v_pv               RECORD;
  v_effective_pv_id  uuid;
  v_active_pv_count  integer;
  v_doc_number       bigint;
  v_doc_id           uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: solo owner/admin puede emitir
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can emit fiscal documents'
      USING ERRCODE = 'P0401';
  END IF;

  -- Obtener perfil fiscal de la cuenta
  SELECT id, iva_condition, ambiente INTO v_profile
  FROM   public.fiscal_profiles
  WHERE  account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_profile_not_found: la cuenta no tiene perfil fiscal configurado'
      USING ERRCODE = 'P0404';
  END IF;

  -- Resolver PV efectivo (D11)
  IF p_point_of_sale_id IS NOT NULL THEN
    SELECT id, numero INTO v_pv
    FROM   public.points_of_sale
    WHERE  id = p_point_of_sale_id
      AND  account_id = v_account_id
      AND  is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'point_of_sale_not_found_or_inactive: el punto de venta no existe, no pertenece a la cuenta o está inactivo'
        USING ERRCODE = 'P0404';
    END IF;
    v_effective_pv_id := v_pv.id;

  ELSE
    SELECT count(*) INTO v_active_pv_count
    FROM   public.points_of_sale
    WHERE  account_id = v_account_id AND is_active = TRUE;

    IF v_active_pv_count = 0 THEN
      RAISE EXCEPTION 'no_active_point_of_sale: la cuenta no tiene puntos de venta activos'
        USING ERRCODE = 'P0404';
    ELSIF v_active_pv_count > 1 THEN
      RAISE EXCEPTION 'ambiguous_point_of_sale: la cuenta tiene % puntos de venta activos — especificá point_of_sale_id', v_active_pv_count
        USING ERRCODE = 'P0422';
    ELSE
      SELECT id, numero INTO v_pv
      FROM   public.points_of_sale
      WHERE  account_id = v_account_id AND is_active = TRUE;
      v_effective_pv_id := v_pv.id;
    END IF;
  END IF;

  -- Reservar número (lock corto, fuera de transacción larga de la venta — C-29)
  v_doc_number := public.rpc_next_document_number(v_effective_pv_id, p_comprobante_type);

  -- Insertar comprobante en pending_cae (SIN tocar AFIP — D5)
  -- fiscal-receptor-iva-relay: persistir receptor + IVA (NULL = sin identificar / sin IVA).
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    client_id, total, status,
    receptor_doc_tipo, receptor_doc_nro, neto, iva_amount, iva_alicuota_id
  ) VALUES (
    v_account_id, v_profile.id, v_effective_pv_id,
    p_comprobante_type, v_pv.numero, v_doc_number,
    p_client_id, COALESCE(p_total, 0), 'pending_cae',
    p_receptor_doc_tipo, p_receptor_doc_nro, p_neto, p_iva_amount, p_iva_alicuota_id
  )
  RETURNING id INTO v_doc_id;

  RETURN jsonb_build_object(
    'fiscal_document_id', v_doc_id,
    'point_of_sale_id',   v_effective_pv_id,
    'punto_de_venta',     v_pv.numero,
    'comprobante_type',   p_comprobante_type,
    'number',             v_doc_number,
    'status',             'pending_cae'
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer) TO authenticated;

COMMENT ON FUNCTION public.rpc_emit_pending_cae IS
  'C-27 (D5/D11) + fiscal-receptor-iva-relay: emite un comprobante en pending_cae sin tocar AFIP. '
  'Resuelve el PV efectivo (P0422 si ambiguo), reserva número e INSERTA fiscal_documents. '
  'Persiste la identificación del receptor (DocTipo/DocNro) y el desglose de IVA (opcionales, '
  'NULL = consumidor final sin identificar / sin IVA discriminado).';


-- ─── 3. rpc_emit_subscription_payment_cae — persistir el receptor (no descartarlo) ──
-- Misma firma (text, uuid, integer, text): solo se agrega receptor_doc_tipo/nro al INSERT.
-- Bug previo: la función recibía p_receptor_doc_tipo/p_receptor_doc_nro pero NO los
-- persistía → el receptor se perdía y AFIP recibía DocTipo=99 (vía el default del adapter).
CREATE OR REPLACE FUNCTION public.rpc_emit_subscription_payment_cae(
  p_receipt_id        text,
  p_point_of_sale_id  uuid        DEFAULT NULL,
  p_receptor_doc_tipo integer     DEFAULT 99,
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
  BEGIN
    v_receipt_uuid := p_receipt_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'receipt_not_found: receipt_id is not a valid UUID: %', p_receipt_id
      USING ERRCODE = 'P0404';
  END;

  SELECT be.id, be.amount, be.user_id, be.to_plan
  INTO   v_receipt
  FROM   billing_events be
  WHERE  be.id = v_receipt_uuid
    AND  be.event_type = 'plan_upgraded';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'receipt_not_found: no se encontró el recibo de pago: %', p_receipt_id
      USING ERRCODE = 'P0404';
  END IF;

  IF EXISTS (
    SELECT 1 FROM fiscal_documents
    WHERE  subscription_payment_id = p_receipt_id
  ) THEN
    RAISE EXCEPTION 'already_emitted: ya existe un comprobante para el recibo: %', p_receipt_id
      USING ERRCODE = 'P0409';
  END IF;

  -- Perfil fiscal del admin de plataforma (Aliadata). owner_user_id (no owner_id).
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

  v_doc_number := public.rpc_next_document_number(v_effective_pv_id, 'factura_c');

  -- INSERT con subscription_payment_id (idempotencia) + receptor persistido.
  -- fiscal-receptor-iva-relay: persistir receptor_doc_tipo/nro (antes se descartaban).
  -- Normalizamos DocTipo=99 → NULL para que el adapter aplique su default consistente.
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    total, status,
    subscription_payment_id,
    receptor_doc_tipo, receptor_doc_nro
  ) VALUES (
    v_profile.account_id, v_profile.id, v_effective_pv_id,
    'factura_c', v_pv.numero, v_doc_number,
    COALESCE(v_receipt.amount, 0), 'pending_cae',
    p_receipt_id,
    NULLIF(p_receptor_doc_tipo, 99), p_receptor_doc_nro
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
GRANT  EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_subscription_payment_cae(text, uuid, integer, text) TO service_role;


-- ─── 4. VERIFICATION (post-push) ──────────────────────────────────────────────
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name='fiscal_documents'
--      AND column_name IN ('receptor_doc_tipo','receptor_doc_nro','neto','iva_amount','iva_alicuota_id'); -- 5 rows
--   SELECT count(*) FROM pg_proc WHERE proname='rpc_emit_pending_cae';                 -- 1 (firma nueva)
--   SELECT count(*) FROM pg_proc WHERE proname='rpc_emit_subscription_payment_cae';    -- 1
-- =============================================================================
