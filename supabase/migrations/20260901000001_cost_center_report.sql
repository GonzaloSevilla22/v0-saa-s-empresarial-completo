-- =============================================================================
-- MIGRATION: 20260901000001_cost_center_report.sql
-- CHANGE:    cost-center-surface
-- Design ref: openspec/changes/cost-center-surface/design.md
--
-- QUÉ AGREGA
--   Read-model rpc_cost_center_report(p_account_id, p_start, p_end): costos
--   (gastos + compras) agregados por centro de costo en un rango, con los no
--   imputados (cost_center_id IS NULL) como fila propia "Sin centro de costo".
--
--   Espejo estructural de rpc_branch_report (20260814000001 §4): SECURITY
--   DEFINER, search_path fijo, verificación de membership contra
--   account_members con ERRCODE P0401, y los mismos invariantes RN-D.
--
-- POR QUÉ LEE DOCUMENTOS OPERATIVOS Y NO journal_lines (design Decisión 1)
--   El consumer del journal despacha 5 event types (SaleConfirmed,
--   PurchaseCreated, PaymentReceived, PaymentMade, CreditNoteIssued) y NO
--   existe evento de gasto → un reporte sobre el diario omitiría todos los
--   gastos. Además el asiento es async por outbox (estuvo muerto 22-jun→01-jul).
--
-- INVARIANTES RN-D HORNEADOS (reporting-invariants, 20260814000001)
--   · Costo de línea en compras: SUM(COALESCE(p.total, p.amount)) — nunca
--     amount solo (amount es precio UNITARIO en filas modernas; ese bug
--     subvaluó el revenue de prod 17,53%).
--   · Conteo de operaciones: compras COUNT(DISTINCT COALESCE(operation_id,
--     id)); gastos 1 por fila (no tienen operation_id).
--   · RN-D5 bordes: date >= p_start AND date < (p_end + 1) — el día final
--     entra completo, no se corta en medianoche UTC.
--   · RN-D4: todo importe de salida es NUMERIC.
--
-- FUERA DE ALCANCE
--   Ventas (el centro de costo no se imputa a ingresos: journal_lines de venta
--   lo escribe NULL adrede). Sin DDL de tablas, sin backfill, sin índices
--   nuevos (mismo perfil de acceso que rpc_branch_report: account_id + rango).
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE
--   La integración GitHub de Supabase auto-aplica migraciones al mergear ANTES
--   del `db push` de Actions → esta migración es 100% re-ejecutable:
--   CREATE OR REPLACE + REVOKE/GRANT, sin DDL de tablas. Los gates de
--   comportamiento degradan con NOTICE si el contexto no los permite.
--
-- APPLY: vía CI al mergear a main (Actions: build + deploy + db push).
--        NUNCA con el MCP `apply_migration` (desincroniza el historial).
-- ROLLBACK: DROP FUNCTION IF EXISTS public.rpc_cost_center_report(uuid, date, date);
--        Ninguna pantalla preexistente depende de esta función.
-- =============================================================================


-- =============================================================================
-- 1. rpc_cost_center_report
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_cost_center_report(
    p_account_id uuid,
    p_start      date,
    p_end        date
)
RETURNS TABLE(
    cost_center_id   uuid,
    cost_center_name text,
    cost_center_code text,
    is_active        boolean,
    total_expenses   numeric,
    total_purchases  numeric,
    total_cost       numeric,
    operation_count  bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Verify caller belongs to this account (espejo de rpc_branch_report).
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
    cc_expenses AS (
      SELECT
        e.cost_center_id                  AS cc_id,
        COALESCE(SUM(e.amount), 0)        AS exp_total,
        -- RN-D: expenses no tiene operation_id → se cuenta por fila.
        COUNT(*)::BIGINT                  AS exp_rows
      FROM public.expenses e
      WHERE e.account_id = p_account_id
        -- RN-D5: borde superior inclusivo hasta fin de día local.
        AND e.date >= p_start::timestamptz
        AND e.date <  (p_end + 1)::timestamptz
      GROUP BY e.cost_center_id
    ),
    cc_purchases AS (
      SELECT
        p.cost_center_id                                          AS cc_id,
        -- RN-D: costo de línea consistente COALESCE(p.total, p.amount).
        COALESCE(SUM(COALESCE(p.total, p.amount)), 0)             AS pur_total,
        -- RN-D: conteo de operaciones unificado COALESCE(operation_id, id).
        COUNT(DISTINCT COALESCE(p.operation_id, p.id))::BIGINT    AS pur_ops
      FROM public.purchases p
      WHERE p.account_id = p_account_id
        AND p.date >= p_start::timestamptz
        AND p.date <  (p_end + 1)::timestamptz
      GROUP BY p.cost_center_id
    ),
    all_cc_ids AS (
      -- UNION (no UNION ALL) dedupe incluyendo la clave NULL: los costos sin
      -- imputar colapsan en una sola fila "Sin centro de costo".
      SELECT cc_id FROM cc_expenses
      UNION
      SELECT cc_id FROM cc_purchases
    )
  SELECT
    aci.cc_id                                                       AS cost_center_id,
    COALESCE(cc.name, 'Sin centro de costo')                        AS cost_center_name,
    cc.code                                                         AS cost_center_code,
    -- Los centros desactivados siguen apareciendo con su nombre histórico;
    -- la bandera deja que la UI los distinga sin una consulta extra.
    COALESCE(cc.is_active, true)                                    AS is_active,
    COALESCE(ce.exp_total, 0)                                       AS total_expenses,
    COALESCE(cp.pur_total, 0)                                       AS total_purchases,
    (COALESCE(ce.exp_total, 0) + COALESCE(cp.pur_total, 0))         AS total_cost,
    (COALESCE(ce.exp_rows, 0) + COALESCE(cp.pur_ops, 0))::BIGINT    AS operation_count
  FROM all_cc_ids aci
  LEFT JOIN public.cost_centers cc ON cc.id     = aci.cc_id
  LEFT JOIN cc_expenses         ce ON ce.cc_id  IS NOT DISTINCT FROM aci.cc_id
  LEFT JOIN cc_purchases        cp ON cp.cc_id  IS NOT DISTINCT FROM aci.cc_id
  -- ORDER BY por expresión y no por el nombre de la columna OUT: evita la
  -- ambigüedad columna-vs-variable de plpgsql en RETURN QUERY.
  ORDER BY (COALESCE(ce.exp_total, 0) + COALESCE(cp.pur_total, 0)) DESC;
END;
$function$;

COMMENT ON FUNCTION public.rpc_cost_center_report(uuid, date, date) IS
    'cost-center-surface: costos (gastos + compras) agregados por centro de costo '
    'en un rango. Incluye la fila NULL "Sin centro de costo" para lo no imputado, '
    'de modo que la suma de las filas iguale el costo del período. Invariantes '
    'RN-D: COALESCE(total, amount) en compras, COUNT(DISTINCT COALESCE(operation_id, id)), '
    'borde superior < p_end + 1 día, dinero NUMERIC. Las ventas no participan: '
    'el centro de costo es dimensión de costos, no de ingresos.';


-- =============================================================================
-- 2. ACLs — exigido por el gate scripts/ci/test_function_acl_gate.sql
--    (revocar anon explícitamente; REVOKE FROM PUBLIC no alcanza).
--    Conserva authenticated: la pantalla la invoca vía supabase.rpc con el JWT
--    del usuario, igual que rpc_branch_report.
-- =============================================================================
REVOKE ALL     ON FUNCTION public.rpc_cost_center_report(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_cost_center_report(uuid, date, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_cost_center_report(uuid, date, date) TO authenticated;


-- =============================================================================
-- 3. Gate de introspección (corre SIEMPRE, también en prod)
--    Verifica que el cuerpo PUBLICADO contenga los predicados clave. Barato y
--    no depende de datos: si alguien "arregla" el RPC perdiendo un invariante
--    RN-D, el PR se cae acá.
-- =============================================================================
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'rpc_cost_center_report';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_cost_center_report no existe tras la migración.';
  END IF;

  IF position('COALESCE(p.total, p.amount)' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_cost_center_report no suma el costo de línea con COALESCE(p.total, p.amount) (RN-D).';
  END IF;

  IF position('COUNT(DISTINCT COALESCE(p.operation_id, p.id))' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_cost_center_report no usa COUNT(DISTINCT COALESCE(operation_id, id)) para contar operaciones (RN-D).';
  END IF;

  IF position('(p_end + 1)::timestamptz' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_cost_center_report no usa el borde superior inclusivo < p_end + 1 día (RN-D5).';
  END IF;

  IF position('Sin centro de costo' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_cost_center_report no etiqueta la fila de costos no imputados (cost_center_id IS NULL).';
  END IF;

  IF position('public.sales' in v_def) > 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_cost_center_report referencia public.sales — el centro de costo es dimensión de costos, no de ingresos.';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: rpc_cost_center_report contiene los predicados RN-D y la fila de no imputados.';
END $$;


-- =============================================================================
-- 4. Gate de comportamiento auto-limpiante (solo DB vacía/CI, NOTICE-degrade
--    en prod). Anchor sintético vía handle_new_user (siembra account + branch
--    "Casa Central" + cashbox desde 20260812000001). Cleanup hijo→padre
--    completo — accounts=0 al final.
--
--    A diferencia del gate de 20260814000001, este INVOCA EL RPC DE VERDAD:
--    se setea request.jwt.claims local para que auth.uid() resuelva al usuario
--    anchor y la verificación de membership pase. Si el contexto no lo permite
--    (auth.uid() no lo toma), degrada con NOTICE en vez de abortar.
-- =============================================================================
DO $$
DECLARE
  v_anchor_email  text := 'cost-center-surface-gate@test.local';
  v_user_id       uuid := gen_random_uuid();
  v_account_id    uuid;
  v_branch_id     uuid;
  v_product_id    uuid;
  v_cc_marketing  uuid;
  v_cc_inactivo   uuid;
  v_op_id         uuid := gen_random_uuid();
  v_start         date := (CURRENT_DATE - 10);
  v_end           date := CURRENT_DATE;
  v_row           record;
  v_total_cost    numeric;
  v_unauthorized  boolean := false;
BEGIN
  -- ── Anchor sintético ────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Cost Center Surface', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE COST-CENTER-SURFACE: no se pudo resolver una account para el anchor sintético (contexto no permite el gate, p.ej. prod con RLS activa) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id
  FROM   public.branches
  WHERE  account_id = v_account_id
  ORDER  BY created_at
  LIMIT  1;

  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user_id, v_account_id, '__gate_ccs_product__', 1000, 400)
  RETURNING id INTO v_product_id;

  INSERT INTO public.cost_centers (account_id, name, code)
  VALUES (v_account_id, '__gate_ccs_marketing__', 'MKT')
  RETURNING id INTO v_cc_marketing;

  INSERT INTO public.cost_centers (account_id, name, code, is_active)
  VALUES (v_account_id, '__gate_ccs_inactivo__', 'INA', false)
  RETURNING id INTO v_cc_inactivo;

  -- ── Datos de prueba ──────────────────────────────────────────────────────
  -- (a) Compra multilínea imputada a Marketing: 3 líneas del MISMO operation_id
  --     con totales 1000 + 2000 + 3000 = 6000 → 1 sola operación.
  INSERT INTO public.purchases
    (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id, cost_center_id)
  VALUES
    (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 1, 1000, now(), v_op_id, v_cc_marketing),
    (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 2, 2000, now(), v_op_id, v_cc_marketing),
    (v_user_id, v_account_id, v_branch_id, v_product_id, 1500, 2, 3000, now(), v_op_id, v_cc_marketing);

  -- (b) Gasto imputado a Marketing → total_cost del centro = 5000 + 6000.
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, description, amount, date, cost_center_id)
  VALUES (v_user_id, v_account_id, v_branch_id, 'Marketing', '__gate_ccs_expense__', 5000, now(), v_cc_marketing);

  -- (c) Gasto SIN imputar → debe aparecer bajo "Sin centro de costo".
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, description, amount, date, cost_center_id)
  VALUES (v_user_id, v_account_id, v_branch_id, 'Otros', '__gate_ccs_expense_null__', 700, now(), NULL);

  -- (d) Gasto imputado al centro DESACTIVADO → debe seguir siendo legible.
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, description, amount, date, cost_center_id)
  VALUES (v_user_id, v_account_id, v_branch_id, 'Otros', '__gate_ccs_expense_inactivo__', 800, now(), v_cc_inactivo);

  -- (e) Gasto con hora real en el último día del rango (borde RN-D5).
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, description, amount, date, cost_center_id)
  VALUES (v_user_id, v_account_id, v_branch_id, 'Otros', '__gate_ccs_expense_borde__', 100,
          (v_end::timestamptz + interval '15 hours'), v_cc_marketing);

  -- ── Assert de autorización: sin sesión, el RPC rechaza ───────────────────
  BEGIN
    PERFORM * FROM public.rpc_cost_center_report(v_account_id, v_start, v_end);
  EXCEPTION
    WHEN sqlstate 'P0401' THEN
      v_unauthorized := true;
  END;

  IF NOT v_unauthorized THEN
    RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (auth): el RPC debería rechazar con P0401 cuando auth.uid() no es miembro de la cuenta.';
  END IF;

  -- ── Sesión sintética para invocar el RPC de verdad ───────────────────────
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text,
                     true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE COST-CENTER-SURFACE: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts de agregación (el gate de introspección y el de autorización ya corrieron).';
  ELSE
    -- (1) Marketing: compras 6000 (3 líneas, 1 operación) + gastos 5000 + 100
    --     del borde = 5100 → total_cost 11100, operation_count = 1 op + 2 filas.
    SELECT * INTO v_row
    FROM   public.rpc_cost_center_report(v_account_id, v_start, v_end) r
    WHERE  r.cost_center_id = v_cc_marketing;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (1): el centro de prueba no aparece en el reporte.';
    END IF;

    IF v_row.total_purchases <> 6000 THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (1a): compra multilínea esperaba total_purchases 6000 (COALESCE(total, amount)), dio %.', v_row.total_purchases;
    END IF;

    IF v_row.total_expenses <> 5100 THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (1b): gastos esperaban 5100 (5000 + 100 del borde de fin de día), dio % — revisar RN-D5.', v_row.total_expenses;
    END IF;

    IF v_row.total_cost <> 11100 THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (1c): total_cost esperaba 11100, dio %.', v_row.total_cost;
    END IF;

    IF v_row.operation_count <> 3 THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (1d): operation_count esperaba 3 (1 operación de compra multilínea + 2 gastos), dio % — revisar COUNT(DISTINCT COALESCE(operation_id, id)).', v_row.operation_count;
    END IF;

    -- (2) Fila de no imputados: el gasto de 700 con cost_center_id NULL.
    SELECT * INTO v_row
    FROM   public.rpc_cost_center_report(v_account_id, v_start, v_end) r
    WHERE  r.cost_center_id IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (2a): los costos sin imputar deben aparecer como fila propia, no excluirse.';
    END IF;

    IF v_row.cost_center_name <> 'Sin centro de costo' OR v_row.total_cost <> 700 THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (2b): la fila de no imputados esperaba "Sin centro de costo" con 700, dio "%" con %.', v_row.cost_center_name, v_row.total_cost;
    END IF;

    -- (3) Centro desactivado: sigue legible con su nombre histórico.
    SELECT * INTO v_row
    FROM   public.rpc_cost_center_report(v_account_id, v_start, v_end) r
    WHERE  r.cost_center_id = v_cc_inactivo;

    IF NOT FOUND OR v_row.total_cost <> 800 OR v_row.is_active <> false THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (3): un centro desactivado con costos en el rango debe aparecer con su nombre histórico y is_active=false.';
    END IF;

    -- (4) La suma de las filas iguala el costo del período (11100 + 700 + 800).
    SELECT COALESCE(SUM(r.total_cost), 0) INTO v_total_cost
    FROM   public.rpc_cost_center_report(v_account_id, v_start, v_end) r;

    IF v_total_cost <> 12600 THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (4): la suma de las filas esperaba 12600 (costo total del período), dio % — la imputación parcial no debe subvaluar el reporte.', v_total_cost;
    END IF;

    -- (5) Las ventas no participan: una venta en el rango no mueve el total.
    INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
    VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 2, 2000, now());

    SELECT COALESCE(SUM(r.total_cost), 0) INTO v_total_cost
    FROM   public.rpc_cost_center_report(v_account_id, v_start, v_end) r;

    IF v_total_cost <> 12600 THEN
      RAISE EXCEPTION 'GATE COST-CENTER-SURFACE FAILED (5): una venta en el rango no debe alterar el reporte de costos, el total pasó a %.', v_total_cost;
    END IF;

    RAISE NOTICE 'GATE COST-CENTER-SURFACE PASSED: costo de línea y conteo de operaciones (1), fila de no imputados (2), centro desactivado legible (3), el total cierra contra el período (4), las ventas no participan (5).';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ── Limpieza hijo→padre por anchor (accounts=0 al final) ─────────────────
  --    Espejo de 20260814000001 §7: cashboxes cuelga de branch_id (no de
  --    account_id) y accounts se borra por owner_user_id.
  DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account_id);
  DELETE FROM public.stock_movements               WHERE account_id = v_account_id;
  DELETE FROM public.sales                         WHERE account_id = v_account_id;
  DELETE FROM public.purchases                     WHERE account_id = v_account_id;
  DELETE FROM public.expenses                      WHERE account_id = v_account_id;
  DELETE FROM public.products                      WHERE account_id = v_account_id;
  DELETE FROM public.cost_centers                  WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.branches                      WHERE account_id = v_account_id;
  DELETE FROM public.account_members               WHERE user_id = v_user_id;
  DELETE FROM public.accounts                      WHERE owner_user_id = v_user_id;
  DELETE FROM public.profiles                      WHERE id = v_user_id;
  DELETE FROM public.email_logs                    WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency         WHERE user_id = v_user_id;
  DELETE FROM auth.users                           WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    -- Cleanup best-effort; el fallo se propaga siempre (mismo criterio que
    -- 20260814000001: un gate que no puede correr por un motivo inesperado no
    -- se silencia — las degradaciones legítimas ya salieron por RETURN/NOTICE).
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account_id);
        DELETE FROM public.stock_movements               WHERE account_id = v_account_id;
        DELETE FROM public.sales                         WHERE account_id = v_account_id;
        DELETE FROM public.purchases                     WHERE account_id = v_account_id;
        DELETE FROM public.expenses                      WHERE account_id = v_account_id;
        DELETE FROM public.products                      WHERE account_id = v_account_id;
        DELETE FROM public.cost_centers                  WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.branches                      WHERE account_id = v_account_id;
        DELETE FROM public.account_members               WHERE user_id = v_user_id;
        DELETE FROM public.accounts                      WHERE owner_user_id = v_user_id;
      END IF;
      DELETE FROM public.profiles              WHERE id = v_user_id;
      DELETE FROM public.email_logs            WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
      DELETE FROM auth.users                   WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
