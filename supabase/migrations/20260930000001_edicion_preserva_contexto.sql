-- =============================================================================
-- edicion-preserva-contexto: la edición de una operación preserva su contexto
-- (sucursal, canal, unidad, proveedor, centro de costo) y admite cantidades
-- decimales. Cierra las OQ que el PO firmó el 2026-08-19 sobre
-- edicion-operaciones-lineas: OQ-D (F1), OQ-C (F2, "bloquear"), OQ-G (F3,
-- "decimal").
--
-- Base capturada VIVA de prod (gxdhpxvdjjkmxhdkkwyb, pg_get_functiondef,
-- 2026-08-20) = #415 (edicion-operaciones-lineas) + #417 (stock-movements-
-- edicion) + #419 (metodos-pago-operaciones). El cuerpo se EXTIENDE, no se
-- reescribe de memoria (regla anti-regresión de julio).
--
-- F1 — El contexto del header sobrevive a la edición (design.md §D1-D4, D8-D9):
--   * branch_id/canal (venta) y branch_id (compra) capturados ANTES del
--     DELETE y reescritos en el INSERT nuevo. Se vuelven ADEMÁS editables vía
--     el mismo contrato tri-estado que #419 le dio a payment_method_id:
--     p_branch_id/p_branch_provided, p_canal/p_canal_provided.
--   * unit_id, supplier_id (compra) y cost_center_id (compra) se preservan
--     SIN exponerse. unit_id viaja pegado al ítem del payload (igual que la
--     creación — el recordset gana la columna); supplier_id/cost_center_id
--     no tienen selector en el form de edición hoy, así que se acarrean
--     desde el header viejo tal cual (§D2/§D7).
--   * company_id NO se restaura: eje de tenancy legacy retirado por C-19.
--   * Colateral 1: la pata APPLY de op_stock_movement recibe la sucursal
--     EFECTIVA (v_final_branch_id) en vez de NULL — editar deja de mudar
--     stock a la sucursal default (§D8).
--   * Colateral 2: sales_orders promovida sin comprobante se re-apunta al
--     operation_id nuevo en la misma transacción (§D9) — cierra en su causa
--     raíz la OQ-C de edicion-operaciones-lineas (3 órdenes colgadas hoy).
--   BREAKING de firma en ambas RPCs: DROP FUNCTION + CREATE + re-GRANT
--   (42725) — parámetros nuevos al final, todos con DEFAULT (ventana de
--   despliegue: el backend viejo sigue resolviendo, obtiene "preservar").
--
-- F2 — Una operación de VENTA facturada es inmutable (design.md §D5-D6):
--   Guard nuevo al inicio de rpc_atomic_update_sale_operation, ANTES del
--   REVERSE: si la operación tiene una sales_orders con fiscal_document_id
--   cuyo comprobante está en pending_cae o authorized, la edición falla con
--   ERRCODE = 'P0423'. rejected no bloquea (nunca existió fiscalmente). La
--   compra queda fuera de alcance: no lleva CAE propio (§D6).
--
-- F3 — Cantidad decimal de punta a punta (design.md §D7):
--   jsonb_to_recordset pasa de "quantity integer" a "quantity numeric" en
--   ambas RPCs de edición — único eslabón entero de una cadena que ya es
--   numeric(15,4) de punta a punta. Sin ALTER, sin DROP VIEW.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR) vía
-- supabase/tests/test_edicion_preserva_contexto.sql.
-- =============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 0. Reparación de un gap de historial de migraciones — descubierto durante
--    este change vía el ciclo RED de la task 1.1/1.3 (no algo que el design
--    haya anticipado: design.md §D7 da por sentado, VERIFICADO en prod, que
--    "sales.quantity, purchases.quantity, sale_items.quantity, purchase_
--    items.quantity" ya son numeric(15,4) — cierto en prod, pero el stack
--    local/CI reconstruido desde cero (`supabase start` reejecutando TODOS
--    los archivos de este directorio) deja sales.quantity/purchases.quantity
--    en `integer`, tal como los declaró la migración original — ningún
--    archivo de este repo registra el ALTER que las llevó a numeric(15,4) en
--    prod. Evidencia adicional: 20260616000004_v20_compat_views.sql /
--    20260616000009_fix_compat_views_service_lines.sql ya escriben
--    `COALESCE(si.quantity, s.quantity)` esperando que ambos lados sean
--    compatibles — hoy en local Postgres inserta un cast implícito
--    `s.quantity::numeric` en el árbol de la vista para poder unificarlos,
--    visible con pg_get_viewdef pero ausente del texto fuente.
--
--    Sin este ALTER, F3 (quantity decimal de punta a punta) es verificable
--    en prod pero NO en el stack local/CI: la propia edición insertaría
--    3.25 y Postgres lo redondearía a 3 en silencio, solo en CI — un falso
--    verde para prod escondería un falso rojo de CI, o peor, un gate que
--    nunca podría estar en verde pese a que el comportamiento en prod es
--    correcto. Confirmado con un DO block ad-hoc contra el stack local
--    (2026-08-20): crear con quantity=2.5 ya persistía redondeado a 3
--    ANTES de tocar ninguna RPC de este change — el bug es de paridad de
--    esquema, no de este código.
--
--    Reparación GATEADA por el tipo actual de la columna: en prod (donde ya
--    es numeric) esta sección es un no-op completo — ni DROP VIEW ni ALTER
--    se ejecutan. En local/CI (donde es integer) reconstruye las dos vistas
--    dependientes con su definición EXACTA y vigente (capturada de
--    20260616000009_fix_compat_views_service_lines.sql, incluyendo
--    `WITH (security_invoker = true)` — CRÍTICO, sin eso la vista bypasea
--    RLS) — cero cambio de comportamiento, solo paridad de esquema.
-- ═══════════════════════════════════════════════════════════════════════════
DO $repair_sales_quantity$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.sales'::regclass AND attname = 'quantity' AND atttypid = 'integer'::regtype
  ) THEN
    DROP VIEW IF EXISTS public.v_sales_flat;

    ALTER TABLE public.sales ALTER COLUMN quantity TYPE numeric(15,4) USING quantity::numeric(15,4);
    ALTER TABLE public.sales ALTER COLUMN quantity SET DEFAULT 1;

    CREATE OR REPLACE VIEW public.v_sales_flat
    WITH (security_invoker = true)
    AS
    SELECT
      s.id,
      s.user_id,
      s.account_id,
      s.client_id,
      s.operation_id,
      s.date,
      s.currency,
      s.canal,
      s.branch_id,
      COALESCE(si.product_id, s.product_id) AS product_id,
      COALESCE(si.price,      s.amount)     AS amount,
      COALESCE(si.quantity,   s.quantity)   AS quantity,
      COALESCE(si.subtotal,   s.total)      AS total,
      COALESCE(si.unit_id,    s.unit_id)    AS unit_id
    FROM public.sales s
    LEFT JOIN public.sale_items si ON si.sale_id = s.id AND si.product_id IS NOT NULL;

    COMMENT ON VIEW public.v_sales_flat IS
      'Vista de compatibilidad. Columnas planas desde sale_items con COALESCE al header '
      '(líneas de servicio sin fila de ítem — ver 20260616000009). OQ3: CONSERVAR post-DROP (DEC-15). '
      'security_invoker=true garantiza que RLS de la sesión se aplica — no bypasear. '
      'edicion-preserva-contexto: recreada tras reparar sales.quantity a numeric(15,4) en local/CI (§0).';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.purchases'::regclass AND attname = 'quantity' AND atttypid = 'integer'::regtype
  ) THEN
    DROP VIEW IF EXISTS public.v_purchases_flat;

    ALTER TABLE public.purchases ALTER COLUMN quantity TYPE numeric(15,4) USING quantity::numeric(15,4);
    ALTER TABLE public.purchases ALTER COLUMN quantity SET DEFAULT 1;

    CREATE OR REPLACE VIEW public.v_purchases_flat
    WITH (security_invoker = true)
    AS
    SELECT
      p.id,
      p.user_id,
      p.account_id,
      p.operation_id,
      p.date,
      p.description,
      COALESCE(pi2.product_id, p.product_id) AS product_id,
      COALESCE(pi2.price,      p.amount)     AS amount,
      COALESCE(pi2.quantity,   p.quantity)   AS quantity,
      COALESCE(pi2.subtotal,   p.total)      AS total,
      COALESCE(pi2.unit_id,    p.unit_id)    AS unit_id
    FROM public.purchases p
    LEFT JOIN public.purchase_items pi2 ON pi2.purchase_id = p.id AND pi2.product_id IS NOT NULL;

    COMMENT ON VIEW public.v_purchases_flat IS
      'Vista de compatibilidad. Columnas planas desde purchase_items con COALESCE al header '
      '(ver 20260616000009). OQ3: CONSERVAR post-DROP. security_invoker=true. '
      'edicion-preserva-contexto: recreada tras reparar purchases.quantity a numeric(15,4) en local/CI (§0).';
  END IF;
END;
$repair_sales_quantity$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. DROP de ambas RPCs con su firma vieja COMPLETA Y EXPLÍCITA (§D4) — un
--    CREATE OR REPLACE con una lista de argumentos distinta crearía un
--    overload nuevo (42725), no reemplazaría la función vigente.
-- ═══════════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean);
DROP FUNCTION IF EXISTS public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean);

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. rpc_atomic_update_sale_operation — firma nueva, cuerpo F1+F2+F3.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(
  p_sale_ids                uuid[],
  p_client_id                uuid,
  p_date                      date,
  p_currency                  text,
  p_items                    jsonb,
  p_payment_method_id         uuid DEFAULT NULL::uuid,
  p_payment_method_provided boolean DEFAULT false,
  p_branch_id                 uuid DEFAULT NULL::uuid,
  p_branch_provided        boolean DEFAULT false,
  p_canal                     text DEFAULT NULL::text,
  p_canal_provided         boolean DEFAULT false
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
  -- edicion-preserva-contexto (F1):
  v_old_operation_id uuid;         -- §D9: para re-apuntar sales_orders
  v_old_branch_id    uuid;         -- §D1/§D3
  v_old_canal        text;         -- §D1/§D3
  v_final_branch_id  uuid;         -- §D3/§D8: sucursal EFECTIVA (reimputada o vieja)
  v_final_canal      text;         -- §D3
  v_canal_clean      text;
  v_branch           RECORD;
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

  -- edicion-preserva-contexto (F2, design §D5): guard fiscal — SHALL correr
  -- antes de cualquier reversa/eliminación/reaplicación, de modo que una
  -- operación facturada quede intacta si el guard dispara. Resuelto por JOIN
  -- (sales.operation_id → sales_orders.sale_operation_id →
  -- sales_orders.fiscal_document_id → fiscal_documents.status), nunca por
  -- una columna denormalizada de "facturado" (segunda fuente de verdad).
  -- pending_cae bloquea igual que authorized: la emisión es asíncrona
  -- (relay pg_cron) y ya reservó numeración ante ARCA en ese estado.
  -- rejected NO bloquea: ese comprobante nunca llegó a existir fiscalmente.
  IF EXISTS (
    SELECT 1
    FROM   public.sales s
    JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
    JOIN   public.fiscal_documents fd ON fd.id = so.fiscal_document_id
    WHERE  s.id = ANY(p_sale_ids)
      AND  fd.status IN ('pending_cae', 'authorized')
  ) THEN
    RAISE EXCEPTION 'invoiced_operation_immutable: la operación tiene un comprobante fiscal emitido y no puede editarse — emití una nota de crédito y registrá una venta nueva'
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

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. rpc_atomic_update_purchase_operation — firma nueva, cuerpo F1+F3
--    (F2 no aplica a compra — design §D6, la compra no lleva CAE propio).
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(
  p_purchase_ids             uuid[],
  p_date                      date,
  p_description               text,
  p_items                    jsonb,
  p_payment_method_id         uuid DEFAULT NULL::uuid,
  p_payment_method_provided boolean DEFAULT false,
  p_branch_id                 uuid DEFAULT NULL::uuid,
  p_branch_provided        boolean DEFAULT false
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
  -- edicion-preserva-contexto (F1):
  v_old_branch_id      uuid;       -- §D1/§D3
  v_old_supplier_id    uuid;       -- §D2: preservado, no expuesto (OQ-1)
  v_old_cost_center_id uuid;       -- §D2: preservado, no expuesto (OQ-1)
  v_final_branch_id    uuid;       -- §D3/§D8: sucursal EFECTIVA
  v_branch             RECORD;
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

  -- edicion-preserva-contexto (F1, design §D1/§D2): capturar el contexto
  -- vigente del header ANTES del DELETE. branch_id se vuelve editable
  -- (tri-estado, igual que la venta); supplier_id y cost_center_id se
  -- preservan SIN exponerse — el form de edición de compra no tiene
  -- selector para ninguno de los dos hoy (OQ-1: exponerlos es un change
  -- posterior, cuando el form los tenga).
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
      -- supplier_id/cost_center_id = acarreados sin exponer (F1 §D2),
      -- unit_id = v_item.unit_id (F1 §D7).
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id,
         name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_old_supplier_id, v_old_cost_center_id, v_final_payment_method_id,
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
      -- edicion-preserva-contexto: branch_id/supplier_id/cost_center_id/unit_id igual.
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_old_supplier_id, v_old_cost_center_id, v_final_payment_method_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. ACLs — el DROP resetea las ACLs. Este proyecto (bootstrap Supabase)
--    tiene ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON
--    FUNCTIONS TO anon, authenticated, service_role — así que una función
--    NUEVA (DROP+CREATE, o cualquier CREATE que no matchee una firma
--    existente) nace con `anon=X` GRANT DIRECTO, no vía PUBLIC. Por eso
--    `REVOKE ALL ... FROM PUBLIC` solo NO alcanza (bug real, encontrado en
--    CI: la firma nueva quedó anon-executable pese al REVOKE FROM PUBLIC —
--    localmente no se reproducía porque el stack local ya tenía las ACLs
--    de una corrida previa). Patrón completo de 3 líneas, igual que
--    20260928000001 y el resto del proyecto (advisors 0028/0029):
--    REVOKE ALL FROM PUBLIC + REVOKE EXECUTE FROM anon (el que realmente
--    importa) + GRANT EXECUTE TO authenticated. Inmediatamente después del
--    CREATE, mismo archivo (§D4/Risks).
-- ═══════════════════════════════════════════════════════════════════════════
REVOKE ALL     ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) TO authenticated;

REVOKE ALL     ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Comentarios de trazabilidad (task 3.12).
-- ═══════════════════════════════════════════════════════════════════════════
COMMENT ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) IS
  'edicion-preserva-contexto: preserva branch_id/canal/unit_id al editar (F1, tri-estado para branch_id/canal), bloquea la edición de una operación facturada con P0423 (F2), acepta quantity decimal (F3), y re-apunta sales_orders promovida sin comprobante al operation_id nuevo (F1 §D9). Base: #415 (líneas) + #417 (espejo de stock) + #419 (forma de pago).';

COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean) IS
  'edicion-preserva-contexto: preserva branch_id (tri-estado)/supplier_id/cost_center_id/unit_id al editar (F1), acepta quantity decimal (F3). F2 no aplica a compra (sin CAE propio). Base: #415 (líneas) + #417 (espejo de stock) + #419 (forma de pago).';
