-- =============================================================================
-- 20261081000001_remitos_compra_conversion.sql — remitos-compra, TANDA B
-- (governance MEDIA con tramo ALTO: extrae el núcleo del camino del dinero de
-- las compras —caja, banco, cuenta corriente del proveedor— y reescribe tres
-- funciones desde sus cuerpos VIVOS). Sign-off del PO 2026-09-29 («no necesito
-- el remito legal. Andá con todo lo recomendado») y pedido del 2026-10-14
-- («quiero que empieces con la parte B de remitos»); OQ-RC1..RC11 por su
-- recomendación. Ver openspec/changes/remitos-compra/design.md (D8, D9, D16).
--
-- Qué hace (la tanda A ya está en main: 20261071000001):
--   1. purchases.source_delivery_note_id (FK NO ACTION) + índice parcial + las
--      filas issued -> converted {purchases,stock,admin,owner} y converted ->
--      issued (sin rol: la dispara sólo el borrado de la compra) del catálogo
--      delivery_note_purchase.
--   2. trg_purchases_guard_delivery_note_source: los roles de aplicación (anon,
--      authenticated) no pueden forjar, limpiar, cambiar ni insertar el origen,
--      tocar CUALQUIER columna de una fila con origen (incluido su operation_id:
--      partir), mezclar filas en una operación con origen ni borrar filas con
--      origen: P0403 delivery_note_source_protected. SECURITY INVOKER a
--      propósito (ver el comentario de la sección 2).
--   3. _purchase_operation_core, EXTRAÍDO del pg_get_functiondef vivo de
--      rpc_create_purchase_operation: sin EXECUTE para anon ni authenticated. La
--      cuenta llega por parámetro; con p_source_delivery_note_id (modo remito) el
--      núcleo revalida el remito bajo bloqueo, LEE las líneas del remito, no toma
--      el lock del producto, no suma stock ni escribe movimientos, toma los cuatro
--      snapshots del remito, persiste el origen en cada fila y, al final y en la
--      misma transacción, deja el remito converted con su historial. La decisión
--      de no sumar stock la toma el SERVIDOR: ninguna función pública acepta un
--      parámetro de origen. rpc_create_purchase_operation queda como wrapper de la
--      misma firma de 11 parámetros, la misma ACL y el mismo rechazo sin sesión.
--      Ambos con COMMENT (el wrapper no lo tenía: cierra el candidato (g) de
--      compras-gastos-sucursal-por-defecto).
--   4. rpc_convert_delivery_note_to_purchase (nueva): lock del remito -> rol ->
--      idempotencia bajo el lock -> estado / versión -> proveedor vivo, sucursal
--      activa y no cerrada, precios > 0, fecha -> núcleo en modo remito.
--   5. rpc_delete_purchase_operation, desde el cuerpo vivo: con origen, ANTES de
--      cualquier compensación, lock del remito, relectura de las filas bajo ese
--      lock, rol de anular remitos de compra (P0403 delivery_note_purchase_delete_
--      forbidden), sucursal del remito viva (FOR SHARE, P0422), salto explícito de
--      la reversa de stock y vuelta del remito a issued con historial y motivo.
--   6. rpc_atomic_update_purchase_operation, desde el cuerpo vivo: P0423
--      delivery_note_purchase_locked antes de los tres P0423 de dinero.
--   7. _delivery_note_payload, desde el cuerpo vivo: converted_operation_id en el
--      sentido compra (derivado de purchases.source_delivery_note_id).
--   8. Bloque DO de introspección al final.
--
-- Orden de locks: la conversión toma delivery_notes PRIMERO y después sólo CREA
-- filas de compra (no bloquea filas existentes de purchases ni de products: las
-- FK de las líneas toman FOR KEY SHARE en orden ascendente de product_id, el
-- mismo orden en que la emisión, la edición y la anulación de remitos toman
-- FOR UPDATE, así que no hay ciclo). El borrado de la compra toma el remito
-- ANTES de cualquier compensación (remito -> filas de la compra -> dinero), el
-- mismo orden que la conversión (remito -> dinero).
--
-- Cuerpos de partida (checkpoint 6.1, 2026-10-14, md5 de prosrc sin \r, prod ==
-- base local construida desde los archivos): ver el bloque 0 (preflight), que
-- ABORTA si alguno cambió: otro change que redefina estas funciones (p. ej. la
-- corrección de la edición por sucursal y piso de stock) obliga a rebasar la
-- reescritura sobre el cuerpo vivo. Los diffs contra el cuerpo vivo están en
-- openspec/changes/remitos-compra/evidence/tanda-b/.
--
-- Idempotente (CI la reaplica al final de la cadena, después del último eslabón
-- de remitos): ADD COLUMN IF NOT EXISTS, FK guardada contra pg_constraint,
-- CREATE INDEX IF NOT EXISTS, catálogo con ON CONFLICT DO NOTHING, DROP TRIGGER
-- IF EXISTS + CREATE, CREATE OR REPLACE con firmas fijas (sin overload, sin
-- 42725), REVOKE/GRANT y COMMENT re-emitidos.
--
-- Gates: supabase/tests/test_remito_a_compra.sql (EJECUTA el núcleo, la
-- conversión, el borrado, la edición y el disparador del puente),
-- supabase/tests/test_remitos_compra_race.sh (carreras ampliadas) y los gates de
-- comportamiento de compras re-ejecutados sin tocarlos.
-- =============================================================================

-- =============================================================================
-- 0. Preflight: ningún cuerpo de partida cambió desde el checkpoint (6.1)
-- =============================================================================
-- Las cuatro funciones que esta migración reescribe se reescriben desde su cuerpo
-- VIVO (checkpoint 6.1, md5 de prosrc sin \r). Si otro change las redefinió en el
-- medio (p. ej. la corrección de la edición por sucursal y piso de stock, que
-- también reescribe rpc_atomic_update_purchase_operation), un CREATE OR REPLACE
-- ciego pisaría ese trabajo en silencio: se ABORTA con el md5 observado para
-- rebasar el cuerpo sobre el vivo. Idempotente: con el cuerpo de esta migración
-- ya instalado (reaplicación) sigue de largo.
DO $$
DECLARE
  v_expected jsonb := jsonb_build_object(
    'rpc_create_purchase_operation',        '361a1ffc0c3e31ee2bb1b677cfab2394',
    'rpc_delete_purchase_operation',        '368120a0d7c5453b32fbd39f095bc9c3',
    'rpc_atomic_update_purchase_operation', '2d4c92f6fd3dbfd52d2225edb0a82827',
    '_delivery_note_payload',               '56e740cd5e76a6d4a833a307c2212892');
  v_rewritten jsonb := jsonb_build_object(
    'rpc_create_purchase_operation',        '98e045e69109fe903aedd7ca2d78e448',
    'rpc_delete_purchase_operation',        'a74eac28d5f504f1e0682420b41558af',
    'rpc_atomic_update_purchase_operation', '170fc4693bf217b77c20cc4fb4602271',
    '_delivery_note_payload',               '14d1fed0853c917b00528111a5ef8291');
  v_fn  text;
  v_md5 text;
  v_ok  integer := 0;
  v_re  integer := 0;
BEGIN
  FOR v_fn IN SELECT jsonb_object_keys(v_expected) LOOP
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_md5 = (v_expected ->> v_fn) THEN
      v_ok := v_ok + 1;
    ELSIF v_md5 = (v_rewritten ->> v_fn) THEN
      v_re := v_re + 1;
    ELSE
      RAISE EXCEPTION 'remitos-compra tanda B (preflight): el cuerpo vivo de % mide % y no es ni el de partida (%) ni el de esta migración (%): otro change la redefinió — rebasá la reescritura sobre el cuerpo vivo antes de aplicar',
        v_fn, COALESCE(v_md5, '(no existe)'), v_expected ->> v_fn, v_rewritten ->> v_fn;
    END IF;
  END LOOP;
  RAISE NOTICE 'remitos-compra tanda B (preflight): % cuerpos de partida verificados por md5, % ya reaplicados', v_ok, v_re;
END $$;
-- =============================================================================
-- 20261081000001_remitos_compra_conversion.sql — remitos-compra, TANDA B
-- (governance MEDIA con tramo ALTO: extrae el núcleo del camino del dinero de
-- las compras y reescribe tres funciones desde sus cuerpos VIVOS).
--

-- =============================================================================
-- 1. Puente remito -> compra (D1) y catálogo de la tanda B (D3)
-- =============================================================================
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS source_delivery_note_id uuid;

-- NO ACTION (no RESTRICT): se verifica al final de la sentencia, así que no
-- traba un borrado de cuenta que cascadea a la vez sobre delivery_notes y
-- purchases. En la práctica equivale a RESTRICT: el remito nunca se borra.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchases_source_delivery_note_id_fkey'
      AND conrelid = 'public.purchases'::regclass
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT purchases_source_delivery_note_id_fkey
      FOREIGN KEY (source_delivery_note_id) REFERENCES public.delivery_notes (id) ON DELETE NO ACTION;
  END IF;
END $$;

-- `purchases` tiene una fila por línea: no admite un índice ÚNICO por remito. La
-- unicidad "1 remito -> 1 compra" la garantiza el estado del remito (issued ->
-- converted bajo FOR UPDATE) más el chequeo del núcleo de que no exista ninguna
-- fila con ese origen. El borrado de la compra es físico: no hay "compra
-- cancelada" que excluir. Parcial: sólo indexa las filas con origen.
CREATE INDEX IF NOT EXISTS purchases_source_delivery_note_id_idx
  ON public.purchases (source_delivery_note_id)
  WHERE source_delivery_note_id IS NOT NULL;

COMMENT ON COLUMN public.purchases.source_delivery_note_id IS
  'remitos-compra (D1/D8/D9): remito de compra del que nació la compra, en cada fila de la operación. Lo escribe sólo '
  '_purchase_operation_core (vía rpc_convert_delivery_note_to_purchase); los roles de aplicación no pueden escribirla '
  '(trg_purchases_guard_delivery_note_source). Con valor, el núcleo NO suma stock (el remito ya lo sumó) y revalidó el '
  'remito y sus líneas; rpc_delete_purchase_operation no revierte stock y devuelve el remito a issued; '
  'rpc_atomic_update_purchase_operation rechaza la edición (P0423 delivery_note_purchase_locked).';

-- Filas de la tanda B (regla del seed: cada una con su productor en esta migración).
-- issued -> converted: la produce _purchase_operation_core en modo remito.
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_purchase', 'issued', 'converted', false, false, ARRAY['purchases', 'stock', 'admin', 'owner'])
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;

-- converted -> issued, sin rol: la dispara sólo el borrado de la compra, que
-- exige admin/owner ANTES de cualquier efecto (D9). Misma exención que
-- delivery_note_sale converted -> issued de remitos-venta.
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_purchase', 'converted', 'issued', false, false, NULL)
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;


-- =============================================================================
-- 2. Integridad del puente: nadie de la aplicación escribe el origen (D9)
-- =============================================================================
-- `purchases` admite escritura por PostgREST (policies purchases_writer_* con
-- is_account_writer, sin privilegios por columna). Sin este disparador un
-- escritor podría forjar, limpiar o desviar el origen, partir o mezclar
-- operaciones por su operation_id o borrar las filas por fuera del borrado.
-- Sólo actúa cuando el que escribe ES un rol de aplicación (anon,
-- authenticated): dentro de las funciones SECURITY DEFINER (núcleo, borrado) el
-- current_user es el dueño de la función, y las acciones de FK (SET NULL) corren
-- como dueño de la tabla. Por eso es SECURITY INVOKER: current_user tiene que
-- ser el del que escribe. La búsqueda de (d) corre bajo la RLS del que escribe,
-- que le muestra las filas de SU cuenta, el único alcance que importa: el
-- borrado y la edición filtran por cuenta.
CREATE OR REPLACE FUNCTION public.trg_purchases_guard_delivery_note_source()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user NOT IN ('anon', 'authenticated') THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- (a) un INSERT con origen.
    IF NEW.source_delivery_note_id IS NOT NULL THEN
      RAISE EXCEPTION 'delivery_note_source_protected: el origen de remito de una compra lo escribe sólo la conversión del remito'
        USING ERRCODE = 'P0403';
    END IF;
    -- (d) un INSERT que lleva el operation_id de una operación con filas con origen.
    IF NEW.operation_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.purchases p
         WHERE p.operation_id = NEW.operation_id AND p.source_delivery_note_id IS NOT NULL) THEN
      RAISE EXCEPTION 'delivery_note_source_protected: no se pueden sumar filas a una compra nacida de un remito'
        USING ERRCODE = 'P0403';
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    -- (b) TODO UPDATE de una fila con origen, cambie la columna que cambie:
    -- cambiar su operation_id PARTIRÍA la compra en dos operaciones con el
    -- mismo origen (el remito quedaría inconvertible y sólo anulable, restando
    -- stock con una compra viva). Esas filas ya son inmutables por diseño (la
    -- edición da P0423): el bloqueo total no le quita nada a un camino legítimo.
    IF OLD.source_delivery_note_id IS NOT NULL THEN
      RAISE EXCEPTION 'delivery_note_source_protected: una compra nacida de un remito no se modifica: para corregirla, eliminá la compra y volvé a convertir el remito'
        USING ERRCODE = 'P0403';
    END IF;
    -- (c) un UPDATE que fija el origen en una fila que no lo tenía (forjar).
    IF NEW.source_delivery_note_id IS NOT NULL THEN
      RAISE EXCEPTION 'delivery_note_source_protected: el origen de remito de una compra lo escribe sólo la conversión del remito'
        USING ERRCODE = 'P0403';
    END IF;
    -- (d) un UPDATE que lleva operation_id a una operación con filas con origen (mezclar).
    IF NEW.operation_id IS DISTINCT FROM OLD.operation_id AND NEW.operation_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.purchases p
         WHERE p.operation_id = NEW.operation_id AND p.source_delivery_note_id IS NOT NULL) THEN
      RAISE EXCEPTION 'delivery_note_source_protected: no se pueden sumar filas a una compra nacida de un remito'
        USING ERRCODE = 'P0403';
    END IF;
    RETURN NEW;
  ELSE
    -- (e) un DELETE de una fila con origen: dejaría el remito converted para
    -- siempre, sin compra que borrar ni forma de anularlo.
    IF OLD.source_delivery_note_id IS NOT NULL THEN
      RAISE EXCEPTION 'delivery_note_source_protected: una compra nacida de un remito se elimina sólo por la eliminación de la operación'
        USING ERRCODE = 'P0403';
    END IF;
    RETURN OLD;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.trg_purchases_guard_delivery_note_source() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.trg_purchases_guard_delivery_note_source() IS
  'remitos-compra (D9): protege purchases.source_delivery_note_id de los roles de aplicación (anon, authenticated): rechaza con P0403 delivery_note_source_protected un INSERT con origen, todo UPDATE de una fila con origen (incluido cambiar su operation_id: partir), el UPDATE que fija el origen (forjar), el INSERT/UPDATE que lleva operation_id a una operación con filas con origen (mezclar) y el DELETE de filas con origen. SECURITY INVOKER a propósito: current_user tiene que ser el que escribe; dentro de las RPC SECURITY DEFINER (núcleo, borrado) no actúa.';

DROP TRIGGER IF EXISTS trg_purchases_guard_delivery_note_source ON public.purchases;
CREATE TRIGGER trg_purchases_guard_delivery_note_source
  BEFORE INSERT OR UPDATE OR DELETE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.trg_purchases_guard_delivery_note_source();



-- =============================================================================
-- 3. Núcleo de compra extraído + wrapper público (D8)
-- =============================================================================
-- Desde el pg_get_functiondef VIVO de rpc_create_purchase_operation (md5
-- 361a1ffc0c3e31ee2bb1b677cfab2394, checkpoint 6.1). El diff contra el cuerpo vivo es SÓLO la
-- extracción (la cuenta llega por parámetro) y la rama de origen (modo remito):
-- openspec/changes/remitos-compra/evidence/tanda-b/. El wrapper conserva la firma
-- de 11 parámetros, la ACL (authenticated sí, anon no) y el rechazo 42501 sin sesión.
CREATE OR REPLACE FUNCTION public._purchase_operation_core(
  p_account_id uuid, p_idempotency_key text, p_date date, p_description text, p_items jsonb,
  p_branch_id uuid, p_cost_center_id uuid, p_payment_method_id uuid, p_bank_account_id uuid,
  p_supplier_id uuid, p_cash_session_id uuid, p_due_date date, p_source_delivery_note_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  v3-snapshot-pattern: agrega name_snapshot/sku_snapshot/unit_cost_snapshot/
  iva_rate_snapshot al INSERT de purchases (D2 — el write path real de
  compra) y unit_cost_snapshot al stock_movements de compra. Preserva
  íntegro el fix de 20260804000004 (ON CONFLICT 3-col + branch_stock, sin
  products.stock).

  deudas-menores-agosto (G1): agrega la resolución del flag
  'sale_items_rpc_v2' (mismo patrón COALESCE-después-del-SELECT que
  rpc_create_sale_operation) y, condicionado por ella, el INSERT en
  purchase_items que este RPC nunca tuvo en prod.

  metodos-pago-operaciones: agrega p_payment_method_id opcional, validado
  contra el catálogo de la cuenta y persistido en todas las filas de la
  operación (mirror de p_cost_center_id).

  pagos-cableados-restantes (D7/OQ-E): el payload de PurchaseCreated ya no
  hardcodea 'payment_method':'credit' — deriva el kind real de
  p_payment_method_id (mismo SELECT que ya validaba la pertenencia, ahora
  captura también el kind) con COALESCE(..., 'credit') para preservar el
  comportamiento cuando no hay forma de pago imputada.

  pos-banco-movimientos (D5, task 5.2): agrega p_bank_account_id opcional —
  la compra por método bancario debita el ledger operativo (egreso,
  p_direction='out'), simétrico a la venta.

  compras-proveedor-cuenta-corriente (D4/D6/D8): agrega p_supplier_id opcional
  trailing — la compra pasa a saber a quién se le compró, persistido en LAS DOS
  ramas del INSERT a purchases (D4), y cuando la forma de pago imputada es de
  kind='credit' postea el cargo en la cuenta corriente del proveedor vía el
  helper compartido _pay_register_party_charge (D8).

  caja-compras-cobranzas (D2/D3): agrega p_cash_session_id opcional trailing —
  con las tres condiciones verificadas en servidor, descuenta de la caja por
  el total de la compra. Sin SQL nuevo para D3 (sucursal): p_branch_id ya se
  valida y persiste desde 20261009000001 — lo que arregla D3 vive en el
  frontend/backend Python (grupos 9/10), no acá.

  cobranzas-vencimientos (D3): agrega p_due_date opcional trailing — la
  compra a crédito transporta la fecha de negocio (p_date) y el override al
  helper compartido, que resuelve la cascada con el plazo del PROVEEDOR.

  compras-gastos-sucursal-por-defecto (D1-D3): resuelve UNA vez
  v_gate_branch := COALESCE(p_branch_id, c26_default_branch(cuenta)) y la usa en
  los dos INSERT en purchases, el delta de stock, el movimiento de stock, la
  condición de caja y el banco. Sin sucursal operativa a la cual resolver rechaza
  con P0422 no_branch_found antes de escribir nada, y una sucursal elegida cerrada
  con P0422 branch_closed.

  remitos-compra tanda B (D8): extraído como NÚCLEO INTERNO (sin EXECUTE para anon ni
  authenticated) con p_account_id y p_source_delivery_note_id. Con origen (modo remito,
  sólo desde rpc_convert_delivery_note_to_purchase) el núcleo revalida el remito bajo
  bloqueo, LEE las líneas del propio remito (p_items tiene que venir nulo), NO toma el
  lock del producto ni suma stock ni escribe movimientos (el remito ya sumó el stock),
  toma los cuatro snapshots de la línea del remito, persiste el origen en cada fila y,
  al final y en la misma transacción, pasa el remito a converted con su historial. La
  decisión la toma el servidor desde el remito validado: ningún parámetro público la
  pide. rpc_create_purchase_operation queda como wrapper de la misma firma que llama
  al núcleo con origen nulo: la compra directa es idéntica.
*/
DECLARE
    v_uid             uuid;
    v_account_id      uuid;
    v_flag_on         boolean := false;
    v_new_op_id       uuid;
    v_existing_op     uuid;
    v_item            RECORD;
    v_product         RECORD;
    v_new_purchase_id uuid;
    v_result_items    jsonb := '[]'::jsonb;
    v_qty_before      numeric;
    v_qty_after       numeric;
    v_qty_norm        numeric(15,4);
    v_stock_sum       numeric(15,4);   -- C-21: Σ branch_stock (reemplaza products.stock)
    v_inserted        integer;
    v_total_sum       numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
    v_kind            text;            -- pagos-cableados-restantes (D7)
    -- caja-compras-cobranzas (D2):
    v_cash_movement_id    uuid;
    v_cash_session_status text;
    v_cash_session_branch uuid;
    -- compras-gastos-sucursal-por-defecto (D1/D2/D3):
    v_branch              RECORD;
    v_gate_branch         uuid;
    -- remitos-compra (D8): modo remito.
    v_from_dn             boolean := (p_source_delivery_note_id IS NOT NULL);
    v_dn                  public.delivery_notes%ROWTYPE;
    v_snap_name           text;
    v_snap_sku            text;
    v_snap_cost           numeric;
    v_snap_iva            numeric;
BEGIN
    v_uid := (SELECT auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
    END IF;

    v_account_id := p_account_id;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
            USING ERRCODE = 'P0403';
    END IF;

    -- deudas-menores-agosto (G1/D1): mismo flag_key y mismo patrón que
    -- rpc_create_sale_operation — ausencia de fila = v2 (escribe línea).
    SELECT enabled INTO v_flag_on
    FROM   public.account_feature_flags
    WHERE  account_id = v_account_id
      AND  flag_key   = 'sale_items_rpc_v2'
    LIMIT  1;
    v_flag_on := COALESCE(v_flag_on, true);

    IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
    END IF;

    -- remitos-compra (D8): MODO REMITO, autosuficiente aunque hoy sólo lo use la conversión
    -- (un guard que delega no es guard). Las líneas salen del REMITO, nunca del request.
    IF v_from_dn THEN
        IF p_items IS NOT NULL THEN
            RAISE EXCEPTION 'delivery_note_items_from_source: las líneas de una compra con origen de remito salen del remito, no del request'
                USING ERRCODE = 'P0400';
        END IF;

        SELECT * INTO v_dn
        FROM   public.delivery_notes
        WHERE  id = p_source_delivery_note_id
          AND  account_id = v_account_id
          AND  direction = 'purchase'
        FOR UPDATE;

        IF NOT FOUND
           OR v_dn.status <> 'issued'
           OR p_supplier_id IS DISTINCT FROM v_dn.supplier_id
           OR p_branch_id IS DISTINCT FROM v_dn.branch_id
           OR EXISTS (SELECT 1 FROM public.purchases
                      WHERE source_delivery_note_id = p_source_delivery_note_id) THEN
            RAISE EXCEPTION 'delivery_note_purchase_mismatch: el origen % no es un remito de compra pendiente de esta cuenta, de este proveedor y de esta sucursal, sin otra compra', p_source_delivery_note_id
                USING ERRCODE = 'P0409';
        END IF;

        SELECT jsonb_agg(jsonb_build_object(
                   'product_id', i.product_id, 'amount', i.price, 'quantity', i.quantity, 'unit_id', i.unit_id,
                   'name_snapshot', i.name_snapshot, 'sku_snapshot', i.sku_snapshot,
                   'unit_cost_snapshot', i.unit_cost_snapshot, 'iva_rate_snapshot', i.iva_rate_snapshot)
               ORDER BY i.product_id, i.line_no)
        INTO   p_items
        FROM   public.delivery_note_items i
        WHERE  i.delivery_note_id = p_source_delivery_note_id
          AND  i.account_id = v_account_id;

        IF p_items IS NULL THEN
            RAISE EXCEPTION 'delivery_note_purchase_mismatch: el remito % no tiene líneas', p_source_delivery_note_id
                USING ERRCODE = 'P0409';
        END IF;
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
    END IF;

    IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
    END IF;

    -- Verify branch_id belongs to this account (if provided)
    -- compras-gastos-sucursal-por-defecto (D2/D3, OQ-2 (a)): una sucursal ELEGIDA no
    -- puede estar cerrada — el bloque literal de rpc_create_expense. Hasta este change
    -- sólo se miraba is_active y la mercadería entraba en una sucursal cerrada.
    IF p_branch_id IS NOT NULL THEN
        SELECT id, status INTO v_branch
        FROM   public.branches
        WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
        IF v_branch.status = 'closed' THEN
            RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
        END IF;
    END IF;

    -- cost-center-dimension: Verify cost_center_id belongs to this account (mirror of branch_id)
    IF p_cost_center_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.cost_centers
            WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'cost_center_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- metodos-pago-operaciones: Verify payment_method_id belongs to this account (mirror of cost_center_id).
    -- pagos-cableados-restantes (D7): el mismo SELECT que valida pertenencia
    -- ahora captura también el kind — un solo lookup, no dos.
    IF p_payment_method_id IS NOT NULL THEN
        SELECT kind INTO v_kind
        FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'payment_method_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- compras-proveedor-cuenta-corriente (D6): pertenencia del proveedor a la
    -- cuenta — mismo molde que branch_id/cost_center_id/payment_method_id.
    IF p_supplier_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.suppliers
            WHERE id = p_supplier_id AND account_id = v_account_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'supplier_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- compras-proveedor-cuenta-corriente (D6, OQ-1 opción A): no hay deuda sin
    -- acreedor. Espejo exacto de credit_requires_client del lado venta.
    IF v_kind = 'credit' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
            USING ERRCODE = 'P0400';
    END IF;

    -- compras-gastos-sucursal-por-defecto (D1/D2/D3): la sucursal que se GUARDA es la
    -- misma con la que entra el stock, se escribe el movimiento de stock, se valida la
    -- sesión de caja y se registra el movimiento bancario. Sin sucursal elegida, si la
    -- cuenta no tiene ninguna sucursal OPERATIVA a la cual resolver (ninguna sucursal,
    -- o todas inactivas o cerradas: c26_default_branch devuelve entonces su fallback no
    -- operativo), se rechaza ANTES de escribir nada. Mismo token y mismo código que la
    -- venta. Una sucursal ELEGIDA ya se validó arriba (P0404 / P0422 branch_closed). Va
    -- antes del INSERT en operation_idempotency: el rechazo no deja nada persistido.
    v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));
    IF p_branch_id IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = v_gate_branch AND account_id = v_account_id
          AND is_active = TRUE AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la compra'
            USING ERRCODE = 'P0422';
    END IF;

    v_new_op_id := gen_random_uuid();

    -- ON CONFLICT: el índice único es (user_id, operation_kind, idempotency_key).
    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
    ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'purchase'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                   jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                   '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

        -- Idempotency replay: NO emitir evento duplicado (DEC-20). caja-
        -- compras-cobranzas (D12): un replay tampoco vuelve a postear caja —
        -- el RETURN acá corta antes de llegar al bloque de caja de más abajo.
        RETURN jsonb_build_object(
            'operation_id', v_existing_op,
            'items',        v_result_items,
            'replayed',     true
        );
    END IF;

    FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                   AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid,
                        name_snapshot text, sku_snapshot text, unit_cost_snapshot numeric, iva_rate_snapshot numeric)
        ORDER BY product_id
    LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
            RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
            RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
        END IF;

        -- journal-entry-outbox: acumular total para el payload del evento
        -- (y ahora también para el egreso de caja).
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
            -- remitos-compra (D8): en modo remito se saltean el FOR UPDATE del producto, el chequeo por
            -- usuario, el de padre con variantes, la normalización y el stock (sin stock que mover, el lock
            -- del producto no protege nada y sólo sumaría superficie de interbloqueo con remitos y ventas).
            -- La existencia del producto la garantiza la FK de delivery_note_items.product_id.
            IF NOT v_from_dn THEN
                SELECT id, user_id, is_variant, name, sku, cost INTO v_product
                FROM   public.products
                WHERE  id = v_item.product_id
                FOR UPDATE;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
                END IF;

                IF v_product.user_id <> v_uid THEN
                    RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
                END IF;

                IF NOT v_product.is_variant THEN
                    IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
                        RAISE EXCEPTION
                            'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                            USING ERRCODE = 'P0422';
                    END IF;
                END IF;

                -- ventas-unidades-conversion (D1/D2): misma definición única que la venta.
                -- Tercera revisión (TOCTOU, reproducido con dos conexiones): DESPUÉS
                -- del FOR UPDATE. Normalizar antes leía la unidad base COMMITEADA
                -- mientras un cambio kg → u seguía abierto: la compra esperaba la
                -- fila y escribía 2 (kg) que se leían 2 u.
                v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

                v_snap_name := v_product.name;
                v_snap_sku  := v_product.sku;
                v_snap_cost := v_product.cost;
                v_snap_iva  := NULL;
            ELSE
                -- Los cuatro snapshots de la LÍNEA DEL REMITO (un producto renombrado o dado de baja entre la
                -- recepción y la compra conserva el nombre del remito).
                v_snap_name := v_item.name_snapshot;
                v_snap_sku  := v_item.sku_snapshot;
                v_snap_cost := v_item.unit_cost_snapshot;
                v_snap_iva  := v_item.iva_rate_snapshot;
            END IF;

            -- compras-gastos-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o
            -- la principal), la misma con la que entra el stock — no el p_branch_id crudo.
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot,
                 source_delivery_note_id)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 v_gate_branch, p_cost_center_id, p_payment_method_id,
                 p_supplier_id,
                 v_snap_name, v_snap_sku, v_snap_cost, v_snap_iva,
                 p_source_delivery_note_id)
            RETURNING id INTO v_new_purchase_id;

            IF v_flag_on THEN
                INSERT INTO public.purchase_items (
                    purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
                    name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
                ) VALUES (
                    v_new_purchase_id, v_item.product_id, v_account_id, NULL,
                    v_item.quantity, v_item.unit_id,
                    v_item.amount, v_item.amount * v_item.quantity,
                    v_snap_name, v_snap_sku, v_snap_cost, v_snap_iva
                );
            END IF;

            -- remitos-compra (D8): el stock ya lo sumó el remito al recibir; en modo remito la compra no
            -- toca branch_stock ni escribe stock_movements.
            IF NOT v_from_dn THEN
                -- stock sobre branch_stock (C-21). before/after = Σ branch_stock.
                SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
                FROM   public.branch_stock
                WHERE  product_id = v_item.product_id;

                v_qty_before := v_stock_sum;
                v_qty_after  := v_stock_sum + v_qty_norm;

                -- compras-gastos-sucursal-por-defecto (D1): v_gate_branch EXPLÍCITA. Con el NULL crudo
                -- c21 resolvía la principal por dentro (otra lectura de c26_default_branch) y, sin
                -- ninguna sucursal, creaba "Casa Central" al vuelo.
                PERFORM public.c21_apply_branch_stock_delta(
                    v_account_id, v_item.product_id, v_gate_branch, v_qty_norm);

                INSERT INTO public.stock_movements (
                    user_id, account_id, product_id, product_name, type,
                    quantity_delta, quantity_before, quantity_after,
                    reference_id, reference_type, performed_by,
                    operation_group_id, branch_id, unit_cost_snapshot
                ) VALUES (
                    v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                    v_qty_norm, v_qty_before, v_qty_after,
                    v_new_purchase_id, 'purchase', v_uid,
                    -- compras-gastos-sucursal-por-defecto (D1): el movimiento lleva v_gate_branch, la
                    -- misma sucursal que el delta de stock y que la fila de la compra.
                    v_new_op_id, v_gate_branch, v_product.cost
                );
            END IF;

        ELSE
            IF v_from_dn THEN
                RAISE EXCEPTION 'delivery_note_purchase_mismatch: el remito % tiene una línea sin producto', p_source_delivery_note_id
                    USING ERRCODE = 'P0409';
            END IF;
            -- Línea sin producto: no mueve stock; la unidad se sigue validando (P0404).
            PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
            -- compras-gastos-sucursal-por-defecto (D1/D2): también la línea de servicio guarda
            -- v_gate_branch.
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 v_gate_branch, p_cost_center_id, p_payment_method_id,
                 p_supplier_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
    -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
    -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
    -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
    -- venta de 665,334 y una factura de round(Σ) = 665,33.
    v_total_sum := round(v_total_sum, 2);

    -- ── caja-compras-cobranzas (D2) — OPT-IN DE CAJA, 3 condiciones ───────────
    -- Copiado LITERAL del molde de rpc_create_expense: mismos tres tokens de
    -- error, mismo orden, y p_date (`date`) comparado DIRECTO contra
    -- reporting_local_today() — PROHIBIDO castear a timestamptz (el ::date
    -- implícito usaría la timezone del servidor/UTC, y una compra cargada
    -- entre las 21:00 y las 23:59 de Mendoza se rechazaría con P0422 justo
    -- cuando el usuario sabe que es hoy).
    --
    -- compras-gastos-sucursal-por-defecto (D1): "Sucursal efectiva de la compra" =
    -- v_gate_branch (la elegida o, sin elegir, la principal operativa), la misma que se
    -- persiste y con la que entra el stock — como el gasto y la venta. Antes de este
    -- change se comparaba contra el valor CRUDO: una compra sin sucursal no satisfacía la
    -- condición para ninguna caja real, y el formulario ofrece la sesión de la principal
    -- PRE-MARCADA, así que toda compra en efectivo sin sucursal elegida se rechazaba.
    IF p_cash_session_id IS NOT NULL THEN
        IF v_kind IS DISTINCT FROM 'cash' THEN
            RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
                USING ERRCODE = 'P0422';
        END IF;

        SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
        FROM public.cash_sessions cs
        JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
        WHERE cs.id = p_cash_session_id;

        IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
            RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la compra'
                USING ERRCODE = 'P0422';
        END IF;

        IF p_date <> public.reporting_local_today() THEN
            RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una compra fechada hoy (%)', public.reporting_local_today()
                USING ERRCODE = 'P0422';
        END IF;

        v_cash_movement_id := public.c28_register_cash_movement(
            p_cash_session_id, -v_total_sum, 'purchase_payment', v_new_op_id, p_description
        );
    END IF;
    -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

    -- pos-banco-movimientos (D5, task 5.2): movimiento bancario operativo de
    -- EGRESO — v_kind CRUDO.
    -- compras-gastos-sucursal-por-defecto (D1): lleva v_gate_branch (la sucursal EFECTIVA, la
    -- misma que se persistió en la compra), como el gasto y la venta.
    PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'out', 'purchase', v_new_op_id,
        p_date, v_gate_branch, NULL
    );

    -- compras-proveedor-cuenta-corriente (D8): cargo en la cuenta corriente
    -- del proveedor. cobranzas-vencimientos (D3): transporta la fecha de
    -- negocio y el override — la cascada (plazo del PROVEEDOR) vive en el helper.
    IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
            v_account_id, 'supplier', p_supplier_id, v_total_sum, v_new_op_id, v_new_op_id,
            p_date, p_due_date
        );
    END IF;

    -- ── journal-entry-outbox (Task 4.1): emitir PurchaseCreated en la misma tx ─
    INSERT INTO public.events
        (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
        v_account_id,
        'PurchaseCreated',
        'Purchase',
        v_new_op_id,
        jsonb_build_object(
            'account_id',     v_account_id,
            'operation_id',   v_new_op_id,
            'total',          v_total_sum,
            'cost_center_id', p_cost_center_id,
            'neto',           NULL,
            'iva_amount',     NULL,
            'payment_method', COALESCE(v_kind, 'credit'),
            'occurred_at',    now()
        ),
        now()
    );

    -- remitos-compra (D8, molde de la revisión adversarial RB-02 de remitos-venta): el remito de
    -- origen queda `converted` EN EL NÚCLEO, en la misma transacción que crea la compra y bajo el
    -- mismo lock del remito, y sólo por el camino que crea la compra (un replay de idempotencia
    -- devolvió antes). Si quedara en el caller, uno futuro que lo omitiera dejaría una compra con
    -- origen y el remito issued: editable y anulable, y la anulación restaría stock que esa compra da
    -- por recibido. No sube la revisión (no cambia el contenido). El allowed_role de la fila
    -- issued -> converted se evalúa contra el actor.
    IF v_from_dn THEN
        PERFORM public.record_status_transition(
            v_account_id, 'delivery_note_purchase', p_source_delivery_note_id, 'issued', 'converted', v_uid, NULL);
        UPDATE public.delivery_notes
        SET    status = 'converted', updated_at = now(), updated_by = v_uid
        WHERE  id = p_source_delivery_note_id;
    END IF;

    RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._purchase_operation_core(uuid, text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._purchase_operation_core(uuid, text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date, uuid) IS
  $c$remitos-compra (D8): núcleo transaccional de la compra, extraído del cuerpo vivo de rpc_create_purchase_operation (361a1ffc…) con p_account_id y p_source_delivery_note_id. INTERNO: sin EXECUTE para anon ni authenticated (lo llaman sólo rpc_create_purchase_operation —origen nulo: la compra directa, idéntica— y rpc_convert_delivery_note_to_purchase). Con origen (modo remito) revalida el remito bajo bloqueo (cuenta, sentido compra, issued, mismo proveedor y sucursal, sin otra compra con ese origen: P0409 delivery_note_purchase_mismatch), exige p_items nulo (P0400 delivery_note_items_from_source), LEE las líneas del propio remito, NO toma el lock del producto ni suma stock ni escribe movimientos, toma los cuatro snapshots de la línea del remito, persiste purchases.source_delivery_note_id y deja el remito converted con su historial en la misma transacción. Caja, banco, cuenta corriente del proveedor, idempotencia, total y PurchaseCreated: como la compra directa.$c$;

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_supplier_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_uid        uuid;
    v_account_id uuid;
BEGIN
    v_uid := (SELECT auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT cai INTO v_account_id
    FROM   current_account_ids() AS cai
    LIMIT  1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
            USING ERRCODE = 'P0403';
    END IF;

    -- remitos-compra (D8): wrapper de la misma firma, ACL y rechazo sin sesión. TODA la lógica
    -- vive en _purchase_operation_core; acá NO hay ningún parámetro de origen de remito.
    RETURN public._purchase_operation_core(
        v_account_id, p_idempotency_key, p_date, p_description, p_items,
        p_branch_id, p_cost_center_id, p_payment_method_id, p_bank_account_id,
        p_supplier_id, p_cash_session_id, p_due_date, NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) TO authenticated;
COMMENT ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) IS
  $c$remitos-compra (D8): wrapper público de la compra directa, de la misma firma, ACL y rechazo sin sesión (42501) que antes. Resuelve la cuenta (current_account_ids() LIMIT 1) y llama a _purchase_operation_core con origen nulo: TODA la lógica de la compra (idempotencia DEC-06, validaciones, stock, caja, banco, cuenta corriente, evento) vive en el núcleo. No acepta ningún parámetro de origen de remito.$c$;

-- =============================================================================
-- 4. rpc_convert_delivery_note_to_purchase (D8)
-- =============================================================================
-- Molde de rpc_convert_delivery_note_to_sale: lock del remito -> rol -> idempotencia
-- bajo el lock -> estado / versión -> guards propios (proveedor vivo, sucursal
-- activa y no cerrada, precios > 0, fecha) -> núcleo de compra en modo remito
-- (que crea la compra SIN sumar stock y deja el remito converted). Sin
-- p_branch_id ni p_supplier_id: la compra se imputa a la sucursal y al proveedor
-- del remito.
CREATE OR REPLACE FUNCTION public.rpc_convert_delivery_note_to_purchase(
  p_idempotency_key   text,
  p_delivery_note_id  uuid,
  p_expected_revision integer,
  p_payment_method_id uuid,
  p_date              date DEFAULT NULL,
  p_cash_session_id   uuid DEFAULT NULL,
  p_bank_account_id   uuid DEFAULT NULL,
  p_cost_center_id    uuid DEFAULT NULL,
  p_due_date          date DEFAULT NULL,
  p_description       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_dn           public.delivery_notes%ROWTYPE;
  v_existing_op  uuid;
  v_date         date;
  v_label        text;
  v_result       jsonb;
  v_op           uuid;
BEGIN
  -- 1. Entrada
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;
  IF p_payment_method_id IS NULL THEN
    RAISE EXCEPTION 'payment_method_required: la conversión exige una forma de pago del catálogo'
      USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se convierte'
      USING ERRCODE = 'P0400';
  END IF;

  -- 2. Lock del documento de origen primero (ajeno, inexistente o de venta =
  -- no encontrado), después el rol de la transición issued -> converted.
  SELECT * INTO v_dn
  FROM public.delivery_notes
  WHERE id = p_delivery_note_id
    AND account_id IN (SELECT public.current_account_ids())
    AND direction = 'purchase'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role_dir(v_dn.account_id, 'convert', 'purchase');

  v_label := 'RC-' || lpad(v_dn.number::text, 8, '0');

  -- 3. Idempotencia, leída bajo el lock: el doble clic sobre el mismo remito
  -- espera el lock de arriba y hace replay (ya converted: responde antes de
  -- mirar el estado). Una clave ya usada por OTRA operación (otro remito, una
  -- compra directa) es un conflicto.
  SELECT oi.operation_id INTO v_existing_op
  FROM public.operation_idempotency oi
  WHERE oi.user_id = v_uid
    AND oi.operation_kind = 'purchase'
    AND oi.idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF NOT EXISTS (
         SELECT 1 FROM public.purchases p
         WHERE p.operation_id = v_existing_op
           AND p.source_delivery_note_id = p_delivery_note_id
           AND p.account_id = v_dn.account_id) THEN
      RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
        USING ERRCODE = 'P0409';
    END IF;
    RETURN jsonb_build_object(
      'delivery_note_id',     p_delivery_note_id,
      'delivery_note_number', v_dn.number,
      'operation_id',         v_existing_op,
      'total',                (SELECT round(COALESCE(sum(p.total), 0), 2) FROM public.purchases p
                               WHERE p.operation_id = v_existing_op AND p.account_id = v_dn.account_id),
      'replayed',             true
    );
  END IF;

  -- 4. Estado y versión, sobre la fila bloqueada.
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede convertir', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  -- 5. Guards autosuficientes (no delegan en el guard de baja de sucursal).
  -- Proveedor vivo: una compra a crédito cargaría deuda contra un proveedor que
  -- el directorio ya no muestra. Los productos dados de baja después de recibir
  -- SE CONVIERTEN: la mercadería ya entró.
  IF NOT EXISTS (
    SELECT 1 FROM public.suppliers s
    WHERE s.id = v_dn.supplier_id
      AND s.account_id = v_dn.account_id
      AND s.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'delivery_note_supplier_unavailable: el proveedor del remito fue dado de baja: editá el remito y elegí un proveedor vigente'
      USING ERRCODE = 'P0404';
  END IF;
  -- Sucursal del remito activa y no cerrada (el núcleo sólo rechaza 'closed').
  IF NOT EXISTS (
    SELECT 1 FROM public.branches b
    WHERE b.id = v_dn.branch_id
      AND b.account_id = v_dn.account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'branch_closed: la sucursal del remito está desactivada o cerrada — reactivala para convertir el remito'
      USING ERRCODE = 'P0422';
  END IF;
  -- Todos los precios cargados: el núcleo de compra rechaza amount <= 0 (el
  -- remito admite precio 0 al recibir; la conversión, no).
  IF EXISTS (
    SELECT 1 FROM public.delivery_note_items i
    WHERE i.delivery_note_id = v_dn.id AND i.price <= 0
  ) THEN
    RAISE EXCEPTION 'delivery_note_price_required: cargá el precio de compra de todas las líneas antes de convertir el remito en compra'
      USING ERRCODE = 'P0400';
  END IF;
  -- La fecha de la compra: por defecto hoy; la compra no puede preceder a la
  -- recepción que documenta. La caja sigue exigiendo hoy (en el núcleo).
  v_date := COALESCE(p_date, public.reporting_local_today());
  IF v_date < v_dn.issued_on THEN
    RAISE EXCEPTION 'delivery_note_purchase_date_before_receipt: la compra no puede ser anterior a la fecha de recepción del remito (%)', v_dn.issued_on
      USING ERRCODE = 'P0400';
  END IF;

  -- 6. La compra, con el núcleo en modo remito: sin p_items (las líneas salen
  -- del remito), sin stock, y el remito queda converted dentro del núcleo.
  v_result := public._purchase_operation_core(
    v_dn.account_id,
    p_idempotency_key,
    v_date,
    COALESCE(p_description, 'Remito ' || v_label),
    NULL,
    v_dn.branch_id,
    p_cost_center_id,
    p_payment_method_id,
    p_bank_account_id,
    v_dn.supplier_id,
    p_cash_session_id,
    p_due_date,
    v_dn.id
  );

  -- La misma clave usada en paralelo sobre OTRO documento: el núcleo esperó el
  -- ON CONFLICT y devolvió la operación ajena sin crear ésta.
  IF COALESCE((v_result->>'replayed')::boolean, false) THEN
    RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
      USING ERRCODE = 'P0409';
  END IF;

  v_op := (v_result->>'operation_id')::uuid;

  -- 7. Resultado (la transición issued -> converted ya la hizo el núcleo, en
  -- la misma transacción).
  RETURN jsonb_build_object(
    'delivery_note_id',     v_dn.id,
    'delivery_note_number', v_dn.number,
    'operation_id',         v_op,
    'total',                (SELECT round(COALESCE(sum(p.total), 0), 2) FROM public.purchases p
                             WHERE p.operation_id = v_op AND p.account_id = v_dn.account_id),
    'replayed',             false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_convert_delivery_note_to_purchase(text, uuid, integer, uuid, date, uuid, uuid, uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_convert_delivery_note_to_purchase(text, uuid, integer, uuid, date, uuid, uuid, uuid, date, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_convert_delivery_note_to_purchase(text, uuid, integer, uuid, date, uuid, uuid, uuid, date, text) IS
  'remitos-compra (D8, R8): convierte un remito de compra issued en una compra con un toque, SIN volver a sumar el stock. '
  'Lock del remito (ajeno, de venta o inexistente = P0404 delivery_note_not_found) -> rol issued->converted del catálogo '
  '({purchases,stock,admin,owner}, P0401/P0403) -> idempotencia bajo el lock (replay; otra operación -> P0409 '
  'idempotency_key_conflict) -> estado (P0409 delivery_note_invalid_state) y versión (P0409 delivery_note_changed) '
  '-> proveedor vivo (P0404 delivery_note_supplier_unavailable) -> sucursal del remito activa y no cerrada (P0422 '
  'branch_closed) -> todos los precios > 0 (P0400 delivery_note_price_required) -> fecha no anterior al remito (P0400 '
  'delivery_note_purchase_date_before_receipt) -> _purchase_operation_core con origen (que crea la compra con las líneas '
  'y los snapshots del remito, sin tocar el stock, y deja el remito converted con su historial). La compra mueve caja '
  '(tres condiciones), banco y cuenta corriente del proveedor (vencimiento por cascada) como una compra directa. '
  'Devuelve {delivery_note_id, delivery_note_number, operation_id, total, replayed}.';


-- =============================================================================
-- 5. rpc_delete_purchase_operation desde el cuerpo vivo (D9)
-- =============================================================================
-- Desde el pg_get_functiondef VIVO (md5 368120a0d7c5453b32fbd39f095bc9c3). Con origen de remito:
-- lock del remito ANTES de cualquier compensación, relectura de las filas bajo
-- ese lock, rol de anular remitos de compra, sucursal del remito viva (FOR
-- SHARE), salto explícito de la reversa de stock y vuelta del remito a issued.
CREATE OR REPLACE FUNCTION public.rpc_delete_purchase_operation(p_purchase_id uuid DEFAULT NULL::uuid, p_operation_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_purchase_ids         uuid[];
  v_row                  RECORD;
  v_supplier_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_bank_row             RECORD;
  v_reversed_type        text;
  -- caja-compras-cobranzas (D7):
  v_cashbox_id           uuid;
  v_cash_amount          numeric(12,2);
  v_open_session_id      uuid;
  v_cash_reversal_id     uuid;
  -- remitos-compra (D9): compra nacida de un remito.
  v_origins              uuid[];
  v_direct_rows          integer;
  v_source_dn            uuid;
  v_dn                   public.delivery_notes%ROWTYPE;
  v_dn_label             text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_purchase_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_purchase_operation: se requiere p_purchase_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_purchase_ids
    FROM public.purchases
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.purchases
    WHERE id = p_purchase_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_purchase_ids
      FROM public.purchases
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      v_operation_key := p_purchase_id;
      v_purchase_ids := ARRAY[p_purchase_id];
    END IF;
  END IF;

  IF v_purchase_ids IS NULL OR array_length(v_purchase_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- ── remitos-compra (D9): compra nacida de un remito ─────────────────────────
  -- ANTES de cualquier compensación: lock del remito de origen (leído con la cuenta del usuario y
  -- el sentido compra). Es el mismo orden que la conversión (remito -> dinero), así que no hay
  -- ciclo; tomarlo al final no serializaría dos borrados de la misma compra ni un borrado viejo
  -- contra una reconversión, y a crédito invertiría el orden (cuenta corriente -> remito contra
  -- remito -> cuenta corriente: interbloqueo). Un origen de otra cuenta o de venta NUNCA se reabre.
  SELECT array_agg(DISTINCT p.source_delivery_note_id) FILTER (WHERE p.source_delivery_note_id IS NOT NULL),
         count(*) FILTER (WHERE p.source_delivery_note_id IS NULL)
    INTO v_origins, v_direct_rows
  FROM public.purchases p
  WHERE p.id = ANY(v_purchase_ids);

  IF v_origins IS NOT NULL THEN
    -- Los caminos legítimos nunca mezclan orígenes; el disparador del puente cierra los dos
    -- caminos por PostgREST que sí podrían (partir y mezclar operation_id). Defensa en
    -- profundidad frente a una escritura como postgres.
    IF array_length(v_origins, 1) <> 1 OR v_direct_rows > 0 THEN
      RAISE EXCEPTION 'delivery_note_purchase_mismatch: la operación mezcla filas con y sin remito de origen, o de orígenes distintos'
        USING ERRCODE = 'P0409';
    END IF;
    v_source_dn := v_origins[1];

    SELECT * INTO v_dn
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn
      AND dn.account_id = v_account_id
      AND dn.direction = 'purchase'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_purchase_mismatch: el origen % no es un remito de compra de esta cuenta', v_source_dn
        USING ERRCODE = 'P0409';
    END IF;

    -- Bajo el lock del remito se vuelven a leer las filas de la operación: si otro borrado ganó,
    -- ya no existen y éste termina sin efectos, con el mismo resultado que hoy para una
    -- operación inexistente.
    SELECT array_agg(s.id) INTO v_purchase_ids
    FROM (
      SELECT p.id
      FROM public.purchases p
      WHERE p.id = ANY(v_purchase_ids) AND p.account_id = v_account_id
      ORDER BY p.id
      FOR UPDATE
    ) s;
    IF v_purchase_ids IS NULL OR array_length(v_purchase_ids, 1) IS NULL THEN
      RETURN false;
    END IF;

    IF v_dn.status <> 'converted' THEN
      RAISE EXCEPTION 'delivery_note_purchase_mismatch: el remito % está % y no convertido: la compra no se puede reabrir', v_source_dn, v_dn.status
        USING ERRCODE = 'P0409';
    END IF;

    v_dn_label := 'RC-' || lpad(v_dn.number::text, 8, '0');

    -- Borrar la compra reabre el remito y lo deja anulable: tan sensible como anularlo, así que
    -- exige el mismo rol (administrador o dueño). Literal propio para que la UI lo traduzca.
    BEGIN
      PERFORM public._delivery_note_assert_role_dir(v_account_id, 'void', 'purchase');
    EXCEPTION WHEN SQLSTATE 'P0401' OR SQLSTATE 'P0403' THEN
      RAISE EXCEPTION 'delivery_note_purchase_delete_forbidden: borrar esta compra reabre el remito % y lo deja anulable: requiere administrador o dueño', v_dn_label
        USING ERRCODE = 'P0403';
    END;

    -- La sucursal del remito, activa y no cerrada (FOR SHARE: una desactivación concurrente espera
    -- a este commit). El guard de baja no cuenta los remitos converted: sin esto, borrar la compra
    -- reabriría el remito en una sucursal muerta.
    PERFORM 1
    FROM public.branches b
    WHERE b.id = v_dn.branch_id
      AND b.account_id = v_account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito % está desactivada o cerrada — reactivala antes de eliminar la compra', v_dn_label
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- ── Cuenta corriente de proveedor: reversión del cargo (debit_note, P0425 si negativo) ──
  SELECT supplier_account_id, SUM(amount)
  INTO v_supplier_account_id, v_charge_amount
  FROM public.supplier_account_movements
  WHERE reference_id = v_operation_key AND movement_type = 'purchase'
  GROUP BY supplier_account_id;

  IF v_supplier_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'supplier', v_supplier_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── caja-compras-cobranzas (D7) — CAJA: contra-movimiento por EXISTENCIA ──
  -- Molde exacto de rpc_delete_expense. ⚠️ El guard es `<> 0`, NUNCA `> 0` ni
  -- `< 0`: existe movimiento de caja de la compra ⇒ SIEMPRE se compensa,
  -- cualquiera sea el signo. Condicionarlo al signo esperado dejaría pasar el
  -- borrado sin compensar y SIN levantar P0426 (el modo de falla exacto que
  -- motivó delete-guard-ledgers). La sesión ORIGINAL nunca se toca —
  -- append-only (RN-99); el contra-movimiento va SIEMPRE a la sesión abierta
  -- ACTUAL de la MISMA caja.
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = v_operation_key AND movement_type = 'purchase_payment'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount <> 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar esta compra'
        USING ERRCODE = 'P0426';
    END IF;

    -- El movimiento de la compra es NEGATIVO (egreso), así que -v_cash_amount
    -- da el INGRESO positivo que repone la plata en el cajón. Si por
    -- cualquier camino llegara con el signo contrario, la contra-partida sale
    -- negativa y compensa igual: el opuesto exacto de lo posteado.
    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'purchase_payment_reversal', v_operation_key, 'Reversión por borrado de compra'
    );
  END IF;
  -- ── FIN CAJA ───────────────────────────────────────────────────────────────

  -- ── Banco: espejo con dirección invertida ─────────────────────────────────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'purchase' AND source_doc_ref = v_operation_key
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'purchase', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  -- remitos-compra (D9): una compra nacida de un remito NO revierte stock: la mercadería quedó
  -- recibida con el remito, que vuelve a pendiente más abajo (para sacarla del stock se anula el
  -- remito). El salto es explícito: no depende de que esas filas no tengan movimientos propios.
  IF v_source_dn IS NULL THEN
    FOR v_row IN SELECT unnest(v_purchase_ids) AS id LOOP
      PERFORM public.rpc_reverse_stock_movement(v_row.id, 'purchase', COALESCE(p_reason, 'Compra eliminada'));
    END LOOP;
  END IF;

  -- ── Contable: emitir PurchaseDeleted (async, vía outbox) ──────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'PurchaseDeleted', 'Purchase', v_operation_key,
    jsonb_build_object(
      'account_id',   v_account_id,
      'operation_id', v_operation_key,
      'occurred_at',  now()
    ),
    now()
  );

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(v_purchase_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  -- ── remitos-compra (D9, R5): el remito vuelve a pendiente ────────────────
  -- Con el remito bloqueado desde el principio. Sin filas con ese origen, se puede volver a
  -- convertir. La transición converted -> issued no tiene rol propio: este borrado ya exigió
  -- administrador o dueño ANTES de cualquier efecto.
  IF v_source_dn IS NOT NULL THEN
    PERFORM public.record_status_transition(
      v_account_id, 'delivery_note_purchase', v_source_dn, 'converted', 'issued',
      v_uid, format('Compra eliminada (operación %s)', v_operation_key)
    );
    UPDATE public.delivery_notes
    SET status = 'issued', updated_at = now(), updated_by = v_uid
    WHERE id = v_source_dn;
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) IS
  $c$caja-compras-cobranzas (D7): suma la pata de caja como segunda compensación
  (después de cuenta corriente, antes de banco) — contra-movimiento
  purchase_payment_reversal por existencia (no por signo), P0426 si no hay
  sesión abierta en esa caja. Orden final: cta cte → caja → banco → stock →
  evento → DELETE.
  remitos-compra (D9): con filas de origen de remito, ANTES de cualquier compensación bloquea el remito (cuenta + sentido compra, FOR UPDATE), relee las filas bajo ese lock (si ya no existen termina sin efectos), exige status converted, el rol de anular remitos de compra (admin/owner: P0403 delivery_note_purchase_delete_forbidden) y la sucursal del remito activa y no cerrada (FOR SHARE, P0422 delivery_note_branch_inactive); salta la reversa de stock (el remito ya lo sumó) y devuelve el remito a issued con historial y motivo. Un origen de otra cuenta, de venta o mezclado da P0409 delivery_note_purchase_mismatch.$c$;


-- =============================================================================
-- 6. rpc_atomic_update_purchase_operation desde el cuerpo vivo (D9)
-- =============================================================================
-- Desde el pg_get_functiondef VIVO (md5 2d4c92f6fd3dbfd52d2225edb0a82827). Sólo agrega el P0423
-- delivery_note_purchase_locked, después del chequeo de existencia y ANTES de los
-- tres P0423 de dinero.
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_supplier_id uuid DEFAULT NULL::uuid, p_supplier_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_old_purchase    RECORD;
  v_item            RECORD;
  v_product         RECORD;
  v_new_op_id       uuid;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_flag_on         boolean;
  v_old_snapshots   jsonb;
  v_prev_snap       jsonb;
  v_line_snap       jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
  v_reverse_delta     numeric;         -- ventas-unidades-conversion (D6)
  v_apply_qty_norm    numeric(15,4);   -- ventas-unidades-conversion (D1)
  v_old_payment_method_id   uuid;
  v_final_payment_method_id uuid;
  v_old_branch_id      uuid;
  v_old_supplier_id    uuid;
  v_old_cost_center_id uuid;
  v_final_branch_id    uuid;
  v_branch             RECORD;
  v_final_supplier_id    uuid;
  v_final_cost_center_id uuid;
  v_old_kind             text;
  v_final_kind           text;
  v_dn_label             text;   -- remitos-compra (D9): remito de origen de la compra
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede actualizar la operación'
      USING ERRCODE = 'P0403';
  END IF;

  IF array_length(p_purchase_ids, 1) IS NULL OR array_length(p_purchase_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No purchase IDs provided' USING ERRCODE = 'P0400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.purchases
    WHERE id = ANY(p_purchase_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: purchase belongs to another user' USING ERRCODE = 'P0403';
  END IF;

  IF (SELECT COUNT(*) FROM public.purchases WHERE id = ANY(p_purchase_ids))
      != array_length(p_purchase_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- remitos-compra (D9): una compra nacida de un remito NO se edita. El editor siempre reemplaza
  -- líneas (REVERSE + APPLY) y la REVERSE, sin movimiento propio de esas filas, cae a la
  -- normalización de la línea y RESTARÍA stock que el remito sigue aportando (la APPLY lo sumaría
  -- de nuevo; una reducción dejaría stock restado de más, y la anulación del remito lo restaría
  -- otra vez). Va ANTES de los tres P0423 de dinero —es el motivo más específico: una compra de
  -- remito a crédito recibiría si no el de cuenta corriente, que manda a "borrar y volver a
  -- cargar" sin explicar el remito— y bloquea la operación ENTERA, también la cabecera.
  SELECT COALESCE('RC-' || lpad(dn.number::text, 8, '0'), 'de origen') INTO v_dn_label
  FROM   public.purchases p
  JOIN   public.delivery_notes dn ON dn.id = p.source_delivery_note_id
  WHERE  p.id = ANY(p_purchase_ids)
    AND  p.account_id = v_account_id
  LIMIT  1;

  IF FOUND THEN
    RAISE EXCEPTION 'delivery_note_purchase_locked: la compra nació del remito %: para corregirla, eliminá la compra, editá el remito y volvé a convertirlo', v_dn_label
      USING ERRCODE = 'P0423';
  END IF;

  -- pagos-cableados-restantes (D6, task 9.3): inmutabilidad por cargo de
  -- cuenta corriente posteado.
  IF EXISTS (
    SELECT 1
    FROM public.supplier_account_movements sam
    WHERE sam.reference_id IN (
      SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_account_charge_immutable: compra con cargo en cuenta corriente del proveedor posteado — borrá esta compra (revierte el cargo y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.2): inmutabilidad por movimiento
  -- bancario posteado.
  IF EXISTS (
    SELECT 1
    FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'purchase'
      AND bm.source_doc_ref IN (
        SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_bank_movement_immutable: la operación tiene un movimiento bancario posteado y no puede editarse — registrá el ajuste en el ledger bancario y una compra nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- caja-compras-cobranzas (D8): tercer término del guard P0423 — la compra
  -- que ya descontó de la caja también pasa a ser inmutable. Antes de este
  -- change este caso era INALCANZABLE (ningún camino de alta producía un
  -- movimiento de caja de compra), así que agregarlo no cambia el
  -- comportamiento de ninguna compra existente.
  IF EXISTS (
    SELECT 1
    FROM public.cash_movements cm
    WHERE cm.movement_type = 'purchase_payment'
      AND cm.reference_id IN (
        SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_cash_movement_immutable: la compra descontó de la caja y no puede editarse — borrá esta compra (revierte la caja y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  SELECT COALESCE(jsonb_object_agg(t.product_id::text, t.snap), '{}'::jsonb)
  INTO   v_old_snapshots
  FROM (
    SELECT DISTINCT ON (p.product_id)
           p.product_id,
           jsonb_build_object(
             'name_snapshot',       COALESCE(pi.name_snapshot, p.name_snapshot),
             'sku_snapshot',        COALESCE(pi.sku_snapshot, p.sku_snapshot),
             'unit_cost_snapshot',  COALESCE(pi.unit_cost_snapshot, p.unit_cost_snapshot),
             'iva_rate_snapshot',   COALESCE(pi.iva_rate_snapshot, p.iva_rate_snapshot),
             'snapshot_backfilled', COALESCE(pi.snapshot_backfilled, p.snapshot_backfilled, false)
           ) AS snap
    FROM   public.purchases p
    LEFT JOIN public.purchase_items pi
           ON pi.purchase_id = p.id AND pi.product_id = p.product_id
    WHERE  p.id = ANY(p_purchase_ids)
      AND  p.product_id IS NOT NULL
      AND  (COALESCE(pi.unit_cost_snapshot, p.unit_cost_snapshot) IS NOT NULL
            OR COALESCE(pi.name_snapshot, p.name_snapshot) IS NOT NULL)
    ORDER BY p.product_id, p.id
  ) t;

  SELECT payment_method_id INTO v_old_payment_method_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
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

  SELECT branch_id, supplier_id, cost_center_id
  INTO   v_old_branch_id, v_old_supplier_id, v_old_cost_center_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
  LIMIT  1;

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

  -- compras-gastos-sucursal-por-defecto (D2/D5): para la COMPRA, NULL significa "la
  -- principal". Ni la intención de desimputar (p_branch_provided con NULL) ni una fila
  -- vigente sin sucursal (compra histórica) se preservan: se resuelve a la principal
  -- operativa ANTES del REVERSE, igual que la validación de arriba (gate 2.9 de
  -- edicion-preserva-contexto: una edición inválida no revierte ni reaplica stock).
  -- Una sucursal vigente no nula se preserva sin revalidar, como hoy; una explícita
  -- inválida sigue dando P0422 branch_invalid. El REVERSE de una fila NULL ya caía en la
  -- principal vigente (op_stock_movement) y el APPLY suma en esa misma sucursal: el neto
  -- es cero. El gasto aplica la misma regla en rpc_update_expense.
  IF v_final_branch_id IS NULL THEN
    v_final_branch_id := public.c26_default_branch(v_account_id);
    IF v_final_branch_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id
        AND is_active = TRUE AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la compra'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  IF p_supplier_provided THEN
    IF p_supplier_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.suppliers
        WHERE id = p_supplier_id AND account_id = v_account_id AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'supplier_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_supplier_id := p_supplier_id;
  ELSE
    v_final_supplier_id := v_old_supplier_id;
  END IF;

  IF p_cost_center_provided THEN
    IF p_cost_center_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.cost_centers
        WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
      ) THEN
        RAISE EXCEPTION 'cost_center_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_cost_center_id := p_cost_center_id;
  ELSE
    v_final_cost_center_id := v_old_cost_center_id;
  END IF;

  SELECT kind INTO v_final_kind
  FROM   public.payment_methods
  WHERE  id = v_final_payment_method_id;

  SELECT kind INTO v_old_kind
  FROM   public.payment_methods
  WHERE  id = v_old_payment_method_id;

  IF (p_payment_method_provided OR p_supplier_provided)
     AND v_final_kind = 'credit'
     AND v_final_supplier_id IS NULL
  THEN
    RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_payment_method_provided
     AND v_final_kind = 'credit'
     AND v_old_kind IS DISTINCT FROM 'credit'
  THEN
    RAISE EXCEPTION 'credit_transition_not_allowed: la edición no postea cargos en cuenta corriente — borrá esta compra y volvé a cargarla como compra a crédito'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  FOR v_old_purchase IN
    SELECT id, product_id, quantity, unit_id, branch_id, operation_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_purchase.product_id;

      -- ventas-unidades-conversion (D6): la pata REVERSE devuelve EXACTAMENTE
      -- lo que el movimiento original sumó (quantity_delta, ya en unidad base
      -- del producto). Sin movimiento cae a la definición única.
      SELECT unit_cost_snapshot, -quantity_delta INTO v_reverse_unit_cost, v_reverse_delta
      FROM   public.stock_movements
      WHERE  reference_id = v_old_purchase.id AND reference_type = 'purchase'
      ORDER  BY created_at DESC
      LIMIT  1;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_purchase.product_id, v_old_product_name,
        v_old_purchase.branch_id,
        COALESCE(v_reverse_delta,
                 -public._uom_normalize_quantity(v_old_purchase.product_id, v_old_purchase.unit_id, v_old_purchase.quantity)),
        'purchase_return',
        v_old_purchase.id, 'purchase_update', v_old_purchase.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
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
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- ventas-unidades-conversion (D1): cantidad de la línea nueva en unidad
      -- base del producto para la pata APPLY.
      v_apply_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id,
         name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id,
         v_line_snap->>'name_snapshot',
         v_line_snap->>'sku_snapshot',
         (v_line_snap->>'unit_cost_snapshot')::numeric,
         (v_line_snap->>'iva_rate_snapshot')::numeric)
      RETURNING id INTO v_new_purchase_id;

      IF v_flag_on THEN
        INSERT INTO public.purchase_items (
          purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_purchase_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, v_apply_qty_norm, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated;
COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) IS
  $c$caja-compras-cobranzas (D8): el guard P0423 suma un tercer EXISTS contra
  cash_movements (movement_type=purchase_payment) — una compra con caja
  posteada también pasa a ser inmutable. Mismo predicado en el derivado de
  lectura del listado (backend/repositories/purchase_repository.py).
  remitos-compra (D9): una compra con origen de remito no se edita: P0423 delivery_note_purchase_locked, después de la comprobación de existencia y ANTES de los tres P0423 de dinero (sin tocar stock ni nada).$c$;


-- =============================================================================
-- 7. _delivery_note_payload: la compra generada pasa a derivarse (tanda A -> B)
-- =============================================================================
-- Desde el cuerpo vivo (md5 56e740cd5e76a6d4a833a307c2212892): converted_operation_id completa el
-- campo genérico ya existente con la operación de compra del remito (derivada de
-- purchases.source_delivery_note_id con account_id); converted_sales_order_id queda
-- NULL en compra. Ningún campo paralelo.
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
              -- remitos-compra (D7/D11): contraparte del sentido compra y
              -- cuántas líneas siguen con precio 0 (no se puede convertir).
              'supplier_name',  (SELECT s.name FROM public.suppliers s WHERE s.id = dn.supplier_id AND s.account_id = dn.account_id),
              'supplier_phone', (SELECT s.phone FROM public.suppliers s WHERE s.id = dn.supplier_id AND s.account_id = dn.account_id),
              'supplier_deleted', (SELECT s.deleted_at IS NOT NULL FROM public.suppliers s WHERE s.id = dn.supplier_id AND s.account_id = dn.account_id),
              'missing_price_count', (SELECT count(*) FROM public.delivery_note_items mi
                                      WHERE mi.delivery_note_id = dn.id AND mi.price = 0),
              'branch_name',   (SELECT b.name FROM public.branches b WHERE b.id = dn.branch_id),
              -- remitos-venta tanda B: la orden VIVA nacida del remito (a lo
              -- sumo una, índice único parcial); NULL si no está convertido.
              'converted_sales_order_id', (SELECT so.id FROM public.sales_orders so
                                           WHERE so.source_delivery_note_id = dn.id
                                             AND so.account_id = dn.account_id
                                             AND so.status <> 'canceled'),
              -- remitos-compra tanda B (D7): en el sentido compra, la operación de compra generada
              -- (todas las filas comparten operation_id); la venta y la compra son excluyentes por
              -- sentido, así que el campo genérico se completa con la que corresponda.
              'converted_operation_id',   COALESCE(
                                           (SELECT so.sale_operation_id FROM public.sales_orders so
                                            WHERE so.source_delivery_note_id = dn.id
                                              AND so.account_id = dn.account_id
                                              AND so.status <> 'canceled'),
                                           (SELECT pu.operation_id FROM public.purchases pu
                                            WHERE pu.source_delivery_note_id = dn.id
                                              AND pu.account_id = dn.account_id
                                            LIMIT 1)),
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
  $c$remitos-venta: fila de delivery_notes + document_type, nombres de cliente y sucursal, líneas en orden de carga (con símbolo de unidad y si el producto fue dado de baja) e historial de estados. converted_sales_order_id/converted_operation_id: la orden VIVA (no cancelada) nacida del remito (tanda B), NULL si no está convertido. Interna. remitos-compra (D7): suma supplier_name, supplier_phone y supplier_deleted (proveedor filtrado por la cuenta del remito) y missing_price_count (líneas con price = 0); tanda B: en el sentido compra, converted_operation_id es la operación de compra generada (purchases.source_delivery_note_id, filtrado por cuenta), NULL si no está convertido.$c$;


-- =============================================================================
-- 8. Introspección (D16). Falla la migración si algo no quedó como se diseñó.
-- =============================================================================
DO $$
DECLARE
  v_bad   text[] := '{}';
  v_fn    text;
  v_oid   oid;
  v_n     integer;
  v_src   text;
  v_md5   text;
  v_count integer;
  v_exp   jsonb := jsonb_build_object(
    '_purchase_operation_core',             '7ad5c56ea845bcb188f69d8a2ce96ddb',
    'rpc_create_purchase_operation',        '98e045e69109fe903aedd7ca2d78e448',
    'rpc_delete_purchase_operation',        'a74eac28d5f504f1e0682420b41558af',
    'rpc_atomic_update_purchase_operation', '170fc4693bf217b77c20cc4fb4602271',
    '_delivery_note_payload',               '14d1fed0853c917b00528111a5ef8291');
BEGIN
  -- Puente: columna, FK NO ACTION, índice parcial y disparador de integridad.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'purchases'
                   AND column_name = 'source_delivery_note_id' AND data_type = 'uuid') THEN
    v_bad := v_bad || 'falta purchases.source_delivery_note_id uuid'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'purchases_source_delivery_note_id_fkey' AND contype = 'f'
                   AND conrelid = 'public.purchases'::regclass
                   AND confrelid = 'public.delivery_notes'::regclass AND confdeltype = 'a') THEN
    v_bad := v_bad || 'falta la FK purchases_source_delivery_note_id_fkey (ON DELETE NO ACTION) hacia delivery_notes'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                 WHERE c.relname = 'purchases_source_delivery_note_id_idx'
                   AND i.indrelid = 'public.purchases'::regclass AND i.indpred IS NOT NULL) THEN
    v_bad := v_bad || 'falta el índice parcial purchases_source_delivery_note_id_idx'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                 WHERE t.tgrelid = 'public.purchases'::regclass AND t.tgname = 'trg_purchases_guard_delivery_note_source'
                   AND NOT t.tgisinternal AND t.tgenabled = 'O'
                   AND t.tgtype = 31  -- ROW | BEFORE | INSERT | DELETE | UPDATE
                   AND t.tgfoid = 'public.trg_purchases_guard_delivery_note_source()'::regprocedure) THEN
    v_bad := v_bad || 'falta el disparador trg_purchases_guard_delivery_note_source (BEFORE INSERT OR UPDATE OR DELETE, por fila, habilitado)'::text;
  END IF;

  -- Catálogo de la tanda B, por PRESENCIA y atributos (nunca por conteo).
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status = 'issued' AND to_status = 'converted'
                   AND allowed_role @> ARRAY['purchases', 'stock', 'admin', 'owner'] AND cardinality(allowed_role) = 4
                   AND NOT requires_reason AND NOT is_terminal_to) THEN
    v_bad := v_bad || 'falta issued -> converted de delivery_note_purchase con {purchases,stock,admin,owner}'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status = 'converted' AND to_status = 'issued'
                   AND allowed_role IS NULL AND NOT requires_reason AND NOT is_terminal_to) THEN
    v_bad := v_bad || 'falta converted -> issued de delivery_note_purchase (sin rol)'::text;
  END IF;

  -- Una sola definición por función (sin overloads: 42725 con la reaplicación de CI).
  FOREACH v_fn IN ARRAY ARRAY['_purchase_operation_core', 'rpc_create_purchase_operation',
                              'rpc_convert_delivery_note_to_purchase', 'rpc_delete_purchase_operation',
                              'rpc_atomic_update_purchase_operation', '_delivery_note_payload',
                              'trg_purchases_guard_delivery_note_source'] LOOP
    SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_n <> 1 THEN
      v_bad := v_bad || format('%s tiene %s definiciones (se esperaba 1)', v_fn, v_n);
    END IF;
  END LOOP;

  -- ACLs: el núcleo y el payload no son ejecutables por la aplicación; el disparador tampoco; la conversión
  -- y las tres reescritas conservan authenticated y no tienen anon (ni PUBLIC), son SECURITY DEFINER y
  -- llevan COMMENT.
  FOREACH v_fn IN ARRAY ARRAY['public._purchase_operation_core(uuid, text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date, uuid)',
                              'public._delivery_note_payload(uuid)',
                              'public.trg_purchases_guard_delivery_note_source()'] LOOP
    v_oid := to_regprocedure(v_fn);
    IF v_oid IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_fn);
    ELSIF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
          OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                     WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por authenticated, anon o PUBLIC', v_fn);
    ELSIF obj_description(v_oid, 'pg_proc') IS NULL THEN
      v_bad := v_bad || format('%s sin COMMENT', v_fn);
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY ARRAY['public.rpc_convert_delivery_note_to_purchase(text, uuid, integer, uuid, date, uuid, uuid, uuid, date, text)',
                              'public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)',
                              'public.rpc_delete_purchase_operation(uuid, uuid, text)',
                              'public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'] LOOP
    v_oid := to_regprocedure(v_fn);
    IF v_oid IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_fn);
    ELSIF has_function_privilege('anon', v_oid, 'EXECUTE')
          OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                     WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por anon o PUBLIC', v_fn);
    ELSIF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || format('%s NO es ejecutable por authenticated', v_fn);
    ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      v_bad := v_bad || format('%s no es SECURITY DEFINER', v_fn);
    ELSIF obj_description(v_oid, 'pg_proc') IS NULL THEN
      v_bad := v_bad || format('%s sin COMMENT', v_fn);
    END IF;
  END LOOP;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public._purchase_operation_core(uuid, text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date, uuid)'::regprocedure) THEN
    v_bad := v_bad || '_purchase_operation_core no es SECURITY DEFINER'::text;
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.trg_purchases_guard_delivery_note_source()'::regprocedure) THEN
    v_bad := v_bad || 'el disparador del puente debe ser SECURITY INVOKER (current_user tiene que ser el que escribe)'::text;
  END IF;

  -- Cuerpos: md5 de prosrc (sin \r) = el de esta migración.
  FOR v_fn IN SELECT jsonb_object_keys(v_exp) LOOP
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_md5 IS DISTINCT FROM (v_exp ->> v_fn) THEN
      v_bad := v_bad || format('el cuerpo vivo de %s mide %s y el de esta migración es %s (¿una reaplicación posterior lo pisó?)', v_fn, v_md5, v_exp ->> v_fn);
    END IF;
  END LOOP;

  -- Semántica clave de cada cuerpo (con md5 igual debería sobrar; protege contra un cambio de la lista).
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = '_purchase_operation_core';
  IF position('p_source_delivery_note_id' IN v_src) = 0 OR position('delivery_note_items_from_source' IN v_src) = 0
     OR position('IF NOT v_from_dn THEN' IN v_src) = 0 OR position('delivery_note_purchase_mismatch' IN v_src) = 0
     OR position('''delivery_note_purchase'', p_source_delivery_note_id, ''issued'', ''converted''' IN v_src) = 0
     OR position('c21_apply_branch_stock_delta' IN v_src) = 0 THEN
    v_bad := v_bad || 'el núcleo no tiene la rama de origen (revalidación, líneas del remito, salto del stock, transición a converted)'::text;
  END IF;
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_create_purchase_operation';
  IF position('_purchase_operation_core(' IN v_src) = 0 OR position('c21_apply_branch_stock_delta' IN v_src) > 0
     OR position('source_delivery_note' IN v_src) > 0 THEN
    v_bad := v_bad || 'rpc_create_purchase_operation debe ser un wrapper del núcleo, sin lógica propia ni parámetro de origen'::text;
  END IF;
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_delete_purchase_operation';
  IF position('delivery_note_purchase_delete_forbidden' IN v_src) = 0 OR position('IF v_source_dn IS NULL THEN' IN v_src) = 0
     OR position('FROM public.delivery_notes dn' IN v_src) = 0
     OR position('FROM public.delivery_notes dn' IN v_src) > position('_pay_reverse_party_charge(' IN v_src)
     OR position('_pay_reverse_party_charge(' IN v_src) > position('rpc_reverse_stock_movement(' IN v_src) THEN
    v_bad := v_bad || 'el borrado no toma el lock del remito ANTES de las compensaciones o no saltea la reversa de stock'::text;
  END IF;
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_atomic_update_purchase_operation';
  IF position('delivery_note_purchase_locked' IN v_src) = 0
     OR position('delivery_note_purchase_locked' IN v_src) > position('operation_has_account_charge_immutable' IN v_src) THEN
    v_bad := v_bad || 'la edición no rechaza la compra de un remito (P0423) ANTES de los P0423 de dinero'::text;
  END IF;

  -- COMMENT: los vivos se conservan y la tanda B suma el suyo.
  IF position('caja-compras-cobranzas (D7)' IN obj_description('public.rpc_delete_purchase_operation(uuid, uuid, text)'::regprocedure, 'pg_proc')) = 0
     OR position('remitos-compra (D9)' IN obj_description('public.rpc_delete_purchase_operation(uuid, uuid, text)'::regprocedure, 'pg_proc')) = 0 THEN
    v_bad := v_bad || 'el COMMENT del borrado debe conservar el vivo (caja-compras-cobranzas D7) y sumar remitos-compra (D9)'::text;
  END IF;
  IF position('caja-compras-cobranzas (D8)' IN obj_description('public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'pg_proc')) = 0
     OR position('remitos-compra (D9)' IN obj_description('public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'pg_proc')) = 0 THEN
    v_bad := v_bad || 'el COMMENT de la edición debe conservar el vivo (caja-compras-cobranzas D8) y sumar remitos-compra (D9)'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'remitos-compra tanda B (introspección FALLÓ):\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'remitos-compra tanda B (introspección OK): puente (columna, FK NO ACTION, índice parcial, disparador INVOKER), catálogo issued->converted / converted->issued, núcleo interno sin EXECUTE, wrapper de la misma firma, conversión, borrado, edición y payload con sus cuerpos (md5), ACLs y COMMENT, una definición por función.';
END $$;
