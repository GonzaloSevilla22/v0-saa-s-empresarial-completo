-- =============================================================================
-- multiusuario-operativo — TANDA B (governance CRÍTICO)
-- Las ocho RPCs del camino del dinero de ventas y compras se autorizan por
-- PERTENENCIA A LA CUENTA ACTIVA Y ROL, nunca por el autor del producto ni del
-- documento.
--
-- PROBLEMA (auditoría de stock del 2026-10-14, humo S20, pasos R3a-R3l).
--   Seis de las ocho comparaban `products.user_id` / `sales.user_id` /
--   `purchases.user_id` con `auth.uid()`. En ellas el producto se buscaba SIN filtro
--   de cuenta (`SELECT … FROM products WHERE id = … FOR UPDATE`): el guard de autor era
--   el ÚNICO guard de tenencia. El resultado, para un invitado a una cuenta:
--     R3a / R3b  el vendedor y el administrador NO podían vender por formulario un
--                producto que cargó el dueño (P0403 Permission denied to product);
--     R3g        compras NO podía cargar una compra de ese producto;
--     R3d / R3f  el dueño NO podía corregir una venta del vendedor ni el administrador
--                una del dueño (P0403 … belongs to another user).
--   Y las OCHO no tenían NINGÚN guard de rol en SQL: un observador (`viewer`) con un
--   producto propio vendía, compraba y borraba. Hoy nada de eso ocurre porque no existe
--   ningún miembro además del dueño (0 cuentas con más de un miembro, medido el
--   2026-10-17): es el momento de corregirlo, no después.
--
-- QUÉ HACE (design.md D8, D9)
--   1. `_account_assert_capability(account, roles, mensaje)` — el helper canónico del
--      guard de rol (la Regla de Tres está alcanzada con `_stock_assert_can_adjust`,
--      `_quote_assert_can_write` y `_delivery_note_assert_role_dir`, que NO se migran
--      en este change): primero `is_account_writer` (el observador da P0401), después
--      que los roles activos del caller intersequen `p_roles` (P0403 insufficient_role).
--      Y `_account_assert_document_authority(account, autores, mensaje)` — la regla de
--      OQ-4 (b): sobre un documento de OTRO miembro sólo dueño o administrador.
--   2. El producto se toma con `AND account_id = v_account_id` DENTRO del mismo
--      `SELECT … FOR UPDATE` (no es un lock nuevo: el orden global de locks no cambia): un
--      producto de otra cuenta o de la cuenta no activa da el MISMO P0404 que un id
--      inexistente. Se elimina todo `IF v_product.user_id <> v_uid`.
--   3. La edición exige que cada venta / compra sea de la cuenta activa (P0404 si no) y
--      que, salvo dueño y administrador, el caller sea su autor (P0403). El lock de la
--      edición de venta filtra por cuenta en vez de por autor. La AUTORÍA se conserva:
--      las filas que reemplazan a las editadas llevan al autor original (antes el único
--      que podía editar era el autor, así que `v_uid` coincidía; ahora un administrador
--      puede corregir lo del vendedor y no tiene que quedarse con su autoría).
--   4. El alta de venta y de compra exigen CAN_SELL (dueño, administrador, vendedor,
--      cajero) y CAN_PURCHASE (dueño, administrador, compras); la edición y el borrado
--      exigen la capacidad del dominio y la regla de autor. El depósito NO compra (OQ-3):
--      recibe mercadería por remito. La compra lo exige en el WRAPPER público; el núcleo
--      `_purchase_operation_core` lleva sólo el guard de PRODUCTO (D11), porque la
--      conversión de un remito lo reusa con el rol de remitos (que incluye depósito).
--
-- NO TOCA `user_id`: se sigue ESCRIBIENDO como autoría (spec multi-tenant) pero NUNCA se
-- usa como eje de autorización. NO toca el orden global de locks de la venta
-- (`sales` -> `sales_orders` -> `fiscal_documents` -> resto; productos por id ascendente).
--
-- Cuerpos de partida (checkpoint 7.2, 2026-10-17, md5 de prosrc sin \r, prod == base
-- local construida desde los archivos): ver el bloque 0 (preflight), que ABORTA si alguno
-- cambió. Los cuerpos previos completos están en
-- openspec/changes/multiusuario-operativo/evidence/tanda-b/cuerpos-previos/ (rollback) y
-- los diffs contra el vivo en evidence/tanda-b/diffs/ (sólo el guard que cambia).
--
-- Coordinación (D11): `fix/stock-edicion-sucursal-y-piso` (#646) y
-- `edicion-operaciones-con-dinero` (#644) reescriben también las dos funciones de edición.
-- Quien aplique DESPUÉS de esta migración tiene que partir del cuerpo VIVO (preflight por md5)
-- y re-derivar su reescritura: este PR no espera por ellos.
--
-- Idempotente (CI la reaplica al final de la cadena): CREATE OR REPLACE con firmas fijas
-- (sin overload, sin 42725), REVOKE/GRANT y COMMENT re-emitidos.
--
-- Gates: supabase/tests/test_multiusuario_operaciones.sql (EJECUTA la matriz de roles, la
-- tenencia, la autoría y la ACL) y los gates de comportamiento de ventas y compras
-- re-ejecutados.
--
-- Rollback: restaurar los nueve cuerpos de evidence/tanda-b/cuerpos-previos/ y
--   DROP FUNCTION public._account_assert_capability(uuid, text[], text),
--                 public._account_assert_document_authority(uuid, uuid[], text);
-- =============================================================================

-- =============================================================================
-- 0. Preflight: ningún cuerpo de partida cambió desde el checkpoint (7.2)
-- =============================================================================
-- Las nueve funciones que esta migración reescribe se reescriben desde su cuerpo VIVO.
-- Si otro change las redefinió en el medio (p. ej. #646 o edicion-operaciones-con-dinero),
-- un CREATE OR REPLACE ciego pisaría ese trabajo en silencio: se ABORTA con el md5
-- observado para rebasar el cuerpo sobre el vivo. Idempotente: con el cuerpo de esta
-- migración ya instalado (reaplicación) sigue de largo.
DO $$
DECLARE
  v_expected jsonb := jsonb_build_object(
    '_purchase_operation_core',               '7ad5c56ea845bcb188f69d8a2ce96ddb',
    'rpc_create_purchase_operation',          '98e045e69109fe903aedd7ca2d78e448',
    'rpc_create_purchase_operation_v2',       '64a2a151caef3c9c12d40cf7bab54df1',
    'rpc_create_sale_operation',              'e5185557021d2f481b9e3f6679c50493',
    'rpc_create_sale_operation_v2',           '9fde6d956bc37838e8d81402e22de8fa',
    'rpc_atomic_update_sale_operation',       '52acb873d8c446c24abb19b79eb43c75',
    'rpc_atomic_update_purchase_operation',   '170fc4693bf217b77c20cc4fb4602271',
    'rpc_delete_sale_operation',              '7ab91a899dd0fbc81e6a415f1ea99aac',
    'rpc_delete_purchase_operation',          'a74eac28d5f504f1e0682420b41558af');
  v_rewritten jsonb := jsonb_build_object(
    '_purchase_operation_core',               '12d47cda44f3497817cdc2219d886526',
    'rpc_create_purchase_operation',          '9a3b868b883d2f59b3ae1a6908288ea1',
    'rpc_create_purchase_operation_v2',       '8daac77ff5dac89357e27f45ee8e214f',
    'rpc_create_sale_operation',              '748c7a7e6cd1c4074bd127ae6e0092ee',
    'rpc_create_sale_operation_v2',           '41bfa7554f971d1b386541e01b3cf403',
    'rpc_atomic_update_sale_operation',       'd95db43c5e737c080661c74208595b93',
    'rpc_atomic_update_purchase_operation',   '691d0a01893439e39e7cda93ddcbcc6f',
    'rpc_delete_sale_operation',              'a786dd6dcb2ad607a84b0ec96939aa67',
    'rpc_delete_purchase_operation',          '06c3ea363cbdf1ae4027a3e55c8c3ca3');
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
      RAISE EXCEPTION 'multiusuario-operativo tanda B (preflight): el cuerpo vivo de % mide % y no es ni el de partida (%) ni el de esta migración (%): otro change la redefinió — rebasá la reescritura sobre el cuerpo vivo antes de aplicar',
        v_fn, COALESCE(v_md5, '(no existe)'), v_expected ->> v_fn, v_rewritten ->> v_fn;
    END IF;
  END LOOP;
  RAISE NOTICE 'multiusuario-operativo tanda B (preflight): % cuerpos de partida verificados por md5, % ya reaplicados', v_ok, v_re;
END $$;

-- =============================================================================
-- 1. Los helpers del guard (D9)
-- =============================================================================
-- Molde: `_stock_assert_can_adjust`, `_quote_assert_can_write` y
-- `_delivery_note_assert_role_dir` (INVOKER, STABLE, sin EXECUTE para los roles de
-- aplicación: los invocan las RPCs DEFINER, que corren como su dueño). `auth.uid()` lee
-- los claims del request, no el rol de la sesión.
CREATE OR REPLACE FUNCTION public._account_assert_capability(p_account_id uuid, p_roles text[], p_message text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Sin ningún rol de escritura en la cuenta (el observador): falta de autorización.
  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;
  -- Con rol de escritura pero sin el rol del dominio: rol insuficiente, con los roles requeridos.
  IF NOT (public.account_user_active_roles(p_account_id, auth.uid()) && p_roles) THEN
    RAISE EXCEPTION 'insufficient_role: %', p_message USING ERRCODE = 'P0403';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._account_assert_capability(uuid, text[], text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._account_assert_capability(uuid, text[], text) IS
  $c$multiusuario-operativo (tanda B, D9): helper CANÓNICO del guard de rol de una RPC de operaciones. Primero is_account_writer (sin rol de escritura = P0401 unauthorized), después que los roles activos del caller en p_account_id intersequen p_roles (P0403 insufficient_role: <mensaje>). INVOKER y STABLE: lo invocan las RPCs DEFINER; sin EXECUTE para anon ni authenticated. Mismo molde que _stock_assert_can_adjust, _quote_assert_can_write y _delivery_note_assert_role_dir, que NO se migran en este change (candidato).$c$;

CREATE OR REPLACE FUNCTION public._account_assert_document_authority(p_account_id uuid, p_author_ids uuid[], p_message text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
BEGIN
  -- OQ-4 (b): el dueño y el administrador de la cuenta modifican CUALQUIER documento de la cuenta.
  IF public.account_user_active_roles(p_account_id, auth.uid()) && ARRAY['owner', 'admin'] THEN
    RETURN;
  END IF;
  -- El resto, sólo los documentos de los que es autor. Un conjunto vacío (documento inexistente) no rechaza:
  -- la inexistencia la resuelve cada RPC con su propio P0404 / false.
  IF EXISTS (SELECT 1 FROM unnest(p_author_ids) AS a(user_id) WHERE a.user_id IS DISTINCT FROM auth.uid()) THEN
    RAISE EXCEPTION 'insufficient_role: %', p_message USING ERRCODE = 'P0403';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._account_assert_document_authority(uuid, uuid[], text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._account_assert_document_authority(uuid, uuid[], text) IS
  $c$multiusuario-operativo (tanda B, D9, OQ-4 b): sobre un documento (venta o compra) de OTRO miembro sólo puede el dueño o un administrador de la cuenta; el resto modifica los documentos de los que es autor (P0403 insufficient_role). p_author_ids son los user_id de las filas del documento. Va DESPUÉS de verificar que el documento es de la cuenta activa (un documento de otra cuenta es P0404 / false, nunca P0403: no revela que existe). INVOKER y STABLE; sin EXECUTE para anon ni authenticated.$c$;

-- =============================================================================
-- 2. _purchase_operation_core
-- =============================================================================
CREATE OR REPLACE FUNCTION public._purchase_operation_core(p_account_id uuid, p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid, p_cost_center_id uuid, p_payment_method_id uuid, p_bank_account_id uuid, p_supplier_id uuid, p_cash_session_id uuid, p_due_date date, p_source_delivery_note_id uuid)
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
                  AND account_id = v_account_id
                FOR UPDATE;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
                END IF;

                -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
                -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

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

-- =============================================================================
-- 3. rpc_create_purchase_operation
-- =============================================================================
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

    -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
    -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
    PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'purchases'], 'tu rol no permite registrar compras (requiere compras, administrador o dueño)');

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
-- 4. rpc_create_purchase_operation_v2
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation_v2(p_idempotency_key text, p_date date, p_description text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_new_op_id       uuid;
  v_existing_op     uuid;
  v_item            RECORD;
  v_product         RECORD;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_qty_before      numeric;
  v_qty_after       numeric;
  v_unit_factor     numeric(20,10);
  v_qty_norm        numeric(15,4);
  v_stock_sum       numeric(15,4);
  v_inserted        integer;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'purchases'], 'tu rol no permite registrar compras (requiere compras, administrador o dueño)');

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  v_new_op_id := gen_random_uuid();

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

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
      SELECT id, user_id, is_variant, name INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
        AND account_id = v_account_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
      -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- OQ2: doble escritura — header flat + purchase_items
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;

      INSERT INTO public.purchase_items (
        purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
      ) VALUES (
        v_new_purchase_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity
      );

      -- C-21 checkpoint #2: before/after desde Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      v_qty_before := v_stock_sum;
      v_qty_after  := v_stock_sum + v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, NULL, v_qty_norm);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
        v_qty_norm, v_qty_before, v_qty_after,
        v_new_purchase_id, 'purchase', v_uid,
        v_new_op_id
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_purchase_operation_v2(text, date, text, jsonb) FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 5. rpc_create_sale_operation
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_flag_on    boolean := false;
  v_uid        uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  -- deudas-menores-agosto (G1/D1): ausencia de fila = v2 (antes: legacy). El
  -- COALESCE va DESPUÉS del SELECT — SELECT ... INTO sin fila deja v_flag_on
  -- en NULL, y el COALESCE de acá lo resuelve a true. Ponerlo DENTRO del
  -- SELECT (como antes) no ejecuta nada cuando no hay fila y v_flag_on queda
  -- NULL (≈ false en el IF), que es exactamente el bug que se corrige.
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  IF v_flag_on THEN
    -- pagos-cableados-restantes: propaga p_cash_session_id a la v2.
    -- pos-banco-movimientos: propaga p_bank_account_id a la v2 (D6).
    -- cobranzas-vencimientos: propaga p_due_date a la v2 (el camino vivo).
    RETURN public.rpc_create_sale_operation_v2(
      p_idempotency_key, p_client_id, p_date, p_currency, p_items,
      p_branch_id, p_canal, p_payment_method_id, p_cash_session_id, p_bank_account_id,
      p_due_date
    );
  ELSE
    DECLARE
      v_new_op_id    uuid;
      v_existing_op  uuid;
      v_item         RECORD;
      v_product      RECORD;
      v_branch       RECORD;
      v_gate_branch  uuid;
      v_new_sale_id  uuid;
      v_result_items jsonb := '[]'::jsonb;
      v_qty_before   numeric;
      v_qty_after    numeric;
      v_qty_norm     numeric(15,4);
      v_branch_qty   numeric(15,4);
      v_inserted     integer;
      v_canal        text;
      -- pagos-cableados-restantes (task 5.3): mismo trío que la rama v2.
      v_kind                  text;
      v_total_sum             numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
      v_cash_session_status   text;
      v_cash_session_branch   uuid;
    BEGIN
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
          USING ERRCODE = 'P0403';
      END IF;

      -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
      -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
      PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite registrar ventas (requiere vendedor, cajero, administrador o dueño)');

      IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
      END IF;

      IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
      END IF;

      IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
      END IF;

      v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
      IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
        RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
      END IF;

      -- pagos-cableados-restantes: mismo patrón de derivación de kind que la v2.
      -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id)
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

      IF v_kind = 'credit' AND p_client_id IS NULL THEN
        RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id'
          USING ERRCODE = 'P0400';
      END IF;

      -- C-26: la branch explícita debe existir, estar activa Y operativa
      IF p_branch_id IS NOT NULL THEN
        SELECT id, status INTO v_branch
        FROM public.branches
        WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'branch_not_found or not active for this account'
            USING ERRCODE = 'P0404';
        END IF;
        IF v_branch.status = 'closed' THEN
          RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-26: branch del gate y del descuento (explícita o default operativa)
      v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

      -- ventas-sucursal-por-defecto (D2/D3): la sucursal que se GUARDA es la misma con
      -- la que se valida el stock, la caja y el banco. Sin sucursal elegida, si la
      -- cuenta no tiene ninguna sucursal OPERATIVA a la cual resolver (ninguna
      -- sucursal, o todas inactivas o cerradas: c26_default_branch devuelve entonces
      -- su fallback no operativo), se rechaza ANTES de escribir nada. Mismo token y
      -- mismo código que rpc_quick_sale y "Facturar venta manual" cuando la cuenta no
      -- tiene sucursal. Una sucursal ELEGIDA ya se validó arriba (P0404 / P0422
      -- branch_closed). Va antes del INSERT en operation_idempotency: el rechazo no
      -- deja nada persistido.
      IF p_branch_id IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = v_gate_branch AND account_id = v_account_id
          AND is_active = TRUE AND status = 'active'
      ) THEN
        RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la venta'
          USING ERRCODE = 'P0422';
      END IF;

      v_new_op_id := gen_random_uuid();

      INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
      VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
      ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

      GET DIAGNOSTICS v_inserted = ROW_COUNT;

      IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'sale'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                 jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
                 '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.sales s
        WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

        RETURN jsonb_build_object(
          'operation_id', v_existing_op,
          'items',        v_result_items,
          'replayed',     true
        );
      END IF;

      FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                 AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
        ORDER BY product_id
      LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
          RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
          RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
        END IF;

        -- pagos-cableados-restantes: acumular total (mismo patrón que la v2).
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
          SELECT id, user_id, is_variant, name, sku, cost INTO v_product
          FROM   public.products
          WHERE  id = v_item.product_id
            AND account_id = v_account_id
          FOR UPDATE;

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
          END IF;

          -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
          -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

          IF NOT v_product.is_variant THEN
            IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
              RAISE EXCEPTION
                'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
                USING ERRCODE = 'P0422';
            END IF;
          END IF;

          -- ventas-unidades-conversion (auditoría post-apply): la rama legacy del
          -- kill-switch sale_items_rpc_v2=false conservaba la conversión inline
          -- (relativa a la base del TIPO). Misma definición única que la v2.
          -- Tercera revisión (TOCTOU): DESPUÉS del FOR UPDATE, como en la v2.
          v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

          -- C-26 (OQ-A): gate per-branch — el stock debe estar EN la branch
          -- de la operación (explícita o default operativa)
          SELECT COALESCE(quantity, 0) INTO v_branch_qty
          FROM   public.branch_stock
          WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
          v_branch_qty := COALESCE(v_branch_qty, 0);

          IF v_branch_qty < v_qty_norm THEN
            IF p_branch_id IS NOT NULL THEN
              RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            ELSE
              RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            END IF;
          END IF;

          -- ventas-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o la
          -- principal operativa), la MISMA con la que se validó el stock y se descuenta,
          -- no el p_branch_id crudo.
          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, v_item.product_id,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             v_gate_branch, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;

          v_qty_before := v_branch_qty;
          v_qty_after  := v_branch_qty - v_qty_norm;

          PERFORM public.c21_apply_branch_stock_delta(
            v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

          -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
          -- ventas-sucursal-por-defecto (D1/D2): el movimiento lleva v_gate_branch, la
          -- sucursal de la que SALIÓ el stock: la reversa del borrado lee la sucursal DEL
          -- MOVIMIENTO (se escribe una única vez, en este INSERT: RN-21 intacta).
          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id, branch_id, unit_cost_snapshot
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
            -v_qty_norm, v_qty_before, v_qty_after,
            v_new_sale_id, 'sale', v_uid,
            v_new_op_id, v_gate_branch, v_product.cost
          );

        ELSE
          -- Línea sin producto: no mueve stock; la unidad se sigue validando (P0404).
          PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
          -- ventas-sucursal-por-defecto (D1/D2): v_gate_branch, no p_branch_id crudo.
          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, NULL,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             v_gate_branch, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;
        END IF;

        v_result_items := v_result_items
          || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
      END LOOP;

      -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
      -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
      -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
      -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
      -- venta de 665,334 y una factura de round(Σ) = 665,33.
      v_total_sum := round(v_total_sum, 2);

      -- pagos-cableados-restantes (task 5.3/6.2): mismo trío opt-in de caja
      -- + cargo de crédito que la rama v2 — la rama legacy queda consistente.
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
          RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
            USING ERRCODE = 'P0422';
        END IF;

        IF p_date <> public.reporting_local_today() THEN
          RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una venta fechada hoy (%)', public.reporting_local_today()
            USING ERRCODE = 'P0422';
        END IF;

        PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total_sum, 'sale', v_new_op_id);
      END IF;

      -- cobranzas-vencimientos (D3): la rama legacy transporta la fecha de
      -- negocio y el override al helper — la MISMA llamada que la v2.
      IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
          v_account_id, 'customer', p_client_id, v_total_sum, v_new_op_id, v_new_op_id,
          p_date, p_due_date
        );
      END IF;

      -- pos-banco-movimientos (D5, task 5.1): rama legacy — mismo helper y
      -- mismo punto que la v2, para que ambas ramas del strangler queden
      -- consistentes (regla dura del proyecto: no duplicar la regla).
      PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'in', 'sale', v_new_op_id,
        p_date, v_gate_branch, NULL
      );

      RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
      );
    END;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) TO authenticated;

-- =============================================================================
-- 6. rpc_create_sale_operation_v2
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation_v2(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_new_op_id    uuid;
  v_existing_op  uuid;
  v_item         RECORD;
  v_product      RECORD;
  v_branch       RECORD;
  v_gate_branch  uuid;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_qty_norm     numeric(15,4);
  v_branch_qty   numeric(15,4);
  v_inserted     integer;
  v_canal        text;
  -- pagos-cableados-restantes (D1/D4/D5): kind derivado + total acumulado
  -- para el cargo de crédito y el movimiento de caja opt-in.
  v_kind                  text;
  v_total_sum             numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
  v_cash_session_status   text;
  v_cash_session_branch   uuid;
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

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite registrar ventas (requiere vendedor, cajero, administrador o dueño)');

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
  END IF;

  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
  IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
    RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
  END IF;

  -- pagos-cableados-restantes (D1 de pos-catalogo-pagos, reaplicado): el
  -- kind se DERIVA del catálogo — nunca se acepta como texto del cliente.
  -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id).
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

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): el client_id es opcional pero, si viene,
  -- tiene que pertenecer al tenant — ANTES de cualquier escritura (incluida
  -- la fila legacy de `sales`, más abajo). El choke point
  -- c30_get_or_create_customer_account (20261011000001) sólo se ejecuta
  -- para ventas a CRÉDITO (vía _pay_register_party_charge, DESPUÉS del
  -- INSERT en `sales`): una venta al CONTADO (cash/transfer/card/...) con un
  -- client_id ajeno nunca invoca ese choke point y hoy escribe la fila
  -- igual, sin rollback — exactamente la OQ-4 que este fix cierra. Guard
  -- explícito, incondicional al kind. Mismo predicado que el choke point
  -- (sin filtro de deleted_at, a propósito: un cliente dado de baja ya es
  -- aceptado hoy por ese mismo camino para postear un cargo).
  IF p_client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = p_client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- pagos-cableados-restantes (D5): crédito es obligatorio, nunca opcional —
  -- ANTES del descuento de stock (task 5.2). No hay "vender a cuenta
  -- corriente sin anotarlo".
  IF v_kind = 'credit' AND p_client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- C-26: la branch explícita debe existir, estar activa Y operativa
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch del gate y del descuento (explícita o default operativa)
  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  -- ventas-sucursal-por-defecto (D2/D3): la sucursal que se GUARDA es la misma con
  -- la que se valida el stock, la caja y el banco. Sin sucursal elegida, si la
  -- cuenta no tiene ninguna sucursal OPERATIVA a la cual resolver (ninguna
  -- sucursal, o todas inactivas o cerradas: c26_default_branch devuelve entonces
  -- su fallback no operativo), se rechaza ANTES de escribir nada. Mismo token y
  -- mismo código que rpc_quick_sale y "Facturar venta manual" cuando la cuenta no
  -- tiene sucursal. Una sucursal ELEGIDA ya se validó arriba (P0404 / P0422
  -- branch_closed). Va antes del INSERT en operation_idempotency: el rechazo no
  -- deja nada persistido.
  IF p_branch_id IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_gate_branch AND account_id = v_account_id
      AND is_active = TRUE AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la venta'
      USING ERRCODE = 'P0422';
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'sale'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.sales s
    WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    -- pagos-cableados-restantes: acumular total para el cargo de crédito y/o
    -- el movimiento de caja opt-in (mismo patrón que rpc_create_purchase_operation).
    v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost a la lectura ya existente
      -- (name, is_variant) para congelar name/sku/cost sin un SELECT extra.
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
        AND account_id = v_account_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
      -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- ventas-unidades-conversion (D1/D2): la conversión por unidad vive en UNA
      -- sola definición, relativa a la unidad base del PRODUCTO (P0404 unidad
      -- inexistente, P0400 unit_type_mismatch / unit_requires_base_unit).
      -- Tercera revisión (TOCTOU): DESPUÉS del FOR UPDATE — con la fila tomada
      -- la unidad base ya no cambia (trg_product_base_unit_guard espera esta
      -- fila) y un cambio que commiteó mientras esperábamos se lee acá.
      v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      -- C-26 (OQ-A): gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        IF p_branch_id IS NOT NULL THEN
          RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        ELSE
          RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        END IF;
      END IF;

      -- ventas-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o la
      -- principal operativa), la MISMA con la que se validó el stock y se descuenta,
      -- no el p_branch_id crudo.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product ya cargado.
      -- iva_rate_snapshot: products no tiene columna de IVA (D3) → NULL.
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

      -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
      -- ventas-sucursal-por-defecto (D1/D2): el movimiento lleva v_gate_branch, la
      -- sucursal de la que SALIÓ el stock: la reversa del borrado lee la sucursal DEL
      -- MOVIMIENTO (se escribe una única vez, en este INSERT: RN-21 intacta).
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch, v_product.cost
      );

    ELSE
      -- v3-snapshot-pattern (2.6): línea de servicio — name_snapshot no
      -- disponible en el payload legacy de esta RPC (solo amount/quantity/
      -- unit_id); queda NULL como hoy. La línea de servicio con
      -- name_snapshot desde payload se resuelve en _c29_confirm_order_core
      -- (sales_order_items ya trae el nombre desde el frontend — ver 2.4/2.6).
      -- ventas-unidades-conversion: sin producto no hay stock que mover, pero
      -- la unidad de la línea se sigue validando (P0404) como antes.
      PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
      -- ventas-sucursal-por-defecto (D1/D2): v_gate_branch, no p_branch_id crudo.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
  -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
  -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
  -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
  -- venta de 665,334 y una factura de round(Σ) = 665,33.
  v_total_sum := round(v_total_sum, 2);

  -- pagos-cableados-restantes (OQ-C, D4): opt-in de caja — las tres
  -- condiciones se validan en el SERVIDOR (kind cash + sesión abierta en la
  -- sucursal EFECTIVA + fecha de hoy en ART), nunca se confía en la UI. La
  -- ausencia de p_cash_session_id es no-op (D5 — compatible hacia atrás con
  -- las 223 operaciones históricas del formulario).
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
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
        USING ERRCODE = 'P0422';
    END IF;

    IF p_date <> public.reporting_local_today() THEN
      RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una venta fechada hoy (%)', public.reporting_local_today()
        USING ERRCODE = 'P0422';
    END IF;

    PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total_sum, 'sale', v_new_op_id);
  END IF;

  -- pagos-cableados-restantes (OQ-D, D2/D5): crédito SIEMPRE postea el
  -- cargo, vía el mismo helper compartido que usa el POS — una sola
  -- definición de "cargar una venta a cuenta corriente" (D1).
  -- cobranzas-vencimientos (D3): transporta la fecha de negocio (p_date) y
  -- el override (p_due_date) — la cascada se resuelve EN el helper, nunca acá.
  IF v_kind = 'credit' THEN
    PERFORM public._pay_register_party_charge(
      v_account_id, 'customer', p_client_id, v_total_sum, v_new_op_id, v_new_op_id,
      p_date, p_due_date
    );
  END IF;

  -- pos-banco-movimientos (D5, task 5.1): movimiento bancario operativo del
  -- formulario de venta — mismo helper que el POS, mismo punto (después de
  -- caja/crédito). p_value_date = p_date (el form admite fechas pasadas —
  -- D4, guard P0424 dentro del helper).
  PERFORM public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    v_total_sum, 'in', 'sale', v_new_op_id,
    p_date, v_gate_branch, NULL
  );

  -- asiento-venta-formulario (D6): evento del outbox — INSERT plano, SIN
  -- bloque EXCEPTION. Si esto falla y la venta igual commitea, el
  -- resultado es exactamente el bug que este change arregla (venta sin
  -- asiento) pero silencioso — swallowear el fallo no es aceptable.
  -- payment_method va CRUDO (v_kind), sin COALESCE: el default vive en la
  -- rama del consumidor, no en el payload (D6 — lección de pagos-cableados-
  -- restantes D7 con el 'credit' cableado de compras).
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationCreated', 'SaleOperation', v_new_op_id,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_new_op_id,
      'total',          v_total_sum,
      'payment_method', v_kind,
      'client_id',      p_client_id,
      'sale_date',      p_date,
      'occurred_at',    now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) TO authenticated;

-- =============================================================================
-- 7. rpc_atomic_update_sale_operation
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_canal text DEFAULT NULL::text, p_canal_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_author         uuid;   -- multiusuario-operativo (tanda B): autor de la operación que se edita
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
  v_reverse_delta     numeric;         -- ventas-unidades-conversion (D6)
  v_apply_qty_norm    numeric(15,4);   -- ventas-unidades-conversion (D1)
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
  v_total_sum          numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
  v_kind_final          text;
  v_pending_event_id    uuid;
  v_pending_event_type  text;
  v_pending_payload     jsonb;
  v_has_posted_entry    boolean := false;
  -- venta-editable-sin-cae: la anulación del comprobante pendiente NO enviado.
  v_void_rec            RECORD;   -- (sales_order_id, operation_id) a anular
  v_voided_doc          jsonb;    -- descriptor del último comprobante anulado
  -- venta-editable-vs-promocion-legacy (20261061000001):
  v_locked              integer;  -- filas de la operación tomadas con FOR UPDATE
  v_resync_id           uuid;     -- orden re-apuntada que se recalcula (N3)
  v_dn_label            text;     -- remitos-venta (D9): remito de origen de la venta
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

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite editar ventas (requiere vendedor, cajero, administrador o dueño)');

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P0400';
  END IF;

  -- multiusuario-operativo (tanda B, D8): el documento tiene que ser de la CUENTA ACTIVA, no del caller. Una venta de
  -- otra cuenta es indistinguible de una inexistente (P0404, mismo texto): no se revela que existe en otra cuenta.
  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids) AND account_id = v_account_id)
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): sobre una venta de OTRO miembro sólo puede el dueño o un administrador;
  -- el resto corrige lo propio (P0403). La autoría se CONSERVA en las filas nuevas (v_author): la edición reemplaza las
  -- líneas, pero quien la cargó sigue siendo su autor.
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT s.user_id) FROM public.sales s WHERE s.id = ANY(p_sale_ids)),
    'solo el dueño o un administrador modifican las ventas que cargó otro miembro');
  SELECT s.user_id INTO v_author FROM public.sales s WHERE s.id = ANY(p_sale_ids) ORDER BY s.id LIMIT 1;

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción.
  -- Las filas de sales de la operación son lo único que existe ANTES que la
  -- orden, así que son el ancla común: la promoción, la edición y el borrado
  -- las toman PRIMERO, con FOR UPDATE y en orden ascendente de id. Orden
  -- global de locks: sales → sales_orders → fiscal_documents → resto.
  -- Sin este lock, el enumerador de órdenes de más abajo leía SIN lock, no
  -- veía la orden que una promoción concurrente estaba creando, y la venta
  -- quedaba editada con un comprobante pendiente VIVO por importes viejos.
  -- Recuento bajo el lock: si otra edición o un borrado ganó y se llevó
  -- alguna fila mientras se esperaba, se aborta acá, antes de revertir stock
  -- o de tocar cualquier libro (doble "Guardar" incluido).
  SELECT count(*) INTO v_locked
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(p_sale_ids)
      AND  s.account_id = v_account_id
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_locked <> array_length(p_sale_ids, 1) THEN
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

  -- remitos-venta (D9): una venta nacida de un remito NO se edita. El editor
  -- siempre reemplaza líneas (REVERSE + APPLY) y la REVERSE, sin movimiento
  -- propio de esas filas sales, cae a la normalización de la línea y
  -- REPONDRÍA stock que el remito sigue reteniendo (la APPLY lo descontaría
  -- de nuevo; una reducción dejaría reposición de más que la anulación del
  -- remito duplicaría). Va ANTES del bloque fiscal para no anular un
  -- comprobante pendiente por una edición que igual se rechaza, y bloquea la
  -- operación entera (también la cabecera).
  SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'de origen') INTO v_dn_label
  FROM   public.sales s
  JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
  JOIN   public.delivery_notes dn ON dn.id = so.source_delivery_note_id
  WHERE  s.id = ANY(p_sale_ids)
  LIMIT  1;

  IF FOUND THEN
    RAISE EXCEPTION 'delivery_note_sale_locked: la venta nació del remito %: para corregirla, eliminá la venta, editá el remito y volvé a convertirlo', v_dn_label
      USING ERRCODE = 'P0423';
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
  --
  -- Esta query NO filtra por `so.fiscal_document_id IS NOT NULL` (red team
  -- 2026-09-22, M1): ese filtro se evalúa SIN lock, así que con una emisión
  -- abierta en otra conexión devolvía cero filas, el helper no se llamaba
  -- NUNCA, y la venta se editaba dejando vivo el comprobante que la emisión
  -- estaba por commitear. Quién decide "hay comprobante" es el helper, con la
  -- fila de la orden BLOQUEADA. Acá sólo se enumeran las órdenes de la
  -- operación (a lo sumo una: sale_operation_id tiene índice único parcial).
  FOR v_void_rec IN
    SELECT DISTINCT so.id AS sales_order_id, s.operation_id AS operation_id
    FROM   public.sales s
    JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
    WHERE  s.id = ANY(p_sale_ids)
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

  -- ventas-sucursal-por-defecto (D5, OQ-7): para la VENTA, NULL significa "la
  -- principal". Ni la intención de desimputar (p_branch_provided con NULL) ni una
  -- fila vigente sin sucursal (residuo histórico) se preservan: se resuelve a la
  -- principal operativa ANTES del REVERSE, igual que la validación de arriba (gate
  -- 2.9 de edicion-preserva-contexto: una edición inválida no revierte ni
  -- reaplica stock). Una sucursal vigente no nula se preserva sin revalidar, como
  -- hoy; una explícita inválida sigue dando P0422 branch_invalid. El REVERSE de
  -- una fila NULL ya caía en la principal vigente (op_stock_movement) y el APPLY
  -- descuenta de esa misma sucursal: el neto es cero. Compra y gasto conservan
  -- las tres intenciones del contrato tri-estado.
  IF v_final_branch_id IS NULL THEN
    v_final_branch_id := public.c26_default_branch(v_account_id);
    IF v_final_branch_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id
        AND is_active = TRUE AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la venta'
        USING ERRCODE = 'P0422';
    END IF;
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
    SELECT id, product_id, quantity, unit_id, branch_id, operation_id
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
      -- ventas-unidades-conversion (D6): la pata REVERSE devuelve EXACTAMENTE
      -- lo que el movimiento original descontó (quantity_delta, ya en unidad
      -- base del producto), nunca la cantidad cruda de la línea. Sin
      -- movimiento (fila anterior al ledger C-21) cae a la definición única.
      SELECT unit_cost_snapshot, -quantity_delta INTO v_reverse_unit_cost, v_reverse_delta
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
        v_old_sale.branch_id,
        COALESCE(v_reverse_delta,
                 public._uom_normalize_quantity(v_old_sale.product_id, v_old_sale.unit_id, v_old_sale.quantity)),
        'sale_return',
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
        AND account_id = v_account_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
      -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- ventas-unidades-conversion (D1): cantidad de la línea nueva en unidad
      -- base del producto — gate de stock y pata APPLY usan este valor.
      v_apply_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      IF v_stock_sum < v_apply_qty_norm THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal = v_final_* (F1 §D3),
      -- unit_id = v_item.unit_id (F1 §D7, viaja con la línea).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (COALESCE(v_author, v_uid), v_account_id, p_client_id, v_item.product_id,
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
        v_final_branch_id, -v_apply_qty_norm, 'sale', v_new_sale_id, 'sale',
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
        (COALESCE(v_author, v_uid), v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
  -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
  -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
  -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
  -- venta de 665,334 y una factura de round(Σ) = 665,33.
  v_total_sum := round(v_total_sum, 2);

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
  --
  -- venta-editable-vs-promocion-legacy (N3): la orden re-apuntada SIGUE a la
  -- operación también en importes. Re-apuntar sólo sale_operation_id dejaba
  -- total, cliente y líneas VIEJOS: la re-facturación después de anular (D5
  -- de venta-editable-sin-cae) y el "Facturar" de una venta del POS editada
  -- emitían por el importe anterior. El recálculo vive en UN solo lugar,
  -- compartido con la promoción: _sales_order_sync_from_operation. El
  -- predicado del re-apuntado no cambia; el helper de anulación ya corrió
  -- arriba, así que acá sólo llegan órdenes sin comprobante o con uno
  -- rechazado/anulado (a lo sumo una: índice único parcial).
  UPDATE public.sales_orders so
  SET    sale_operation_id = v_new_op_id
  WHERE  so.sale_operation_id = v_old_operation_id
    AND  NOT EXISTS (
      SELECT 1 FROM public.fiscal_documents fd
      WHERE fd.id = so.fiscal_document_id
        AND fd.status IN ('pending_cae', 'authorized')
    )
  RETURNING so.id INTO v_resync_id;

  IF v_resync_id IS NOT NULL THEN
    PERFORM public._sales_order_sync_from_operation(v_resync_id, v_new_op_id, v_account_id);
  END IF;

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

REVOKE ALL ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) TO authenticated;
COMMENT ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) IS
  $c$edicion-preserva-contexto: preserva branch_id/canal/unit_id al editar (F1, tri-estado para branch_id/canal), bloquea la edición de una operación facturada con P0423 (F2), acepta quantity decimal (F3), y re-apunta sales_orders promovida sin comprobante al operation_id nuevo (F1 §D9). Base: #415 (líneas) + #417 (espejo de stock) + #419 (forma de pago). ventas-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la principal.$c$;

-- =============================================================================
-- 8. rpc_atomic_update_purchase_operation
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_supplier_id uuid DEFAULT NULL::uuid, p_supplier_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_author          uuid;   -- multiusuario-operativo (tanda B): autor de la operación que se edita
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

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'purchases'], 'tu rol no permite editar compras (requiere compras, administrador o dueño)');

  IF array_length(p_purchase_ids, 1) IS NULL OR array_length(p_purchase_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No purchase IDs provided' USING ERRCODE = 'P0400';
  END IF;

  -- multiusuario-operativo (tanda B, D8): el documento tiene que ser de la CUENTA ACTIVA, no del caller. Una compra de
  -- otra cuenta es indistinguible de una inexistente (P0404, mismo texto).
  IF (SELECT COUNT(*) FROM public.purchases WHERE id = ANY(p_purchase_ids) AND account_id = v_account_id)
      != array_length(p_purchase_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): sobre una compra de OTRO miembro sólo puede el dueño o un administrador;
  -- el resto corrige lo propio (P0403). La autoría se CONSERVA en las filas nuevas (v_author).
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT p.user_id) FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)),
    'solo el dueño o un administrador modifican las compras que cargó otro miembro');
  SELECT p.user_id INTO v_author FROM public.purchases p WHERE p.id = ANY(p_purchase_ids) ORDER BY p.id LIMIT 1;

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
        AND account_id = v_account_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
      -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

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
        (COALESCE(v_author, v_uid), v_account_id, v_item.product_id,
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
        (COALESCE(v_author, v_uid), v_account_id, NULL,
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
-- 9. rpc_delete_sale_operation
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_delete_sale_operation(p_sale_id uuid DEFAULT NULL::uuid, p_operation_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS boolean
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
  -- remitos-venta (D9): venta nacida de un remito.
  v_source_dn            uuid;
  v_so_branch_id         uuid;
  v_dn_label             text;
  v_dn_status            text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite eliminar ventas (requiere vendedor, cajero, administrador o dueño)');

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

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción,
  -- mismo ancla y mismo orden que la edición (sales → sales_orders →
  -- fiscal_documents). Las filas se toman ANTES de resolver la orden: si una
  -- promoción las tiene, se espera a que commitee y la orden que creó se ve
  -- (y se cancela) más abajo; si otra edición o borrado ganó, el conjunto
  -- se recalcula bajo el lock y, vacío, no hay nada que borrar.
  SELECT array_agg(l.id ORDER BY l.id) INTO v_sale_ids
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(v_sale_ids)
      AND  s.account_id = v_account_id
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): borrar la venta de OTRO miembro es del dueño o de un administrador; el
  -- resto borra lo propio (P0403). Va sobre las filas YA tomadas con FOR UPDATE (la autoría no cambia) y antes de cualquier
  -- compensación o escritura. Una venta de otra cuenta nunca llega acá: las filas se resuelven por la cuenta activa.
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT s.user_id) FROM public.sales s WHERE s.id = ANY(v_sale_ids)),
    'solo el dueño o un administrador modifican las ventas que cargó otro miembro');

  -- sales_order asociada (camino POS) — misma convención que el guard P0423.
  SELECT id, status INTO v_sales_order_id, v_so_status
  FROM public.sales_orders
  WHERE sale_operation_id = v_operation_key;

  v_reference_ids := ARRAY[v_operation_key];
  IF v_sales_order_id IS NOT NULL THEN
    v_reference_ids := v_reference_ids || v_sales_order_id;
  END IF;

  -- ── remitos-venta (D9): venta nacida de un remito ─────────────────────────
  -- La sucursal del remito (= la de la orden) tiene que estar activa y no
  -- cerrada ANTES de cualquier efecto: el guard de baja de sucursal no cuenta
  -- los remitos converted, así que una sucursal se puede vaciar y desactivar
  -- con un remito convertido; sin este guard, borrar la venta devolvería el
  -- remito a issued en una sucursal muerta (la conversión lo rechazaría y la
  -- anulación devolvería stock a una sucursal que no opera). FOR SHARE: una
  -- desactivación concurrente espera a este commit.
  IF v_sales_order_id IS NOT NULL THEN
    SELECT so.source_delivery_note_id, so.branch_id INTO v_source_dn, v_so_branch_id
    FROM public.sales_orders so
    WHERE so.id = v_sales_order_id;
  END IF;

  IF v_source_dn IS NOT NULL THEN
    SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'del remito') INTO v_dn_label
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn;

    PERFORM 1
    FROM public.branches b
    WHERE b.id = v_so_branch_id
      AND b.account_id = v_account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito % está desactivada o cerrada — reactivala antes de eliminar la venta', v_dn_label
        USING ERRCODE = 'P0422';
    END IF;
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
  -- remitos-venta (D9): una venta nacida de un remito NO repone stock: la
  -- mercadería quedó entregada con el remito, que vuelve a pendiente más
  -- abajo (para devolverla al stock se anula el remito). El salto es
  -- explícito: no depende de que esas filas sales no tengan movimientos.
  IF v_source_dn IS NULL THEN
    FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
      PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
    END LOOP;
  END IF;

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

  -- ── remitos-venta (D9, R5): el remito vuelve a pendiente ─────────────────
  -- Lock del remito AL FINAL (sales -> sales_orders -> fiscal_documents ->
  -- delivery_notes). La orden ya pasó a canceled, así que el índice único
  -- parcial queda libre y el remito se puede volver a convertir. La
  -- transición converted -> issued no tiene rol propio: este borrado ya
  -- registró sales_order confirmed -> canceled, que exige admin/owner.
  IF v_source_dn IS NOT NULL AND v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    SELECT dn.status INTO v_dn_status
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn
    FOR UPDATE;

    IF v_dn_status = 'converted' THEN
      PERFORM public.record_status_transition(
        v_account_id, 'delivery_note_sale', v_source_dn, 'converted', 'issued',
        v_uid, format('Venta eliminada (operación %s)', v_operation_key)
      );

      UPDATE public.delivery_notes
      SET status = 'issued', updated_at = now(), updated_by = v_uid
      WHERE id = v_source_dn;
    END IF;
  END IF;

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(v_sale_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) IS
  $c$delete-guard-ledgers: RPC atómica de borrado de venta — guard fiscal (P0423), compensa cuenta corriente (P0425), caja (P0426) y banco, revierte stock (#417), emite SaleOperationDeleted, cancela la sales_order del POS. Acepta p_sale_id (delete_by_id) o p_operation_id (delete_by_operation).$c$;

-- =============================================================================
-- 10. rpc_delete_purchase_operation
-- =============================================================================
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

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'purchases'], 'tu rol no permite eliminar compras (requiere compras, administrador o dueño)');

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

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): borrar la compra de OTRO miembro es del dueño o de un administrador; el
  -- resto borra lo propio (P0403). Antes de tomar el remito de origen y de cualquier compensación. Una compra de otra
  -- cuenta nunca llega acá: las filas se resuelven por la cuenta activa.
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT p.user_id) FROM public.purchases p WHERE p.id = ANY(v_purchase_ids)),
    'solo el dueño o un administrador modifican las compras que cargó otro miembro');

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
-- 11. Introspección: lo que esta migración promete, verificado en la base viva
-- =============================================================================
-- Falla la migración (y la reaplicación de CI) si alguna de las nueve funciones quedó sin el
-- filtro de cuenta, con el guard por autor, sin overload único o con la ACL cambiada.
DO $$
DECLARE
  v_fn   text;
  v_src  text;
  v_n    integer;
BEGIN
  FOR v_fn IN SELECT unnest(ARRAY[
      'rpc_create_sale_operation', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
      'rpc_create_purchase_operation_v2', 'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
      'rpc_delete_sale_operation', 'rpc_delete_purchase_operation', '_purchase_operation_core'])
  LOOP
    SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): % tiene % definiciones vivas', v_fn, v_n;
    END IF;
    SELECT regexp_replace(regexp_replace(prosrc, '/\*.*?\*/', '', 'gs'), '--[^\n\r]*', '', 'g') INTO v_src
    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_src ~* 'v_product\.user_id' OR v_src ~* 'user_id\s*(<>|!=)\s*v_uid' THEN
      RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): % todavía autoriza por el autor', v_fn;
    END IF;
  END LOOP;

  -- El filtro de cuenta DENTRO del SELECT … FOR UPDATE del producto, donde hay producto que bloquear.
  FOR v_fn IN SELECT unnest(ARRAY[
      'rpc_create_sale_operation', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation_v2',
      'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation', '_purchase_operation_core'])
  LOOP
    SELECT regexp_replace(regexp_replace(regexp_replace(prosrc, '/\*.*?\*/', '', 'gs'), '--[^\n\r]*', '', 'g'), '\s+', ' ', 'g') INTO v_src
    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_src !~* 'FROM\s+public\.products\s+WHERE\s+id\s*=\s*v_item\.product_id\s+AND\s+account_id\s*=\s*v_account_id\s+FOR UPDATE' THEN
      RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): % no filtra por la cuenta dentro del FOR UPDATE del producto', v_fn;
    END IF;
  END LOOP;

  -- El guard de rol en las siete funciones públicas / internas que lo llevan (el núcleo no: lo decide el wrapper).
  FOR v_fn IN SELECT unnest(ARRAY[
      'rpc_create_sale_operation', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
      'rpc_create_purchase_operation_v2', 'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
      'rpc_delete_sale_operation', 'rpc_delete_purchase_operation'])
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_src NOT LIKE '%_account_assert_capability(v_account_id, ARRAY[%' THEN
      RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): % no llama a _account_assert_capability', v_fn;
    END IF;
  END LOOP;
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = '_purchase_operation_core';
  IF v_src LIKE '%_account_assert_capability%' THEN
    RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): _purchase_operation_core no debe exigir CAN_PURCHASE (la conversión de un remito lo reusa con el rol de remitos)';
  END IF;

  -- La regla de autor en las cuatro funciones de edición y borrado.
  FOR v_fn IN SELECT unnest(ARRAY[
      'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
      'rpc_delete_sale_operation', 'rpc_delete_purchase_operation'])
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_src NOT LIKE '%_account_assert_document_authority(%' THEN
      RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): % no aplica la regla de autor (OQ-4 b)', v_fn;
    END IF;
  END LOOP;

  -- ACL: las siete públicas siguen ejecutables por authenticated y nunca por anon; la v2 de compra y el núcleo, por ninguno.
  FOR v_fn IN SELECT unnest(ARRAY[
      'rpc_create_sale_operation', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
      'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
      'rpc_delete_sale_operation', 'rpc_delete_purchase_operation'])
  LOOP
    IF NOT has_function_privilege('authenticated', (SELECT oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn), 'EXECUTE')
       OR has_function_privilege('anon', (SELECT oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn), 'EXECUTE') THEN
      RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): la ACL de % cambió', v_fn;
    END IF;
  END LOOP;
  FOR v_fn IN SELECT unnest(ARRAY['rpc_create_purchase_operation_v2', '_purchase_operation_core', '_account_assert_capability', '_account_assert_document_authority'])
  LOOP
    IF has_function_privilege('authenticated', (SELECT oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn), 'EXECUTE')
       OR has_function_privilege('anon', (SELECT oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn), 'EXECUTE') THEN
      RAISE EXCEPTION 'multiusuario-operativo tanda B (introspección): % es ejecutable por anon o authenticated', v_fn;
    END IF;
  END LOOP;

  RAISE NOTICE 'multiusuario-operativo tanda B (introspección OK): 9 funciones sin guard por autor, filtro de cuenta en el FOR UPDATE del producto, guard de rol y regla de autor presentes, una definición viva y ACLs intactas';
END $$;
