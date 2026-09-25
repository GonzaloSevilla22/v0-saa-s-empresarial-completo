-- =============================================================================
-- MIGRATION: 20261062000001_ventas_unidades_conversion.sql
-- CHANGE: ventas-unidades-conversion (2026-09-24) — governance MEDIA con un
--         tramo de severidad ALTA (reescribe seis RPCs SECURITY DEFINER que
--         escriben stock y, desde la segunda revisión, las tres lecturas de
--         reporting que cuentan/costean cantidades; no escribe dinero, caja,
--         cuentas corrientes ni fiscal — pero el contrato de PRECIO por unidad
--         de la línea, D-F, sí es de dinero y queda pendiente del sign-off).
--         Renumerada de 20261061000001 a 20261062000001 el 2026-09-25: la
--         20261061000001 la tomó el PR #585 (venta-editable-vs-promocion-legacy),
--         ya mergeado y vivo en prod.
--
-- PROBLEMA (medido en prod el 2026-09-24): la conversión por unidad de medida
-- vivía en dos de los cuatro caminos que mueven stock (alta de venta y alta de
-- compra, ambas con la misma copia inline `quantity * factor`) y faltaba en
-- los otros dos: el POS (_c29_confirm_order_core: v_qty_norm := v_item.quantity)
-- y la edición de venta/compra (revierte y reaplica con la cantidad cruda).
-- Vender 450 g desde el POS descontaba 450 kg. Además "× factor" a secas es
-- relativo a la base del TIPO (kg), no a la del PRODUCTO — coincidía sólo
-- porque ningún producto tiene unidad base derivada. Y branch_stock.min_stock
-- era integer (imposible "avisar cuando queden 0,5 kg").
--
-- QUÉ HACE (design.md D1–D7):
--   1. Helper _uom_normalize_quantity(producto, unidad, cantidad): ÚNICA
--      definición, relativa a la unidad base del producto, mismo type
--      obligatorio (P0400 unit_type_mismatch), sin unidad base sólo unidades
--      base (P0400 unit_requires_base_unit). SECURITY INVOKER, sin EXECUTE
--      para anon/authenticated.
--   2-7. Seis cuerpos reescritos desde su cuerpo VIVO (md5 abajo), con la
--      conversión inline retirada y el helper en su lugar; en las dos
--      ediciones la pata REVERSE devuelve el quantity_delta guardado (D6).
--      El sexto (auditoría post-apply) es la rama legacy del kill-switch
--      sale_items_rpc_v2=false de rpc_create_sale_operation, que conservaba
--      la conversión inline. Una variante hereda la base del padre; la unidad
--      de la línea tiene que ser del sistema o de la cuenta (P0404).
--   8. branch_stock.min_stock → numeric(15,4) (vista v_products_with_stock
--      recreada, get_dashboard_critical_stock_items y
--      rpc_set_product_min_stock con DROP + CREATE).
--  10. (segunda revisión) Reporting en unidad BASE: reporting_sales_lines_in_window,
--      rpc_dashboard_kpi_summary y rpc_dashboard_channel_margin cuentan y
--      costean la cantidad normalizada (envoltorio de lectura
--      _uom_quantity_for_reporting); el precio sigue por unidad de la línea (D-F).
--  11. (segunda revisión) trg_product_base_unit_guard: la unidad base no cambia
--      debajo del stock (P0409 base_unit_locked, D-C) y es del sistema o de la
--      cuenta (P0404) — para FastAPI, PostgREST y cualquier escritor; desde la
--      tercera revisión también observa parent_id (re-parentar una variante
--      que hereda le cambia la unidad efectiva).
--  12. (tercera revisión) D-F′: sales_order_items.price y quote_items.price de
--      numeric(15,2) a numeric (como sales.amount / sale_items.price): el
--      precio por unidad de la línea no se redondea y el total es exacto.
--  13. (tercera revisión) check_low_margin (alerta de margen por email)
--      compara el importe de la línea contra el costo de la cantidad en unidad
--      base — décimo cuerpo del preflight.
--  14. Gate embebido de introspección.
--  Tercera revisión, además: en rpc_create_sale_operation_v2,
--  rpc_create_purchase_operation y la rama legacy de rpc_create_sale_operation
--  la cantidad se normaliza DESPUÉS de tomar el producto FOR UPDATE (TOCTOU
--  contra un cambio de unidad base abierto; los otros tres ya lo hacían).
--
-- CUERPOS DE PARTIDA (md5 de prosrc CR-stripped, re-medidos contra prod
-- gxdhpxvdjjkmxhdkkwyb el 2026-09-25 — después del deploy de #585, 308
-- migraciones, max(version)=20261061000001 — y contra el último CREATE OR
-- REPLACE de este directorio — idénticos):
--   _c29_confirm_order_core              7489bd12fca16ec4fbb5e12fc4b1e852  (20261045000001_operacion_party_guard.sql)
--   rpc_create_sale_operation_v2         3f68a783995da7bdf333751a8e347b18  (20261045000001_operacion_party_guard.sql)
--   rpc_create_purchase_operation        f465b93f8eaedeba46bca08a4fc41033  (20261022000001_cobranzas_vencimientos.sql)
--   rpc_atomic_update_sale_operation     7c8c1b765ca669ad736e8fc181d471bb  (20261061000001_venta_editable_vs_promocion_legacy.sql, PR #585)
--   rpc_atomic_update_purchase_operation fd5052c8e3fa146512600aa9987e2beb  (20261018000001_caja_compras_cobranzas.sql)
--   rpc_create_sale_operation            343e0f1f938a918daaba41434c8a494b  (20261022000001_cobranzas_vencimientos.sql)
--   reporting_sales_lines_in_window      4bba3c6c619212bb4bfa59a814a8a040  (20261042000001_products_cost_nullable.sql) — §10, segunda revisión
--   rpc_dashboard_kpi_summary            41c86badb97f3980a786a7b158fa7fd6  (20261042000001_products_cost_nullable.sql) — §10
--   rpc_dashboard_channel_margin         47023d57067c03bd8bdd2cef362c0843  (20261042000001_products_cost_nullable.sql) — §10
--   check_low_margin                     a03b312675753c26372046613391c17b  (20260517000002_fix_function_search_path.sql) — §13, tercera revisión
--
-- rpc_atomic_update_sale_operation parte AHORA del cuerpo de #585 (lock
-- temprano N1 + recálculo N3), no del de 20261060000001 (a657c54b…) que
-- usaba la versión original de este PR: su cuerpo es la fusión en 3 vías
-- base 20261060000001 / ours #585 / theirs unidades (0 conflictos, §5).
--
-- Firmas intactas en las seis (CREATE OR REPLACE); ACLs intactas (el REPLACE
-- conserva proacl). Gates: supabase/tests/test_ventas_unidades_conversion.sql
-- (matriz de los seis caminos + min_stock) cableado en KPI_Validation.yml.
-- =============================================================================

-- ─── 0. Punto de partida verificado ────────────────────────────────────────
-- Cada cuerpo se reescribe desde su pg_get_functiondef VIVO, verificado el
-- 2026-09-25 contra prod (gxdhpxvdjjkmxhdkkwyb, sólo SELECT) y contra el
-- último CREATE OR REPLACE del directorio de migraciones: md5(prosrc)
-- CR-stripped IDÉNTICO en los seis. Si el cuerpo vivo del stack que aplica
-- esta migración difiere (una migración intermedia que nadie reconcilió), se
-- ABORTA en vez de reescribir a ciegas — regla de integridad de función
-- (20261060000001).
DO $$
DECLARE
  v_expected jsonb := jsonb_build_object(
    '_c29_confirm_order_core',              '7489bd12fca16ec4fbb5e12fc4b1e852',
    'rpc_create_sale_operation_v2',         '3f68a783995da7bdf333751a8e347b18',
    'rpc_create_purchase_operation',        'f465b93f8eaedeba46bca08a4fc41033',
    'rpc_atomic_update_sale_operation',     '7c8c1b765ca669ad736e8fc181d471bb',
    'rpc_atomic_update_purchase_operation', 'fd5052c8e3fa146512600aa9987e2beb',
    'rpc_create_sale_operation',            '343e0f1f938a918daaba41434c8a494b',
    -- Segunda revisión (§10, reporting en unidad base): vivos en prod el
    -- 2026-09-25 (SELECT sobre gxdhpxvdjjkmxhdkkwyb) = stack local.
    'reporting_sales_lines_in_window',      '4bba3c6c619212bb4bfa59a814a8a040',
    'rpc_dashboard_kpi_summary',            '41c86badb97f3980a786a7b158fa7fd6',
    'rpc_dashboard_channel_margin',         '47023d57067c03bd8bdd2cef362c0843',
    -- Tercera revisión (§13, alerta de margen en unidad base): vivo en prod el
    -- 2026-09-25 (SELECT sobre gxdhpxvdjjkmxhdkkwyb) = stack local.
    'check_low_margin',                     'a03b312675753c26372046613391c17b'
  );
  -- Cuerpo que ESTA migración deja (reaplicación: KPI_Validation "idempotente
  -- on reapply" / db reset con la migración ya vigente). Auditoría post-apply:
  -- antes se toleraba cualquier cuerpo que contuviera la llamada al helper, lo
  -- que dejaba pasar en silencio una redefinición posterior — ahora sólo el
  -- md5 exacto. Medidos de pg_proc en el stack local después de aplicar ESTE
  -- archivo (db reset, 309 migraciones, 2026-09-25); el de
  -- rpc_atomic_update_sale_operation es el de la fusión con #585. Tercera
  -- revisión: re-medidos los de rpc_create_sale_operation_v2,
  -- rpc_create_purchase_operation y rpc_create_sale_operation (normalización
  -- después del FOR UPDATE) y el nuevo de check_low_margin; el archivo pasó a
  -- LF sin CR literales y los nueve anteriores no cambiaron (se miden
  -- CR-stripped).
  v_rewritten jsonb := jsonb_build_object(
    '_c29_confirm_order_core',              'd69e1ea6daac7c4deec0a1603ae4ceae',
    'rpc_create_sale_operation_v2',         'cd9faffb6aacd735565575ac5c28a1ef',
    'rpc_create_purchase_operation',        '485339208790c80cf96e38e539ec4c03',
    'rpc_atomic_update_sale_operation',     '66c49a34b4e9de40ddbe90a1e33d0f83',
    'rpc_atomic_update_purchase_operation', '23558c073cf71d08ea4a0dfb15079555',
    'rpc_create_sale_operation',            '5685625cd216fc192cf992f120b71b2f',
    'reporting_sales_lines_in_window',      '32500045f7934cb1e86b6051c21b515b',
    'rpc_dashboard_kpi_summary',            'bba246e4a9e507b19a56e1cc01ec8bcd',
    'rpc_dashboard_channel_margin',         '881b3390fb0d2c9fd6dbc34f9aa15120',
    'check_low_margin',                     'b95295a770a181aa61d2ebd5e0df27af'
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
      RAISE NOTICE 'ventas-unidades-conversion: % ya es el cuerpo de esta migración (reaplicación)', v_fn;
    ELSE
      v_bad := v_bad || format('%s: esperado %s (partida) o %s (reaplicación), vivo %s',
        v_fn, v_expected ->> v_fn, v_rewritten ->> v_fn, COALESCE(v_md5, '(no existe)'));
    END IF;
  END LOOP;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'ventas-unidades-conversion: el cuerpo vivo de partida difiere del verificado contra prod el 2026-09-25 — reconciliar antes de reescribir: %',
      array_to_string(v_bad, '; ');
  END IF;
  -- Segunda revisión: el mensaje dice lo que pasó (antes anunciaba "seis
  -- cuerpos de partida verificados" aunque los seis fueran reaplicación).
  RAISE NOTICE 'ventas-unidades-conversion: % cuerpos reescritos desde el cuerpo de partida verificado por md5, % ya reaplicados',
    v_n_partida, v_n_reaplicacion;
END $$;

-- ─── 0b. Reparación de un gap de historial de migraciones ───────────────────
-- 20260509211504_create_units_of_measure.sql es un STUB documental ("applied
-- directly via Supabase MCP"): el DDL vivo de prod (products.base_unit_id con
-- FK a units_of_measure + índice parcial, y las 10 unidades de sistema) NO
-- está en ningún archivo de este directorio. Un stack reconstruido desde cero
-- (supabase start / db reset en CI) no tiene la columna, y el helper de este
-- change la lee. Guardado: no-op en prod (la columna existe desde 2026-05-09),
-- crea la columna en local/CI. Mismo patrón que 20260930000001 §0. Las
-- unidades de sistema NO se siembran acá (dato, no esquema): los gates crean
-- las suyas por cuenta.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_schema = 'public' AND table_name = 'products' AND column_name = 'base_unit_id'
  ) THEN
    ALTER TABLE public.products
      ADD COLUMN base_unit_id uuid REFERENCES public.units_of_measure(id);
    RAISE NOTICE 'ventas-unidades-conversion: products.base_unit_id creada (gap de historial, stub 20260509211504)';
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_products_base_unit
  ON public.products USING btree (base_unit_id) WHERE (base_unit_id IS NOT NULL);

-- ─── 1. Helper _uom_normalize_quantity (D1/D2/D3) ───
CREATE OR REPLACE FUNCTION public._uom_normalize_quantity(
  p_product_id uuid,
  p_unit_id    uuid,
  p_quantity   numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
DECLARE
  v_unit     RECORD;
  v_base     RECORD;
  v_base_id  uuid;
  v_account  uuid;
  v_result   numeric(15,4);
BEGIN
  IF p_quantity IS NULL THEN
    RETURN NULL;
  END IF;

  -- Línea sin unidad: factor 1 (misma semántica que antes en los cinco caminos).
  IF p_unit_id IS NULL THEN
    RETURN p_quantity::numeric(15,4);
  END IF;

  SELECT id, type, factor, base_unit_id, COALESCE(is_system, false) AS is_system, account_id INTO v_unit
  FROM   public.units_of_measure
  WHERE  id = p_unit_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unit of measure not found: %', p_unit_id USING ERRCODE = 'P0404';
  END IF;

  -- Línea de servicio (sin producto): no mueve stock, no hay base contra la
  -- cual convertir — la cantidad queda tal cual.
  IF p_product_id IS NULL THEN
    RETURN p_quantity::numeric(15,4);
  END IF;

  -- Auditoría post-apply: una VARIANTE hereda la unidad base de su padre.
  -- Nada en el sistema asigna base_unit_id a una variante (el formulario no
  -- la manda y el backend sólo hereda category_id), y un padre con variantes
  -- sólo se vende a través de ellas: sin la herencia, 163 variantes de padres
  -- en kg (prod, 2026-09-24) quedaban "sin unidad base". Misma regla que
  -- expone v_products_with_stock.base_unit_id.
  SELECT COALESCE(p.base_unit_id, pp.base_unit_id), p.account_id
  INTO   v_base_id, v_account
  FROM   public.products p
  LEFT JOIN public.products pp ON pp.id = p.parent_id
  WHERE  p.id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Auditoría post-apply (tenencia): la unidad de la línea es del sistema o
  -- de la cuenta del producto. El FK a units_of_measure no está scopeado por
  -- tenant y la conversión inline anterior tampoco lo verificaba. Mismo P0404
  -- que el guard del backend (no revela si existe en otra cuenta).
  IF NOT v_unit.is_system AND v_unit.account_id IS DISTINCT FROM v_account THEN
    RAISE EXCEPTION 'Unit of measure not found: %', p_unit_id USING ERRCODE = 'P0404';
  END IF;

  -- D3: sin unidad base no existe referencia contra la cual convertir; sólo se
  -- admite una unidad base (factor 1, sin base_unit_id) y la cantidad va tal cual.
  IF v_base_id IS NULL THEN
    IF v_unit.factor <> 1 OR v_unit.base_unit_id IS NOT NULL THEN
      RAISE EXCEPTION 'unit_requires_base_unit: la unidad % (factor %) no es una unidad base y el producto % no declara unidad base',
        p_unit_id, v_unit.factor, p_product_id
        USING ERRCODE = 'P0400';
    END IF;
    RETURN p_quantity::numeric(15,4);
  END IF;

  -- Misma unidad que la base del producto: identidad exacta, sin aritmética.
  IF v_base_id = v_unit.id THEN
    RETURN p_quantity::numeric(15,4);
  END IF;

  SELECT id, type, factor INTO v_base
  FROM   public.units_of_measure
  WHERE  id = v_base_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unit of measure not found: %', v_base_id USING ERRCODE = 'P0404';
  END IF;

  -- D1: sólo dentro del mismo tipo (units-of-measure: nunca un resultado silencioso).
  IF v_unit.type IS DISTINCT FROM v_base.type THEN
    RAISE EXCEPTION 'unit_type_mismatch: la unidad % (%) no es del mismo tipo que la unidad base % (%) del producto %',
      p_unit_id, v_unit.type, v_base_id, v_base.type, p_product_id
      USING ERRCODE = 'P0400';
  END IF;

  -- Segunda revisión: también un factor <= 0 de la unidad de la LÍNEA.
  -- units_of_measure no tiene CHECK (factor > 0) y la policy
  -- uom_account_insert deja crear unidades por PostgREST: con factor -1,
  -- VENDER sumaba stock (medido, 40-probe-d6-y-factor.out.txt).
  IF v_base.factor IS NULL OR v_base.factor <= 0 OR v_unit.factor IS NULL OR v_unit.factor <= 0 THEN
    RAISE EXCEPTION 'unit_factor_invalid: factor nulo, cero o negativo en % / %', p_unit_id, v_base_id
      USING ERRCODE = 'P0400';
  END IF;

  -- D1: cantidad × factor(línea) ÷ factor(base del producto), a la precisión
  -- de las columnas de stock. Una cantidad no nula que se anule al redondear
  -- se rechaza: no se registran ventas que no mueven stock.
  v_result := round(p_quantity * v_unit.factor / v_base.factor, 4);
  IF p_quantity <> 0 AND v_result = 0 THEN
    RAISE EXCEPTION 'quantity_below_precision: la cantidad % en la unidad % equivale a 0 en la unidad base del producto %',
      p_quantity, p_unit_id, p_product_id
      USING ERRCODE = 'P0400';
  END IF;
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public._uom_normalize_quantity(uuid, uuid, numeric) IS
  'ventas-unidades-conversion (D1/D2/D3): ÚNICA definición de "cantidad de una línea en la unidad en que se lleva el stock del producto" (unidad base del producto). La consumen los seis cuerpos que escriben stock desde una operación: alta de venta (rpc_create_sale_operation_v2 y la rama legacy del kill-switch en rpc_create_sale_operation), POS (_c29_confirm_order_core), edición de venta (rpc_atomic_update_sale_operation), alta y edición de compra. Una variante hereda la unidad base de su padre. La unidad de la línea tiene que ser del sistema o de la cuenta del producto (P0404). Mismo type obligatorio (P0400 unit_type_mismatch); producto sin unidad base sólo admite unidades base (P0400 unit_requires_base_unit). Helper intra-transacción: sin EXECUTE para anon/authenticated.';

-- GOTCHA prod ≠ local (#432): prod concede EXECUTE directo a anon/authenticated,
-- no vía PUBLIC — el REVOKE nombra la lista completa.
REVOKE ALL ON FUNCTION public._uom_normalize_quantity(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;

-- ─── 2. rpc_create_sale_operation_v2 — conversión inline retirada ───
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
  v_total_sum             numeric(15,2) := 0;
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
      -- ventas-unidades-conversion: sin producto no hay stock que mover, pero
      -- la unidad de la línea se sigue validando (P0404) como antes.
      PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
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

-- ─── 3. rpc_create_purchase_operation — conversión inline retirada ───
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
  p_idempotency_key   text,
  p_date              date,
  p_description       text,
  p_items             jsonb,
  p_branch_id         uuid DEFAULT NULL::uuid,
  p_cost_center_id    uuid DEFAULT NULL::uuid,
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_bank_account_id   uuid DEFAULT NULL::uuid,
  p_supplier_id       uuid DEFAULT NULL::uuid,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_due_date          date DEFAULT NULL::date
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
    v_total_sum       numeric(15,2) := 0;
    v_kind            text;            -- pagos-cableados-restantes (D7)
    -- caja-compras-cobranzas (D2):
    v_cash_movement_id    uuid;
    v_cash_session_status text;
    v_cash_session_branch uuid;
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
            -- Línea sin producto: no mueve stock; la unidad se sigue validando (P0404).
            PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
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

    -- ── caja-compras-cobranzas (D2) — OPT-IN DE CAJA, 3 condiciones ───────────
    -- Copiado LITERAL del molde de rpc_create_expense: mismos tres tokens de
    -- error, mismo orden, y p_date (`date`) comparado DIRECTO contra
    -- reporting_local_today() — PROHIBIDO castear a timestamptz (el ::date
    -- implícito usaría la timezone del servidor/UTC, y una compra cargada
    -- entre las 21:00 y las 23:59 de Mendoza se rechazaría con P0422 justo
    -- cuando el usuario sabe que es hoy).
    --
    -- "Sucursal efectiva de la compra" = p_branch_id tal cual (sin COALESCE a
    -- una default: a diferencia del gasto, la compra no resuelve una
    -- sucursal por defecto — D3 sólo exige que se PERSISTA la elegida). Una
    -- compra sin sucursal (p_branch_id NULL) no puede satisfacer esta
    -- condición para ninguna caja real: es el comportamiento correcto, no un
    -- caso sin cubrir.
    IF p_cash_session_id IS NOT NULL THEN
        IF v_kind IS DISTINCT FROM 'cash' THEN
            RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
                USING ERRCODE = 'P0422';
        END IF;

        SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
        FROM public.cash_sessions cs
        JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
        WHERE cs.id = p_cash_session_id;

        IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM p_branch_id THEN
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
    PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'out', 'purchase', v_new_op_id,
        p_date, p_branch_id, NULL
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

-- ─── 4. _c29_confirm_order_core — el POS deja de descontar la cantidad cruda ───
CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid DEFAULT NULL::uuid, p_comprobante_type text DEFAULT NULL::text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_order            public.sales_orders%ROWTYPE;
  v_gate_branch      uuid;
  v_branch           RECORD;
  v_item             RECORD;
  v_product          RECORD;
  v_branch_qty       numeric(15,4);
  v_qty_norm         numeric(15,4);
  v_existing_op      uuid;
  v_new_op_id        uuid;
  v_new_sale_id      uuid;
  v_fiscal_doc_id    uuid;
  v_fiscal_result    jsonb;
  v_inserted         integer;
  v_canal            text;
  v_total            numeric(15,2) := 0;
  v_qty_before       numeric;
  v_qty_after        numeric;
  -- pos-catalogo-pagos (D2/D3): resolución de kind y cuenta corriente.
  v_kind                 text;
  v_pm_is_active         boolean;
  -- tenancy-guard-caja-outbox (h1, capa 1): mismos nombres que en
  -- rpc_create_sale_operation_v2, de donde se copia el predicado.
  v_cash_session_status  text;
  v_cash_session_branch  uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar idempotency_key
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  -- Cargar la orden
  SELECT * INTO v_order
  FROM public.sales_orders
  WHERE id = p_sales_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_order.account_id;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado de la orden
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'order_not_in_draft: estado %', v_order.status
      USING ERRCODE = 'P0409';
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): mismo guard que
  -- rpc_create_sale_operation_v2 (20261045000001) — cubre POS
  -- (rpc_quick_sale), rpc_confirm_sales_order y rpc_accept_quote una vez
  -- confirmado: v_order.client_id se valida contra el tenant ANTES de
  -- cualquier escritura (idempotencia incluida, más abajo). Si viene de
  -- rpc_quick_sale, el INSERT en sales_orders corre en la MISMA
  -- transacción que esta RPC — el rechazo de acá revierte también esa fila.
  IF v_order.client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = v_order.client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', v_order.client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ─── pos-catalogo-pagos (D2): resolver el kind — el cliente no elige la
  -- taxonomía, la RPC la deriva del catálogo y no le cree al texto que
  -- venga junto. Va con los demás guards de entrada, antes de tocar stock.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind, is_active INTO v_kind, v_pm_is_active
    FROM public.payment_methods
    WHERE id = p_payment_method_id
      AND account_id = v_account_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found: % no pertenece a la cuenta o no existe', p_payment_method_id
        USING ERRCODE = 'P0404';
    END IF;

    IF NOT v_pm_is_active THEN
      RAISE EXCEPTION 'payment_method_inactive: % está desactivada', p_payment_method_id
        USING ERRCODE = 'P0400';
    END IF;

    IF p_payment_method IS NOT NULL AND p_payment_method <> v_kind THEN
      RAISE EXCEPTION 'payment_method_mismatch: el texto % no coincide con el kind % de la forma de pago', p_payment_method, v_kind
        USING ERRCODE = 'P0400';
    END IF;
  ELSE
    -- Camino legacy (D2, limpiezas-pagos-admin): sin payment_method_id, el
    -- kind es el texto recibido (o 'other' si viene NULL). A diferencia del
    -- comportamiento anterior (que dejaba el kind viviendo solo en la
    -- columna de texto sales_orders.payment_method, ahora retirada), se
    -- intenta resolver la forma de pago viva y activa de la cuenta con ese
    -- kind (desempate por sort_order, luego id) para imputar
    -- p_payment_method_id. Si no hay ninguna forma de pago sembrada de ese
    -- kind (p.ej. 'check', ver OQ-1), la orden queda sin imputar — no
    -- aborta, es el mismo criterio "sin especificar" que ya contempla la
    -- capability payment-method.
    v_kind := COALESCE(p_payment_method, 'other');

    SELECT id INTO p_payment_method_id
    FROM public.payment_methods
    WHERE account_id = v_account_id
      AND kind = v_kind
      AND is_active = true
      AND deleted_at IS NULL
    ORDER BY sort_order, id
    LIMIT 1;
  END IF;

  -- D6: validación cash sin session → P0400 (ramifica sobre v_kind, no sobre
  -- el texto crudo — D4).
  IF v_kind = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ╔═══ tenancy-guard-caja-outbox (h1, CAPA 1 — invariante de SUCURSAL) ════╗
  -- El p_cash_session_id llega del payload y hasta acá NADIE lo validaba: sólo
  -- se chequeaba IS NULL (arriba) y se lo pasaba crudo a
  -- c28_register_cash_movement, que no mira account_id. Una sesión de caja de
  -- OTRO TENANT se confirmaba y le dejaba un ingreso fantasma en el arqueo.
  -- El predicado se COPIA de rpc_create_sale_operation_v2 (el formulario, que
  -- ya lo cumplía): sesión abierta Y de la sucursal efectiva de la venta.
  -- Mismo ERRCODE y MISMO mensaje literal: que dos caminos den errores
  -- distintos para la misma condición es deuda, no feature.
  -- PARIDAD PARCIAL, A PROPÓSITO. Sobre el MISMO parámetro el formulario
  -- aplica tres guards, y acá se replica UNO — el de tenencia. Los otros dos
  -- NO se replican: `cash_optin_requires_cash_kind` (rechaza el id de sesión
  -- si el kind no es cash) y `cash_optin_requires_today`. Son higiene de
  -- input, no tenencia: con kind no-cash el id se descarta sin tocar caja
  -- (el consumo vive dentro de `IF v_kind = 'cash'`), y la fecha de la venta
  -- del POS la fija reporting_local_today() en el propio INSERT, así que la
  -- condición se cumple por construcción. Replicarlos agrandaría el BREAKING
  -- de un change CRÍTICO sobre payloads que ninguna superficie del producto
  -- genera, a cambio de cero seguridad. Queda anotado como candidato en
  -- design.md D2. Lo que sí está cubierto y es lo que importa: el guard de
  -- tenencia es AGNÓSTICO DEL KIND — una sesión ajena rebota igual con
  -- `transfer` (assert 2.6 del gate).
  -- Ubicación (D2): junto a las demás validaciones de payload, inmediatamente
  -- después de cash_requires_session y ANTES de la primera escritura (el
  -- INSERT en operation_idempotency, más abajo). Se compara contra
  -- v_order.branch_id porque `v_gate_branch := v_order.branch_id` se asigna
  -- unas líneas más abajo: es el mismo valor, y mover esa asignación habría
  -- introducido una diferencia contra el baseline vivo que no es el guard.
  -- EL GUARD ES AUTOSUFICIENTE — única diferencia deliberada contra el
  -- predicado copiado del formulario, y está acá por una revisión adversarial
  -- (2026-08-24). En el formulario `v_gate_branch` ya viene validada como
  -- perteneciente al tenant antes del bloque; en el core NO: la sucursal de la
  -- orden la elige el atacante en el camino de rpc_quick_sale
  -- (`COALESCE(p_branch_id, c26_default_branch(...))` va al INSERT en
  -- sales_orders sin chequeo de cuenta) y la validación de tenencia de la
  -- sucursal —el `AND account_id = v_account_id` del `branch_not_found`—
  -- ocurre unas líneas MÁS ABAJO. Con sólo `cb.branch_id = v_order.branch_id`,
  -- mandar la sucursal de la víctima junto con su sesión de caja SATISFACE el
  -- guard, y lo único que frena la escritura pasa a ser un chequeo ajeno a
  -- este change que ningún test congela (medido: ese payload rebotaba con
  -- P0404, no con P0422). Por eso el SELECT JOINea `branches` y exige
  -- `b.account_id = v_account_id`: el guard establece por sí solo los DOS
  -- invariantes —caja de la sucursal de la venta Y del tenant que llama— sin
  -- depender de nada de más abajo. Si la sesión no cumple, el SELECT no
  -- devuelve fila, las dos variables quedan NULL y el IS DISTINCT FROM de
  -- abajo dispara el P0422. Candados: asserts (2.7) y (2.8) del gate.
  IF p_cash_session_id IS NOT NULL THEN
    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches   b  ON b.id  = cb.branch_id
    WHERE cs.id = p_cash_session_id
      AND b.account_id = v_account_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_order.branch_id THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- pos-catalogo-pagos (D3): restaurar el guard credit_requires_client del
  -- bloque C-30 (20260720000001), ANTES de tocar stock — junto con los
  -- demás guards de entrada.
  IF v_kind = 'credit' AND v_order.client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id en la orden'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method (D4: vocabulario completo del catálogo, los 7 kind)
  IF v_kind NOT IN ('cash', 'transfer', 'card', 'check', 'wallet', 'credit', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', v_kind
      USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch del gate (ya está en la orden; usamos la branch de la orden)
  v_gate_branch := v_order.branch_id;

  -- Validar que la branch esté activa
  SELECT id, status INTO v_branch
  FROM public.branches
  WHERE id = v_gate_branch AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Canal normalizado
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');

  -- ─── Idempotencia (DEC-06) ───────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver la operación original sin re-ejecutar
    -- (v3-document-status-history: el return temprano garantiza que el replay
    -- NO inserta historial duplicado). La forma de pago del replay se ignora
    -- (pos-catalogo-pagos: mismo criterio, ahora también para payment_method_id).
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'sale'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_existing_op,
      'replayed',        true
    );
  END IF;

  -- ─── Calcular total y descontar stock por línea ──────────────────────────
  FOR v_item IN
    SELECT * FROM public.sales_order_items
    WHERE sales_order_id = p_sales_order_id
    ORDER BY id
  LOOP
    v_total := v_total + v_item.subtotal;

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
      SELECT id, user_id, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      -- ventas-unidades-conversion (D1/D2): el POS descontaba la cantidad
      -- CRUDA de la línea; ahora normaliza por la misma definición única que
      -- el formulario (unidad base del producto). sales_order_items.unit_id
      -- viaja con la línea desde rpc_quick_sale / rpc_confirm_sales_order.
      v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      -- Gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM public.branch_stock
      WHERE product_id = v_item.product_id AND branch_id = v_gate_branch;

      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_item.product_id, v_branch_qty, v_qty_norm
          USING ERRCODE = 'P0409';
      END IF;

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      -- Descontar stock (C-21 helper)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm
      );

      -- Insertar fila legacy sales (retrocompat D4). app-timezone-argentina
      -- (task 5): día argentino, no CURRENT_DATE (UTC del servidor).
      -- pos-catalogo-pagos: cada fila legacy nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product (2.4).
      -- iva_rate_snapshot NULL (D3).
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      -- stock_movements (reference_type='sale') — v3-snapshot-pattern: costo congelado.
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
      -- Línea de servicio sin producto — solo fila legacy (2.6: sin snapshot,
      -- name_snapshot ya vive en sales_order_items.name_snapshot desde su
      -- propia creación en quick_sale/confirm_sales_order — no aplica acá).
      -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
      -- pos-catalogo-pagos: también nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  -- pos-catalogo-pagos (D4): ramifica sobre v_kind, no sobre el texto crudo.
  IF v_kind = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── pagos-cableados-restantes (D2): cuenta corriente del cliente — el
  -- bloque inline restaurado por pos-catalogo-pagos (D3) se REEMPLAZA por
  -- la llamada al helper compartido _pay_register_party_charge (D1), la
  -- misma definición que usa el formulario de venta (rpc_create_sale_
  -- operation_v2). client_id ya validado arriba (credit_requires_client
  -- antes del descuento de stock). El helper posta el cargo C-30 y emite
  -- CustomerAccountCharged en la misma operación atómica — nada de esto
  -- se relaja, sólo deja de estar duplicado.
  IF v_kind = 'credit' THEN
    PERFORM public._pay_register_party_charge(
      v_account_id, 'customer', v_order.client_id, v_total, p_sales_order_id, v_new_op_id
    );
  END IF;

  -- ─── pos-banco-movimientos (D5): movimiento bancario operativo — después
  -- de caja/cuenta corriente, ANTES del bloque fiscal (task 4.1). NULL si no
  -- corresponde escribir (kind no bancario, o bancario sin cuenta resuelta —
  -- D2). value_date = día ART (D4, el POS nunca dispara P0424: opera siempre
  -- sobre hoy).
  PERFORM public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    v_total, 'in', 'sale', p_sales_order_id,
    public.reporting_local_today(), v_gate_branch, NULL
  );

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  -- GATE OQ-G: bloque fiscal copiado SIN TOCAR NI UNA LÍNEA desde la
  -- definición viva capturada 2026-08-19. No modificar sin sign-off del PO.
  IF p_comprobante_type IS NOT NULL THEN
    SELECT public.rpc_emit_pending_cae(
      p_comprobante_type,
      v_total,
      v_order.client_id,
      p_point_of_sale_id
    ) INTO v_fiscal_result;

    v_fiscal_doc_id := (v_fiscal_result->>'fiscal_document_id')::uuid;
  END IF;

  -- ─── INSERT outbox (DEC-20 — SaleConfirmed) ─────────────────────────────
  -- pos-catalogo-pagos: el payload lleva el kind EFECTIVO (v_kind), no el
  -- texto crudo del cliente — coherente con lo que persiste sales_orders.
  -- limpiezas-pagos-admin (D1 de design.md): esta clave NO cambia — el
  -- consumidor (_journal_post_from_event) lee el PAYLOAD, nunca la columna.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SaleConfirmed',
    'SalesOrder',
    p_sales_order_id,
    jsonb_build_object(
      'account_id',      v_account_id,
      'branch_id',       v_gate_branch,
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_new_op_id,
      'total',           v_total,
      'payment_method',  v_kind,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- v3-document-status-history (RN-A1): transición draft→confirmed en la
  -- misma transacción atómica (junto con stock, caja, fiscal y outbox)
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', p_sales_order_id, 'draft', 'confirmed', v_uid, NULL);

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  -- limpiezas-pagos-admin (G1b): la columna de texto payment_method fue
  -- retirada — la orden persiste únicamente payment_method_id (resuelto
  -- arriba, explícito o vía la resolución legacy D2). El kind efectivo
  -- (v_kind) sigue viajando en el payload del evento SaleConfirmed.
  UPDATE public.sales_orders
  SET
    status              = 'confirmed',
    payment_method_id   = p_payment_method_id,
    total               = v_total,
    sale_operation_id   = v_new_op_id,
    fiscal_document_id  = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$function$;

-- ─── 5. rpc_atomic_update_sale_operation — REVERSE por delta guardado, APPLY normalizada ───
-- Fusión en 3 vías (2026-09-25, corrección del PR #584): base = cuerpo de
-- 20261060000001 (md5 a657c54b…), ours = cuerpo VIVO de prod dejado por
-- 20261061000001_venta_editable_vs_promocion_legacy (PR #585, md5 7c8c1b76…:
-- lock temprano FOR UPDATE de las filas sales en orden de id (N1) + recálculo
-- de la orden re-apuntada vía _sales_order_sync_from_operation (N3)), theirs =
-- los hunks de unidades de este change (v_apply_qty_norm vía el helper y
-- reversa por quantity_delta, D6). Hunks disjuntos, 0 conflictos; se conserva
-- también la anulación de venta-editable-sin-cae (#582) y sus guards P0423.
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
  v_total_sum          numeric(15,2) := 0;
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
      AND  s.user_id = v_uid
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

-- ─── 6. rpc_atomic_update_purchase_operation — REVERSE por delta guardado, APPLY normalizada ───
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

-- ─── 7. rpc_create_sale_operation — rama legacy del kill-switch por la definición única (auditoría post-apply) ───
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(
  p_idempotency_key   text,
  p_client_id         uuid,
  p_date              date,
  p_currency          text,
  p_items             jsonb,
  p_branch_id         uuid DEFAULT NULL::uuid,
  p_canal             text DEFAULT NULL::text,
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_bank_account_id   uuid DEFAULT NULL::uuid,
  p_due_date          date DEFAULT NULL::date
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
      v_total_sum             numeric(15,2) := 0;
      v_cash_session_status   text;
      v_cash_session_branch   uuid;
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
          -- Línea sin producto: no mueve stock; la unidad se sigue validando (P0404).
          PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
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

-- ─── 8. Umbral de stock mínimo fraccionario (D7) ───────────────────────────
-- branch_stock.min_stock era integer: imposible "avisar cuando queden 0,5 kg".
-- Pasa a numeric(15,4), misma precisión que quantity. La vista
-- v_products_with_stock depende de la columna (Postgres rechaza el ALTER con
-- una vista encima) → se recrea con su definición VIVA de prod (pg_get_viewdef
-- 2026-09-24), security_invoker y ACLs idénticas.
DROP VIEW IF EXISTS public.v_products_with_stock;

ALTER TABLE public.branch_stock
  ALTER COLUMN min_stock TYPE numeric(15,4) USING min_stock::numeric(15,4),
  ALTER COLUMN min_stock SET DEFAULT 0;

COMMENT ON COLUMN public.branch_stock.min_stock IS
  'Umbral de alerta de stock bajo, en la UNIDAD BASE del producto (ventas-unidades-conversion: numeric(15,4), admite fracciones — 0,5 kg). 0 = sin alerta. Única fuente de verdad del umbral (RN-23), propagada desde el producto por rpc_set_product_min_stock.';

-- products.min_stock (columna deprecada, RN-23-bis) ya es numeric(15,4) en
-- prod; el stack local reconstruido desde cero la deja integer. Guardado para
-- que local y prod converjan (mismo patrón que 20260930000001 §0).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_schema = 'public' AND table_name = 'products'
      AND  column_name = 'min_stock' AND data_type = 'integer'
  ) THEN
    ALTER TABLE public.products
      ALTER COLUMN min_stock TYPE numeric(15,4) USING min_stock::numeric(15,4);
  END IF;
END $$;

CREATE VIEW public.v_products_with_stock
WITH (security_invoker=true) AS
 SELECT p.id,
    p.user_id,
    p.name,
    p.price,
    p.cost,
    p.created_at,
    pc.name AS category,
    COALESCE(( SELECT max(bs.min_stock) AS max
           FROM public.branch_stock bs
          WHERE bs.product_id = p.id), 0) AS min_stock,
    p.parent_id,
    p.barcode,
    p.is_variant,
    p.company_id,
    p.sku,
    p.account_id,
    p.deleted_at,
    p.stock_control_type,
    COALESCE(( SELECT sum(bs.quantity) AS sum
           FROM public.branch_stock bs
          WHERE bs.product_id = p.id), 0::numeric) AS stock,
    p.category_id,
    COALESCE(p.base_unit_id, pp.base_unit_id) AS base_unit_id
   FROM public.products p
   LEFT JOIN public.product_categories pc ON pc.id = p.category_id
   LEFT JOIN public.products pp ON pp.id = p.parent_id;

-- ventas-unidades-conversion (D10, hallazgo del apply): products.base_unit_id
-- NO viajaba por la API — la vista no la exponía, ProductOut/ProductCreate/
-- ProductUpdate no la tenían y el hook del frontend no la mapeaba ni la
-- enviaba. Sin esto la "unidad en que se lleva el stock" nunca llega al
-- selector ni a la normalización local, y el formulario de producto la
-- descartaba en silencio. Columna aditiva al FINAL (mismo criterio que
-- category_id en 20261023000001: ningún lector cambia de posición). Auditoría
-- post-apply: la columna es la base EFECTIVA — una variante hereda la del padre
-- (COALESCE con el self-join), igual que el helper.
COMMENT ON COLUMN public.v_products_with_stock.base_unit_id IS
    'ventas-unidades-conversion (D10): unidad EFECTIVA en que se lleva el stock del producto (FK units_of_measure): la propia o, para una variante, la de su padre (auditoría post-apply — misma regla que _uom_normalize_quantity). NULL = sin unidad base (sólo admite unidades base al vender/comprar).';

COMMENT ON COLUMN public.v_products_with_stock.category IS
    'productos-categoria-text-retiro: derivada de product_categories.name vía category_id (LEFT JOIN). Ya NO es una columna física de products — se conserva el nombre para que ningún lector cambie (D1/OQ-1). NULL si el producto no tiene category_id.';
COMMENT ON VIEW public.v_products_with_stock IS
    'C-21: vista de compatibilidad con stock = Σ branch_stock. productos-categorias-sku: + category_id (última columna) — la fuente de verdad de la categoría. ventas-unidades-conversion: min_stock numeric(15,4) (unidad base del producto).';

-- ACLs vivas de prod (relacl): anon / authenticated / service_role con ALL.
GRANT ALL ON public.v_products_with_stock TO anon, authenticated, service_role;

-- get_dashboard_critical_stock_items devolvía min_stock integer en su RETURNS
-- TABLE: con la columna numeric, "structure of query does not match function
-- result type" en runtime. Cambiar el tipo de retorno exige DROP + CREATE
-- (CREATE OR REPLACE no puede cambiar el resultado); cuerpo vivo de prod
-- sin otro cambio, ACLs idénticas (authenticated + service_role, sin anon).
DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock_items(uuid, integer);

CREATE FUNCTION public.get_dashboard_critical_stock_items(p_branch_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20)
 RETURNS TABLE(product_id uuid, name text, sku text, branch_id uuid, branch_name text, quantity numeric, min_stock numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- D7 (contrato de paginación): p_limit NULL = sin límite (Postgres ya
  -- trata LIMIT NULL como "sin límite" nativamente); p_limit <= 0 es un
  -- error del caller, no un "cero resultados" silencioso.
  IF p_limit IS NOT NULL AND p_limit <= 0 THEN
    RAISE EXCEPTION 'p_limit debe ser positivo (o NULL para sin límite): %', p_limit
      USING ERRCODE = 'P0400';
  END IF;

  RETURN QUERY
  -- Mismo FROM/JOIN/WHERE que get_dashboard_critical_stock(p_branch_id) —
  -- ver el bloque de verificación de integridad arriba. Una fila por
  -- (producto, sucursal), no deduplicada por producto (el detalle es "por
  -- sucursal"; la hermana sí dedupea porque cuenta productos distintos).
  SELECT
    bs.product_id,
    p.name,
    p.sku,
    bs.branch_id,
    b.name AS branch_name,
    bs.quantity,
    bs.min_stock
  FROM public.branch_stock bs
  JOIN public.products p ON p.id = bs.product_id
  JOIN public.branches b ON b.id = bs.branch_id
  WHERE bs.account_id IN (SELECT current_account_ids())
    AND bs.min_stock > 0
    AND bs.quantity <= bs.min_stock
    AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
    AND p.deleted_at IS NULL
    AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
  -- Más crítico primero: menor razón quantity/min_stock (más lejos bajo su
  -- umbral), desempatado por nombre para un orden determinístico en tests.
  ORDER BY (bs.quantity / NULLIF(bs.min_stock, 0)) ASC, p.name ASC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL     ON FUNCTION public.get_dashboard_critical_stock_items(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_dashboard_critical_stock_items(uuid, integer) TO authenticated, service_role;

-- DROP + CREATE borra el COMMENT vivo: se re-emite el de prod (leído con
-- obj_description el 2026-09-25) más una línea sobre el tipo nuevo. El gate
-- embebido y el bloque E del gate SQL exigen que no quede NULL.
COMMENT ON FUNCTION public.get_dashboard_critical_stock_items(uuid, integer) IS
  'kpi-canonicalization (candidato S5): detalle canónico de productos críticos por sucursal — hermana de get_dashboard_critical_stock(uuid) con el MISMO predicado (branch_stock.min_stock > 0 AND quantity <= min_stock, tracked/untracked/variant_only, deleted_at, tenencia vía current_account_ids()), pero devolviendo las filas (una por producto+sucursal, sin deduplicar) en vez del conteo. Consumido por el Copiloto (buildBusinessSnapshot.ts) y ai-insights/index.ts para poder nombrar los productos críticos, no sólo contarlos. Nunca reconstruir este predicado desde v_products_with_stock. ventas-unidades-conversion: min_stock del resultado pasa a numeric(15,4) (unidad base del producto, admite 0,5 kg) — mismo predicado, sólo cambia el tipo.';

-- rpc_set_product_min_stock(uuid, int) → (uuid, numeric). Firma distinta =
-- DROP + CREATE, nunca CREATE OR REPLACE con la firma nueva (dejaría dos
-- overloads vivos: gotcha 42725). Cuerpo vivo de prod, sólo cambia el tipo.
-- GREATEST(..., 0) se conserva como red: el negativo lo rechaza Pydantic (ge=0).
DROP FUNCTION IF EXISTS public.rpc_set_product_min_stock(uuid, integer);

-- OR REPLACE sobre la firma NUEVA (no sobre la vieja): reaplicable sin 42723.
CREATE OR REPLACE FUNCTION public.rpc_set_product_min_stock(
  p_product_id uuid,
  p_min_stock  numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        uuid;
  v_account_id uuid;
  v_min_stock  numeric(15,4);
  v_updated    int;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- Resolver la cuenta del producto (no la del caller): el producto ya
  -- pertenece a una cuenta fija; el caller debe ser writer de ESA cuenta.
  SELECT account_id INTO v_account_id
  FROM   public.products
  WHERE  id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can set min_stock'
      USING ERRCODE = 'P0401';
  END IF;

  v_min_stock := GREATEST(COALESCE(p_min_stock, 0), 0)::numeric(15,4);

  UPDATE public.branch_stock
  SET    min_stock = v_min_stock
  WHERE  product_id = p_product_id
    AND  account_id = v_account_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object(
    'product_id',    p_product_id,
    'min_stock',     v_min_stock,
    'rows_updated',  v_updated
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_set_product_min_stock(uuid, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_set_product_min_stock(uuid, numeric) TO authenticated, service_role;

-- DROP + CREATE borra el COMMENT vivo: se re-emite el de prod (leído con
-- obj_description el 2026-09-25) más una línea sobre la firma nueva.
COMMENT ON FUNCTION public.rpc_set_product_min_stock(uuid, numeric) IS
  'branch-min-stock-realign (1.2): propaga min_stock del producto a TODAS las filas branch_stock existentes de ese producto (semántica "aplica a todas las sucursales", decisión PO 2026-07-04). SECURITY DEFINER + guard is_account_writer — mismo patrón que rpc_adjust_branch_stock. Filas branch_stock lazy futuras (creadas por otros deltas) nacen en min_stock=0 hasta la próxima edición que re-propague; comportamiento aceptado y documentado (ver design.md Decisión (a)). ventas-unidades-conversion: p_min_stock pasa de integer a numeric y se guarda como numeric(15,4) (unidad base del producto, admite 0,5 kg); la firma (uuid, integer) se retiró con DROP + CREATE, sin overload.';

-- ─── 10. Reporting en unidad BASE (segunda revisión del PR #584) ────────────
-- Con este change el POS y los formularios venden en unidades no base (g,
-- docenas). Todo el reporting multiplicaba la cantidad CRUDA de la línea por
-- un costo POR UNIDAD BASE (unit_cost_snapshot / products.cost) y sumaba las
-- unidades crudas: 100 g de un producto a 600/kg costaban 60.000 y contaban
-- "100" unidades en el Tablero, /estadisticas y rentabilidad (medido en el
-- stack local, 30-consumidores-cantidad-cruda.out.txt). En prod hoy: 0 filas
-- afectadas (las 1.030 líneas con unidad están en su unidad base); este
-- change es lo que las vuelve alcanzables.
--
-- El precio NO cambia de semántica (contrato D-F, provisorio hasta el sign-off
-- del PO): `amount`/`price` es por unidad de LA LÍNEA y el importe de línea
-- sigue siendo COALESCE(total, amount) — sólo la CANTIDAD que se cuenta y se
-- costea pasa a la unidad base.
--
-- Envoltorio de LECTURA de la definición única: el helper rechaza (P0400) una
-- línea histórica que la regla de escritura de hoy no admitiría — la venta
-- real del 2026-09-22 en mL sobre un producto sin unidad base —, y un reporte
-- no puede abortar por eso: se reporta tal como se grabó. No hay una segunda
-- aritmética: convierte SÓLO _uom_normalize_quantity.
CREATE OR REPLACE FUNCTION public._uom_quantity_for_reporting(
  p_product_id uuid,
  p_unit_id    uuid,
  p_quantity   numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
BEGIN
  -- Camino rápido sin subtransacción: línea sin unidad o sin producto.
  IF p_unit_id IS NULL OR p_product_id IS NULL OR p_quantity IS NULL THEN
    RETURN p_quantity;
  END IF;
  BEGIN
    RETURN public._uom_normalize_quantity(p_product_id, p_unit_id, p_quantity);
  EXCEPTION WHEN SQLSTATE 'P0400' OR SQLSTATE 'P0404' THEN
    RETURN p_quantity;
  END;
END;
$$;

COMMENT ON FUNCTION public._uom_quantity_for_reporting(uuid, uuid, numeric) IS
  'ventas-unidades-conversion (segunda revisión): cantidad de una línea de venta en la unidad BASE del producto para REPORTING (la unidad en que están unit_cost_snapshot y products.cost). Envoltorio de lectura de _uom_normalize_quantity, la única definición: una línea histórica que la regla de escritura de hoy rechazaría (P0400/P0404) se reporta con la cantidad tal como se grabó, en vez de abortar el reporte. La consumen reporting_sales_lines_in_window (y por ella ranking, evolución, desgloses, top clientes y rentabilidad), rpc_dashboard_kpi_summary y rpc_dashboard_channel_margin. Sin EXECUTE para anon/authenticated.';

REVOKE ALL ON FUNCTION public._uom_quantity_for_reporting(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;

-- Los tres cuerpos parten de su pg_get_functiondef VIVO (md5 en el preflight,
-- §0) y sólo cambian la cantidad; CREATE OR REPLACE conserva firma, ACLs y
-- COMMENT. reporting_sales_lines_in_window sigue siendo SQL sin SET
-- search_path (inlineable, estadisticas-ventas E1).

CREATE OR REPLACE FUNCTION public.reporting_sales_lines_in_window(p_account_id uuid, p_start date, p_end date, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text)
 RETURNS TABLE(sale_id uuid, operation_key uuid, product_id uuid, client_id uuid, branch_id uuid, canal text, business_date date, created_at timestamp with time zone, quantity numeric, line_revenue numeric, unit_cost numeric, has_cost boolean)
 LANGUAGE sql
 STABLE
AS $function$
  SELECT
    s.id,
    COALESCE(s.operation_id, s.id),
    s.product_id,
    s.client_id,
    s.branch_id,
    s.canal,
    -- reporting-invariants (fecha de negocio vs instante): sales.date guarda el
    -- día calendario declarado a 00:00 UTC. Casteo DIRECTO — aplicarle
    -- AT TIME ZONE corre cada venta un día hacia atrás (218/218 medido).
    s.date::date,
    s.created_at,
    -- ventas-unidades-conversion (segunda revisión, 2026-09-25): cantidad en
    -- la unidad BASE del producto — la misma en que están unit_cost_snapshot
    -- y products.cost. Antes 100 g sobre un producto a 600/kg sumaban "100"
    -- unidades y costaban 60.000. Única conversión: _uom_normalize_quantity,
    -- vía el envoltorio de lectura (nunca aborta por una línea histórica).
    public._uom_quantity_for_reporting(s.product_id, s.unit_id, s.quantity),
    -- RN-D (revenue de línea consistente): COALESCE(total, amount), nunca
    -- amount solo (precio unitario).
    COALESCE(s.total, s.amount),
    -- RN-D2 cascada canónica: snapshot congelado de la línea; products.cost
    -- actual sólo cuando la línea no tiene snapshot. products-costo-nullable:
    -- la nulabilidad se propaga sola — el costo del catálogo es opcional.
    COALESCE(si.unit_cost_snapshot, pr.cost),
    -- productos-costo-nullable (D3): has_cost_snapshot -> has_cost. La
    -- pregunta que la spec product-ranking hace es "¿tiene costo?", no
    -- "¿tiene snapshot?" — una línea sin snapshot pero con costo de catálogo
    -- real tiene su margen perfectamente medido y debe contar como cubierta.
    (COALESCE(si.unit_cost_snapshot, pr.cost) IS NOT NULL)
  FROM public.sales s
  LEFT JOIN public.products   pr ON pr.id = s.product_id
  LEFT JOIN public.sale_items si ON si.sale_id = s.id AND si.product_id = s.product_id
  WHERE s.account_id = p_account_id
    -- RN-D5: bordes >= inicio y < fin + 1 día (ambos a medianoche UTC, como
    -- las filas). p_end NULL = sin borde superior (rpc_product_profitability).
    AND s.date >= p_start::timestamptz
    AND (p_end IS NULL OR s.date < (p_end + 1)::timestamptz)
    AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    AND (p_canal     IS NULL OR s.canal     = p_canal);
$function$;

CREATE OR REPLACE FUNCTION public.rpc_dashboard_kpi_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(net_profit numeric, prev_net_profit numeric, avg_ticket numeric, prev_avg_ticket numeric, cost_per_sale numeric, prev_cost_per_sale numeric, stagnant_stock_value numeric, stagnant_stock_count integer, stagnant_stock_without_cost_count integer, prev_stagnant_stock_value numeric, prev_stagnant_stock_count integer, sales_count integer, prev_sales_count integer, invoiced_revenue numeric, prev_invoiced_revenue numeric, collected_revenue numeric, prev_collected_revenue numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_from > p_to OR p_prev_from > p_prev_to THEN
    RAISE EXCEPTION 'Invalid date range' USING ERRCODE = 'P0400';
  END IF;

  RETURN QUERY
  WITH sales_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS revenue,
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_revenue,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_from      AND p_to)     AS ops,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to) AS prev_ops,
      -- v3-snapshot-pattern (D6): COGS = snapshot congelado (via sale_items),
      -- fallback a pr.cost actual solo si la línea no tiene snapshot.
      -- productos-costo-nullable: pr.cost puede ser NULL — el COALESCE final
      -- a 0 es el KPI de rentabilidad agregada de la cuenta (no un ranking
      -- por producto), donde un costo ausente sigue sin poder inventarse
      -- pero tampoco puede dejar el KPI entero en NULL.
      -- ventas-unidades-conversion (segunda revisión): el costo es por unidad
      -- BASE, así que la cantidad también — vía el envoltorio de lectura.
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * public._uom_quantity_for_reporting(s.product_id, s.unit_id, s.quantity)) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS cogs,
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * public._uom_quantity_for_reporting(s.product_id, s.unit_id, s.quantity)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D1, grupo 6): la regla de NC —incluida la
  -- atribución de sucursal— vive en el helper único (D5) consumido también
  -- por get_dashboard_financials. p_branch_id ahora SÍ filtra (helper
  -- reescrito en esta migración).
  nc_agg AS (
    SELECT
      public.reporting_credit_notes_in_window(v_account_id, p_from,      p_to,      p_branch_id) AS nc,
      public.reporting_credit_notes_in_window(v_account_id, p_prev_from, p_prev_to, p_branch_id) AS prev_nc
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cargos a cuenta corriente del período. SIGUEN sin filtrar por sucursal
  -- (nivel cuenta) — no son la causa de collected_revenue = NULL bajo
  -- filtro, pero tampoco se filtran: ver el CASE del SELECT final.
  charges_agg AS (
    SELECT
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_from      AND p_to),      0) AS charges,
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_charges
    FROM public.customer_account_movements cam
    WHERE cam.account_id = v_account_id
      AND cam.movement_type = 'sale'
      AND cam.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cobros del período. payments_received no tiene sucursal atribuible
  -- (reference_sale_id opcional y en la práctica NULL) — no filtrable.
  payments_agg AS (
    SELECT
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_from      AND p_to),      0) AS payments,
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_payments
    FROM public.payments_received pr_
    WHERE pr_.account_id = v_account_id
      AND pr_.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  expenses_agg AS (
    SELECT
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_from      AND p_to),      0) AS expenses,
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_expenses
    FROM public.expenses e
    WHERE e.account_id = v_account_id
      AND e.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
  ),
  purchases_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_from      AND p_to),      0) AS purchases,
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_purchases
    FROM public.purchases pu
    WHERE pu.account_id = v_account_id
      AND pu.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR pu.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D3, grupo 5): stock sin rotación por sucursal
  -- sobre branch_stock. productos-costo-nullable (OQ-2=a, D13): la
  -- aritmética NO cambia — un producto sin costo sigue aportando 0 al total
  -- (idéntico a un cost=0 de hoy) — lo que se agrega es CUÁNTOS de los
  -- productos sin rotación no tienen costo, para que el total sea auditable.
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0)                    AS value,
      COUNT(DISTINCT bs.product_id)::integer                                 AS cnt,
      COUNT(DISTINCT bs.product_id) FILTER (WHERE p.cost IS NULL)::integer   AS without_cost_cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_from AND p_to
          -- kpi-branch-consistency (D4): fail-open sobre ventas legacy sin
          -- sucursal. 75% de las filas de `sales` en producción tienen
          -- branch_id NULL (medido 2026-08-11) — una venta legacy es
          -- evidencia REAL de rotación y no se puede duplicar (EXISTS, no
          -- SUM); fail-closed marcaría como "sin rotación" a casi todo el
          -- catálogo apenas se selecciona una sucursal.
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(DISTINCT bs.product_id)::integer               AS cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  )
  SELECT
    (sa.revenue - na.nc)      - (ea.expenses      + pa.purchases)       AS net_profit,
    (sa.prev_revenue - na.prev_nc) - (ea.prev_expenses + pa.prev_purchases)  AS prev_net_profit,
    ROUND(sa.revenue      / NULLIF(sa.ops, 0), 2)             AS avg_ticket,
    ROUND(sa.prev_revenue / NULLIF(sa.prev_ops, 0), 2)        AS prev_avg_ticket,
    ROUND(sa.cogs         / NULLIF(sa.ops, 0), 2)             AS cost_per_sale,
    ROUND(sa.prev_cogs    / NULLIF(sa.prev_ops, 0), 2)        AS prev_cost_per_sale,
    sc.value                                                  AS stagnant_stock_value,
    sc.cnt                                                    AS stagnant_stock_count,
    sc.without_cost_cnt                                       AS stagnant_stock_without_cost_count,
    sp.value                                                  AS prev_stagnant_stock_value,
    sp.cnt                                                    AS prev_stagnant_stock_count,
    sa.ops::integer                                           AS sales_count,
    sa.prev_ops::integer                                      AS prev_sales_count,
    -- v3-reporting-invariants (RN-D3): devengado neto de NC, filtrado por
    -- sucursal (el helper ya atribuye — D1, grupo 6).
    (sa.revenue - na.nc)                                      AS invoiced_revenue,
    (sa.prev_revenue - na.prev_nc)                            AS prev_invoiced_revenue,
    -- kpi-branch-consistency (D2, grupo 6): collected_revenue no es
    -- computable por sucursal — payments_received no tiene branch_id
    -- atribuible (reference_sale_id opcional y en la práctica NULL), y
    -- percibido = devengado - cargos + cobros es una identidad cuyos tres
    -- términos deben vivir en el mismo universo. Bajo filtro de sucursal se
    -- declara NULL (requirement de filtro uniforme, reporting-invariants)
    -- en vez de mezclar un devengado filtrado con cargos/cobros de toda la
    -- cuenta. Sin filtro, comportamiento sin cambios.
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.revenue - na.nc) - ca.charges + pay.payments
    END                                                        AS collected_revenue,
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.prev_revenue - na.prev_nc) - ca.prev_charges + pay.prev_payments
    END                                                        AS prev_collected_revenue
  FROM sales_agg sa
  CROSS JOIN nc_agg        na
  CROSS JOIN charges_agg   ca
  CROSS JOIN payments_agg  pay
  CROSS JOIN expenses_agg  ea
  CROSS JOIN purchases_agg pa
  CROSS JOIN stagnant_curr sc
  CROSS JOIN stagnant_prev sp;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_dashboard_channel_margin(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(channels jsonb, leader text, margin_pct numeric, prev_margin_pct numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  RETURN QUERY
  WITH per_channel AS (
    -- v3-snapshot-pattern (D6): COGS = snapshot congelado, fallback a pr.cost
    -- actual solo si la línea no tiene snapshot (histórica no backfilleada).
    -- ventas-unidades-conversion (segunda revisión): cantidad en unidad BASE
    -- (la del costo), vía el envoltorio de lectura de _uom_normalize_quantity.
    SELECT
      COALESCE(NULLIF(trim(s.canal), ''), 'sin_canal')                                          AS canal,
      SUM(COALESCE(s.total, s.amount))                                                           AS revenue,
      SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(public._uom_quantity_for_reporting(si.product_id, si.unit_id, si.quantity), 0))                AS cogs
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    GROUP BY 1
  ),
  channel_rows AS (
    SELECT
      pc.canal,
      pc.revenue,
      ROUND((pc.revenue - pc.cogs) / NULLIF(pc.revenue, 0) * 100, 1) AS margin_pct
    FROM per_channel pc
    WHERE pc.revenue > 0
  ),
  totals_curr AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(public._uom_quantity_for_reporting(si.product_id, si.unit_id, si.quantity), 0)))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  totals_prev AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(public._uom_quantity_for_reporting(si.product_id, si.unit_id, si.quantity), 0)))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_prev_from AND p_prev_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  )
  SELECT
    COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object('canal', cr.canal, 'revenue', cr.revenue, 'margin_pct', cr.margin_pct)
                ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
              )
       FROM channel_rows cr),
      '[]'::jsonb
    )                                                                AS channels,
    (SELECT cr.canal FROM channel_rows cr
     ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
     LIMIT 1)                                                        AS leader,
    tc.pct                                                           AS margin_pct,
    tp.pct                                                           AS prev_margin_pct
  FROM totals_curr tc
  CROSS JOIN totals_prev tp;
END;
$function$;

-- ─── 11. La unidad base no cambia debajo del stock (D-C, en la base) ─────────
-- D-C (decisión provisoria hasta el sign-off del PO, decisión 6 opción (a)):
-- se permite ASIGNAR la unidad base a un producto que no la tenía; cambiarla
-- (o quitarla) se rechaza si el grupo (el producto y las variantes que la
-- heredan) tiene stock distinto de 0 en alguna sucursal o movimientos de
-- stock — "12 u" pasaría a leerse "12 kg". El guard de FastAPI
-- (_guard_base_unit_change) quedaba solo: `authenticated` tiene UPDATE sobre
-- products.base_unit_id (policy products_writer_update), así que un PATCH
-- por PostgREST lo salteaba, y el chequeo leía sin bloquear (TOCTOU con una
-- compra concurrente). El trigger es el único punto de paso para cualquier
-- escritor, presente o futuro — mismo patrón que trg_guard_branch_decommission
-- y trg_product_category_tenancy_guard —, y evalúa con la fila bloqueada y las
-- variantes tomadas FOR UPDATE. La serialización con una venta o compra
-- concurrente es de DOS lados: las seis RPCs toman FOR UPDATE la fila del
-- producto de cada línea y, desde la tercera revisión, recién DESPUÉS
-- normalizan la cantidad (antes, en tres de los seis caminos, normalizaban con
-- la unidad commiteada y la carrera seguía abierta: una compra escribía 2 kg
-- que se leían 2 u — reproducido con dos conexiones y fijado por
-- supabase/tests/test_ventas_unidades_conversion_race.sh). Además replica en
-- la base el guard de tenencia del backend (base_unit_not_found → 404): la
-- unidad base es del sistema o de la cuenta.
CREATE OR REPLACE FUNCTION public.fn_product_base_unit_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_unit_system  boolean;
  v_unit_account uuid;
  v_parent_base  uuid;
  v_old_parent_base  uuid;
  v_old_eff      uuid;
  v_new_eff      uuid;
  v_self_changed     boolean;
  v_children_changed boolean;
BEGIN
  -- Tenencia: sólo cuando la unidad base (o la cuenta) efectivamente cambia.
  IF NEW.base_unit_id IS NOT NULL AND (
       TG_OP = 'INSERT'
       OR NEW.base_unit_id IS DISTINCT FROM OLD.base_unit_id
       OR NEW.account_id   IS DISTINCT FROM OLD.account_id) THEN
    SELECT COALESCE(u.is_system, false), u.account_id
      INTO v_unit_system, v_unit_account
      FROM public.units_of_measure u
     WHERE u.id = NEW.base_unit_id;
    IF NOT FOUND OR (NOT v_unit_system AND v_unit_account IS DISTINCT FROM NEW.account_id) THEN
      RAISE EXCEPTION 'base_unit_not_found: la unidad base no existe o no pertenece a la cuenta del producto'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- Tercera revisión: la unidad base EFECTIVA de una variante que hereda
  -- también cambia si se la RE-PARENTA (o se la desengancha): `authenticated`
  -- tiene UPDATE sobre products.parent_id, y re-parentar 5 kg a un padre en
  -- 'u' los dejaba leyéndose 5 u (reproducido por PostgREST).
  IF TG_OP = 'INSERT'
     OR (NEW.base_unit_id IS NOT DISTINCT FROM OLD.base_unit_id
         AND NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id) THEN
    RETURN NEW;
  END IF;

  -- Unidad base EFECTIVA antes y después: la propia o la heredada del padre
  -- (misma regla que _uom_normalize_quantity y v_products_with_stock) — el
  -- padre de OLD para la de antes y el de NEW para la de después.
  IF OLD.parent_id IS NOT NULL THEN
    SELECT p.base_unit_id INTO v_old_parent_base FROM public.products p WHERE p.id = OLD.parent_id;
  END IF;
  IF NEW.parent_id IS NOT NULL THEN
    SELECT p.base_unit_id INTO v_parent_base FROM public.products p WHERE p.id = NEW.parent_id;
  END IF;
  v_old_eff := COALESCE(OLD.base_unit_id, v_old_parent_base);
  v_new_eff := COALESCE(NEW.base_unit_id, v_parent_base);

  -- D-C: asignar a quien no tenía unidad efectiva se permite; sin cambio
  -- efectivo no hay nada que proteger. Dos grupos, cada uno con su condición:
  --   · el producto mismo, si SU unidad efectiva cambia (base propia o padre);
  --   · las variantes que HEREDAN su base propia, si la base PROPIA cambia
  --     desde un valor no nulo (re-parentar al producto no las toca: heredan
  --     NEW.base_unit_id, no la unidad efectiva de NEW).
  v_self_changed     := v_old_eff IS NOT NULL AND v_old_eff IS DISTINCT FROM v_new_eff;
  v_children_changed := OLD.base_unit_id IS NOT NULL AND NEW.base_unit_id IS DISTINCT FROM OLD.base_unit_id;
  IF NOT v_self_changed AND NOT v_children_changed THEN
    RETURN NEW;
  END IF;

  -- Las variantes que heredan se toman FOR UPDATE (orden de id) para
  -- serializar con las ventas/compras, que toman la fila de su producto.
  IF v_children_changed THEN
    PERFORM 1 FROM public.products v
     WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL
     ORDER BY v.id
     FOR UPDATE;
  END IF;

  IF EXISTS (
       SELECT 1 FROM public.branch_stock bs
        WHERE bs.quantity <> 0
          AND ((v_self_changed AND bs.product_id = NEW.id)
               OR (v_children_changed
                   AND bs.product_id IN (SELECT v.id FROM public.products v
                                          WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL))))
     OR EXISTS (
       SELECT 1 FROM public.stock_movements sm
        WHERE (v_self_changed AND sm.product_id = NEW.id)
           OR (v_children_changed
               AND sm.product_id IN (SELECT v.id FROM public.products v
                                      WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL))) THEN
    RAISE EXCEPTION 'base_unit_locked: el producto % ya tiene stock o movimientos en su unidad base actual; cambiarla haría que las cantidades se lean en otra unidad. Creá un producto nuevo con la unidad correcta y pasale el stock con un ajuste.', NEW.id
      USING ERRCODE = 'P0409';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_product_base_unit_guard() IS
  'ventas-unidades-conversion (D-C, segunda y tercera revisión; provisorio hasta el sign-off del PO): la unidad base EFECTIVA de un producto (propia o heredada del padre) no cambia ni se quita si el grupo tiene stock <> 0 o movimientos (P0409 base_unit_locked) — ni cambiando base_unit_id ni re-parentando o desenganchando una variante que hereda (parent_id); asignarla a un producto que no tenía se permite. Tenencia: la unidad base es del sistema o de la cuenta (P0404 base_unit_not_found). Único punto de paso para FastAPI, PostgREST y cualquier escritor futuro.';

REVOKE ALL ON FUNCTION public.fn_product_base_unit_guard() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_product_base_unit_guard ON public.products;
CREATE TRIGGER trg_product_base_unit_guard
  BEFORE INSERT OR UPDATE OF base_unit_id, account_id, parent_id ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_product_base_unit_guard();

-- ─── 12. D-F′: el precio por unidad de la LÍNEA no se redondea (tercera revisión) ──
-- Contrato D-F (D12): `amount`/`price` es por unidad de la línea. Re-expresado
-- a una unidad chica, un precio de catálogo con centavos necesita más de dos
-- decimales ($4.575/kg = $4,575/g; $1.234,56/kg = $1,23456/g). sales.amount,
-- sale_items.price, purchases.amount y purchase_items.price ya son numeric
-- sin tope; sales_order_items.price y quote_items.price eran numeric(15,2):
-- el POS grababa 4,58 en sales.amount (amount × quantity ≠ total) y editar
-- la venta sin tocar nada la re-preciaba (2.058,75 → 2.061, medido por la
-- revisión). Se llevan al mismo tipo que las otras cuatro: una sola precisión
-- para el precio unitario de una línea. Los totales de dinero (subtotal,
-- sales_orders.total, caja, banco, cuenta corriente) siguen al centavo.
--
-- Costo: numeric(15,2) → numeric sin tope es binario-compatible, sin
-- reescritura de tabla (el CHECK price >= 0 se re-valida: 237 filas en prod
-- el 2026-09-25, 104 kB; quote_items 48 kB); lock ACCESS EXCLUSIVE de
-- milisegundos. Sin vistas, índices ni policies sobre la columna (medido en
-- prod). Guardado: la reaplicación no toca una columna ya ampliada.
DO $$
DECLARE
  v_t text;
BEGIN
  FOR v_t IN
    SELECT c.table_name::text
    FROM   information_schema.columns c
    WHERE  c.table_schema = 'public'
      AND  c.table_name IN ('sales_order_items', 'quote_items')
      AND  c.column_name = 'price'
      AND  c.numeric_scale IS NOT NULL
    ORDER BY 1
  LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN price TYPE numeric', v_t);
    RAISE NOTICE 'ventas-unidades-conversion: %.price numeric(15,2) → numeric (D-F′)', v_t;
  END LOOP;
END $$;

-- ─── 13. check_low_margin costea en unidad BASE (tercera revisión) ───────────
-- Trigger on_sale_insert_margin_check (AFTER INSERT ON sales) → email
-- "Alerta de margen crítico". Comparaba el precio UNITARIO (NEW.amount)
-- contra costo × cantidad CRUDA: con D-F cada venta en una unidad menor a la
-- base (g, mL) mandaba un email con un margen absurdo (100 g a $1,80/g con
-- costo $1.200/kg: −6.666.567 %), y ya antes cualquier venta con cantidad > 1
-- daba un falso positivo (3 u a $100 con costo $50: −50 %) — prod registró
-- 71 alertas en 30 días, 66 de ellas con cantidad > 1 que con el cálculo nuevo
-- no se disparan (medido el 2026-09-25). Ahora: importe de la LÍNEA
-- (COALESCE(total, amount ×
-- quantity), la misma regla RN-D del reporting) contra costo por unidad base ×
-- cantidad en unidad base (_uom_quantity_for_reporting, el envoltorio de
-- lectura de la definición única — nunca aborta un INSERT por una línea
-- histórica inconvertible). El email muestra ese importe y ese costo.
--
-- Cuerpo de partida: el VIVO de prod (md5 a03b312675753c26372046613391c17b,
-- medido el 2026-09-25 = 20260517000002_fix_function_search_path.sql:42, en
-- el preflight). CREATE OR REPLACE conserva firma, SECURITY DEFINER,
-- search_path y ACL (postgres, service_role); no tenía COMMENT.
CREATE OR REPLACE FUNCTION public.check_low_margin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  prod_cost    numeric;
  prod_name    text;
  sale_margin  numeric;
  user_email   text;
  -- ventas-unidades-conversion (tercera revisión)
  v_qty_base   numeric;
  v_revenue    numeric;
  v_cost_basis numeric;
BEGIN
  IF NEW.product_id IS NOT NULL AND NEW.amount > 0 THEN
    SELECT cost, name INTO prod_cost, prod_name
    FROM public.products WHERE id = NEW.product_id;

    IF prod_cost IS NOT NULL THEN
      v_qty_base   := public._uom_quantity_for_reporting(NEW.product_id, NEW.unit_id, NEW.quantity);
      v_revenue    := COALESCE(NEW.total, NEW.amount * NEW.quantity);
      v_cost_basis := prod_cost * v_qty_base;
      sale_margin  := ((v_revenue - v_cost_basis) / NULLIF(v_revenue, 0)) * 100;

      IF sale_margin < 15 THEN
        SELECT email INTO user_email FROM auth.users WHERE id = NEW.user_id;

        INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
        VALUES (
          NEW.user_id,
          'low_margin_alert',
          user_email,
          'Alerta de Margen Bajo: ' || prod_name,
          jsonb_build_object(
            'sale_id',            NEW.id,
            'product_name',       prod_name,
            'margin_percentage',  round(sale_margin, 2),
            'amount',             round(v_revenue, 2),
            'cost_basis',         round(v_cost_basis, 2)
          )
        );
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.check_low_margin() IS
  'Trigger on_sale_insert_margin_check (AFTER INSERT ON sales): si el margen de la línea es menor al 15 %, registra un email low_margin_alert. ventas-unidades-conversion (tercera revisión): margen = (importe de la línea − costo por unidad base × cantidad en unidad base) / importe de la línea; importe = COALESCE(total, amount × quantity) y cantidad vía _uom_quantity_for_reporting. Antes comparaba el precio unitario contra costo × cantidad cruda (falso positivo con cantidad > 1, margen absurdo en g/mL).';

-- ─── 14. Gate embebido de introspección (falla el deploy si falta una pieza) ──
-- Cada literal que se agrega a v_bad lleva ::text: text[] || 'literal' la
-- resolvería como ARRAY ("malformed array literal") y taparía el motivo real.
DO $$
DECLARE
  v_fn      text;
  v_src     text;
  v_bad     text[] := '{}';
  v_cnt     integer;
  v_type    text;
  v_scale   integer;
  v_res     text;
  v_pos1    integer;
  v_pos2    integer;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    '_c29_confirm_order_core', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
    'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
    'rpc_create_sale_operation'
  ] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_src IS NULL THEN
      v_bad := v_bad || (v_fn || ': no existe'); CONTINUE;
    END IF;
    IF position('public._uom_normalize_quantity(' IN v_src) = 0 THEN
      v_bad := v_bad || (v_fn || ': no invoca _uom_normalize_quantity');
    END IF;
    IF v_src ~ '\*\s*v_unit_factor' THEN
      v_bad := v_bad || (v_fn || ': conserva la multiplicación inline por v_unit_factor');
    END IF;
    IF position('v_qty_norm := v_item.quantity;' IN v_src) > 0 THEN
      v_bad := v_bad || (v_fn || ': sigue descontando la cantidad cruda');
    END IF;
  END LOOP;

  -- Las dos ediciones: la pata APPLY nunca vuelve a pasar la cantidad cruda.
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_atomic_update_sale_operation';
  IF v_src ~ '-v_item\.quantity,\s*''sale''' OR v_src ~ 'v_old_sale\.quantity,\s*''sale_return''' THEN
    v_bad := v_bad || 'rpc_atomic_update_sale_operation: alguna pata sigue usando la cantidad cruda'::text;
  END IF;
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_atomic_update_purchase_operation';
  IF v_src ~ 'v_item\.quantity,\s*''purchase''' OR v_src ~ '-v_old_purchase\.quantity,\s*''purchase_return''' THEN
    v_bad := v_bad || 'rpc_atomic_update_purchase_operation: alguna pata sigue usando la cantidad cruda'::text;
  END IF;

  -- Helper: una sola definición, SECURITY INVOKER, sin EXECUTE para los roles de aplicación.
  SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity';
  IF v_cnt <> 1 THEN v_bad := v_bad || format('_uom_normalize_quantity: %s definiciones (esperaba 1)', v_cnt); END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity' AND p.prosecdef) THEN
    v_bad := v_bad || '_uom_normalize_quantity: es SECURITY DEFINER (debe ser INVOKER)'::text;
  END IF;
  IF has_function_privilege('anon', 'public._uom_normalize_quantity(uuid, uuid, numeric)', 'EXECUTE') THEN
    v_bad := v_bad || '_uom_normalize_quantity: anon puede ejecutarla'::text;
  END IF;
  IF has_function_privilege('authenticated', 'public._uom_normalize_quantity(uuid, uuid, numeric)', 'EXECUTE') THEN
    v_bad := v_bad || '_uom_normalize_quantity: authenticated puede ejecutarla'::text;
  END IF;

  -- min_stock numeric(15,4) en branch_stock y en products.
  SELECT data_type, numeric_scale INTO v_type, v_scale FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'branch_stock' AND column_name = 'min_stock';
  IF v_type IS DISTINCT FROM 'numeric' OR v_scale IS DISTINCT FROM 4 THEN
    v_bad := v_bad || format('branch_stock.min_stock: %s/%s (esperaba numeric/4)', v_type, v_scale);
  END IF;
  SELECT data_type INTO v_type FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'min_stock';
  IF v_type IS DISTINCT FROM 'numeric' THEN
    v_bad := v_bad || format('products.min_stock: %s (esperaba numeric)', v_type);
  END IF;

  -- rpc_set_product_min_stock: UNA firma, con numeric.
  SELECT count(*), max(pg_get_function_identity_arguments(p.oid)) INTO v_cnt, v_res
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_set_product_min_stock';
  IF v_cnt <> 1 OR v_res IS DISTINCT FROM 'p_product_id uuid, p_min_stock numeric' THEN
    v_bad := v_bad || format('rpc_set_product_min_stock: %s firmas, última "%s"', v_cnt, v_res);
  END IF;
  IF has_function_privilege('anon', 'public.rpc_set_product_min_stock(uuid, numeric)', 'EXECUTE') THEN
    v_bad := v_bad || 'rpc_set_product_min_stock: anon puede ejecutarla'::text;
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpc_set_product_min_stock(uuid, numeric)', 'EXECUTE') THEN
    v_bad := v_bad || 'rpc_set_product_min_stock: authenticated perdió EXECUTE'::text;
  END IF;

  -- get_dashboard_critical_stock_items: una firma, min_stock numeric en el resultado, ACLs.
  SELECT count(*), max(pg_get_function_result(p.oid)) INTO v_cnt, v_res
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_dashboard_critical_stock_items';
  IF v_cnt <> 1 OR v_res !~ 'min_stock numeric' THEN
    v_bad := v_bad || format('get_dashboard_critical_stock_items: %s firmas, resultado "%s"', v_cnt, v_res);
  END IF;
  IF has_function_privilege('anon', 'public.get_dashboard_critical_stock_items(uuid, integer)', 'EXECUTE') THEN
    v_bad := v_bad || 'get_dashboard_critical_stock_items: anon puede ejecutarla'::text;
  END IF;

  -- DROP + CREATE no puede dejar las dos funciones sin su COMMENT vivo.
  IF obj_description('public.get_dashboard_critical_stock_items(uuid, integer)'::regprocedure, 'pg_proc') IS NULL THEN
    v_bad := v_bad || 'get_dashboard_critical_stock_items: perdió su COMMENT ON FUNCTION'::text;
  END IF;
  IF obj_description('public.rpc_set_product_min_stock(uuid, numeric)'::regprocedure, 'pg_proc') IS NULL THEN
    v_bad := v_bad || 'rpc_set_product_min_stock: perdió su COMMENT ON FUNCTION'::text;
  END IF;

  -- Vista recreada con security_invoker y visible para los roles de aplicación.
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'v_products_with_stock' AND c.relkind = 'v'
      AND c.reloptions::text LIKE '%security_invoker=true%'
  ) THEN
    v_bad := v_bad || 'v_products_with_stock: no existe o perdió security_invoker'::text;
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.v_products_with_stock', 'SELECT') THEN
    v_bad := v_bad || 'v_products_with_stock: authenticated perdió SELECT'::text;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'v_products_with_stock' AND column_name = 'base_unit_id'
  ) THEN
    v_bad := v_bad || 'v_products_with_stock: no expone base_unit_id (D10)'::text;
  END IF;
  -- Auditoría post-apply: la base de una variante es la del padre, en la vista y en el helper.
  IF pg_get_viewdef('public.v_products_with_stock'::regclass) !~ 'pp\.base_unit_id' THEN
    v_bad := v_bad || 'v_products_with_stock: base_unit_id no hereda del padre (COALESCE con pp.base_unit_id)'::text;
  END IF;
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity';
  IF position('LEFT JOIN public.products pp' IN v_src) = 0 OR position('v_unit.is_system' IN v_src) = 0 THEN
    v_bad := v_bad || '_uom_normalize_quantity: perdió la herencia del padre o el guard de tenencia'::text;
  END IF;

  -- Segunda revisión (§10): el reporting cuenta y costea en unidad base.
  FOREACH v_fn IN ARRAY ARRAY['reporting_sales_lines_in_window', 'rpc_dashboard_kpi_summary', 'rpc_dashboard_channel_margin'] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_src IS NULL OR position('public._uom_quantity_for_reporting(' IN v_src) = 0 THEN
      v_bad := v_bad || (v_fn || ': no cuenta la cantidad en unidad base (_uom_quantity_for_reporting)');
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public._uom_quantity_for_reporting(uuid, uuid, numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._uom_quantity_for_reporting(uuid, uuid, numeric)', 'EXECUTE') THEN
    v_bad := v_bad || '_uom_quantity_for_reporting: ejecutable por anon/authenticated'::text;
  END IF;
  -- §11: el guard de la unidad base vive en la tabla (no sólo en FastAPI).
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                 WHERE t.tgrelid = 'public.products'::regclass AND t.tgname = 'trg_product_base_unit_guard' AND NOT t.tgisinternal) THEN
    v_bad := v_bad || 'products: falta trg_product_base_unit_guard (D-C en la base)'::text;
  END IF;
  IF has_function_privilege('authenticated', 'public.fn_product_base_unit_guard()', 'EXECUTE') THEN
    v_bad := v_bad || 'fn_product_base_unit_guard: ejecutable por authenticated'::text;
  END IF;
  -- Helper: un factor <= 0 de la unidad de la línea se rechaza.
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity';
  IF position('v_unit.factor <= 0' IN v_src) = 0 THEN
    v_bad := v_bad || '_uom_normalize_quantity: no rechaza un factor <= 0 de la unidad de la línea'::text;
  END IF;

  -- Tercera revisión: (a) en los seis caminos la cantidad se normaliza
  -- DESPUÉS de tomar la fila del producto FOR UPDATE (TOCTOU contra un cambio
  -- de unidad base abierto).
  FOREACH v_fn IN ARRAY ARRAY[
    '_c29_confirm_order_core', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
    'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation',
    'rpc_create_sale_operation'
  ] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    v_pos1 := strpos(v_src, COALESCE(substring(v_src FROM 'FROM\s+public\.products\s+WHERE\s+id\s*=\s*v_item\.product_id\s+FOR UPDATE'), E'\x01'));
    v_pos2 := strpos(v_src, '_uom_normalize_quantity(v_item.product_id');
    IF v_pos1 = 0 OR v_pos2 = 0 OR v_pos2 < v_pos1 THEN
      v_bad := v_bad || format('%s: normaliza la cantidad antes de tomar el producto FOR UPDATE', v_fn);
    END IF;
  END LOOP;
  -- (b) D-F′: ninguna columna de precio de línea redondea el precio unitario.
  FOR v_res, v_scale IN
    SELECT c.table_name::text || '.' || c.column_name::text, c.numeric_scale
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND (c.table_name::text, c.column_name::text) IN (('sales_order_items', 'price'), ('quote_items', 'price'),
                                                        ('sales', 'amount'), ('sale_items', 'price'),
                                                        ('purchases', 'amount'), ('purchase_items', 'price'))
  LOOP
    IF v_scale IS NOT NULL THEN
      v_bad := v_bad || format('%s: numeric con escala %s (D-F′: el precio por unidad de la línea no se redondea)', v_res, v_scale);
    END IF;
  END LOOP;
  -- (c) la alerta de margen costea la cantidad en unidad base.
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'check_low_margin';
  IF v_src IS NULL OR position('public._uom_quantity_for_reporting(' IN v_src) = 0 THEN
    v_bad := v_bad || 'check_low_margin: no costea la cantidad en unidad base'::text;
  END IF;
  -- (d) el guard de unidad base observa también parent_id (re-parent).
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_attribute a ON a.attrelid = t.tgrelid AND a.attname = 'parent_id'
    WHERE t.tgrelid = 'public.products'::regclass AND t.tgname = 'trg_product_base_unit_guard'
      AND a.attnum = ANY (t.tgattr::int2[])
  ) THEN
    v_bad := v_bad || 'trg_product_base_unit_guard: no observa parent_id'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'GATE ventas-unidades-conversion (embebido) FAILED: %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE ventas-unidades-conversion (embebido): PASS';
END $$;
