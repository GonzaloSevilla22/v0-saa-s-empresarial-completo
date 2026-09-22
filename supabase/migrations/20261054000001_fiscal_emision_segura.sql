-- ═══════════════════════════════════════════════════════════════════════════
-- 20261054000001_fiscal_emision_segura.sql
--
-- fiscal-emision-segura (governance CRÍTICO). Cuatro grupos:
--   G3/G7  El número que ARCA autoriza se PERSISTE (hoy se descarta).
--   G4     Un envío a ARCA no confirmado CONGELA el documento en vez de
--          reintentarse a ciegas con un número nuevo (evita doble factura).
--   G6     Las 4 RPCs del relay dejan de ser ejecutables por `authenticated`:
--          `rpc_fiscal_document_authorize` es SECURITY DEFINER, no valida
--          tenencia, y con EXECUTE para authenticated cualquier usuario
--          logueado podía escribir un CAE arbitrario en el comprobante de
--          cualquier cuenta vía PostgREST. Su único puente authenticated era
--          POST /fiscal/documents/process-pending, retirado en este mismo PR.
--   G9     Un mismo CUIT no puede tener el mismo punto de venta ACTIVO en dos
--          cuentas: es exactamente la clave con la que ARCA numera
--          (CUIT, PtoVta, CbteTipo). Hoy prod tiene ese caso (dos perfiles con
--          20-42266245-7 y PV 3 activo en los dos, uno por un CUIT cargado por
--          error). El guard NO toca las filas existentes — sólo impide que el
--          caso se cree o se agrande.
--
-- Todos los cuerpos de función parten del `pg_get_functiondef` VIVO de
-- producción (releído el 2026-09-22). Idempotente y segura en base vacía.
-- Sin backfill: los 2 documentos vivos están authorized con CAE real y números
-- coherentes con ARCA (verificado: 0 duplicados de (PV, tipo, número)).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── G4: marcas de envío no confirmado ────────────────────────────────────────
ALTER TABLE public.fiscal_documents
  ADD COLUMN IF NOT EXISTS cae_submit_unconfirmed_at timestamptz,
  ADD COLUMN IF NOT EXISTS arca_requested_number     bigint;

COMMENT ON COLUMN public.fiscal_documents.cae_submit_unconfirmed_at IS
  'No nulo = se envió un FECAESolicitar a ARCA cuyo resultado NUNCA se confirmó. '
  'El documento queda CONGELADO: rpc_fiscal_document_claim_pending no lo reclama. '
  'Puede tener un CAE real emitido en ARCA sin registro local — resolver a mano '
  'consultando arca_requested_number en ARCA antes de reintentar.';
COMMENT ON COLUMN public.fiscal_documents.arca_requested_number IS
  'Número (CbteDesde) que se le pidió a ARCA en el envío no confirmado. Es el dato '
  'con el que un humano puede consultar en ARCA si la factura existe.';

-- ── G3: red local contra dos comprobantes autorizados con el mismo número ────
-- ALCANCE REAL: la clave de ARCA es (CUIT, PtoVta, CbteTipo). Este índice usa
-- point_of_sale_id, así que NO detecta la colisión entre dos fiscal_profiles
-- del MISMO CUIT con el mismo PV — ése es el caso que cierra G9 más abajo, por
-- otra vía (impedir que exista). Riesgo residual declarado para las filas que
-- YA existen.
CREATE UNIQUE INDEX IF NOT EXISTS fiscal_documents_authorized_number_uq
  ON public.fiscal_documents (point_of_sale_id, comprobante_type, number)
  WHERE status = 'authorized';

-- ── G3: rpc_fiscal_document_authorize — cambia la firma (+ p_number) ─────────
-- DROP + CREATE (nunca CREATE OR REPLACE agregando un parámetro con DEFAULT:
-- dejaría DOS funciones vivas y el 42725 en cada llamada de 3 argumentos).
DROP FUNCTION IF EXISTS public.rpc_fiscal_document_authorize(uuid, text, date);

CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_authorize(
  p_doc_id       uuid,
  p_cae          text,
  p_cae_due_date date,
  p_number       bigint DEFAULT NULL
)
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
        number       = v_new_num
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

COMMENT ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date, bigint) IS
  'Transiciona un comprobante pending_cae → authorized con el CAE de ARCA y, si '
  'ARCA autorizó un número distinto al reservado localmente, PERSISTE el de ARCA '
  '(fuente de verdad) resincronizando document_sequences hacia adelante y dejando '
  'el desfasaje en document_status_history.reason. Ante colisión con otro '
  'comprobante ya autorizado conserva el número local y NUNCA pierde el CAE; si '
  'ni ese número es libre, guarda el CAE y CONGELA el documento en vez de dejar '
  'que la excepción del índice único haga perder el CAE (lo que provocaría una '
  'segunda factura real en el próximo tick del relay). '
  'p_number con DEFAULT NULL sostiene la ventana de despliegue (backend viejo, '
  '3 args) — no es un overload: hay una sola función.';

-- ── G4: congelar un envío no confirmado ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_freeze_unconfirmed(
  p_doc_id                uuid,
  p_arca_requested_number bigint,
  p_detail                text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_matched boolean;
BEGIN
  -- El status NO cambia: sigue pending_cae porque honestamente NO sabemos si
  -- ARCA autorizó. Lo que cambia es que deja de ser reclamable (el predicado
  -- nuevo de rpc_fiscal_document_claim_pending). No se toca `attempts`: el
  -- freno es estructural, no un efecto lateral del contador.
  UPDATE public.fiscal_documents
  SET cae_submit_unconfirmed_at = COALESCE(cae_submit_unconfirmed_at, now()),
      arca_requested_number     = COALESCE(p_arca_requested_number, arca_requested_number),
      last_error                = p_detail,
      next_attempt_at           = NULL
  WHERE id = p_doc_id
    AND status = 'pending_cae'
    AND cae_submit_unconfirmed_at IS NULL;

  v_matched := FOUND;
  RETURN v_matched;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_freeze_unconfirmed(uuid, bigint, text) IS
  'Congela un comprobante cuyo FECAESolicitar se envió y NUNCA se confirmó. Evita '
  'el peor error del dominio: reintentar pidiendo FECompUltimoAutorizado+1 y emitir '
  'una SEGUNDA factura real para el mismo documento. Idempotente (no repisa una '
  'marca previa). Resolución manual: consultar arca_requested_number en ARCA.';

-- ── G4: claim_pending deja de reclamar documentos congelados ─────────────────
-- Cuerpo vivo + el predicado nuevo. El RETURNING suma las dos columnas nuevas
-- para que el relay pueda verlas sin una segunda query.
-- DROP + CREATE y no CREATE OR REPLACE: los parámetros de RETURNS TABLE son
-- parte del TIPO DE RETORNO, y agregarle dos columnas da 42P13 ("cannot change
-- return type of existing function"). Los argumentos de identidad no cambian
-- (uuid, integer), así que no hay riesgo de overload.
DROP FUNCTION IF EXISTS public.rpc_fiscal_document_claim_pending(uuid, integer);

CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_claim_pending(
  p_doc_id uuid, p_max_attempts integer DEFAULT 10)
RETURNS TABLE(
  id uuid, account_id uuid, fiscal_profile_id uuid, point_of_sale_id uuid,
  comprobante_type text, punto_de_venta integer, number bigint, total numeric,
  status text, cae text, cae_due_date date, attempts integer,
  next_attempt_at timestamp with time zone, last_error text,
  receptor_doc_tipo smallint, receptor_doc_nro text, neto numeric,
  iva_amount numeric, iva_alicuota_id smallint, cuit text, ambiente text,
  cae_submit_unconfirmed_at timestamp with time zone, arca_requested_number bigint)
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
    -- G4: un envío no confirmado NUNCA se vuelve a reclamar automáticamente.
    AND fd.cae_submit_unconfirmed_at IS NULL
  RETURNING
    fd.id, fd.account_id, fd.fiscal_profile_id, fd.point_of_sale_id,
    fd.comprobante_type, fd.punto_de_venta, fd.number, fd.total,
    fd.status, fd.cae, fd.cae_due_date, fd.attempts, fd.next_attempt_at,
    fd.last_error,
    fd.receptor_doc_tipo, fd.receptor_doc_nro,
    fd.neto, fd.iva_amount, fd.iva_alicuota_id,
    fp.cuit, fp.ambiente,
    fd.cae_submit_unconfirmed_at, fd.arca_requested_number;
END;
$function$;

COMMENT ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer) IS
  'Lease optimista de 5 minutos sobre un comprobante pending_cae: 0 filas = otro '
  'caller lo tiene, o el documento está CONGELADO por un envío no confirmado (G4), '
  'y en ninguno de los dos casos hay que pedirle un CAE.';

-- ── G9: un CUIT no puede tener el mismo PV activo en dos cuentas ─────────────
-- ARCA numera por (CUIT, PtoVta, CbteTipo); `document_sequences` numera por
-- point_of_sale_id, que es distinto en cada perfil. Dos cuentas con el mismo
-- CUIT y el mismo PV activo compiten por LA MISMA secuencia de ARCA: la segunda
-- en emitir reserva un número local que ARCA ya usó. G3 lo registra como
-- ARCA_NUMBER_MISMATCH, pero el problema de fondo es de datos y se cierra acá.
--
-- SECURITY DEFINER es OBLIGATORIO y no cosmético: la comprobación tiene que
-- VER las filas de la OTRA cuenta, y con la RLS efectiva para el backend
-- (v31-tenancy-pool-rls, rol `authenticated` por transacción) un trigger
-- SECURITY INVOKER no vería nada y el guard nunca dispararía. Como toda función
-- nace con EXECUTE para PUBLIC, lleva su REVOKE explícito (chequeo (1) del gate
-- de ACLs).
CREATE OR REPLACE FUNCTION public.fn_guard_pos_cuit_cross_account()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cuit       text;
  v_account_id uuid;
  v_other      uuid;
BEGIN
  -- Un PV inactivo no compite por la numeración de ARCA.
  IF NOT NEW.is_active THEN
    RETURN NEW;
  END IF;

  -- No toca filas existentes: en UPDATE sólo se verifica cuando el PV RECIÉN
  -- se vuelve conflictivo (se reactiva, cambia de número o cambia de perfil).
  -- Un UPDATE cualquiera sobre el duplicado que ya existe en prod pasa igual —
  -- incluida su DESACTIVACIÓN, que es parte de cómo se arregla.
  IF TG_OP = 'UPDATE'
     AND OLD.is_active
     AND OLD.numero = NEW.numero
     AND OLD.fiscal_profile_id = NEW.fiscal_profile_id THEN
    RETURN NEW;
  END IF;

  SELECT regexp_replace(fp.cuit, '[^0-9]', '', 'g'), fp.account_id
    INTO v_cuit, v_account_id
  FROM public.fiscal_profiles fp
  WHERE fp.id = NEW.fiscal_profile_id;

  IF v_cuit IS NULL OR v_cuit = '' THEN
    RETURN NEW;
  END IF;

  SELECT fp2.account_id INTO v_other
  FROM public.points_of_sale pos
  JOIN public.fiscal_profiles fp2 ON fp2.id = pos.fiscal_profile_id
  WHERE pos.is_active
    AND pos.numero = NEW.numero
    AND pos.id <> NEW.id
    AND fp2.account_id <> v_account_id
    AND regexp_replace(fp2.cuit, '[^0-9]', '', 'g') = v_cuit
  LIMIT 1;

  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION
      'cuit_punto_venta_en_otra_cuenta: Ese CUIT ya tiene el punto de venta % '
      'activo en otra cuenta. Ante ARCA la numeración es por CUIT y punto de '
      'venta: dos cuentas no pueden compartirlo. Revisá el CUIT cargado en '
      'Datos fiscales, o usá otro número de punto de venta.', NEW.numero
      USING ERRCODE = 'P0435';
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.fn_guard_pos_cuit_cross_account() IS
  'G9 de fiscal-emision-segura: rechaza (P0435) dejar ACTIVO un punto de venta '
  'cuyo número ya está activo en OTRA cuenta con el mismo CUIT normalizado. No '
  'toca filas existentes: en UPDATE sólo verifica cuando el PV recién se vuelve '
  'conflictivo, así que desactivar o corregir el duplicado vivo sigue siendo '
  'posible.';

REVOKE ALL ON FUNCTION public.fn_guard_pos_cuit_cross_account()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_pos_cuit_cross_account ON public.points_of_sale;
CREATE TRIGGER trg_guard_pos_cuit_cross_account
  BEFORE INSERT OR UPDATE ON public.points_of_sale
  FOR EACH ROW EXECUTE FUNCTION public.fn_guard_pos_cuit_cross_account();

-- El espejo por el otro lado: cambiarle el CUIT a un perfil puede crear el
-- mismo conflicto sin tocar ningún punto de venta.
CREATE OR REPLACE FUNCTION public.fn_guard_fiscal_profile_cuit_cross_account()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_new_cuit text;
  v_numero   integer;
BEGIN
  v_new_cuit := regexp_replace(COALESCE(NEW.cuit, ''), '[^0-9]', '', 'g');

  IF v_new_cuit = '' THEN
    RETURN NEW;
  END IF;

  -- Sólo cuando el CUIT efectivamente CAMBIA: un UPDATE que lo reescribe igual
  -- (el upsert de POST /fiscal/profile lo hace siempre) no puede crear nada.
  IF TG_OP = 'UPDATE'
     AND regexp_replace(COALESCE(OLD.cuit, ''), '[^0-9]', '', 'g') = v_new_cuit THEN
    RETURN NEW;
  END IF;

  SELECT mine.numero INTO v_numero
  FROM public.points_of_sale mine
  JOIN public.points_of_sale other
    ON other.numero = mine.numero
   AND other.is_active
   AND other.id <> mine.id
  JOIN public.fiscal_profiles fp2 ON fp2.id = other.fiscal_profile_id
  WHERE mine.fiscal_profile_id = NEW.id
    AND mine.is_active
    AND fp2.account_id <> NEW.account_id
    AND regexp_replace(fp2.cuit, '[^0-9]', '', 'g') = v_new_cuit
  LIMIT 1;

  IF v_numero IS NOT NULL THEN
    RAISE EXCEPTION
      'cuit_punto_venta_en_otra_cuenta: Ese CUIT ya tiene el punto de venta % '
      'activo en otra cuenta. Ante ARCA la numeración es por CUIT y punto de '
      'venta: dos cuentas no pueden compartirlo. Desactivá ese punto de venta '
      'o usá otro número antes de cambiar el CUIT.', v_numero
      USING ERRCODE = 'P0435';
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.fn_guard_fiscal_profile_cuit_cross_account() IS
  'G9 de fiscal-emision-segura, espejo del guard de points_of_sale: rechaza '
  '(P0435) cambiarle el CUIT a un perfil si con el CUIT nuevo alguno de sus '
  'puntos de venta activos colisionaría con otra cuenta. Sólo actúa cuando el '
  'CUIT cambia de verdad.';

REVOKE ALL ON FUNCTION public.fn_guard_fiscal_profile_cuit_cross_account()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_fiscal_profile_cuit_cross_account ON public.fiscal_profiles;
CREATE TRIGGER trg_guard_fiscal_profile_cuit_cross_account
  BEFORE INSERT OR UPDATE OF cuit ON public.fiscal_profiles
  FOR EACH ROW EXECUTE FUNCTION public.fn_guard_fiscal_profile_cuit_cross_account();

-- ── ACLs ─────────────────────────────────────────────────────────────────────
-- Vivas antes de esta migración en las 4 RPCs del relay:
--   authenticated:EXECUTE, postgres:EXECUTE, service_role:EXECUTE  (anon: no)
-- Después: SIN authenticated. El único caller authenticated era
-- POST /fiscal/documents/process-pending, retirado en este mismo PR; el cron
-- las llama con service conn (rol postgres).
-- Candado permanente: las 5 firmas entran en v_internal_only_fns del
-- chequeo (3) de supabase/tests/test_function_acl_gate.sql.
REVOKE ALL ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date, bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date, bigint)
  TO postgres, service_role;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_freeze_unconfirmed(uuid, bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_freeze_unconfirmed(uuid, bigint, text)
  TO postgres, service_role;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer)
  TO postgres, service_role;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_retry(uuid, integer, timestamptz, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_retry(uuid, integer, timestamptz, text)
  TO postgres, service_role;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_reject(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_reject(uuid, text)
  TO postgres, service_role;
