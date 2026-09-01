-- =============================================================================
-- qa-integral-modulos — arreglos SQL del QA integral 2026-08-30
-- (G4 task 4.2, G8 task 8.2, G16 tasks 16.2/16.3 con OQ-3)
--
-- ⚠️ REGLA DE INTEGRIDAD DE FUNCIÓN: los cuatro CREATE OR REPLACE de este archivo
-- parten del pg_get_functiondef VIVO de prod, capturado el 2026-08-31 en
-- openspec/changes/qa-integral-modulos/baseline/*.live.sql (md5 verificado
-- byte a byte contra prod, ver baseline/BASELINE.md):
--   · rpc_branch_report(uuid,date,date)        md5 fd21f8864b9878d7cb271ff210ee6953
--   · rpc_product_profitability(integer)       md5 eb25445906c068f6025600517012bf38
--   · rpc_create_expense(text,numeric,date,text,uuid,uuid,uuid,uuid,uuid)
--                                              md5 b58ac4d270aa0d62c479da92e5290b21
--   · rpc_delete_expense(uuid)                 md5 819bd69422dfec39dceea76148a7634c
-- La ÚNICA diferencia admisible por función es el fix puntual documentado en
-- su sección. NUNCA partir del archivo de migración anterior: el cuerpo vivo
-- de rpc_product_profitability YA divergió de su archivo ('P0403' vivo vs
-- 'P403' en 20260814000001 L153, reescritura in-place del G3 de
-- 20261003000001) — ese 'P0403' se conserva tal cual.
--
-- Sin DROP (resetea ACLs y el RETURNS TABLE exigiría recrear firma): CREATE OR
-- REPLACE conservando firma y tipo de retorno, ACLs reafirmadas igual (defensa
-- en profundidad, lección advisor 0028). Sin ERRCODEs nuevos; sin P0001.
-- Re-appliable por construcción: CREATE OR REPLACE + UPDATEs acotados por
-- description IS NULL. Va como ÚLTIMO eslabón de la cadena de reapply de
-- KPI_Validation.yml.
-- =============================================================================


-- =============================================================================
-- 1. rpc_branch_report — fix 42702 (H4): "column reference branch_id is
--    ambiguous". El RETURNS TABLE declara la variable plpgsql branch_id y el
--    CTE all_branch_ids referenciaba la columna homónima SIN calificar
--    (arrastrado verbatim desde 20260607000000:304). La función NUNCA ejecutó
--    correctamente desde su creación (C-06, 2026-06-07).
--    FIX PUNTUAL (única diferencia con el baseline): calificar branch_id en
--    las dos ramas del CTE all_branch_ids. Probado en local: con eso solo, la
--    función planifica y ejecuta (el ORDER BY total_sales resuelve al alias de
--    salida sin conflicto).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_branch_report(p_account_id uuid, p_start date, p_end date)
 RETURNS TABLE(branch_id uuid, branch_name text, total_sales numeric, total_expenses numeric, operation_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Verify caller belongs to this account
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
    branch_sales AS (
      SELECT
        s.branch_id,
        -- RN-D — revenue de línea consistente: COALESCE(total, amount).
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0) AS total_sales,
        -- RN-D — conteo de operaciones unificado: COALESCE(operation_id, id)
        -- para que las ventas legacy sin operation_id cuenten 1 c/u.
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT AS op_count
      FROM public.sales s
      WHERE s.account_id = p_account_id
        -- RN-D5: borde superior inclusivo hasta fin de día local.
        AND s.date >= p_start::timestamptz
        AND s.date <  (p_end + 1)::timestamptz
      GROUP BY s.branch_id
    ),
    branch_expenses AS (
      SELECT
        e.branch_id,
        COALESCE(SUM(e.amount), 0) AS total_expenses
      FROM public.expenses e
      WHERE e.account_id = p_account_id
        AND e.date >= p_start::timestamptz
        AND e.date <  (p_end + 1)::timestamptz
      GROUP BY e.branch_id
    ),
    all_branch_ids AS (
      -- qa-integral-modulos (G4): calificado — sin el prefijo, branch_id
      -- colisiona con el parámetro OUT homónimo del RETURNS TABLE (42702).
      SELECT DISTINCT branch_sales.branch_id FROM branch_sales
      UNION
      SELECT DISTINCT branch_expenses.branch_id FROM branch_expenses
    )
  SELECT
    abi.branch_id,
    COALESCE(b.name, 'Sin sucursal')       AS branch_name,
    COALESCE(bs.total_sales, 0)            AS total_sales,
    COALESCE(be.total_expenses, 0)         AS total_expenses,
    COALESCE(bs.op_count, 0)              AS operation_count
  FROM all_branch_ids abi
  LEFT JOIN public.branches b  ON b.id = abi.branch_id
  LEFT JOIN branch_sales   bs  ON bs.branch_id IS NOT DISTINCT FROM abi.branch_id
  LEFT JOIN branch_expenses be ON be.branch_id IS NOT DISTINCT FROM abi.branch_id
  ORDER BY total_sales DESC NULLS LAST;
END;
$function$;

-- ACLs reafirmadas = estado vigente en prod (postgres/authenticated/service_role,
-- sin PUBLIC, sin anon — 20260824000001 revocó anon). CREATE OR REPLACE las
-- preserva; se reafirman igual por si un futuro DROP+CREATE las resetea.
REVOKE ALL     ON FUNCTION public.rpc_branch_report(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_branch_report(uuid, date, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_branch_report(uuid, date, date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_branch_report(uuid, date, date) TO service_role;


-- =============================================================================
-- 2. rpc_product_profitability — fix 42804 (G8): el RETURNS TABLE declara
--    last_sale_date date pero el SELECT devolvía MAX(s.date) (timestamptz) →
--    "structure of query does not match function result type" en TODA
--    ejecución. FIX PUNTUAL (única diferencia con el baseline): cast
--    consciente de zona (MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')::date
--    — el mismo patrón que public.reporting_local_today() canoniza y que el
--    propio cuerpo ya usa para v_since_date (RN-D5). Un ::date desnudo
--    castearía con la TimeZone de sesión (UTC en Supabase) y una venta de
--    21:00–23:59 ART quedaría fechada el día siguiente (off-by-one que el
--    barrido 20260907000001 ya eliminó). Firma y tipo de retorno intactos.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_product_profitability(p_period_days integer DEFAULT 30)
 RETURNS TABLE(product_id uuid, product_name text, total_revenue numeric, total_cost numeric, gross_margin numeric, gross_margin_pct numeric, units_sold numeric, last_sale_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        UUID;
  v_account_id UUID;
  v_since_date DATE;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Derive the caller's active account (C-05 D7 pattern)
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- v3-reporting-invariants (RN-D5): ancla a la fecha LOCAL del tenant, no a
  -- CURRENT_DATE (UTC del servidor) — evita que la ventana corra un día
  -- antes entre las 21:00 y las 00:00 hora Argentina.
  v_since_date := public.reporting_local_today() - (p_period_days || ' days')::INTERVAL;

  -- v3-snapshot-pattern (D6, RN-D2): el costo por línea deriva del snapshot
  -- congelado en sale_items (unit_cost_snapshot), no del maestro actual.
  -- Cascada de fallback: (1) unit_cost_snapshot de la línea; (2) products.cost
  -- actual solo cuando el snapshot es NULL (líneas muy viejas no backfilleadas).
  -- CTEs avoid Cartesian product when aggregating two fact tables on the same key
  RETURN QUERY
  WITH
    sales_agg AS (
      SELECT
        s.product_id,
        -- v3-reporting-invariants (RN-D — revenue de línea consistente):
        -- COALESCE(total, amount), nunca amount solo (precio unitario).
        SUM(COALESCE(s.total, s.amount))                           AS total_revenue,
        SUM(s.quantity)                                            AS units_sold,
        -- qa-integral-modulos (G8): cast consciente de zona — el RETURNS TABLE
        -- declara date y s.date es timestamptz (42804 sin el cast).
        (MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')::date AS last_sale_date,
        SUM(COALESCE(si.unit_cost_snapshot, pr2.cost) * s.quantity) AS total_cost_snapshot,
        bool_or(si.unit_cost_snapshot IS NULL)                     AS any_missing_snapshot
      FROM   public.sales s
      JOIN   public.products pr2 ON pr2.id = s.product_id
      LEFT   JOIN public.sale_items si
             ON si.sale_id = s.id AND si.product_id = s.product_id
      WHERE  s.account_id   = v_account_id
        AND  s.product_id  IS NOT NULL
        AND  s.date        >= v_since_date
      GROUP  BY s.product_id
    )
  SELECT
    sa.product_id,
    pr.name                                                                   AS product_name,
    sa.total_revenue,
    sa.total_cost_snapshot                                                    AS total_cost,
    sa.total_revenue - sa.total_cost_snapshot                                 AS gross_margin,
    ROUND(
      (sa.total_revenue - sa.total_cost_snapshot)
      / NULLIF(sa.total_revenue, 0) * 100,
      2
    )                                                                         AS gross_margin_pct,
    sa.units_sold,
    sa.last_sale_date
  FROM   sales_agg         sa
  JOIN   public.products   pr ON pr.id          = sa.product_id
  ORDER  BY gross_margin_pct DESC NULLS LAST
  LIMIT  200;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_product_profitability(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_product_profitability(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(integer) TO service_role;


-- =============================================================================
-- 3. Backfill OQ-3 (H11 / G16 task 16.3) — motivo de los movimientos de caja
--    y banco generados por gastos desde el 2026-08-30 (gastos-forma-pago):
--    rpc_create_expense los escribía con description NULL. IDEMPOTENTE por
--    construcción: acotado por referencia al gasto vivo y description IS NULL
--    — la segunda pasada no matchea ninguna fila. Los movimientos cuyo gasto
--    ya fue borrado (rpc_delete_expense hace DELETE físico) no tienen fila en
--    expenses para joinear y quedan como están, por diseño: no hay fuente de
--    verdad de la que copiar el motivo. Medido en prod el 2026-08-31: 4 filas
--    de caja y 0 de banco con motivo NULL.
-- =============================================================================
UPDATE public.cash_movements cm
SET    description = e.description
FROM   public.expenses e
WHERE  e.id = cm.reference_id
  AND  cm.movement_type IN ('expense', 'expense_reversal')
  AND  cm.description IS NULL
  AND  e.description IS NOT NULL;

UPDATE public.bank_movements bm
SET    description = e.description
FROM   public.expenses e
WHERE  e.id = bm.source_doc_ref
  AND  bm.source_doc_type = 'expense'
  AND  bm.description IS NULL
  AND  e.description IS NOT NULL;


-- =============================================================================
-- 5. rpc_create_expense — motivo del gasto en los libros (H11 / G16 task 16.2).
--    El cuerpo vivo llamaba a c28_register_cash_movement con 4 args (omitia el
--    5o p_description, DEFAULT NULL) y a _pay_register_operation_bank_movement
--    con NULL literal en la ultima posicion (p_description): plata que se movia
--    sin explicacion en /caja y /banco. FIX PUNTUAL (unica diferencia con
--    baseline/rpc_create_expense.live.sql, md5 b58ac4d270aa0d62c479da92e5290b21):
--    pasar p_description en ambas llamadas. Firma y tipo de retorno intactos.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_expense(p_category text, p_amount numeric, p_date date, p_description text DEFAULT NULL::text, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_expense_id          uuid;
  v_branch              RECORD;
  v_gate_branch         uuid;
  v_kind                text;
  v_cash_movement_id    uuid;
  v_bank_movement_id    uuid;
  v_cash_session_status text;
  v_cash_session_branch uuid;
BEGIN
  -- ── (a) Autenticación, tenant desde la SESIÓN y rol de escritura ──────────
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede registrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── IMPORTE POSITIVO — la precondición de la que depende TODO lo de abajo ─
  -- COPIADO VERBATIM de los dos baselines de los que este RPC toma sus otros
  -- predicados (rpc_create_sale_operation_v2 L154 y rpc_create_purchase_
  -- operation L239: 'Amount must be greater than zero', P0400). La primera
  -- versión de este archivo se trajo el bloque de opt-in de caja y la llamada
  -- bancaria y dejó afuera esta línea, y sin ella:
  --   · la pata de caja registra `-p_amount`, o sea que con p_amount = -5000
  --     escribe un movimiento 'expense' de +5000 — un "gasto" que SUMA plata
  --     al cajón que después se arquea y se firma;
  --   · el guard de signo del borrado (sección 4, `v_cash_amount < 0`) queda
  --     FALSO sobre ese movimiento positivo, así que el DELETE procede SIN
  --     registrar el expense_reversal y la plata fantasma queda sin ningún
  --     documento que la respalde ni forma de rastrearla (el gasto ya no
  --     existe). Es el modo de falla exacto de delete-guard-ledgers —204
  --     operaciones backfilleadas— reintroducido por el change que dice
  --     cerrarlo;
  --   · la pata bancaria produce un 'transfer_out' que AUMENTA el saldo y se
  --     va a la conciliación contra el extracto real.
  -- Se rechaza en el SERVIDOR aunque la UI ya lo limite, por la misma doctrina
  -- que D3: la API no puede ser un bypass del formulario. Gate: sección 8.
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Derivación del kind desde el catálogo ─────────────────────────────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2: el kind se
  -- DERIVA del catálogo, nunca se acepta como texto del cliente, y el mismo
  -- predicado (id + account_id + is_active + deleted_at) cubre de una vez la
  -- forma de pago ajena, la inactiva y la borrada.
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

  -- ── D3: credit NO aplica a un gasto ───────────────────────────────────────
  -- expenses no tiene contraparte (ni supplier_id ni client_id): no hay cuenta
  -- corriente que cargar. Se rechaza en el servidor además de ocultarse en la
  -- UI, para que la API no sea un bypass del selector.
  IF v_kind = 'credit' THEN
    RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Sucursal: mismo predicado y mismo COALESCE que la venta (C-26 / D6) ───
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

  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  -- ── Centro de costo: mismo predicado que la edición de compra ─────────────
  -- (rpc_atomic_update_purchase_operation). El INSERT plano que este RPC
  -- reemplaza aceptaba cualquier cost_center_id, incluido el de otra cuenta:
  -- la FK no está scopeada por tenant.
  IF p_cost_center_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.cost_centers
      WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'cost_center_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ── D5: la cuenta bancaria deja de fallar en silencio EN EL GASTO ─────────
  -- BLOQUEANTE DE PRODUCTO MEDIDO: payment_methods con bank_account_id
  -- configurado = 0 de 37 cuentas. Con la cuenta sin resolver,
  -- _pay_register_operation_bank_movement retorna NULL SIN ERROR — o sea que,
  -- tal cual está, el pedido literal del PO ("que estos movimientos concilien
  -- banco") fallaría en silencio para el 100% de los tenants.
  --
  -- El guard vive ACÁ, en el caller, y NO en el helper: la spec bank-movement
  -- tiene un escenario explícito —"sin cuenta resuelta la venta sigue
  -- funcionando igual que antes"— y el helper es punto de paso de venta,
  -- compra y POS. El endurecimiento asimétrico es deliberado: el gasto NACE
  -- con este contrato, las ventas no.
  --
  -- CONDICIONADO a que la organización tenga al menos una cuenta bancaria
  -- activa: un guard incondicional dejaría a 33 de 37 tenants sin poder
  -- registrar un gasto por transferencia hasta que carguen una cuenta — un
  -- bloqueo de registro por un problema de configuración, el mismo error que
  -- D1 evita en caja.
  --
  -- La resolución se hace con el MISMO helper que usará después
  -- _pay_register_operation_bank_movement (override → default → NULL), así que
  -- no hay una segunda definición de "qué cuenta corresponde"; y si la cuenta
  -- informada es ajena, inactiva o borrada, el propio helper ya levanta P0412
  -- desde acá.
  IF v_kind IN ('transfer', 'card', 'check', 'wallet')
     AND public._pay_resolve_bank_account(v_account_id, p_payment_method_id, p_bank_account_id) IS NULL
     AND EXISTS (
       SELECT 1 FROM public.bank_accounts
       WHERE account_id = v_account_id AND is_active = TRUE AND deleted_at IS NULL
     )
  THEN
    RAISE EXCEPTION 'bank_account_required_for_expense: elegí la cuenta bancaria de la que sale el dinero — sin ella el gasto no aparecería nunca en la conciliación bancaria'
      USING ERRCODE = 'P0412';
  END IF;

  -- ── (b) El gasto ──────────────────────────────────────────────────────────
  -- D6: branch_id se persiste RESUELTO (COALESCE con la default), no crudo:
  -- el escenario de spec exige que un gasto sin sucursal informada quede con
  -- la sucursal por defecto de la cuenta. RN-93 estaba incumplida al 100%
  -- para gastos (0 de 175).
  INSERT INTO public.expenses
    (user_id, account_id, category, amount, description, date,
     branch_id, cost_center_id, payment_method_id)
  VALUES
    (v_uid, v_account_id, p_category, p_amount, p_description, p_date,
     v_gate_branch, p_cost_center_id, p_payment_method_id)
  RETURNING id INTO v_expense_id;

  -- ── (c) PATA DE CAJA — opt-in explícito con las tres condiciones ──────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2 (bloque
  -- "pagos-cableados-restantes OQ-C/D4"), con las dos ÚNICAS adaptaciones que
  -- D1 autoriza:
  --   (a) p_date se declara `date` y se compara DIRECTO contra
  --       reporting_local_today(). ⚠️ PROHIBIDO `p_date timestamptz` con
  --       `p_date::date`: ese cast se resuelve en el TimeZone de la SESIÓN
  --       (UTC en este servidor) mientras reporting_local_today() es
  --       (now() AT TIME ZONE 'America/Argentina/Mendoza')::date, así que un
  --       gasto legítimo de hoy cargado entre las 21:00 y las 23:59 ART
  --       (= 00:00-02:59 UTC del día siguiente) se rechazaría con P0422 justo
  --       en la franja en que el microemprendedor cierra el día. Con `date` el
  --       resultado es invariante por construcción — y lo que ya viaja por el
  --       payload es una fecha pura (ExpenseCreate.date: datetime.date).
  --   (b) c28_register_cash_movement(sesión, -p_amount, 'expense', id_del_gasto):
  --       signo NEGATIVO (egreso) y el gasto como referencia.
  --
  -- La ausencia de p_cash_session_id es NO-OP: bloquear el alta porque no hay
  -- caja abierta convertiría un problema de arqueo en un problema de registro
  -- (D1). El helper aporta gratis P0409 (sesión abierta), P0401 (tenencia,
  -- agregada por tenancy-guard-caja-outbox — el gasto es exactamente el
  -- "caller futuro" que ese guard fue escrito para cubrir), P0422 (sucursal
  -- activa), balance_after serializado y created_by.
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
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva del gasto'
        USING ERRCODE = 'P0422';
    END IF;

    IF p_date <> public.reporting_local_today() THEN
      RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja un gasto fechado hoy (%)', public.reporting_local_today()
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      -- qa-integral-modulos (G16/H11): 5o argumento p_description — el motivo
      -- del gasto viaja al historial de caja (antes se omitia y quedaba NULL).
      p_cash_session_id, -p_amount, 'expense', v_expense_id, p_description
    );
  END IF;

  -- ── PATA BANCARIA — llamada INCONDICIONAL al helper compartido ────────────
  -- CALCADA de la de rpc_create_purchase_operation (baseline), que ya despacha
  -- un EGRESO con este mismo helper. Sin ningún IF previo: el helper decide.
  -- Aporta gratis el predicado kind IN ('transfer','card','check','wallet'),
  -- la resolución override→default→NULL, la validación de la cuenta (P0412),
  -- el rechazo de cuenta bancaria sobre kind no bancario (P0400), el mapa
  -- kind→movement_type (card→card_settlement, resto out→transfer_out), el
  -- signo y el guard de período conciliado (P0424), que revierte la operación
  -- ENTERA si la fecha cae dentro de una reconciliation_sessions cerrada.
  --
  -- p_value_date = p_date, que ya es `date` (D1) y por lo tanto no arrastra
  -- ningún cast dependiente de la zona de la sesión. Va SÍ O SÍ: con NULL el
  -- movimiento caería en created_at y la sugerencia automática de conciliación
  -- (monto exacto, ventana ±3 días) se desalinearía del extracto.
  --
  -- p_branch_id = v_gate_branch: la sucursal EFECTIVA, la misma que se
  -- persistió en el gasto.
  v_bank_movement_id := public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    p_amount, 'out', 'expense', v_expense_id,
    -- qa-integral-modulos (G16/H11): p_description reemplaza el NULL literal —
    -- el motivo del gasto viaja al historial bancario.
    p_date, v_gate_branch, p_description
  );

  RETURN jsonb_build_object(
    'expense_id',       v_expense_id,
    'branch_id',        v_gate_branch,
    'payment_method_kind', v_kind,
    'cash_movement_id', v_cash_movement_id,
    'bank_movement_id', v_bank_movement_id
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) TO service_role;


-- =============================================================================
-- 6. rpc_delete_expense — las reversas del borrado llevan el mismo motivo
--    (H11 / G16 task 16.2, "misma descripcion en las reversas"). La reversa de
--    caja (expense_reversal) nacia con description NULL (4 args) y el espejo
--    bancario decia solo el marcador generico. FIX PUNTUAL (unica diferencia
--    con baseline/rpc_delete_expense.live.sql, md5 819bd69422dfec39dceea76148a7634c,
--    capturado de prod el 2026-08-31): la reversa de caja pasa
--    v_expense.description como 5o argumento y el espejo bancario le anexa el
--    motivo CONSERVANDO el marcador 'Reversión por borrado de gasto' que el
--    gate test_gastos_forma_pago (5.5/5.7) exige. Firma intacta.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_delete_expense(p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_expense          RECORD;
  v_cashbox_id       uuid;
  v_cash_amount      numeric(12,2);
  v_open_session_id  uuid;
  v_cash_reversal_id uuid;
  v_bank_row         RECORD;
  v_reversed_type    text;
  v_bank_reversals   integer := 0;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede borrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  -- Copiado del baseline de rpc_delete_sale_operation (20261005000001:1205-1234)
  -- CON UNA INVERSIÓN OBLIGATORIA Y EXPLÍCITA DEL GUARD DE SIGNO.
  --
  -- ⚠️⚠️ El original es `IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0`,
  -- porque los movimientos agrupados de una VENTA son de tipo 'sale' con
  -- importe POSITIVO. Los del GASTO son de tipo 'expense' con importe
  -- NEGATIVO (lo fija este mismo change: expense negativo, expense_reversal
  -- positivo). Copiado verbatim, `v_cash_amount > 0` es FALSO PARA TODO GASTO:
  -- se saltearía el bloque entero, no se registraría el expense_reversal,
  -- NUNCA se lanzaría P0426 y el DELETE procedería igual — se reintroduciría
  -- exactamente el borrado inseguro que motivó delete-guard-ledgers, desde el
  -- change que dice cerrarlo. Y sin levantar un solo error.
  --
  -- Por eso el guard correcto NO es el positivo del original, y por eso el
  -- gate tiene un CONTROL NEGATIVO obligatorio (5.4b): un test que sólo
  -- assertara "no hubo error" quedaría verde por omisión.
  --
  -- ⚠️ Y por eso tampoco es `v_cash_amount < 0`: esa forma sigue dependiendo
  -- de una invariante que vive en OTRA función (que el alta nunca acepte un
  -- importe no positivo). El guard es `<> 0`: **existe movimiento de caja del
  -- gasto ⇒ SIEMPRE se compensa**, cualquiera sea el signo. Con `< 0`, un solo
  -- movimiento 'expense' positivo —el que producía el alta antes del guard de
  -- P0400, o cualquier camino futuro— hacía que el DELETE procediera sin
  -- compensar y SIN levantar un error. El SELECT de abajo ya filtra
  -- `movement_type = 'expense'`, así que las reversas no se autocompensan.
  -- Gate: sección 8.5, que inyecta a mano el estado corrupto.
  --
  -- La sesión ORIGINAL nunca se toca: el ledger de caja es append-only. El
  -- contra-movimiento va SIEMPRE a la sesión abierta actual de la MISMA caja,
  -- con el mismo criterio que ya rige para el borrado de una venta en efectivo.
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = p_expense_id AND movement_type = 'expense'
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
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar este gasto'
        USING ERRCODE = 'P0426';
    END IF;

    -- El movimiento del gasto es NEGATIVO (lo garantiza el guard de importe
    -- positivo del alta), así que -v_cash_amount da el INGRESO positivo que
    -- repone la plata en el cajón. Si por cualquier camino el movimiento
    -- fuera positivo, la contra-partida sale negativa y compensa igual: la
    -- reversa es siempre el opuesto exacto de lo que se posteó.
    v_cash_reversal_id := public.c28_register_cash_movement(
      -- qa-integral-modulos (G16/H11): la reversa lleva el motivo del gasto
      -- borrado (mismo criterio que el alta y que el backfill de la seccion 3).
      v_open_session_id, -v_cash_amount, 'expense_reversal', p_expense_id,
      v_expense.description
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled ───────────
  -- Loop calcado del de rpc_delete_sale_operation. Se usa _register_bank_movement
  -- (el escritor crudo) y NO _pay_register_operation_bank_movement: la reversa
  -- no tiene que volver a resolver la cuenta ni volver a evaluar el guard de
  -- período conciliado — va contra la MISMA cuenta del movimiento original.
  -- Es el único uso autorizado del escritor crudo en este change (D2).
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'expense' AND source_doc_ref = p_expense_id
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'expense', p_expense_id, CURRENT_DATE, v_bank_row.branch_id,
      -- qa-integral-modulos (G16/H11): el espejo nombra al gasto borrado.
      -- El marcador 'Reversión por borrado de gasto' se CONSERVA: el gate
      -- test_gastos_forma_pago (5.5/5.7) lo exige como ancla del contrato.
      'Reversión por borrado de gasto' || COALESCE(': ' || v_expense.description, '')
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  -- ── El borrado, DESPUÉS de las dos compensaciones ────────────────────────
  DELETE FROM public.expenses WHERE id = p_expense_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'deleted',           true,
    'cash_reversal_id',  v_cash_reversal_id,
    'bank_reversals',    v_bank_reversals
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_delete_expense(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_delete_expense(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_delete_expense(uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_delete_expense(uuid) TO service_role;


-- =============================================================================
-- 7. Gate ANTI-OVERLOAD (molde de 20260928000001 §9 / 20261015000001 §5): las
--    dos funciones se reescriben con CREATE OR REPLACE sobre su firma vigente
--    — si un cambio futuro alterara la lista de argumentos sin DROP, quedaría
--    un overload fantasma y la próxima llamada posicional reventaría con 42725.
-- =============================================================================
DO $$
DECLARE
  v_proname text;
  v_count   integer;
BEGIN
  FOREACH v_proname IN ARRAY ARRAY[
    'rpc_branch_report',
    'rpc_product_profitability',
    'rpc_create_expense',
    'rpc_delete_expense'
  ] LOOP
    SELECT COUNT(*) INTO v_count
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE ANTI-OVERLOAD FAILED: % tiene % definiciones en public (esperaba exactamente 1) — quedó un overload fantasma y la próxima llamada posicional revienta con 42725.',
        v_proname, v_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'GATE ANTI-OVERLOAD PASSED: las 4 funciones reescritas tienen exactamente 1 definición cada una.';
END $$;
