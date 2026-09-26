-- =============================================================================
-- 20261063000001_punto_venta_predeterminado.sql
-- punto-venta-seleccion (governance MEDIA, dominio fiscal).
--
-- Pedido del PO (2026-09-25): "quiero que en la venta se pueda elegir el punto
-- de venta o al facturar, por si tienen más de 1". Sign-off 2026-09-26: se
-- elige AL FACTURAR (OQ-1), con un punto de venta PREDETERMINADO opcional por
-- cuenta (D2).
--
-- Medido en prod (sólo lectura, 2026-09-25): 2 de 2 cuentas con puntos de
-- venta tienen DOS activos (3 y 9999). Emitir sin PV explícito con dos activos
-- da P0422 ambiguous_point_of_sale — es lo que manda /ventas/ordenes (donde se
-- facturan las ventas del POS) con más de un PV: el 100% de las cuentas que
-- facturan no podía facturar una venta del POS.
--
-- Esta migración:
--   1. points_of_sale.is_default boolean NOT NULL DEFAULT false (D2): la marca
--      vive en la fila que describe; la desactivación la limpia en la misma
--      sentencia (repository).
--   2. CHECK points_of_sale_default_is_active (NOT is_default OR is_active):
--      defensa en profundidad — un camino futuro que desactive un PV sin
--      limpiar la marca FALLA en vez de dejar un predeterminado inactivo.
--   3. Índice ÚNICO PARCIAL points_of_sale_one_default_per_account
--      ON (account_id) WHERE is_default: como mucho uno por cuenta. Es un
--      índice (no constraint): no admite DEFERRABLE, por eso el repository
--      quita la marca vieja y pone la nueva en DOS sentencias (D9).
--   4. Disparador trg_points_of_sale_guard_default (hallazgo de red-team): la
--      RLS de la tabla habilita UPDATE a los 7 roles is_writer=true
--      (is_account_writer, desde v3-rbac-multirole), no sólo owner/admin — el
--      guard de CAN_CONFIGURE del backend (D-service) no tiene equivalente en
--      la base, así que cualquier vendedor/cajero podía escribir is_default
--      directo por PostgREST. El disparador (BEFORE INSERT OR UPDATE) rechaza
--      con P0401 cualquier cambio de is_default hecho por un actor sin rol
--      owner/admin en la cuenta; el resto de la fila (numero, is_active,
--      fiscal_profile_id) sigue sin protección propia — deuda preexistente,
--      no de este change, anotada en CHANGES.md. Postgres saltea los
--      disparadores normales con session_replication_role='replica' (el
--      patrón ya usado por el cleanup de los gates SQL), así que no hace
--      falta ninguna excepción explícita para eso.
--   5. rpc_emit_pending_cae (D3): en la rama "sin PV explícito y más de un
--      activo", usa el predeterminado activo de la cuenta antes de levantar
--      P0422. explícito inválido → P0404 aunque haya predeterminado; cero
--      activos → P0404; uno → ese; varios sin predeterminado → P0422 (sin
--      cambio). Los tres SELECT de resolución de PV toman FOR SHARE (hallazgo
--      de red-team, TOCTOU preexistente en las tres ramas): conflictúa con el
--      FOR NO KEY UPDATE implícito de una desactivación/cambio de
--      predeterminado concurrente, así que la emisión espera y re-evalúa en
--      vez de facturar sobre un PV que está a punto de quedar inactivo.
--
-- Cuerpo partido del pg_get_functiondef VIVO de prod, releído el 2026-09-26
-- inmediatamente antes de escribir esta migración: md5 (sin \r)
-- 8c10f8cac606d99d0e1b638d82fe3312 = el de 20261059000001 L516 (sin desvío).
-- CREATE OR REPLACE con la MISMA firma de 9 parámetros: no aplica el 42725.
-- Se conserva el COMMENT vivo (R4, lección de #579) extendido con una línea
-- de este change, y se re-aplican REVOKE/GRANT.
--
-- rpc_emit_subscription_payment_cae (facturación de suscripciones de la
-- plataforma) NO se toca (D5/OQ-3): el bloque DO del final asserta que su md5
-- sigue siendo el vivo de prod.
--
-- Sin backfill (OQ-5): ninguna cuenta queda con predeterminado hasta que el
-- dueño lo marque en Configuración → Datos fiscales.
--
-- Idempotente (el auto-apply de Supabase GitHub exige re-ejecutables):
-- ADD COLUMN IF NOT EXISTS, CHECK guardado contra pg_constraint, índice IF NOT
-- EXISTS, CREATE OR REPLACE.
--
-- Gate: supabase/tests/test_punto_venta_predeterminado.sql (EJECUTA la RPC).
-- =============================================================================

-- ── 1. Columna ───────────────────────────────────────────────────────────────
ALTER TABLE public.points_of_sale
  ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.points_of_sale.is_default IS
  'punto-venta-seleccion (D2): punto de venta predeterminado de la cuenta. '
  'Como mucho uno por cuenta (índice único parcial '
  'points_of_sale_one_default_per_account) y sólo activo (CHECK '
  'points_of_sale_default_is_active). rpc_emit_pending_cae lo usa cuando la '
  'emisión no especifica PV y la cuenta tiene más de uno activo. Lo marca el '
  'dueño en Configuración; sin backfill.';

-- ── 2. CHECK: sólo un PV activo puede ser predeterminado ─────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.points_of_sale'::regclass
      AND  conname  = 'points_of_sale_default_is_active'
  ) THEN
    ALTER TABLE public.points_of_sale
      ADD CONSTRAINT points_of_sale_default_is_active
      CHECK (NOT is_default OR is_active);
  END IF;
END $$;

-- ── 3. Como mucho un predeterminado por cuenta ───────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS points_of_sale_one_default_per_account
  ON public.points_of_sale (account_id)
  WHERE is_default;

-- ── 4. Guard: sólo owner/admin puede cambiar is_default ──────────────────────
CREATE OR REPLACE FUNCTION public.points_of_sale_guard_default_owner_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF (TG_OP = 'INSERT' AND NEW.is_default)
     OR (TG_OP = 'UPDATE' AND NEW.is_default IS DISTINCT FROM OLD.is_default)
  THEN
    IF NOT EXISTS (
      SELECT 1
      FROM   public.account_members am
      JOIN   LATERAL unnest(public.member_active_roles(am.id)) AS r(code) ON true
      WHERE  am.account_id = NEW.account_id
        AND  am.user_id    = (SELECT auth.uid())
        AND  r.code IN ('owner', 'admin')
    ) THEN
      RAISE EXCEPTION 'unauthorized: only owner or admin can change points_of_sale.is_default'
        USING ERRCODE = 'P0401';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.points_of_sale_guard_default_owner_admin() IS
  'punto-venta-seleccion (hallazgo de red-team): la RLS de points_of_sale '
  'habilita UPDATE a los 7 roles is_writer=true (is_account_writer), no sólo '
  'owner/admin. Este disparador cierra ESE hueco puntual para is_default '
  '(P0401 si el actor no es owner/admin de la cuenta) — no reemplaza la RLS '
  'ni protege numero/is_active/fiscal_profile_id.';

-- Es SECURITY DEFINER (necesita leer account_members/member_active_roles sin
-- que la RLS del actor se lo permita) pero NUNCA una RPC de usuario: sólo la
-- invoca el trigger. Sin este REVOKE, test_function_acl_gate.sql (1) la
-- marca como una función trigger SECURITY DEFINER ejecutable por
-- anon/authenticated — el mismo gotcha 42725/re-GRANT que ya documentó
-- cuenta-corriente-party-guard.
REVOKE ALL ON FUNCTION public.points_of_sale_guard_default_owner_admin() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_points_of_sale_guard_default ON public.points_of_sale;
CREATE TRIGGER trg_points_of_sale_guard_default
  BEFORE INSERT OR UPDATE ON public.points_of_sale
  FOR EACH ROW
  EXECUTE FUNCTION public.points_of_sale_guard_default_owner_admin();

-- ── 5. rpc_emit_pending_cae: el predeterminado resuelve la ambigüedad ────────
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

  -- Resolver PV efectivo (D11). Los tres SELECT toman FOR SHARE: conflictúa
  -- con el FOR NO KEY UPDATE que toma una desactivación/cambio de
  -- predeterminado concurrente (fiscal-riesgos-residuales / TOCTOU hallado en
  -- red-team de punto-venta-seleccion), así que esta RPC espera a que esa
  -- transacción termine y vuelve a evaluar is_active/is_default con datos
  -- ya committeados en vez de emitir sobre un PV que está a punto de
  -- desactivarse.
  IF p_point_of_sale_id IS NOT NULL THEN
    SELECT id, numero INTO v_pv
    FROM   public.points_of_sale
    WHERE  id = p_point_of_sale_id
      AND  account_id = v_account_id
      AND  is_active = TRUE
    FOR SHARE;

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
      -- punto-venta-seleccion (D3): con varios activos y sin PV explícito, el
      -- predeterminado de la cuenta resuelve la ambigüedad. Sin predeterminado,
      -- P0422 como antes. `is_active` redundante con el CHECK
      -- points_of_sale_default_is_active: defensa en profundidad.
      SELECT id, numero INTO v_pv
      FROM   public.points_of_sale
      WHERE  account_id = v_account_id
        AND  is_active  = TRUE
        AND  is_default = TRUE
      FOR SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'ambiguous_point_of_sale: la cuenta tiene % puntos de venta activos — especificá point_of_sale_id', v_active_pv_count
          USING ERRCODE = 'P0422';
      END IF;
      v_effective_pv_id := v_pv.id;
    ELSE
      SELECT id, numero INTO v_pv
      FROM   public.points_of_sale
      WHERE  account_id = v_account_id AND is_active = TRUE
      FOR SHARE;
      -- Hallazgo de red-team (TOCTOU): con FOR SHARE, si el ÚNICO activo se
      -- desactivó en la transacción que este SELECT esperó, la fila deja de
      -- matchear el WHERE al re-evaluarse y NOT FOUND es real (no sólo
      -- teórico) — P0404 explícito en vez de dejar v_pv.id en NULL y
      -- reventar más abajo, en rpc_next_document_number, con otro error.
      IF NOT FOUND THEN
        RAISE EXCEPTION 'no_active_point_of_sale: la cuenta no tiene puntos de venta activos'
          USING ERRCODE = 'P0404';
      END IF;
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
  'CondicionIVAReceptorId. punto-venta-seleccion (D3): sin point_of_sale_id y '
  'con varios PV activos usa el predeterminado de la cuenta (is_default); sin '
  'predeterminado, P0422 ambiguous_point_of_sale como antes.';

-- RPC de USUARIO: `authenticated` CONSERVA su EXECUTE. `anon` y PUBLIC, nunca.
REVOKE ALL ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)
  TO authenticated, service_role, postgres;

-- ── 6. Introspección (sólo catálogo, sin datos) ──────────────────────────────
DO $$
DECLARE
  v_sig CONSTANT text :=
    'public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)';
  v_oid     oid;
  v_count   integer;
  v_def     text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE  attrelid = 'public.points_of_sale'::regclass
      AND  attname = 'is_default' AND NOT attisdropped AND attnotnull
  ) THEN
    RAISE EXCEPTION 'punto-venta-seleccion: falta points_of_sale.is_default NOT NULL';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.points_of_sale'::regclass
      AND  conname = 'points_of_sale_default_is_active' AND contype = 'c'
  ) THEN
    RAISE EXCEPTION 'punto-venta-seleccion: falta el CHECK points_of_sale_default_is_active';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    WHERE  i.indrelid = 'public.points_of_sale'::regclass
      AND  c.relname = 'points_of_sale_one_default_per_account'
      AND  i.indisunique AND i.indpred IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'punto-venta-seleccion: falta el índice único parcial points_of_sale_one_default_per_account';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE  tgrelid = 'public.points_of_sale'::regclass
      AND  tgname  = 'trg_points_of_sale_guard_default'
      AND  NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'punto-venta-seleccion: falta el trigger trg_points_of_sale_guard_default';
  END IF;

  IF has_function_privilege('anon', 'public.points_of_sale_guard_default_owner_admin()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.points_of_sale_guard_default_owner_admin()', 'EXECUTE')
     OR has_function_privilege('public', 'public.points_of_sale_guard_default_owner_admin()', 'EXECUTE') THEN
    RAISE EXCEPTION 'punto-venta-seleccion: points_of_sale_guard_default_owner_admin() es una función trigger y no debe ser ejecutable por anon/authenticated/PUBLIC';
  END IF;

  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_emit_pending_cae';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'punto-venta-seleccion: rpc_emit_pending_cae tiene % definiciones (overload 42725)', v_count;
  END IF;

  v_oid := to_regprocedure(v_sig);
  v_def := replace(pg_get_functiondef(v_oid), E'\r', '');
  IF v_def NOT LIKE '%is_default = TRUE%' THEN
    RAISE EXCEPTION 'punto-venta-seleccion: rpc_emit_pending_cae no contiene la rama del predeterminado';
  END IF;

  IF v_def NOT LIKE '%FOR SHARE%' THEN
    RAISE EXCEPTION 'punto-venta-seleccion: rpc_emit_pending_cae no toma FOR SHARE en la resolución de PV (TOCTOU)';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('public', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'punto-venta-seleccion: ACLs de rpc_emit_pending_cae incorrectas (anon/PUBLIC sin EXECUTE, authenticated con EXECUTE)';
  END IF;

  -- D5 (rpc_emit_subscription_payment_cae intacta) NO se fija con un md5 acá:
  -- esta migración corre de nuevo en el paso de reaplicación de
  -- KPI_Validation.yml sobre el estado ya reconvergido, y una reescritura
  -- futura A PROPÓSITO de esa RPC (documentada en su propia migración)
  -- rompería este DO block para siempre — la migración, a diferencia del
  -- gate, no se puede editar una vez aplicada en prod. La comprobación
  -- md5 real vive sólo en supabase/tests/test_punto_venta_predeterminado.sql,
  -- que sí se puede actualizar en el mismo PR que reescriba esa RPC.
  RAISE NOTICE 'punto-venta-seleccion (introspección): OK';
END $$;
