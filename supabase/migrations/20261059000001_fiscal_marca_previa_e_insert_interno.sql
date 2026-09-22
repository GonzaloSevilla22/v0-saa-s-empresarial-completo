-- ═══════════════════════════════════════════════════════════════════════════
-- 20261059000001_fiscal_marca_previa_e_insert_interno.sql
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
--   R3  (segundo red team sobre el fix de R1/R2, mismo día) `rejected` es
--       TERMINAL y rpc_fiscal_document_reject no tenía más guard que
--       `status = 'pending_cae'`: rechazaba igual un comprobante con la marca
--       de envío viva —cuyo número PUEDE existir en ARCA— y hasta uno
--       CONGELADO, congelado justamente porque no sabemos si ARCA lo autorizó.
--       Tres caminos independientes del relay llegaban ahí (el guard de
--       ambiente, el camino de error ordinario y una llamada manual).
--       Cierre: el guard en la RPC, que es el CHOKE POINT de los tres.
--
--   R4  `rpc_emit_pending_cae` resolvía el snapshot fiscal del receptor con
--       `SELECT ... FROM clients WHERE id = p_client_id`, SIN filtrar por
--       account_id: un client_id ajeno copiaba razón social y condición IVA de
--       otra cuenta. Candidato anotado desde #579; entra en alcance porque
--       OQ-3 hace que esa condición IVA empiece a VIAJAR A ARCA.
--       Cierre: `AND account_id = v_account_id` + P0404.
--
-- Sin backfill: 0 documentos pending_cae, 0 congelados, las 2 filas vivas son
-- authorized con CAE real de ARCA, las dos de la MISMA cuenta
-- (9b52ebe0-0660-4938-9ccf-b7746e52c1f7, CUIT 20-42266245-7, PV 3, números 1 y
-- 2, factura_c), las dos con client_id NULL y receptor_iva_condition NULL; y 0
-- documentos con un cliente de otra cuenta (medido en prod el 2026-09-22).
--
-- Layout: R1 (columna, índice, 2 RPCs nuevas, claim_pending y SUS ACLs),
-- después R2 (policy, privilegios, trigger y SU revoke), R3 y R4. Las ACLs
-- van al final de la sección que hace el DROP+CREATE que las resetea, no al
-- final del archivo: ninguna sección redefine funciones de otra.
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
  -- OQ-3 — CAMBIO DE COMPORTAMIENTO DECLARADO, no un no-op.
  --
  -- Hasta este change claim_pending NO devolvía receptor_iva_condition, así que
  -- en el ÚNICO camino de emisión llegaba None al adapter y ARCA recibía
  -- siempre CondicionIVAReceptorId=5 (consumidor final), aunque la columna
  -- estuviera poblada. Es decir: se le mandaba a ARCA una condición de receptor
  -- FALSA. Con la columna devuelta, a partir del primer comprobante emitido con
  -- cliente lo que viaja es la real:
  --
  --     NULL / consumidor_final  -> 5   (igual que antes)
  --     monotributista           -> 6   (antes iba 5)
  --     exento                   -> 4   (antes iba 5)
  --     responsable_inscripto    -> 1   (antes iba 5)
  --
  -- Se deja PUESTO —y no diferido— porque la alternativa es seguir declarando
  -- ante ARCA una condición que sabemos falsa, que en un change fiscal es peor
  -- que el riesgo que introduce. El riesgo que introduce: una factura B a un
  -- receptor RI pasa de salir con la condición mal a ser rechazada por ARCA
  -- (10246). Para la ÚNICA cuenta que hoy emite en producción no aplica: emite
  -- factura_c (monotributista emisor), donde cualquier condición de receptor es
  -- legítima. Medido en prod el 2026-09-22: 0 de 2 documentos tienen la columna
  -- poblada, y clients.iva_condition sólo admite los 4 valores que el adapter
  -- ya mapea (ninguno cae en el ValueError de condición desconocida).
  --
  -- El agravante que traía —que esa condición podía venir de un cliente de OTRA
  -- cuenta— se cierra en la sección R4 de esta misma migración.
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


-- ════════════════════════════════ R2 ═══════════════════════════════════════
-- Tres capas, ninguna delegando en la otra (lección de #577).

-- ── R2.1: la policy de INSERT se retira ─────────────────────────────────────
-- Sin el GRANT de abajo la policy ya es letra muerta, pero dejarla puesta es
-- una trampa: el día que alguien re-otorgue INSERT "para probar algo", la
-- policy lo vuelve a autorizar sola. Con la policy borrada, un re-GRANT
-- accidental choca contra RLS sin policy de INSERT ⇒ cero filas insertables.
DROP POLICY IF EXISTS fiscal_documents_writer_insert ON public.fiscal_documents;

-- ── R2.2: allow-list de privilegios (cero escritura directa) ────────────────
-- authenticated tenía arwdDxtm sobre las dos tablas: INSERT (comprobante
-- 'authorized' con CAE inventado — medido HTTP 201) y TRUNCATE, que NO pasa
-- por RLS: vaciado cross-tenant de las 40 cuentas. Se eligió el REVOKE y no
-- "endurecer el WITH CHECK a status='pending_cae'" porque una allow-list no
-- tiene que anticipar qué columna es peligrosa: hoy es status+cae, mañana es
-- la que agregue el próximo change.
--
-- Verificado antes de escribir esto (prod, 2026-09-22): ninguna de las dos
-- tablas tiene grants POR COLUMNA (attacl = 0 en ambas), así que el gotcha de
-- "el REVOKE de tabla borra los grants por columna" no aplica acá.
REVOKE ALL ON TABLE public.fiscal_documents   FROM anon, authenticated;
REVOKE ALL ON TABLE public.document_sequences FROM anon, authenticated;

-- SELECT de vuelta SÓLO para authenticated: lo necesitan la pantalla y la
-- suscripción Realtime de FiscalDocumentBadge (Realtime evalúa la policy de
-- SELECT; sin el GRANT el badge dejaría de actualizarse solo). `anon` queda
-- sin nada: tenía el privilegio pero ninguna policy, así que nunca vio una
-- fila — el cambio observable es 403 en vez de [] para un request anónimo, y
-- no hay ninguna pantalla pública que consulte estas tablas.
GRANT SELECT ON TABLE public.fiscal_documents   TO authenticated;
GRANT SELECT ON TABLE public.document_sequences TO authenticated;

-- ── R2.3: tercera capa — un INSERT directo sólo puede nacer pending_cae ─────
-- Sigue puesta aunque alguien re-otorgue el privilegio Y recree la policy. Es
-- exactamente el invariante que ya cumplen rpc_emit_pending_cae y
-- rpc_emit_subscription_payment_cae (las dos insertan 'pending_cae' sin CAE),
-- así que no estorba a ningún camino legítimo.
--
-- SIN exención por rol: un `IF current_user = 'postgres' THEN RETURN NEW` la
-- volvería inverificable desde el gate (que corre como postgres) y la apagaría
-- justamente para el camino que #577 demostró que puede fallar. El precio es
-- migrar 6 fixtures de test con session_replication_role = replica — el
-- precedente ya establecido por sucursal-guard-vaciado-auditoria.
CREATE OR REPLACE FUNCTION public.fn_guard_fiscal_document_insert_interno()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM 'pending_cae'
     OR NEW.cae IS NOT NULL
     OR NEW.cae_due_date IS NOT NULL
     OR NEW.cae_submit_unconfirmed_at IS NOT NULL
     OR NEW.cae_submit_started_at IS NOT NULL
     OR NEW.arca_requested_number IS NOT NULL
  THEN
    RAISE EXCEPTION
      'FISCAL_DOCUMENT_INSERT_SOLO_PENDING: un comprobante fiscal sólo puede NACER en pending_cae y sin CAE (status=%, cae=%). El CAE lo escribe el relay contra ARCA, nunca el INSERT.',
      NEW.status, COALESCE(NEW.cae, '<NULL>')
      USING ERRCODE = 'P0436';
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.fn_guard_fiscal_document_insert_interno() IS
  'fiscal-riesgos-residuales (R2, tercera capa). Un comprobante sólo nace '
  'pending_cae y sin CAE. Las dos primeras capas son el REVOKE de escritura y '
  'la ausencia de policy de INSERT; ésta es la única que sobrevive a que '
  'alguien re-otorgue el privilegio y recree la policy. Una migración futura '
  'que necesite sembrar filas authorized (backfill histórico) debe desactivarla '
  'explícitamente — que la omisión sea una decisión, no un descuido.';

-- Los helpers de trigger nacen con EXECUTE para PUBLIC: REVOKE explícito
-- (chequeo (1) del gate de ACLs, mismo patrón que fn_guard_pos_cuit_cross_account).
REVOKE ALL ON FUNCTION public.fn_guard_fiscal_document_insert_interno()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_fiscal_document_insert_interno ON public.fiscal_documents;
CREATE TRIGGER trg_guard_fiscal_document_insert_interno
  BEFORE INSERT ON public.fiscal_documents
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_guard_fiscal_document_insert_interno();


-- ════════════════════════════════ R3 ═══════════════════════════════════════
-- `rejected` PROHIBIDO sobre un envío que puede haber llegado a ARCA.
--
-- `rejected` es un estado TERMINAL: nadie lo revisa después. El relay ya tenía
-- `_retry_or_freeze_reconcile` —que NUNCA rechaza— precisamente porque un
-- documento marcado "podría estar tapando un CAE real", pero esa protección
-- sólo cubría la rama de reconciliación. El segundo red team encontró TRES
-- caminos que la esquivaban:
--
--   (a) el guard de ambiente del processor se evalúa antes de la rama de
--       reconciliación y no retornaba;
--   (b) el camino de error ordinario, cuando el hook marcó en ESE mismo tick
--       (el snapshot de claim_pending todavía decía que no había marca);
--   (c) una llamada directa a esta RPC, que no tenía guard alguno — ni siquiera
--       para un documento CONGELADO.
--
-- (a) y (b) se cierran en el processor (Python). Éste es el CHOKE POINT que los
-- cubre a los tres de una vez, y el único que sobrevive a un camino futuro que
-- nadie anticipó — mismo patrón que `cuenta-corriente-party-guard` usó con
-- `c30_get_or_create_*`.
--
-- LEVANTA en vez de devolver false a propósito: un rechazo silenciosamente
-- ignorado dejaría el documento pending_cae para siempre, sin señal. Con el
-- guard de la capa 1 puesto, este RAISE no debería dispararse nunca; si se
-- dispara, es un camino nuevo que hay que mirar.
--
-- La resolución MANUAL de un congelado no pasa por acá (la RPC no tiene EXECUTE
-- para authenticated desde #577): un DBA que decida que ARCA efectivamente lo
-- rechazó hace el UPDATE directo, que es deliberado y auditable.
--
-- Cuerpo partido del pg_get_functiondef VIVO de prod (releído 2026-09-22); lo
-- único que se agrega es el bloque del guard. CREATE OR REPLACE con la MISMA
-- firma (uuid, text) — no hay cambio de tipo de retorno ni parámetro nuevo, así
-- que no aplica ni el 42P13 ni el 42725 del overload. Las ACLs se re-aplican
-- igual, por si esta migración corre sobre una base donde la función nace acá.
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_reject(
  p_doc_id     uuid,
  p_last_error text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_matched      boolean;
  v_started      timestamptz;
  v_unconfirmed  timestamptz;
  v_req          bigint;
BEGIN
  SELECT cae_submit_started_at, cae_submit_unconfirmed_at, arca_requested_number
  INTO   v_started, v_unconfirmed, v_req
  FROM   public.fiscal_documents
  WHERE  id = p_doc_id;

  IF v_started IS NOT NULL OR v_unconfirmed IS NOT NULL THEN
    RAISE EXCEPTION
      'FISCAL_DOCUMENT_REJECT_CON_ENVIO_MARCADO: el comprobante % tiene un envío a ARCA marcado (started=%, unconfirmed=%, número pedido %) y "rejected" es TERMINAL: taparía un CAE que puede existir en ARCA. Reconciliar (FECompConsultar) o congelar; nunca rechazar.',
      p_doc_id, v_started, v_unconfirmed, COALESCE(v_req::text, '<NULL>')
      USING ERRCODE = 'P0438';
  END IF;

  UPDATE public.fiscal_documents
  SET status     = 'rejected',
      last_error = p_last_error
  WHERE id = p_doc_id AND status = 'pending_cae';

  v_matched := FOUND;

  IF v_matched THEN
    PERFORM public.rpc_record_fiscal_transition(p_doc_id, 'rejected', p_last_error);
  END IF;

  RETURN v_matched;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_reject(uuid, text) IS
  'Transición terminal a rejected. fiscal-riesgos-residuales (R3): RECHAZA con '
  'P0438 si el comprobante tiene cae_submit_started_at o '
  'cae_submit_unconfirmed_at — un envío que puede haber llegado a ARCA no se '
  'puede dejar en un estado terminal. Choke point de los tres caminos del relay '
  'que llegaban acá. Interna: sólo postgres/service_role.';

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_reject(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_reject(uuid, text)
  TO postgres, service_role;


-- ════════════════════════════════ R4 ═══════════════════════════════════════
-- El snapshot del receptor deja de poder copiarse de un cliente AJENO.
--
-- `rpc_emit_pending_cae` resolvía la identidad fiscal del receptor con
--
--     SELECT legal_name, iva_condition INTO ...
--     FROM public.clients WHERE id = p_client_id;
--
-- sin filtrar por `account_id`. Un `client_id` de otra cuenta copiaba su razón
-- social y su condición IVA al comprobante propio, y dejaba ese `client_id`
-- ajeno persistido en `fiscal_documents.client_id`. Misma familia que
-- `operacion-party-guard` (#552) y que `cuenta-corriente-party-guard`.
--
-- Estaba anotado como candidato desde #579 y se cierra ACÁ, en este change, por
-- una razón concreta: hasta ahora `claim_pending` no devolvía
-- `receptor_iva_condition`, así que el adapter recibía siempre `None` y le
-- mandaba a ARCA el default `consumidor_final`. Con OQ-3 esa columna empieza a
-- viajar — y con ella viajaría a ARCA la condición IVA de un tercero. Deja de
-- ser una fuga de datos para ser un dato falso en un comprobante fiscal.
--
-- Daño histórico: CERO. Medido en prod hoy — 2 fiscal_documents, los 2 con
-- `client_id IS NULL` (consumidor final) y `receptor_iva_condition IS NULL`,
-- y 0 documentos cuyo cliente pertenezca a otra cuenta. Sin backfill.
--
-- P0404 y no un snapshot NULL en silencio: un `client_id` que no pertenece a la
-- cuenta es un bug del caller o un ataque, y el mismo P0404 ya se usa dos
-- líneas más abajo para el punto de venta que no es de la cuenta. El
-- `p_client_id NULL` (consumidor final, el fix de #579) NO entra al guard.
--
-- Cuerpo partido del `pg_get_functiondef` VIVO de prod (releído hoy, DESPUÉS
-- de #579 — incluye sus escalares `v_client_legal_name`/`v_client_iva_condition`
-- que reemplazaron al `v_client RECORD` del 55000). Lo único que cambia es el
-- `AND account_id = v_account_id` y el `IF NOT FOUND`. CREATE OR REPLACE con
-- la MISMA firma de 9 parámetros: no aplica el 42725.
CREATE OR REPLACE FUNCTION public.rpc_emit_pending_cae(
  p_comprobante_type  text,
  p_total             numeric,
  p_client_id         uuid    DEFAULT NULL::uuid,
  p_point_of_sale_id  uuid    DEFAULT NULL::uuid,
  p_receptor_doc_tipo integer DEFAULT NULL::integer,
  p_receptor_doc_nro  text    DEFAULT NULL::text,
  p_neto              numeric DEFAULT NULL::numeric,
  p_iva_amount        numeric DEFAULT NULL::numeric,
  p_iva_alicuota_id   integer DEFAULT NULL::integer
)
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
  -- fiscal-emit-cae-consumidor-final (#579): escalares en vez de
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
  --
  -- fiscal-riesgos-residuales (R4): `AND account_id = v_account_id`. Sin ese
  -- filtro, un client_id ajeno copiaba la identidad fiscal de otra cuenta al
  -- comprobante propio — y desde OQ-3 esa condición IVA viaja a ARCA.
  IF p_client_id IS NOT NULL THEN
    SELECT legal_name, iva_condition INTO v_client_legal_name, v_client_iva_condition
    FROM   public.clients
    WHERE  id = p_client_id
      AND  account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'client_not_found: el cliente no existe o no pertenece a la cuenta'
        USING ERRCODE = 'P0404';
    END IF;
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

COMMENT ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer) IS
  'Emite un comprobante fiscal en pending_cae para una VENTA. RPC de USUARIO: '
  'conserva EXECUTE para authenticated. fiscal-riesgos-residuales (R4): el '
  'client_id tiene que pertenecer a la cuenta (P0404) — sin ese filtro copiaba '
  'la identidad fiscal de un cliente ajeno, que desde OQ-3 viaja a ARCA como '
  'CondicionIVAReceptorId.';

-- Es RPC de USUARIO: `authenticated` CONSERVA su EXECUTE (a diferencia de las
-- del relay). `anon` y PUBLIC, nunca. Re-aplicado acá porque el CREATE OR
-- REPLACE de arriba corre sobre una base donde el ALTER DEFAULT PRIVILEGES de
-- Supabase puede haber otorgado a anon.
REVOKE ALL ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)
  TO authenticated, service_role, postgres;
