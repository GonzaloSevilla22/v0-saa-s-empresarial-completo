-- =============================================================================
-- CHANGE: bugfix/receipts-subscription-charges (2026-09-04, governance CRÍTICO
-- — billing, primera suscripción real de mp-real-subscriptions).
--
-- LAGUNA: "Recibos de Pago" del admin (backend/repositories/billing_repository.py
-- ::_RECEIPT_SELECT / list_receipts) y el numerador de recibos (trigger
-- trg_assign_billing_receipt_number → assign_billing_receipt_number()) sólo
-- contemplaban el flujo LEGACY de pago único: event_type = 'plan_upgraded'.
-- Los cobros de suscripción de mp-real-subscriptions escriben
-- event_type = 'subscription_payment_approved' con mercadopago_payment_id,
-- amount y to_plan — todo lo que un recibo necesita — pero NUNCA reciben
-- receipt_number ni aparecen en la lista/PDF/Factura C del admin.
--
-- Caso real (2026-09-04, cuenta b6005a59…, owner tubecoventas6@gmail.com):
--   billing_events.mercadopago_payment_id = '176341057469', amount = 24900,
--   to_plan = 'inicial', created_at = 2026-09-04T23:30:30Z, receipt_number = NULL.
-- El recibo legacy existente es RC-2026-000001 (13/06, $69.900) — la
-- numeración tiene que CONTINUAR (000002), nunca reordenar ni renumerar.
--
-- QUÉ HACE ESTA MIGRACIÓN:
--   (1) CREATE OR REPLACE de assign_billing_receipt_number() — partiendo del
--       cuerpo VIVO de prod (pg_get_functiondef) — para que numere también
--       'subscription_payment_approved'. El trigger y su disparo NO cambian.
--   (2) CREATE OR REPLACE de rpc_emit_subscription_payment_cae() — hallazgo
--       real de la verificación de este fix (instrucción 2 del brief: "Factura
--       C en routers/fiscal.py si toma el recibo por id"): la RPC que emite
--       la Factura C de un recibo de suscripción resuelve el billing_event
--       con `AND be.event_type = 'plan_upgraded'` — con esa condición sin
--       tocar, un cobro de suscripción recién visible en la lista seguiría
--       fallando con receipt_not_found (P0404) al intentar facturarlo. Mismo
--       patrón: CREATE OR REPLACE partiendo del cuerpo VIVO, sólo se amplía
--       la condición.
--   (3) Backfill idempotente: asigna receipt_number a los
--       'subscription_payment_approved' existentes sin número, en orden
--       created_at/id, usando la MISMA secuencia billing_receipt_seq (nunca
--       una secuencia nueva — la numeración es continua entre los dos
--       flujos). Hoy es 1 fila (el caso real de arriba); el loop soporta N.
--       Reaplicar esta migración es un no-op: el WHERE receipt_number IS NULL
--       ya no matchea las filas ya numeradas.
--
-- NO se toca: el índice único billing_events_receipt_number_key (sigue
-- siendo válido — los números siguen siendo únicos entre los dos flujos
-- porque comparten la misma secuencia), ni el trigger en sí (mismo
-- BEFORE INSERT, misma función, sólo cambia su condición interna).
-- =============================================================================


-- ── (1) Trigger: numera pagos aprobados Y cobros de suscripción ──────────────
CREATE OR REPLACE FUNCTION public.assign_billing_receipt_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.event_type IN ('plan_upgraded', 'subscription_payment_approved')
     AND NEW.receipt_number IS NULL THEN
    NEW.receipt_number :=
      'RC-' || to_char(now() AT TIME ZONE 'UTC', 'YYYY') || '-' ||
      lpad(nextval('billing_receipt_seq')::text, 6, '0');
  END IF;
  RETURN NEW;
END;
$function$;


-- ── (2) Factura C de suscripción: reconoce el recibo con ambos event_type ───
-- Cuerpo idéntico al vivo de prod (pg_get_functiondef, verificado antes de
-- escribir esta migración) salvo la condición del SELECT sobre billing_events.
CREATE OR REPLACE FUNCTION public.rpc_emit_subscription_payment_cae(p_receipt_id text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_receptor_doc_tipo integer DEFAULT 99, p_receptor_doc_nro text DEFAULT NULL::text)
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
    AND  be.event_type IN ('plan_upgraded', 'subscription_payment_approved');

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
  -- Normalizamos DocTipo=99 → NULL para que el adapter aplique su default consistente.
  -- v3-snapshot-pattern: no hay fila en clients para el suscriptor de plataforma
  -- → receptor_legal_name/receptor_iva_condition quedan NULL (sin fuente, D3/D4).
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


-- ── (3) Backfill idempotente ──────────────────────────────────────────────────
-- Numera los subscription_payment_approved existentes sin receipt_number, en
-- orden cronológico, con la MISMA secuencia billing_receipt_seq (continúa la
-- numeración legacy, nunca la reinicia). Año del recibo = año de created_at
-- (mismo criterio que el backfill original de 20260628000001), no el de
-- ejecución de esta migración. Reaplicar es un no-op: la segunda vez el
-- WHERE receipt_number IS NULL no encuentra ninguna fila.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT id, created_at
    FROM   public.billing_events
    WHERE  event_type = 'subscription_payment_approved'
      AND  receipt_number IS NULL
    ORDER  BY created_at, id
  LOOP
    UPDATE public.billing_events
    SET    receipt_number =
             'RC-' || to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY') || '-' ||
             lpad(nextval('billing_receipt_seq')::text, 6, '0')
    WHERE  id = r.id;
  END LOOP;
END;
$$;
