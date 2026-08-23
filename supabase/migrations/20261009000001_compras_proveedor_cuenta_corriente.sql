-- =============================================================================
-- compras-proveedor-cuenta-corriente
-- =============================================================================
-- La cuenta corriente de proveedores existe entera desde C-30 (2026-06-20) y
-- nunca se usó: tablas, RPCs, backend de 3 capas, la pantalla
-- /proveedores/[id]/cuenta y —desde pagos-cableados-restantes (2026-08-20)— el
-- helper compartido _pay_register_party_charge con su pata 'supplier' escrita
-- y ejercitada por tests, pero SIN NINGÚN LLAMADOR. Esta migración conecta esa
-- maquinaria con la realidad:
--
--   1. public.suppliers gana identidad fiscal (RN-96 — FiscalIdentity es un
--      Value Object COMPARTIDO con clients: mismos nombres, mismos tipos,
--      mismo vocabulario de condición IVA) y suppliers.company_id deja de
--      ser NOT NULL (legacy de v20-tenancy-cleanup, nunca ejercitado hasta
--      que el ABM de proveedores de este change hace el primer INSERT real).
--   2. rpc_create_purchase_operation recibe el proveedor (8 -> 9 args) y, si
--      la forma de pago imputada es de kind='credit', postea el cargo real.
--   3. rpc_atomic_update_purchase_operation reimputa proveedor y centro de
--      costo por contrato tri-estado (8 -> 12 args), y rechaza con P0400 que
--      la EDICIÓN convierta una compra en compra a crédito (la edición no
--      postea cargos — review A, SQL-1/BE-2/SEC-1).
--
-- BASELINE (regla dura de la saga): las dos RPCs se reescriben partiendo del
--   cuerpo VIVO en prod (gxdhpxvdjjkmxhdkkwyb), capturado y verificado por
--   md5 en openspec/changes/compras-proveedor-cuenta-corriente/baseline/*.sql
--   — NO del archivo de migración histórico.
--
--   HALLAZGO DEL CHECKPOINT (task 1.4): el cuerpo vivo de
--   rpc_create_purchase_operation NO coincide con el de su última migración
--   literal (20261002000001_pos_banco_movimientos.sql): 14459 -> 14471 chars.
--   Causa benigna y verificada: el bloque G3 de
--   20261003000001_limpiezas_pagos_admin.sql la reescribió IN PLACE con
--   regexp_replace sobre pg_get_functiondef() para expandir 12 ERRCODE de 4
--   chars a 5 ('P400'->'P0400', 'P403'->'P0403', 'P404'->'P0404',
--   'P422'->'P0422'). Como G3 nunca escribe un `CREATE OR REPLACE FUNCTION
--   public.rpc_create_purchase_operation` literal, un grep del nombre NO lo
--   encuentra: la deriva sólo aparece comparando hashes. Partir del archivo
--   de 20261002000001 habría reintroducido en silencio los 12 códigos rotos
--   (que revientan en runtime con "unrecognized exception condition") y roto
--   supabase/tests/test_errcode_5char_gate.sql.
--   rpc_atomic_update_purchase_operation sí coincide byte a byte.
--
-- BASELINE DE DATOS en prod al momento de escribir (2026-08-23):
--   suppliers = 0, supplier_accounts = 0, supplier_account_movements = 0,
--   purchases = 445 filas / 38 operaciones, con supplier_id NOT NULL = 0.
--   MAX(version) = 20261007000001.
--
-- HALLAZGO DE SCHEMA: public.suppliers en PROD ya tiene tax_id, email y phone
--   (vienen del schema pre-migraciones; la tabla nunca tuvo un CREATE TABLE
--   versionado — sólo el stub de CI en 20260517000000_ci_compat_stubs.sql,
--   que tiene únicamente id/company_id/name/created_at). El design.md de este
--   change afirmaba lo contrario. Por eso las cinco columnas se agregan con
--   ADD COLUMN IF NOT EXISTS: en prod dos son nuevas (iva_condition,
--   legal_name) y tres son no-op; en CI/local las cinco son nuevas. El mismo
--   archivo converge los dos entornos.
--
-- FIRMAS (D12): las dos RPCs cambian de firma => DROP FUNCTION IF EXISTS con
--   la firma EXACTA vieja + CREATE OR REPLACE con la nueva. Sin el DROP,
--   `CREATE OR REPLACE` con una lista de argumentos distinta crea un OVERLOAD
--   nuevo y toda llamada posicional falla con 42725 ("function is not
--   unique"). Tras el DROP+CREATE los ACLs se pierden => REVOKE ALL FROM
--   PUBLIC + REVOKE EXECUTE FROM anon (explícito: el proyecto tiene ALTER
--   DEFAULT PRIVILEGES que otorga EXECUTE a anon en toda función nueva) +
--   GRANT EXECUTE TO authenticated, en este mismo archivo. Lo verifica
--   supabase/tests/test_function_acl_gate.sql en cada PR.
--
-- CI: esta migración se agrega como ÚLTIMO eslabón de la cadena de reapply del
--   paso "Verify G1/G4 migrations are idempotent on reapply" de
--   .github/workflows/KPI_Validation.yml — el reapply de 20261002000001 (y de
--   20261003000001, que redefine el cuerpo vía G3) recrea las firmas viejas
--   como overloads fantasma; el DROP FUNCTION IF EXISTS de este archivo los
--   limpia y deja exactamente 1 definición de cada función.
--
-- IDEMPOTENCIA: ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF EXISTS antes de
--   ADD CONSTRAINT, CREATE INDEX IF NOT EXISTS, DROP FUNCTION IF EXISTS +
--   CREATE OR REPLACE, DROP NOT NULL guardado con chequeo de is_nullable
--   (mismo patrón que 20260702000002/20260804000006: en el segundo apply
--   encuentra la columna ya nullable y no-opea, sin error). Reaplicar el
--   archivo dos veces seguidas es no-op — verificado en local para las
--   piezas originales (docker exec ... psql -f, doble aplicación sin error
--   y sin cambio de fingerprint) ANTES de este fix; el DROP NOT NULL de
--   company_id se agregó después con el stack local caído — su idempotencia
--   se sostiene por construcción (ALTER ... DROP NOT NULL es intrínsecamente
--   idempotente en Postgres, y el guard de is_nullable lo hace además
--   silencioso en el reapply) y por el gate 2.5, no por reapply verificado.
--
-- GOVERNANCE: MEDIUM — toca dinero sobre helpers ya en producción y sobre la
--   RPC de alta de compra (hot path, 104 compras en 30 días).
-- APPLY: npx supabase db push  (NUNCA el MCP apply_migration)
-- ROLLBACK: aditivo en datos (columnas nullable, sin backfill). Revertir el
--   comportamiento = reaplicar los cuerpos previos de las dos RPCs; NO se
--   dropean columnas ni se tocan supplier_account_movements. Un cargo ya
--   posteado se revierte por su camino normal (borrar la operación ->
--   _pay_reverse_party_charge), nunca con DELETE.
-- =============================================================================


-- =============================================================================
-- STEP 1 - public.suppliers gana identidad fiscal (D2, RN-96)
-- =============================================================================
-- Espejo EXACTO de clients (20260614000000_clients_fiscal_identity.sql): mismos
-- nombres de columna, mismos tipos, mismo vocabulario cerrado de condición IVA.
-- RN-96 define FiscalIdentity como Value Object compartido entre Customer y
-- Supplier ("misma validación, cero duplicación") y DEC-18 lo confirma;
-- divergir en los nombres hoy encarecería extraer el VO a tabla común mañana.
--
-- Todas nullable y sin DEFAULT: aditivo puro, sin rewrite de tabla, sin
-- backfill. El frontend reutiliza frontend/lib/cuit-utils.ts para el dígito
-- verificador, sin duplicar la validación.

ALTER TABLE public.suppliers
  ADD COLUMN IF NOT EXISTS tax_id        TEXT,
  ADD COLUMN IF NOT EXISTS legal_name    TEXT,
  ADD COLUMN IF NOT EXISTS iva_condition TEXT,
  ADD COLUMN IF NOT EXISTS email         TEXT,
  ADD COLUMN IF NOT EXISTS phone         TEXT;

-- suppliers.company_id: legacy de v20-tenancy-cleanup. clients.company_id ya
-- es nullable (20260613000003_v20_companies_to_accounts.sql); suppliers se
-- quedó atrás con el NOT NULL + FK a companies(id) porque, hasta este change,
-- nada insertaba un supplier desde el backend — el gap nunca se ejercitó.
-- Mismo precedente drift-tolerant que 20260702000002 (events.company_id) y
-- 20260804000006 (audit_logs.company_id): guardado con un chequeo de
-- is_nullable para no tocar la columna si ya está nullable (p. ej. reapply).
-- El FK a companies(id) NO se toca — solo se relaja la nulabilidad. Sin
-- backfill: las filas legacy con company_id NOT NULL siguen intactas.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'suppliers'
      AND column_name = 'company_id' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.suppliers ALTER COLUMN company_id DROP NOT NULL;
    RAISE NOTICE 'suppliers.company_id: DROP NOT NULL aplicado';
  ELSE
    RAISE NOTICE 'suppliers.company_id: ya nullable o inexistente — no-op';
  END IF;
END $$;

-- CHECK de dominio cerrado, mismos 4 valores que clients_iva_condition_check.
-- DROP IF EXISTS + ADD NOT VALID (D12): idempotente y sin escanear la tabla.
-- NOT VALID sólo exime a las filas PREEXISTENTES; todo INSERT/UPDATE nuevo se
-- valida igual — que es lo que importa (hoy hay 0 proveedores en prod).
DO $$
BEGIN
  ALTER TABLE public.suppliers DROP CONSTRAINT IF EXISTS suppliers_iva_condition_check;
  ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_iva_condition_check
    CHECK (iva_condition IN ('responsable_inscripto', 'monotributista', 'exento', 'consumidor_final'))
    NOT VALID;
END $$;

-- Índice de listado: /proveedores lista por cuenta, ordenado por nombre, sólo
-- filas vivas (suppliers está en SOFT_DELETE_TABLES desde v3-soft-delete-policy).
CREATE INDEX IF NOT EXISTS idx_suppliers_account_alive
  ON public.suppliers (account_id, name)
  WHERE deleted_at IS NULL;

COMMENT ON COLUMN public.suppliers.tax_id IS
  'CUIT (NN-NNNNNNNN-N) o DNI del proveedor - opcional, validado en frontend. RN-96: FiscalIdentity es un Value Object COMPARTIDO con clients (mismos nombres/tipos/dominio) - no divergir.';
COMMENT ON COLUMN public.suppliers.legal_name IS
  'Razon social del proveedor - opcional. RN-96: espejo de clients.legal_name.';
COMMENT ON COLUMN public.suppliers.iva_condition IS
  'Condicion frente al IVA - dominio cerrado por CHECK, opcional. RN-96: mismos 4 valores que clients.iva_condition. Habilita que la factura de compra futura (percepciones, v25-tax-perceptions) lea la condicion del proveedor.';
COMMENT ON COLUMN public.suppliers.email IS
  'Email de contacto del proveedor - opcional. RN-96: espejo de clients.email.';
COMMENT ON COLUMN public.suppliers.phone IS
  'Telefono de contacto del proveedor - opcional. RN-96: espejo de clients.phone.';

-- Gate (task 2.1/2.3): post-condición de STEP 1. Corre en ROJO contra el
-- schema previo (en CI/local faltan las cinco columnas; en prod faltaban
-- iva_condition y legal_name).
DO $$
DECLARE
  v_missing text;
BEGIN
  SELECT string_agg(c.col, ', ' ORDER BY c.col) INTO v_missing
  FROM (VALUES ('tax_id'), ('legal_name'), ('iva_condition'), ('email'), ('phone')) AS c(col)
  WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'suppliers' AND column_name = c.col
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'GATE compras-proveedor (2.1) FAILED: a public.suppliers le faltan las columnas: %', v_missing;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'suppliers_iva_condition_check'
      AND conrelid = 'public.suppliers'::regclass
  ) THEN
    RAISE EXCEPTION 'GATE compras-proveedor (2.3a) FAILED: falta el CHECK suppliers_iva_condition_check.';
  END IF;

  -- El CHECK cubre los cuatro valores de clients. El rechazo efectivo de un
  -- valor fuera de dominio se ejercita con un INSERT real en
  -- supabase/tests/test_compras_proveedor_cuenta_corriente.sql (gate 1c) - aca
  -- solo se verifica la DEFINICION, sin escribir filas en la migracion.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'suppliers_iva_condition_check'
      AND conrelid = 'public.suppliers'::regclass
      AND pg_get_constraintdef(oid) LIKE '%responsable_inscripto%'
      AND pg_get_constraintdef(oid) LIKE '%monotributista%'
      AND pg_get_constraintdef(oid) LIKE '%exento%'
      AND pg_get_constraintdef(oid) LIKE '%consumidor_final%'
  ) THEN
    RAISE EXCEPTION 'GATE compras-proveedor (2.3b) FAILED: el CHECK de iva_condition no cubre los cuatro valores de clients.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'suppliers' AND indexname = 'idx_suppliers_account_alive'
  ) THEN
    RAISE EXCEPTION 'GATE compras-proveedor (2.4) FAILED: falta el indice idx_suppliers_account_alive.';
  END IF;

  -- Gate (fix post-apply, phase B backend): suppliers.company_id debe quedar
  -- nullable. Sin este DROP NOT NULL, SupplierRepository.create() (que ya NO
  -- provee company_id — mirror de ClientRepository.create()) revienta con
  -- 23502 en el primer INSERT real de proveedor.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'suppliers'
      AND column_name = 'company_id' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'GATE compras-proveedor (2.5) FAILED: suppliers.company_id sigue NOT NULL.';
  END IF;

  RAISE NOTICE 'compras-proveedor STEP 1 OK: identidad fiscal + CHECK + indice + company_id nullable.';
END $$;


-- =============================================================================
-- STEP 2 - rpc_create_purchase_operation: 8 -> 9 args (+ p_supplier_id)
-- =============================================================================
-- Cuerpo partido del baseline VIVO. Bloques PRESERVADOS (verificados por el
-- generador antes de emitir este archivo, y por el gate de STEP 4):
--   * resolución del flag 'sale_items_rpc_v2' (deudas-menores-agosto G1)
--   * snapshots v3 (name/sku/unit_cost/iva_rate) en purchases y stock_movements
--   * INSERT condicionado en purchase_items
--   * branch_stock via c21_apply_branch_stock_delta (C-21)
--   * stock_movements
--   * _pay_register_operation_bank_movement (pos-banco-movimientos D5)
--   * evento PurchaseCreated con COALESCE(v_kind,'credit') INTACTO
--   * replay idempotente sin evento duplicado (DEC-20)
--   * los 12 ERRCODE de 5 chars que dejó el G3 de 20261003000001
--
-- DELTAS: firma (+p_supplier_id trailing), guard de pertenencia P0404, guard
--   credit_requires_supplier P0400, supplier_id en LAS DOS ramas del INSERT, y
--   el bloque de cargo via _pay_register_party_charge.

DROP FUNCTION IF EXISTS public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid);

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
$function$;

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid) IS
  'Alta atomica de una operacion de compra. compras-proveedor-cuenta-corriente: p_supplier_id (9o parametro, trailing, opcional) se persiste en las DOS ramas del INSERT a purchases; cuando el kind derivado de p_payment_method_id es ''credit'' postea el cargo en la cuenta corriente del proveedor via _pay_register_party_charge (helper compartido, cero logica nueva). Guards: P0404 si el proveedor no pertenece a la cuenta o esta borrado; P0400 credit_requires_supplier si se compra a credito sin proveedor. El disparo usa v_kind CRUDO, nunca el COALESCE(...,''credit'') del evento contable: una compra SIN forma de pago imputada no carga cuenta corriente.';


-- =============================================================================
-- STEP 3 - rpc_atomic_update_purchase_operation: 8 -> 12 args
-- =============================================================================
-- (+ p_supplier_id/p_supplier_provided y p_cost_center_id/p_cost_center_provided)
--
-- Cuerpo partido del baseline VIVO (que aquí SÍ coincide byte a byte con
-- 20261002000001). Bloques PRESERVADOS:
--   * guards P0403 (cuenta activa) y P0404 (ids no encontrados)
--   * los DOS EXISTS de P0423 - cargo de cuenta corriente y movimiento
--     bancario. El primero deja de ser inalcanzable con este change: es el
--     guard que vuelve inmutable a la compra a credito con cargo posteado.
--   * flag 'sale_items_rpc_v2'
--   * acarreo de snapshots keyed por product_id (COALESCE purchase_items/header)
--   * ciclo REVERSE -> DELETE -> APPLY de stock con su espejo en stock_movements
--   * tri-estado ya existente de payment_method_id y branch_id
--
-- DELTAS: firma, dos variables "efectivas" en el DECLARE, resolución tri-estado
--   de supplier_id (D7) y de cost_center_id (OQ-5 opción A), y el uso de esos
--   efectivos en las dos ramas del INSERT.
--
-- DELTAS DE REVIEW A (intencionales, sobre el baseline vivo):
--   * SQL-1/BE-2/SEC-1 — guard de transición a crédito: dos variables más en
--     el DECLARE (v_old_kind/v_final_kind) y dos RAISE P0400
--     (credit_requires_supplier / credit_transition_not_allowed) ubicados
--     junto al resto de los guards de parámetros, ANTES del REVERSE.
--   * SPEC-05 — el mensaje del P0423 de cuenta corriente deja de ofrecer "una
--     nota de crédito" (camino del lado VENTA, inexistente en compras) y pasa
--     a nombrar el camino real: borrar + volver a cargar.
--   * SQL-3 — comentarios del DECLARE de v_old_supplier_id/v_old_cost_center_id
--     (decían "preservado, no expuesto (OQ-1)", heredado del baseline: desde
--     este change AMBOS son parámetros del tri-estado).
--
-- DELTAS DE REVIEW C (intencionales, sobre el cuerpo de review A):
--   * S1 — la regla (a) credit_requires_supplier se condiciona a que la
--     edición TOQUE el contrato de crédito (p_payment_method_provided OR
--     p_supplier_provided). Tal como estaba, una compra legacy imputada a un
--     kind='credit' SIN proveedor —el estado de las 38 operaciones vivas en
--     prod, que hasta este change no tenía proveedores a los que imputar—
--     quedaba INEDITABLE: cambiarle una cantidad rebotaba con P0400. Contradecía
--     la spec operation-edit-context y el comentario del propio guard (b).
--     Cubierto por los gates 8c-bis (pasa) y 8d-bis (rechaza al tocar la forma
--     de pago). La regla (b) no cambia.
--   * S3 — el anti-regresión de STEP 4 sobre el copy del P0423 deja de ser un
--     `position('nota de crédito') > 0` (que matchea COMENTARIOS y depende del
--     acento) y pasa a ser un check POSITIVO sobre el RAISE nuevo más uno
--     NEGATIVO sobre el texto exacto del RAISE viejo del lado venta.
--
-- La edición NO postea ni revierte cargos: una compra con cargo ya es inmutable
-- por P0423, así que el unico caso editable es el de una compra sin cargo — y
-- por eso mismo la edición no puede CONVERTIR una compra en compra a crédito.

DROP FUNCTION IF EXISTS public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean);

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
  v_old_payment_method_id   uuid;  -- metodos-pago-operaciones (D5)
  v_final_payment_method_id uuid;  -- metodos-pago-operaciones (D5)
  -- edicion-preserva-contexto (F1):
  v_old_branch_id      uuid;       -- §D1/§D3
  -- valor vigente capturado antes del DELETE — base del tri-estado
  -- (compras-proveedor-cuenta-corriente D7/OQ-5)
  v_old_supplier_id    uuid;
  -- valor vigente capturado antes del DELETE — base del tri-estado
  -- (compras-proveedor-cuenta-corriente D7/OQ-5)
  v_old_cost_center_id uuid;
  v_final_branch_id    uuid;       -- §D3/§D8: sucursal EFECTIVA
  v_branch             RECORD;
  -- compras-proveedor-cuenta-corriente (D7 + OQ-5): proveedor y centro de
  -- costo EFECTIVOS — cierran la OQ-1 que edicion-preserva-contexto dejó
  -- abierta ("preservados pero no parámetro, porque el form no los expone").
  v_final_supplier_id    uuid;
  v_final_cost_center_id uuid;
  -- compras-proveedor-cuenta-corriente (review A, SQL-1/BE-2/SEC-1): kind
  -- EFECTIVO de la forma de pago — el vigente antes de la edición y el que
  -- queda después. Base del guard de transición a crédito.
  v_old_kind             text;
  v_final_kind           text;
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

  -- pagos-cableados-restantes (D6, task 9.3): espejo del guard de venta —
  -- inmutabilidad de operaciones con cargo de cuenta corriente posteado.
  -- Purchases no tiene el concepto de "purchase_orders" análogo a
  -- sales_orders: reference_id del cargo (cuando exista, vía el helper
  -- compartido _pay_register_party_charge con party_kind='supplier') apunta
  -- directo a purchases.operation_id, sin la complejidad de doble referencia
  -- de la venta. Sin guard de caja: las compras no tienen opt-in de caja en
  -- este change (OQ-E recortado — ver design.md Non-Goals).
  IF EXISTS (
    SELECT 1
    FROM public.supplier_account_movements sam
    WHERE sam.reference_id IN (
      SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
    )
  ) THEN
    -- compras-proveedor-cuenta-corriente (review A, SPEC-05): el texto venía
    -- copiado del lado VENTA y ofrecía un camino de corrección que en compras
    -- NO existe (el listado de compras ya lo dice en la UI). El camino real es
    -- borrar + recargar: rpc_delete_purchase_operation compensa el cargo, el
    -- banco y el stock de forma atómica.
    -- (El gate de STEP 4 verifica que la copia de venta no vuelva a colarse.)
    RAISE EXCEPTION 'operation_has_account_charge_immutable: compra con cargo en cuenta corriente del proveedor posteado — borrá esta compra (revierte el cargo y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.2): tercer EXISTS — bank_movements
  -- entra al mismo bloqueo P0423 que el cargo de cuenta corriente. Egreso de
  -- compra: reference siempre purchases.operation_id (sin la doble
  -- convención de la venta).
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

  -- edicion-operaciones-lineas (D3): mismo flag_key y mismo patrón que venta.
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  -- edicion-operaciones-lineas (D2/D5): acarreo de snapshot keyed por
  -- product_id. Para compra el snapshot puede vivir en purchase_items, en el
  -- header purchases, o en ambos — se acarrea desde purchase_items cuando
  -- hay fila y, si no, cae al header (COALESCE(pi.*, p.*)).
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

  -- metodos-pago-operaciones (D5): capturar el payment_method_id vigente de
  -- la operación ANTES del DELETE — mismo momento que v_old_snapshots.
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

  -- edicion-preserva-contexto (F1, design §D1/§D2): capturar el contexto
  -- vigente del header ANTES del DELETE (el DELETE de más abajo borra las
  -- filas viejas: sin esta captura previa no habría de dónde preservar).
  --
  -- compras-proveedor-cuenta-corriente (D7 + OQ-5): los tres son ahora
  -- editables por contrato TRI-ESTADO — se cierra la OQ-1 de
  -- edicion-preserva-contexto, que los dejó "preservados sin exponerse"
  -- porque el form de compra no tenía selector. Ahora lo tiene para
  -- proveedor, y el CostCenterSelect ya estaba montado en el form de edición
  -- sin ningún efecto (UI que mentía en producción).
  SELECT branch_id, supplier_id, cost_center_id
  INTO   v_old_branch_id, v_old_supplier_id, v_old_cost_center_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
  LIMIT  1;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para branch_id —
  -- espejo del de venta. Validación antes del REVERSE (gate 2.9).
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

  -- compras-proveedor-cuenta-corriente (D7): tri-estado para supplier_id —
  -- mismo contrato que payment_method_id y branch_id. El router lo resuelve
  -- con `"supplier_id" in payload.model_fields_set`, NUNCA con
  -- `payload.supplier_id is None`:
  --   provided=false            -> preservar el vigente (v_old_supplier_id)
  --   provided=true, valor uuid -> reimputar
  --   provided=true, valor NULL -> desimputar
  --
  -- Validación ANTES del REVERSE (mismo gate que branch_id): un proveedor
  -- ajeno o borrado rechaza sin reversa ni reaplicación de stock.
  --
  -- La edición NO postea ni revierte cargos de cuenta corriente: una compra
  -- con cargo posteado ya es inmutable (P0423, guard de más arriba), así que
  -- el único caso editable es el de una compra SIN cargo — y ahí reimputar el
  -- proveedor es sólo cambiar una FK. Invariante asertada por test, no
  -- asumida.
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

  -- compras-proveedor-cuenta-corriente (OQ-5 opción A): mismo tri-estado para
  -- cost_center_id. Cierra la OQ-1 de edicion-preserva-contexto COMPLETA — el
  -- CostCenterSelect ya está montado en el form de edición de compra y hasta
  -- hoy no tenía parámetro en la RPC: el usuario cambiaba el centro de costo,
  -- guardaba, y no pasaba nada.
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

  -- compras-proveedor-cuenta-corriente (review A — SQL-1/BE-2/SEC-1): guard de
  -- transición a crédito en la EDICIÓN.
  --
  -- D7 es explícito: la edición NO postea ni revierte cargos de cuenta
  -- corriente. Sin este guard, el camino de edición podía mover una compra a
  -- una forma de pago de kind='credit' —con o sin proveedor— y dejarla
  -- registrada como "a crédito" SIN cargo posteado: exactamente el defecto que
  -- la spec `supplier-account` declara ("Una compra imputada a kind='credit'
  -- que quede registrada sin su cargo correspondiente SHALL considerarse un
  -- defecto, no una configuración válida"). Y como el guard P0423 de más
  -- arriba mira supplier_account_movements, la compra resultante quedaba
  -- además indefinidamente editable — deuda invisible y mutable.
  --
  -- Se resuelven los DOS kinds efectivos: el que queda tras la edición
  -- (v_final_payment_method_id, ya validado por el tri-estado de arriba) y el
  -- que la operación tenía antes (v_old_payment_method_id). SELECT INTO sobre
  -- un id NULL deja la variable en NULL — "sin forma de pago imputada".
  SELECT kind INTO v_final_kind
  FROM   public.payment_methods
  WHERE  id = v_final_payment_method_id;

  SELECT kind INTO v_old_kind
  FROM   public.payment_methods
  WHERE  id = v_old_payment_method_id;

  -- (a) Simetría con el alta (D6): no hay deuda sin acreedor, tampoco por
  --     edición. MISMO mensaje y MISMO ERRCODE que el camino de creación —
  --     el mapeo backend/frontend es uno solo. Cubre el caso "compra a crédito
  --     legacy a la que se le desimputa el proveedor".
  --
  --     review C (S1): la regla sólo alcanza a la edición que TOCA el contrato
  --     de crédito — es decir, la que informa la forma de pago o el proveedor.
  --     Sin ese condicionante, una compra legacy que YA estaba imputada a un
  --     kind='credit' y NO tiene proveedor (el estado de las 38 operaciones
  --     vivas en prod, donde hasta este change había 0 proveedores) quedaba
  --     INEDITABLE: cambiarle una cantidad rebotaba con P0400 sin que el
  --     usuario hubiera tocado ni la forma de pago ni el proveedor. Eso
  --     contradice tanto la spec operation-edit-context ("una compra que YA
  --     estaba imputada a kind='credit' y no tiene cargo SHALL seguir siendo
  --     editable") como el comentario de (b) acá abajo. Con el condicionante:
  --       - desimputar el proveedor (p_supplier_provided)            -> rechaza
  --       - reimputar la forma de pago, aunque siga en credit
  --         (p_payment_method_provided)                              -> rechaza
  --       - editar cantidades/fecha/descripción sin tocar ninguno    -> pasa
  IF (p_payment_method_provided OR p_supplier_provided)
     AND v_final_kind = 'credit'
     AND v_final_supplier_id IS NULL
  THEN
    RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
      USING ERRCODE = 'P0400';
  END IF;

  -- (b) Transición HACIA crédito: sólo se rechaza cuando la edición informa
  --     explícitamente la forma de pago (p_payment_method_provided) y el kind
  --     pasa de "no crédito" (incluido NULL, sin forma de pago) a 'credit'.
  --     El camino de corrección es borrar + recargar, que sí postea el cargo.
  --
  --     Las compras a crédito YA existentes sin cargo posteado (las históricas
  --     de antes de este change) siguen siendo editables: v_old_kind ya es
  --     'credit', así que este IF no se dispara y sólo aplica (a). Sin ese
  --     matiz, el change habría vuelto inmutables en silencio a las 38
  --     operaciones de compra vivas en prod.
  --
  --     No se acuña un ERRCODE nuevo: P0400 (ya mapeado a 400) con el prefijo
  --     de mensaje distinguiendo el caso, mismo criterio que D6.
  IF p_payment_method_provided
     AND v_final_kind = 'credit'
     AND v_old_kind IS DISTINCT FROM 'credit'
  THEN
    RAISE EXCEPTION 'credit_transition_not_allowed: la edición no postea cargos en cuenta corriente — borrá esta compra y volvé a cargarla como compra a crédito'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — espejo de
  -- la venta, signos invertidos. REVERSE sigue sobre la sucursal VIEJA de
  -- cada fila (§D8 — no cambia con F1).
  FOR v_old_purchase IN
    SELECT id, product_id, quantity, branch_id, operation_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_purchase.product_id;

      SELECT unit_cost_snapshot INTO v_reverse_unit_cost
      FROM   public.stock_movements
      WHERE  reference_id = v_old_purchase.id AND reference_type = 'purchase'
      ORDER  BY created_at DESC
      LIMIT  1;

      -- C-21 checkpoint #2: revertir de la branch original de la compra (o default).
      -- stock-movements-edicion (D2/D3): pata REVERSE — type='purchase_return',
      -- reference_id=id VIEJO, reference_type='purchase_update', delta
      -- NEGATIVO (revierte la entrada de stock que aplicó la compra original).
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_purchase.product_id, v_old_product_name,
        v_old_purchase.branch_id, -v_old_purchase.quantity, 'purchase_return',
        v_old_purchase.id, 'purchase_update', v_old_purchase.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  -- edicion-preserva-contexto (F3, design §D7): quantity integer→numeric,
  -- unit_id sumado al recordset (misma forma que rpc_create_purchase_operation).
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock).
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

      -- edicion-operaciones-lineas (D2/D4/D5): misma decisión de snapshot que
      -- la venta, aplicada AL HEADER siempre (D5 — el write path real).
      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id = v_final_branch_id (F1 §D3),
      -- unit_id = v_item.unit_id (F1 §D7).
      -- compras-proveedor-cuenta-corriente (D7/OQ-5): supplier_id y
      -- cost_center_id pasan de acarreados a EFECTIVOS (tri-estado).
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

      -- edicion-operaciones-lineas (D3): purchase_items condicionado por el
      -- mismo flag que la venta y que la creación de compra.
      -- edicion-preserva-contexto: unit_id = v_item.unit_id en vez de NULL.
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

      -- C-21 checkpoint #2: single-write branch_stock.
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='purchase',
      -- reference_id=id NUEVO, reference_type='purchase' (indistinguible de
      -- la creación). unit_cost_snapshot reusa v_line_snap.
      -- edicion-preserva-contexto (F1 §D8): sucursal EFECTIVA en vez de NULL.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, v_item.quantity, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/unit_id igual.
      -- compras-proveedor-cuenta-corriente (D7/OQ-5): supplier_id y
      -- cost_center_id EFECTIVOS también en la rama sin producto.
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

REVOKE ALL     ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated;

COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) IS
  'Edicion atomica de una operacion de compra (REVERSE -> DELETE -> APPLY). compras-proveedor-cuenta-corriente: supplier_id (D7) y cost_center_id (OQ-5) pasan a contrato TRI-ESTADO, igual que payment_method_id y branch_id - no informado preserva, informado con uuid reimputa, informado con NULL desimputa. El router resuelve el "provided" con model_fields_set, NUNCA con `is None`. Cierra la OQ-1 de edicion-preserva-contexto: el CostCenterSelect ya estaba montado en el form de edicion sin ningun efecto. La edicion no postea ni revierte cargos de cuenta corriente (una compra con cargo es inmutable por P0423) y por eso rechaza con P0400 tanto dejar la compra en kind=credit sin proveedor (credit_requires_supplier, mismo mensaje que el alta) como MOVERLA a kind=credit desde otro kind (credit_transition_not_allowed) - el camino de correccion es borrar y volver a cargar. Las compras que YA eran a credito sin cargo posteado siguen siendo editables.';


-- =============================================================================
-- STEP 4 - Gates finales
-- =============================================================================
DO $$
DECLARE
  v_n        integer;
  v_def      text;
  v_missing  text[] := '{}';
  r          RECORD;
BEGIN
  -- (a) ANTI-OVERLOAD 42725: exactamente UNA firma por funcion (tasks 3.12/4.8).
  FOR r IN
    SELECT unnest(ARRAY['rpc_create_purchase_operation',
                        'rpc_atomic_update_purchase_operation']) AS fname
  LOOP
    SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = r.fname;

    IF v_n <> 1 THEN
      RAISE EXCEPTION 'GATE compras-proveedor (anti-overload) FAILED: public.% tiene % definiciones (esperado 1). Overload fantasma 42725 - revisar el DROP FUNCTION IF EXISTS con la firma exacta vieja.', r.fname, v_n;
    END IF;
  END LOOP;

  -- (b) Los deltas de este change estan realmente en el cuerpo VIVO.
  v_def := pg_get_functiondef('public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid)'::regprocedure);
  IF position('_pay_register_party_charge' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/_pay_register_party_charge');
  END IF;
  IF position('credit_requires_supplier' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/credit_requires_supplier');
  END IF;
  IF position('supplier_not_found' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/supplier_not_found');
  END IF;

  -- (c) ANTI-REGRESION de bloques preservados: si una reescritura futura los
  --     pierde (lo que le paso al bloque `credit` de C-30, PR #421), este gate
  --     lo grita en vez de dejarlo pasar en silencio.
  IF position('c21_apply_branch_stock_delta' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/branch_stock');
  END IF;
  IF position('_pay_register_operation_bank_movement' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/banco');
  END IF;
  IF position('PurchaseCreated' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/evento');
  END IF;
  IF position('sale_items_rpc_v2' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/flag');
  END IF;
  IF position('purchase_items' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/purchase_items');
  END IF;
  -- El COALESCE del EVENTO debe seguir vivo, y el cargo NO debe usarlo (D5).
  IF position(E'COALESCE(v_kind, ''credit'')' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'create/COALESCE-del-evento');
  END IF;

  v_def := pg_get_functiondef('public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure);
  IF position('p_supplier_provided' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/tri-estado-supplier');
  END IF;
  IF position('p_cost_center_provided' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/tri-estado-cost-center');
  END IF;
  IF position('operation_has_account_charge_immutable' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/P0423-cta-cte');
  END IF;
  IF position('operation_has_bank_movement_immutable' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/P0423-banco');
  END IF;
  IF position('v_old_snapshots' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/acarreo-snapshots');
  END IF;
  -- review A (SQL-1/BE-2/SEC-1): el guard de transición a crédito de la
  -- edición. Sin él, la edición podía dejar una compra en kind='credit' sin
  -- cargo posteado — el defecto que la spec supplier-account declara.
  IF position('credit_requires_supplier' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/credit_requires_supplier');
  END IF;
  IF position('credit_transition_not_allowed' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/credit_transition_not_allowed');
  END IF;
  -- review A (SPEC-05): el P0423 de cuenta corriente nombra el camino de
  -- corrección de COMPRAS (borrar + recargar), no la nota de crédito de venta.
  --
  -- review C (S3): el check era `position('nota de crédito' in v_def) > 0`, y
  -- pg_get_functiondef devuelve el cuerpo CON sus comentarios: cualquier
  -- comentario legítimo que mencionara la nota de crédito de venta —incluido
  -- el que explica por qué acá NO va— tumbaba el gate. Además dependía del
  -- acento ('credito' sin tilde lo esquivaba). Se reemplaza por un check
  -- POSITIVO sobre el texto del RAISE nuevo (específico de compras) más uno
  -- NEGATIVO sobre el texto EXACTO del RAISE viejo del lado venta, que ningún
  -- comentario reproduce.
  IF position('operation_has_account_charge_immutable: compra con cargo en cuenta corriente del proveedor' in v_def) = 0 THEN
    v_missing := array_append(v_missing, 'update/P0423-copy-de-compras');
  END IF;
  IF position('emití una nota de crédito' in v_def) > 0 THEN
    v_missing := array_append(v_missing, 'update/P0423-copy-de-venta');
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'GATE compras-proveedor (integridad de cuerpo) FAILED: faltan bloques en las RPCs vivas: %', v_missing;
  END IF;

  -- (d) ACLs restituidas tras el DROP+CREATE (gotcha ALTER DEFAULT PRIVILEGES).
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    IF has_function_privilege('anon', 'public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid)'::regprocedure, 'EXECUTE')
    OR has_function_privilege('anon', 'public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE compras-proveedor (ACL) FAILED: anon conserva EXECUTE sobre una de las RPCs recreadas.';
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    IF NOT has_function_privilege('authenticated', 'public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid)'::regprocedure, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE compras-proveedor (ACL) FAILED: authenticated perdio EXECUTE sobre una de las RPCs recreadas.';
    END IF;
  END IF;

  RAISE NOTICE 'compras-proveedor STEP 4 OK: 1 firma por funcion, deltas presentes, bloques preservados, ACLs correctas.';
END $$;
