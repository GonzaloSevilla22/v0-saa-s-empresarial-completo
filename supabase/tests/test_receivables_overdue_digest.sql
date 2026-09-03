-- =============================================================================
-- GATE: test_receivables_overdue_digest.sql
-- CHANGE: cobranzas-vencimientos — grupo 5 (barrido diario y avisos)
--
-- Cubre tasks 5.1/5.5-5.8:
--   (1) Existe el job de pg_cron; el barrido NO es ejecutable por
--       anon/authenticated; _notification_from_event tiene UNA definición con
--       los dos tipos nuevos en su lista en-scope (9º y 10º del Consumer 4).
--   (2) Una cuenta con deuda vencida recibe UN aviso con la cifra agregada
--       (email + evento) — un dedup, dos canales.
--   (3) Segunda corrida el mismo día NO duplica, ni siquiera con importes
--       distintos (D8 capa 2 — as_of).
--   (4) Al día siguiente vuelve a avisar (dedup por día, OQ-3 firmada).
--   (5) Cuenta sin deuda vencida (al día) → nada. Deuda sólo "sin
--       vencimiento" → nada (escenario 5.8: prod hoy = 0 filas).
--   (6) Los dos lados (por cobrar / por pagar) se deduplican por separado.
--   (7) OQ-2 firmada: clientes dados de baja EXCLUIDOS del barrido.
--   (8) INVARIANTE D13: los tipos nuevos NO están en el conjunto canónico de
--       11 del Consumer 3; un evento de digest por _journal_post_from_event
--       NO produce asiento. (El gate completo de D13 vive en
--       test_cobranzas_reverso.sql (11) y sigue corriendo.)
-- =============================================================================

-- ═══════════ (1)+(8-estructural) — corre SIEMPRE ════════════════════════════
DO $$
DECLARE
  v_cnt int;
  v_def text;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM cron.job WHERE jobname = 'cobranzas-overdue-digest-sweep';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (1): el job cobranzas-overdue-digest-sweep no está programado (hay %).', v_cnt;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM cron.job
  WHERE jobname = 'cobranzas-overdue-digest-sweep' AND schedule = '0 12 * * *';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (1): el job debe correr a las 0 12 * * * (~09:00 Mendoza).';
  END IF;

  IF has_function_privilege('anon', 'public._produce_receivables_overdue_digest()'::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._produce_receivables_overdue_digest()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (1): el barrido no debe ser ejecutable por anon/authenticated.';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace AND proname = '_notification_from_event';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (1): _notification_from_event tiene % definiciones.', v_cnt;
  END IF;
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_notification_from_event';
  IF position('ReceivablesOverdueDigest' in v_def) = 0 OR position('PayablesOverdueDigest' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (1): _notification_from_event no lista los dos tipos nuevos en su alcance.';
  END IF;

  -- (8-estructural) los tipos nuevos NO entran al conjunto canónico de 11
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_journal_post_from_event';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (8): _journal_post_from_event no existe.';
  END IF;
  IF position('ReceivablesOverdueDigest' in v_def) > 0 OR position('PayablesOverdueDigest' in v_def) > 0 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (8): un tipo de digest apareció en _journal_post_from_event — el invariante D13 (11 tipos canónicos) NO admite tipos que no mueven plata.';
  END IF;
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_process_outbox_dispatch';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (8): rpc_process_outbox_dispatch no existe.';
  END IF;
  IF (substring(v_def from 'Consumer 3: JournalEntry.*?IN \(([^)]*)\)')) ~ 'OverdueDigest' THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (8): un tipo de digest apareció en el filtro del Consumer 3 del dispatcher.';
  END IF;

  RAISE NOTICE 'PASS (1)(8-estructural): cron programado, ACLs del barrido, Consumer 4 con los 2 tipos, D13 intacto.';
END $$;

-- ═══════════ (2)-(8) COMPORTAMIENTO — anchor sintético ══════════════════════
CREATE FUNCTION pg_temp.dg_mk_debt(p_uid uuid, p_acc uuid, p_name text,
                                   p_amount numeric, p_due date,
                                   p_deleted boolean DEFAULT false) RETURNS uuid AS $mk$
DECLARE v_cl uuid; v_ca uuid;
BEGIN
  INSERT INTO public.clients (user_id, account_id, name, deleted_at)
  VALUES (p_uid, p_acc, p_name, CASE WHEN p_deleted THEN now() ELSE NULL END)
  RETURNING id INTO v_cl;
  INSERT INTO public.customer_accounts (account_id, client_id, balance)
  VALUES (p_acc, v_cl, p_amount) RETURNING id INTO v_ca;
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type,
     reference_id, due_date, created_by, created_at)
  VALUES (v_ca, p_acc, p_amount, p_amount, 'sale', gen_random_uuid(), p_due, p_uid,
          now() - interval '15 days');
  RETURN v_cl;
END;
$mk$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_user_d uuid := gen_random_uuid();  -- cuenta D: vencido por cobrar Y por pagar
  v_user_e uuid := gen_random_uuid();  -- cuenta E: deuda al día → nada
  v_user_g uuid := gen_random_uuid();  -- cuenta G: deuda sólo sin vencimiento → nada
  v_user_i uuid := gen_random_uuid();  -- cuenta I: deudor vencido pero cliente dado de baja → nada
  v_acc_d uuid; v_acc_e uuid; v_acc_g uuid; v_acc_i uuid;
  v_sup_d uuid; v_sa_d uuid;
  v_today date;
  v_cnt int;
  v_ev  public.events%ROWTYPE;
  v_meta jsonb;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v_user_d, 'authenticated', 'authenticated', 'gate-digest-d@test.local', now(), now(), jsonb_build_object('name', 'Gate Digest D')),
    (v_user_e, 'authenticated', 'authenticated', 'gate-digest-e@test.local', now(), now(), jsonb_build_object('name', 'Gate Digest E')),
    (v_user_g, 'authenticated', 'authenticated', 'gate-digest-g@test.local', now(), now(), jsonb_build_object('name', 'Gate Digest G')),
    (v_user_i, 'authenticated', 'authenticated', 'gate-digest-i@test.local', now(), now(), jsonb_build_object('name', 'Gate Digest I'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_acc_d FROM public.account_members WHERE user_id = v_user_d LIMIT 1;
  SELECT account_id INTO v_acc_e FROM public.account_members WHERE user_id = v_user_e LIMIT 1;
  SELECT account_id INTO v_acc_g FROM public.account_members WHERE user_id = v_user_g LIMIT 1;
  SELECT account_id INTO v_acc_i FROM public.account_members WHERE user_id = v_user_i LIMIT 1;
  IF v_acc_d IS NULL OR v_acc_e IS NULL OR v_acc_g IS NULL OR v_acc_i IS NULL THEN
    RAISE NOTICE 'GATE DIGEST (setup): tenants no provisionados — degradando.';
    RETURN;
  END IF;

  v_today := public.reporting_local_today();

  -- D: 2 deudores vencidos (5000 + 2000) y 1 proveedor vencido (800)
  PERFORM pg_temp.dg_mk_debt(v_user_d, v_acc_d, '__dg_d1__', 5000, v_today - 10);
  PERFORM pg_temp.dg_mk_debt(v_user_d, v_acc_d, '__dg_d2__', 2000, v_today - 40);
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc_d, '__dg_sup__') RETURNING id INTO v_sup_d;
  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance)
  VALUES (v_acc_d, v_sup_d, 800) RETURNING id INTO v_sa_d;
  INSERT INTO public.supplier_account_movements
    (supplier_account_id, account_id, amount, balance_after, movement_type, reference_id, due_date, created_by, created_at)
  VALUES (v_sa_d, v_acc_d, 800, 800, 'purchase', gen_random_uuid(), v_today - 5, v_user_d, now() - interval '15 days');

  -- E: deuda al día (vence en 5 días) → NO debe avisar
  PERFORM pg_temp.dg_mk_debt(v_user_e, v_acc_e, '__dg_e1__', 3000, v_today + 5);

  -- G: deuda sólo SIN vencimiento → NO debe avisar (escenario 5.8, prod hoy)
  PERFORM pg_temp.dg_mk_debt(v_user_g, v_acc_g, '__dg_g1__', 4000, NULL);

  -- I: deudor vencido pero cliente DADO DE BAJA → NO debe avisar (OQ-2)
  PERFORM pg_temp.dg_mk_debt(v_user_i, v_acc_i, '__dg_i1__', 9000, v_today - 30, true);

  -- ── (2) primera corrida: UN aviso por lado para D, nada para E/G/I ────────
  PERFORM public._produce_receivables_overdue_digest();

  SELECT COUNT(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'receivables_overdue_digest' AND (metadata->>'account_id')::uuid = v_acc_d;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (2): esperaba 1 email de cobrar para D, hay %.', v_cnt;
  END IF;
  SELECT metadata INTO v_meta FROM public.email_logs
  WHERE event_type = 'receivables_overdue_digest' AND (metadata->>'account_id')::uuid = v_acc_d;
  IF (v_meta->>'party_count')::int <> 2 OR (v_meta->>'overdue_total')::numeric <> 7000
     OR v_meta->>'as_of' <> v_today::text THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (2): la cifra agregada debía ser 2 deudores / 7000 / as_of hoy — metadata %.', v_meta;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.events
  WHERE account_id = v_acc_d AND event_type = 'ReceivablesOverdueDigest';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (2): esperaba 1 evento ReceivablesOverdueDigest para D, hay %.', v_cnt;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'payables_overdue_digest' AND (metadata->>'account_id')::uuid = v_acc_d;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (2): esperaba 1 email de pagar para D, hay %.', v_cnt;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.events
  WHERE account_id = v_acc_d AND event_type = 'PayablesOverdueDigest';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (2): esperaba 1 evento PayablesOverdueDigest para D, hay %.', v_cnt;
  END IF;

  -- (5) E (al día), G (sin vencimiento) e I (cliente de baja, OQ-2): NADA
  SELECT COUNT(*) INTO v_cnt FROM public.email_logs
  WHERE event_type IN ('receivables_overdue_digest', 'payables_overdue_digest')
    AND (metadata->>'account_id')::uuid IN (v_acc_e, v_acc_g, v_acc_i);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (5/7): E (al día), G (sin vencimiento) o I (cliente de baja) recibieron aviso — hay % emails.', v_cnt;
  END IF;
  RAISE NOTICE 'PASS (2)(5)(7): un aviso por lado con la cifra agregada; al día / sin vencimiento / cliente de baja NO avisan.';

  -- ── (3) segunda corrida el MISMO día, con importes DISTINTOS → no duplica ─
  PERFORM pg_temp.dg_mk_debt(v_user_d, v_acc_d, '__dg_d3__', 1111, v_today - 20);
  PERFORM public._produce_receivables_overdue_digest();
  SELECT COUNT(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'receivables_overdue_digest' AND (metadata->>'account_id')::uuid = v_acc_d;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (3): la segunda corrida del mismo día duplicó el aviso (hay % emails) — la capa 2 del dedup (as_of) no está funcionando.', v_cnt;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.events
  WHERE account_id = v_acc_d AND event_type = 'ReceivablesOverdueDigest';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (3): la segunda corrida duplicó el evento (hay %).', v_cnt;
  END IF;

  -- ── (4) al día siguiente vuelve a avisar (se simula envejeciendo el as_of) ─
  UPDATE public.email_logs
  SET metadata = jsonb_set(metadata, '{as_of}', to_jsonb((v_today - 1)::text))
  WHERE event_type IN ('receivables_overdue_digest', 'payables_overdue_digest')
    AND (metadata->>'account_id')::uuid = v_acc_d;
  PERFORM public._produce_receivables_overdue_digest();
  SELECT COUNT(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'receivables_overdue_digest' AND (metadata->>'account_id')::uuid = v_acc_d;
  IF v_cnt <> 2 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (4): al día siguiente debía avisar de nuevo (esperaba 2 emails, hay %).', v_cnt;
  END IF;

  -- ── (6) los dos lados se deduplican por separado ──────────────────────────
  -- El "día siguiente" de (4) envejeció los DOS lados; la corrida de (4)
  -- regeneró ambos. Ahora se retira SOLO el de pagar de hoy: la corrida debe
  -- recrear el de pagar y NO duplicar el de cobrar.
  DELETE FROM public.email_logs
  WHERE event_type = 'payables_overdue_digest'
    AND (metadata->>'account_id')::uuid = v_acc_d
    AND metadata->>'as_of' = v_today::text;
  PERFORM public._produce_receivables_overdue_digest();
  SELECT COUNT(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'payables_overdue_digest' AND (metadata->>'account_id')::uuid = v_acc_d
    AND metadata->>'as_of' = v_today::text;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (6): el lado de pagar debía regenerarse hoy (hay % con as_of hoy).', v_cnt;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'receivables_overdue_digest' AND (metadata->>'account_id')::uuid = v_acc_d
    AND metadata->>'as_of' = v_today::text;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (6): el lado de cobrar se duplicó al regenerar el de pagar (hay % con as_of hoy).', v_cnt;
  END IF;
  RAISE NOTICE 'PASS (3)(4)(6): dedup por día, re-aviso al día siguiente, lados independientes.';

  -- ── (8-comportamiento) un evento de digest NO produce asiento ─────────────
  SELECT * INTO v_ev FROM public.events
  WHERE account_id = v_acc_d AND event_type = 'ReceivablesOverdueDigest'
  ORDER BY occurred_at DESC LIMIT 1;
  SELECT COUNT(*) INTO v_cnt FROM public.journal_entries WHERE account_id = v_acc_d;
  PERFORM public._journal_post_from_event(v_ev);
  SELECT COUNT(*) - v_cnt INTO v_cnt FROM public.journal_entries WHERE account_id = v_acc_d;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'GATE DIGEST FAILED (8): procesar un ReceivablesOverdueDigest por el Consumer 3 creó % asientos — un vencimiento no mueve plata.', v_cnt;
  END IF;
  RAISE NOTICE 'PASS (8): el digest no produce asiento contable.';

  RAISE NOTICE '=== GATE RECEIVABLES-OVERDUE-DIGEST: TODO OK ===';
END $$;


-- ── Cleanup (molde test_party_payment_cash — deja la DB como estaba) ─────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('gate-digest-d@test.local', 'gate-digest-e@test.local', 'gate-digest-g@test.local', 'gate-digest-i@test.local');

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
  DELETE FROM public.email_logs WHERE user_id = ANY(v_users) OR recipient IN ('gate-digest-d@test.local', 'gate-digest-e@test.local', 'gate-digest-g@test.local', 'gate-digest-i@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE DIGEST: cleanup completo.';
END $$;
