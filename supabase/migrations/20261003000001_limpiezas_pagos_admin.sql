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


