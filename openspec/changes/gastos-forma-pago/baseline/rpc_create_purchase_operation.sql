-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-29, via
-- pg_get_functiondef(oid) -- task 1.6 de gastos-forma-pago.
-- MAX(version) al momento de la captura: 20261014000001 (263 migraciones).
-- md5(pg_get_functiondef) = 058f4d291d85bec0ae46589bde49e3a3 - length = 19438.
-- Rol en el change: REFERENCIA (no se toca): de aca se copia la llamada incondicional a _pay_register_operation_bank_movement con direction 'out' (D2).
--
-- Procedencia del byte exacto: el cuerpo se materializo desde el stack local
-- (supabase db reset sobre las mismas 263 migraciones) y se verifico contra PROD
-- por md5 EXACTO del pg_get_functiondef vivo. El stack local guarda CR embebidos
-- (los .sql del working tree estan en CRLF por core.autocrlf=true), por eso el
-- hash se calcula sobre replace(def, chr(13), '') -- que da byte-identico a PROD.

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_supplier_id uuid DEFAULT NULL::uuid)
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
  helper compartido _pay_register_party_charge (D8 — cero lógica nueva de
  cuenta corriente: la pata 'supplier' del helper estaba escrita desde
  pagos-cableados-restantes y sin ningún llamador). Dos guards nuevos, ambos
  con ERRCODEs YA existentes (D6, sin acuñar códigos nuevos): pertenencia del
  proveedor a la cuenta (P0404) y credit_requires_supplier (P0400, espejo
  exacto de credit_requires_client del lado venta). El disparo del cargo usa
  v_kind CRUDO — misma distinción que ya hace el movimiento bancario.
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
    v_unit_factor     numeric(20,10);
    v_qty_norm        numeric(15,4);
    v_stock_sum       numeric(15,4);   -- C-21: Σ branch_stock (reemplaza products.stock)
    v_inserted        integer;
    v_total_sum       numeric(15,2) := 0;
    v_kind            text;            -- pagos-cableados-restantes (D7)
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
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.branches
            WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P0404';
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
    -- NOTA: el ERRCODE es 'P0404' (5 chars), NO 'P404' como branch_not_found/
    -- cost_center_not_found un poco más arriba en esta misma función —
    -- descubierto en CI (2026-08-19): plpgsql's RAISE ... USING ERRCODE
    -- exige un nombre de condición reconocido o un código de 5 caracteres;
    -- 'P404' (4 chars) revienta en runtime con "unrecognized exception
    -- condition" en vez de levantar el error intencional. Es un bug
    -- preexistente de cost-center-dimension (nunca antes ejercitado por
    -- ningún test) que este change NO corrige — deliberadamente fuera de
    -- alcance, preservando el cuerpo byte a byte — pero el checkeo NUEVO
    -- que este change agrega no puede heredar un patrón roto.
    --
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
    -- cuenta — mismo molde que branch_id/cost_center_id/payment_method_id de
    -- arriba, mismo ERRCODE ya mapeado a 404. Incluye deleted_at IS NULL:
    -- suppliers tiene soft delete desde v3-soft-delete-policy y un proveedor
    -- borrado no puede recibir imputaciones nuevas. Defensa en profundidad —
    -- se mantiene DENTRO de esta RPC (no sólo en
    -- c30_get_or_create_supplier_account) para no depender del orden de merge
    -- con `cuenta-corriente-party-guard`, que endurece ese helper por su lado.
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
    -- acreedor. Espejo exacto de credit_requires_client del lado venta, mismo
    -- ERRCODE 'P0400' (ya mapeado a 400 en _BUSINESS_ERRCODE_STATUS) — NO se
    -- acuña un código nuevo para el caso simétrico.
    --
    -- v_kind CRUDO, no COALESCE(v_kind,'credit'): una compra SIN forma de pago
    -- imputada (el 100% de las 38 históricas) NO es una compra a crédito para
    -- la cuenta corriente, aunque el evento contable de más abajo sí la
    -- propague como 'credit'. Exigirle proveedor rompería toda alta que no
    -- elige método.
    --
    -- Ubicado con los demás guards de parámetros: antes del loop de ítems
    -- (antes de tocar branch_stock/stock_movements) y antes de reservar el
    -- slot de idempotencia — un rechazo no quema la clave, así que el
    -- reintento con la MISMA clave y proveedor tiene éxito real (mismo
    -- criterio que el P0413 de banco-caja-historial-ajustes).
    IF v_kind = 'credit' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
            USING ERRCODE = 'P0400';
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

        -- Idempotency replay: NO emitir evento duplicado (DEC-20)
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

        -- journal-entry-outbox: acumular total para el payload del evento
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
            -- v3-snapshot-pattern: se agrega sku, cost a la lectura ya
            -- existente (sin leer products.stock — DROPeado en C-21).
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

            -- v3-snapshot-pattern (D2): congelar name/sku/cost en purchases
            -- (flat) — es donde el write path REAL de compra escribe la línea.
            -- iva_rate_snapshot NULL (D3: products no tiene columna de IVA).
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id,
                 p_supplier_id,
                 v_product.name, v_product.sku, v_product.cost, NULL)
            RETURNING id INTO v_new_purchase_id;

            -- deudas-menores-agosto (G1): línea de purchase_items condicionada
            -- por el flag (kill-switch). Mismos valores/semántica que
            -- sale_items en rpc_create_sale_operation_v2.
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

            PERFORM public.c21_apply_branch_stock_delta(
                v_account_id, v_item.product_id, p_branch_id, v_qty_norm);

            -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
            INSERT INTO public.stock_movements (
                user_id, account_id, product_id, product_name, type,
                quantity_delta, quantity_before, quantity_after,
                reference_id, reference_type, performed_by,
                operation_group_id, branch_id, unit_cost_snapshot
            ) VALUES (
                v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                v_qty_norm, v_qty_before, v_qty_after,
                v_new_purchase_id, 'purchase', v_uid,
                v_new_op_id, p_branch_id, v_product.cost
            );

        ELSE
            -- cost-center-dimension: p_cost_center_id propagated to non-product rows too
            -- metodos-pago-operaciones: p_payment_method_id propagated to non-product rows too
            -- compras-proveedor-cuenta-corriente (D4): p_supplier_id TAMBIÉN acá —
            -- esta rama ELSE repite la lista de columnas y ya se olvidó una vez.
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id,
                 p_supplier_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- pos-banco-movimientos (D5, task 5.2): movimiento bancario operativo de
    -- EGRESO — v_kind CRUDO (NO el COALESCE(...,'credit') del evento de
    -- abajo): sin payment_method_id imputado, v_kind es NULL y el helper
    -- correctamente no escribe nada (NULL no es un kind bancario).
    PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'out', 'purchase', v_new_op_id,
        p_date, p_branch_id, NULL
    );

    -- compras-proveedor-cuenta-corriente (D8): cargo en la cuenta corriente
    -- del proveedor. UNA SOLA línea de despacho — el escritor sigue siendo el
    -- helper compartido _pay_register_party_charge, que ya resuelve/crea la
    -- SupplierAccount (c30_get_or_create_supplier_account), postea el
    -- movimiento (c30_register_supplier_account_movement) y emite
    -- SupplierAccountCharged.
    --
    -- v_kind CRUDO (NO el COALESCE(...,'credit') del evento de abajo), misma
    -- distinción que el movimiento bancario de arriba: sin payment_method_id
    -- imputado v_kind es NULL y NO se carga nada. Usar el COALESCE haría que
    -- toda compra sin forma de pago endeudara al proveedor en silencio.
    --
    -- reference_id y operation_id son ambos v_new_op_id: en compras no existe
    -- el equivalente de sales_orders, así que no hay la doble convención de
    -- referencia de la venta — el guard P0423 de la edición y
    -- rpc_delete_purchase_operation ya asumen exactamente esto.
    IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
            v_account_id, 'supplier', p_supplier_id, v_total_sum, v_new_op_id, v_new_op_id
        );
    END IF;

    -- ── journal-entry-outbox (Task 4.1): emitir PurchaseCreated en la misma tx ─
    -- pagos-cableados-restantes (D7): 'payment_method' ya NO es el literal
    -- 'credit' — es el kind REAL derivado de p_payment_method_id, con
    -- COALESCE(...,'credit') para preservar el comportamiento sin forma de
    -- pago imputada (las compras que nunca setearon payment_method_id).
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
$function$
