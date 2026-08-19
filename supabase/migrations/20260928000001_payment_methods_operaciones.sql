-- =============================================================================
-- MIGRATION: 20260928000001_payment_methods_operaciones.sql
-- CHANGE:    metodos-pago-operaciones
-- Design ref: openspec/changes/metodos-pago-operaciones/design.md
--
-- QUÉ AGREGA
--   1. Catálogo maestro `payment_methods` por cuenta — espejo estructural
--      exacto de `cost_centers` (tenancy account-direct, RLS, unique
--      case-insensitive) + `sort_order` + soft delete (`deleted_at`/
--      `deleted_by`, D1/D11).
--   2. Vocabulario cerrado `kind ∈ {cash,transfer,card,check,wallet,credit,
--      other}` — superset de las dos taxonomías ya vivas (D2).
--   3. Seed de 6 formas de pago: backfill idempotente de las cuentas
--      existentes + sub-bloque degrade-don't-fail en `handle_new_user`
--      (patrón v3-provisioning-seed, D11).
--   4. Columna nullable `payment_method_id` en `sales` y `purchases`, por
--      operación (D3).
--   5. Las 4 RPCs de operaciones (`rpc_create_sale_operation` +
--      `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation`,
--      `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_
--      operation`) ganan `p_payment_method_id` — cuerpo preservado BYTE A
--      BYTE desde la base vigente (20260924000001 / 20260927000001, D4).
--   6. `rpc_payment_method_report(p_account_id, p_start, p_end)` — espejo de
--      `rpc_cost_center_report`, invariantes RN-D (D9).
--
-- QUÉ NO TOCA (Non-Goals, firmado por el PO 2026-08-19)
--   El POS (`rpc_quick_sale`, `rpc_confirm_sales_order`), el CHECK de
--   `sales_orders.payment_method`, las RPCs de cobro/pago y su ruteo
--   bancario/contable, el payload del evento `PurchaseCreated`
--   (`payment_method: 'credit'` queda literal — cablear eso es OQ-1/OQ-2,
--   change siguiente). Cero cargo automático en cuenta corriente, cero
--   `cash_movement`, cero asiento — D8/D10, ver Requirement "La forma de
--   pago es una etiqueta..." en la spec.
--
-- DECISIÓN D4 — DROP + CREATE, no CREATE OR REPLACE
--   Cambiar la aridad con CREATE OR REPLACE crea un overload y deja la
--   llamada anterior ambigua (42725). Por eso: DROP FUNCTION IF EXISTS con
--   la firma EXACTA (leída de pg_get_function_identity_arguments en prod,
--   2026-08-19) + CREATE + REVOKE/GRANT re-emitidos en este mismo archivo
--   (los GRANTs no sobreviven al DROP).
--
-- DECISIÓN D5 — edición: NULL ausente ≠ NULL explícito
--   Las 2 RPCs de update ganan DOS parámetros trailing:
--     p_payment_method_id uuid DEFAULT NULL           -- valor deseado
--     p_payment_method_provided boolean DEFAULT false -- ¿el caller lo mandó?
--   provided=false  → se preserva el payment_method_id vigente de la operación
--                      (capturado ANTES del DELETE, mismo patrón que
--                      v_old_snapshots de edicion-operaciones-lineas).
--   provided=true + id NULL  → desimputar explícito ("Sin especificar").
--   provided=true + id uuid  → reimputar a esa forma de pago (validada).
--   Sin esto, cualquier edición desde un cliente que no mande el campo
--   perdería la imputación en silencio — el mismo hueco que dejó la edición
--   sin líneas (OQ-1 de deudas-menores-agosto).
--
-- BASE EXACTA (pg_get_functiondef, prod gxdhpxvdjjkmxhdkkwyb, 2026-08-19)
--   rpc_create_sale_operation             — MAX(version) = 20260927000001
--   rpc_create_sale_operation_v2          — idem
--   rpc_create_purchase_operation         — idem (20260924000001 la definió)
--   rpc_atomic_update_sale_operation      — idem (20260927000001 la definió)
--   rpc_atomic_update_purchase_operation  — idem
--   handle_new_user                       — base exacta 20260812000001,
--                                            confirmada vigente byte a byte.
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE
--   La integración GitHub de Supabase auto-aplica esta migración al mergear,
--   ANTES del `db push` de Actions. Re-ejecutable de punta a punta: CREATE
--   TABLE IF NOT EXISTS, ADD COLUMN IF NOT EXISTS, DROP+CREATE de funciones,
--   backfill por WHERE NOT EXISTS(kind). Los gates de comportamiento
--   degradan con NOTICE si el contexto no los permite (auth.uid() no
--   resuelve, típico de prod con RLS real).
--
-- BACKFILL DE LAS 120 VENTAS DEL POS — NO VIVE ACÁ (firma del PO 2026-08-19)
--   Va en scripts/sql/backfill_payment_method_pos_sales.sql, firmado, para
--   ejecutar UNA vez post-merge vía MCP con conteos antes/después. No es una
--   migración: toca datos, no schema, y su ejecución es explícita y
--   auditada, no automática al mergear.
--
-- CABLEADOS PROFUNDOS GATEADOS (OQ-1/OQ-2/OQ-3/OQ-4, firma PO 2026-08-19)
--   Unificar el POS al catálogo, cargo automático en cuenta corriente, caja
--   obligatoria y ampliar el CHECK de sales_orders a wallet/check quedan
--   FUERA de este change — recomendados como change siguiente
--   (`pos-catalogo-pagos`). Ver design.md Open Questions.
--
-- APPLY: vía CI al mergear a main (Actions: build + deploy + db push).
--        NUNCA con el MCP `apply_migration` (desincroniza el historial).
-- ROLLBACK:
--   UPDATE payment_methods SET is_active = false  -- selector vacío, sin tocar datos
--   Duro: restaurar las 4 RPCs desde 20260924000001/20260927000001 y
--   handle_new_user desde 20260812000001 (las contienen íntegras). La tabla
--   y las columnas se dejan (aditivas e inocuas; borrarlas perdería
--   imputación real).
-- =============================================================================


-- =============================================================================
-- 1. Tabla payment_methods (espejo de cost_centers + sort_order + soft delete)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.payment_methods (
    id          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    name        text          NOT NULL,
    kind        text          NOT NULL,
    is_active   boolean       NOT NULL DEFAULT true,
    sort_order  integer       NOT NULL DEFAULT 0,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    deleted_at  timestamptz   NULL,
    deleted_by  uuid          NULL,
    CONSTRAINT payment_methods_kind_check CHECK (
        kind IN ('cash', 'transfer', 'card', 'check', 'wallet', 'credit', 'other')
    )
);

COMMENT ON TABLE  public.payment_methods            IS 'metodos-pago-operaciones: catálogo plano de formas de pago por cuenta. Espejo estructural de cost_centers + sort_order + soft delete.';
COMMENT ON COLUMN public.payment_methods.account_id IS 'Cuenta propietaria (RLS por account_id, tenancy account-direct).';
COMMENT ON COLUMN public.payment_methods.name       IS 'Etiqueta editable por el usuario (única case-insensitive por cuenta entre filas vivas).';
COMMENT ON COLUMN public.payment_methods.kind        IS 'Vocabulario cerrado que razona el sistema (D2). Superset de sales_orders.payment_method y de la taxonomía de cobro/pago — este change no modifica ninguna de las dos.';
COMMENT ON COLUMN public.payment_methods.is_active  IS 'Baja lógica REVERSIBLE: FALSE oculta del selector de altas nuevas pero conserva imputaciones históricas.';
COMMENT ON COLUMN public.payment_methods.sort_order IS 'Orden del selector de uso diario (D1). Los 6 sembrados nacen 1..6; el usuario puede reordenar.';
COMMENT ON COLUMN public.payment_methods.deleted_at IS 'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado, sale de toda lectura por defecto. Convive con is_active.';
COMMENT ON COLUMN public.payment_methods.deleted_by IS 'Autoría del borrado (RN-B2). Referencia lógica a auth.users (sin FK dura).';


-- ─── Índices ────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS payment_methods_account_id_idx
    ON public.payment_methods (account_id);

-- Unique case-insensitive sobre filas VIVAS únicamente (permite reusar un
-- nombre si la fila anterior está soft-deleted — task 1.3 TRIANGULATE).
CREATE UNIQUE INDEX IF NOT EXISTS payment_methods_account_name_lower_idx
    ON public.payment_methods (account_id, lower(name))
    WHERE deleted_at IS NULL;


-- ─── RLS (espejo exacto de cost_centers, D1) ─────────────────────────────────

ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "payment_methods_member_select" ON public.payment_methods;
CREATE POLICY "payment_methods_member_select" ON public.payment_methods
    FOR SELECT
    TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

DROP POLICY IF EXISTS "payment_methods_writer_insert" ON public.payment_methods;
CREATE POLICY "payment_methods_writer_insert" ON public.payment_methods
    FOR INSERT
    TO authenticated
    WITH CHECK (is_account_writer(account_id));

DROP POLICY IF EXISTS "payment_methods_writer_update" ON public.payment_methods;
CREATE POLICY "payment_methods_writer_update" ON public.payment_methods
    FOR UPDATE
    TO authenticated
    USING     (is_account_writer(account_id))
    WITH CHECK (is_account_writer(account_id));


-- =============================================================================
-- 2. Columna payment_method_id en sales y purchases (D3)
-- =============================================================================

ALTER TABLE public.sales
    ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL
        REFERENCES public.payment_methods(id) ON DELETE SET NULL;

ALTER TABLE public.purchases
    ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL
        REFERENCES public.payment_methods(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS sales_payment_method_id_idx
    ON public.sales (payment_method_id) WHERE payment_method_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS purchases_payment_method_id_idx
    ON public.purchases (payment_method_id) WHERE payment_method_id IS NOT NULL;

COMMENT ON COLUMN public.sales.payment_method_id IS
    'metodos-pago-operaciones: forma de pago opcional, por OPERACIÓN (todas las líneas del mismo operation_id comparten el valor). NULL = "Sin especificar". NO dispara caja, cuenta corriente ni asiento (D8) — es una etiqueta.';
COMMENT ON COLUMN public.purchases.payment_method_id IS
    'metodos-pago-operaciones: forma de pago opcional, por OPERACIÓN (todas las líneas del mismo operation_id comparten el valor). NULL = "Sin especificar". NO dispara caja, cuenta corriente ni asiento (D8) — es una etiqueta.';


-- =============================================================================
-- 3. Seed del catálogo — Parte A: backfill idempotente de cuentas existentes
--    (D11). WHERE NOT EXISTS por kind (no por name — el name es editable por
--    el usuario y no debe re-sembrarse si lo renombró).
-- =============================================================================

INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
SELECT a.id, v.name, v.kind, v.sort_order
FROM   public.accounts a
CROSS JOIN (VALUES
    ('Efectivo',               'cash',     1),
    ('Transferencia bancaria', 'transfer', 2),
    ('Tarjeta',                'card',     3),
    ('Billetera virtual',      'wallet',   4),
    ('Cuenta corriente',       'credit',   5),
    ('Otro',                   'other',    6)
) AS v(name, kind, sort_order)
WHERE NOT EXISTS (
    SELECT 1 FROM public.payment_methods pm
    WHERE pm.account_id = a.id
      AND pm.kind       = v.kind
      AND pm.deleted_at IS NULL
);


-- =============================================================================
-- 4. Seed del catálogo — Parte B: handle_new_user (D11)
--    Base EXACTA 20260812000001 (confirmada vigente en prod, 2026-08-19).
--    Único agregado: el sub-bloque "payment-method" al final, antes de
--    RETURN new. Degrade-don't-fail: un fallo del seed jamás aborta el
--    signup — mismo patrón que el sub-bloque de branch/cashbox de
--    v3-provisioning-seed, que queda intacto arriba.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  user_name          text;
  user_last_name     text;
  user_phone         text;
  user_locality      text;
  user_province      text;
  user_terms_version text;
  user_email_optin   boolean;
  v_terms_accepted_at timestamptz;
  v_account_id       uuid;
  v_branch_id        uuid;
BEGIN
  user_name          := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), '');
  user_last_name     := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'last_name', '')), '');
  user_phone         := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), '');
  user_locality      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), '');
  user_province      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'province', '')), '');
  user_terms_version := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'terms_version', '')), '');
  user_email_optin   := COALESCE((new.raw_user_meta_data->>'email_notifications_opt_in')::boolean, false);
  v_terms_accepted_at := CASE WHEN user_terms_version IS NOT NULL THEN now() ELSE NULL END;

  -- 1) Perfil (sin cambios respecto a 20260801000003)
  INSERT INTO public.profiles (
    id, name, last_name, phone, locality, province, role,
    terms_accepted_at, terms_version, email_notifications_opt_in
  )
  VALUES (
    new.id, user_name, user_last_name, user_phone, user_locality, user_province, 'user',
    v_terms_accepted_at, user_terms_version, user_email_optin
  );

  -- 2) Tenant: cuenta propia + membresía como OWNER (sin cambios).
  INSERT INTO public.accounts (
    owner_user_id, billing_plan, billing_status,
    trial_plan, trial_started_at, trial_expires_at
  )
  SELECT new.id, p.billing_plan, p.billing_status,
         p.trial_plan, p.trial_started_at, p.trial_expires_at
  FROM   public.profiles p
  WHERE  p.id = new.id
  RETURNING id INTO v_account_id;

  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_id, new.id, 'owner')
  ON CONFLICT (account_id, user_id) DO NOTHING;

  -- 3) Mail de bienvenida (sin cambios)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', COALESCE(user_name, 'Emprendedor'))
  );

  -- 4) Aviso al administrador (sin cambios)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'new_user_admin_notice',
    'danielsevilla@alia-data.com',
    'Nuevo registro en ALIADATA',
    jsonb_build_object(
      'name',      COALESCE(user_name, 'Sin nombre'),
      'last_name', COALESCE(user_last_name, '-'),
      'full_name', NULLIF(TRIM(COALESCE(user_name, '') || ' ' || COALESCE(user_last_name, '')), ''),
      'email',     new.email,
      'phone',     COALESCE(user_phone, '-'),
      'locality',  COALESCE(user_locality, '-'),
      'province',  COALESCE(user_province, '-')
    )
  );

  -- 5) v3-provisioning-seed: sucursal default + caja default (EAGER).
  --    Aislado en su propio sub-bloque: un fallo acá degrada a WARNING y
  --    JAMÁS aborta el signup. El core de arriba (profile/account/membership/
  --    emails) queda fuera de este bloque a propósito — si eso falla, el
  --    signup DEBE fallar (comportamiento preexistente, correcto).
  BEGIN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (v_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    v_branch_id := public.c26_default_branch(v_account_id);

    IF v_branch_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.cashboxes cb WHERE cb.branch_id = v_branch_id
    ) THEN
      INSERT INTO public.cashboxes (branch_id, name, currency)
      VALUES (v_branch_id, 'Caja Principal', 'ARS');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'v3-provisioning-seed: no se pudo sembrar branch/cashbox default para account_id=% (signup continúa; el lazy-create de c21_apply_branch_stock_delta sigue como red de seguridad). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  -- 6) metodos-pago-operaciones (D11 Parte B): catálogo de 6 formas de pago.
  --    Mismo criterio degrade-don't-fail que el sub-bloque de arriba —
  --    aislado, propia EXCEPTION, jamás aborta el signup.
  BEGIN
    INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
    SELECT v_account_id, v.name, v.kind, v.sort_order
    FROM (VALUES
        ('Efectivo',               'cash',     1),
        ('Transferencia bancaria', 'transfer', 2),
        ('Tarjeta',                'card',     3),
        ('Billetera virtual',      'wallet',   4),
        ('Cuenta corriente',       'credit',   5),
        ('Otro',                   'other',    6)
    ) AS v(name, kind, sort_order)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.payment_methods pm
      WHERE pm.account_id = v_account_id
        AND pm.kind       = v.kind
        AND pm.deleted_at IS NULL
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'metodos-pago-operaciones: no se pudo sembrar el catálogo de formas de pago para account_id=% (signup continúa). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  RETURN new;
END;
$function$;


-- =============================================================================
-- 5. rpc_create_sale_operation (dispatcher) + rpc_create_sale_operation_v2
--    Base EXACTA vigente (pg_get_functiondef, prod, 2026-08-19). Cuerpo
--    preservado byte a byte; únicos agregados marcados "metodos-pago-
--    operaciones": el parámetro trailing, su validación de pertenencia
--    (mismo lugar que la validación de p_canal/branch_id) y su persistencia
--    en las 2 rutas de INSERT (línea de producto y línea de servicio) de
--    CADA función. p_payment_method_id se propaga al _v2 igual que ya se
--    propaga p_canal (D4).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(
    p_idempotency_key text,
    p_client_id uuid,
    p_date date,
    p_currency text,
    p_items jsonb,
    p_branch_id uuid DEFAULT NULL::uuid,
    p_canal text DEFAULT NULL::text,
    p_payment_method_id uuid DEFAULT NULL::uuid  -- metodos-pago-operaciones: opcional, valida pertenencia a cuenta
)
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
    RETURN public.rpc_create_sale_operation_v2(
      p_idempotency_key, p_client_id, p_date, p_currency, p_items,
      p_branch_id, p_canal, p_payment_method_id
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
      v_unit_factor  numeric(20,10);
      v_qty_norm     numeric(15,4);
      v_branch_qty   numeric(15,4);
      v_inserted     integer;
      v_canal        text;
    BEGIN
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
          USING ERRCODE = 'P0403';
      END IF;

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

      -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id)
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
                'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
                USING ERRCODE = 'P0422';
            END IF;
          END IF;

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

          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, v_item.product_id,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             p_branch_id, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;

          v_qty_before := v_branch_qty;
          v_qty_after  := v_branch_qty - v_qty_norm;

          PERFORM public.c21_apply_branch_stock_delta(
            v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

          -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id, branch_id, unit_cost_snapshot
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
            -v_qty_norm, v_qty_before, v_qty_after,
            v_new_sale_id, 'sale', v_uid,
            v_new_op_id, p_branch_id, v_product.cost
          );

        ELSE
          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, NULL,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             p_branch_id, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;
        END IF;

        v_result_items := v_result_items
          || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
      END LOOP;

      RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
      );
    END;
  END IF;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid) TO authenticated;


DROP FUNCTION IF EXISTS public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation_v2(
    p_idempotency_key text,
    p_client_id uuid,
    p_date date,
    p_currency text,
    p_items jsonb,
    p_branch_id uuid DEFAULT NULL::uuid,
    p_canal text DEFAULT NULL::text,
    p_payment_method_id uuid DEFAULT NULL::uuid  -- metodos-pago-operaciones: opcional, valida pertenencia a cuenta
)
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
  v_unit_factor  numeric(20,10);
  v_qty_norm     numeric(15,4);
  v_branch_qty   numeric(15,4);
  v_inserted     integer;
  v_canal        text;
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

  -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id)
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
      -- v3-snapshot-pattern: se agrega sku, cost a la lectura ya existente
      -- (name, is_variant) para congelar name/sku/cost sin un SELECT extra.
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
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

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

      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal, p_payment_method_id)
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
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, p_branch_id, v_product.cost
      );

    ELSE
      -- v3-snapshot-pattern (2.6): línea de servicio — name_snapshot no
      -- disponible en el payload legacy de esta RPC (solo amount/quantity/
      -- unit_id); queda NULL como hoy. La línea de servicio con
      -- name_snapshot desde payload se resuelve en _c29_confirm_order_core
      -- (sales_order_items ya trae el nombre desde el frontend — ver 2.4/2.6).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid) TO authenticated;


-- =============================================================================
-- 6. rpc_create_purchase_operation
--    Base EXACTA vigente (pg_get_functiondef, prod, 2026-08-19: la
--    20260924000001 la definió por última vez). Cuerpo preservado byte a
--    byte; únicos agregados marcados "metodos-pago-operaciones". No hay
--    dispatch a _v2 — el flag sale_items_rpc_v2 ya está inline (kill-switch
--    del INSERT en purchase_items), a diferencia de venta.
--    El payload del evento PurchaseCreated ('payment_method', 'credit')
--    queda LITERAL a propósito — cablearlo con el valor real es OQ-2,
--    change siguiente (Non-Goals, firma PO 2026-08-19).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid);

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
    p_idempotency_key text,
    p_date date,
    p_description text,
    p_items jsonb,
    p_branch_id uuid DEFAULT NULL::uuid,
    p_cost_center_id uuid DEFAULT NULL::uuid,
    p_payment_method_id uuid DEFAULT NULL::uuid  -- metodos-pago-operaciones: opcional, valida pertenencia a cuenta
)
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
  purchase_items que este RPC nunca tuvo en prod. Ver cabecera de este
  archivo de migración para el hallazgo completo.

  metodos-pago-operaciones: agrega p_payment_method_id opcional, validado
  contra el catálogo de la cuenta y persistido en todas las filas de la
  operación (mirror de p_cost_center_id).
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
            USING ERRCODE = 'P403';
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
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
    END IF;

    IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P400';
    END IF;

    -- Verify branch_id belongs to this account (if provided)
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.branches
            WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P404';
        END IF;
    END IF;

    -- cost-center-dimension: Verify cost_center_id belongs to this account (mirror of branch_id)
    IF p_cost_center_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.cost_centers
            WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'cost_center_not_found or not active for this account'
                USING ERRCODE = 'P404';
        END IF;
    END IF;

    -- metodos-pago-operaciones: Verify payment_method_id belongs to this account (mirror of cost_center_id)
    IF p_payment_method_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.payment_methods
            WHERE id = p_payment_method_id AND account_id = v_account_id
              AND is_active = TRUE AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'payment_method_not_found or not active for this account'
                USING ERRCODE = 'P404';
        END IF;
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
            RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
            RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P400';
        END IF;

        v_unit_factor := 1.0;
        IF v_item.unit_id IS NOT NULL THEN
            SELECT factor INTO v_unit_factor
            FROM   public.units_of_measure
            WHERE  id = v_item.unit_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
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
                RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
            END IF;

            IF v_product.user_id <> v_uid THEN
                RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
            END IF;

            IF NOT v_product.is_variant THEN
                IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
                    RAISE EXCEPTION
                        'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                        USING ERRCODE = 'P422';
                END IF;
            END IF;

            -- v3-snapshot-pattern (D2): congelar name/sku/cost en purchases
            -- (flat) — es donde el write path REAL de compra escribe la línea.
            -- iva_rate_snapshot NULL (D3: products no tiene columna de IVA).
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id,
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
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- ── journal-entry-outbox (Task 4.1): emitir PurchaseCreated en la misma tx ─
    -- metodos-pago-operaciones: 'payment_method' queda LITERAL 'credit' a
    -- propósito (Non-Goals) — cablearlo con p_payment_method_id real es OQ-2.
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
            'payment_method', 'credit',
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

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid) TO authenticated;


-- =============================================================================
-- 7. rpc_atomic_update_sale_operation
--    Base EXACTA vigente (pg_get_functiondef, prod, 2026-08-19: la
--    20260927000001 la definió por última vez). Cuerpo preservado byte a
--    byte; únicos agregados marcados "metodos-pago-operaciones".
--
--    D5 — preservación por COALESCE: DOS parámetros trailing.
--      p_payment_method_id uuid DEFAULT NULL           — valor deseado
--      p_payment_method_provided boolean DEFAULT false — ¿el caller lo mandó?
--    provided=false            → se preserva v_old_payment_method_id
--                                 (capturado ANTES del DELETE, mismo momento
--                                 que v_old_snapshots).
--    provided=true + id NULL   → desimputar explícito ("Sin especificar").
--    provided=true + id uuid   → reimputar (validado contra el catálogo).
--    NO altera el acarreo de snapshot/líneas (#415) ni la reversa/aplicación
--    de stock_movements (#417) — únicamente agrega payment_method_id a las 2
--    rutas de INSERT de STEP 3.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb);

CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(
    p_sale_ids uuid[],
    p_client_id uuid,
    p_date date,
    p_currency text,
    p_items jsonb,
    p_payment_method_id uuid DEFAULT NULL::uuid,        -- metodos-pago-operaciones (D5)
    p_payment_method_provided boolean DEFAULT false      -- metodos-pago-operaciones (D5)
)
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

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — id vieja
  -- es el reference_id de la pata REVERSE, operation_id agrupa el movimiento
  -- bajo la operación a la que pertenecía la fila que se está reemplazando.
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

      -- design §D5: la pata REVERSE copia el unit_cost_snapshot del
      -- movimiento ORIGINAL (el que dejó la creación o la edición anterior)
      -- si existe; si la operación todavía no tiene movimiento de referencia
      -- (una de las 204 delete-inseguras, hasta el backfill gateado del
      -- grupo 5), queda NULL — no se inventa costo histórico.
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

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

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
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_payment_method_id)
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
        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, NULL, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default).
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='sale',
      -- reference_id=id NUEVO, reference_type='sale' (indistinguible de la
      -- creación — el contrato del que depende la reversa al eliminar).
      -- unit_cost_snapshot reusa v_line_snap, la misma decisión de acarreo
      -- que la línea (sin re-valuar al costo actual).
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        NULL, -v_item.quantity, 'sale', v_new_sale_id, 'sale',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean) TO authenticated;


-- =============================================================================
-- 8. rpc_atomic_update_purchase_operation
--    Base EXACTA vigente (pg_get_functiondef, prod, 2026-08-19: la
--    20260927000001 la definió por última vez). Cuerpo preservado byte a
--    byte; únicos agregados marcados "metodos-pago-operaciones". Mismo
--    patrón D5 (COALESCE de preservación) que la venta — ver cabecera §7.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb);

CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(
    p_purchase_ids uuid[],
    p_date date,
    p_description text,
    p_items jsonb,
    p_payment_method_id uuid DEFAULT NULL::uuid,        -- metodos-pago-operaciones (D5)
    p_payment_method_provided boolean DEFAULT false      -- metodos-pago-operaciones (D5)
)
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

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — espejo de
  -- la venta, signos invertidos.
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

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
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
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, payment_method_id,
         name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id, v_final_payment_method_id,
         v_line_snap->>'name_snapshot',
         v_line_snap->>'sku_snapshot',
         (v_line_snap->>'unit_cost_snapshot')::numeric,
         (v_line_snap->>'iva_rate_snapshot')::numeric)
      RETURNING id INTO v_new_purchase_id;

      -- edicion-operaciones-lineas (D3): purchase_items condicionado por el
      -- mismo flag que la venta y que la creación de compra.
      IF v_flag_on THEN
        INSERT INTO public.purchase_items (
          purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_purchase_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, NULL, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default).
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='purchase',
      -- reference_id=id NUEVO, reference_type='purchase' (indistinguible de
      -- la creación). unit_cost_snapshot reusa v_line_snap.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        NULL, v_item.quantity, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, payment_method_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id, v_final_payment_method_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean) TO authenticated;


-- =============================================================================
-- 9. Gate anti-overload (42725) — corre SIEMPRE, también en prod.
--    D4: si el DROP no matchea la firma vieja exacta, CREATE OR REPLACE deja
--    DOS funciones con el mismo proname y distinta aridad → la próxima
--    llamada posicional revienta con "function is not unique". Barato,
--    determinístico, no depende de datos.
-- =============================================================================
DO $$
DECLARE
  v_proname text;
  v_count   integer;
BEGIN
  FOREACH v_proname IN ARRAY ARRAY[
    'rpc_create_sale_operation',
    'rpc_create_sale_operation_v2',
    'rpc_create_purchase_operation',
    'rpc_atomic_update_sale_operation',
    'rpc_atomic_update_purchase_operation'
  ] LOOP
    SELECT COUNT(*) INTO v_count
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE ANTI-OVERLOAD FAILED: % tiene % definiciones en public (esperaba exactamente 1) — el DROP FUNCTION IF EXISTS no matcheó la firma vieja y quedó un overload fantasma (42725).',
        v_proname, v_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'GATE ANTI-OVERLOAD PASSED: las 5 funciones de operaciones tienen exactamente 1 definición cada una.';
END $$;


-- =============================================================================
-- 10. rpc_payment_method_report — espejo de rpc_cost_center_report (D9).
--     Lee sales y purchases (documentos operativos), NO journal_lines —
--     mismo motivo que el reporte de centros de costo (async por outbox).
--     Excepción documentada a RN-D1: NO resta notas de crédito — una NC no
--     tiene forma de pago atribuible, repartirla proporcionalmente sería
--     inventar (mismo tipo de excepción ya documentada para el margen por
--     canal). Visible también en la pantalla del reporte (task 6.3).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_payment_method_report(
    p_account_id uuid,
    p_start      date,
    p_end        date
)
RETURNS TABLE(
    payment_method_id   uuid,
    payment_method_name text,
    payment_method_kind text,
    is_active           boolean,
    total_sold          numeric,
    total_purchased     numeric,
    operation_count     bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Verify caller belongs to this account (espejo de rpc_cost_center_report).
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH
    pm_sales AS (
      SELECT
        s.payment_method_id                                       AS pm_id,
        -- RN-D: importe de línea COALESCE(total, amount).
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0)             AS sold_total,
        -- RN-D: conteo de operaciones COUNT(DISTINCT COALESCE(operation_id, id)).
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT    AS sold_ops
      FROM public.sales s
      WHERE s.account_id = p_account_id
        -- RN-D5: borde superior inclusivo hasta fin de día local.
        AND s.date >= p_start::timestamptz
        AND s.date <  (p_end + 1)::timestamptz
      GROUP BY s.payment_method_id
    ),
    pm_purchases AS (
      SELECT
        p.payment_method_id                                       AS pm_id,
        COALESCE(SUM(COALESCE(p.total, p.amount)), 0)             AS purchased_total,
        COUNT(DISTINCT COALESCE(p.operation_id, p.id))::BIGINT    AS purchased_ops
      FROM public.purchases p
      WHERE p.account_id = p_account_id
        AND p.date >= p_start::timestamptz
        AND p.date <  (p_end + 1)::timestamptz
      GROUP BY p.payment_method_id
    ),
    all_pm_ids AS (
      -- UNION (no UNION ALL) dedupe incluyendo la clave NULL: lo no imputado
      -- colapsa en una sola fila "Sin especificar".
      SELECT pm_id FROM pm_sales
      UNION
      SELECT pm_id FROM pm_purchases
    )
  SELECT
    api.pm_id                                                            AS payment_method_id,
    COALESCE(pm.name, 'Sin especificar')                                 AS payment_method_name,
    pm.kind                                                              AS payment_method_kind,
    -- Las formas de pago desactivadas siguen apareciendo con su nombre
    -- histórico; la bandera deja que la UI las distinga sin consulta extra.
    COALESCE(pm.is_active, true)                                         AS is_active,
    COALESCE(ps.sold_total, 0)                                           AS total_sold,
    COALESCE(pp.purchased_total, 0)                                      AS total_purchased,
    (COALESCE(ps.sold_ops, 0) + COALESCE(pp.purchased_ops, 0))::BIGINT   AS operation_count
  FROM all_pm_ids api
  LEFT JOIN public.payment_methods pm ON pm.id     = api.pm_id
  LEFT JOIN pm_sales               ps ON ps.pm_id  IS NOT DISTINCT FROM api.pm_id
  LEFT JOIN pm_purchases           pp ON pp.pm_id  IS NOT DISTINCT FROM api.pm_id
  -- ORDER BY por expresión y no por el nombre de la columna OUT: evita la
  -- ambigüedad columna-vs-variable de plpgsql en RETURN QUERY.
  ORDER BY (COALESCE(ps.sold_total, 0) + COALESCE(pp.purchased_total, 0)) DESC;
END;
$function$;

COMMENT ON FUNCTION public.rpc_payment_method_report(uuid, date, date) IS
    'metodos-pago-operaciones: ventas y compras agregadas por forma de pago '
    'en un rango. Incluye la fila NULL "Sin especificar" para lo no imputado. '
    'Invariantes RN-D: COALESCE(total, amount), COUNT(DISTINCT COALESCE(operation_id, id)), '
    'borde superior < p_end + 1 día, dinero NUMERIC. Excepción documentada a '
    'RN-D1: no resta notas de crédito (no tienen forma de pago atribuible).';


-- =============================================================================
-- 11. ACLs — exigido por el gate supabase/tests/test_function_acl_gate.sql
--     (revocar anon explícitamente; REVOKE FROM PUBLIC no alcanza).
-- =============================================================================
REVOKE ALL     ON FUNCTION public.rpc_payment_method_report(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_payment_method_report(uuid, date, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_payment_method_report(uuid, date, date) TO authenticated;


-- =============================================================================
-- 12. Gate de introspección del reporte (corre SIEMPRE, también en prod).
-- =============================================================================
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'rpc_payment_method_report';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_payment_method_report no existe tras la migración.';
  END IF;

  IF position('COALESCE(s.total, s.amount)' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_payment_method_report no suma ventas con COALESCE(s.total, s.amount) (RN-D).';
  END IF;

  IF position('COALESCE(p.total, p.amount)' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_payment_method_report no suma compras con COALESCE(p.total, p.amount) (RN-D).';
  END IF;

  IF position('(p_end + 1)::timestamptz' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_payment_method_report no usa el borde superior inclusivo < p_end + 1 día (RN-D5).';
  END IF;

  IF position('Sin especificar' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_payment_method_report no etiqueta la fila de no imputados.';
  END IF;

  IF position('journal_lines' in v_def) > 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_payment_method_report referencia journal_lines — debe leer sales/purchases (D9), el asiento es async por outbox.';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: rpc_payment_method_report contiene los predicados RN-D y la fila de no imputados.';
END $$;
