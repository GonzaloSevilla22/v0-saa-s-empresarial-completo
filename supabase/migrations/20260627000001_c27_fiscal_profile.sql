-- =============================================================================
-- MIGRATION: 20260627000001_c27_fiscal_profile.sql
-- CHANGE:    C-27 v21-fiscal-profile — FiscalProfile multi-PV + DocumentSequence
--            + adaptador WSFE (CAE asíncrono)
--
-- Implementa (design.md, OQs resueltas por el PO 2026-06-12):
--   1. fiscal_profiles — perfil fiscal 1:1 con accounts (sin punto_de_venta — OQ-2).
--   2. points_of_sale — multi-PV por cuenta, FK a fiscal_profiles.
--   3. document_sequences — numeración por (point_of_sale_id, comprobante_type).
--   4. fiscal_documents — comprobante con máquina de estados pending_cae→authorized|rejected.
--   5. rpc_next_document_number — lock corto, UPDATE-then-INSERT (NO upsert acumulativo).
--   6. rpc_emit_pending_cae — reserva número + inserta pending_cae; resuelve PV
--      efectivo; P0422 ambiguous_point_of_sale si hay varios PVs activos sin especificar.
--   7. pg_cron relay-process-pending-cae — dispatcher cada minuto.
--   8. Bucket privado afip-certs + Storage policies.
--
-- ERRCODE convention: 5 chars P04xx (P0400/P0401/P0403/P0404/P0409/P0422).
-- P0422 ambiguous_point_of_sale: varios PVs activos sin especificar point_of_sale_id.
--
-- GOVERNANCE: CRÍTICO — PO aprobó proposal + design + tasks (PRs #168/#169).
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
-- ROLLBACK:
--   SELECT cron.unschedule('relay-process-pending-cae');
--   DROP FUNCTION IF EXISTS public.rpc_emit_pending_cae CASCADE;
--   DROP FUNCTION IF EXISTS public.rpc_next_document_number CASCADE;
--   DROP TABLE IF EXISTS public.fiscal_documents CASCADE;
--   DROP TABLE IF EXISTS public.document_sequences CASCADE;
--   DROP TABLE IF EXISTS public.points_of_sale CASCADE;
--   DROP TABLE IF EXISTS public.fiscal_profiles CASCADE;
-- =============================================================================


-- ============================================================
-- 1.1 fiscal_profiles — perfil fiscal 1:1 con accounts
-- ============================================================
CREATE TABLE IF NOT EXISTS public.fiscal_profiles (
  id                    uuid        NOT NULL DEFAULT gen_random_uuid(),
  account_id            uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  cuit                  text        NOT NULL,
  iva_condition         text        NOT NULL
    CHECK (iva_condition IN ('responsable_inscripto', 'monotributista', 'exento', 'consumidor_final')),
  iibb_condition        text        NULL,
  certificado_afip_path text        NULL,
  ambiente              text        NOT NULL DEFAULT 'homologacion'
    CHECK (ambiente IN ('homologacion', 'produccion')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fiscal_profiles_pkey PRIMARY KEY (id),
  CONSTRAINT fiscal_profiles_account_id_unique UNIQUE (account_id)
);

COMMENT ON TABLE public.fiscal_profiles IS
  'C-27: perfil fiscal del emisor (CUIT, condición IVA, IIBB, ambiente AFIP). '
  '1:1 con accounts. Los puntos de venta viven en points_of_sale (multi-PV).';

CREATE INDEX IF NOT EXISTS fiscal_profiles_account_idx
  ON public.fiscal_profiles (account_id);

ALTER TABLE public.fiscal_profiles ENABLE ROW LEVEL SECURITY;

-- SELECT: miembros de la cuenta
DROP POLICY IF EXISTS "fiscal_profiles_member_select" ON public.fiscal_profiles;
CREATE POLICY "fiscal_profiles_member_select" ON public.fiscal_profiles
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- INSERT: solo owner/admin (is_account_writer en WITH CHECK)
DROP POLICY IF EXISTS "fiscal_profiles_writer_insert" ON public.fiscal_profiles;
CREATE POLICY "fiscal_profiles_writer_insert" ON public.fiscal_profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_account_writer(account_id));

-- UPDATE: solo owner/admin (USING + WITH CHECK)
DROP POLICY IF EXISTS "fiscal_profiles_writer_update" ON public.fiscal_profiles;
CREATE POLICY "fiscal_profiles_writer_update" ON public.fiscal_profiles
  FOR UPDATE
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (public.is_account_writer(account_id));


-- ============================================================
-- 1.2 points_of_sale — puntos de venta AFIP (multi-PV por cuenta)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.points_of_sale (
  id                uuid        NOT NULL DEFAULT gen_random_uuid(),
  fiscal_profile_id uuid        NOT NULL REFERENCES public.fiscal_profiles(id) ON DELETE CASCADE,
  account_id        uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  branch_id         uuid        NULL     REFERENCES public.branches(id) ON DELETE SET NULL,
  numero            integer     NOT NULL,
  is_active         boolean     NOT NULL DEFAULT TRUE,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT points_of_sale_pkey PRIMARY KEY (id),
  CONSTRAINT points_of_sale_unique_numero UNIQUE (fiscal_profile_id, numero),
  CONSTRAINT points_of_sale_numero_positive CHECK (numero > 0)
);

COMMENT ON TABLE public.points_of_sale IS
  'C-27 (OQ-2 multi-PV): punto de venta AFIP de la cuenta. '
  'account_id desnormalizado para RLS directa (patrón C-26). '
  'branch_id NULL en V2.1; se endurece a NOT NULL en C-29 (quickSale).';

CREATE INDEX IF NOT EXISTS points_of_sale_account_idx
  ON public.points_of_sale (account_id, is_active);

CREATE INDEX IF NOT EXISTS points_of_sale_fiscal_profile_idx
  ON public.points_of_sale (fiscal_profile_id);

ALTER TABLE public.points_of_sale ENABLE ROW LEVEL SECURITY;

-- SELECT: miembros de la cuenta
DROP POLICY IF EXISTS "points_of_sale_member_select" ON public.points_of_sale;
CREATE POLICY "points_of_sale_member_select" ON public.points_of_sale
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- INSERT: solo owner/admin
DROP POLICY IF EXISTS "points_of_sale_writer_insert" ON public.points_of_sale;
CREATE POLICY "points_of_sale_writer_insert" ON public.points_of_sale
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_account_writer(account_id));

-- UPDATE: solo owner/admin (USING + WITH CHECK)
DROP POLICY IF EXISTS "points_of_sale_writer_update" ON public.points_of_sale;
CREATE POLICY "points_of_sale_writer_update" ON public.points_of_sale
  FOR UPDATE
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (public.is_account_writer(account_id));


-- ============================================================
-- 1.3 document_sequences — numeración por (point_of_sale_id, comprobante_type)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.document_sequences (
  id                uuid        NOT NULL DEFAULT gen_random_uuid(),
  point_of_sale_id  uuid        NOT NULL REFERENCES public.points_of_sale(id) ON DELETE CASCADE,
  comprobante_type  text        NOT NULL,
  last_number       bigint      NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT document_sequences_pkey PRIMARY KEY (id),
  CONSTRAINT document_sequences_unique_pv_type UNIQUE (point_of_sale_id, comprobante_type),
  CONSTRAINT document_sequences_last_number_non_negative CHECK (last_number >= 0)
);

COMMENT ON TABLE public.document_sequences IS
  'C-27 (D3): numeración AFIP por punto de venta y tipo de comprobante. '
  'Escritura EXCLUSIVA vía rpc_next_document_number (SECURITY DEFINER). '
  'SELECT via join a points_of_sale → account_id para RLS.';

CREATE INDEX IF NOT EXISTS document_sequences_pv_idx
  ON public.document_sequences (point_of_sale_id);

ALTER TABLE public.document_sequences ENABLE ROW LEVEL SECURITY;

-- SELECT: miembros de la cuenta (vía join a points_of_sale)
DROP POLICY IF EXISTS "document_sequences_member_select" ON public.document_sequences;
CREATE POLICY "document_sequences_member_select" ON public.document_sequences
  FOR SELECT
  TO authenticated
  USING (
    point_of_sale_id IN (
      SELECT id FROM public.points_of_sale
      WHERE account_id IN (SELECT current_account_ids())
    )
  );
-- NO INSERT/UPDATE policies: la escritura es EXCLUSIVA vía RPC SECURITY DEFINER.


-- ============================================================
-- 1.4 fiscal_documents — comprobante con máquina de estados CAE
-- ============================================================
CREATE TABLE IF NOT EXISTS public.fiscal_documents (
  id                uuid        NOT NULL DEFAULT gen_random_uuid(),
  account_id        uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  fiscal_profile_id uuid        NOT NULL REFERENCES public.fiscal_profiles(id) ON DELETE CASCADE,
  point_of_sale_id  uuid        NOT NULL REFERENCES public.points_of_sale(id) ON DELETE CASCADE,
  comprobante_type  text        NOT NULL,
  punto_de_venta    integer     NOT NULL,  -- snapshot del numero del PV al emitir
  number            bigint      NOT NULL,
  client_id         uuid        NULL REFERENCES public.clients(id) ON DELETE SET NULL,
  total             numeric(15,2) NOT NULL DEFAULT 0,
  status            text        NOT NULL DEFAULT 'pending_cae'
    CHECK (status IN ('pending_cae', 'authorized', 'rejected')),
  cae               text        NULL,
  cae_due_date      date        NULL,
  attempts          integer     NOT NULL DEFAULT 0,
  next_attempt_at   timestamptz NULL,
  last_error        text        NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fiscal_documents_pkey PRIMARY KEY (id)
);

COMMENT ON TABLE public.fiscal_documents IS
  'C-27 (D5): comprobante fiscal emitido. Nace en pending_cae (sin tocar AFIP), '
  'transiciona a authorized o rejected vía relay del CAE en background. '
  'RLS por account_id. Índice parcial sobre pending_cae = cola del relay.';

CREATE INDEX IF NOT EXISTS fiscal_documents_account_idx
  ON public.fiscal_documents (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS fiscal_documents_pending_cae_idx
  ON public.fiscal_documents (next_attempt_at NULLS FIRST)
  WHERE status = 'pending_cae';

ALTER TABLE public.fiscal_documents ENABLE ROW LEVEL SECURITY;

-- SELECT: miembros de la cuenta
DROP POLICY IF EXISTS "fiscal_documents_member_select" ON public.fiscal_documents;
CREATE POLICY "fiscal_documents_member_select" ON public.fiscal_documents
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- INSERT: solo owner/admin (el backend emite vía rpc_emit_pending_cae,
-- pero los tests de integración y el endpoint directo pueden insertar directamente)
DROP POLICY IF EXISTS "fiscal_documents_writer_insert" ON public.fiscal_documents;
CREATE POLICY "fiscal_documents_writer_insert" ON public.fiscal_documents
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_account_writer(account_id));

-- UPDATE: solo vía service_role o RPC definer (relay del CAE)
-- No exponemos UPDATE policy a authenticated; el relay usa service_role.


-- ============================================================
-- 1.6 rpc_next_document_number — lock corto, UPDATE-then-INSERT
--     SECURITY DEFINER con guard is_account_writer
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_next_document_number(
  p_point_of_sale_id uuid,
  p_comprobante_type text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_pv_account_id  uuid;
  v_next_number    bigint;
  v_updated        integer;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id del PV para el guard
  SELECT account_id INTO v_pv_account_id
  FROM   public.points_of_sale
  WHERE  id = p_point_of_sale_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'point_of_sale_not_found: %', p_point_of_sale_id
      USING ERRCODE = 'P0404';
  END IF;

  -- Guard: solo owner/admin de la cuenta puede numerar
  IF NOT public.is_account_writer(v_pv_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can number fiscal documents'
      USING ERRCODE = 'P0401';
  END IF;

  -- Lock corto: SELECT FOR UPDATE sobre la fila de secuencia
  -- Gotcha del proyecto: NO upsert acumulativo; usar UPDATE-then-INSERT
  UPDATE public.document_sequences
  SET    last_number = last_number + 1
  WHERE  point_of_sale_id = p_point_of_sale_id
    AND  comprobante_type = p_comprobante_type
  RETURNING last_number INTO v_next_number;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated = 0 THEN
    -- Primera vez: INSERT si no existe la fila
    INSERT INTO public.document_sequences (point_of_sale_id, comprobante_type, last_number)
    VALUES (p_point_of_sale_id, p_comprobante_type, 1)
    ON CONFLICT (point_of_sale_id, comprobante_type)
      DO UPDATE SET last_number = public.document_sequences.last_number + 1
    RETURNING last_number INTO v_next_number;
  END IF;

  RETURN v_next_number;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_next_document_number(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_next_document_number(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_next_document_number(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_next_document_number IS
  'C-27 (D3): entrega el próximo número de comprobante para (point_of_sale_id, comprobante_type). '
  'SELECT FOR UPDATE serializa el acceso; UPDATE-then-INSERT evita el gotcha de upsert acumulativo '
  'sobre tablas con CHECK (encontrado en C-26 con branch_stock). '
  'SECURITY DEFINER con guard is_account_writer sobre el account_id del PV.';


-- ============================================================
-- 1.7 rpc_emit_pending_cae — reserva número + persiste pending_cae
--     Resuelve PV efectivo; P0422 ambiguous_point_of_sale si hay varios
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_emit_pending_cae(
  p_comprobante_type  text,
  p_total             numeric,
  p_client_id         uuid    DEFAULT NULL,
  p_point_of_sale_id  uuid    DEFAULT NULL
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
    -- PV especificado: verificar que pertenece a la cuenta y está activo
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
    -- Sin PV especificado: resolver automáticamente
    SELECT count(*) INTO v_active_pv_count
    FROM   public.points_of_sale
    WHERE  account_id = v_account_id AND is_active = TRUE;

    IF v_active_pv_count = 0 THEN
      RAISE EXCEPTION 'no_active_point_of_sale: la cuenta no tiene puntos de venta activos'
        USING ERRCODE = 'P0404';
    ELSIF v_active_pv_count > 1 THEN
      -- D11: PV ambiguo → P0422 ambiguous_point_of_sale
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
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    client_id, total, status
  ) VALUES (
    v_account_id, v_profile.id, v_effective_pv_id,
    p_comprobante_type, v_pv.numero, v_doc_number,
    p_client_id, COALESCE(p_total, 0), 'pending_cae'
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

REVOKE ALL     ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_pending_cae(text, numeric, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_emit_pending_cae IS
  'C-27 (D5/D11): emite un comprobante fiscal en pending_cae de forma síncrona. '
  'Resuelve el PV efectivo (auto si 1 PV activo; P0422 ambiguous_point_of_sale si varios sin especificar). '
  'Reserva número vía rpc_next_document_number + INSERT fiscal_documents. SIN llamar a AFIP.';


-- ============================================================
-- 1.9 pg_cron relay del CAE — dispatcher cada minuto
--     Patrón: como reset-ai-counters (job ya existente)
-- ============================================================
-- El endpoint backend /fiscal/documents/process-pending (relay idempotente, OQ-1=A)
-- se dispara vía pg_cron cada minuto para procesar los comprobantes pending_cae.
-- En la fase inicial (stub adapter) el cron llama un SELECT de mantenimiento;
-- cuando el adaptador real esté disponible, se cambia el comando sin migrar datos.
SELECT cron.unschedule('relay-process-pending-cae') FROM cron.job WHERE jobname = 'relay-process-pending-cae';

SELECT cron.schedule(
  'relay-process-pending-cae',
  '* * * * *',  -- cada minuto
  $$
    -- C-27 (OQ-1=A): trigger del relay idempotente del CAE.
    -- El relay real POST /fiscal/documents/process-pending se llama desde el backend.
    -- Este job marca next_attempt_at para los pending sin programar (arranque).
    UPDATE public.fiscal_documents
    SET next_attempt_at = now()
    WHERE status = 'pending_cae'
      AND next_attempt_at IS NULL
      AND attempts < 10;
  $$
);

COMMENT ON TABLE public.fiscal_documents IS
  'C-27 (D5): comprobante fiscal emitido. Nace en pending_cae (sin tocar AFIP), '
  'transiciona a authorized o rejected vía relay del CAE en background (pg_cron cada minuto). '
  'RLS por account_id. Índice parcial sobre pending_cae = cola del relay.';


-- ============================================================
-- 1.8 Bucket privado afip-certs + Storage policies
-- ============================================================
-- NOTA: El bucket se crea vía la API de Storage (no SQL DDL).
-- Las policies de Storage se aplican vía INSERT en storage.objects (si RLS).
-- En Supabase, los buckets privados se crean con:
--   INSERT INTO storage.buckets (id, name, public) VALUES ('afip-certs', 'afip-certs', false)
--   ON CONFLICT (id) DO NOTHING;
-- Y las policies de Storage se crean directamente.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'afip-certs',
  'afip-certs',
  false,  -- PRIVADO — nunca público
  1048576,  -- 1MB max por cert
  ARRAY['application/x-pem-file', 'application/octet-stream', 'text/plain']
)
ON CONFLICT (id) DO UPDATE SET public = false;

-- Storage RLS policies para afip-certs
-- INSERT: el path debe empezar con el account_id del usuario
DROP POLICY IF EXISTS "afip_certs_insert" ON storage.objects;
CREATE POLICY "afip_certs_insert" ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'afip-certs'
    AND (storage.foldername(name))[1] IN (SELECT current_account_ids()::text)
    AND public.is_account_writer((storage.foldername(name))[1]::uuid)
  );

-- SELECT: miembros de la cuenta
DROP POLICY IF EXISTS "afip_certs_select" ON storage.objects;
CREATE POLICY "afip_certs_select" ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'afip-certs'
    AND (storage.foldername(name))[1] IN (SELECT current_account_ids()::text)
  );

-- UPDATE: owner/admin
DROP POLICY IF EXISTS "afip_certs_update" ON storage.objects;
CREATE POLICY "afip_certs_update" ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'afip-certs'
    AND (storage.foldername(name))[1] IN (SELECT current_account_ids()::text)
  )
  WITH CHECK (
    bucket_id = 'afip-certs'
    AND (storage.foldername(name))[1] IN (SELECT current_account_ids()::text)
    AND public.is_account_writer((storage.foldername(name))[1]::uuid)
  );


-- =============================================================================
-- VERIFICATION (post-push):
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema='public' AND table_name IN
--   ('fiscal_profiles','points_of_sale','document_sequences','fiscal_documents'); -- 4 rows
--   SELECT proname FROM pg_proc WHERE proname IN
--   ('rpc_next_document_number','rpc_emit_pending_cae'); -- 2 rows
--   SELECT jobname FROM cron.job WHERE jobname='relay-process-pending-cae'; -- 1 row
--   SELECT id FROM storage.buckets WHERE id='afip-certs'; -- 1 row
-- =============================================================================
