-- =============================================================================
-- 20261064000001_factura_fiscal_imprimible.sql
-- factura-fiscal-imprimible (governance MEDIA con tramo ALTO por exactitud
-- legal: toca rpc_fiscal_document_authorize, la RPC por la que pasa TODO
-- comprobante autorizado — relay y reconciliación).
--
-- Pedido del PO (2026-09-25): "quiero que se pueda imprimir la factura".
-- Sign-off 2026-09-26: "arrancá la implementación con lo recomendado"
-- (OQ-1..OQ-9 por su recomendación; ver design.md §"Sign-off del PO").
--
-- Esta migración:
--   1. fiscal_profiles gana los datos del emisor que exige la representación
--      impresa (RG 1415): razon_social, nombre_fantasia, domicilio_comercial,
--      iibb_numero (text) e inicio_actividades (date). Todas NULLABLE y SIN
--      default: su ausencia no bloquea la emisión, sólo la impresión.
--   2. fiscal_documents gana fecha_comprobante (date: la CbteFch que ARCA
--      confirmó — hasta hoy no se persistía en ningún lado y el QR de RG 4892
--      la exige exacta) y emisor_snapshot (jsonb: la foto del emisor al
--      autorizar, para que un cambio posterior del perfil no reescriba
--      facturas viejas).
--   3. rpc_fiscal_document_authorize gana p_fecha_comprobante date DEFAULT NULL
--      y escribe fecha + foto SÓLO en la transición real pending_cae →
--      authorized. DROP de la firma de 4 parámetros + CREATE (nunca CREATE OR
--      REPLACE agregando un parámetro: dejaría un overload vivo y el 42725 en
--      cada llamada de 4 argumentos). El DEFAULT NULL sostiene la ventana de
--      despliegue (backend viejo, 4 o 3 argumentos).
--   4. rpc_fiscal_document_set_fecha_comprobante(p_doc_id, p_fecha): RPC
--      INTERNA para el backfill de los comprobantes autorizados antes de este
--      change (OQ-9). Sólo completa una fecha NULL sobre un authorized. NO se
--      ejecuta en esta migración: el backfill consulta ARCA real
--      (FECompConsultar) y requiere el OK del PO en el momento.
--   5. Bloque DO de introspección (una sola definición de cada RPC, firma,
--      DEFINER, ACL interna).
--
-- Cuerpo de rpc_fiscal_document_authorize partido del pg_get_functiondef VIVO
-- de prod, releído por SELECT el 2026-09-26 inmediatamente antes de escribir
-- esta migración: md5 (sin \r) c8bc224d6f2767c6eb8d28031488e1f7, 4.394
-- caracteres (= el de 20261054000001; el stack local tiene el mismo md5). El
-- diff línea a línea contra ese cuerpo cambia SÓLO la línea de la firma y la
-- asignación de `number` (que gana la coma), más las 18 líneas nuevas del SET;
-- el WHERE, la lógica de colisión y la rama 7b quedan byte a byte. Se conserva
-- el COMMENT vivo (lección de #579) con una línea de este change, y se
-- re-aplican REVOKE/GRANT exactos (DROP + CREATE resetea las ACLs).
--
-- Idempotente: ADD COLUMN IF NOT EXISTS; DROP FUNCTION IF EXISTS de la firma
-- vieja (no-op en la segunda pasada) + CREATE OR REPLACE de la nueva; COMMENT
-- y ACLs re-emitidos idénticos.
-- =============================================================================

-- ── 1. Datos del emisor en fiscal_profiles ───────────────────────────────────
ALTER TABLE public.fiscal_profiles
  ADD COLUMN IF NOT EXISTS razon_social        text,
  ADD COLUMN IF NOT EXISTS nombre_fantasia     text,
  ADD COLUMN IF NOT EXISTS domicilio_comercial text,
  ADD COLUMN IF NOT EXISTS iibb_numero         text,
  ADD COLUMN IF NOT EXISTS inicio_actividades  date;

COMMENT ON COLUMN public.fiscal_profiles.razon_social IS
  'Apellido y nombre o razón social del emisor, tal como figura en ARCA. Obligatorio para imprimir la factura (RG 1415); su ausencia no bloquea la emisión.';
COMMENT ON COLUMN public.fiscal_profiles.nombre_fantasia IS
  'Nombre de fantasía (opcional). Si existe, la factura lo imprime grande y la razón social debajo (OQ-3).';
COMMENT ON COLUMN public.fiscal_profiles.domicilio_comercial IS
  'Domicilio comercial del emisor (texto libre). Obligatorio para imprimir la factura.';
COMMENT ON COLUMN public.fiscal_profiles.iibb_numero IS
  'Número de inscripción en Ingresos Brutos. Para imprimir basta éste o iibb_condition (Exento, No inscripto, Convenio Multilateral...).';
COMMENT ON COLUMN public.fiscal_profiles.inicio_actividades IS
  'Fecha de inicio de actividades del emisor. Obligatoria para imprimir la factura.';

-- ── 2. Fecha y foto del emisor en fiscal_documents ───────────────────────────
ALTER TABLE public.fiscal_documents
  ADD COLUMN IF NOT EXISTS fecha_comprobante date,
  ADD COLUMN IF NOT EXISTS emisor_snapshot   jsonb;

COMMENT ON COLUMN public.fiscal_documents.fecha_comprobante IS
  'Fecha de emisión (CbteFch) con la que ARCA autorizó el comprobante. La escribe rpc_fiscal_document_authorize en la transición a authorized; NULL = no confirmada (comprobantes anteriores a factura-fiscal-imprimible, o una respuesta de ARCA ilegible): la factura NO se imprime con una fecha adivinada. Se completa con rpc_fiscal_document_set_fecha_comprobante (backfill vía FECompConsultar, con OK del PO).';
COMMENT ON COLUMN public.fiscal_documents.emisor_snapshot IS
  'Foto de los datos del emisor (fiscal_profiles) tomada al autorizar: {cuit, razon_social, nombre_fantasia, domicilio_comercial, iva_condition, iibb_condition, iibb_numero, inicio_actividades, ambiente}. No se reescribe después; NULL en los comprobantes anteriores a factura-fiscal-imprimible (la impresión completa campo por campo desde el perfil actual).';

-- ── 3. rpc_fiscal_document_authorize: + p_fecha_comprobante ──────────────────
DROP FUNCTION IF EXISTS public.rpc_fiscal_document_authorize(uuid, text, date, bigint);

CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_authorize(p_doc_id uuid, p_cae text, p_cae_due_date date, p_number bigint DEFAULT NULL::bigint, p_fecha_comprobante date DEFAULT NULL::date)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_matched   boolean;
  v_doc       RECORD;
  v_collision uuid;
  v_reason    text;
  v_new_num   bigint;
BEGIN
  SELECT fd.id, fd.point_of_sale_id, fd.comprobante_type, fd.number
    INTO v_doc
  FROM public.fiscal_documents fd
  WHERE fd.id = p_doc_id AND fd.status = 'pending_cae'
  FOR UPDATE;

  -- Idempotencia: ya authorized/rejected (o inexistente) → no-op, mismo
  -- contrato que el cuerpo anterior (UPDATE que no matcheaba → false).
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_new_num := v_doc.number;

  IF p_number IS NOT NULL AND p_number <> v_doc.number THEN
    SELECT fd.id INTO v_collision
    FROM public.fiscal_documents fd
    WHERE fd.point_of_sale_id = v_doc.point_of_sale_id
      AND fd.comprobante_type = v_doc.comprobante_type
      AND fd.number           = p_number
      AND fd.status           = 'authorized'
      AND fd.id              <> p_doc_id
    LIMIT 1;

    IF v_collision IS NULL THEN
      -- ARCA es la fuente de verdad del número: lo adoptamos.
      v_new_num := p_number;
      v_reason  := format('ARCA_NUMBER_MISMATCH: local=%s arca=%s',
                          v_doc.number, p_number);

      -- Resincronizar el contador local SOLO hacia adelante (nunca hacia
      -- atrás: retroceder re-entregaría un número ya usado).
      UPDATE public.document_sequences ds
      SET last_number = p_number
      WHERE ds.point_of_sale_id = v_doc.point_of_sale_id
        AND ds.comprobante_type = v_doc.comprobante_type
        AND ds.last_number      < p_number;
    ELSE
      -- NUNCA sacrificar el CAE real por una colisión de número: se persiste
      -- el CAE y se conserva el número local, con rastro para revisión.
      v_reason := format(
        'ARCA_NUMBER_COLLISION: arca=%s ya usado por el documento %s; '
        'se conserva el numero local %s — requiere revision manual',
        p_number, v_collision, v_doc.number);
    END IF;
  END IF;

  BEGIN
    UPDATE public.fiscal_documents
    SET status       = 'authorized',
        cae          = p_cae,
        cae_due_date = p_cae_due_date,
        number       = v_new_num,
        -- factura-fiscal-imprimible (D5/D6): la fecha que ARCA confirmó y la
        -- foto del emisor se congelan en la MISMA transición real a authorized.
        -- Ni el camino idempotente (NOT FOUND arriba) ni la colisión
        -- irresoluble (EXCEPTION de abajo) las escriben.
        fecha_comprobante = p_fecha_comprobante,
        emisor_snapshot   = (
          SELECT jsonb_build_object(
                   'cuit',                fp.cuit,
                   'razon_social',        fp.razon_social,
                   'nombre_fantasia',     fp.nombre_fantasia,
                   'domicilio_comercial', fp.domicilio_comercial,
                   'iva_condition',       fp.iva_condition,
                   'iibb_condition',      fp.iibb_condition,
                   'iibb_numero',         fp.iibb_numero,
                   'inicio_actividades',  fp.inicio_actividades,
                   'ambiente',            fp.ambiente)
          FROM public.fiscal_profiles fp
          WHERE fp.id = fiscal_documents.fiscal_profile_id)
    WHERE id = p_doc_id AND status = 'pending_cae';

    v_matched := FOUND;
  EXCEPTION WHEN unique_violation THEN
    -- Red de la red (ronda adversarial de la implementación): el índice único
    -- parcial de arriba puede RECHAZAR este UPDATE si el número que queda
    -- (el de ARCA o, en la rama de colisión, el local) ya lo tiene otro
    -- comprobante autorizado del mismo PV y tipo. Sin este bloque, la
    -- excepción abortaría la RPC, el CAE REAL se perdería, el documento
    -- seguiría pending_cae y el próximo tick del cron le pediría OTRO CAE:
    -- una SEGUNDA factura real, que es justo el error que este change viene a
    -- cerrar. Así que el CAE se persiste igual, el estado NO se transiciona
    -- (honestamente no sabemos con qué número quedó el comprobante) y el
    -- documento se CONGELA con el mismo mecanismo de G4 para que el relay no
    -- vuelva a pedir nada. Resolución manual, con el CAE y el número ya
    -- guardados como pistas.
    UPDATE public.fiscal_documents
    SET cae                       = p_cae,
        cae_due_date              = p_cae_due_date,
        arca_requested_number     = COALESCE(p_number, arca_requested_number),
        cae_submit_unconfirmed_at = COALESCE(cae_submit_unconfirmed_at, now()),
        next_attempt_at           = NULL,
        last_error                = format(
          'ARCA_NUMBER_UNRESOLVABLE: el CAE %s se guardó pero el numero %s ya '
          'esta tomado por otro comprobante autorizado del mismo punto de venta '
          'y tipo. El documento queda CONGELADO (no se reintenta) y requiere '
          'resolucion manual.', p_cae, COALESCE(p_number, v_new_num))
    WHERE id = p_doc_id AND status = 'pending_cae';

    RETURN false;
  END;

  IF v_matched THEN
    -- El catálogo declara pending_cae→authorized con requires_reason=false:
    -- v_reason es NULL en el caso normal y lleva el desfasaje cuando lo hay.
    PERFORM public.rpc_record_fiscal_transition(p_doc_id, 'authorized', v_reason);
  END IF;

  RETURN v_matched;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date, bigint, date) IS
  'Transiciona un comprobante pending_cae → authorized con el CAE de ARCA y, si '
  'ARCA autorizó un número distinto al reservado localmente, PERSISTE el de ARCA '
  '(fuente de verdad) resincronizando document_sequences hacia adelante y dejando '
  'el desfasaje en document_status_history.reason. Ante colisión con otro '
  'comprobante ya autorizado conserva el número local y NUNCA pierde el CAE; si '
  'ni ese número es libre, guarda el CAE y CONGELA el documento en vez de dejar '
  'que la excepción del índice único haga perder el CAE (lo que provocaría una '
  'segunda factura real en el próximo tick del relay). '
  'p_number con DEFAULT NULL sostiene la ventana de despliegue (backend viejo, '
  '3 args) — no es un overload: hay una sola función. '
  'factura-fiscal-imprimible: p_fecha_comprobante (DEFAULT NULL, misma ventana '
  'de despliegue) persiste la CbteFch que ARCA confirmó, y la misma transición '
  'real congela emisor_snapshot desde fiscal_profiles; ni el camino idempotente '
  'ni la colisión irresoluble escriben ninguna de las dos.';

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date, bigint, date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date, bigint, date)
  TO postgres, service_role;

-- ── 4. rpc_fiscal_document_set_fecha_comprobante (backfill, OQ-9) ────────────
-- Interna: sin EXECUTE para anon/authenticated. Sólo completa una fecha NULL
-- de un comprobante YA autorizado; nunca pisa una fecha existente ni fecha un
-- pending_cae (que no es una factura). La fecha la aporta el procedimiento de
-- backfill desde FECompConsultar (ResultGet.CbteFch), nunca created_at.
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_set_fecha_comprobante(
  p_doc_id uuid,
  p_fecha  date
)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'rpc_fiscal_document_set_fecha_comprobante: p_fecha es obligatoria (la fecha confirmada por ARCA)'
      USING ERRCODE = 'P0400';
  END IF;

  UPDATE public.fiscal_documents
  SET    fecha_comprobante = p_fecha
  WHERE  id = p_doc_id
    AND  status = 'authorized'
    AND  fecha_comprobante IS NULL;

  RETURN FOUND;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_set_fecha_comprobante(uuid, date) IS
  'factura-fiscal-imprimible (OQ-9): completa fiscal_documents.fecha_comprobante de un comprobante authorized que no la tiene (autorizado antes de este change), con la CbteFch que devuelve FECompConsultar. Sólo escribe si la fecha es NULL y el documento está authorized; true = escribió. Interna (sin EXECUTE para roles de aplicación): la invoca el procedimiento de backfill documentado en el change, con OK del PO.';

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_set_fecha_comprobante(uuid, date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_set_fecha_comprobante(uuid, date)
  TO postgres, service_role;

-- ── 5. Introspección ─────────────────────────────────────────────────────────
DO $$
DECLARE
  v_count integer;
  v_args  text;
  v_oid   oid;
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_authorize';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'factura-fiscal-imprimible: se esperaba UNA rpc_fiscal_document_authorize y hay % (overload = 42725)', v_count;
  END IF;

  SELECT pg_get_function_identity_arguments(p.oid) INTO v_args
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_authorize';
  IF v_args <> 'p_doc_id uuid, p_cae text, p_cae_due_date date, p_number bigint, p_fecha_comprobante date' THEN
    RAISE EXCEPTION 'factura-fiscal-imprimible: firma inesperada de rpc_fiscal_document_authorize: (%)', v_args;
  END IF;

  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_fiscal_document_set_fecha_comprobante';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'factura-fiscal-imprimible: se esperaba UNA rpc_fiscal_document_set_fecha_comprobante y hay %', v_count;
  END IF;

  FOREACH v_oid IN ARRAY ARRAY[
    'public.rpc_fiscal_document_authorize(uuid, text, date, bigint, date)'::regprocedure::oid,
    'public.rpc_fiscal_document_set_fecha_comprobante(uuid, date)'::regprocedure::oid
  ] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      RAISE EXCEPTION 'factura-fiscal-imprimible: % dejó de ser SECURITY DEFINER', v_oid::regprocedure;
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'factura-fiscal-imprimible: % es ejecutable por authenticated (¿DROP+CREATE sin re-aplicar el REVOKE?)', v_oid::regprocedure;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'factura-fiscal-imprimible: % es ejecutable por anon', v_oid::regprocedure;
    END IF;
  END LOOP;

  RAISE NOTICE 'factura-fiscal-imprimible (introspección): OK — una sola rpc_fiscal_document_authorize de 5 parámetros y una rpc_fiscal_document_set_fecha_comprobante, ambas SECURITY DEFINER e internas.';
END $$;
