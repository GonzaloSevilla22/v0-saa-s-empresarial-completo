-- =============================================================================
-- venta-editable-sin-cae — 20261060000001
--
-- Pedido textual del PO: "necesito que las ventas se puedan modificar, sólo si
-- ésta no tiene el CAE, es decir no se envió al ARCA aún".
--
-- Governance: CRÍTICO (dominio fiscal — anula comprobantes y toca la RPC de
-- emisión) con tramos MEDIOS (superficie frontend).
--
-- Hasta hoy, rpc_atomic_update_sale_operation (edición) y
-- rpc_delete_sale_operation (borrado) rechazaban con P0423 en cuanto la
-- sales_order de la venta tenía un fiscal_documents con
-- status IN ('pending_cae','authorized')  —  20260930000001 (F2) y
-- 20261005000001. Eso es MÁS estricto de lo que el PO necesita: bloquea apenas
-- se emite el comprobante, aunque ARCA todavía no lo haya recibido.
--
-- Regla nueva (D2). La venta es editable/borrable si:
--     (a) no tiene comprobante, o
--     (b) el comprobante está en ('rejected','voided'), o
--     (c) está 'pending_cae' y TODAVÍA NO SE MANDÓ a ARCA, es decir
--         cae_submit_started_at IS NULL AND cae_submit_unconfirmed_at IS NULL.
-- Queda BLOQUEADA desde el instante en que el pedido salió hacia ARCA, con o
-- sin respuesta. Desde fiscal-riesgos-residuales (R1, 20261059000001) ese
-- instante es EXACTO: `cae_submit_started_at` es la marca previa que se
-- persiste ANTES del FECAESolicitar (hook on_submit_start del relay), y
-- `cae_submit_unconfirmed_at` es el congelado, que es un caso de marca.
--
-- En el caso (c) el comprobante se ANULA (estado terminal nuevo 'voided') en
-- la MISMA transacción de la edición/borrado, para que el cron no facture
-- después importes viejos; el usuario puede volver a emitir (comprobante
-- nuevo, número nuevo — el número local no se reutiliza, D9).
--
-- Bloques de este archivo:
--   (1) CHECK de fiscal_documents.status: admite el 4º estado 'voided'.
--   (2) Catálogo document_status_transitions: pending_cae → voided.
--   (3) Helper _fiscal_void_pending_for_sale_edit — ÚNICA definición de la
--       regla, compartida por la edición y el borrado.
--   (4) rpc_atomic_update_sale_operation — guard fiscal reescrito.
--   (5) rpc_delete_sale_operation — mismo guard, mismo helper.
--   (6) rpc_emit_sale_invoice — el guard de idempotencia pasa de "¿hay
--       comprobante?" a "¿lo que hay bloquea?" (allow-list), para que la
--       re-emisión sea posible.
--   (7) Gate de introspección embebido.
--
-- Integridad de función (regla dura de la casa): los cuerpos de (4), (5) y (6)
-- parten del pg_get_functiondef VIVO, verificado el 2026-09-22 contra prod
-- (gxdhpxvdjjkmxhdkkwyb, sólo SELECT) Y contra el stack local, con md5(prosrc)
-- CR-stripped idéntico en los tres lados:
--   rpc_atomic_update_sale_operation  2e7394bef577adb708c91da8ea469a9f (20261045000001)
--   rpc_delete_sale_operation         c84c6f1bdd15e845b307fbe2aa554fa4 (20261005000001)
--   rpc_emit_sale_invoice             c0b01bc297f8be4e47483cff39ea987c (20260801000001)
-- Las tres se recrean con CREATE OR REPLACE y firma IDÉNTICA: no cambia ni un
-- parámetro ni un default, así que no hay riesgo de overload fantasma (42725)
-- y no hace falta DROP.
--
-- Idempotente y segura en base vacía: DROP CONSTRAINT IF EXISTS + ADD,
-- INSERT ... ON CONFLICT DO UPDATE, y CREATE OR REPLACE en las funciones.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- (1) CHECK de status: admite el estado terminal nuevo 'voided'
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.fiscal_documents
  DROP CONSTRAINT IF EXISTS fiscal_documents_status_check;

ALTER TABLE public.fiscal_documents
  ADD CONSTRAINT fiscal_documents_status_check
  CHECK (status = ANY (ARRAY['pending_cae'::text, 'authorized'::text, 'rejected'::text, 'voided'::text]));

COMMENT ON CONSTRAINT fiscal_documents_status_check ON public.fiscal_documents IS
  'venta-editable-sin-cae (D1): 4o estado terminal ''voided'' — comprobante anulado por edición/borrado de su venta ANTES de que el pedido saliera hacia ARCA. NO es una nota de crédito (esa revierte un comprobante que SÍ tuvo efecto fiscal).';


-- ─────────────────────────────────────────────────────────────────────────────
-- (2) Catálogo FSM: pending_cae → voided
--
-- SIN esta fila, NINGÚN UPDATE de status a 'voided' es posible: el trigger
-- fiscal_documents_enforce_status_transition (BEFORE UPDATE, WHEN old.status IS
-- DISTINCT FROM new.status) delega en is_valid_transition, que consulta este
-- catálogo, y aborta con P0409 (fsm_violation) antes incluso del CHECK de la
-- tabla. O sea: el catálogo ES el guard de las transiciones prohibidas
-- (authorized→voided, rejected→voided, voided→*) — no hay que escribir ninguna.
--
-- is_terminal_to = true: 'voided' no sale a ningún otro estado.
-- requires_reason = true (D6): transition_requires_reason('fiscal_document',
--   'voided') pasa a ser true y record_status_transition exige el motivo con
--   P0400. Así "anulado por edición de la venta X" queda en
--   document_status_history sin una línea de código extra.
-- allowed_role = NULL (D7): igual que las otras 3 filas de fiscal_document —
--   sin restricción de rol. Quien puede editar la venta ya pasó
--   require_role(auth, ["user","admin"]) en el service y los guards de la RPC.
--
-- GOTCHA (precedente seguros-perfil-asesor, 42P10): document_status_transitions_uq
-- es un índice único PARCIAL (WHERE from_status IS NOT NULL) → el ON CONFLICT
-- tiene que repetir el predicado o Postgres no lo infiere.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('fiscal_document', 'pending_cae', 'voided', true, true, NULL)
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL
DO UPDATE SET is_terminal_to  = EXCLUDED.is_terminal_to,
              requires_reason = EXCLUDED.requires_reason,
              allowed_role    = EXCLUDED.allowed_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- (3) Helper canónico de anulación — el ÚNICO objeto nuevo de este change
--
-- ÚNICA definición de "anular el comprobante pendiente de esta orden". Lo
-- comparten la edición y el borrado (regla "reutilización antes que
-- repetición"): dos copias de esta lógica divergirían y una de las dos
-- terminaría anulando un comprobante ya enviado a ARCA.
--
-- Contrato:
--   · Devuelve jsonb NULL si la orden no existe, si no tiene comprobante, o si
--     el que tiene ya es terminal-inocuo ('rejected'/'voided') → no hay nada
--     que anular y la venta se edita/borra sin tocar nada fiscal.
--   · Devuelve {fiscal_document_id, punto_de_venta, number, label} si anuló.
--   · RAISE P0423 si el comprobante BLOQUEA. TRES mensajes con TOKEN propio
--     cada uno, porque la acción que le queda al usuario es distinta:
--       invoiced_operation_immutable     → authorized: nota de crédito
--       fiscal_document_sent_immutable   → marcado o congelado: esperar/revisar
--       fiscal_document_claim_in_flight  → lock del relay: reintentar en minutos
--   · NUNCA toca sales_orders.fiscal_document_id (D5): el vínculo sobrevive
--     para que el badge muestre "Anulado" y para el rastro de auditoría.
--
-- Concurrencia (D4). Dos pasos deliberadamente distintos:
--   Paso 1, lectura SIN lock: sirve SÓLO para RECHAZAR RÁPIDO. Nunca para
--     decidir anular.
--   Paso 2, SELECT ... FOR UPDATE NOWAIT + RE-EVALUACIÓN del predicado con lo
--     que se ve BAJO el lock: esa condición, y no la del paso 1, es la que
--     autoriza la anulación (mismo argumento de re-evaluación bajo READ
--     COMMITTED que el cuerpo de rpc_atomic_update_sale_operation ya usa para
--     el SELECT ... FOR UPDATE sobre public.events).
--   NOWAIT y no FOR UPDATE a secas: si el relay tiene la fila tomada, este
--     request del usuario NO puede quedar colgado detrás de un round-trip SOAP
--     a ARCA. 55P03 → P0423 con token TRANSITORIO ("probá en unos minutos").
--
-- Por qué la carrera contra el relay es segura en las dos direcciones:
--   · Si la anulación gana, rpc_fiscal_document_claim_pending no matchea
--     (filtra status='pending_cae') y rpc_fiscal_document_mark_submit_started
--     levanta P0437 (mismo filtro + RAISE) → el FECAESolicitar NUNCA sale.
--   · Si el relay gana, la marca ya está commiteada y el paso 1 (o la
--     re-evaluación del paso 2) rechaza con P0423 → JAMÁS se anula un
--     comprobante enviado.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._fiscal_void_pending_for_sale_edit(
  p_sales_order_id uuid,
  p_account_id     uuid,
  p_performed_by   uuid,
  p_reason         text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_doc     RECORD;
  v_locked  RECORD;
BEGIN
  IF p_sales_order_id IS NULL THEN
    RETURN NULL;                      -- venta legacy sin sales_orders
  END IF;

  -- ── Paso 1: lectura SIN lock, sólo para RECHAZAR RÁPIDO.
  SELECT fd.id, fd.status, fd.punto_de_venta, fd.number,
         fd.cae_submit_started_at, fd.cae_submit_unconfirmed_at
  INTO   v_doc
  FROM   public.sales_orders so
  JOIN   public.fiscal_documents fd ON fd.id = so.fiscal_document_id
  WHERE  so.id = p_sales_order_id;

  IF NOT FOUND THEN
    RETURN NULL;                      -- sin comprobante: nada que anular
  END IF;

  IF v_doc.status IN ('rejected', 'voided') THEN
    RETURN NULL;                      -- terminal inocuo: nunca tuvo efecto fiscal
  END IF;

  IF v_doc.status = 'authorized' THEN
    RAISE EXCEPTION 'invoiced_operation_immutable: la venta tiene un comprobante autorizado por ARCA (%-%) y no puede editarse ni borrarse — emití una nota de crédito y registrá una venta nueva',
      lpad(v_doc.punto_de_venta::text, 4, '0'), lpad(v_doc.number::text, 8, '0')
      USING ERRCODE = 'P0423';
  END IF;

  -- Acá status = 'pending_cae' por descarte (el CHECK sólo admite 4 valores y
  -- los otros 3 ya retornaron o abortaron). ALLOW-LIST, no deny-list: si
  -- mañana aparece un status nuevo, cae en este IF y BLOQUEA.
  IF v_doc.status <> 'pending_cae' THEN
    RAISE EXCEPTION 'invoiced_operation_immutable: la venta tiene un comprobante en un estado que no se puede anular (%) — no se puede editar ni borrar', v_doc.status
      USING ERRCODE = 'P0423';
  END IF;

  IF v_doc.cae_submit_started_at IS NOT NULL
     OR v_doc.cae_submit_unconfirmed_at IS NOT NULL THEN
    RAISE EXCEPTION 'fiscal_document_sent_immutable: el comprobante de esta venta (%-%) ya se envió a ARCA y todavía no hay respuesta — no se puede editar ni borrar hasta que se resuelva',
      lpad(v_doc.punto_de_venta::text, 4, '0'), lpad(v_doc.number::text, 8, '0')
      USING ERRCODE = 'P0423';
  END IF;

  -- ── Paso 2: lock explícito + RE-EVALUACIÓN.
  BEGIN
    SELECT fd.id, fd.status, fd.punto_de_venta, fd.number,
           fd.cae_submit_started_at, fd.cae_submit_unconfirmed_at
    INTO   v_locked
    FROM   public.fiscal_documents fd
    WHERE  fd.id = v_doc.id
    FOR UPDATE NOWAIT;
  EXCEPTION
    WHEN lock_not_available THEN       -- 55P03
      RAISE EXCEPTION 'fiscal_document_claim_in_flight: se está emitiendo el comprobante de esta venta en este momento — probá de nuevo en unos minutos'
        USING ERRCODE = 'P0423';
  END;

  IF v_locked.status <> 'pending_cae'
     OR v_locked.cae_submit_started_at     IS NOT NULL
     OR v_locked.cae_submit_unconfirmed_at IS NOT NULL THEN
    RAISE EXCEPTION 'fiscal_document_sent_immutable: el comprobante de esta venta (%-%) salió hacia ARCA mientras se guardaban los cambios — no se editó nada; volvé a intentar cuando se resuelva',
      lpad(v_locked.punto_de_venta::text, 4, '0'), lpad(v_locked.number::text, 8, '0')
      USING ERRCODE = 'P0423';
  END IF;

  -- ── Paso 3: anular. El trigger de FSM valida la transición contra el
  -- catálogo; record_status_transition escribe el historial con el motivo.
  UPDATE public.fiscal_documents
  SET    status = 'voided'
  WHERE  id = v_locked.id;

  PERFORM public.record_status_transition(
    p_account_id, 'fiscal_document', v_locked.id,
    'pending_cae', 'voided',
    -- performed_by es NOT NULL en document_status_history: el uuid cero es la
    -- convención de "sistema" que ya usa rpc_record_fiscal_transition.
    COALESCE(p_performed_by, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(NULLIF(trim(p_reason), ''), 'Anulado por edición de la venta')
  );

  RETURN jsonb_build_object(
    'fiscal_document_id', v_locked.id,
    'punto_de_venta',     v_locked.punto_de_venta,
    'number',             v_locked.number,
    'label',              lpad(v_locked.punto_de_venta::text, 4, '0') || '-' ||
                          lpad(v_locked.number::text, 8, '0')
  );
END;
$function$;

-- ACLs: helper de nombre INTERNO (prefijo `_`) — NUNCA anon/authenticated.
-- Corre siempre desde dentro de una RPC SECURITY DEFINER propiedad de postgres,
-- así que no necesita GRANT al rol del request. Mismo contrato que
-- record_status_transition (ACL viva en prod: postgres=X | service_role=X).
-- Candado de firma: v_internal_only_fns del chequeo (3) de
-- supabase/tests/test_function_acl_gate.sql.
REVOKE ALL ON FUNCTION public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text) TO postgres, service_role;

COMMENT ON FUNCTION public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text) IS
  'venta-editable-sin-cae: anula (voided) el comprobante pendiente de una sales_order cuando el pedido NO salió hacia ARCA, dentro de la transacción de la edición/borrado de la venta. P0423 con token propio si bloquea (authorized / enviado / lock del relay). Helper interno: nunca expuesto a anon/authenticated.';


-- ─────────────────────────────────────────────────────────────────────────────
-- (4) rpc_atomic_update_sale_operation — guard fiscal reescrito
--
-- Cuerpo VIVO de 20261045000001_operacion_party_guard.sql
-- (md5 CR-stripped 2e7394bef577adb708c91da8ea469a9f), con TRES cambios y
-- nada más: dos variables nuevas en el DECLARE, el guard fiscal reemplazado
-- por el LOOP que llama al helper, y el descriptor del comprobante anulado en
-- el RETURN. Firma IDÉNTICA (también porque está anclada literalmente en dos
-- entradas del chequeo (5) de test_function_acl_gate.sql).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_canal text DEFAULT NULL::text, p_canal_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_old_sale       RECORD;
  v_item           RECORD;
  v_product        RECORD;
  v_new_op_id      uuid;
  v_new_sale_id    uuid;
  v_stock_sum      numeric(15,4);
  v_result_items   jsonb := '[]'::jsonb;
  v_flag_on        boolean;
  v_old_snapshots  jsonb;
  v_prev_snap      jsonb;
  v_line_snap      jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
  v_old_payment_method_id   uuid;  -- metodos-pago-operaciones (D5)
  v_final_payment_method_id uuid;  -- metodos-pago-operaciones (D5)
  -- edicion-preserva-contexto (F1):
  v_old_operation_id uuid;         -- §D9: para re-apuntar sales_orders
  v_old_branch_id    uuid;         -- §D1/§D3
  v_old_canal        text;         -- §D1/§D3
  v_final_branch_id  uuid;         -- §D3/§D8: sucursal EFECTIVA (reimputada o vieja)
  v_final_canal      text;         -- §D3
  v_canal_clean      text;
  v_branch           RECORD;
  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable de la operación editada en vez de bloquear la edición.
  v_total_sum          numeric(15,2) := 0;
  v_kind_final          text;
  v_pending_event_id    uuid;
  v_pending_event_type  text;
  v_pending_payload     jsonb;
  v_has_posted_entry    boolean := false;
  -- venta-editable-sin-cae: la anulación del comprobante pendiente NO enviado.
  v_void_rec            RECORD;   -- (sales_order_id, operation_id) a anular
  v_voided_doc          jsonb;    -- descriptor del último comprobante anulado
BEGIN
  -- Identity always comes from the JWT — never from caller input
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Account scoping (C-05 D7) ────────────────────────────────────────────
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede actualizar la operación'
      USING ERRCODE = 'P0403';
  END IF;

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P0400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.sales
    WHERE id = ANY(p_sale_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: sale belongs to another user' USING ERRCODE = 'P0403';
  END IF;

  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids))
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): la edición también puede reasignar el
  -- client_id de la operación (p_client_id es obligatorio, sin contrato
  -- tri-estado _provided — el llamador siempre lo reenvía) y hoy lo
  -- escribe sin validar tenencia, igual que rpc_create_sale_operation_v2
  -- antes de este fix. Mismo predicado, mismo ERRCODE, ANTES de cualquier
  -- guard de inmutabilidad/reversa.
  IF p_client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = p_client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- edicion-preserva-contexto (F2, design §D5) + venta-editable-sin-cae (D2):
  -- guard fiscal — SHALL correr antes de cualquier reversa/eliminación/
  -- reaplicación, de modo que una operación bloqueada quede intacta si el
  -- guard dispara. Resuelto por JOIN (sales.operation_id →
  -- sales_orders.sale_operation_id → sales_orders.fiscal_document_id →
  -- fiscal_documents), nunca por una columna denormalizada de "facturado"
  -- (segunda fuente de verdad).
  --
  -- venta-editable-sin-cae: el predicado deja de ser "¿HAY comprobante?" y
  -- pasa a ser "¿el comprobante YA SALIÓ hacia ARCA?". Un pending_cae SIN
  -- marca de envío ya no bloquea: se ANULA (voided) en ESTA MISMA
  -- transacción, para que el relay no lo facture después con los importes
  -- viejos. authorized, marcado y congelado siguen bloqueando con P0423
  -- (tres tokens distintos — ver _fiscal_void_pending_for_sale_edit, que es
  -- la ÚNICA definición de esta regla y la comparte con el borrado).
  -- rejected y voided no bloquean ni se tocan.
  -- asiento-venta-formulario: el guard fiscal sigue siendo el PRIMERO.
  FOR v_void_rec IN
    SELECT DISTINCT so.id AS sales_order_id, s.operation_id AS operation_id
    FROM   public.sales s
    JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
    WHERE  s.id = ANY(p_sale_ids)
      AND  so.fiscal_document_id IS NOT NULL
  LOOP
    v_voided_doc := public._fiscal_void_pending_for_sale_edit(
      v_void_rec.sales_order_id, v_account_id, v_uid,
      format('Anulado por edición de la venta (operación %s)', v_void_rec.operation_id)
    );
  END LOOP;

  -- pagos-cableados-restantes (D6): inmutabilidad de operaciones con cargo
  -- de cuenta corriente o movimiento de caja posteado. Bloquea la operación
  -- ENTERA (no sólo monto/método — editar la fecha desplazaría la
  -- atribución temporal del movimiento). reference_id de ambas tablas puede
  -- apuntar a sales_orders.id (camino POS, vía _pay_register_party_charge /
  -- c28_register_cash_movement dentro de _c29_confirm_order_core, p_reference_id
  -- = p_sales_order_id) o directamente a sales.operation_id (camino
  -- formulario, rpc_create_sale_operation_v2) — se cubren ambos.
  -- asiento-venta-formulario: guards de cuenta corriente/caja/banco SIN CAMBIOS.
  IF EXISTS (
    SELECT 1
    FROM public.customer_account_movements cam
    WHERE cam.reference_id IN (
      SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
      UNION
      SELECT so.id FROM public.sales_orders so
      JOIN public.sales s ON s.operation_id = so.sale_operation_id
      WHERE s.id = ANY(p_sale_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_account_charge_immutable: la operación tiene un cargo de cuenta corriente posteado y no puede editarse — emití una nota de crédito y registrá una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cash_movements cm
    WHERE cm.reference_id IN (
      SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
      UNION
      SELECT so.id FROM public.sales_orders so
      JOIN public.sales s ON s.operation_id = so.sale_operation_id
      WHERE s.id = ANY(p_sale_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_cash_movement_immutable: la operación tiene un movimiento de caja posteado y no puede editarse — emití una nota de crédito y registrá una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.1): tercer EXISTS — bank_movements
  -- entra al mismo bloqueo P0423, misma doble referencia. El ledger
  -- bancario es append-only (C1) y el movimiento puede estar ya `matched`
  -- dentro de una sesión de conciliación cerrada: editarlo destruiría una
  -- conciliación firmada.
  IF EXISTS (
    SELECT 1
    FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'sale'
      AND bm.source_doc_ref IN (
        SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
        UNION
        SELECT so.id FROM public.sales_orders so
        JOIN public.sales s ON s.operation_id = so.sale_operation_id
        WHERE s.id = ANY(p_sale_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_bank_movement_immutable: la operación tiene un movimiento bancario posteado y no puede editarse — registrá el ajuste en el ledger bancario y una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- edicion-operaciones-lineas (D3): mismo flag_key y mismo patrón
  -- COALESCE-después-del-SELECT que rpc_create_sale_operation — ausencia de
  -- fila = v2 (escribe línea).
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  -- edicion-operaciones-lineas (D2): acarreo de snapshot keyed por
  -- product_id, capturado ANTES del DELETE — el CASCADE se lleva puesto
  -- sale_items en STEP 2. DISTINCT ON (product_id) ORDER BY product_id, id:
  -- determinístico ante colisión (dos filas viejas de header con el mismo
  -- producto — la forma legacy 1-operación:N-filas, 23 ventas en prod).
  SELECT COALESCE(jsonb_object_agg(t.product_id::text, t.snap), '{}'::jsonb)
  INTO   v_old_snapshots
  FROM (
    SELECT DISTINCT ON (si.product_id)
           si.product_id,
           jsonb_build_object(
             'name_snapshot',       si.name_snapshot,
             'sku_snapshot',        si.sku_snapshot,
             'unit_cost_snapshot',  si.unit_cost_snapshot,
             'iva_rate_snapshot',   si.iva_rate_snapshot,
             'snapshot_backfilled', si.snapshot_backfilled
           ) AS snap
    FROM   public.sale_items si
    WHERE  si.sale_id = ANY(p_sale_ids)
      AND  si.product_id IS NOT NULL
    ORDER BY si.product_id, si.id
  ) t;

  -- metodos-pago-operaciones (D5): capturar el payment_method_id vigente de
  -- la operación ANTES del DELETE — mismo momento que v_old_snapshots. Por
  -- operación (D3): cualquier fila alcanza (todas comparten el valor).
  SELECT payment_method_id INTO v_old_payment_method_id
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
  LIMIT  1;

  IF p_payment_method_provided THEN
    IF p_payment_method_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old_payment_method_id;
  END IF;

  -- edicion-preserva-contexto (F1, design §D1): capturar el contexto vigente
  -- del header ANTES del DELETE, junto al resto de lo que se acarrea.
  -- LIMIT 1 es correcto: branch_id/canal/operation_id son de la operación,
  -- no de la línea — todas las filas del mismo operation_id los comparten
  -- (misma justificación que payment_method_id, D3 de #419).
  SELECT operation_id, branch_id, canal
  INTO   v_old_operation_id, v_old_branch_id, v_old_canal
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
  LIMIT  1;

  -- asiento-venta-formulario (D7, override del PO): resolver el rastro
  -- contable de v_old_operation_id ANTES del REVERSE/DELETE — no se
  -- rechaza la edición, se ajusta el rastro más abajo. Caso B: se toma el
  -- lock ACÁ, sobre el evento pendiente (SaleOperationCreated apuntando a
  -- esta operación, o SaleOperationAdjusted cuyo new_operation_id es esta
  -- operación), para no competir con el dispatcher a mitad de camino. Bajo
  -- READ COMMITTED, SELECT ... FOR UPDATE re-evalúa el WHERE contra la
  -- versión más reciente de la fila al tomar el lock: si el dispatcher ya
  -- la marcó processed_at mientras se esperaba el lock, Postgres la excluye
  -- automáticamente del resultado — no hace falta un re-chequeo manual.
  IF v_old_operation_id IS NOT NULL THEN
    SELECT id, event_type, payload
    INTO   v_pending_event_id, v_pending_event_type, v_pending_payload
    FROM   public.events
    WHERE  processed_at IS NULL
      AND  (
             (event_type = 'SaleOperationCreated' AND aggregate_id = v_old_operation_id)
          OR (event_type = 'SaleOperationAdjusted' AND (payload->>'new_operation_id')::uuid = v_old_operation_id)
           )
    ORDER BY occurred_at
    LIMIT 1
    FOR UPDATE;

    -- Caso C: sin evento pendiente reemplazable — ¿hay un asiento ya posteado?
    IF v_pending_event_id IS NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_old_operation_id
          AND status = 'posted'
      ) INTO v_has_posted_entry;
    END IF;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para branch_id —
  -- espejo exacto del contrato de payment_method_id. provided=false →
  -- preservar; provided=true + NULL → desimputar; provided=true + valor →
  -- reimputar, previa validación de pertenencia a la cuenta y sucursal
  -- operativa (mismo guard que rpc_create_sale_operation_v2, C-26). La
  -- validación corre ACÁ, antes del REVERSE (gate 2.9: una reimputación
  -- inválida no debe revertir ni reaplicar stock).
  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM   public.branches
      WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old_branch_id;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para canal —
  -- mismo contrato. Sin conjunto cerrado en el schema (sales.canal es texto
  -- libre, sin CHECK) — se valida longitud igual que rpc_create_sale_operation_v2.
  IF p_canal_provided THEN
    v_canal_clean := NULLIF(trim(COALESCE(p_canal, '')), '');
    IF v_canal_clean IS NOT NULL AND length(v_canal_clean) > 40 THEN
      RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
    END IF;
    v_final_canal := v_canal_clean;
  ELSE
    v_final_canal := v_old_canal;
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — id vieja
  -- es el reference_id de la pata REVERSE, operation_id agrupa el movimiento
  -- bajo la operación a la que pertenecía la fila que se está reemplazando.
  -- La pata REVERSE sigue devolviendo a la sucursal VIEJA de cada fila
  -- (v_old_sale.branch_id) — no cambia con F1 (§D8: REVERSE = sucursal vieja).
  FOR v_old_sale IN
    SELECT id, product_id, quantity, branch_id, operation_id
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      -- Nombre actual del producto para el movimiento (congelar el nombre no
      -- es el contrato de este movimiento — el name_snapshot vive en la
      -- línea, no acá — se usa el mismo patrón que la creación: products.name
      -- vigente al momento de la operación).
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_sale.product_id;

      -- design §D5 (stock-movements-edicion): la pata REVERSE copia el
      -- unit_cost_snapshot del movimiento ORIGINAL si existe; si no, NULL.
      SELECT unit_cost_snapshot INTO v_reverse_unit_cost
      FROM   public.stock_movements
      WHERE  reference_id = v_old_sale.id AND reference_type = 'sale'
      ORDER  BY created_at DESC
      LIMIT  1;

      -- C-21 checkpoint #2: devolver a la branch original de la venta (o default).
      -- stock-movements-edicion (D2/D3): op_stock_movement aplica el delta
      -- (misma aritmética que antes) Y emite el movimiento espejo REVERSE:
      -- type='sale_return', reference_id=id VIEJO, reference_type='sale_update'.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_sale.product_id, v_old_product_name,
        v_old_sale.branch_id, v_old_sale.quantity, 'sale_return',
        v_old_sale.id, 'sale_update', v_old_sale.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  -- sale_items.sale_id tiene FK ON DELETE CASCADE: este DELETE es lo que
  -- borraba la línea sin recrearla (el hallazgo de edicion-operaciones-lineas).
  -- El acarreo de arriba ya capturó lo necesario antes de perderlo.
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  -- edicion-preserva-contexto (F3, design §D7): quantity pasa de integer a
  -- numeric — único eslabón entero de una cadena que ya es numeric(15,4) de
  -- punta a punta. unit_id se suma al recordset (igual forma que la
  -- creación) para escribirlo real en vez de NULL explícito (§D7 último
  -- párrafo).
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    -- asiento-venta-formulario: acumular el total nuevo (mismo patrón que
    -- rpc_create_sale_operation_v2) para el ajuste contable de más abajo.
    v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock).
      -- edicion-operaciones-lineas: se agrega name/sku/cost a la misma
      -- lectura para resolver el snapshot fresco sin una consulta extra.
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      IF v_stock_sum < v_item.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal = v_final_* (F1 §D3),
      -- unit_id = v_item.unit_id (F1 §D7, viaja con la línea).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- edicion-operaciones-lineas (D2/D4): la línea sigue al header.
      -- product_id presente en el mapa viejo → acarrea (una corrección de
      -- cantidad/precio no re-precifica); ausente → snapshot fresco
      -- (producto nuevo, ítem agregado, u operación que nunca tuvo línea).
      -- stock-movements-edicion: v_line_snap se calcula SIEMPRE (antes vivía
      -- adentro del IF v_flag_on) porque el movimiento de stock lo necesita
      -- exista o no la línea — el kill-switch apaga sale_items, no el ledger.
      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      IF v_flag_on THEN
        -- edicion-preserva-contexto: unit_id = v_item.unit_id en vez de NULL
        -- explícito (F1 §D7 último párrafo).
        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock.
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='sale',
      -- reference_id=id NUEVO, reference_type='sale' (indistinguible de la
      -- creación — el contrato del que depende la reversa al eliminar).
      -- unit_cost_snapshot reusa v_line_snap, la misma decisión de acarreo
      -- que la línea (sin re-valuar al costo actual).
      -- edicion-preserva-contexto (F1 §D8): la sucursal pasa a ser
      -- v_final_branch_id (la efectiva) en vez de NULL — editar deja de
      -- mudar stock a la sucursal default.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, -v_item.quantity, 'sale', v_new_sale_id, 'sale',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal/unit_id preservados/reimputados igual.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- edicion-preserva-contexto (F1, design §D9): la orden promovida SIN
  -- comprobante "real" se re-apunta al operation_id nuevo, en la misma
  -- transacción — cierra en su causa raíz la OQ-C de edicion-operaciones-
  -- lineas (3 órdenes colgadas en prod hoy, no reconstruibles
  -- retroactivamente: nada registró antes el mapeo operation_id viejo→nuevo
  -- de esas ediciones — ver design §D10).
  --
  -- "no tiene comprobante fiscal asociado" usa la MISMA definición que el
  -- guard F2 de arriba (§D5): fiscal_document_id NULL, o apuntando a un
  -- comprobante 'rejected' (nunca existió fiscalmente) — no solo NULL a
  -- secas. Sin este matiz, una orden cuyo único comprobante quedó rejected
  -- SÍ pasa el guard F2 (rejected no bloquea, D5) y SÍ se edita, pero
  -- fiscal_document_id sigue NOT NULL apuntando al doc rejected → un
  -- `WHERE fiscal_document_id IS NULL` a secas la deja huérfana (gate 2.8,
  -- descubierto en RED contra esta migración: no era redundante con F2, F2
  -- ya deja pasar exactamente este caso).
  UPDATE public.sales_orders so
  SET    sale_operation_id = v_new_op_id
  WHERE  so.sale_operation_id = v_old_operation_id
    AND  NOT EXISTS (
      SELECT 1 FROM public.fiscal_documents fd
      WHERE fd.id = so.fiscal_document_id
        AND fd.status IN ('pending_cae', 'authorized')
    );

  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable AHORA que v_new_op_id/v_total_sum/v_final_payment_method_id
  -- son finales. v_pending_event_id / v_has_posted_entry ya fueron
  -- resueltos ANTES del REVERSE/DELETE (con el lock tomado en el momento
  -- correcto) — acá sólo se actúa sobre lo ya resuelto.
  IF v_final_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind_final
    FROM public.payment_methods
    WHERE id = v_final_payment_method_id;
  ELSE
    v_kind_final := NULL;
  END IF;

  IF v_pending_event_id IS NOT NULL THEN
    -- Caso B (D7): reemplazar el evento pendiente EN EL LUGAR — el
    -- dispatcher, cuando lo procese, genera un solo asiento final,
    -- correcto, referenciando v_new_op_id. No se emite un segundo evento.
    IF v_pending_event_type = 'SaleOperationCreated' THEN
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = jsonb_build_object(
               'account_id',     v_account_id,
               'operation_id',   v_new_op_id,
               'total',          v_total_sum,
               'payment_method', v_kind_final,
               'client_id',      p_client_id,
               'sale_date',      p_date,
               'occurred_at',    now()
             )
      WHERE  id = v_pending_event_id;
    ELSE
      -- 'SaleOperationAdjusted' todavía pendiente (edición encadenada antes
      -- de que el relay procese la anterior): se actualiza el destino
      -- (new_operation_id) y los valores nuevos, pero se PRESERVA
      -- old_operation_id — la referencia al asiento a revertir no cambia,
      -- sigue siendo el mismo asiento original, todavía no tocado. Esto
      -- colapsa N ediciones-antes-de-procesar en un solo evento final.
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = v_pending_payload
                        || jsonb_build_object(
                             'new_operation_id', v_new_op_id,
                             'total',            v_total_sum,
                             'payment_method',   v_kind_final,
                             'client_id',        p_client_id,
                             'sale_date',        p_date,
                             'occurred_at',      now()
                           )
      WHERE  id = v_pending_event_id;
    END IF;
  ELSIF v_has_posted_entry THEN
    -- Caso C (D7): el asiento ya fue posteado — emitir el evento de
    -- ajuste. INSERT plano, SIN bloque EXCEPTION (D6): swallowear el
    -- fallo reproduciría en silencio el bug que este change arregla.
    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      v_account_id, 'SaleOperationAdjusted', 'SaleOperation', v_new_op_id,
      jsonb_build_object(
        'old_operation_id', v_old_operation_id,
        'new_operation_id', v_new_op_id,
        'account_id',       v_account_id,
        'total',            v_total_sum,
        'payment_method',   v_kind_final,
        'client_id',        p_client_id,
        'sale_date',        p_date,
        'occurred_at',      now()
      ),
      now()
    );
  END IF;
  -- Caso A (D7): ni v_pending_event_id ni v_has_posted_entry — no-op contable
  -- (operación anterior al productor, o que nunca tuvo evento).

  -- venta-editable-sin-cae: el descriptor del comprobante anulado viaja en la
  -- respuesta para que el toast diga "se anuló el comprobante 0003-00000005"
  -- con lo que dice el SERVIDOR, nunca con lo que el cliente creía.
  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items,
                            'voided_fiscal_document', v_voided_doc);
END;
$function$;

-- ACLs re-emitidas idénticas a las vivas en prod (postgres=X | authenticated=X
-- | service_role=X). CREATE OR REPLACE no las resetea, pero re-emitirlas
-- explícitas es el patrón de la casa y es lo que sostiene el gate de ACLs.
REVOKE ALL     ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) TO postgres, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- (5) rpc_delete_sale_operation — mismo guard, mismo helper
--
-- Cuerpo VIVO de 20261005000001_delete_guard_ledgers.sql
-- (md5 CR-stripped c84c6f1bdd15e845b307fbe2aa554fa4), con DOS cambios: la
-- variable nueva en el DECLARE y el guard fiscal reemplazado por la llamada al
-- helper. Firma IDÉNTICA.
--
-- El UPDATE de cancelación de la orden (status='canceled',
-- sale_operation_id = NULL) NO se toca: deja fiscal_document_id apuntando al
-- comprobante anulado, que es lo correcto — la orden cancelada ya no se puede
-- facturar (rpc_emit_sale_invoice exige status='confirmed') y el rastro queda.
--
-- Asimetría DELIBERADA con la edición: esta función devuelve boolean y NO se le
-- cambia el tipo de retorno (sería cambio de firma → DROP+CREATE → dos entradas
-- de gate que tocar). El frontend ya sabe qué comprobante se va a anular ANTES
-- de confirmar el borrado (derivado is_fiscally_locked / fiscal_pending_voidable
-- del read model), así que no necesita el descriptor en la respuesta.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_delete_sale_operation(
  p_sale_id      uuid DEFAULT NULL,
  p_operation_id uuid DEFAULT NULL,
  p_reason       text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_sale_ids             uuid[];
  v_sales_order_id       uuid;
  v_so_status             text;
  v_reference_ids        uuid[];
  v_row                  RECORD;
  v_customer_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_cash_session_id      uuid;
  v_cash_amount          numeric(12,2);
  v_cashbox_id           uuid;
  v_open_session_id      uuid;
  v_bank_row             RECORD;
  v_reversed_type        text;
  v_voided_doc           jsonb;   -- venta-editable-sin-cae
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_sale_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_sale_operation: se requiere p_sale_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Resolver el conjunto de filas + la clave de operación (D2) ───────────
  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_sale_ids
    FROM public.sales
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.sales
    WHERE id = p_sale_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_sale_ids
      FROM public.sales
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      -- Legacy: sin operation_id — la fila es su propia operación.
      v_operation_key := p_sale_id;
      v_sale_ids := ARRAY[p_sale_id];
    END IF;
  END IF;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- sales_order asociada (camino POS) — misma convención que el guard P0423.
  SELECT id, status INTO v_sales_order_id, v_so_status
  FROM public.sales_orders
  WHERE sale_operation_id = v_operation_key;

  v_reference_ids := ARRAY[v_operation_key];
  IF v_sales_order_id IS NOT NULL THEN
    v_reference_ids := v_reference_ids || v_sales_order_id;
  END IF;

  -- ── Guard fiscal (P0423) — MISMO helper que rpc_atomic_update_sale_operation ──
  -- venta-editable-sin-cae (D2): un comprobante pendiente que NO salió hacia
  -- ARCA se ANULA acá mismo (misma transacción que el borrado), para que el
  -- relay no lo facture después. authorized, marcado y congelado siguen
  -- bloqueando con P0423. Sigue siendo el PRIMER guard, antes de compensar
  -- cuenta corriente (P0425), caja (P0426), banco y de revertir stock — si
  -- levanta, no se tocó ningún libro.
  -- Una sola definición de la regla, compartida con la edición: dos copias
  -- divergirían y una de las dos terminaría anulando un comprobante enviado.
  v_voided_doc := public._fiscal_void_pending_for_sale_edit(
    v_sales_order_id, v_account_id, v_uid,
    format('Anulado por borrado de la venta (operación %s)', v_operation_key)
  );

  -- ── Cuenta corriente de cliente: reversión del cargo (credit_note, P0425 si negativo) ──
  SELECT customer_account_id, SUM(amount)
  INTO v_customer_account_id, v_charge_amount
  FROM public.customer_account_movements
  WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
  GROUP BY customer_account_id;

  IF v_customer_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'customer', v_customer_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder anular esta venta'
        USING ERRCODE = 'P0426';
    END IF;

    PERFORM public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'sale_reversal', v_operation_key
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled (D6) ─────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'sale' AND source_doc_ref = ANY(v_reference_ids)
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'sale', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
    PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
  END LOOP;

  -- ── Contable: emitir SaleOperationDeleted (async, vía outbox) ────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationDeleted', 'SaleOperation', v_operation_key,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_operation_key,
      'sales_order_id', v_sales_order_id,
      'occurred_at',    now()
    ),
    now()
  );

  -- ── POS: cancelar la sales_order en la misma transacción (D8) ────────────
  IF v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    UPDATE public.sales_orders
    SET status = 'canceled', sale_operation_id = NULL
    WHERE id = v_sales_order_id;

    PERFORM public.record_status_transition(
      v_account_id, 'sales_order', v_sales_order_id, 'confirmed', 'canceled',
      v_uid, COALESCE(p_reason, 'Venta eliminada')
    );
  END IF;

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(v_sale_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$;

-- ACLs re-emitidas idénticas a las vivas en prod.
REVOKE ALL     ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) TO postgres, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- (6) rpc_emit_sale_invoice — guard de PRESENCIA → guard de ESTADO (D5)
--
-- Sin este bloque la promesa "después el usuario vuelve a facturar" NO se
-- cumple: el `already_invoiced` (P0409) era incondicional al status del
-- comprobante enlazado, así que una orden con un comprobante anulado quedaba
-- muerta para siempre. De paso cierra un bug PREEXISTENTE con la misma forma:
-- una orden cuyo único comprobante quedó 'rejected' tampoco se podía volver a
-- facturar nunca.
--
-- Cuerpo VIVO de 20260801000001_emit_sale_invoice.sql
-- (md5 CR-stripped c0b01bc297f8be4e47483cff39ea987c), con DOS cambios: la
-- variable nueva en el DECLARE y el bloque de idempotencia. Firma IDÉNTICA.
--
-- Es el tramo de MAYOR RIESGO del change (R1): un error acá produce una
-- SEGUNDA FACTURA REAL. Por eso la allow-list es explícita y cerrada
-- ('rejected','voided'), NULL también bloquea, y hay FOR UPDATE sobre el
-- comprobante además del que ya se toma sobre la orden.
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_existing_status   text;   -- venta-editable-sin-cae (D5)
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

  -- Idempotencia: si ya tiene un comprobante que NO es terminal-inocuo → 409.
  -- venta-editable-sin-cae (D5): ALLOW-LIST deliberada, no deny-list. Sólo
  -- 'rejected' (nunca existió fiscalmente) y 'voided' (anulado por editar o
  -- borrar la venta, antes de salir hacia ARCA) habilitan volver a facturar.
  -- Cualquier otro valor —incluido uno que no exista hoy— BLOQUEA: un
  -- deny-list ("NOT IN (pending_cae, authorized)") convertiría un status
  -- futuro desconocido en una SEGUNDA factura real, que es el peor bug
  -- posible en este dominio (lección de #577/#580: guards cerrados por
  -- defecto). v_existing_status NULL (FK colgada, imposible hoy) bloquea igual.
  -- La orden ya está tomada con FOR UPDATE más arriba, y acá se toma también
  -- el comprobante, así que este chequeo y el UPDATE de más abajo son
  -- atómicos contra otra emisión Y contra la anulación de la edición.
  -- Efecto lateral DECLARADO y deseado: cierra el bug preexistente de que una
  -- orden cuyo único comprobante quedó 'rejected' no se podía volver a
  -- facturar NUNCA (el guard era incondicional al status).
  IF v_order.fiscal_document_id IS NOT NULL THEN
    SELECT fd.status INTO v_existing_status
    FROM   public.fiscal_documents fd
    WHERE  fd.id = v_order.fiscal_document_id
    FOR UPDATE;

    IF v_existing_status IS NULL OR v_existing_status NOT IN ('rejected', 'voided') THEN
      RAISE EXCEPTION 'already_invoiced: la orden ya tiene un comprobante fiscal asociado (fiscal_document_id=%, status=%)',
        v_order.fiscal_document_id, COALESCE(v_existing_status, 'desconocido')
        USING ERRCODE = 'P0409';
    END IF;
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

-- ACLs re-emitidas idénticas a las vivas en prod.
REVOKE ALL     ON FUNCTION public.rpc_emit_sale_invoice(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_sale_invoice(uuid, uuid) TO postgres, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- (7) Gate de introspección embebido (patrón de la casa)
--
-- Asserta lo que esta migración PROMETE, para que un reapply desordenado o una
-- reescritura futura no la apaguen en silencio. El gate de comportamiento vive
-- en supabase/tests/ (test_edicion_preserva_contexto.sql,
-- test_delete_guard_ledgers.sql y test_venta_editable_sin_cae.sql); esto es el
-- candado estructural que viaja CON la migración.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_missing text[] := '{}';
  v_def     text;
  v_count   int;
BEGIN
  -- (a) El CHECK admite los 4 valores y NO más.
  SELECT pg_get_constraintdef(oid) INTO v_def
  FROM   pg_constraint
  WHERE  conrelid = 'public.fiscal_documents'::regclass
    AND  conname  = 'fiscal_documents_status_check';

  IF v_def IS NULL THEN
    v_missing := v_missing || format('fiscal_documents_status_check NO EXISTE');
  ELSE
    IF position('voided' in v_def) = 0 THEN
      v_missing := v_missing || format('fiscal_documents_status_check no admite ''voided''');
    END IF;
    -- Cualquier status inventado tiene que seguir siendo imposible: el CHECK es
    -- una allow-list de 4, no una puerta abierta.
    IF position('pending_cae' in v_def) = 0
       OR position('authorized' in v_def) = 0
       OR position('rejected'   in v_def) = 0 THEN
      v_missing := v_missing || format('fiscal_documents_status_check perdió uno de los 3 estados previos');
    END IF;
  END IF;

  -- (b) La fila del catálogo existe, es terminal y exige motivo.
  SELECT COUNT(*) INTO v_count
  FROM   public.document_status_transitions
  WHERE  document_type = 'fiscal_document'
    AND  from_status   = 'pending_cae'
    AND  to_status     = 'voided'
    AND  is_terminal_to
    AND  requires_reason
    AND  allowed_role IS NULL;
  IF v_count <> 1 THEN
    v_missing := v_missing || format('document_status_transitions: esperaba 1 fila fiscal_document pending_cae→voided (terminal, requires_reason, allowed_role NULL), hay %s', v_count);
  END IF;

  -- Y NINGUNA otra transición hacia/desde voided: el catálogo ES el guard.
  SELECT COUNT(*) INTO v_count
  FROM   public.document_status_transitions
  WHERE  document_type = 'fiscal_document'
    AND  (to_status = 'voided' OR from_status = 'voided')
    AND  NOT (from_status = 'pending_cae' AND to_status = 'voided');
  IF v_count <> 0 THEN
    v_missing := v_missing || format('document_status_transitions: hay %s transición(es) extra hacia/desde voided — voided es TERMINAL y sólo se alcanza desde pending_cae', v_count);
  END IF;

  -- (c) El helper existe, es SECURITY DEFINER y NO es ejecutable por
  -- anon/authenticated (expuesto sería la primitiva para anular el comprobante
  -- pendiente de cualquier cuenta vía PostgREST: no valida tenencia, recibe el
  -- account_id por parámetro).
  IF to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)') IS NULL THEN
    v_missing := v_missing || format('_fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text) NO EXISTE');
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc
            WHERE oid = to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)')) THEN
      v_missing := v_missing || format('_fiscal_void_pending_for_sale_edit no es SECURITY DEFINER');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND (has_function_privilege('anon', to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)'), 'EXECUTE')
         OR has_function_privilege('authenticated', to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)'), 'EXECUTE')) THEN
      v_missing := v_missing || format('_fiscal_void_pending_for_sale_edit es ejecutable por anon/authenticated');
    END IF;
  END IF;

  -- (d) Las 3 RPCs reescritas: UNA sola definición viva (sin overload
  -- fantasma) y el guard nuevo presente en el cuerpo.
  SELECT COUNT(*) INTO v_count FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_atomic_update_sale_operation';
  IF v_count <> 1 THEN
    v_missing := v_missing || format('rpc_atomic_update_sale_operation: %s definiciones vivas (esperaba 1 — overload fantasma, gotcha 42725)', v_count);
  END IF;
  SELECT COUNT(*) INTO v_count FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_delete_sale_operation';
  IF v_count <> 1 THEN
    v_missing := v_missing || format('rpc_delete_sale_operation: %s definiciones vivas (esperaba 1)', v_count);
  END IF;
  SELECT COUNT(*) INTO v_count FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_emit_sale_invoice';
  IF v_count <> 1 THEN
    v_missing := v_missing || format('rpc_emit_sale_invoice: %s definiciones vivas (esperaba 1)', v_count);
  END IF;

  SELECT prosrc INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)');
  IF v_def IS NULL OR position('_fiscal_void_pending_for_sale_edit' in v_def) = 0 THEN
    v_missing := v_missing || format('rpc_atomic_update_sale_operation no llama al helper de anulación');
  END IF;
  -- El guard VIEJO no puede seguir vivo. El sentinel es su RAISE, NO el
  -- predicado `fd.status IN ('pending_cae','authorized')`: ese texto sigue
  -- apareciendo —legítimamente— en el bloque que re-apunta sales_orders
  -- (edicion-preserva-contexto gate 2.8), donde significa otra cosa.
  IF v_def IS NOT NULL
     AND position('comprobante fiscal emitido y no puede editarse' in v_def) > 0 THEN
    v_missing := v_missing || format('rpc_atomic_update_sale_operation conserva el RAISE del guard VIEJO (pending_cae bloquea a secas)');
  END IF;

  SELECT prosrc INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.rpc_delete_sale_operation(uuid, uuid, text)');
  IF v_def IS NULL OR position('_fiscal_void_pending_for_sale_edit' in v_def) = 0 THEN
    v_missing := v_missing || format('rpc_delete_sale_operation no llama al helper de anulación');
  END IF;
  IF v_def IS NOT NULL
     AND position('comprobante fiscal emitido y no puede borrarse' in v_def) > 0 THEN
    v_missing := v_missing || format('rpc_delete_sale_operation conserva el RAISE del guard VIEJO (pending_cae bloquea a secas)');
  END IF;

  SELECT prosrc INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.rpc_emit_sale_invoice(uuid, uuid)');
  IF v_def IS NULL OR position('NOT IN (''rejected'', ''voided'')' in v_def) = 0 THEN
    v_missing := v_missing || format('rpc_emit_sale_invoice sin la allow-list de re-emisión (rejected/voided)');
  END IF;

  -- (e) El candado que hace segura toda la carrera: claim_pending SIGUE
  -- filtrando por status='pending_cae'. Si alguien lo relaja, un comprobante
  -- ANULADO volvería a ser emitible y el relay facturaría importes viejos.
  SELECT pg_get_functiondef(to_regprocedure('public.rpc_fiscal_document_claim_pending(uuid, integer)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || format('rpc_fiscal_document_claim_pending(uuid, integer) NO EXISTE (¿cambió de firma?)');
  ELSIF position('fd.status = ''pending_cae''' in v_def) = 0 THEN
    v_missing := v_missing || format('rpc_fiscal_document_claim_pending dejó de filtrar por status=''pending_cae'': un comprobante voided volvería a ser emitible');
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.rpc_fiscal_document_mark_submit_started(uuid, bigint)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || format('rpc_fiscal_document_mark_submit_started(uuid, bigint) NO EXISTE (¿cambió de firma?)');
  ELSIF position('status = ''pending_cae''' in v_def) = 0 THEN
    v_missing := v_missing || format('rpc_fiscal_document_mark_submit_started dejó de exigir status=''pending_cae'': podría enviar a ARCA un comprobante anulado');
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIGRACION 20261060000001 (venta-editable-sin-cae) INCOMPLETA:\n  %',
      array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'venta-editable-sin-cae OK: CHECK de 4 estados, catálogo pending_cae→voided (terminal + motivo obligatorio), helper interno cerrado a anon/authenticated, 3 RPCs con una sola definición viva y el guard nuevo, y los dos candados del relay (claim_pending/mark_submit_started) intactos.';
END $$;
