-- =============================================================================
-- MIGRATION: 20260801000001_emit_sale_invoice.sql
-- CHANGE:    facturar-venta-afip
-- Design ref: D1 (endpoint dedicado), D2 (RPC envolvente), D3 (tipo en backend),
--             D5 (receptor desde C-22), D6 (idempotencia fiscal)
--             Gate 0 + OQ-1/2/3 sign-off PO 2026-06-26
--
-- Crea la RPC rpc_emit_sale_invoice que:
--   1. Carga sales_orders con FOR UPDATE y valida:
--        - orden pertenece a la cuenta (P0404)
--        - status = 'confirmed' (P0400)
--        - fiscal_document_id IS NULL (P0409 — idempotencia)
--   2. Lee fiscal_profiles.iva_condition del emisor.
--      Si el emisor es responsable_inscripto → BLOQUEA con P0401 (OQ-1).
--   3. Si hay client_id, lee clients.iva_condition / clients.tax_id.
--   4. Deriva receptor:
--        iva_condition = 'responsable_inscripto' → DocTipo 80 (CUIT)
--        iva_condition = 'monotributista' → DocTipo 96 (DNI) si hay tax_id
--        sin client_id o sin tax_id → NULL/NULL (adapter lo convierte a 99/0)
--   5. Comprobante: monotributista → 'factura_c' (D3).
--   6. Llama rpc_emit_pending_cae(comprobante_type, total, client_id,
--        p_point_of_sale_id, receptor_doc_tipo, receptor_doc_nro, NULL, NULL, NULL)
--   7. UPDATE sales_orders SET fiscal_document_id = <nuevo> en el mismo commit.
--
-- Alcance MVP: solo Factura C (monotributista). A/B bloqueado por OQ-1 (P0401).
-- Sin columnas nuevas (aditivo puro: 1 función).
--
-- GOVERNANCE: FISCAL = CRÍTICO. Apply manual por el PO:
--   npx supabase db push  (NUNCA MCP apply_migration — CLAUDE.md regla dura).
-- ROLLBACK: DROP FUNCTION IF EXISTS public.rpc_emit_sale_invoice(uuid, uuid);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_emit_sale_invoice(
  p_sales_order_id   uuid,
  p_point_of_sale_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid               uuid;
  v_account_id        uuid;
  v_order             RECORD;
  v_profile           RECORD;
  v_client            RECORD;
  v_comprobante_type  text;
  v_receptor_doc_tipo integer;
  v_receptor_doc_nro  text;
  v_emit_result       jsonb;
BEGIN
  -- ── 0. Autenticación ──────────────────────────────────────────────────────
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- ── 1. Cargar la orden con lock (anti doble-emisión concurrente) ──────────
  SELECT so.id, so.account_id, so.status, so.fiscal_document_id,
         so.total, so.client_id
  INTO   v_order
  FROM   public.sales_orders so
  WHERE  so.id = p_sales_order_id
    AND  so.account_id = v_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found: orden de venta no encontrada o no pertenece a la cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- Validar estado: solo confirmadas
  IF v_order.status != 'confirmed' THEN
    RAISE EXCEPTION 'order_not_confirmed: la orden debe estar en estado confirmed para facturar (estado actual: %)',
      v_order.status
      USING ERRCODE = 'P0400';
  END IF;

  -- Idempotencia: si ya tiene comprobante → 409
  IF v_order.fiscal_document_id IS NOT NULL THEN
    RAISE EXCEPTION 'already_invoiced: la orden ya tiene un comprobante fiscal asociado (fiscal_document_id=%)',
      v_order.fiscal_document_id
      USING ERRCODE = 'P0409';
  END IF;

  -- ── 2. Leer perfil fiscal del emisor ──────────────────────────────────────
  SELECT id, iva_condition INTO v_profile
  FROM   public.fiscal_profiles
  WHERE  account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_profile_not_found: la cuenta no tiene perfil fiscal configurado'
      USING ERRCODE = 'P0404';
  END IF;

  -- OQ-1: bloquear si el emisor es RI (Factura A/B fuera de alcance MVP — D8)
  IF v_profile.iva_condition = 'responsable_inscripto' THEN
    RAISE EXCEPTION 'ri_not_supported: la facturación A/B para Responsables Inscriptos aún no está disponible. Completá la configuración cuando se habilite la función.'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── 3. Resolver tipo de comprobante (D3) ─────────────────────────────────
  -- MVP: monotributista → factura_c (único caso soportado tras el guard OQ-1)
  v_comprobante_type := 'factura_c';

  -- ── 4. Derivar receptor desde clients (C-22) (D5) ────────────────────────
  -- Sin client_id o sin tax_id → NULL/NULL (el WSFEAdapter lo convierte a 99/0)
  v_receptor_doc_tipo := NULL;
  v_receptor_doc_nro  := NULL;

  IF v_order.client_id IS NOT NULL THEN
    SELECT iva_condition, tax_id INTO v_client
    FROM   public.clients
    WHERE  id = v_order.client_id
      AND  account_id = v_account_id;

    IF FOUND AND v_client.tax_id IS NOT NULL THEN
      -- Responsable Inscripto con CUIT → DocTipo 80
      IF v_client.iva_condition = 'responsable_inscripto' THEN
        v_receptor_doc_tipo := 80;
        v_receptor_doc_nro  := v_client.tax_id;
      -- Monotributista u otro con tax_id → tratar como DNI (DocTipo 96)
      ELSIF v_client.iva_condition IN ('monotributista', 'exento') THEN
        v_receptor_doc_tipo := 96;
        v_receptor_doc_nro  := v_client.tax_id;
      END IF;
      -- consumidor_final con tax_id → seguir como NULL (99/0)
    END IF;
  END IF;

  -- ── 5. Emitir comprobante vía pipeline existente ──────────────────────────
  -- Llama rpc_emit_pending_cae con neto/IVA en NULL (Factura C no discrimina)
  v_emit_result := public.rpc_emit_pending_cae(
    p_comprobante_type  => v_comprobante_type,
    p_total             => v_order.total,
    p_client_id         => v_order.client_id,
    p_point_of_sale_id  => p_point_of_sale_id,
    p_receptor_doc_tipo => v_receptor_doc_tipo,
    p_receptor_doc_nro  => v_receptor_doc_nro,
    p_neto              => NULL,
    p_iva_amount        => NULL,
    p_iva_alicuota_id   => NULL
  );

  -- ── 6. Vincular el comprobante a la orden (mismo commit) ─────────────────
  UPDATE public.sales_orders
  SET    fiscal_document_id = (v_emit_result->>'fiscal_document_id')::uuid
  WHERE  id = p_sales_order_id;

  -- Enriquecer la respuesta con el status de la orden (OQ-3)
  v_emit_result := v_emit_result || jsonb_build_object(
    'sales_order_id', p_sales_order_id,
    'status',         'pending_cae'
  );

  RETURN v_emit_result;
END;
$function$;

-- ── Permisos ─────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.rpc_emit_sale_invoice(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_emit_sale_invoice(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_sale_invoice(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_emit_sale_invoice IS
  'facturar-venta-afip (D1/D2/D3/D5/D6): emite un comprobante AFIP para una '
  'SalesOrder confirmada sin comprobante. Atómico: valida (P0404/P0400/P0409) + '
  'resuelve tipo (monotributista→factura_c; OQ-1: bloquea RI con P0401) + '
  'deriva receptor (CUIT→80, DNI→96, sin id→NULL/NULL) + llama '
  'rpc_emit_pending_cae + UPDATE sales_orders.fiscal_document_id en un commit. '
  'Apply manual: npx supabase db push (nunca MCP apply_migration).';
