-- ═══════════════════════════════════════════════════════════════════════════
-- 20261055000001_fiscal_marca_previa_e_insert_interno.sql
--
-- fiscal-riesgos-residuales (governance CRÍTICO). Los dos riesgos residuales
-- que dejó abiertos fiscal-emision-segura (#577, 20261054000001):
--
--   R1  La marca de "algo salió para ARCA" se escribía DESPUÉS del intento.
--       Si el proceso muere (OOM, SIGKILL, redeploy de Render) o la base se
--       cae entre el FECAESolicitar y el freeze/authorize, no queda marca: a
--       los 5 min vence el lease, el próximo tick reclama el documento, pide
--       FECompUltimoAutorizado+1 (que YA avanzó) y emite una SEGUNDA factura
--       real. Reproducido en local por el red team de #577 (2 llamadas a
--       request_cae con la base caída).
--       Cierre: la marca se persiste ANTES del envío, en su propia
--       transacción (el relay corre en autocommit, ver backend/core/database.py
--       get_service_conn), y al reclamar un documento MARCADO el relay
--       RECONCILIA contra ARCA (FECompConsultar) en vez de pedir un CAE nuevo.
--
--   R2  fiscal_documents tenía policy de INSERT para `authenticated` y el
--       CHECK de status admite 'authorized' (y el trigger de FSM es BEFORE
--       UPDATE, no dispara en INSERT) ⇒ un writer podía POSTear a PostgREST un
--       comprobante 'authorized' con un CAE inventado en su propia cuenta
--       (medido: HTTP 201). Y `authenticated` tenía además TRUNCATE sobre
--       fiscal_documents y document_sequences — TRUNCATE NO pasa por RLS:
--       vaciado cross-tenant de las 40 cuentas.
--       Cierre: allow-list (cero escritura directa) + policy retirada +
--       trigger BEFORE INSERT como tercera capa.
--
-- Sin backfill: 0 documentos pending_cae, 0 congelados, las 2 filas vivas son
-- authorized con CAE real de ARCA (medido en prod el 2026-09-22).
--
-- Layout: R1 (columna, índice, 2 RPCs nuevas, claim_pending y SUS ACLs) y
-- después R2 (policy, privilegios, trigger y SU revoke). Las ACLs van al final
-- de la sección que hace el DROP+CREATE que las resetea, no al final del
-- archivo: R2 no redefine ninguna de las funciones de R1.
-- ═══════════════════════════════════════════════════════════════════════════


-- ════════════════════════════════ R1 ═══════════════════════════════════════

-- ── R1.1: columna de la marca previa ────────────────────────────────────────
ALTER TABLE public.fiscal_documents
  ADD COLUMN IF NOT EXISTS cae_submit_started_at timestamptz;

COMMENT ON COLUMN public.fiscal_documents.cae_submit_started_at IS
  'No nulo = se va a enviar (o se envió) un FECAESolicitar con el número de '
  'arca_requested_number. Se escribe ANTES del envío, en su propia transacción: '
  'la invariante es que un FECAESolicitar NUNCA sale sin una marca commiteada. '
  'Marca TRANSITORIA — no excluye de claim_pending (eso lo hace '
  'cae_submit_unconfirmed_at): un documento marcado SÍ se reclama, pero el relay '
  'lo RECONCILIA contra ARCA (FECompConsultar) en vez de pedir un CAE nuevo. '
  'La limpia sólo rpc_fiscal_document_clear_submit_mark, cuando ARCA demuestra '
  'que el comprobante no existe (602 con ultimo_autorizado < el número pedido).';

-- ── R1.2: dos documentos NO pueden tener el mismo número en vuelo ───────────
-- El relay procesa en serie dentro del tick (for doc in docs), así que hoy no
-- puede pasar; este índice hace que, si algún día deja de ser serial, el
-- segundo documento falle al MARCAR (sin enviar nada) en vez de pedirle a ARCA
-- un número que otro documento ya tiene en vuelo. El predicado excluye a los
-- CONGELADOS a propósito: un congelado conserva su marca para siempre y, si
-- nunca llegó a existir en ARCA, su número vuelve a estar legítimamente
-- disponible.
CREATE UNIQUE INDEX IF NOT EXISTS fiscal_documents_submit_mark_uq
  ON public.fiscal_documents (point_of_sale_id, comprobante_type, arca_requested_number)
  WHERE status = 'pending_cae'
    AND cae_submit_started_at IS NOT NULL
    AND cae_submit_unconfirmed_at IS NULL;

-- ── R1.3: marca previa ──────────────────────────────────────────────────────
-- LEVANTA en vez de devolver false: el caller es el hook que corre justo antes
-- del FECAESolicitar, y "no pude marcar" tiene que ABORTAR el envío, no
-- degradarse a un booleano que alguien puede ignorar. Fail-closed.
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_mark_submit_started(
  p_doc_id                uuid,
  p_arca_requested_number bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_status  text;
  v_started timestamptz;
BEGIN
  IF p_arca_requested_number IS NULL THEN
    RAISE EXCEPTION
      'MARK_SUBMIT_STARTED_SIN_NUMERO: no se puede marcar el envío del comprobante % sin el número que se le va a pedir a ARCA.',
      p_doc_id
      USING ERRCODE = 'P0437';
  END IF;

  UPDATE public.fiscal_documents
  SET cae_submit_started_at = now(),
      arca_requested_number = p_arca_requested_number
  WHERE id = p_doc_id
    AND status = 'pending_cae'
    AND cae_submit_started_at IS NULL;

  IF FOUND THEN
    RETURN true;
  END IF;

  -- No matcheó: averiguar por qué, para que el log del relay sea accionable.
  SELECT status, cae_submit_started_at
  INTO   v_status, v_started
  FROM   public.fiscal_documents
  WHERE  id = p_doc_id;

  IF v_status IS NULL THEN
    RAISE EXCEPTION
      'MARK_SUBMIT_STARTED_DOC_INEXISTENTE: el comprobante % no existe.', p_doc_id
      USING ERRCODE = 'P0437';
  ELSIF v_status <> 'pending_cae' THEN
    RAISE EXCEPTION
      'MARK_SUBMIT_STARTED_ESTADO_INVALIDO: el comprobante % ya no está pending_cae (está %). NO se envía nada a ARCA.',
      p_doc_id, v_status
      USING ERRCODE = 'P0437';
  ELSE
    RAISE EXCEPTION
      'MARK_SUBMIT_STARTED_MARCA_VIVA: el comprobante % ya tiene un envío marcado (% , número pedido ahora %). Hay que RECONCILIAR contra ARCA, no volver a enviar.',
      p_doc_id, v_started, p_arca_requested_number
      USING ERRCODE = 'P0437';
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_mark_submit_started(uuid, bigint) IS
  'fiscal-riesgos-residuales (R1). Persiste, ANTES del FECAESolicitar y en su '
  'propia transacción, el número que se le va a pedir a ARCA. La llama el hook '
  'on_submit_start del adapter; si levanta, el envío NO sale. Interna: sólo '
  'postgres/service_role (el relay corre con service conn).';

-- ── R1.4: limpieza de la marca cuando ARCA demuestra que no existe ──────────
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_clear_submit_mark(
  p_doc_id uuid,
  p_detail text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- attempts + 1 acota el ciclo marca → 602 → limpieza → marca: claim_pending
  -- exige attempts < p_max_attempts, así que la re-emisión no puede volverse un
  -- bucle. next_attempt_at = now() para que el PRÓXIMO tick lo tome.
  -- cae_submit_unconfirmed_at IS NULL: un CONGELADO no se desmarca por la vía
  -- automática ni aunque alguien llame esta RPC por error.
  UPDATE public.fiscal_documents
  SET cae_submit_started_at = NULL,
      arca_requested_number = NULL,
      attempts              = attempts + 1,
      next_attempt_at       = now(),
      last_error            = p_detail
  WHERE id = p_doc_id
    AND status = 'pending_cae'
    AND cae_submit_started_at IS NOT NULL
    AND cae_submit_unconfirmed_at IS NULL;

  RETURN FOUND;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_clear_submit_mark(uuid, text) IS
  'fiscal-riesgos-residuales (R1). Borra la marca de envío SÓLO cuando ARCA '
  'demostró que el comprobante no existe (FECompConsultar 602 + '
  'FECompUltimoAutorizado < el número pedido). Incrementa attempts: la '
  're-emisión queda acotada por el mismo tope que el resto del relay. No toca '
  'documentos CONGELADOS. Interna: sólo postgres/service_role.';

-- ── R1.5: claim_pending devuelve la marca ───────────────────────────────────
-- DROP + CREATE: cambia el TIPO DE RETORNO (RETURNS TABLE gana columnas) y
-- CREATE OR REPLACE lo rechaza con 42P13. La IDENTIDAD (uuid, integer) no
-- cambia, así que las listas de firmas de los gates siguen resolviendo.
-- Cuerpo partido del pg_get_functiondef VIVO de prod (releído 2026-09-22): el
-- WHERE es idéntico, lo único que cambia es el RETURNING.
DROP FUNCTION IF EXISTS public.rpc_fiscal_document_claim_pending(uuid, integer);

CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_claim_pending(
  p_doc_id       uuid,
  p_max_attempts integer DEFAULT 10
)
RETURNS TABLE(
  id uuid, account_id uuid, fiscal_profile_id uuid, point_of_sale_id uuid,
  comprobante_type text, punto_de_venta integer, number bigint, total numeric,
  status text, cae text, cae_due_date date, attempts integer,
  next_attempt_at timestamp with time zone, last_error text,
  receptor_doc_tipo smallint, receptor_doc_nro text,
  neto numeric, iva_amount numeric, iva_alicuota_id smallint,
  cuit text, ambiente text,
  cae_submit_unconfirmed_at timestamp with time zone,
  arca_requested_number bigint,
  -- fiscal-riesgos-residuales (R1): sin esta columna el processor no puede
  -- saber que el documento ya tiene un envío marcado y volvería a pedir un CAE
  -- nuevo — que es exactamente el riesgo que este change cierra.
  cae_submit_started_at timestamp with time zone,
  -- OQ-3: hasta este change claim_pending NO devolvía receptor_iva_condition,
  -- así que en el ÚNICO camino de emisión llegaba None al adapter y ARCA
  -- recibía siempre CondicionIVAReceptorId=5 (consumidor final), aunque la
  -- columna estuviera poblada. Medido en prod el 2026-09-22: 0 de 2 documentos
  -- la tienen poblada y clients.iva_condition sólo admite los 4 valores que el
  -- adapter ya mapea ⇒ incluirla es un no-op hoy y cierra el futuro.
  receptor_iva_condition text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  UPDATE public.fiscal_documents fd
  SET next_attempt_at = now() + interval '5 minutes'
  FROM public.fiscal_profiles fp
  WHERE fd.id = p_doc_id
    AND fp.id = fd.fiscal_profile_id
    AND fd.status = 'pending_cae'
    AND (fd.next_attempt_at IS NULL OR fd.next_attempt_at <= now())
    AND fd.attempts < p_max_attempts
    -- G4 (#577): un envío no confirmado NUNCA se vuelve a reclamar automáticamente.
    -- R1: cae_submit_started_at NO aparece acá A PROPÓSITO — un documento
    -- MARCADO sí se reclama, para RECONCILIARLO. Si lo excluyéramos, un
    -- documento cuyo proceso murió quedaría inalcanzable para siempre.
    AND fd.cae_submit_unconfirmed_at IS NULL
  RETURNING
    fd.id, fd.account_id, fd.fiscal_profile_id, fd.point_of_sale_id,
    fd.comprobante_type, fd.punto_de_venta, fd.number, fd.total,
    fd.status, fd.cae, fd.cae_due_date, fd.attempts, fd.next_attempt_at,
    fd.last_error,
    fd.receptor_doc_tipo, fd.receptor_doc_nro,
    fd.neto, fd.iva_amount, fd.iva_alicuota_id,
    fp.cuit, fp.ambiente,
    fd.cae_submit_unconfirmed_at, fd.arca_requested_number,
    fd.cae_submit_started_at, fd.receptor_iva_condition;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer) IS
  'Lease optimista de 5 minutos sobre un comprobante pending_cae. Excluye a los '
  'CONGELADOS (#577) y NO excluye a los MARCADOS (fiscal-riesgos-residuales R1): '
  'un documento con cae_submit_started_at se reclama para RECONCILIARLO contra '
  'ARCA, nunca para pedirle un CAE nuevo. Interna: sólo postgres/service_role.';

-- ── R1.6: ACLs (el DROP+CREATE de arriba las resetea a los defaults, y el
--          ALTER DEFAULT PRIVILEGES de Supabase otorga a anon/authenticated/
--          service_role). Re-aplicar SIEMPRE, en el mismo archivo. Las 3 RPCs
--          de emisión (rpc_emit_pending_cae, rpc_emit_subscription_payment_cae,
--          rpc_next_document_number) NO se tocan: las llama el usuario y
--          conservan su EXECUTE para authenticated. ────────────────────────────
REVOKE ALL ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer)
  TO postgres, service_role;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_mark_submit_started(uuid, bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_mark_submit_started(uuid, bigint)
  TO postgres, service_role;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_clear_submit_mark(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_clear_submit_mark(uuid, text)
  TO postgres, service_role;
