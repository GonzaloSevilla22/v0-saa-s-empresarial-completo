-- =============================================================================
-- 20261067000001_presupuestos_modulo.sql
-- presupuestos-modulo, TANDA A (governance MEDIA; sign-off del PO 2026-10-01:
-- «Anda con todo lo recomendado me parece bien», OQ-P1..P16 por su
-- recomendación). Ver openspec/changes/presupuestos-modulo/design.md.
--
-- Qué hace (sin dinero: la conversión a venta es la tanda B, 20261068000001):
--
--   1. quotes gana number (D3), notes (CHECK 2.000), sent_at, updated_at,
--      updated_by y revision (D1: versión del contenido, la incrementa cada
--      edición). UNIQUE (account_id, number). quote_items gana line_no (orden
--      de carga de las líneas: sin él el detalle y el PDF salían en un orden
--      no garantizado). accounts gana default_quote_validity_days (D7: 15,
--      CHECK 1..365) — columna de privilegio, nace sin UPDATE para la API de
--      datos (allow-list por columna vacía de accounts).
--   2. Numeración interna NO fiscal (capability internal-document-numbering,
--      D3): tabla internal_document_sequences (CHECK cerrado: 'quote'),
--      _next_internal_document_number (UPDATE-then-INSERT con reintento ante
--      unique_violation, nunca ON CONFLICT DO UPDATE),
--      _assign_internal_document_number (siguiente o número explícito que
--      avanza la secuencia) y el disparador GENÉRICO
--      trg_assign_internal_document_number(TG_ARGV[0]), enganchado a quotes
--      como quotes_assign_number('quote'). La validez por defecto vive en un
--      disparador propio del presupuesto (quotes_default_valid_until).
--   3. FSM (D4): filas nuevas quote: expired -> draft y rejected -> draft
--      (reapertura por edición, {seller,admin,owner}) e is_terminal_to = false
--      en quote: draft|sent -> expired|rejected — accepted queda como único
--      terminal de quote.
--   4. Escritura sólo por RPC (D2, D5, D7, D8, D11): rpc_create_quote,
--      rpc_update_quote, rpc_transition_quote, rpc_delete_quote,
--      rpc_set_default_quote_validity y rpc_commercial_issuer, SECURITY
--      DEFINER, sin anon. Guards de tenencia (cliente vivo, producto vivo de la
--      cuenta y no padre, unidad del sistema o de la cuenta también en una
--      línea de servicio, compatibilidad RN-24), rol CAN_QUOTE
--      ({seller,admin,owner}, P0403) verificado ANTES de escribir, total
--      calculado en el servidor (RN-24-bis), snapshots desde el maestro
--      FILTRADO por cuenta y re-tomados al editar, P0423 en accepted,
--      historial en cada transición.
--   5. Se retiran las 4 políticas de escritura directa (quotes_insert,
--      quotes_update, quote_items_insert, quote_items_update) y los
--      privilegios INSERT/UPDATE/DELETE/TRUNCATE de la API de datos sobre las
--      dos tablas: quedan sólo los SELECT (patrón de sales_orders).
--   6. Vencimiento (D7): _expire_overdue_quotes (FOR UPDATE SKIP LOCKED, actor
--      uuid cero, motivo "vencimiento automático") + pg_cron
--      quotes-expire-sweep (03:05 UTC = 00:05 ART), idempotente
--      (unschedule + schedule).
--   7. Backfill defensivo (D14) de number y valid_until de presupuestos
--      previos (POST /quotes con INSERT directo sigue vivo hasta el deploy),
--      encapsulado en _quotes_backfill_number_and_validity() para que el gate
--      lo ejecute de verdad.
--   8. Bloque DO de introspección al final.
--
-- Idempotente (auto-apply de Supabase GitHub): ADD COLUMN IF NOT EXISTS,
-- constraints guardadas contra pg_constraint, CREATE TABLE/INDEX IF NOT
-- EXISTS, CREATE OR REPLACE FUNCTION con firmas nuevas (sin overload previo,
-- sin riesgo de 42725), DROP POLICY/TRIGGER IF EXISTS + CREATE, INSERT … ON
-- CONFLICT DO NOTHING, UPDATE/REVOKE/GRANT re-ejecutables.
--
-- Gate: supabase/tests/test_presupuestos_modulo.sql (EJECUTA las 6 RPCs, el
-- barrido y el backfill) + supabase/tests/test_internal_document_numbering_race.sh.
-- =============================================================================


-- =============================================================================
-- 1. Columnas
-- =============================================================================
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS number     bigint;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS notes      text;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS sent_at    timestamptz;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS updated_at timestamptz;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS updated_by uuid;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS revision   integer NOT NULL DEFAULT 1;

ALTER TABLE public.quote_items ADD COLUMN IF NOT EXISTS line_no integer;

ALTER TABLE public.accounts ADD COLUMN IF NOT EXISTS default_quote_validity_days integer NOT NULL DEFAULT 15;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.quotes'::regclass AND conname = 'quotes_account_number_key') THEN
    ALTER TABLE public.quotes ADD CONSTRAINT quotes_account_number_key UNIQUE (account_id, number);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.quotes'::regclass AND conname = 'quotes_number_positive') THEN
    ALTER TABLE public.quotes ADD CONSTRAINT quotes_number_positive CHECK (number IS NULL OR number > 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.quotes'::regclass AND conname = 'quotes_notes_max_length') THEN
    ALTER TABLE public.quotes ADD CONSTRAINT quotes_notes_max_length CHECK (notes IS NULL OR char_length(notes) <= 2000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.quotes'::regclass AND conname = 'quotes_revision_positive') THEN
    ALTER TABLE public.quotes ADD CONSTRAINT quotes_revision_positive CHECK (revision >= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.accounts'::regclass AND conname = 'accounts_default_quote_validity_days_range') THEN
    ALTER TABLE public.accounts ADD CONSTRAINT accounts_default_quote_validity_days_range
      CHECK (default_quote_validity_days BETWEEN 1 AND 365);
  END IF;
END $$;

-- El barrido diario recorre sólo los abiertos.
CREATE INDEX IF NOT EXISTS quotes_open_valid_until_idx
  ON public.quotes (valid_until) WHERE status IN ('draft', 'sent');
CREATE INDEX IF NOT EXISTS quotes_account_client_idx
  ON public.quotes (account_id, client_id);

COMMENT ON TABLE public.quotes IS
  'Presupuesto/cotización (C-29; presupuestos-modulo). FSM del catálogo document_status_transitions: '
  'draft→sent, draft|sent→accepted|rejected|expired, expired|rejected→draft (reapertura al editar); '
  'accepted ("convertido en venta") es el único terminal. Escritura SÓLO por RPC (rpc_create_quote, '
  'rpc_update_quote, rpc_transition_quote, rpc_delete_quote; vencimiento por _expire_overdue_quotes). '
  'No toca stock, caja, banco ni cuenta corriente.';
COMMENT ON COLUMN public.quotes.number IS
  'presupuestos-modulo (D3): número interno correlativo por cuenta (internal_document_sequences, tipo quote), '
  'asignado por el disparador quotes_assign_number. Visible como P-00000012. Nullable sólo por los escritores '
  'que insertan con session_replication_role = replica.';
COMMENT ON COLUMN public.quotes.notes IS 'presupuestos-modulo (D1): condiciones / forma de entrega. Hasta 2.000 caracteres.';
COMMENT ON COLUMN public.quotes.sent_at IS 'presupuestos-modulo (D1): primera vez que el presupuesto pasó a sent.';
COMMENT ON COLUMN public.quotes.updated_at IS 'presupuestos-modulo (D1): última edición (rpc_update_quote).';
COMMENT ON COLUMN public.quotes.updated_by IS 'presupuestos-modulo (D1): usuario de la última edición.';
COMMENT ON COLUMN public.quotes.revision IS
  'presupuestos-modulo (D1): versión del contenido. Empieza en 1; rpc_update_quote la incrementa. La edición y la '
  'conversión reciben la versión que el usuario vio y rechazan con P0409 quote_changed si cambió. Las transiciones '
  'no la tocan.';
COMMENT ON COLUMN public.quote_items.line_no IS
  'presupuestos-modulo: orden de carga de la línea (1..N, ordinalidad del payload p_items).';
COMMENT ON COLUMN public.accounts.default_quote_validity_days IS
  'presupuestos-modulo (D7): validez por defecto de los presupuestos, en días (1..365). Se escribe sólo por '
  'rpc_set_default_quote_validity (owner/admin).';


-- =============================================================================
-- 2. Numeración interna (internal-document-numbering)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.internal_document_sequences (
  account_id    uuid   NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  document_type text   NOT NULL,
  last_number   bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, document_type)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.internal_document_sequences'::regclass
                   AND conname = 'internal_document_sequences_document_type_check') THEN
    ALTER TABLE public.internal_document_sequences
      ADD CONSTRAINT internal_document_sequences_document_type_check CHECK (document_type IN ('quote'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.internal_document_sequences'::regclass
                   AND conname = 'internal_document_sequences_last_number_check') THEN
    ALTER TABLE public.internal_document_sequences
      ADD CONSTRAINT internal_document_sequences_last_number_check CHECK (last_number >= 0);
  END IF;
END $$;

ALTER TABLE public.internal_document_sequences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS internal_document_sequences_select ON public.internal_document_sequences;
CREATE POLICY internal_document_sequences_select
  ON public.internal_document_sequences
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

REVOKE ALL ON TABLE public.internal_document_sequences FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.internal_document_sequences FROM authenticated;

COMMENT ON TABLE public.internal_document_sequences IS
  'internal-document-numbering (presupuestos-modulo D3): último número entregado por cuenta y tipo de documento '
  'NO fiscal. Independiente de document_sequences (fiscal, por punto de venta). El CHECK de document_type se '
  'amplía de forma aditiva (remitos-venta sumará delivery_note). Sin políticas de escritura: sólo la escriben '
  '_next_internal_document_number / _assign_internal_document_number.';


-- Siguiente número. UPDATE-then-INSERT (patrón de rpc_next_document_number):
-- el UPDATE toma el lock de la fila hasta el commit del alta (sin huecos: un
-- alta que se revierte revierte el incremento); si la fila no existe, el
-- INSERT puede chocar con otro concurrente y en ese caso se reintenta el
-- UPDATE una vez. Nunca INSERT … ON CONFLICT DO UPDATE (gotcha de CHECK).
CREATE OR REPLACE FUNCTION public._next_internal_document_number(p_account_id uuid, p_document_type text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_number bigint;
BEGIN
  IF p_account_id IS NULL OR p_document_type IS NULL THEN
    RAISE EXCEPTION 'internal_document_number_invalid_args: cuenta y tipo son obligatorios'
      USING ERRCODE = 'P0400';
  END IF;

  UPDATE public.internal_document_sequences
  SET    last_number = last_number + 1
  WHERE  account_id = p_account_id AND document_type = p_document_type
  RETURNING last_number INTO v_number;
  IF FOUND THEN
    RETURN v_number;
  END IF;

  BEGIN
    INSERT INTO public.internal_document_sequences (account_id, document_type, last_number)
    VALUES (p_account_id, p_document_type, 1);
    RETURN 1;
  EXCEPTION WHEN unique_violation THEN
    UPDATE public.internal_document_sequences
    SET    last_number = last_number + 1
    WHERE  account_id = p_account_id AND document_type = p_document_type
    RETURNING last_number INTO v_number;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'internal_document_number_unavailable: no se pudo reservar el número de % para %',
        p_document_type, p_account_id USING ERRCODE = 'P0409';
    END IF;
    RETURN v_number;
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public._next_internal_document_number(uuid, text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._next_internal_document_number(uuid, text) IS
  'internal-document-numbering (D3): entrega el siguiente número interno de (cuenta, tipo) bajo lock de fila, '
  'UPDATE-then-INSERT con reintento ante unique_violation. Sin huecos ni repetidos. Interna: sin EXECUTE para '
  'los roles de aplicación.';


-- Asignación: sin número -> el siguiente; con número explícito -> se respeta y
-- avanza la secuencia hasta él (GREATEST), creando la fila si falta.
CREATE OR REPLACE FUNCTION public._assign_internal_document_number(p_account_id uuid, p_document_type text, p_explicit bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_explicit IS NULL THEN
    RETURN public._next_internal_document_number(p_account_id, p_document_type);
  END IF;

  IF p_account_id IS NULL OR p_document_type IS NULL THEN
    RAISE EXCEPTION 'internal_document_number_invalid_args: cuenta y tipo son obligatorios'
      USING ERRCODE = 'P0400';
  END IF;

  UPDATE public.internal_document_sequences
  SET    last_number = GREATEST(last_number, p_explicit)
  WHERE  account_id = p_account_id AND document_type = p_document_type;
  IF NOT FOUND THEN
    BEGIN
      INSERT INTO public.internal_document_sequences (account_id, document_type, last_number)
      VALUES (p_account_id, p_document_type, GREATEST(p_explicit, 0));
    EXCEPTION WHEN unique_violation THEN
      UPDATE public.internal_document_sequences
      SET    last_number = GREATEST(last_number, p_explicit)
      WHERE  account_id = p_account_id AND document_type = p_document_type;
    END;
  END IF;
  RETURN p_explicit;
END;
$function$;

REVOKE ALL ON FUNCTION public._assign_internal_document_number(uuid, text, bigint) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._assign_internal_document_number(uuid, text, bigint) IS
  'internal-document-numbering (D3): regla única de asignación. NULL -> _next_internal_document_number; número '
  'explícito -> se respeta y avanza la secuencia (last_number = GREATEST(last_number, explícito)). La unicidad la '
  'protege el UNIQUE de la tabla del documento. Interna: sin EXECUTE para los roles de aplicación.';


-- Disparador genérico: el tipo de documento llega por TG_ARGV[0]. Un tipo nuevo
-- sólo suma su CREATE TRIGGER y su valor al CHECK, sin copiar lógica.
CREATE OR REPLACE FUNCTION public.trg_assign_internal_document_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  NEW.number := public._assign_internal_document_number(NEW.account_id, TG_ARGV[0], NEW.number);
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.trg_assign_internal_document_number() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.trg_assign_internal_document_number() IS
  'internal-document-numbering (D3): BEFORE INSERT genérico, parametrizado por el tipo (TG_ARGV[0]). Asigna '
  'NEW.number con _assign_internal_document_number. Paso obligado para todo escritor con disparadores activos.';

DROP TRIGGER IF EXISTS quotes_assign_number ON public.quotes;
CREATE TRIGGER quotes_assign_number
  BEFORE INSERT ON public.quotes
  FOR EACH ROW EXECUTE FUNCTION public.trg_assign_internal_document_number('quote');


-- Validez por defecto: lógica PROPIA del presupuesto (no vive en la pieza
-- compartida de numeración).
CREATE OR REPLACE FUNCTION public.trg_quote_default_valid_until()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.valid_until IS NULL THEN
    NEW.valid_until := public.reporting_local_today()
      + COALESCE((SELECT a.default_quote_validity_days FROM public.accounts a WHERE a.id = NEW.account_id), 15);
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.trg_quote_default_valid_until() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.trg_quote_default_valid_until() IS
  'presupuestos-modulo (D3/D7): BEFORE INSERT de quotes — un valid_until NULL nace como día de negocio argentino '
  '+ accounts.default_quote_validity_days. Ningún presupuesto con disparadores activos nace sin vencimiento.';

DROP TRIGGER IF EXISTS quotes_default_valid_until ON public.quotes;
CREATE TRIGGER quotes_default_valid_until
  BEFORE INSERT ON public.quotes
  FOR EACH ROW EXECUTE FUNCTION public.trg_quote_default_valid_until();


-- =============================================================================
-- 3. FSM: reapertura por edición; accepted como único terminal de quote (D4)
-- =============================================================================
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('quote', 'expired',  'draft', false, false, ARRAY['seller', 'admin', 'owner']),
  ('quote', 'rejected', 'draft', false, false, ARRAY['seller', 'admin', 'owner'])
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;

UPDATE public.document_status_transitions
SET    is_terminal_to = false
WHERE  document_type = 'quote'
  AND  from_status IN ('draft', 'sent')
  AND  to_status IN ('expired', 'rejected')
  AND  is_terminal_to;


-- =============================================================================
-- 4. Helpers internos de escritura del presupuesto
-- =============================================================================

-- Writer de la cuenta (P0401) + rol CAN_QUOTE (P0403), con el mismo predicado
-- que record_status_transition (roles ACTIVOS no vencidos ∩ {seller,admin,owner}).
CREATE OR REPLACE FUNCTION public._quote_assert_can_write(p_account_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;
  IF NOT (public.account_user_active_roles(p_account_id, auth.uid()) && ARRAY['seller', 'admin', 'owner']) THEN
    RAISE EXCEPTION 'insufficient_role: tu rol no permite gestionar presupuestos (requiere vendedor, administrador o dueño)'
      USING ERRCODE = 'P0403';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._quote_assert_can_write(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._quote_assert_can_write(uuid) IS
  'presupuestos-modulo (D11): guard común de escritura — is_account_writer (P0401) y rol CAN_QUOTE '
  '{seller,admin,owner} activo (P0403 insufficient_role), el mismo conjunto que el catálogo de transiciones de '
  'quote. Interna: la invocan las RPCs SECURITY DEFINER antes de escribir.';


-- Valida el payload de líneas contra la cuenta y devuelve el total del
-- servidor (round(Σ subtotal, 2), RN-24-bis). No escribe.
CREATE OR REPLACE FUNCTION public._quote_validate_items(p_account_id uuid, p_items jsonb)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_item     jsonb;
  v_pid      uuid;
  v_uid      uuid;
  v_qty      numeric;
  v_price    numeric;
  v_sub      numeric;
  v_desc     text;
  v_product  RECORD;
  v_total    numeric := 0;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'quote_items_required: el presupuesto necesita al menos una línea' USING ERRCODE = 'P0400';
  END IF;
  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'quote_too_many_items: máximo 500 líneas por presupuesto' USING ERRCODE = 'P0400';
  END IF;

  FOR v_item IN SELECT e FROM jsonb_array_elements(p_items) AS e LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION 'quote_line_invalid: cada línea debe ser un objeto' USING ERRCODE = 'P0400';
    END IF;

    v_pid   := NULLIF(v_item->>'product_id', '')::uuid;
    v_uid   := NULLIF(v_item->>'unit_id', '')::uuid;
    v_qty   := (v_item->>'quantity')::numeric;
    v_price := (v_item->>'price')::numeric;
    v_sub   := (v_item->>'subtotal')::numeric;
    v_desc  := NULLIF(btrim(COALESCE(v_item->>'description', '')), '');

    IF v_qty IS NULL OR round(v_qty, 4) <= 0 THEN
      RAISE EXCEPTION 'quote_line_invalid_quantity: la cantidad debe ser mayor que 0' USING ERRCODE = 'P0400';
    END IF;
    IF v_price IS NULL OR v_price < 0 THEN
      RAISE EXCEPTION 'quote_line_invalid_price: el precio no puede ser negativo' USING ERRCODE = 'P0400';
    END IF;
    IF v_sub IS NULL OR v_sub < 0 THEN
      RAISE EXCEPTION 'quote_line_invalid_subtotal: el subtotal no puede ser negativo' USING ERRCODE = 'P0400';
    END IF;

    -- Toda línea con unidad (también la de servicio) exige una unidad del
    -- sistema o de la cuenta. _uom_normalize_quantity sale temprano sin
    -- producto, antes de su propio chequeo de tenencia: este guard es propio.
    IF v_uid IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.units_of_measure u
      WHERE u.id = v_uid AND (COALESCE(u.is_system, false) OR u.account_id = p_account_id)
    ) THEN
      RAISE EXCEPTION 'Unit of measure not found: %', v_uid USING ERRCODE = 'P0404';
    END IF;

    IF v_pid IS NULL THEN
      -- Línea de servicio: la descripción es obligatoria (va a name_snapshot).
      IF v_desc IS NULL THEN
        RAISE EXCEPTION 'quote_service_line_description_required: una línea sin producto necesita una descripción'
          USING ERRCODE = 'P0400';
      END IF;
      IF char_length(v_desc) > 200 THEN
        RAISE EXCEPTION 'quote_service_line_description_too_long: la descripción admite hasta 200 caracteres'
          USING ERRCODE = 'P0400';
      END IF;
    ELSE
      SELECT p.id, p.name, p.stock_control_type INTO v_product
      FROM   public.products p
      WHERE  p.id = v_pid AND p.account_id = p_account_id AND p.deleted_at IS NULL;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_pid USING ERRCODE = 'P0404';
      END IF;
      IF v_product.stock_control_type = 'variant_only' OR EXISTS (
        SELECT 1 FROM public.products c WHERE c.parent_id = v_pid AND c.deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'product_is_parent: "%" se vende a través de sus variantes', v_product.name
          USING ERRCODE = 'P0400';
      END IF;
      -- RN-24 (a)(b)(c)(f): sólo para validar la compatibilidad; el resultado se descarta.
      PERFORM public._uom_normalize_quantity(v_pid, v_uid, v_qty);
    END IF;

    v_total := v_total + v_sub;
  END LOOP;

  RETURN round(v_total, 2);
END;
$function$;

REVOKE ALL ON FUNCTION public._quote_validate_items(uuid, jsonb) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._quote_validate_items(uuid, jsonb) IS
  'presupuestos-modulo (D2): valida el payload p_items ({product_id, unit_id, quantity, price, subtotal, '
  'description}) contra la cuenta — producto vivo, de la cuenta y no padre (P0404 product_not_found / P0400 '
  'product_is_parent), unidad del sistema o de la cuenta también en servicio (P0404), compatibilidad RN-24, '
  'descripción obligatoria sin producto — y devuelve el total del servidor round(Σ subtotal, 2). No escribe.';


-- Inserta las líneas con snapshots congelados desde el maestro FILTRADO por
-- la cuenta del presupuesto, en el MISMO INSERT … SELECT. Asume el payload ya
-- validado por _quote_validate_items.
CREATE OR REPLACE FUNCTION public._quote_insert_items(p_account_id uuid, p_quote_id uuid, p_items jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.quote_items
    (quote_id, account_id, product_id, unit_id, quantity, price, subtotal,
     name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, line_no)
  SELECT
    p_quote_id,
    p_account_id,
    NULLIF(e.item->>'product_id', '')::uuid,
    NULLIF(e.item->>'unit_id', '')::uuid,
    (e.item->>'quantity')::numeric,
    (e.item->>'price')::numeric,
    (e.item->>'subtotal')::numeric,
    CASE WHEN NULLIF(e.item->>'product_id', '') IS NULL
         THEN btrim(e.item->>'description')
         ELSE p.name END,
    p.sku,
    p.cost,      -- costo NULL = "sin costo cargado" (productos-costo-nullable), sin COALESCE
    NULL,        -- products no tiene IVA (D3 de v3-snapshot-pattern)
    e.ord::integer
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord)
  LEFT JOIN public.products p
         ON p.id = NULLIF(e.item->>'product_id', '')::uuid
        AND p.account_id = p_account_id
        AND p.deleted_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public._quote_insert_items(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._quote_insert_items(uuid, uuid, jsonb) IS
  'presupuestos-modulo (D2/D5): inserta las líneas del presupuesto con name/sku/costo congelados desde products '
  'filtrado por account_id (nunca el maestro de otra cuenta) y line_no = orden de carga. Interna.';


-- Presupuesto + líneas en orden de carga, como lo devuelven las RPCs.
CREATE OR REPLACE FUNCTION public._quote_payload(p_quote_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT to_jsonb(q)
         || jsonb_build_object(
              'is_expired', (q.status IN ('draft', 'sent') AND q.valid_until < public.reporting_local_today()),
              'items', COALESCE((
                SELECT jsonb_agg(to_jsonb(qi) ORDER BY qi.line_no NULLS LAST, qi.id)
                FROM public.quote_items qi
                WHERE qi.quote_id = q.id), '[]'::jsonb))
  FROM public.quotes q
  WHERE q.id = p_quote_id;
$function$;

REVOKE ALL ON FUNCTION public._quote_payload(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._quote_payload(uuid) IS
  'presupuestos-modulo: fila de quotes + is_expired (día ART) + items ordenados por line_no. Interna: la usan las '
  'RPCs de escritura como valor de retorno.';


-- =============================================================================
-- 5. RPCs públicas
-- =============================================================================

-- ── rpc_create_quote ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_quote(
  p_client_id   uuid,
  p_branch_id   uuid,
  p_valid_until date,
  p_notes       text,
  p_items       jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        uuid;
  v_account_id uuid;
  v_branch     RECORD;
  v_notes      text;
  v_total      numeric;
  v_quote_id   uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'quote_client_required: el presupuesto necesita un cliente' USING ERRCODE = 'P0400';
  END IF;

  -- La cuenta es la del cliente, entre las cuentas del usuario: determinista
  -- aunque el usuario pertenezca a más de una. Ajeno e inexistente son
  -- indistinguibles (mismo literal que operacion-party-guard).
  SELECT c.account_id INTO v_account_id
  FROM   public.clients c
  WHERE  c.id = p_client_id
    AND  c.account_id IN (SELECT public.current_account_ids());
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._quote_assert_can_write(v_account_id);

  IF NOT EXISTS (SELECT 1 FROM public.clients WHERE id = p_client_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  IF p_valid_until IS NOT NULL AND p_valid_until < public.reporting_local_today() THEN
    RAISE EXCEPTION 'quote_valid_until_in_past: la validez no puede ser anterior a hoy (%)', p_valid_until
      USING ERRCODE = 'P0400';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'quote_notes_too_long: las notas admiten hasta 2.000 caracteres' USING ERRCODE = 'P0400';
  END IF;

  v_total := public._quote_validate_items(v_account_id, p_items);

  -- quotes_assign_number numera, quotes_default_valid_until completa la validez
  -- (NULL -> hoy ART + default de la cuenta) y quotes_record_status_creation
  -- registra NULL -> draft con el creador.
  INSERT INTO public.quotes
    (account_id, branch_id, client_id, status, valid_until, total, notes, created_by)
  VALUES
    (v_account_id, p_branch_id, p_client_id, 'draft', p_valid_until, v_total, v_notes, v_uid)
  RETURNING id INTO v_quote_id;

  PERFORM public._quote_insert_items(v_account_id, v_quote_id, p_items);

  RETURN public._quote_payload(v_quote_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_quote(uuid, uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_quote(uuid, uuid, date, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.rpc_create_quote(uuid, uuid, date, text, jsonb) IS
  'presupuestos-modulo (D2): alta de un presupuesto en draft. Cliente obligatorio y vivo de la cuenta (P0400 / '
  'P0404 client_not_found), writer (P0401) y rol CAN_QUOTE (P0403) antes de escribir, sucursal de la cuenta y no '
  'cerrada (P0404/P0422), validez >= hoy ART (P0400; NULL -> default de la cuenta), líneas validadas por '
  '_quote_validate_items, total del servidor. Número por disparador. No toca stock, caja, banco ni cuenta '
  'corriente. Devuelve el presupuesto con sus líneas.';


-- ── rpc_update_quote ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_update_quote(
  p_quote_id          uuid,
  p_expected_revision integer,
  p_client_id         uuid,
  p_branch_id         uuid,
  p_valid_until       date,
  p_notes             text,
  p_items             jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        uuid;
  v_quote      public.quotes%ROWTYPE;
  v_branch     RECORD;
  v_notes      text;
  v_total      numeric;
  v_new_status text;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_quote
  FROM   public.quotes
  WHERE  id = p_quote_id AND account_id IN (SELECT public.current_account_ids())
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found: %', p_quote_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._quote_assert_can_write(v_quote.account_id);

  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'quote_revision_required: falta la versión del presupuesto que se editó' USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision <> v_quote.revision THEN
    RAISE EXCEPTION 'quote_changed: el presupuesto cambió mientras lo editabas (versión % -> %): revisalo',
      p_expected_revision, v_quote.revision USING ERRCODE = 'P0409';
  END IF;

  IF v_quote.status = 'accepted' THEN
    RAISE EXCEPTION 'quote_locked_converted: el presupuesto ya se convirtió en venta; los cambios se hacen sobre la venta'
      USING ERRCODE = 'P0423';
  END IF;

  IF p_valid_until IS NULL THEN
    RAISE EXCEPTION 'quote_valid_until_required: la edición exige la fecha de validez' USING ERRCODE = 'P0400';
  END IF;
  IF p_valid_until < public.reporting_local_today() THEN
    RAISE EXCEPTION 'quote_valid_until_in_past: la validez no puede ser anterior a hoy (%)', p_valid_until
      USING ERRCODE = 'P0400';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'quote_client_required: el presupuesto necesita un cliente' USING ERRCODE = 'P0400';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.clients
    WHERE id = p_client_id AND account_id = v_quote.account_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_quote.account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'quote_notes_too_long: las notas admiten hasta 2.000 caracteres' USING ERRCODE = 'P0400';
  END IF;

  v_total := public._quote_validate_items(v_quote.account_id, p_items);

  -- D5: editar un expired o rejected lo reabre a draft (historial con el editor
  -- como actor, en la misma transacción). draft y sent conservan su estado.
  v_new_status := v_quote.status;
  IF v_quote.status IN ('expired', 'rejected') THEN
    PERFORM public.record_status_transition(
      v_quote.account_id, 'quote', p_quote_id, v_quote.status, 'draft', v_uid, NULL);
    v_new_status := 'draft';
  END IF;

  -- Reemplazo atómico con snapshots RE-TOMADOS del maestro vigente (D5).
  DELETE FROM public.quote_items WHERE quote_id = p_quote_id;
  PERFORM public._quote_insert_items(v_quote.account_id, p_quote_id, p_items);

  UPDATE public.quotes
  SET    client_id   = p_client_id,
         branch_id   = p_branch_id,
         valid_until = p_valid_until,
         notes       = v_notes,
         total       = v_total,
         status      = v_new_status,
         updated_at  = now(),
         updated_by  = v_uid,
         revision    = revision + 1
  WHERE  id = p_quote_id;

  RETURN public._quote_payload(p_quote_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_update_quote(uuid, integer, uuid, uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_quote(uuid, integer, uuid, uuid, date, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.rpc_update_quote(uuid, integer, uuid, uuid, date, text, jsonb) IS
  'presupuestos-modulo (D5): reemplazo completo de un presupuesto bajo FOR UPDATE. Tenencia (P0404 '
  'quote_not_found), writer/rol (P0401/P0403), versión esperada (P0400 si falta, P0409 quote_changed si cambió), '
  'accepted inmutable (P0423 quote_locked_converted), validez obligatoria >= hoy ART (P0400), mismos guards de '
  'cliente/sucursal/líneas que el alta. Snapshots re-tomados del maestro; expired|rejected se reabren a draft con '
  'historial; revision + 1.';


-- ── rpc_transition_quote ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_transition_quote(p_quote_id uuid, p_to_status text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid    uuid;
  v_quote  public.quotes%ROWTYPE;
  v_reason text;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- accepted sólo por la conversión a venta; expired sólo por el barrido.
  IF p_to_status IS NULL OR p_to_status NOT IN ('sent', 'rejected') THEN
    RAISE EXCEPTION 'quote_transition_not_allowed: la API sólo admite sent y rejected (pedido: %)', p_to_status
      USING ERRCODE = 'P0400';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
  IF v_reason IS NOT NULL AND char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'quote_reason_too_long: el motivo admite hasta 500 caracteres' USING ERRCODE = 'P0400';
  END IF;

  SELECT * INTO v_quote
  FROM   public.quotes
  WHERE  id = p_quote_id AND account_id IN (SELECT public.current_account_ids())
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found: %', p_quote_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._quote_assert_can_write(v_quote.account_id);

  -- Reenviar un enviado: no-op idempotente (lo usa el menú de compartir).
  IF p_to_status = 'sent' AND v_quote.status = 'sent' THEN
    RETURN public._quote_payload(p_quote_id);
  END IF;

  IF v_quote.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'quote_invalid_state: un presupuesto en % no admite pasar a %', v_quote.status, p_to_status
      USING ERRCODE = 'P0409';
  END IF;

  PERFORM public.record_status_transition(
    v_quote.account_id, 'quote', p_quote_id, v_quote.status, p_to_status, v_uid, v_reason);

  UPDATE public.quotes
  SET    status  = p_to_status,
         sent_at = CASE WHEN p_to_status = 'sent' THEN COALESCE(sent_at, now()) ELSE sent_at END
  WHERE  id = p_quote_id;

  RETURN public._quote_payload(p_quote_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_transition_quote(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_transition_quote(uuid, text, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_transition_quote(uuid, text, text) IS
  'presupuestos-modulo (D2/D4): transición desde la API — sólo sent y rejected (P0400 '
  'quote_transition_not_allowed). FOR UPDATE, writer/rol (P0401/P0403), estado abierto (P0409 '
  'quote_invalid_state), record_status_transition (catálogo, rol, motivo) y UPDATE. sent sobre sent es no-op sin '
  'historial; el primer sent fija sent_at. No toca revision.';


-- ── rpc_delete_quote ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_delete_quote(p_quote_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid     uuid;
  v_quote   public.quotes%ROWTYPE;
  v_deleted integer;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Bajo lock: un borrado que leyó draft y una conversión que commitea en el
  -- medio no pueden terminar borrando un presupuesto ya accepted.
  SELECT * INTO v_quote
  FROM   public.quotes
  WHERE  id = p_quote_id AND account_id IN (SELECT public.current_account_ids())
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found: %', p_quote_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._quote_assert_can_write(v_quote.account_id);

  IF v_quote.status <> 'draft' OR v_quote.sent_at IS NOT NULL THEN
    RAISE EXCEPTION 'quote_not_deletable: sólo se elimina un borrador que nunca se envió (estado %)', v_quote.status
      USING ERRCODE = 'P0409';
  END IF;

  -- quote_items se va por CASCADE; el historial de estados es append-only y queda.
  DELETE FROM public.quotes
  WHERE  id = p_quote_id AND status = 'draft' AND sent_at IS NULL;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted <> 1 THEN
    RAISE EXCEPTION 'quote_not_deletable: el presupuesto cambió de estado' USING ERRCODE = 'P0409';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_delete_quote(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delete_quote(uuid) TO authenticated;
COMMENT ON FUNCTION public.rpc_delete_quote(uuid) IS
  'presupuestos-modulo (D2): borrado físico de un borrador NUNCA enviado (status draft y sent_at NULL), bajo FOR '
  'UPDATE y con el predicado de estado en el propio DELETE (ROW_COUNT = 1). Otro estado -> P0409 '
  'quote_not_deletable. Rol CAN_QUOTE (P0403). El historial queda.';


-- ── rpc_set_default_quote_validity ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_set_default_quote_validity(p_days integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  SELECT cai INTO v_account_id
  FROM   public.current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL OR NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- CAN_CONFIGURE: es configuración de la cuenta, como las formas de pago.
  IF NOT (public.account_user_active_roles(v_account_id, auth.uid()) && ARRAY['owner', 'admin']) THEN
    RAISE EXCEPTION 'insufficient_role: sólo el dueño o un administrador cambian la validez por defecto'
      USING ERRCODE = 'P0403';
  END IF;

  IF p_days IS NULL OR p_days < 1 OR p_days > 365 THEN
    RAISE EXCEPTION 'quote_validity_out_of_range: la validez por defecto va de 1 a 365 días (%)', p_days
      USING ERRCODE = 'P0400';
  END IF;

  UPDATE public.accounts
  SET    default_quote_validity_days = p_days
  WHERE  id = v_account_id;

  RETURN p_days;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_set_default_quote_validity(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_default_quote_validity(integer) TO authenticated;
COMMENT ON FUNCTION public.rpc_set_default_quote_validity(integer) IS
  'presupuestos-modulo (D7): fija accounts.default_quote_validity_days de la cuenta del invocante. Writer (P0401), '
  'owner/admin (P0403 insufficient_role), rango 1..365 (P0400). Devuelve el valor guardado.';


-- ── rpc_commercial_issuer ────────────────────────────────────────────────────
-- SECURITY DEFINER a propósito: la única política de lectura de profiles para
-- un no administrador es auth.uid() = id, así que leído por la conexión del
-- request el perfil del dueño vuelve vacío cuando descarga un vendedor.
CREATE OR REPLACE FUNCTION public.rpc_commercial_issuer(p_account_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF p_account_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.current_account_ids() AS cai WHERE cai = p_account_id
  ) THEN
    RAISE EXCEPTION 'account_not_found: %', p_account_id USING ERRCODE = 'P0404';
  END IF;

  SELECT jsonb_build_object(
           'nombre_fantasia',     fp.nombre_fantasia,
           'razon_social',        fp.razon_social,
           'cuit',                fp.cuit,
           'domicilio_comercial', fp.domicilio_comercial,
           'business_name',       pr.business_name,
           'phone',               pr.phone)
  INTO   v_result
  FROM   public.accounts a
  LEFT JOIN public.fiscal_profiles fp ON fp.account_id = a.id
  LEFT JOIN public.profiles pr        ON pr.id = a.owner_user_id
  WHERE  a.id = p_account_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'account_not_found: %', p_account_id USING ERRCODE = 'P0404';
  END IF;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_commercial_issuer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_commercial_issuer(uuid) TO authenticated;
COMMENT ON FUNCTION public.rpc_commercial_issuer(uuid) IS
  'commercial-document-pdf (D8): datos del emisor para el PDF comercial — sólo nombre_fantasia, razon_social, '
  'cuit, domicilio_comercial (fiscal_profiles) y business_name, phone (profiles del dueño). Miembro de la cuenta '
  'o P0404 account_not_found. SECURITY DEFINER porque la RLS de profiles sólo deja ver el perfil propio. Sin email.';


-- =============================================================================
-- 6. Políticas y privilegios de escritura directa (D2)
-- =============================================================================
DROP POLICY IF EXISTS quotes_insert      ON public.quotes;
DROP POLICY IF EXISTS quotes_update      ON public.quotes;
DROP POLICY IF EXISTS quote_items_insert ON public.quote_items;
DROP POLICY IF EXISTS quote_items_update ON public.quote_items;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.quotes      FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.quote_items FROM anon, authenticated;


-- =============================================================================
-- 7. Vencimiento automático (D7)
-- =============================================================================
CREATE OR REPLACE FUNCTION public._expire_overdue_quotes()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_row   RECORD;
  v_count integer := 0;
BEGIN
  -- SKIP LOCKED: no espera a una conversión en curso; si gana, el presupuesto
  -- queda accepted y el barrido no lo toca al día siguiente.
  FOR v_row IN
    SELECT q.id, q.account_id, q.status
    FROM   public.quotes q
    WHERE  q.status IN ('draft', 'sent')
      AND  q.valid_until < public.reporting_local_today()
    ORDER  BY q.id
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Actor de SISTEMA = uuid cero (document_status_history.performed_by es
    -- NOT NULL; un actor NULL abortaría cada corrida con 23502). La fila
    -- draft|sent -> expired no tiene allowed_role: no requiere rol.
    PERFORM public.record_status_transition(
      v_row.account_id, 'quote', v_row.id, v_row.status, 'expired',
      '00000000-0000-0000-0000-000000000000'::uuid, 'vencimiento automático');
    UPDATE public.quotes SET status = 'expired' WHERE id = v_row.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public._expire_overdue_quotes() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._expire_overdue_quotes() IS
  'presupuestos-modulo (D7): vence los presupuestos draft|sent con valid_until < día de negocio argentino, en orden '
  'de id con FOR UPDATE SKIP LOCKED, registrando la transición con el actor de sistema (uuid cero) y el motivo '
  '"vencimiento automático". Idempotente. La corre el pg_cron quotes-expire-sweep. Sin EXECUTE para roles de '
  'aplicación.';

SELECT cron.unschedule('quotes-expire-sweep')
FROM cron.job WHERE jobname = 'quotes-expire-sweep';

SELECT cron.schedule(
    'quotes-expire-sweep',
    '5 3 * * *',  -- 03:05 UTC = 00:05 ART: un presupuesto "válido hasta ayer" amanece vencido
    $$ SELECT public._expire_overdue_quotes(); $$
);


-- =============================================================================
-- 8. Backfill defensivo (D14)
-- =============================================================================
CREATE OR REPLACE FUNCTION public._quotes_backfill_number_and_validity()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_row     RECORD;
  v_count   integer := 0;
  v_updated integer;
BEGIN
  -- Número en orden de (account_id, created_at, id): un UPDATE masivo no
  -- garantiza el orden.
  FOR v_row IN
    SELECT q.id, q.account_id
    FROM   public.quotes q
    WHERE  q.number IS NULL
    ORDER  BY q.account_id, q.created_at, q.id
  LOOP
    UPDATE public.quotes
    SET    number = public._assign_internal_document_number(v_row.account_id, 'quote', NULL)
    WHERE  id = v_row.id AND number IS NULL;
    v_count := v_count + 1;
  END LOOP;

  -- created_at es un instante: el AT TIME ZONE es el correcto.
  UPDATE public.quotes q
  SET    valid_until = (q.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date
                       + COALESCE((SELECT a.default_quote_validity_days FROM public.accounts a WHERE a.id = q.account_id), 15)
  WHERE  q.valid_until IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN v_count + v_updated;
END;
$function$;

REVOKE ALL ON FUNCTION public._quotes_backfill_number_and_validity() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._quotes_backfill_number_and_validity() IS
  'presupuestos-modulo (D14): completa number (en orden de cuenta, alta e id) y valid_until (alta en ART + '
  'validez por defecto) de los presupuestos que nacieron sin disparadores. Idempotente por los WHERE … IS NULL. '
  'Devuelve la cantidad de actualizaciones.';

SELECT public._quotes_backfill_number_and_validity();


-- =============================================================================
-- 9. Introspección (corre siempre, también en prod)
-- =============================================================================
DO $$
DECLARE
  v_bad text[] := '{}';
  v_fn  text;
  v_n   integer;
BEGIN
  -- Columnas
  SELECT COUNT(*) INTO v_n FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'quotes'
    AND column_name IN ('number', 'notes', 'sent_at', 'updated_at', 'updated_by', 'revision');
  IF v_n <> 6 THEN v_bad := v_bad || format('quotes: %s/6 columnas nuevas', v_n); END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'accounts'
                   AND column_name = 'default_quote_validity_days' AND is_nullable = 'NO') THEN
    v_bad := v_bad || 'accounts.default_quote_validity_days ausente o nullable'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.quotes'::regclass
                   AND conname = 'quotes_account_number_key' AND contype = 'u') THEN
    v_bad := v_bad || 'falta UNIQUE (account_id, number) en quotes'::text;
  END IF;

  -- Disparadores
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.quotes'::regclass AND tgname = 'quotes_assign_number'
                   AND tgfoid = 'public.trg_assign_internal_document_number'::regproc
                   AND encode(tgargs, 'escape') = 'quote\000') THEN
    v_bad := v_bad || 'falta quotes_assign_number -> trg_assign_internal_document_number(''quote'')'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.quotes'::regclass AND tgname = 'quotes_default_valid_until') THEN
    v_bad := v_bad || 'falta quotes_default_valid_until'::text;
  END IF;

  -- Tabla de secuencias con RLS
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.internal_document_sequences'::regclass AND relrowsecurity) THEN
    v_bad := v_bad || 'internal_document_sequences sin RLS'::text;
  END IF;

  -- Políticas de escritura directa ausentes
  SELECT COUNT(*) INTO v_n FROM pg_policy
  WHERE polrelid IN ('public.quotes'::regclass, 'public.quote_items'::regclass)
    AND polname IN ('quotes_insert', 'quotes_update', 'quote_items_insert', 'quote_items_update');
  IF v_n <> 0 THEN v_bad := v_bad || format('%s política(s) de escritura directa siguen vivas', v_n); END IF;
  IF has_table_privilege('authenticated', 'public.quotes', 'INSERT')
     OR has_table_privilege('authenticated', 'public.quotes', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.quote_items', 'INSERT')
     OR has_table_privilege('authenticated', 'public.quote_items', 'UPDATE') THEN
    v_bad := v_bad || 'authenticated conserva INSERT/UPDATE sobre quotes/quote_items'::text;
  END IF;

  -- Catálogo
  SELECT COUNT(*) INTO v_n FROM public.document_status_transitions
  WHERE document_type = 'quote' AND from_status IN ('expired', 'rejected') AND to_status = 'draft';
  IF v_n <> 2 THEN v_bad := v_bad || format('faltan las filas de reapertura (%s/2)', v_n); END IF;
  IF EXISTS (SELECT 1 FROM public.document_status_transitions
             WHERE document_type = 'quote' AND is_terminal_to AND to_status <> 'accepted') THEN
    v_bad := v_bad || 'quote tiene un terminal distinto de accepted'::text;
  END IF;

  -- Backfill
  SELECT COUNT(*) INTO v_n FROM public.quotes WHERE number IS NULL OR valid_until IS NULL;
  IF v_n <> 0 THEN v_bad := v_bad || format('%s presupuesto(s) sin número o sin validez', v_n); END IF;

  -- Una sola definición de cada función nueva
  FOREACH v_fn IN ARRAY ARRAY['_next_internal_document_number', '_assign_internal_document_number',
                              'trg_assign_internal_document_number', 'trg_quote_default_valid_until',
                              '_quote_assert_can_write', '_quote_validate_items', '_quote_insert_items',
                              '_quote_payload', 'rpc_create_quote', 'rpc_update_quote', 'rpc_transition_quote',
                              'rpc_delete_quote', 'rpc_set_default_quote_validity', 'rpc_commercial_issuer',
                              '_expire_overdue_quotes', '_quotes_backfill_number_and_validity'] LOOP
    SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_n <> 1 THEN v_bad := v_bad || format('%s tiene %s definiciones', v_fn, v_n); END IF;
  END LOOP;

  -- ACLs: RPCs sin anon y con authenticated; internas sin roles de aplicación.
  FOREACH v_fn IN ARRAY ARRAY['public.rpc_create_quote(uuid, uuid, date, text, jsonb)',
                              'public.rpc_update_quote(uuid, integer, uuid, uuid, date, text, jsonb)',
                              'public.rpc_transition_quote(uuid, text, text)',
                              'public.rpc_delete_quote(uuid)',
                              'public.rpc_set_default_quote_validity(integer)',
                              'public.rpc_commercial_issuer(uuid)'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE') OR NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('ACL de %s', v_fn);
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY ARRAY['public._next_internal_document_number(uuid, text)',
                              'public._assign_internal_document_number(uuid, text, bigint)',
                              'public.trg_assign_internal_document_number()',
                              'public.trg_quote_default_valid_until()',
                              'public._quote_assert_can_write(uuid)',
                              'public._quote_validate_items(uuid, jsonb)',
                              'public._quote_insert_items(uuid, uuid, jsonb)',
                              'public._quote_payload(uuid)',
                              'public._expire_overdue_quotes()',
                              'public._quotes_backfill_number_and_validity()'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE') OR has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por un rol de aplicación', v_fn);
    END IF;
  END LOOP;

  -- Cron
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'quotes-expire-sweep' AND schedule = '5 3 * * *') THEN
    v_bad := v_bad || 'falta el job quotes-expire-sweep'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'presupuestos-modulo (introspección) FAILED:\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'presupuestos-modulo (introspección): OK — columnas, UNIQUE, 2 disparadores, secuencias con RLS, 0 políticas de escritura directa, reapertura catalogada con accepted único terminal, 0 presupuestos sin número/validez, ACLs y quotes-expire-sweep.';
END $$;
