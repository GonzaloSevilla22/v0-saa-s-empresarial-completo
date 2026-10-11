-- =============================================================================
-- MIGRATION: 20261076000001_compras_gastos_sucursal_por_defecto.sql
-- CHANGE: compras-gastos-sucursal-por-defecto (2026-10-11) — governance MEDIA con
--         un tramo de severidad ALTA: reescribe las funciones que mueven stock,
--         caja y banco en el alta y la edición de compras, y la edición de gastos.
--         Change hermano de ventas-sucursal-por-defecto (20261075000001/2). No hay
--         migración de datos: los históricos NO se rellenan (OQ-1 (a)).
--
-- DECISIÓN DEL PO: al firmar ventas-sucursal-por-defecto (2026-10-09, «vamos con
-- todo lo recomendado») eligió, para compras y gastos, un change hermano sin tocar
-- las compras viejas. Sign-off de las Open Questions de ESTE change (2026-10-11,
-- «vamos con todo lo recomendado»): OQ-1 (a) históricos sin backfill, OQ-2 (a) la
-- compra en una sucursal CERRADA se rechaza, OQ-3 (a) el gasto sin sucursal
-- operativa se registra como hoy (sin guard).
--
-- PROBLEMA: una compra registrada SIN sucursal elegida se guardaba con
-- purchases.branch_id = NULL, pero esa compra no ocurrió en ningún lado: su stock
-- ENTRABA en la sucursal principal (c21_apply_branch_stock_delta resuelve
-- c26_default_branch por dentro). La fila, su movimiento de stock y su movimiento
-- bancario quedaban en NULL, el ledger rompía su invariante de reconstrucción por
-- (producto, sucursal), y —el defecto que el PO nombró— el opt-in de caja de esa
-- compra se rechazaba SIEMPRE: el formulario lo ofrece PRE-MARCADO con la sesión de
-- la principal y el servidor comparaba la sesión contra el p_branch_id CRUDO (NULL)
-- y devolvía P0422 cash_optin_requires_open_session. Y la edición de compra y de
-- gasto podía dejar (o conservar) una fila sin sucursal.
--
-- QUÉ HACE (design D1-D5):
--   D1/D2  rpc_create_purchase_operation resuelve UNA vez
--          v_gate_branch := COALESCE(p_branch_id, c26_default_branch(cuenta)) y la
--          usa en los dos INSERT en purchases (con y sin producto), el delta de
--          stock (explícita, ya no la resuelve c21 por dentro), el movimiento de
--          stock, la condición de sucursal del opt-in de caja y el movimiento
--          bancario.
--   D3     Sin sucursal elegida y sin sucursal OPERATIVA a la cual resolver
--          (ninguna, o todas inactivas o cerradas): P0422 no_branch_found antes de
--          escribir nada (mismo token y código que la venta). Una sucursal ELEGIDA
--          cerrada se rechaza con P0422 branch_closed (OQ-2 (a); el bloque literal
--          de rpc_create_expense): la spec branches ya lo exigía.
--   D5     rpc_atomic_update_purchase_operation: para la COMPRA, NULL significa "la
--          principal" (BREAKING del contrato interno de edición): un branch_id
--          informado como NULL, o una fila vigente sin sucursal, se resuelve a
--          c26_default_branch ANTES del REVERSE, con el mismo guard no_branch_found.
--   D4/D5  rpc_update_expense: un nulo de sucursal, informado o vigente, se resuelve
--          con la MISMA regla que el alta del gasto (COALESCE con la principal).
--          Sin guard de operativa (OQ-3 (a)). rpc_create_expense NO se toca.
--
-- CASO A DE D6 (coordinación con remitos-compra tanda B): el checkpoint 0 verificó
-- (2026-10-11) que public._purchase_operation_core NO existe: remitos-compra sigue en
-- su tanda A, sin tanda B ni PR. Este change reescribe rpc_create_purchase_operation
-- entera. La tanda B extraerá su núcleo DESDE este cuerpo (su checkpoint partirá del
-- cuerpo vivo y anotará el desvío); en su modo remito p_branch_id es siempre la
-- sucursal del remito (nunca NULL), así que el guard no se activa y el COALESCE es la
-- identidad.
--
-- REGLA PARA EL PR SIGUIENTE: una migración posterior que redefina cualquiera de estas
-- tres funciones (p. ej. remitos-compra tanda B) tiene que RETIRAR el bloque de
-- reaplicación de 20261076000001 en KPI_Validation.yml en el mismo PR (su preflight
-- abortaría, igual que el de 20261062000001 y el de 20261075000001) y apuntar el bloque
-- (0) de supabase/tests/test_compras_gastos_sucursal_por_defecto.sql al cuerpo que
-- contenga la lógica (el núcleo), actualizando los md5.
--
-- CUERPOS DE PARTIDA (md5 de prosrc sin \r, verificados el 2026-10-11 contra
-- producción gxdhpxvdjjkmxhdkkwyb —323 migraciones, max(version)=20261075000002, sólo
-- SELECT, por el orquestador— y contra la base local construida desde los archivos:
-- IDÉNTICOS):
--   rpc_create_purchase_operation         0366977251522a469d123c4d143f42f9  (20261062000001_ventas_unidades_conversion.sql)
--   rpc_atomic_update_purchase_operation  23558c073cf71d08ea4a0dfb15079555  (20261062000001_ventas_unidades_conversion.sql)
--   rpc_update_expense                    360d4dc4320208b56eb106d82c7b38c3  (20261043000001, gastos-forma-pago)
--
-- Reescritura con CREATE OR REPLACE y la MISMA firma (sin DROP, sin overload, sin
-- 42725). La ACL se conserva y se re-emite idéntica (anon sin EXECUTE). El alta de
-- compra no tenía COMMENT y no se le agrega; el de la edición de compra se re-declara
-- IDÉNTICO (no menciona la sucursal); el de rpc_update_expense se re-declara completo
-- más la excepción de D5, porque «aplica el contrato tri-estado … a sucursal» deja de
-- ser cierto para un branch_id nulo. El diff contra cada cuerpo vivo es EXACTAMENTE lo
-- de D2 más un comentario `-- compras-gastos-sucursal-por-defecto (Dn):` en cada punto
-- tocado (y el reemplazo del comentario de caja, que describía el contrato viejo).
--
-- Orden global de locks intacto: ni el guard ni el COALESCE toman locks nuevos
-- (c26_default_branch es un SELECT sin FOR UPDATE).
--
-- Gates: supabase/tests/test_compras_gastos_sucursal_por_defecto.sql (ejecuta las tres
-- RPCs) y test_gastos_forma_pago.sql (4.3b/4.3c/4.4/4.4b cambiados a propósito).
-- KPI_Validation.yml los cablea y reaplica esta migración AL FINAL de la cadena,
-- después de 20261075000001/2: su reaplicación imprime los tres NOTICE de
-- reaplicación.
-- =============================================================================

-- ─── 0. Preflight: integridad de función ───────────────────────────────────────
-- Cada cuerpo se reescribe desde su cuerpo VIVO. Si el del stack que aplica esta
-- migración no es ni el de partida ni el que ella deja (una migración
-- intermedia que nadie reconcilió), se ABORTA en vez de pisarlo en silencio —
-- regla de integridad de función (20261060000001, molde de 20261075000001).
DO $$
DECLARE
  v_expected jsonb := jsonb_build_object(
    'rpc_create_purchase_operation',        '0366977251522a469d123c4d143f42f9',
    'rpc_atomic_update_purchase_operation', '23558c073cf71d08ea4a0dfb15079555',
    'rpc_update_expense',                   '360d4dc4320208b56eb106d82c7b38c3'
  );
  -- Cuerpo que ESTA migración deja (reaplicación). Medidos de pg_proc en el stack
  -- local después de aplicar este archivo.
  v_rewritten jsonb := jsonb_build_object(
    'rpc_create_purchase_operation',        '361a1ffc0c3e31ee2bb1b677cfab2394',
    'rpc_atomic_update_purchase_operation', '2d4c92f6fd3dbfd52d2225edb0a82827',
    'rpc_update_expense',                   'bb8e7d02f737937fdd120804722a3151'
  );
  v_fn  text;
  v_md5 text;
  v_bad text[] := '{}';
  v_n_partida      integer := 0;
  v_n_reaplicacion integer := 0;
BEGIN
  FOR v_fn IN SELECT jsonb_object_keys(v_expected) LOOP
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_md5 = (v_expected ->> v_fn) THEN
      v_n_partida := v_n_partida + 1;
    ELSIF v_md5 = (v_rewritten ->> v_fn) THEN
      v_n_reaplicacion := v_n_reaplicacion + 1;
      RAISE NOTICE 'compras-gastos-sucursal-por-defecto: % ya es el cuerpo de esta migración (reaplicación)', v_fn;
    ELSE
      v_bad := v_bad || format('%s: esperado %s (partida) o %s (reaplicación), vivo %s',
        v_fn, v_expected ->> v_fn, v_rewritten ->> v_fn, COALESCE(v_md5, '(no existe)'));
    END IF;
  END LOOP;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'compras-gastos-sucursal-por-defecto: el cuerpo vivo de partida difiere del verificado contra prod el 2026-10-11 — reconciliar antes de reescribir: %',
      array_to_string(v_bad, '; ');
  END IF;
  RAISE NOTICE 'compras-gastos-sucursal-por-defecto: % cuerpos reescritos desde el cuerpo de partida verificado por md5, % ya reaplicados',
    v_n_partida, v_n_reaplicacion;
END $$;

-- ─── 1. rpc_create_purchase_operation ──────────────────────────────────────────
-- Desde su cuerpo vivo (== el de 20261062000001_ventas_unidades_conversion.sql). Cambios:
-- branch_closed para una sucursal elegida cerrada (D3, OQ-2), v_gate_branch + el guard
-- no_branch_found (D1/D3) y v_gate_branch en los seis puntos (D1/D2).
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_supplier_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
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
                   AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
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

            -- compras-gastos-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o
            -- la principal), la misma con la que entra el stock — no el p_branch_id crudo.
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 v_gate_branch, p_cost_center_id, p_payment_method_id,
                 p_supplier_id,
                 v_product.name, v_product.sku, v_product.cost, NULL)
            RETURNING id INTO v_new_purchase_id;

            IF v_flag_on THEN
                INSERT INTO public.purchase_items (
                    purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
                    name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
                ) VALUES (
                    v_new_purchase_id, v_item.product_id, v_account_id, NULL,
                    v_item.quantity, v_item.unit_id,
                    v_item.amount, v_item.amount * v_item.quantity,
                    v_product.name, v_product.sku, v_product.cost, NULL
                );
            END IF;

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

        ELSE
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

    RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
    );
END;
$function$;

-- ─── 2. rpc_atomic_update_purchase_operation ───────────────────────────────────
-- Desde su cuerpo vivo (== el de 20261062000001_ventas_unidades_conversion.sql). Cambio:
-- COALESCE con la principal y el guard, después del tri-estado y ANTES del REVERSE (D5).
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

-- ─── 3. rpc_update_expense ──────────────────────────────────────────────────────
-- Desde su cuerpo vivo (== el de 20261043000001, gastos-forma-pago). Cambio: COALESCE con la
-- principal después del tri-estado, sin guard (D4/D5, OQ-3 (a)).
CREATE OR REPLACE FUNCTION public.rpc_update_expense(p_expense_id uuid, p_category text DEFAULT NULL::text, p_amount numeric DEFAULT NULL::numeric, p_date date DEFAULT NULL::date, p_description text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_old                 RECORD;
  v_branch              RECORD;
  v_final_payment_method_id uuid;
  v_final_branch_id     uuid;
  v_final_cost_center_id    uuid;
  -- asiento-contable-gastos (D7): valores finales resultantes de la edición,
  -- para la carga de ExpenseAdjusted — mismo mapeo que ExpenseCreated.
  v_final_amount        numeric;
  v_final_date          date;
  v_final_kind          text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede editar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Localización POR TENANT: si el gasto no aparece, P0404 — sin distinguir
  -- "no existe" de "es de otra cuenta" (D4).
  SELECT * INTO v_old
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── D11: los dos guards de inmutabilidad, ANTES DE CUALQUIER ESCRITURA ────
  -- Mismos predicados y mismo ERRCODE que rpc_atomic_update_sale_operation
  -- (baseline). Los mensajes son distinguibles a propósito: el usuario tiene
  -- que saber cuál de los dos libros produjo el bloqueo.
  --
  -- asiento-contable-gastos (D6): la existencia de un ASIENTO contable NO se
  -- suma a estos guards. Un gasto sin movimiento de caja ni bancario sigue
  -- siendo plenamente editable aunque ya tenga su asiento posteado; la
  -- edición lo corrige por el par contra-asiento/asiento nuevo más abajo.
  IF EXISTS (
    SELECT 1 FROM public.cash_movements cm
    WHERE cm.reference_id = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_cash_movement_immutable: el gasto tiene un movimiento de caja posteado y no puede editarse — borralo y volvé a cargarlo (el borrado compensa la caja)'
      USING ERRCODE = 'P0423';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_bank_movement_immutable: el gasto tiene un movimiento bancario posteado y no puede editarse — borralo y volvé a cargarlo (el borrado registra el movimiento espejo)'
      USING ERRCODE = 'P0423';
  END IF;

  -- ── Importe positivo, espejo del alta ─────────────────────────────────────
  -- Sin esto la edición sería el bypass del guard del alta: un gasto legítimo
  -- pasaría a importe negativo con un solo PUT. `NULL` conserva la semántica
  -- COALESCE heredada del UPDATE que este RPC reemplaza ("no cambia"), y por
  -- eso el predicado es IS NOT NULL AND <= 0 y no el del alta.
  IF p_amount IS NOT NULL AND p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── D12: tri-estado, campo por campo, con validación ANTES del UPDATE ─────
  IF p_payment_method_provided THEN
    -- ⚠️ La validación de reimputación se aplica SÓLO cuando el valor cambia.
    -- El formulario manda `paymentMethodId` SIEMPRE (está en el literal del
    -- payload) y en edición ofrece a propósito las formas dadas de baja
    -- (`includeInactive={isEdit}`, para que un gasto histórico siga nombrando
    -- la suya). Con el predicado aplicado sin excepción, desactivar una forma
    -- de pago volvía INOPERABLE todo gasto que la usara: cualquier edición
    -- —aunque sólo tocara el importe— rebotaba con P0404 hasta reactivarla.
    -- Reenviar el valor vigente es PRESERVAR, no reimputar. La TENENCIA sí se
    -- verifica siempre: lo que se relaja es `is_active`/`deleted_at`, nunca el
    -- `account_id`. Gate: sección 8.7, con control negativo (cambiar a OTRA
    -- forma inactiva sigue siendo P0404).
    IF p_payment_method_id IS NOT NULL
       AND p_payment_method_id IS DISTINCT FROM v_old.payment_method_id THEN
      -- Mismo predicado que el alta: cuenta + activa + no borrada.
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
      -- D3 también en la edición: la API no puede ser un bypass del selector.
      IF (SELECT kind FROM public.payment_methods WHERE id = p_payment_method_id) = 'credit' THEN
        RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
          USING ERRCODE = 'P0400';
      END IF;
    ELSIF p_payment_method_id IS NOT NULL THEN
      -- Reenvío del valor vigente: sólo tenencia (el gasto ya es del tenant,
      -- pero la FK de payment_methods no está scopeada por cuenta y el guard
      -- de tenencia no se relaja nunca — lección de cuenta-corriente-party-guard).
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old.payment_method_id;
  END IF;

  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old.branch_id;
  END IF;

  -- compras-gastos-sucursal-por-defecto (D4/D5): un nulo de sucursal, informado o vigente
  -- (gasto histórico), se resuelve con la MISMA regla que el alta del gasto
  -- (rpc_create_expense): COALESCE con la principal. Sin guard de sucursal operativa
  -- (OQ-3 (a)): el gasto no mueve mercadería y el alta persiste el fallback. La
  -- intención de desimputar la sucursal desaparece del contrato tri-estado; forma de
  -- pago y centro de costo conservan las tres intenciones.
  v_final_branch_id := COALESCE(v_final_branch_id, public.c26_default_branch(v_account_id));

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
    v_final_cost_center_id := v_old.cost_center_id;
  END IF;

  UPDATE public.expenses
  SET category          = COALESCE(p_category, v_old.category),
      amount            = COALESCE(p_amount, v_old.amount),
      date              = COALESCE(p_date::timestamptz, v_old.date),
      description       = COALESCE(p_description, v_old.description),
      payment_method_id = v_final_payment_method_id,
      branch_id         = v_final_branch_id,
      cost_center_id    = v_final_cost_center_id
  WHERE id = p_expense_id AND account_id = v_account_id;

  -- ── asiento-contable-gastos (D7): ExpenseAdjusted, SÓLO si existe el alta ──
  -- El predicado evalúa la EXISTENCIA DEL EVENTO de alta, nunca la del
  -- asiento: un gasto creado y editado/borrado dentro de la misma ventana de
  -- relay tiene su ExpenseCreated sin procesar y todavía no tiene asiento, y
  -- tiene que emitir igual — el relay procesa en orden de ocurrencia y el
  -- fallo recuperable (P0451) del consumidor resuelve si quedan en corridas
  -- distintas. Un gasto histórico (sin ExpenseCreated) no emite nada: si
  -- emitiera, el consumidor jamás encontraría el asiento original y
  -- reintentaría con P0451 cada minuto, para siempre (evento envenenado).
  IF EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'ExpenseCreated' AND aggregate_type = 'Expense' AND aggregate_id = p_expense_id AND account_id = v_account_id
  ) THEN
    v_final_amount := COALESCE(p_amount, v_old.amount);
    v_final_date   := COALESCE(p_date, v_old.date::date);

    -- Corrección de findings (revisor, ronda 1, major): el `kind` que decide
    -- la CONTRAPARTIDA del asiento se deriva de lo que REALMENTE ocurrió en
    -- los libros de dinero (design.md D4: "el asiento nombra la cuenta del
    -- libro que efectivamente se movió"), NUNCA de la forma de pago
    -- declarada en el edit. rpc_update_expense jamás llama a
    -- _pay_register_operation_bank_movement ni a c28_register_cash_movement
    -- (la edición no mueve dinero, D6) — y el guard de inmutabilidad de
    -- arriba ya garantiza que, si llegamos hasta acá, el gasto NO tiene
    -- ningún bank_movement posteado. Sin este fix, cambiar la forma de pago
    -- a un kind bancario en la edición acreditaría 1110 Banco sin que exista
    -- ningún movimiento bancario real que lo respalde — un descuadre de
    -- conciliación esperando a pasar. La rama IS NULL (verdadera 100% del
    -- tiempo, por el guard de arriba) queda declarada por robustez, no por
    -- necesidad: si alguna vez cambia el guard, este derivado sigue siendo
    -- correcto sin tocarlo.
    IF EXISTS (
      SELECT 1 FROM public.bank_movements bm
      WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
    ) THEN
      -- Los cuatro kind bancarios son equivalentes para
      -- _journal_expense_credit_account (todos → 1110): cualquiera sirve.
      v_final_kind := 'transfer';
    ELSE
      v_final_kind := NULL;
    END IF;

    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload)
    VALUES (
      v_account_id, 'ExpenseAdjusted', 'Expense', p_expense_id,
      jsonb_build_object(
        'account_id', v_account_id,
        'expense_id', p_expense_id,
        'amount', v_final_amount,
        'expense_date', v_final_date,
        'cost_center_id', v_final_cost_center_id,
        'kind', v_final_kind
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'payment_method_id', v_final_payment_method_id,
    'branch_id',         v_final_branch_id,
    'cost_center_id',    v_final_cost_center_id
  );
END;
$function$;

-- ─── 4. COMMENT y ACL ──────────────────────────────────────────────────────────
-- COMMENT de la edición de compra: el vivo, IDÉNTICO (no menciona la sucursal). El de la
-- edición de gasto: el vivo completo más la excepción de D5. Sin COMMENT en el alta de
-- compra (no tenía).
COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) IS 'caja-compras-cobranzas (D8): el guard P0423 suma un tercer EXISTS contra
  cash_movements (movement_type=purchase_payment) — una compra con caja
  posteada también pasa a ser inmutable. Mismo predicado en el derivado de
  lectura del listado (backend/repositories/purchase_repository.py).';
COMMENT ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) IS 'gastos-forma-pago: edición atómica del gasto. Bloquea con P0423 el gasto con
  movimiento de caja o bancario posteado, con mensajes distinguibles y ANTES de
  cualquier escritura (D11), y aplica el contrato tri-estado
  (p_<campo>, p_<campo>_provided) a forma de pago, sucursal y centro de costo
  (D12). NO postea movimientos: imputar una forma de pago por edición es sólo
  una etiqueta (D13). compras-gastos-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la sucursal por defecto, como en el alta.';

-- ACL: la de CREATE OR REPLACE se conserva; se re-emite idéntica a la viva
-- (postgres, authenticated y service_role con EXECUTE; anon sin EXECUTE).
REVOKE ALL ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated, service_role;

-- ─── 5. Introspección ──────────────────────────────────────────────────────────
-- El md5 vivo de cada función es el `v_rewritten` del preflight, hay una sola firma por
-- función, la ACL no cambió, el alta de compra sigue sin COMMENT, el de la edición de
-- compra se conserva y el de la edición de gasto suma la excepción de D5. Si algo no
-- cierra, la migración ABORTA.
DO $$
DECLARE
  v_rewritten jsonb := jsonb_build_object(
    'rpc_create_purchase_operation',        '361a1ffc0c3e31ee2bb1b677cfab2394',
    'rpc_atomic_update_purchase_operation', '2d4c92f6fd3dbfd52d2225edb0a82827',
    'rpc_update_expense',                   'bb8e7d02f737937fdd120804722a3151'
  );
  v_fn  text;
  v_md5 text;
  v_n   integer;
  v_oid oid;
  v_bad text[] := '{}';
BEGIN
  FOR v_fn IN SELECT jsonb_object_keys(v_rewritten) LOOP
    SELECT COUNT(*), md5(replace(MIN(p.prosrc), E'\r', '')), MIN(p.oid)::oid
      INTO v_n, v_md5, v_oid
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_n <> 1 THEN
      v_bad := v_bad || format('%s: %s firmas (debía haber una)', v_fn, v_n);
      CONTINUE;
    END IF;
    IF v_md5 IS DISTINCT FROM (v_rewritten ->> v_fn) THEN
      v_bad := v_bad || format('%s: md5 vivo %s, esperado %s', v_fn, v_md5, v_rewritten ->> v_fn);
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || format('%s: anon tiene EXECUTE', v_fn);
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || format('%s: authenticated o service_role perdieron EXECUTE', v_fn);
    END IF;
  END LOOP;
  IF obj_description('public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)'::regprocedure, 'pg_proc') IS NOT NULL THEN
    v_bad := v_bad || 'rpc_create_purchase_operation: no tenía COMMENT y no se le agrega uno';
  END IF;
  IF position('caja-compras-cobranzas (D8)' IN COALESCE(obj_description('public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'pg_proc'), '')) = 0 THEN
    v_bad := v_bad || 'COMMENT de rpc_atomic_update_purchase_operation: no conserva el texto vivo';
  END IF;
  IF position('compras-gastos-sucursal-por-defecto' IN COALESCE(obj_description('public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'pg_proc'), '')) = 0 THEN
    v_bad := v_bad || 'COMMENT de rpc_update_expense: sin la excepción de D5';
  END IF;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'compras-gastos-sucursal-por-defecto (introspección) FAILED: %', array_to_string(v_bad, ' | ');
  END IF;
  RAISE NOTICE 'compras-gastos-sucursal-por-defecto (introspección) OK: tres cuerpos con la sucursal resuelta, una firma por función, ACL y COMMENT conservados';
END $$;
