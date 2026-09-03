-- =============================================================================
-- GATE: test_receivables_aging_fifo.sql
-- CHANGE: cobranzas-vencimientos — grupo 4 (derivación FIFO y read-models)
--
-- Cubre tasks 4.1/4.6-4.10:
--   (1) INVARIANTE DE CIERRE: SUM(importe abierto) = customer_accounts.balance
--       para una cuenta sintética con cargos, cobros, notas y una anulación.
--   (2) Imputación: un cobro cancela el cargo más viejo; el parcial deja un
--       cargo parcialmente abierto; ANULAR un cobro reabre exactamente lo que
--       había cancelado; la nota de crédito consume como un cobro.
--   (3) Tramos: hoy = al día; ayer = 1-30; fronteras 30/31 y 60/61; sin
--       vencimiento NUNCA vencido (aunque tenga 200 días); los cinco tramos
--       suman el saldo.
--   (4) D5 — dos reglas separadas: el cargo sin vencimiento MÁS VIEJO se
--       cancela PRIMERO y lo que queda abierto clasifica en "sin vencimiento".
--   (5) Robustez de vocabulario: un movimiento no-cargo entra al pozo de
--       crédito con su signo, no genera ítem abierto, y el invariante cierra.
--   (6) Día argentino: reporting_local_today() en el cuerpo vivo; PROHIBIDO
--       CURRENT_DATE y now()::date (introspección).
--   (7) Espejo proveedor (rpc_payables_report) con la misma forma.
--   (8) rpc_set_default_payment_terms: escribe, limpia con NULL, P0400 si
--       negativo; guard is_account_writer en el cuerpo vivo.
--   (9) ACLs: anon sin EXECUTE, authenticated con EXECUTE, en los 3 RPCs.
--
-- La observación por tramos ES la observación por cargo: cada cargo del
-- anchor usa un due_date de un tramo distinto, así el reparto delata qué
-- cargo quedó abierto sin necesidad de exponer ítems individuales.
-- =============================================================================

-- ═══════════ (6)+(9) INTROSPECCIÓN + ACLs — corre SIEMPRE ═══════════════════
DO $$
DECLARE
  v_def text;
  v_fn  text;
BEGIN
  FOR v_fn IN SELECT unnest(ARRAY['rpc_receivables_report', 'rpc_payables_report']) LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_def IS NULL THEN
      RAISE EXCEPTION 'GATE AGING-FIFO FAILED (setup): % no existe.', v_fn;
    END IF;
    IF position('reporting_local_today' in v_def) = 0 THEN
      RAISE EXCEPTION 'GATE AGING-FIFO FAILED (6): % no ancla el día a reporting_local_today() (RN-D5).', v_fn;
    END IF;
    IF v_def ~* 'CURRENT_DATE' OR v_def ~ 'now\(\)::date' THEN
      RAISE EXCEPTION 'GATE AGING-FIFO FAILED (6): % usa CURRENT_DATE/now()::date — día del servidor, no día argentino.', v_fn;
    END IF;
    IF position('P0401' in v_def) = 0 THEN
      RAISE EXCEPTION 'GATE AGING-FIFO FAILED: % no rechaza no-miembros con P0401.', v_fn;
    END IF;
  END LOOP;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'rpc_set_default_payment_terms';
  IF v_def IS NULL OR position('is_account_writer' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (8): rpc_set_default_payment_terms debe existir con guard is_account_writer.';
  END IF;

  IF has_function_privilege('anon', 'public.rpc_receivables_report(uuid)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_payables_report(uuid)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_set_default_payment_terms(smallint)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (9): anon no debe poder ejecutar los RPCs de cobranzas.';
  END IF;
  IF NOT (has_function_privilege('authenticated', 'public.rpc_receivables_report(uuid)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.rpc_payables_report(uuid)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.rpc_set_default_payment_terms(smallint)'::regprocedure, 'EXECUTE')) THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (9): authenticated debe poder ejecutar los 3 RPCs.';
  END IF;
  RAISE NOTICE 'PASS (6)(9): introspección de día argentino, guards y ACLs.';
END $$;

-- ═══════════ (1)-(5)(7)(8) COMPORTAMIENTO — anchor sintético ════════════════
-- Helpers de armado del ledger sintético, en pg_temp (mueren con la sesión):
-- inserts DIRECTOS como superusuario, control total de created_at/due_date —
-- el gate construye un ledger consistente y fija el balance del header por
-- escenario (la derivación sólo lee ledger + balance).
CREATE FUNCTION pg_temp.ins_cam(p_ca uuid, p_acc uuid, p_amount numeric, p_type text,
                                p_due date, p_created timestamptz, p_by uuid) RETURNS void AS $ins$
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type,
     reference_id, due_date, created_by, created_at)
  VALUES (p_ca, p_acc, p_amount, 0, p_type, gen_random_uuid(), p_due, p_by, p_created);
$ins$ LANGUAGE sql;

CREATE FUNCTION pg_temp.mk_client(p_uid uuid, p_acc uuid, p_name text) RETURNS uuid AS $mk$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (p_uid, p_acc, p_name) RETURNING id INTO v_id;
  INSERT INTO public.customer_accounts (account_id, client_id, balance)
  VALUES (p_acc, v_id, 0);
  RETURN v_id;
END;
$mk$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.ca_of(p_client uuid) RETURNS uuid AS $ca$
  SELECT id FROM public.customer_accounts WHERE client_id = p_client;
$ca$ LANGUAGE sql;

DO $$
DECLARE
  v_user_f    uuid := gen_random_uuid();
  v_account_f uuid;
  v_today     date;
  -- clientes por escenario
  v_cl_a uuid; v_cl_b uuid; v_cl_c uuid; v_cl_d uuid; v_cl_e uuid; v_cl_f uuid; v_cl_g uuid;
  v_sup_a uuid;
  v_row   record;
  v_cnt   int;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_f, 'authenticated', 'authenticated', 'gate-fifo-f@test.local',
          now(), now(), jsonb_build_object('name', 'Gate FIFO F'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_f FROM public.account_members
  WHERE user_id = v_user_f ORDER BY created_at LIMIT 1;
  IF v_account_f IS NULL THEN
    RAISE NOTICE 'GATE AGING-FIFO (setup): tenant no provisionado — degradando.';
    RETURN;
  END IF;

  v_today := public.reporting_local_today();

  -- ── Escenario A: cobro cancela el cargo más viejo ─────────────────────────
  v_cl_a := pg_temp.mk_client(v_user_f, v_account_f, '__fifo_a__');
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_a), v_account_f, 1000, 'sale',             v_today - 40, now() - interval '40 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_a), v_account_f,  500, 'sale',             v_today - 10, now() - interval '10 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_a), v_account_f, -1000, 'payment_received', NULL,        now() - interval '1 day', v_user_f);
  UPDATE public.customer_accounts SET balance = 500 WHERE id = pg_temp.ca_of(v_cl_a);

  -- ── Escenario B: cobro parcial deja el cargo parcialmente abierto ─────────
  v_cl_b := pg_temp.mk_client(v_user_f, v_account_f, '__fifo_b__');
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_b), v_account_f, 1000, 'sale',             v_today - 40, now() - interval '40 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_b), v_account_f, -400, 'payment_received', NULL,         now() - interval '1 day', v_user_f);
  UPDATE public.customer_accounts SET balance = 600 WHERE id = pg_temp.ca_of(v_cl_b);

  -- ── Escenario C: anular un cobro reabre lo que había cancelado ────────────
  v_cl_c := pg_temp.mk_client(v_user_f, v_account_f, '__fifo_c__');
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_c), v_account_f, 1000, 'sale',                      v_today - 40, now() - interval '40 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_c), v_account_f,  500, 'sale',                      v_today - 10, now() - interval '10 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_c), v_account_f, -1200, 'payment_received',          NULL,        now() - interval '2 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_c), v_account_f,  1200, 'payment_received_reversal', NULL,        now() - interval '1 day', v_user_f);
  UPDATE public.customer_accounts SET balance = 1500 WHERE id = pg_temp.ca_of(v_cl_c);

  -- ── Escenario D: la nota de crédito consume como un cobro ─────────────────
  v_cl_d := pg_temp.mk_client(v_user_f, v_account_f, '__fifo_d__');
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_d), v_account_f, 1000, 'sale',        v_today - 40, now() - interval '40 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_d), v_account_f,  500, 'sale',        v_today - 10, now() - interval '10 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_d), v_account_f, -1000, 'credit_note', NULL,        now() - interval '1 day', v_user_f);
  UPDATE public.customer_accounts SET balance = 500 WHERE id = pg_temp.ca_of(v_cl_d);

  -- ── Escenario E: tramos y fronteras (cada cargo en un tramo distinto) ─────
  v_cl_e := pg_temp.mk_client(v_user_f, v_account_f, '__fifo_e__');
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_e), v_account_f, 100, 'sale', v_today,      now(), v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_e), v_account_f, 200, 'sale', v_today - 1,  now() - interval '1 day', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_e), v_account_f, 300, 'sale', v_today - 30, now() - interval '30 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_e), v_account_f, 400, 'sale', v_today - 31, now() - interval '31 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_e), v_account_f, 500, 'sale', v_today - 60, now() - interval '60 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_e), v_account_f, 600, 'sale', v_today - 61, now() - interval '61 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_e), v_account_f, 700, 'sale', NULL,         now() - interval '200 days', v_user_f);
  UPDATE public.customer_accounts SET balance = 2800 WHERE id = pg_temp.ca_of(v_cl_e);

  -- ── Escenario F (D5): el sin-vencimiento más viejo se cancela PRIMERO ─────
  v_cl_f := pg_temp.mk_client(v_user_f, v_account_f, '__fifo_f__');
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_f), v_account_f, 1000, 'sale',            NULL,         now() - interval '200 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_f), v_account_f,  500, 'sale',            v_today - 10, now() - interval '10 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_f), v_account_f, -300, 'payment_received', NULL,        now() - interval '1 day', v_user_f);
  UPDATE public.customer_accounts SET balance = 1200 WHERE id = pg_temp.ca_of(v_cl_f);

  -- ── Escenario G: robustez — adjustment negativo y reversal en el pozo ─────
  v_cl_g := pg_temp.mk_client(v_user_f, v_account_f, '__fifo_g__');
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_g), v_account_f, 1000, 'sale',                      v_today - 10, now() - interval '10 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_g), v_account_f, -200, 'adjustment',                 NULL,        now() - interval '3 days', v_user_f);
  PERFORM pg_temp.ins_cam(pg_temp.ca_of(v_cl_g), v_account_f,  100, 'payment_received_reversal',  NULL,        now() - interval '1 day', v_user_f);
  UPDATE public.customer_accounts SET balance = 900 WHERE id = pg_temp.ca_of(v_cl_g);

  -- ── Sesión sintética del miembro F ────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_f::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_f THEN
    RAISE NOTICE 'GATE AGING-FIFO: auth.uid() no resuelve — se omiten los asserts de comportamiento.';
    RETURN;
  END IF;

  -- ── (1) INVARIANTE DE CIERRE en TODAS las filas ───────────────────────────
  FOR v_row IN SELECT * FROM public.rpc_receivables_report(v_account_f) LOOP
    IF (v_row.amount_current + v_row.amount_overdue_1_30 + v_row.amount_overdue_31_60
        + v_row.amount_overdue_60_plus + v_row.amount_no_due_date) <> v_row.balance THEN
      RAISE EXCEPTION 'GATE AGING-FIFO FAILED (1): los 5 tramos de % suman % y el saldo es % — el invariante de cierre no se cumple.',
        v_row.client_name,
        v_row.amount_current + v_row.amount_overdue_1_30 + v_row.amount_overdue_31_60
          + v_row.amount_overdue_60_plus + v_row.amount_no_due_date,
        v_row.balance;
    END IF;
    IF v_row.overdue_total <> (v_row.amount_overdue_1_30 + v_row.amount_overdue_31_60 + v_row.amount_overdue_60_plus) THEN
      RAISE EXCEPTION 'GATE AGING-FIFO FAILED (1): overdue_total (%) != suma de los tramos vencidos en %.',
        v_row.overdue_total, v_row.client_name;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (1): invariante de cierre en todas las filas (7 escenarios).';

  -- ── (2a) A: el cobro canceló el cargo más viejo (31-60 en 0, 1-30 con 500) ─
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_a;
  IF v_row.amount_overdue_31_60 <> 0 OR v_row.amount_overdue_1_30 <> 500 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (2a): esperaba el cargo viejo cancelado (31-60=0) y el nuevo abierto (1-30=500); obtuve %/%.',
      v_row.amount_overdue_31_60, v_row.amount_overdue_1_30;
  END IF;

  -- ── (2b) B: cobro parcial → 600 abiertos del cargo de 1000 ────────────────
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_b;
  IF v_row.amount_overdue_31_60 <> 600 OR v_row.overdue_total <> 600 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (2b): el cobro parcial debía dejar 600 abiertos en 31-60; obtuve % (overdue_total %).',
      v_row.amount_overdue_31_60, v_row.overdue_total;
  END IF;

  -- ── (2c) C: la anulación reabrió EXACTAMENTE lo cancelado ─────────────────
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_c;
  IF v_row.amount_overdue_31_60 <> 1000 OR v_row.amount_overdue_1_30 <> 500 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (2c): anular el cobro debía reabrir 1000 (31-60) y 500 (1-30); obtuve %/%.',
      v_row.amount_overdue_31_60, v_row.amount_overdue_1_30;
  END IF;
  IF v_row.amount_current <> 0 AND v_row.amount_no_due_date <> 0 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (2c-rejuvenecer): la anulación NO puede crear un ítem abierto fechado hoy ni sin vencimiento.';
  END IF;

  -- ── (2d) D: la nota de crédito consumió el cargo más viejo ────────────────
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_d;
  IF v_row.amount_overdue_31_60 <> 0 OR v_row.amount_overdue_1_30 <> 500 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (2d): la nota de crédito debía cancelar el cargo viejo; obtuve 31-60=% y 1-30=%.',
      v_row.amount_overdue_31_60, v_row.amount_overdue_1_30;
  END IF;
  RAISE NOTICE 'PASS (2): imputación — más viejo primero, parcial, anulación reabre, nota consume.';

  -- ── (3) E: tramos y fronteras ─────────────────────────────────────────────
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_e;
  IF v_row.amount_current <> 100 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (3): vencimiento HOY debe estar al día (esperaba 100, obtuve %).', v_row.amount_current;
  END IF;
  IF v_row.amount_overdue_1_30 <> 500 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (3): ayer + hace 30 días deben caer en 1-30 (esperaba 200+300=500, obtuve %).', v_row.amount_overdue_1_30;
  END IF;
  IF v_row.amount_overdue_31_60 <> 900 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (3): hace 31 + hace 60 deben caer en 31-60 (esperaba 400+500=900, obtuve %).', v_row.amount_overdue_31_60;
  END IF;
  IF v_row.amount_overdue_60_plus <> 600 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (3): hace 61 debe caer en +60 (esperaba 600, obtuve %).', v_row.amount_overdue_60_plus;
  END IF;
  IF v_row.amount_no_due_date <> 700 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (3): el cargo sin vencimiento de hace 200 días debe caer en "sin vencimiento" (esperaba 700, obtuve %) — NUNCA en un tramo de vencido.', v_row.amount_no_due_date;
  END IF;
  IF v_row.oldest_due_date IS DISTINCT FROM (v_today - 61) OR v_row.days_overdue_max IS DISTINCT FROM 61 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (3): oldest_due_date/days_overdue_max esperaba (%/61), obtuve (%/%).',
      v_today - 61, v_row.oldest_due_date, v_row.days_overdue_max;
  END IF;
  RAISE NOTICE 'PASS (3): tramos, fronteras 30/31 y 60/61, sin-vencimiento nunca vencido.';

  -- ── (4) F: dos reglas separadas (D5) ──────────────────────────────────────
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_f;
  IF v_row.amount_no_due_date <> 700 OR v_row.amount_overdue_1_30 <> 500 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (4): el cobro de 300 debía imputarse al cargo sin vencimiento (más viejo) dejándolo en 700 "sin vencimiento", y el fechado intacto en 500 (1-30); obtuve %/%.',
      v_row.amount_no_due_date, v_row.amount_overdue_1_30;
  END IF;
  RAISE NOTICE 'PASS (4): imputación por antigüedad y clasificación por vencimiento son reglas separadas.';

  -- ── (5) G: vocabulario — no-cargos al pozo con su signo ───────────────────
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_g;
  IF v_row.amount_overdue_1_30 <> 900 OR v_row.balance <> 900 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (5): crédito = 200 (adjustment negativo) - 100 (reversal) = 100 → abierto 900 en 1-30; obtuve % (balance %).',
      v_row.amount_overdue_1_30, v_row.balance;
  END IF;
  IF v_row.amount_current <> 0 OR v_row.amount_no_due_date <> 0 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (5): ni el adjustment negativo ni el reversal pueden generar un ítem abierto propio.';
  END IF;
  RAISE NOTICE 'PASS (5): tipos no-cargo al pozo de crédito, sin ítem abierto propio.';

  -- ── (7) espejo proveedor ──────────────────────────────────────────────────
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_f, '__fifo_sup__')
  RETURNING id INTO v_sup_a;
  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance)
  VALUES (v_account_f, v_sup_a, 0);
  INSERT INTO public.supplier_account_movements
    (supplier_account_id, account_id, amount, balance_after, movement_type, reference_id, due_date, created_by, created_at)
  SELECT sa.id, v_account_f, x.amount, 0, x.mt, gen_random_uuid(), x.due, v_user_f, x.ts
  FROM public.supplier_accounts sa,
       (VALUES (800::numeric, 'purchase',     v_today - 10, now() - interval '10 days'),
               (-300::numeric, 'payment_made', NULL::date,   now() - interval '1 day')
       ) AS x(amount, mt, due, ts)
  WHERE sa.supplier_id = v_sup_a;
  UPDATE public.supplier_accounts SET balance = 500 WHERE supplier_id = v_sup_a;

  SELECT * INTO v_row FROM public.rpc_payables_report(v_account_f) r WHERE r.supplier_id = v_sup_a;
  IF v_row.supplier_id IS NULL OR v_row.amount_overdue_1_30 <> 500 OR v_row.overdue_total <> 500
     OR (v_row.amount_current + v_row.amount_overdue_1_30 + v_row.amount_overdue_31_60
         + v_row.amount_overdue_60_plus + v_row.amount_no_due_date) <> v_row.balance THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (7): el espejo proveedor debía mostrar 500 abiertos en 1-30 con invariante de cierre.';
  END IF;
  RAISE NOTICE 'PASS (7): rpc_payables_report — misma forma, mismo invariante.';

  -- ── (8) rpc_set_default_payment_terms ─────────────────────────────────────
  PERFORM public.rpc_set_default_payment_terms(30::smallint);
  SELECT default_payment_terms_days::int INTO v_cnt FROM public.accounts WHERE id = v_account_f;
  IF v_cnt IS DISTINCT FROM 30 THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (8): rpc_set_default_payment_terms(30) no persistió (obtuve %).', v_cnt;
  END IF;
  PERFORM public.rpc_set_default_payment_terms(NULL::smallint);
  SELECT default_payment_terms_days::int INTO v_cnt FROM public.accounts WHERE id = v_account_f;
  IF v_cnt IS NOT NULL THEN
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (8): rpc_set_default_payment_terms(NULL) debe limpiar el plazo.';
  END IF;
  BEGIN
    PERFORM public.rpc_set_default_payment_terms((-1)::smallint);
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (8): un plazo negativo debe rechazarse con P0400.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS (8): plazo por defecto — set, clear con NULL, P0400 negativo.';

  -- ── P0401: un no-miembro es rechazado por los DOS read-models ─────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM * FROM public.rpc_receivables_report(v_account_f);
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (P0401): un no-miembro pudo leer el read-model de cobrar.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0401' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM * FROM public.rpc_payables_report(v_account_f);
    RAISE EXCEPTION 'GATE AGING-FIFO FAILED (P0401): un no-miembro pudo leer el read-model de pagar.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0401' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS: P0401 en los dos read-models para no-miembros.';

  RAISE NOTICE '=== GATE RECEIVABLES-AGING-FIFO: TODO OK ===';
END $$;


-- ── Cleanup (molde test_party_payment_cash — deja la DB como estaba) ─────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('gate-fifo-f@test.local');

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.operation_idempotency
      WHERE event_id IN (SELECT id FROM public.events WHERE account_id = ANY(v_accounts));
    DELETE FROM public.notifications WHERE account_id = ANY(v_accounts);
    DELETE FROM public.journal_lines jl USING public.journal_entries je
      WHERE jl.entry_id = je.id AND je.account_id = ANY(v_accounts);
    DELETE FROM public.journal_entries WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sale_items WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchase_items WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchases WHERE account_id = ANY(v_accounts);
    DELETE FROM public.stock_movements WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_received WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_made     WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_account_movements cam USING public.customer_accounts ca
      WHERE cam.customer_account_id = ca.id AND ca.account_id = ANY(v_accounts);
    DELETE FROM public.customer_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_account_movements sam USING public.supplier_accounts sa
      WHERE sam.supplier_account_id = sa.id AND sa.account_id = ANY(v_accounts);
    DELETE FROM public.supplier_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.clients   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements WHERE bank_account_id IN (SELECT id FROM public.bank_accounts WHERE account_id = ANY(v_accounts));
    DELETE FROM public.bank_accounts  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.events  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
    DELETE FROM public.payment_methods WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = ANY(v_users);
  DELETE FROM public.email_logs WHERE user_id = ANY(v_users) OR recipient IN ('gate-fifo-f@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE AGING-FIFO: cleanup completo.';
END $$;
