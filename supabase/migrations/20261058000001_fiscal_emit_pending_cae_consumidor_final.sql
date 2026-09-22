-- =============================================================================
-- Fix ad-hoc: fiscal-emit-cae-consumidor-final (governance CRÍTICO — dominio
-- fiscal). 2026-09-22.
--
-- QUÉ FALLA: rpc_emit_pending_cae (el camino de "facturar una VENTA", a
-- diferencia de rpc_emit_subscription_payment_cae que factura una
-- suscripción) levanta SQLSTATE 55000 "record v_client is not assigned yet"
-- cuando se la llama SIN p_client_id (consumidor final).
--
-- CAUSA: v_client era un `RECORD` que sólo se asignaba dentro del bloque
-- `IF p_client_id IS NOT NULL THEN SELECT legal_name, iva_condition INTO
-- v_client ... END IF`, pero el INSERT en fiscal_documents lee
-- v_client.legal_name / v_client.iva_condition INCONDICIONALMENTE. En
-- plpgsql, leer un campo de un RECORD que nunca fue asignado es un ERROR —
-- nunca NULL, a diferencia de una variable escalar declarada sin asignar.
--
-- ORIGEN: 20260806000001_v3_snapshot_pattern.sql (v3-snapshot-pattern, D4),
-- reescrita en 20260807000001_v3_document_status_history.sql (agosto 2026).
-- El propio comentario de esa migración ya decía que el caso sin cliente
-- debe dejar los snapshots del receptor en NULL ("consumidor final,
-- comportamiento previo") — el bug es que el código nunca lo hizo: declaró
-- un RECORD en vez de escalares, así que el caso "sin asignar" quedó
-- indistinguible de un bug de acceso a un campo inexistente.
--
-- POR QUÉ NUNCA EXPLOTÓ EN PROD: medido 2026-09-22, las 2 únicas facturas
-- reales en fiscal_documents salieron por rpc_emit_subscription_payment_cae
-- (las dos tienen subscription_payment_id IS NOT NULL; 0 filas sin cliente y
-- sin suscripción). rpc_emit_pending_cae — el único camino que además admite
-- client_id NULL — jamás se ejercitó en producción. El schema Pydantic del
-- backend (backend/schemas/fiscal.py, client_id: uuid.UUID | None = None) sí
-- permite emitir sin cliente, así que el primer usuario que facturara a
-- consumidor final por este camino se habría comido un 500.
--
-- ARREGLO MÍNIMO: la firma NO cambia, así que alcanza CREATE OR REPLACE. El
-- DROP FUNCTION + CREATE del proyecto se reserva para cambios de firma (para
-- no dejar un overload vivo — el 42725 de siempre) y obliga a re-otorgar las
-- ACLs; acá no hace falta el DROP, pero las ACLs se re-aplican igual.
-- Se reemplaza `v_client RECORD` por dos escalares
-- (`v_client_legal_name text`, `v_client_iva_condition text`), que en
-- plpgsql SIEMPRE nacen en NULL sin necesidad de asignación — leerlos antes
-- de asignarlos es válido y devuelve NULL, a diferencia de un RECORD. El
-- resto del cuerpo (mensajes de error, ERRCODEs, orden de las operaciones,
-- el jsonb de retorno) queda BYTE-IDÉNTICO al `pg_get_functiondef` vivo de
-- producción (volcado el 2026-09-22, md5 con CR stripped
-- 8489df0fb6c604128d41dd104c356153 — igual en prod y en el stack local antes
-- de este fix). Las ACLs se re-aplican al final de este mismo archivo,
-- idénticas a las vivas: sin EXECUTE para PUBLIC/anon, con EXECUTE para
-- authenticated (es RPC de usuario — la ejercita cualquier cuenta al
-- facturar una venta) y service_role.
--
-- Candidato que deja, fuera de alcance de este fix (ver CHANGES.md, sección
-- de este mismo fix): el SELECT de public.clients por p_client_id no filtra
-- por account_id — un client_id ajeno copiaría la razón social/condición IVA
-- de OTRA cuenta al comprobante propio (misma familia que
-- operacion-party-guard, PR #552). Se deja para una decisión aparte por ser
-- CRÍTICO: el guard correcto es rechazar con P0404, no filtrar en silencio.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_emit_pending_cae(p_comprobante_type text, p_total numeric, p_client_id uuid DEFAULT NULL::uuid, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_receptor_doc_tipo integer DEFAULT NULL::integer, p_receptor_doc_nro text DEFAULT NULL::text, p_neto numeric DEFAULT NULL::numeric, p_iva_amount numeric DEFAULT NULL::numeric, p_iva_alicuota_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                    uuid;
  v_account_id             uuid;
  v_profile                RECORD;
  v_pv                     RECORD;
  v_effective_pv_id        uuid;
  v_active_pv_count        integer;
  v_doc_number             bigint;
  v_doc_id                 uuid;
  -- fiscal-emit-cae-consumidor-final (2026-09-22): escalares en vez de
  -- `v_client RECORD`. Un escalar declarado sin asignar es NULL al leerlo;
  -- un RECORD sin asignar levanta 55000 al leer cualquiera de sus campos —
  -- y el caso "sin cliente" (consumidor final) nunca lo asigna a propósito.
  v_client_legal_name      text;
  v_client_iva_condition   text;
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

  -- v3-snapshot-pattern (D4): FiscalIdentitySnapshot del receptor — derivar
  -- razón social y condición IVA desde clients si hay client_id. NULL si
  -- no hay cliente identificado (consumidor final, comportamiento previo).
  IF p_client_id IS NOT NULL THEN
    SELECT legal_name, iva_condition INTO v_client_legal_name, v_client_iva_condition
    FROM   public.clients
    WHERE  id = p_client_id;
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

  -- Insertar comprobante en pending_cae (SIN tocar AFIP — D5). v3-snapshot-pattern:
  -- persistir receptor_legal_name/receptor_iva_condition (D4), además del
  -- receptor + IVA ya existentes (fiscal-receptor-iva-relay).
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    client_id, total, status,
    receptor_doc_tipo, receptor_doc_nro, neto, iva_amount, iva_alicuota_id,
    receptor_legal_name, receptor_iva_condition
  ) VALUES (
    v_account_id, v_profile.id, v_effective_pv_id,
    p_comprobante_type, v_pv.numero, v_doc_number,
    p_client_id, COALESCE(p_total, 0), 'pending_cae',
    p_receptor_doc_tipo, p_receptor_doc_nro, p_neto, p_iva_amount, p_iva_alicuota_id,
    v_client_legal_name, v_client_iva_condition
  )
  RETURNING id INTO v_doc_id;

  -- v3-document-status-history (RN-A2): creación del comprobante → historial
  PERFORM public.record_status_transition(
    v_account_id, 'fiscal_document', v_doc_id, NULL, 'pending_cae', v_uid, NULL);

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

-- Comentario vivo de prod (obj_description, 2026-09-22) conservado íntegro +
-- la marca de este fix.
COMMENT ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer) IS
  'C-27 (D5/D11) + fiscal-receptor-iva-relay + v3-snapshot-pattern (D4) + '
  'v3-document-status-history: emite un comprobante en pending_cae sin tocar '
  'AFIP, persiste receptor + IVA + FiscalIdentitySnapshot y registra '
  'NULL→pending_cae en document_status_history (RN-A2). '
  '+ fiscal-emit-cae-consumidor-final (2026-09-22): sin cliente los snapshots '
  'del receptor quedan NULL en vez de abortar con 55000 (v_client pasó de '
  'RECORD a dos escalares: un escalar sin asignar es NULL, un RECORD sin '
  'asignar levanta error al leer un campo).';

-- ACLs: RPC de usuario (SECURITY DEFINER) — se re-otorgan idénticas a las
-- vivas en cada CREATE OR REPLACE porque el proyecto no usa DROP+CREATE para
-- estas funciones (evita el hueco de ACL vacía del 42725).
REVOKE ALL ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer) TO authenticated, service_role;
