-- =============================================================================
-- 20261069000001_remitos_venta.sql
-- remitos-venta, TANDA A (governance MEDIA con tramo ALTO: escribe el ledger
-- de stock). Sign-off del PO 2026-09-29: «no necesito el remito legal. Andá con
-- todo lo recomendado» y «quiero que tanto el remito como los presupuestos se
-- puedan modificar» (R1-R8); OQ-RV1..RV13 por su recomendación. Ver
-- openspec/changes/remitos-venta/design.md (D1-D16).
--
-- Qué hace (sin dinero: la conversión a venta es la tanda B):
--   1. Modelo (D1): delivery_notes (un sentido por fila, 'sale'|'purchase';
--      cliente y sucursal obligatorios en venta) y delivery_note_items (sólo
--      líneas con producto, quantity_base NOT NULL = lo que la línea retiene
--      del stock). RLS sólo de SELECT por cuenta; sin escritura directa.
--   2. CHECK ampliados de forma aditiva: internal_document_sequences
--      (delivery_note_sale), document_status_history/transitions
--      (delivery_note_sale), stock_movements.reference_type (delivery_note,
--      delivery_note_update, delivery_note_reversal) y
--      operation_idempotency.operation_kind (delivery_note_sale).
--   3. FSM y numeración (D2, D3): filas NULL -> issued y issued -> canceled
--      del catálogo; disparadores de número (genérico, 'delivery_note_sale'),
--      creación y enforcement, los tres con WHEN (direction = 'sale').
--   4. Reutilización (D12): _assert_document_product extraído;
--      _quote_validate_items reescrita desde su cuerpo vivo para llamarlo.
--   5. Helpers internos _delivery_note_* (D4-D6) y RPCs SECURITY DEFINER
--      rpc_create_sale_delivery_note (idempotente, molde DEC-06 del núcleo),
--      rpc_update_delivery_note (par espejo sólo en los pares que cambian),
--      rpc_cancel_delivery_note (motivo, repone lo retenido) y
--      rpc_get_delivery_note. Lo retenido sale SIEMPRE de
--      delivery_note_items.quantity_base, nunca de sumar stock_movements
--      (que la API de datos puede insertar).
--   6. Guards desde el cuerpo vivo: fn_product_base_unit_guard y
--      fn_uom_in_use_guard suman delivery_note_items (D14);
--      _branch_assert_empty suma la cuarta condición
--      branch_has_pending_delivery_notes vía _branch_pending_delivery_notes
--      (D10). _branch_blocking_content y fn_guard_branch_decommission no se
--      tocan.
--   7. Bloque DO de introspección al final.
--
-- Idempotente (auto-apply de Supabase GitHub y cadena de reaplicación de
-- KPI_Validation.yml): CREATE TABLE/INDEX IF NOT EXISTS, DROP CONSTRAINT IF
-- EXISTS + ADD con la lista completa, CREATE OR REPLACE con firmas nuevas o
-- idénticas (sin overload, sin 42725), DROP POLICY/TRIGGER IF EXISTS + CREATE,
-- catálogo con ON CONFLICT DO NOTHING, REVOKE/GRANT re-ejecutables.
--
-- Gates: supabase/tests/test_remitos_venta.sql (EJECUTA las 4 RPCs, los guards
-- y la regresión de presupuestos), supabase/tests/test_remitos_venta_race.sh y
-- supabase/tests/test_internal_document_numbering_race.sh (DOC_TYPE=
-- delivery_note_sale).
-- =============================================================================


-- =============================================================================
-- 1. Modelo (D1)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.delivery_notes (
  id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id         uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  direction          text          NOT NULL,
  branch_id          uuid          NOT NULL REFERENCES public.branches(id),
  client_id          uuid          REFERENCES public.clients(id),
  supplier_id        uuid          REFERENCES public.suppliers(id),
  supplier_reference text,
  number             bigint,
  status             text          NOT NULL,
  issued_on          date          NOT NULL,
  delivery_address   text,
  notes              text,
  total              numeric(15,2) NOT NULL DEFAULT 0,
  revision           integer       NOT NULL DEFAULT 1,
  created_by         uuid,
  created_at         timestamptz   NOT NULL DEFAULT now(),
  updated_by         uuid,
  updated_at         timestamptz,
  CONSTRAINT delivery_notes_direction_check CHECK (direction IN ('sale', 'purchase')),
  CONSTRAINT delivery_notes_status_check CHECK (status IN ('issued', 'converted', 'canceled')),
  CONSTRAINT delivery_notes_counterparty_check CHECK (
    (direction = 'sale' AND client_id IS NOT NULL AND supplier_id IS NULL)
    OR (direction = 'purchase' AND supplier_id IS NOT NULL AND client_id IS NULL)),
  CONSTRAINT delivery_notes_supplier_reference_length_check CHECK (supplier_reference IS NULL OR char_length(supplier_reference) <= 100),
  CONSTRAINT delivery_notes_supplier_reference_direction_check CHECK (direction = 'purchase' OR supplier_reference IS NULL),
  CONSTRAINT delivery_notes_delivery_address_length_check CHECK (delivery_address IS NULL OR char_length(delivery_address) <= 500),
  CONSTRAINT delivery_notes_notes_length_check CHECK (notes IS NULL OR char_length(notes) <= 2000),
  CONSTRAINT delivery_notes_revision_check CHECK (revision >= 1),
  CONSTRAINT delivery_notes_account_direction_number_key UNIQUE (account_id, direction, number)
);

CREATE TABLE IF NOT EXISTS public.delivery_note_items (
  id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_note_id   uuid          NOT NULL REFERENCES public.delivery_notes(id) ON DELETE CASCADE,
  account_id         uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  line_no            integer       NOT NULL,
  product_id         uuid          NOT NULL REFERENCES public.products(id),
  unit_id            uuid          REFERENCES public.units_of_measure(id),
  quantity           numeric(15,4) NOT NULL,
  price              numeric       NOT NULL,
  subtotal           numeric(15,2) NOT NULL,
  name_snapshot      text,
  sku_snapshot       text,
  unit_cost_snapshot numeric(15,2),
  iva_rate_snapshot  numeric(5,2),
  quantity_base      numeric(15,4) NOT NULL,
  created_at         timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT delivery_note_items_quantity_check CHECK (quantity > 0),
  CONSTRAINT delivery_note_items_price_check CHECK (price >= 0),
  CONSTRAINT delivery_note_items_subtotal_check CHECK (subtotal >= 0),
  CONSTRAINT delivery_note_items_quantity_base_check CHECK (quantity_base > 0)
);

CREATE INDEX IF NOT EXISTS delivery_notes_account_list_idx
  ON public.delivery_notes (account_id, direction, status, issued_on DESC);
CREATE INDEX IF NOT EXISTS delivery_notes_client_issued_idx
  ON public.delivery_notes (client_id) WHERE status = 'issued';
CREATE INDEX IF NOT EXISTS delivery_notes_branch_issued_idx
  ON public.delivery_notes (branch_id) WHERE status = 'issued';
CREATE INDEX IF NOT EXISTS delivery_notes_supplier_issued_idx
  ON public.delivery_notes (supplier_id) WHERE status = 'issued';
CREATE INDEX IF NOT EXISTS delivery_note_items_note_idx
  ON public.delivery_note_items (delivery_note_id, line_no);
CREATE INDEX IF NOT EXISTS delivery_note_items_product_idx
  ON public.delivery_note_items (product_id);
CREATE INDEX IF NOT EXISTS delivery_note_items_unit_idx
  ON public.delivery_note_items (unit_id) WHERE unit_id IS NOT NULL;

ALTER TABLE public.delivery_notes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_note_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS delivery_notes_select ON public.delivery_notes;
CREATE POLICY delivery_notes_select
  ON public.delivery_notes
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

DROP POLICY IF EXISTS delivery_note_items_select ON public.delivery_note_items;
CREATE POLICY delivery_note_items_select
  ON public.delivery_note_items
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

REVOKE ALL ON TABLE public.delivery_notes      FROM anon;
REVOKE ALL ON TABLE public.delivery_note_items FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.delivery_notes      FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.delivery_note_items FROM authenticated;
GRANT SELECT ON TABLE public.delivery_notes      TO authenticated;
GRANT SELECT ON TABLE public.delivery_note_items TO authenticated;

COMMENT ON TABLE public.delivery_notes IS
  'remitos-venta (D1): remito interno ("X", no fiscal). direction = sale (este change) | purchase '
  '(remitos-compra). Emitir descuenta stock de branch_id; editar ajusta por par producto-sucursal; anular '
  'repone. Sin políticas de escritura: sólo lo escriben las RPCs rpc_*_delivery_note. El motivo y el actor de '
  'la anulación viven en document_status_history (RN-A5).';
COMMENT ON COLUMN public.delivery_notes.number IS
  'remitos-venta (D2): número interno por cuenta y por sentido (internal_document_sequences, tipo '
  'delivery_note_sale). Se muestra como R-00000012 en venta; el prefijo se formatea desde direction.';
COMMENT ON COLUMN public.delivery_notes.issued_on IS
  'remitos-venta (D1, OQ-RV9): día ART de la emisión (reporting_local_today()), no editable. Fecha de negocio.';
COMMENT ON COLUMN public.delivery_notes.revision IS
  'remitos-venta (D5): versión del contenido; cada edición la incrementa y la edición/anulación exigen la vista.';
COMMENT ON COLUMN public.delivery_notes.supplier_reference IS
  'remitos-venta (D1): número del remito del proveedor; sólo para direction = purchase (remitos-compra).';
COMMENT ON TABLE public.delivery_note_items IS
  'remitos-venta (D1): líneas del remito, siempre con producto (OQ-RV11). Snapshots congelados por cuenta; '
  'quantity_base es la cantidad normalizada a la unidad base que la línea retiene del stock.';
COMMENT ON COLUMN public.delivery_note_items.quantity_base IS
  'remitos-venta (D4): cantidad normalizada con _uom_normalize_quantity después del lock del producto. Es la '
  'ÚNICA fuente de lo que el remito retiene: la edición y la anulación revierten Σ quantity_base, nunca un '
  'cálculo sobre stock_movements.';


-- =============================================================================
-- 2. CHECK ampliados (aditivos, desde los vivos)
-- =============================================================================
ALTER TABLE public.internal_document_sequences
  DROP CONSTRAINT IF EXISTS internal_document_sequences_document_type_check;
ALTER TABLE public.internal_document_sequences
  ADD CONSTRAINT internal_document_sequences_document_type_check
  CHECK (document_type IN ('quote', 'delivery_note_sale'));

ALTER TABLE public.document_status_history
  DROP CONSTRAINT IF EXISTS document_status_history_document_type_check;
ALTER TABLE public.document_status_history
  ADD CONSTRAINT document_status_history_document_type_check
  CHECK (document_type IN ('quote', 'sales_order', 'fiscal_document', 'cash_session',
                           'reconciliation_session', 'stock_transfer', 'delivery_note_sale'));

ALTER TABLE public.document_status_transitions
  DROP CONSTRAINT IF EXISTS document_status_transitions_document_type_check;
ALTER TABLE public.document_status_transitions
  ADD CONSTRAINT document_status_transitions_document_type_check
  CHECK (document_type IN ('quote', 'sales_order', 'fiscal_document', 'cash_session',
                           'reconciliation_session', 'stock_transfer', 'delivery_note_sale'));

ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_reference_type_check;
ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_reference_type_check
  CHECK (reference_type = ANY (ARRAY['sale', 'purchase', 'adjustment', 'initial', 'sale_update',
                                     'purchase_update', 'transfer', 'sale_reversal', 'purchase_reversal',
                                     'delivery_note', 'delivery_note_update', 'delivery_note_reversal']::text[]));

ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;
ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale', 'purchase', 'payment_received', 'payment_made', 'supplier_charge',
    'bank_movement', 'event_consumer', 'bank_statement_import',
    'cash_session_close', 'subscription_webhook', 'credit_note',
    'expense_import', 'product_import', 'delivery_note_sale'
  ]::text[]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'remitos-venta (D4): suma delivery_note_sale (emisión idempotente del remito) al vocabulario cerrado de operation_kind.';


-- =============================================================================
-- 3. FSM y numeración (D2, D3)
-- =============================================================================
-- Sólo las filas de la tanda A (regla del seed: ninguna transición sin productor).
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_sale', NULL, 'issued', false, false, ARRAY['seller', 'stock', 'admin', 'owner'])
ON CONFLICT (document_type, to_status) WHERE from_status IS NULL DO NOTHING;

INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_sale', 'issued', 'canceled', true, true, ARRAY['admin', 'owner'])
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;

-- Número: la función genérica de presupuestos-modulo, sin cambios. El WHEN
-- resuelve que una tabla lleve dos sentidos con secuencias distintas.
DROP TRIGGER IF EXISTS delivery_notes_assign_number_sale ON public.delivery_notes;
CREATE TRIGGER delivery_notes_assign_number_sale
  BEFORE INSERT ON public.delivery_notes
  FOR EACH ROW WHEN (NEW.direction = 'sale')
  EXECUTE FUNCTION public.trg_assign_internal_document_number('delivery_note_sale');

-- Creación: molde de trg_quote_record_creation, con el tipo por TG_ARGV[0]
-- para que remitos-compra enganche su gemelo sin otra función.
CREATE OR REPLACE FUNCTION public.trg_delivery_note_record_creation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid;
BEGIN
  v_actor := COALESCE(NEW.created_by, auth.uid());
  IF v_actor IS NULL THEN
    RETURN NEW;  -- contexto administrativo sin actor: no registrar, no romper
  END IF;

  PERFORM public.record_status_transition(
    NEW.account_id, TG_ARGV[0], NEW.id, NULL, NEW.status, v_actor, NULL);
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.trg_delivery_note_record_creation() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.trg_delivery_note_record_creation() IS
  'remitos-venta (D3): AFTER INSERT de delivery_notes — registra NULL -> status con el tipo de documento de '
  'TG_ARGV[0] (delivery_note_sale), validando el rol del creador contra el catálogo (record_status_transition).';

DROP TRIGGER IF EXISTS delivery_notes_record_status_creation_sale ON public.delivery_notes;
CREATE TRIGGER delivery_notes_record_status_creation_sale
  AFTER INSERT ON public.delivery_notes
  FOR EACH ROW WHEN (NEW.direction = 'sale')
  EXECUTE FUNCTION public.trg_delivery_note_record_creation('delivery_note_sale');

DROP TRIGGER IF EXISTS delivery_notes_enforce_status_transition_sale ON public.delivery_notes;
CREATE TRIGGER delivery_notes_enforce_status_transition_sale
  BEFORE UPDATE ON public.delivery_notes
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status AND OLD.direction = 'sale' AND NEW.direction = 'sale')
  EXECUTE FUNCTION public.trg_enforce_status_transition('delivery_note_sale');


-- =============================================================================
-- 4. Reutilización en SQL (D12): guard de producto compartido
-- =============================================================================
CREATE OR REPLACE FUNCTION public._assert_document_product(p_account_id uuid, p_product_id uuid)
RETURNS public.products
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_product public.products;
BEGIN
  SELECT p.* INTO v_product
  FROM   public.products p
  WHERE  p.id = p_product_id AND p.account_id = p_account_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;
  IF v_product.stock_control_type = 'variant_only' OR EXISTS (
    SELECT 1 FROM public.products c WHERE c.parent_id = p_product_id AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'product_is_parent: "%" se vende a través de sus variantes', v_product.name
      USING ERRCODE = 'P0400';
  END IF;
  RETURN v_product;
END;
$function$;

REVOKE ALL ON FUNCTION public._assert_document_product(uuid, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._assert_document_product(uuid, uuid) IS
  'remitos-venta (D12): única definición de "producto vivo, de la cuenta y no padre con variantes ni '
  'variant_only" para las líneas de documentos (presupuesto, remito). P0404 product_not_found / P0400 '
  'product_is_parent. Devuelve la fila. Interna.';

-- _quote_validate_items desde su cuerpo VIVO (md5 sin \r verificado en el
-- checkpoint 0.3, igual a 20261067000001:372-460): el único cambio es que el
-- guard de producto embebido pasa a ser la llamada a _assert_document_product.
-- CREATE OR REPLACE con la misma firma conserva COMMENT y ACL.
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
      -- remitos-venta (D12): producto vivo, de la cuenta y no padre — definición única.
      v_product := public._assert_document_product(p_account_id, v_pid);
      -- RN-24 (a)(b)(c)(f): sólo para validar la compatibilidad; el resultado se descarta.
      PERFORM public._uom_normalize_quantity(v_pid, v_uid, v_qty);
    END IF;

    v_total := v_total + v_sub;
  END LOOP;

  RETURN round(v_total, 2);
END;
$function$;


-- =============================================================================
-- 5. Helpers internos del remito (D4-D6)
-- =============================================================================

-- Rol por operación, leído del catálogo de transiciones: una sola fuente de
-- los roles (la misma que record_status_transition). P0401 si no es writer.
CREATE OR REPLACE FUNCTION public._delivery_note_assert_role(p_account_id uuid, p_mode text)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_from  text;
  v_to    text;
  v_roles text[];
  v_label text;
BEGIN
  CASE p_mode
    WHEN 'issue'   THEN v_from := NULL;     v_to := 'issued';    v_label := 'emitir o editar remitos (requiere vendedor, stock, administrador o dueño)';
    WHEN 'void'    THEN v_from := 'issued'; v_to := 'canceled';  v_label := 'anular remitos (requiere administrador o dueño)';
    WHEN 'convert' THEN v_from := 'issued'; v_to := 'converted'; v_label := 'convertir remitos en venta (requiere vendedor, cajero, administrador o dueño)';
    ELSE
      RAISE EXCEPTION 'delivery_note_role_mode_invalid: %', p_mode USING ERRCODE = 'P0400';
  END CASE;

  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  SELECT t.allowed_role INTO v_roles
  FROM   public.document_status_transitions t
  WHERE  t.document_type = 'delivery_note_sale'
    AND  t.from_status IS NOT DISTINCT FROM v_from
    AND  t.to_status = v_to;
  IF v_roles IS NULL THEN
    RAISE EXCEPTION 'delivery_note_role_mode_unavailable: la operación % no está catalogada', p_mode
      USING ERRCODE = 'P0409';
  END IF;

  IF NOT (public.account_user_active_roles(p_account_id, auth.uid()) && v_roles) THEN
    RAISE EXCEPTION 'insufficient_role: tu rol no permite %', v_label USING ERRCODE = 'P0403';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_assert_role(uuid, text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_assert_role(uuid, text) IS
  'remitos-venta (D3/D4/D13): is_account_writer (P0401) y roles activos del usuario ∩ allowed_role de la '
  'transición del catálogo delivery_note_sale que corresponde al modo (issue: NULL->issued, void: '
  'issued->canceled, convert: issued->converted) — P0403 insufficient_role. Se evalúa ANTES de escribir. Interna.';


-- Único helper de lock de productos del remito: orden ascendente de id,
-- filtrado por cuenta. Va ANTES de validar (TOCTOU de units-of-measure).
CREATE OR REPLACE FUNCTION public._delivery_note_lock_products(p_account_id uuid, p_product_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM 1
  FROM   public.products p
  WHERE  p.id = ANY (COALESCE(p_product_ids, ARRAY[]::uuid[]))
    AND  p.account_id = p_account_id
  ORDER BY p.id
  FOR UPDATE;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_lock_products(uuid, uuid[]) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_lock_products(uuid, uuid[]) IS
  'remitos-venta (D4/D5): FOR UPDATE de los productos de la cuenta en orden ascendente de id. Lo usan la '
  'emisión, la edición y la anulación antes de validar o de leer branch_stock. Un id ajeno o inexistente no '
  'se bloquea (la validación lo rechaza). Interna.';


-- Valida el payload sobre filas YA bloqueadas y normaliza cada línea.
-- p_held: lo retenido por las líneas vigentes (edición) o NULL (emisión).
-- Devuelve {total, lines: [{line_no, product_id, unit_id, quantity, price,
-- subtotal, quantity_base}], required: [{product_id, branch_id, quantity}]}.
CREATE OR REPLACE FUNCTION public._delivery_note_validate_items(p_account_id uuid, p_branch_id uuid,
                                                               p_items jsonb, p_held jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_item     jsonb;
  v_ord      bigint;
  v_pid      uuid;
  v_uid      uuid;
  v_qty      numeric;
  v_price    numeric;
  v_sub      numeric;
  v_base     numeric;
  v_alive    boolean;
  v_held_ids uuid[];
  v_total    numeric := 0;
  v_lines    jsonb := '[]'::jsonb;
  v_required jsonb;
  v_dead     RECORD;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'delivery_note_items_required: el remito necesita al menos una línea' USING ERRCODE = 'P0400';
  END IF;
  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'delivery_note_too_many_items: máximo 500 líneas por remito' USING ERRCODE = 'P0400';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT (e->>'product_id')::uuid), ARRAY[]::uuid[]) INTO v_held_ids
  FROM   jsonb_array_elements(COALESCE(p_held, '[]'::jsonb)) AS e;

  FOR v_item, v_ord IN SELECT e, o FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o) LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION 'delivery_note_line_invalid: cada línea debe ser un objeto' USING ERRCODE = 'P0400';
    END IF;

    v_pid   := NULLIF(v_item->>'product_id', '')::uuid;
    v_uid   := NULLIF(v_item->>'unit_id', '')::uuid;
    v_qty   := (v_item->>'quantity')::numeric;
    v_price := (v_item->>'price')::numeric;
    v_sub   := (v_item->>'subtotal')::numeric;

    IF v_pid IS NULL THEN
      RAISE EXCEPTION 'delivery_note_product_required: cada línea del remito necesita un producto (línea %)', v_ord
        USING ERRCODE = 'P0400';
    END IF;
    IF v_qty IS NULL OR round(v_qty, 4) <= 0 THEN
      RAISE EXCEPTION 'delivery_note_line_invalid_quantity: la cantidad debe ser mayor que 0 (línea %)', v_ord
        USING ERRCODE = 'P0400';
    END IF;
    IF v_price IS NULL OR v_price < 0 THEN
      RAISE EXCEPTION 'delivery_note_line_invalid_price: el precio no puede ser negativo (línea %)', v_ord
        USING ERRCODE = 'P0400';
    END IF;
    IF v_sub IS NULL OR v_sub < 0 THEN
      RAISE EXCEPTION 'delivery_note_line_invalid_subtotal: el subtotal no puede ser negativo (línea %)', v_ord
        USING ERRCODE = 'P0400';
    END IF;
    IF v_uid IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.units_of_measure u
      WHERE u.id = v_uid AND (COALESCE(u.is_system, false) OR u.account_id = p_account_id)
    ) THEN
      RAISE EXCEPTION 'Unit of measure not found: %', v_uid USING ERRCODE = 'P0404';
    END IF;

    -- Producto ya presente en el remito y hoy dado de baja (D5, OQ-RV3): se
    -- acepta sin revalidar el catálogo vivo (sigue siendo de la cuenta); el
    -- tope contra lo retenido se controla después del loop, sobre el total.
    SELECT p.deleted_at IS NULL INTO v_alive
    FROM   public.products p
    WHERE  p.id = v_pid AND p.account_id = p_account_id;
    IF v_alive IS NULL OR v_alive OR NOT (v_pid = ANY (v_held_ids)) THEN
      PERFORM public._assert_document_product(p_account_id, v_pid);
    END IF;

    -- RN-24 con el lock del producto ya tomado (la emisión/edición lo toman antes).
    v_base := public._uom_normalize_quantity(v_pid, v_uid, v_qty);

    v_lines := v_lines || jsonb_build_object(
      'line_no', v_ord, 'product_id', v_pid, 'unit_id', v_uid, 'quantity', v_qty,
      'price', v_price, 'subtotal', v_sub, 'quantity_base', v_base);
    v_total := v_total + v_sub;
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', l.pid, 'branch_id', p_branch_id, 'quantity', l.qty)
                            ORDER BY l.pid), '[]'::jsonb)
  INTO   v_required
  FROM  (SELECT (e->>'product_id')::uuid AS pid, sum((e->>'quantity_base')::numeric) AS qty
         FROM   jsonb_array_elements(v_lines) AS e GROUP BY 1) l;

  -- Producto dado de baja: lo requerido en total no supera lo retenido en total
  -- (por producto, sumando sus pares, sea cual sea la sucursal).
  FOR v_dead IN
    SELECT r.pid, r.qty AS required,
           COALESCE((SELECT sum((h->>'quantity')::numeric) FROM jsonb_array_elements(COALESCE(p_held, '[]'::jsonb)) h
                     WHERE (h->>'product_id')::uuid = r.pid), 0) AS held
    FROM  (SELECT (e->>'product_id')::uuid AS pid, (e->>'quantity')::numeric AS qty
           FROM jsonb_array_elements(v_required) e) r
    JOIN   public.products p ON p.id = r.pid AND p.account_id = p_account_id AND p.deleted_at IS NOT NULL
  LOOP
    IF v_dead.required > v_dead.held THEN
      RAISE EXCEPTION 'delivery_note_product_unavailable: el producto % fue dado de baja: se puede conservar o reducir lo entregado (%), no aumentarlo (%)',
        v_dead.pid, v_dead.held, v_dead.required
        USING ERRCODE = 'P0400';
    END IF;
  END LOOP;

  RETURN jsonb_build_object('total', round(v_total, 2), 'lines', v_lines, 'required', v_required);
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_validate_items(uuid, uuid, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_validate_items(uuid, uuid, jsonb, jsonb) IS
  'remitos-venta (D4/D5): valida p_items ({product_id, unit_id, quantity, price, subtotal}) sobre productos ya '
  'bloqueados — producto obligatorio (P0400 delivery_note_product_required), vivo/de la cuenta/no padre por '
  '_assert_document_product, unidad del sistema o de la cuenta, topes — y normaliza cada línea con '
  '_uom_normalize_quantity. En la edición (p_held), un producto ya presente y dado de baja se acepta sin '
  'revalidar si su cantidad base requerida total no supera la retenida total (P0400 '
  'delivery_note_product_unavailable). Devuelve total del servidor, líneas con quantity_base y pares '
  'requeridos en p_branch_id. No escribe.';


-- Inserta las líneas con snapshots. p_carry: {product_id: {name_snapshot,
-- sku_snapshot, unit_cost_snapshot, iva_rate_snapshot}} de las líneas viejas
-- (edición, política canónica de operaciones); sin entrada -> maestro vigente
-- filtrado por cuenta, en el MISMO INSERT … SELECT.
CREATE OR REPLACE FUNCTION public._delivery_note_insert_items(p_account_id uuid, p_dn_id uuid,
                                                             p_lines jsonb, p_carry jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.delivery_note_items
    (delivery_note_id, account_id, line_no, product_id, unit_id, quantity, price, subtotal,
     name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, quantity_base)
  SELECT
    p_dn_id,
    p_account_id,
    (e->>'line_no')::integer,
    (e->>'product_id')::uuid,
    NULLIF(e->>'unit_id', '')::uuid,
    (e->>'quantity')::numeric,
    (e->>'price')::numeric,
    (e->>'subtotal')::numeric,
    CASE WHEN c.snap IS NOT NULL THEN c.snap->>'name_snapshot' ELSE p.name END,
    CASE WHEN c.snap IS NOT NULL THEN c.snap->>'sku_snapshot' ELSE p.sku END,
    CASE WHEN c.snap IS NOT NULL THEN (c.snap->>'unit_cost_snapshot')::numeric ELSE p.cost END,  -- NULL = sin costo
    CASE WHEN c.snap IS NOT NULL THEN (c.snap->>'iva_rate_snapshot')::numeric ELSE NULL END,      -- products no tiene IVA
    (e->>'quantity_base')::numeric
  FROM jsonb_array_elements(p_lines) AS e
  LEFT JOIN LATERAL (SELECT COALESCE(p_carry, '{}'::jsonb) -> (e->>'product_id') AS snap) c ON true
  LEFT JOIN public.products p
         ON p.id = (e->>'product_id')::uuid
        AND p.account_id = p_account_id
        AND p.deleted_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_insert_items(uuid, uuid, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_insert_items(uuid, uuid, jsonb, jsonb) IS
  'remitos-venta (D4/D6): inserta las líneas ya validadas con quantity_base y snapshots: los del producto que '
  'ya estaba en el remito se acarrean (nombre, SKU, costo, IVA), los de uno nuevo se congelan desde products '
  'filtrado por la cuenta. Interna.';


-- ÚNICA definición de lo retenido: Σ quantity_base de las líneas vigentes, por
-- producto, en la sucursal vigente del remito. Nunca suma stock_movements.
CREATE OR REPLACE FUNCTION public._delivery_note_held_pairs(p_dn_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id',   x.product_id,
           'branch_id',    x.branch_id,
           'quantity',     x.quantity,
           'unit_cost',    x.unit_cost,
           'product_name', x.product_name,
           'item_ids',     x.item_ids) ORDER BY x.product_id), '[]'::jsonb)
  FROM (
    SELECT i.product_id,
           dn.branch_id,
           sum(i.quantity_base)                                       AS quantity,
           (array_agg(i.unit_cost_snapshot ORDER BY i.line_no, i.id))[1] AS unit_cost,
           (array_agg(i.name_snapshot ORDER BY i.line_no, i.id))[1]      AS product_name,
           to_jsonb(array_agg(i.id ORDER BY i.line_no, i.id))            AS item_ids
    FROM   public.delivery_note_items i
    JOIN   public.delivery_notes dn ON dn.id = i.delivery_note_id
    WHERE  i.delivery_note_id = p_dn_id
    GROUP BY i.product_id, dn.branch_id
  ) x;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_held_pairs(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_held_pairs(uuid) IS
  'remitos-venta (D4): ÚNICA definición de lo que un remito retiene — por producto, en su sucursal vigente, '
  'Σ delivery_note_items.quantity_base de sus líneas vigentes (con el costo y el nombre congelados y los ids '
  'de línea). NUNCA suma stock_movements: el ledger es escribible por la API de datos y una fila forjada no '
  'debe convertirse en stock. Interna.';


-- Pata de aplicación: gate por par + delta negativo + movimiento
-- sale/delivery_note, SÓLO sobre los pares recibidos (no lee las líneas).
-- pairs: [{product_id, branch_id, quantity, unit_cost, product_name, item_ids}]
CREATE OR REPLACE FUNCTION public._delivery_note_apply_stock(p_account_id uuid, p_dn_id uuid,
                                                            p_op_group uuid, p_pairs jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_pair   jsonb;
  v_pid    uuid;
  v_bid    uuid;
  v_qty    numeric;
  v_before numeric;
  v_uid    uuid := auth.uid();
BEGIN
  FOR v_pair IN SELECT e FROM jsonb_array_elements(COALESCE(p_pairs, '[]'::jsonb)) AS e LOOP
    v_pid := (v_pair->>'product_id')::uuid;
    v_bid := (v_pair->>'branch_id')::uuid;
    v_qty := (v_pair->>'quantity')::numeric;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(bs.quantity, 0) INTO v_before
    FROM   public.branch_stock bs
    WHERE  bs.product_id = v_pid AND bs.branch_id = v_bid
    FOR UPDATE;
    v_before := COALESCE(v_before, 0);

    -- Mismo literal que el núcleo de la venta (la UI ya lo traduce).
    IF v_before < v_qty THEN
      RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
        v_pid, v_before, v_qty
        USING ERRCODE = 'P0409';
    END IF;

    PERFORM public.c21_apply_branch_stock_delta(p_account_id, v_pid, v_bid, -v_qty);

    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reference_id, reference_type, performed_by,
      operation_group_id, branch_id, unit_cost_snapshot, metadata
    ) VALUES (
      v_uid, p_account_id, v_pid, v_pair->>'product_name', 'sale',
      -v_qty, v_before, v_before - v_qty,
      p_dn_id, 'delivery_note', v_uid,
      p_op_group, v_bid, (v_pair->>'unit_cost')::numeric,
      jsonb_build_object('delivery_note_item_ids', COALESCE(v_pair->'item_ids', '[]'::jsonb))
    );
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb) IS
  'remitos-venta (D4/D5): ÚNICO lugar donde el remito descuenta stock. Por cada par recibido (la emisión pasa '
  'todos; la edición, sólo los que cambian): gate branch_stock >= requerido (P0409 stock_insuficiente, mismo '
  'literal que el núcleo de la venta), c21_apply_branch_stock_delta(-requerido) y movimiento type = sale, '
  'reference_type = delivery_note con quantity_before/after, costo congelado y metadata.delivery_note_item_ids. '
  'No lee las líneas ni el ledger. Interna.';


-- Pata de reversa: delta positivo + movimiento sale_return SÓLO sobre los
-- pares recibidos (la anulación pasa todos; la edición, sólo los que cambian).
CREATE OR REPLACE FUNCTION public._delivery_note_reverse_held(p_account_id uuid, p_dn_id uuid,
                                                             p_op_group uuid, p_pairs jsonb,
                                                             p_reference_type text, p_reverses text)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_pair   jsonb;
  v_pid    uuid;
  v_bid    uuid;
  v_qty    numeric;
  v_before numeric;
  v_uid    uuid := auth.uid();
BEGIN
  IF p_reference_type NOT IN ('delivery_note_update', 'delivery_note_reversal') THEN
    RAISE EXCEPTION 'delivery_note_reverse_invalid_reference: %', p_reference_type USING ERRCODE = 'P0400';
  END IF;

  FOR v_pair IN SELECT e FROM jsonb_array_elements(COALESCE(p_pairs, '[]'::jsonb)) AS e LOOP
    v_pid := (v_pair->>'product_id')::uuid;
    v_bid := (v_pair->>'branch_id')::uuid;
    v_qty := (v_pair->>'quantity')::numeric;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(bs.quantity, 0) INTO v_before
    FROM   public.branch_stock bs
    WHERE  bs.product_id = v_pid AND bs.branch_id = v_bid
    FOR UPDATE;
    v_before := COALESCE(v_before, 0);

    PERFORM public.c21_apply_branch_stock_delta(p_account_id, v_pid, v_bid, v_qty);

    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reference_id, reference_type, performed_by,
      operation_group_id, branch_id, unit_cost_snapshot, metadata
    ) VALUES (
      v_uid, p_account_id, v_pid, v_pair->>'product_name', 'sale_return',
      v_qty, v_before, v_before + v_qty,
      p_dn_id, p_reference_type, v_uid,
      p_op_group, v_bid, (v_pair->>'unit_cost')::numeric,
      jsonb_build_object('reverses', p_reverses,
                         'delivery_note_item_ids', COALESCE(v_pair->'item_ids', '[]'::jsonb))
    );
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text) IS
  'remitos-venta (D4/D5/D16): devuelve al stock lo retenido sobre los pares recibidos (de '
  '_delivery_note_held_pairs): c21_apply_branch_stock_delta(+retenido) y movimiento type = sale_return con '
  'reference_type delivery_note_update (edición) o delivery_note_reversal (anulación) y metadata.reverses. No '
  'lee el ledger. Interna.';


-- Remito + líneas + historial + nombres, como lo devuelven las RPCs.
CREATE OR REPLACE FUNCTION public._delivery_note_payload(p_dn_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT to_jsonb(dn)
         || jsonb_build_object(
              'document_type', 'delivery_note_' || dn.direction,
              'client_name',   (SELECT c.name FROM public.clients c WHERE c.id = dn.client_id),
              'client_phone',  (SELECT c.phone FROM public.clients c WHERE c.id = dn.client_id),
              'client_deleted', (SELECT c.deleted_at IS NOT NULL FROM public.clients c WHERE c.id = dn.client_id),
              'branch_name',   (SELECT b.name FROM public.branches b WHERE b.id = dn.branch_id),
              'converted_sales_order_id', NULL,
              'converted_operation_id',   NULL,
              'items', COALESCE((
                SELECT jsonb_agg(to_jsonb(i)
                                 || jsonb_build_object(
                                      'unit_symbol', (SELECT u.symbol FROM public.units_of_measure u WHERE u.id = i.unit_id),
                                      'product_deleted', (SELECT p.deleted_at IS NOT NULL FROM public.products p WHERE p.id = i.product_id))
                                 ORDER BY i.line_no, i.id)
                FROM public.delivery_note_items i
                WHERE i.delivery_note_id = dn.id), '[]'::jsonb),
              'history', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                         'from_status', h.from_status, 'to_status', h.to_status,
                         'performed_by', h.performed_by, 'reason', h.reason, 'occurred_at', h.occurred_at)
                       ORDER BY h.occurred_at, h.id)
                FROM public.document_status_history h
                WHERE h.document_type = 'delivery_note_' || dn.direction
                  AND h.document_id = dn.id
                  AND h.account_id = dn.account_id), '[]'::jsonb))
  FROM public.delivery_notes dn
  WHERE dn.id = p_dn_id;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_payload(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_payload(uuid) IS
  'remitos-venta: fila de delivery_notes + document_type, nombres de cliente y sucursal, líneas en orden de '
  'carga (con símbolo de unidad y si el producto fue dado de baja) e historial de estados. '
  'converted_sales_order_id/converted_operation_id quedan NULL hasta la tanda B. Interna.';


-- =============================================================================
-- 6. RPCs públicas
-- =============================================================================

-- ── rpc_create_sale_delivery_note ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_sale_delivery_note(
  p_idempotency_key  text,
  p_client_id        uuid,
  p_branch_id        uuid,
  p_delivery_address text,
  p_notes            text,
  p_items            jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid         uuid;
  v_dn_id       uuid;
  v_inserted    integer;
  v_existing_op uuid;
  v_account_id  uuid;
  v_branch      RECORD;
  v_address     text;
  v_notes       text;
  v_products    uuid[];
  v_valid       jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION 'idempotency_key_required: la emisión del remito necesita una clave de idempotencia'
      USING ERRCODE = 'P0400';
  END IF;

  -- DEC-06, molde exacto de _c29_confirm_order_core: la fila se inserta ANTES
  -- de escribir y revierte con el remito. Un envío concurrente con la misma
  -- clave espera acá al primero y cae en DO NOTHING (nunca un 23505).
  v_dn_id := gen_random_uuid();
  INSERT INTO public.operation_idempotency (user_id, operation_kind, idempotency_key, operation_id)
  VALUES (v_uid, 'delivery_note_sale', p_idempotency_key, v_dn_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid AND operation_kind = 'delivery_note_sale' AND idempotency_key = p_idempotency_key;
    IF v_existing_op IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.delivery_notes dn
      WHERE dn.id = v_existing_op AND dn.direction = 'sale'
        AND dn.account_id IN (SELECT public.current_account_ids())
    ) THEN
      RETURN public._delivery_note_payload(v_existing_op) || jsonb_build_object('replayed', true);
    END IF;
    RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación' USING ERRCODE = 'P0409';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_client_required: el remito necesita un cliente' USING ERRCODE = 'P0400';
  END IF;

  -- La cuenta es la del cliente, entre las del usuario (molde de rpc_create_quote).
  SELECT c.account_id INTO v_account_id
  FROM   public.clients c
  WHERE  c.id = p_client_id
    AND  c.account_id IN (SELECT public.current_account_ids());
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role(v_account_id, 'issue');

  IF NOT EXISTS (SELECT 1 FROM public.clients WHERE id = p_client_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_branch_required: el remito necesita la sucursal de la que sale la mercadería'
      USING ERRCODE = 'P0400';
  END IF;
  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or not active for this account' USING ERRCODE = 'P0404';
  END IF;
  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  v_address := NULLIF(btrim(COALESCE(p_delivery_address, '')), '');
  IF v_address IS NOT NULL AND char_length(v_address) > 500 THEN
    RAISE EXCEPTION 'delivery_note_address_too_long: el domicilio admite hasta 500 caracteres' USING ERRCODE = 'P0400';
  END IF;
  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'delivery_note_notes_too_long: las notas admiten hasta 2.000 caracteres' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'delivery_note_items_required: el remito necesita al menos una línea' USING ERRCODE = 'P0400';
  END IF;

  -- Lock de los productos ANTES de validarlos (TOCTOU, D4 paso 5).
  SELECT array_agg(DISTINCT NULLIF(e->>'product_id', '')::uuid) INTO v_products
  FROM   jsonb_array_elements(p_items) AS e
  WHERE  jsonb_typeof(e) = 'object';
  PERFORM public._delivery_note_lock_products(v_account_id, v_products);

  v_valid := public._delivery_note_validate_items(v_account_id, p_branch_id, p_items, NULL);

  -- delivery_notes_assign_number_sale numera y
  -- delivery_notes_record_status_creation_sale registra NULL -> issued.
  INSERT INTO public.delivery_notes
    (id, account_id, direction, branch_id, client_id, status, issued_on,
     delivery_address, notes, total, created_by)
  VALUES
    (v_dn_id, v_account_id, 'sale', p_branch_id, p_client_id, 'issued', public.reporting_local_today(),
     v_address, v_notes, (v_valid->>'total')::numeric, v_uid);

  PERFORM public._delivery_note_insert_items(v_account_id, v_dn_id, v_valid->'lines', NULL);

  PERFORM public._delivery_note_apply_stock(v_account_id, v_dn_id, gen_random_uuid(),
                                            public._delivery_note_held_pairs(v_dn_id));

  RETURN public._delivery_note_payload(v_dn_id) || jsonb_build_object('replayed', false);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale_delivery_note(text, uuid, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_delivery_note(text, uuid, uuid, text, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.rpc_create_sale_delivery_note(text, uuid, uuid, text, text, jsonb) IS
  'remitos-venta (D4): emite un remito de venta y DESCUENTA el stock de la sucursal en la misma transacción. '
  'Idempotente por (usuario, delivery_note_sale, clave) con el molde DEC-06 del núcleo (replay -> mismo remito '
  'con replayed = true; clave de otra operación -> P0409 idempotency_key_conflict). Cliente vivo de las cuentas '
  'del usuario (P0404 client_not_found), rol issue antes de escribir (P0401/P0403), sucursal obligatoria, de la '
  'cuenta, activa y no cerrada (P0400/P0404/P0422), productos bloqueados en orden de id ANTES de validar, '
  'líneas normalizadas, total del servidor, gate por par producto-sucursal (P0409 stock_insuficiente, cero '
  'efectos). No toca caja, banco, cuenta corriente ni outbox.';


-- ── rpc_update_delivery_note ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_update_delivery_note(
  p_delivery_note_id  uuid,
  p_expected_revision integer,
  p_client_id         uuid,
  p_branch_id         uuid,
  p_delivery_address  text,
  p_notes             text,
  p_items             jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid      uuid;
  v_dn       RECORD;
  v_branch   RECORD;
  v_address  text;
  v_notes    text;
  v_products uuid[];
  v_old      jsonb;
  v_new      jsonb;
  v_valid    jsonb;
  v_carry    jsonb;
  v_rev      jsonb;
  v_app      jsonb;
  v_op_group uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_dn
  FROM   public.delivery_notes
  WHERE  id = p_delivery_note_id
    AND  account_id IN (SELECT public.current_account_ids())
    AND  direction = 'sale'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role(v_dn.account_id, 'issue');

  IF v_dn.status = 'converted' THEN
    RAISE EXCEPTION 'delivery_note_locked_converted: el remito ya se convirtió en venta: para corregirlo, eliminá la venta y el remito vuelve a quedar pendiente'
      USING ERRCODE = 'P0423';
  END IF;
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede editar', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se editó' USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  IF p_client_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.clients
    WHERE id = p_client_id AND account_id = v_dn.account_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  -- La pata de reversa escribe en la sucursal VIGENTE: autosuficiente, no
  -- delega en el guard de baja de sucursal (D5, D9).
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_dn.branch_id AND is_active = TRUE AND status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito está desactivada o cerrada — reactivala para editar el remito'
      USING ERRCODE = 'P0422';
  END IF;

  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_branch_required: el remito necesita la sucursal de la que sale la mercadería'
      USING ERRCODE = 'P0400';
  END IF;
  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_dn.account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or not active for this account' USING ERRCODE = 'P0404';
  END IF;
  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Reemplazo completo: NULL significa vacío (la UI manda el valor vigente).
  v_address := NULLIF(btrim(COALESCE(p_delivery_address, '')), '');
  IF v_address IS NOT NULL AND char_length(v_address) > 500 THEN
    RAISE EXCEPTION 'delivery_note_address_too_long: el domicilio admite hasta 500 caracteres' USING ERRCODE = 'P0400';
  END IF;
  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'delivery_note_notes_too_long: las notas admiten hasta 2.000 caracteres' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'delivery_note_items_required: el remito necesita al menos una línea' USING ERRCODE = 'P0400';
  END IF;

  -- Lock de la unión de productos (vigentes + nuevos) ANTES de validar.
  SELECT array_agg(DISTINCT x.pid) INTO v_products
  FROM (
    SELECT i.product_id AS pid FROM public.delivery_note_items i WHERE i.delivery_note_id = v_dn.id
    UNION
    SELECT NULLIF(e->>'product_id', '')::uuid FROM jsonb_array_elements(p_items) AS e WHERE jsonb_typeof(e) = 'object'
  ) x
  WHERE x.pid IS NOT NULL;
  PERFORM public._delivery_note_lock_products(v_dn.account_id, v_products);

  -- Lo retenido por las líneas VIGENTES, antes de tocarlas.
  v_old := public._delivery_note_held_pairs(v_dn.id);

  v_valid := public._delivery_note_validate_items(v_dn.account_id, p_branch_id, p_items, v_old);

  -- Política canónica de operaciones (D6): el producto que sigue acarrea sus
  -- cuatro snapshots (ante varias líneas, la de menor line_no).
  SELECT COALESCE(jsonb_object_agg(s.product_id::text, jsonb_build_object(
           'name_snapshot', s.name_snapshot, 'sku_snapshot', s.sku_snapshot,
           'unit_cost_snapshot', s.unit_cost_snapshot, 'iva_rate_snapshot', s.iva_rate_snapshot)), '{}'::jsonb)
  INTO   v_carry
  FROM  (SELECT DISTINCT ON (i.product_id) i.product_id, i.name_snapshot, i.sku_snapshot,
                i.unit_cost_snapshot, i.iva_rate_snapshot
         FROM   public.delivery_note_items i
         WHERE  i.delivery_note_id = v_dn.id
         ORDER BY i.product_id, i.line_no, i.id) s;

  DELETE FROM public.delivery_note_items WHERE delivery_note_id = v_dn.id;

  UPDATE public.delivery_notes
  SET    client_id        = p_client_id,
         branch_id        = p_branch_id,
         delivery_address = v_address,
         notes            = v_notes,
         total            = (v_valid->>'total')::numeric,
         updated_at       = now(),
         updated_by       = v_uid,
         revision         = revision + 1
  WHERE  id = v_dn.id;

  PERFORM public._delivery_note_insert_items(v_dn.account_id, v_dn.id, v_valid->'lines', v_carry);

  v_new := public._delivery_note_held_pairs(v_dn.id);

  -- Pares que cambian: retenido <> requerido por (producto, sucursal). Los
  -- demás no escriben nada (una edición de precio no ensucia el kardex).
  WITH o AS (
    SELECT e, (e->>'product_id')::uuid AS pid, (e->>'branch_id')::uuid AS bid, (e->>'quantity')::numeric AS qty
    FROM jsonb_array_elements(v_old) e
  ), n AS (
    SELECT e, (e->>'product_id')::uuid AS pid, (e->>'branch_id')::uuid AS bid, (e->>'quantity')::numeric AS qty
    FROM jsonb_array_elements(v_new) e
  ), changed AS (
    SELECT o.e AS old_e, n.e AS new_e
    FROM o FULL JOIN n ON n.pid = o.pid AND n.bid = o.bid
    WHERE COALESCE(o.qty, 0) <> COALESCE(n.qty, 0)
  )
  SELECT COALESCE(jsonb_agg(old_e) FILTER (WHERE old_e IS NOT NULL), '[]'::jsonb),
         COALESCE(jsonb_agg(new_e) FILTER (WHERE new_e IS NOT NULL), '[]'::jsonb)
  INTO   v_rev, v_app
  FROM   changed;

  v_op_group := gen_random_uuid();
  -- Reversa primero: el control de faltante es sobre el neto.
  PERFORM public._delivery_note_reverse_held(v_dn.account_id, v_dn.id, v_op_group, v_rev,
                                             'delivery_note_update', 'delivery_note_edit');
  PERFORM public._delivery_note_apply_stock(v_dn.account_id, v_dn.id, v_op_group, v_app);

  RETURN public._delivery_note_payload(v_dn.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) IS
  'remitos-venta (D5/D6): reemplazo atómico de un remito issued bajo FOR UPDATE (P0404 delivery_note_not_found '
  'si es ajeno o no existe; P0423 delivery_note_locked_converted; P0409 delivery_note_invalid_state; P0409 '
  'delivery_note_changed ante una versión vieja). Rol issue, cliente vivo, sucursal vigente y nueva activas y '
  'no cerradas (P0422 delivery_note_branch_inactive / branch_closed). Productos bloqueados antes de validar; '
  'retenido de las líneas vigentes (_delivery_note_held_pairs, nunca el ledger) contra requerido normalizado: '
  'sólo los pares que cambian reciben reversa (sale_return/delivery_note_update) y después aplicación '
  '(sale/delivery_note, faltante sobre el neto). Snapshots acarreados por producto. revision + 1, sin historial '
  'de estados.';


-- ── rpc_cancel_delivery_note ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_cancel_delivery_note(
  p_delivery_note_id  uuid,
  p_expected_revision integer,
  p_reason            text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid      uuid;
  v_dn       RECORD;
  v_reason   text;
  v_products uuid[];
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_dn
  FROM   public.delivery_notes
  WHERE  id = p_delivery_note_id
    AND  account_id IN (SELECT public.current_account_ids())
    AND  direction = 'sale'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role(v_dn.account_id, 'void');

  IF v_dn.status = 'converted' THEN
    RAISE EXCEPTION 'delivery_note_locked_converted: el remito ya se convirtió en venta: para anularlo, primero eliminá la venta'
      USING ERRCODE = 'P0423';
  END IF;
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede anular', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se anula' USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'delivery_note_cancel_reason_required: anular un remito exige un motivo' USING ERRCODE = 'P0400';
  END IF;
  IF char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'delivery_note_cancel_reason_too_long: el motivo admite hasta 500 caracteres' USING ERRCODE = 'P0400';
  END IF;

  -- Autosuficiente (D9/D16): nunca reponer stock en una sucursal que no opera.
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_dn.branch_id AND is_active = TRUE AND status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito está desactivada o cerrada — reactivala para anular el remito'
      USING ERRCODE = 'P0422';
  END IF;

  -- Lock de los productos ANTES de leer branch_stock (D16 paso 7).
  SELECT array_agg(DISTINCT i.product_id) INTO v_products
  FROM   public.delivery_note_items i WHERE i.delivery_note_id = v_dn.id;
  PERFORM public._delivery_note_lock_products(v_dn.account_id, v_products);

  PERFORM public._delivery_note_reverse_held(v_dn.account_id, v_dn.id, gen_random_uuid(),
                                             public._delivery_note_held_pairs(v_dn.id),
                                             'delivery_note_reversal', 'delivery_note_cancel');

  PERFORM public.record_status_transition(v_dn.account_id, 'delivery_note_sale', v_dn.id,
                                          'issued', 'canceled', v_uid, v_reason);
  UPDATE public.delivery_notes
  SET    status = 'canceled', updated_at = now(), updated_by = v_uid
  WHERE  id = v_dn.id;

  RETURN public._delivery_note_payload(v_dn.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_cancel_delivery_note(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_delivery_note(uuid, integer, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_cancel_delivery_note(uuid, integer, text) IS
  'remitos-venta (D16, R3): anula un remito issued bajo FOR UPDATE. Rol void ({admin,owner}, P0403); converted '
  '-> P0423 delivery_note_locked_converted; canceled -> P0409 delivery_note_invalid_state; versión (P0409 '
  'delivery_note_changed); motivo obligatorio (P0400 delivery_note_cancel_reason_required); sucursal del remito '
  'activa y no cerrada (P0422 delivery_note_branch_inactive, sin efectos). Bloquea los productos antes de leer '
  'el stock y repone TODO lo retenido (sale_return/delivery_note_reversal) desde las líneas, nunca desde el '
  'ledger. Historial issued -> canceled con el motivo y el actor.';


-- ── rpc_get_delivery_note ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_get_delivery_note(p_delivery_note_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.delivery_notes dn
    WHERE dn.id = p_delivery_note_id AND dn.account_id IN (SELECT public.current_account_ids())
  ) THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;
  RETURN public._delivery_note_payload(p_delivery_note_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_get_delivery_note(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_note(uuid) TO authenticated;
COMMENT ON FUNCTION public.rpc_get_delivery_note(uuid) IS
  'remitos-venta (D16): payload del remito (cabecera, líneas, nombres e historial) para cualquier miembro de la '
  'cuenta. Ajeno e inexistente responden igual: P0404 delivery_note_not_found. Sólo lectura.';
