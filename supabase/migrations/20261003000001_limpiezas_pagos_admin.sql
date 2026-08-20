-- =============================================================================
-- MIGRATION: 20261003000001_limpiezas_pagos_admin.sql
-- SCOPE: change `limpiezas-pagos-admin` — tres limpiezas técnicas de la saga
--        de pagos (#415-#428), sin funcionalidad nueva:
--
--   G3 — 5 funciones VIGENTES lanzan RAISE ... USING ERRCODE con códigos de
--        4 caracteres (P400/P403/P404/P409/P422). Postgres los rechaza en
--        runtime (42704 unrecognized exception condition), el mensaje
--        original se pierde y backend/core/errors.py degrada el error a un
--        500 genérico. Se corrige a la convención P04xx (5 chars) y se
--        agrega un gate PERMANENTE de CI — la corrección de 2026-06-24
--        (20260624000001) se perdió porque nada la sostenía.
--
--   G2 — 4 RPCs get_admin_* (activation_rate, umv_rate, paid_conversion_rate,
--        insights_breakdown, firma (timestamptz,timestamptz)) quedaron sin
--        ningún consumidor tras deudas-menores-agosto G5. Verificado en prod
--        (pg_proc/prosrc de toda la base + grep de todo el árbol de código):
--        cero callers. Se dropean. get_admin_community_interactions NO se
--        toca — la invocan rpc_admin_business_kpis y rpc_admin_kpi_overview.
--
--   G1 — BREAKING: se dropea sales_orders.payment_method (TEXT). Quedó desde
--        pagos-cableados-restantes (#421) como columna DERIVADA del kind del
--        catálogo — segunda fuente de verdad viva que ya produjo un JOIN
--        latente con fan-out (D3 de design.md). La forma de pago de una
--        orden se lee EXCLUSIVAMENTE por payment_method_id -> payment_
--        methods.kind desde acá en adelante. El payload del evento
--        SaleConfirmed NO cambia (sigue transportando 'payment_method' =
--        kind efectivo, ya derivado desde payment_method_id desde #421);
--        _journal_post_from_event NO se toca. El parámetro p_payment_method
--        text de rpc_quick_sale/rpc_confirm_sales_order/
--        _c29_confirm_order_core SE CONSERVA (contrato POS + guard
--        payment_method_mismatch) — este change retira la COLUMNA, no el
--        parámetro.
--
--   SEED (OQ-1) — 'Cheque' (kind=check) se agrega como 7º método sembrado:
--        el vocabulario del CHECK lo admite desde 20260928000001 pero
--        ninguna de las 35 cuentas de prod lo tiene sembrado. Sin esto, la
--        resolución legacy de G1 (ver abajo) nunca imputa una venta con
--        cheque. Riesgo cero: nace is_active=true como los otros 6, el
--        usuario puede desactivarlo desde el manager de Configuración.
--
-- ORDEN OBLIGATORIO (ver design.md "Migration Plan"): G3 -> G2 -> G1a
--   (INSERTs dejan de escribir el texto) -> SEED -> G1b (confirm_order_core,
--   resuelve el camino legacy) -> G1c (DROP COLUMN, al final, cuando ya nada
--   la escribe).
--
-- BASELINE: pg_get_functiondef() de las funciones tocadas capturado de la
--   base VIGENTE (replica local verificada byte-a-byte idéntica a prod
--   gxdhpxvdjjkmxhdkkwyb al mismo MAX(version)=20261002000001) en
--   openspec/changes/limpiezas-pagos-admin/baseline/*.sql (8 funciones del
--   propose original + rpc_quick_sale y handle_new_user, capturadas ad-hoc
--   al aplicar — ver nota del hallazgo del gate 4.1 en la sección G1a) —
--   cada CREATE OR
--   REPLACE de abajo parte de ese baseline con el diff mínimo documentado.
--
-- GOVERNANCE: MEDIUM — G1 toca el hot path del POS (_c29_confirm_order_core).
--   G2 y G3 son LOW.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- ROLLBACK: G3/G2 irreversibles en la práctica (nadie quiere volver a
--   códigos rotos ni resucitar RPCs muertas). G1 se revierte con
--   ALTER TABLE sales_orders ADD COLUMN payment_method text NOT NULL
--   DEFAULT 'other' + el CHECK + UPDATE ... SET payment_method = pm.kind
--   FROM payment_methods pm WHERE pm.id = so.payment_method_id (reconstruye
--   el 100% del valor desde payment_method_id).
-- =============================================================================


-- ═══════════════════════════════════════════════════════════════════════════
-- G3 — ERRCODEs de 4 caracteres -> 5 (convención P04xx)
-- ═══════════════════════════════════════════════════════════════════════════
-- Reutiliza literalmente el mecanismo de 20260624000001_fix_invalid_
-- errcodes_5char.sql (D4 de design.md): pg_get_functiondef() como fuente de
-- verdad + regexp_replace + CREATE OR REPLACE. CREATE OR REPLACE preserva
-- ACLs/owner/SECURITY DEFINER/search_path — no hay DROP, no hay re-GRANT que
-- reponer. Idempotente: en la segunda corrida el WHERE no matchea nada.
DO $$
DECLARE
  r            RECORD;
  v_def        text;
  v_count      integer := 0;
  v_residue    integer;
  v_rewritten  text[] := '{}';
  v_expected   CONSTANT text[] := ARRAY[
    'rpc_create_purchase_operation',
    'rpc_dashboard_kpi_summary',
    'rpc_dashboard_channel_margin',
    'rpc_issue_credit_note',
    'rpc_product_profitability'
  ];
  v_rewritten_sorted text[];
  v_unexpected       text[];
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'community')
      AND p.prosrc ~ 'ERRCODE\s*=\s*''P(400|403|404|409|422)'''
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_def := regexp_replace(
      v_def,
      '(ERRCODE\s*=\s*'')P(400|403|404|409|422)('')',
      '\1P0\2\3',
      'g'
    );
    EXECUTE v_def;
    v_count := v_count + 1;
    v_rewritten := array_append(v_rewritten, r.proname);
    RAISE NOTICE 'limpiezas-pagos-admin G3: ERRCODE fix aplicado a %', r.proname;
  END LOOP;

  RAISE NOTICE 'limpiezas-pagos-admin G3: funciones reescritas: %', v_count;

  -- Salvaguarda (task 2.4): todo lo reescrito SHALL pertenecer al conjunto
  -- esperado — si aparece una función FUERA de esa lista (un RAISE de 4
  -- chars nuevo colado por otra migración concurrente), abortar en vez de
  -- aplicarlo a ciegas. SUBCONJUNTO, no igualdad exacta: en el paso de
  -- reconvergencia de KPI_Validation.yml (reaplicar migraciones viejas que
  -- redefinen alguna de estas 5 funciones con su cuerpo pre-G3, y luego
  -- reaplicar ESTA migración al final) es legítimo que solo 1-4 de las 5
  -- necesiten reescribirse en esa segunda pasada — exigir el conjunto
  -- COMPLETO ahí abortaría una reconvergencia válida.
  IF v_count > 0 THEN
    SELECT array_agg(x ORDER BY x) INTO v_rewritten_sorted FROM unnest(v_rewritten) x;

    SELECT array_agg(x ORDER BY x) INTO v_unexpected
    FROM unnest(v_rewritten) x
    WHERE x <> ALL (v_expected);

    IF v_unexpected IS NOT NULL THEN
      RAISE EXCEPTION 'limpiezas-pagos-admin G3 INESPERADO: se reescribieron funciones fuera de la lista esperada (%): reescritas=%, esperadas=%.',
        v_unexpected, v_rewritten_sorted, v_expected;
    END IF;
  END IF;

  -- Gate de residuo cero: no debe quedar ningún código inválido de 4 chars.
  SELECT count(*) INTO v_residue
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('public', 'community')
    AND p.prosrc ~ 'ERRCODE\s*=\s*''P(400|403|404|409|422)''';

  IF v_residue <> 0 THEN
    RAISE EXCEPTION 'limpiezas-pagos-admin G3 INCOMPLETO: % funciones aún contienen ERRCODE de 4 caracteres', v_residue;
  END IF;
END $$;


-- ═══════════════════════════════════════════════════════════════════════════
-- G2 — Baja de las 4 RPCs get_admin_* huérfanas
-- ═══════════════════════════════════════════════════════════════════════════
-- Verificado en prod (pg_proc de toda la base) y en el árbol de código: cero
-- callers. Firma explícita (timestamptz, timestamptz) — nunca por nombre
-- pelado, para no dropear un overload distinto por error. Sin GRANT que
-- reponer: nunca tuvieron EXECUTE para anon (test_function_acl_gate.sql no
-- requiere edición).
DROP FUNCTION IF EXISTS public.get_admin_activation_rate(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.get_admin_umv_rate(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.get_admin_paid_conversion_rate(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.get_admin_insights_breakdown(timestamptz, timestamptz);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_admin_community_interactions'
      AND pg_get_function_identity_arguments(p.oid) LIKE '%timestamp with time zone%'
  ) THEN
    RAISE EXCEPTION 'limpiezas-pagos-admin G2 ABORTADO: get_admin_community_interactions desapareció — esa RPC NO debía tocarse (la invocan rpc_admin_business_kpis y rpc_admin_kpi_overview).';
  END IF;

  RAISE NOTICE 'limpiezas-pagos-admin G2: 4 RPCs admin huérfanas dropeadas; get_admin_community_interactions sigue viva.';
END $$;




-- ═══════════════════════════════════════════════════════════════════════════
-- G1a — Los sitios de escritura dejan de escribir el texto
-- ═══════════════════════════════════════════════════════════════════════════
-- rpc_accept_quote y rpc_promote_legacy_sale_to_order: dejan de escribir el
-- literal 'other' (D7 de design.md) — el draft/la promoción nace sin forma
-- de pago imputada (payment_method_id NULL), en vez de una etiqueta que el
-- usuario nunca eligió. Misma firma -> CREATE OR REPLACE, sin DROP, sin
-- re-GRANT.
--
-- HALLAZGO del gate estático 4.1 (test_sales_order_payment_method_drop.sql,
-- RED antes de este fix): el inventario de design.md listaba 3 sitios de
-- escritura, pero rpc_quick_sale (el entrypoint del POS) también insertaba
-- el texto crudo p_payment_method al crear el draft — un 4º sitio no
-- inventariado. Sin este fix, el DROP COLUMN de G1c habría roto toda venta
-- del POS en el acto. Se agrega acá con el mismo criterio D7: el draft nace
-- sin columna de texto; _c29_confirm_order_core (llamado en la misma
-- transacción, líneas más abajo en la propia función) resuelve/valida
-- payment_method_id de verdad.

CREATE OR REPLACE FUNCTION public.rpc_accept_quote(p_quote_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_quote          public.quotes%ROWTYPE;
  v_item           RECORD;
  v_sales_order_id uuid;
  v_branch_id      uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cargar el quote y validar tenencia
  SELECT * INTO v_quote
  FROM public.quotes
  WHERE id = p_quote_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_quote.account_id;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado: solo draft o sent son aceptables
  IF v_quote.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'quote_invalid_state: estado % no es aceptable', v_quote.status
      USING ERRCODE = 'P0409';
  END IF;

  -- OQ-4: validación defensiva on-read de expiración.
  -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE (UTC del
  -- servidor) — evita marcar "vencido" un quote válido hasta hoy(ART) cuando
  -- se lo lee entre las 21:00 y las 23:59:59 ART.
  IF v_quote.valid_until IS NOT NULL AND v_quote.valid_until < public.reporting_local_today() THEN
    RAISE EXCEPTION 'quote_expired: valid_until % ya pasó', v_quote.valid_until
      USING ERRCODE = 'P0409';
  END IF;

  -- Resolver branch: preferir branch del quote, sino default
  v_branch_id := COALESCE(
    v_quote.branch_id,
    public.c26_default_branch(v_account_id)
  );

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Crear la SalesOrder en estado draft (sin tocar stock aún)
  -- limpiezas-pagos-admin (D7): ya no escribe el literal 'other' en la
  -- columna de texto (retirada) — un draft nace sin forma de pago imputada
  -- (payment_method_id NULL); se decide recién en el confirm.
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, source_quote_id, status,
     total, created_by)
  VALUES
    (v_account_id, v_branch_id, v_quote.client_id, p_quote_id, 'draft',
     v_quote.total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

  -- v3-snapshot-pattern (D1): copiar quote_items → sales_order_items
  -- propagando los snapshots ya congelados, SIN re-leer products.
  FOR v_item IN
    SELECT * FROM public.quote_items WHERE quote_id = p_quote_id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
       name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal,
       v_item.name_snapshot, v_item.sku_snapshot, v_item.unit_cost_snapshot,
       v_item.iva_rate_snapshot, v_item.snapshot_backfilled);
  END LOOP;

  -- v3-document-status-history (RN-A1): transición del quote en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'quote', p_quote_id, v_quote.status, 'accepted', v_uid, NULL);

  -- Transicionar el quote a accepted
  UPDATE public.quotes
  SET status = 'accepted'
  WHERE id = p_quote_id;

  -- v3-notifications-realtime (5.3): productor de QuoteAccepted al outbox.
  -- seller_id = quote.created_by (proxy — no hay columna seller_id dedicada
  -- hoy; deuda conocida documentada, igual criterio que D3).
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'QuoteAccepted', 'Quote', p_quote_id,
    jsonb_build_object(
      'quote_id',  p_quote_id,
      'seller_id', v_quote.created_by,
      'branch_id', v_branch_id,
      'total',     v_quote.total
    ),
    now()
  );

  RETURN jsonb_build_object(
    'sales_order_id', v_sales_order_id,
    'quote_id',       p_quote_id,
    'status',         'accepted'
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_promote_legacy_sale_to_order(p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_client_id      uuid;
  v_total          numeric(15,2) := 0;
  v_sales_order_id uuid;
  v_existing_id    uuid;
  v_item           RECORD;
BEGIN
  -- ── Autenticación ───────────────────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Tenencia: existe la operación legacy y pertenece al usuario ─────────────
  -- Tomamos account_id, branch_id y client_id de la primera fila de la operación.
  -- MIN() para evitar ambigüedad si hay varias filas (operaciones multi-ítem).
  SELECT
    MIN(s.account_id),
    MIN(s.branch_id),
    MIN(s.client_id)
  INTO v_account_id, v_branch_id, v_client_id
  FROM public.sales s
  JOIN public.account_members am
    ON am.account_id = s.account_id
   AND am.user_id    = v_uid
  WHERE s.operation_id = p_operation_id;

  IF v_account_id IS NULL THEN
    -- La operación no existe o pertenece a otro usuario/cuenta
    RAISE EXCEPTION 'operation_not_found: operación % no encontrada o ajena', p_operation_id
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Permiso de escritura ────────────────────────────────────────────────────
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: sin permiso de escritura sobre la cuenta'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── Idempotencia: short-circuit si la SalesOrder ya existe (D2) ─────────────
  SELECT id INTO v_existing_id
  FROM public.sales_orders
  WHERE sale_operation_id = p_operation_id;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END IF;

  -- ── Resolver branch efectiva (D4) ────────────────────────────────────────────
  -- Preferir branch de la venta legacy; sino, default de la cuenta (C-26).
  v_branch_id := COALESCE(v_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- ── Reconstruir ítems desde sale_items con fallback al header plano (D3) ─────
  -- Calculamos total = Σ subtotales.
  -- Líneas de servicio (product_id NULL) se incluyen sin error.
  SELECT COALESCE(SUM(COALESCE(si.subtotal, s.total)), 0)
  INTO v_total
  FROM public.sales s
  LEFT JOIN public.sale_items si ON si.sale_id = s.id
  WHERE s.operation_id = p_operation_id
    AND s.account_id   = v_account_id;

  -- ── INSERT sales_orders (status='confirmed', side-effect-free) ──────────────
  -- Carrera de concurrencia (D2): si otra promoción de la MISMA operación ganó
  -- entre el short-circuit de arriba y este INSERT, el índice único parcial dispara
  -- unique_violation. La capturamos y devolvemos la orden existente como replay,
  -- haciendo honor a la idempotencia que el diseño promete (en vez de un 500).
  BEGIN
    -- limpiezas-pagos-admin (D7): la promoción de una venta legacy no
    -- inventa una forma de pago (era 'other' literal) — nace genuinamente
    -- sin imputar (payment_method_id NULL), que es lo que la spec de
    -- sales-order ya exige ("la promoción no inventa una forma de pago").
    INSERT INTO public.sales_orders
      (account_id, branch_id, client_id, status,
       sale_operation_id, total, fiscal_document_id, created_by)
    VALUES
      (v_account_id, v_branch_id, v_client_id, 'confirmed',
       p_operation_id, v_total, NULL, v_uid)
    RETURNING id INTO v_sales_order_id;
  EXCEPTION WHEN unique_violation THEN
    -- La transacción concurrente ya commiteó su sales_orders → es visible.
    SELECT id INTO v_existing_id
    FROM public.sales_orders
    WHERE sale_operation_id = p_operation_id;

    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END;

  -- ── INSERT sales_order_items (D3: sale_items con fallback header plano) ──────
  FOR v_item IN
    SELECT
      COALESCE(si.product_id, s.product_id)   AS product_id,
      s.unit_id                                AS unit_id,
      COALESCE(si.quantity,   s.quantity)      AS quantity,
      COALESCE(si.price,      s.amount)        AS price,
      COALESCE(si.subtotal,   s.total)         AS subtotal
    FROM public.sales s
    LEFT JOIN public.sale_items si ON si.sale_id = s.id
    WHERE s.operation_id = p_operation_id
      AND s.account_id   = v_account_id
    ORDER BY s.id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal);
  END LOOP;

  -- D1 verificación: NO se toca branch_stock, NO se inserta cash_movement,
  -- NO se inserta SaleConfirmed en events, NO se llama _c29_confirm_order_core.

  RETURN jsonb_build_object(
    'sales_order_id',    v_sales_order_id,
    'sale_operation_id', p_operation_id,
    'replayed',          false
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_quick_sale(p_idempotency_key text, p_client_id uuid DEFAULT NULL::uuid, p_items jsonb DEFAULT '[]'::jsonb, p_payment_method text DEFAULT 'other'::text, p_cash_session_id uuid DEFAULT NULL::uuid, p_comprobante_type text DEFAULT NULL::text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_sales_order_id uuid;
  v_item           RECORD;
  v_total          numeric(15,2) := 0;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar items
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch
  v_branch_id := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular total inicial
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'quantity debe ser > 0' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.price IS NULL OR v_item.price < 0 THEN
      RAISE EXCEPTION 'price debe ser >= 0' USING ERRCODE = 'P0400';
    END IF;
    v_total := v_total + COALESCE(v_item.subtotal, v_item.price * v_item.quantity);
  END LOOP;

  -- Crear SalesOrder en draft
  -- limpiezas-pagos-admin (D7 extendido, hallazgo del gate 4.1): ya no
  -- escribe el texto crudo p_payment_method en la columna retirada — el
  -- draft nace sin imputar (payment_method_id NULL); _c29_confirm_order_core
  -- (abajo, misma transacción) resuelve/valida la imputación real.
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, status, total, created_by)
  VALUES
    (v_account_id, v_branch_id, p_client_id, 'draft', v_total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

  -- Crear sales_order_items
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price,
       COALESCE(v_item.subtotal, v_item.price * v_item.quantity));
  END LOOP;

  -- Confirmar inline (hot path transaccional). pos-catalogo-pagos: pasa
  -- p_payment_method_id — la RPC interna resuelve y valida el kind (D2).
  -- pos-banco-movimientos: pasa p_bank_account_id — passthrough (D6).
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    v_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal,
    p_payment_method_id,
    p_bank_account_id
  );
END;
$function$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SEED — 'Cheque' (kind=check), 7º método de pago (OQ-1)
-- ═══════════════════════════════════════════════════════════════════════════
-- El vocabulario payment_methods_kind_check admite 'check' desde
-- 20260928000001, pero el seed original (esa migración + handle_new_user)
-- solo trae 6 de los 7 kind — ninguna de las 35 cuentas de prod tiene un
-- método kind='check'. Sin esto, la resolución legacy D2 de G1b (más abajo)
-- para ese kind nunca imputa nada. Se agrega como 7º método, sort_order=7
-- (al final, no reordena los 6 existentes), mismo patrón WHERE NOT
-- EXISTS(kind) idempotente que 20260928000001. Riesgo cero: nace
-- is_active=true igual que los otros 6; el usuario puede desactivarlo desde
-- el manager de Configuración si no lo usa.

INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
SELECT a.id, 'Cheque', 'check', 7
FROM public.accounts a
WHERE NOT EXISTS (
  SELECT 1 FROM public.payment_methods pm
  WHERE pm.account_id = a.id
    AND pm.kind        = 'check'
    AND pm.deleted_at IS NULL
);

-- handle_new_user: mismo seed para cuentas nuevas (7 métodos en vez de 6).
-- Sub-bloque degrade-don't-fail preservado sin cambios (patrón
-- v3-provisioning-seed) — solo se agrega la fila 'Cheque' al VALUES.
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

  -- 6) metodos-pago-operaciones (D11 Parte B) + limpiezas-pagos-admin (OQ-1):
  --    catálogo de 7 formas de pago (6 originales + Cheque). Mismo criterio
  --    degrade-don't-fail que el sub-bloque de arriba — aislado, propia
  --    EXCEPTION, jamás aborta el signup.
  BEGIN
    -- limpiezas-pagos-admin (OQ-1): 'Cheque' (kind=check) se agrega como 7º
    -- método sembrado — el vocabulario del CHECK ya lo admitía desde
    -- 20260928000001 pero el seed original solo traía 6/7. sort_order=7
    -- (al final, no reordena los 6 existentes). Riesgo cero: el usuario
    -- puede desactivarlo desde el manager de Configuración si no lo usa.
    INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
    SELECT v_account_id, v.name, v.kind, v.sort_order
    FROM (VALUES
        ('Efectivo',               'cash',     1),
        ('Transferencia bancaria', 'transfer', 2),
        ('Tarjeta',                'card',     3),
        ('Billetera virtual',      'wallet',   4),
        ('Cuenta corriente',       'credit',   5),
        ('Otro',                   'other',    6),
        ('Cheque',                 'check',    7)
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


-- ═══════════════════════════════════════════════════════════════════════════
-- G1b — _c29_confirm_order_core: deja de escribir el texto + resuelve el
--        camino legacy (D2)
-- ═══════════════════════════════════════════════════════════════════════════
-- Único cambio de lógica de todo el change: (a) el UPDATE final ya no
-- persiste payment_method = v_kind (columna retirada); (b) en la rama ELSE
-- (sin payment_method_id explícito), se intenta resolver la forma de pago
-- viva y activa de la cuenta con ese kind (desempate sort_order, luego id) y
-- se imputa reasignando el parámetro p_payment_method_id — si no hay match,
-- la orden queda sin imputar, sin abortar. El resto de la función (guards,
-- stock, caja, cuenta corriente, bank_movements, fiscal, outbox, payload del
-- evento) es BYTE A BYTE igual al baseline capturado — misma firma, sin
-- DROP, sin re-GRANT.
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

      v_qty_norm := v_item.quantity;

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


-- Gate estático interno (task 4.4): confirma que la definición viva de
-- _c29_confirm_order_core sigue emitiendo la clave 'payment_method' en el
-- payload del evento — _journal_post_from_event no se toca y no debe
-- tocarse (D1).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = '_c29_confirm_order_core'
      AND p.prosrc LIKE '%''payment_method'',  v_kind%'
  ) THEN
    RAISE EXCEPTION 'limpiezas-pagos-admin G1b ABORTADO: _c29_confirm_order_core dejó de emitir la clave payment_method en el payload de SaleConfirmed.';
  END IF;
END $$;


-- ═══════════════════════════════════════════════════════════════════════════
-- G1c — DROP de sales_orders.payment_method (al final, cuando ya nada la
--        escribe)
-- ═══════════════════════════════════════════════════════════════════════════
-- El CHECK sales_orders_payment_method_check cae automáticamente con la
-- columna. Se agrega un gate final que verifica que ni la columna ni el
-- CHECK existen.

ALTER TABLE public.sales_orders DROP COLUMN IF EXISTS payment_method;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'sales_orders' AND column_name = 'payment_method'
  ) THEN
    RAISE EXCEPTION 'limpiezas-pagos-admin G1c ABORTADO: sales_orders.payment_method sigue existiendo tras el DROP COLUMN.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'sales_orders_payment_method_check'
  ) THEN
    RAISE EXCEPTION 'limpiezas-pagos-admin G1c ABORTADO: sales_orders_payment_method_check sigue existiendo tras el DROP COLUMN.';
  END IF;

  RAISE NOTICE 'limpiezas-pagos-admin G1c: sales_orders.payment_method y su CHECK ya no existen.';
END $$;


-- ═══════════════════════════════════════════════════════════════════════════
-- GATES FINALES DE LA MIGRACIÓN
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_residue integer;
  v_missing text;
BEGIN
  -- 0 funciones con ERRCODE < 5 chars (residuo, doble check post-G1/G1b/G1c
  -- por si algún CREATE OR REPLACE de este mismo archivo reintrodujo algo).
  SELECT count(*) INTO v_residue
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('public', 'community')
    AND p.prosrc ~ 'ERRCODE\s*=\s*''P(400|403|404|409|422)''';

  IF v_residue <> 0 THEN
    RAISE EXCEPTION 'GATE FINAL FALLÓ: % funciones con ERRCODE de 4 caracteres tras la migración completa.', v_residue;
  END IF;

  -- 4 RPCs admin ausentes
  SELECT string_agg(fn, ', ') INTO v_missing
  FROM unnest(ARRAY[
    'get_admin_activation_rate', 'get_admin_umv_rate',
    'get_admin_paid_conversion_rate', 'get_admin_insights_breakdown'
  ]) fn
  WHERE EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = fn
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'GATE FINAL FALLÓ: RPCs admin que deberían estar dropeadas siguen existiendo: %', v_missing;
  END IF;

  -- community_interactions presente
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_admin_community_interactions'
  ) THEN
    RAISE EXCEPTION 'GATE FINAL FALLÓ: get_admin_community_interactions no existe (no debía tocarse).';
  END IF;

  RAISE NOTICE '=== limpiezas-pagos-admin: migración completa, todos los gates finales verdes ===';
END $$;

-- =============================================================================
-- VERIFICATION (post-push, solo SELECTs):
--   -- Columna y CHECK ausentes:
--   SELECT column_name FROM information_schema.columns
--     WHERE table_name='sales_orders' AND column_name='payment_method';  -- 0 filas
--   -- 4 RPCs admin ausentes + community_interactions presente:
--   SELECT proname FROM pg_proc WHERE proname LIKE 'get_admin_%';  -- solo community_interactions
--   -- ERRCODEs nuevos en las 5 funciones:
--   SELECT proname FROM pg_proc WHERE prosrc ~ 'ERRCODE\s*=\s*''P0(400|403|404|409|422)''';
--   -- Seed 35x7:
--   SELECT account_id, count(DISTINCT kind) FROM payment_methods
--     WHERE deleted_at IS NULL GROUP BY account_id HAVING count(DISTINCT kind) <> 7;  -- 0 filas
-- =============================================================================
