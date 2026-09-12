-- =============================================================================
-- GATE: test_document_status_transition_role_matrix.sql
-- CHANGE: v3-rbac-multirole Parte B, grupo 11 (D13, D14, D15) — matriz rol ×
-- transición sobre document_status_transitions/record_status_transition.
--
--   (1) allowed_role es text[] (D13) y el reparto es EXACTAMENTE 14
--       pobladas / 5 NULL sobre las 19 filas — las 5 son las 3 de
--       fiscal_document y las 2 quote→expired (11.1).
--   (2) segregación de funciones (11.2, RN-A4): un cashier CONFIRMA una
--       venta (sales_order draft→confirmed) pero NO la ANULA
--       (confirmed→canceled, requiere admin/owner); un stock completa una
--       transferencia; un accountant abre Y cierra conciliación; un rol
--       VENCIDO no habilita nada.
--   (3) las 2 exenciones de D14 (11.3): p_performed_by NULL (contexto de
--       sistema, p.ej. relay CAE) pasa SIEMPRE, y una fila con
--       allowed_role NULL (transición de sistema) pasa con CUALQUIER actor
--       (incluso uno sin ROL alguno en la cuenta).
--   (4) el caso negativo real: un actor con roles activos que NO intersecan
--       allowed_role -> P0403.
--   (5) Ronda 1 adversarial (minor 3) — cobertura de CATÁLOGO: enumera los
--       pares (document_type, from_status, to_status) que producen los 12
--       llamadores VIVOS de record_status_transition (task 7.5 -- 14
--       triples distintos, incluidas las 2 ramas dinámicas de
--       rpc_accept_quote (quote draft/sent→accepted) y las 2 de
--       rpc_record_fiscal_transition (fiscal_document pending_cae→
--       authorized/rejected)) y asserta que TODOS existen en
--       document_status_transitions. record_status_transition exime la
--       verificación de rol cuando NO hay fila (D17/11.7, criterio
--       conservador de esta ronda -- ver la migración) — este bloque, POR
--       SÍ SOLO, sólo atrapa que la matriz PIERDA una fila que los 12
--       llamadores de hoy necesitan (mira hacia atrás, contra una lista
--       hardcodeada). No atrapa, solo, una transición nueva genuina: para
--       eso hace falta (5b) de abajo, que atrapa que aparezca un llamador
--       nuevo (o cambie el conjunto de los 12) sin revisar. Juntos (5)+(5b)
--       cubren catálogo + conjunto de llamadores, no una transición nueva
--       en abstracto (ver el punto ciego documentado en (5b): un llamador
--       YA conocido que cambie el PAR que produce sigue sin gate).
--   (5b) Ronda 2 adversarial: el conjunto de funciones que invocan
--       record_status_transition sigue siendo EXACTAMENTE el de los 12
--       llamadores conocidos -- ver el bloque de abajo para el detalle y
--       el punto ciego declarado (trg_quote_record_creation, candidato en
--       CHANGES.md).
--
-- Degrade-don't-fail si no hay auth.users para anclar el fixture.
-- =============================================================================

-- ── (1) Reparto 14/5 exacto, columna text[] ─────────────────────────────────
DO $$
DECLARE
  v_col_type text;
  v_total    int;
  v_populated int;
  v_null_rows record;
  v_null_set text[];
BEGIN
  SELECT data_type INTO v_col_type
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'document_status_transitions' AND column_name = 'allowed_role';

  IF v_col_type <> 'ARRAY' THEN
    RAISE EXCEPTION 'GATE FAILED (1): allowed_role no es un array (data_type=%)', v_col_type;
  END IF;

  SELECT count(*), count(allowed_role) INTO v_total, v_populated
  FROM public.document_status_transitions;

  IF v_total <> 19 OR v_populated <> 14 THEN
    RAISE EXCEPTION 'GATE FAILED (1): se esperaban 19 filas / 14 pobladas, hay % / %', v_total, v_populated;
  END IF;

  SELECT array_agg(document_type || ':' || COALESCE(from_status, 'NULL') || '->' || to_status ORDER BY document_type, from_status NULLS FIRST, to_status)
  INTO v_null_set
  FROM public.document_status_transitions WHERE allowed_role IS NULL;

  IF v_null_set <> ARRAY[
    'fiscal_document:NULL->pending_cae',
    'fiscal_document:pending_cae->authorized',
    'fiscal_document:pending_cae->rejected',
    'quote:draft->expired',
    'quote:sent->expired'
  ] THEN
    RAISE EXCEPTION 'GATE FAILED (1): el conjunto EXACTO de las 5 filas NULL no coincide: %', v_null_set;
  END IF;

  RAISE NOTICE 'PASS (1): allowed_role es text[], 14/19 pobladas, las 5 NULL son exactamente fiscal_document(x3) + quote->expired(x2).';
END $$;


-- ── (2)-(4) comportamiento de record_status_transition contra la matriz ─────
DO $$
DECLARE
  v_anchor_user  uuid;
  v_account_a    uuid := gen_random_uuid();
  v_member_cashier   uuid;
  v_member_stock     uuid;
  v_member_accountant uuid;
  v_member_expired   uuid;
  v_member_none      uuid;
  v_doc_id       uuid := gen_random_uuid();
  v_errcode      text;
  v_blocks_run   int := 0;
  v_expected     int := 8;
BEGIN
  SELECT id INTO v_anchor_user FROM auth.users LIMIT 1;
  IF v_anchor_user IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: no hay ningún auth.users para anclar el fixture -- se omite el comportamiento.';
    RETURN;
  END IF;

  INSERT INTO public.accounts (id, owner_user_id) VALUES (v_account_a, v_anchor_user);

  -- Un solo v_anchor_user real -- 5 "actores" sintéticos son 5 FILAS de
  -- account_members del MISMO usuario en la MISMA cuenta no es posible
  -- (unique account_id,user_id) -- en vez de eso, un ÚNICO member con
  -- roles que se REASIGNAN entre bloques (más simple, mismo poder de
  -- prueba: record_status_transition sólo mira los roles ACTIVOS del
  -- member_id resuelto por account_user_active_roles(account_id, actor),
  -- que resuelve por (account_id, user_id) -- no importa cuántas filas de
  -- account_members haya, sólo la que matchea ese (account_id, user_id)).
  INSERT INTO public.account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_account_a, v_anchor_user, 'member')
    ON CONFLICT (account_id, user_id) DO UPDATE SET role = EXCLUDED.role
    RETURNING id INTO v_member_cashier;
  v_member_stock := v_member_cashier;
  v_member_accountant := v_member_cashier;
  v_member_expired := v_member_cashier;
  v_member_none := v_member_cashier;

  -- (2a) cashier CONFIRMA una venta (draft->confirmed) -- PASA.
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_cashier, 'cashier', now());

  PERFORM public.record_status_transition(v_account_a, 'sales_order', v_doc_id, 'draft', 'confirmed', v_anchor_user, NULL);
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2a): cashier confirma una venta (draft->confirmed).';

  -- (2b) el MISMO cashier NO puede ANULAR (confirmed->canceled, requiere admin/owner).
  BEGIN
    PERFORM public.record_status_transition(v_account_a, 'sales_order', v_doc_id, 'confirmed', 'canceled', v_anchor_user, 'motivo de prueba');
    RAISE EXCEPTION 'GATE FAILED (2b): cashier pudo ANULAR una venta confirmada (debía requerir admin/owner)';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_errcode = RETURNED_SQLSTATE;
    IF v_errcode <> 'P0403' THEN RAISE; END IF;
  END;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2b): cashier NO puede anular una venta confirmada -- P0403 (RN-A4: "pero no anula").';

  DELETE FROM public.account_member_roles WHERE member_id = v_member_cashier;

  -- (2c) stock completa una transferencia.
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_stock, 'stock', now());

  PERFORM public.record_status_transition(v_account_a, 'stock_transfer', v_doc_id, NULL, 'completed', v_anchor_user, NULL);
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2c): stock completa una transferencia.';

  DELETE FROM public.account_member_roles WHERE member_id = v_member_stock;

  -- (2d) accountant abre Y cierra conciliación.
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_accountant, 'accountant', now());

  PERFORM public.record_status_transition(v_account_a, 'reconciliation_session', v_doc_id, NULL, 'open', v_anchor_user, NULL);
  PERFORM public.record_status_transition(v_account_a, 'reconciliation_session', v_doc_id, 'open', 'closed', v_anchor_user, NULL);
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2d): accountant abre Y cierra una sesión de conciliación.';

  DELETE FROM public.account_member_roles WHERE member_id = v_member_accountant;

  -- (2e) un rol VENCIDO no habilita nada -- mismo cashier, ahora vencido.
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at, expires_at)
  VALUES (v_account_a, v_member_expired, 'cashier', now() - INTERVAL '10 days', now() - INTERVAL '1 day');

  BEGIN
    PERFORM public.record_status_transition(v_account_a, 'sales_order', v_doc_id, 'draft', 'confirmed', v_anchor_user, NULL);
    RAISE EXCEPTION 'GATE FAILED (2e): un rol VENCIDO no debía habilitar la transición';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_errcode = RETURNED_SQLSTATE;
    IF v_errcode <> 'P0403' THEN RAISE; END IF;
  END;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2e): un rol vencido no habilita la transición (P0403).';

  DELETE FROM public.account_member_roles WHERE member_id = v_member_expired;

  -- (3a) D14 exención 1: p_performed_by NULL (sistema) -- el CHEQUEO DE ROL
  -- se salta siempre, incluso para una fila CON allowed_role restrictivo
  -- (sales_order draft->confirmed exige cashier/seller/admin/owner).
  -- HALLAZGO (task 7.5, verificado contra el pg_get_functiondef VIVO de los
  -- 12 llamadores reales, no contra el texto del design): NINGÚN llamador
  -- vivo pasa un NULL literal -- document_status_history.performed_by es
  -- NOT NULL desde SIEMPRE (preexistente, ajeno a este change), así que un
  -- INSERT con performed_by NULL falla con 23502 sea cual sea el resultado
  -- del chequeo de rol. rpc_record_fiscal_transition (el relay CAE real) ya
  -- resuelve esto con una convención propia: `COALESCE(auth.uid(),
  -- '00000000-0000-0000-0000-000000000000'::uuid)` -- un UUID centinela,
  -- NO NULL -- documentado en su propio comentario ("uuid cero = sistema").
  -- Ese caso real queda cubierto por la exención 2 (fiscal_document tiene
  -- allowed_role NULL en sus 3 filas), no por ésta. La exención 1 sigue
  -- siendo la interpretación correcta y literal de D14 (defensiva para un
  -- futuro caller que SÍ pase NULL) -- este bloque prueba que el camino
  -- existe y hace lo que dice: el chequeo de rol se SALTEA (el error que
  -- sale es 23502 de la tabla, NUNCA P0403 -- si el chequeo NO se salteara,
  -- record_status_transition fallaría ANTES, con P0403, porque
  -- account_user_active_roles(account_id, NULL) siempre da un conjunto
  -- vacío).
  BEGIN
    PERFORM public.record_status_transition(v_account_a, 'sales_order', v_doc_id, 'draft', 'confirmed', NULL, NULL);
    RAISE EXCEPTION 'GATE FAILED (3a): se esperaba 23502 (NOT NULL de performed_by, preexistente) -- la transición no debía completarse';
  EXCEPTION
    WHEN not_null_violation THEN
      NULL;  -- esperado: el chequeo de rol se salteó (exención 1); lo que
             -- bloquea es la constraint preexistente de la tabla, no P0403.
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_errcode = RETURNED_SQLSTATE;
      RAISE EXCEPTION 'GATE FAILED (3a): se esperaba 23502 (not_null_violation), salió % -- si es P0403 el chequeo de rol NO se está salteando para actor NULL (D14 exención 1 rota)', v_errcode;
  END;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3a): p_performed_by NULL (D14 exención 1) saltea el chequeo de rol -- el único bloqueo es el NOT NULL preexistente de la tabla (23502), nunca P0403.';

  -- (3b) D14 exención 2: allowed_role NULL (transición de sistema) -- pasa
  -- con CUALQUIER actor, incluso uno SIN ningún rol en la cuenta (v_member_none
  -- ya no tiene ninguna fila en el pivot tras los DELETE de arriba).
  PERFORM public.record_status_transition(v_account_a, 'fiscal_document', v_doc_id, NULL, 'pending_cae', v_anchor_user, NULL);
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3b): allowed_role NULL (transición de sistema) pasa con cualquier actor, incluso sin rol alguno.';

  -- (4) caso negativo real: actor con roles que NO intersecan allowed_role.
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_none, 'purchases', now());

  BEGIN
    PERFORM public.record_status_transition(v_account_a, 'cash_session', v_doc_id, NULL, 'open', v_anchor_user, NULL);
    RAISE EXCEPTION 'GATE FAILED (4): purchases no debía poder abrir una sesión de caja';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_errcode = RETURNED_SQLSTATE;
    IF v_errcode <> 'P0403' THEN RAISE; END IF;
  END;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (4): un rol sin intersección con allowed_role -- P0403.';

  -- Cleanup
  DELETE FROM public.document_status_history WHERE account_id = v_account_a;
  DELETE FROM public.account_member_roles WHERE member_id = v_member_cashier;
  DELETE FROM public.account_members WHERE id = v_member_cashier;
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE id = v_account_a;
  SET session_replication_role = DEFAULT;

  IF v_blocks_run <> v_expected THEN
    RAISE EXCEPTION 'GATE DOCUMENT-STATUS-TRANSITION-ROLE-MATRIX FAILED (conteo): % de % bloques.', v_blocks_run, v_expected;
  END IF;

  RAISE NOTICE 'GATE DOCUMENT-STATUS-TRANSITION-ROLE-MATRIX: %/% bloques PASS.', v_blocks_run, v_expected;
EXCEPTION
  WHEN OTHERS THEN
    SET session_replication_role = DEFAULT;
    DELETE FROM public.document_status_history WHERE account_id = v_account_a;
    DELETE FROM public.account_member_roles WHERE member_id = v_member_cashier;
    DELETE FROM public.account_members WHERE id = v_member_cashier;
    SET session_replication_role = replica;
    DELETE FROM public.accounts WHERE id = v_account_a;
    SET session_replication_role = DEFAULT;
    RAISE;
END $$;


-- ── (5) Ronda 1 adversarial (minor 3): cobertura de catálogo de los 12 ──────
-- llamadores VIVOS -- no depende de auth.users, es un chequeo puro contra
-- la tabla document_status_transitions.
DO $$
DECLARE
  v_expected_triples text[] := ARRAY[
    'sales_order:NULL->draft',           -- rpc_accept_quote, rpc_quick_sale
    'sales_order:draft->confirmed',      -- _c29_confirm_order_core
    'sales_order:confirmed->canceled',   -- rpc_delete_sale_operation
    'quote:NULL->draft',                 -- trg_quote_record_creation
    'quote:draft->accepted',             -- rpc_accept_quote (v_quote.status='draft')
    'quote:sent->accepted',              -- rpc_accept_quote (v_quote.status='sent')
    'cash_session:NULL->open',           -- rpc_open_cash_session
    'cash_session:open->closed',         -- rpc_close_cash_session
    'reconciliation_session:NULL->open', -- rpc_open_reconciliation_session
    'reconciliation_session:open->closed', -- rpc_close_reconciliation_session
    'fiscal_document:NULL->pending_cae', -- rpc_emit_pending_cae
    'fiscal_document:pending_cae->authorized', -- rpc_record_fiscal_transition
    'fiscal_document:pending_cae->rejected',   -- rpc_record_fiscal_transition
    'stock_transfer:NULL->completed'     -- rpc_transfer_stock
  ];
  v_existing_triples text[];
  v_missing text[];
  v_triple text;
BEGIN
  SELECT array_agg(document_type || ':' || COALESCE(from_status, 'NULL') || '->' || to_status)
  INTO v_existing_triples
  FROM public.document_status_transitions;

  v_missing := ARRAY[]::text[];
  FOREACH v_triple IN ARRAY v_expected_triples LOOP
    IF NOT (v_triple = ANY (v_existing_triples)) THEN
      v_missing := array_append(v_missing, v_triple);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'GATE FAILED (5): % de los pares (document_type,from,to) que producen los 12 llamadores vivos de record_status_transition NO están catalogados en document_status_transitions: % -- una creación no catalogada hoy pasa SIN chequeo de rol (D17/11.7, exención conservadora), así que un caller nuevo/modificado que produzca uno de estos pares debe agregarlo a la matriz.',
      array_length(v_missing, 1), v_missing;
  END IF;

  RAISE NOTICE 'PASS (5): las % triples (document_type,from,to) que producen los 12 llamadores vivos de record_status_transition están TODAS catalogadas en document_status_transitions.', array_length(v_expected_triples, 1);
END $$;


-- ── (5b) Ronda 2 adversarial (minor): el conjunto de FUNCIONES que ────────
-- invocan record_status_transition sigue siendo EXACTAMENTE el de los 12
-- llamadores conocidos. El bloque (5) de arriba sólo mira hacia ATRÁS (que
-- los 14 pares catalogados existan en document_status_transitions); éste
-- mira hacia ADELANTE -- si aparece un caller NUEVO (o desaparece uno
-- viejo), este bloque falla y obliga a revisar v_expected_triples de (5).
-- Sin este bloque, un caller nuevo que empiece a producir una transición
-- SIN catalogar es invisible: record_status_transition exime la
-- verificación de rol cuando no hay fila (D17/11.7), y (5) sólo audita los
-- 14 pares que YA conoce -- nunca detecta un llamador que ni siquiera
-- estaba en la lista.
--
-- Lo que este bloque NO cierra (punto ciego real, deliberado): un llamador
-- YA conocido que cambie el PAR que produce sigue sin gate.
-- trg_quote_record_creation pasa `NEW.status` DINÁMICO como to_status --
-- hoy sólo ejercita quote:NULL->draft en la práctica (verificado: es el
-- único valor con el que se inserta un quote nuevo), pero nada en su firma
-- lo ata a ESE valor. Anotado como candidato en CHANGES.md, no cerrado acá
-- (exigiría o bien un CHECK en el trigger, o bien auditar el body del
-- trigger contra un valor literal en vez de un caller-set).
DO $$
DECLARE
  v_expected_callers text[] := ARRAY[
    '_c29_confirm_order_core',
    'rpc_accept_quote',
    'rpc_close_cash_session',
    'rpc_close_reconciliation_session',
    'rpc_delete_sale_operation',
    'rpc_emit_pending_cae',
    'rpc_open_cash_session',
    'rpc_open_reconciliation_session',
    'rpc_quick_sale',
    'rpc_record_fiscal_transition',
    'rpc_transfer_stock',
    'trg_quote_record_creation'
  ];
  v_actual_callers   text[];
  v_missing_callers  text[];
  v_new_callers      text[];
  v_c                text;
BEGIN
  -- NOTA (hallazgo de esta misma ronda, ajeno a la task 7.5 pero del mismo
  -- origen): un filtro NAIVE `pg_get_functiondef(p.oid) ILIKE '...'` en el
  -- WHERE de una consulta plana sobre pg_proc explota ACÁ con `ERROR:
  -- "array_agg" is an aggregate function` -- reproducido de forma estable
  -- (2 corridas idénticas) incluso SIN excluir funciones agregadas por
  -- prokind. Materializar la definición en una CTE (`AS MATERIALIZED`)
  -- ANTES de filtrar por ILIKE evita que el planner intente una forma de
  -- plan que dispara ese error; con `WITH ... AS MATERIALIZED` la consulta
  -- es estable (4 corridas idénticas, orden de bloques intercambiado).
  WITH defs AS MATERIALIZED (
    SELECT p.proname, pg_get_functiondef(p.oid) AS def
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname <> 'record_status_transition'
  )
  SELECT array_agg(proname ORDER BY proname)
  INTO v_actual_callers
  FROM defs
  WHERE def ILIKE '%record_status_transition(%';

  v_actual_callers := COALESCE(v_actual_callers, ARRAY[]::text[]);

  v_missing_callers := ARRAY[]::text[];
  FOREACH v_c IN ARRAY v_expected_callers LOOP
    IF NOT (v_c = ANY (v_actual_callers)) THEN
      v_missing_callers := array_append(v_missing_callers, v_c);
    END IF;
  END LOOP;

  v_new_callers := ARRAY[]::text[];
  FOREACH v_c IN ARRAY v_actual_callers LOOP
    IF NOT (v_c = ANY (v_expected_callers)) THEN
      v_new_callers := array_append(v_new_callers, v_c);
    END IF;
  END LOOP;

  IF array_length(v_missing_callers, 1) > 0 THEN
    RAISE EXCEPTION 'GATE FAILED (5b): % llamador(es) conocido(s) de record_status_transition YA NO invocan la función (desapareció o cambió de nombre): % -- revisar v_expected_triples de (5) y v_expected_callers de acá; puede que una transición catalogada haya quedado huérfana.',
      array_length(v_missing_callers, 1), v_missing_callers;
  END IF;

  IF array_length(v_new_callers, 1) > 0 THEN
    RAISE EXCEPTION 'GATE FAILED (5b): % llamador(es) NUEVO(s) de record_status_transition, no revisado(s) todavía: % -- agregalo a v_expected_callers de este bloque y a v_expected_triples de (5) con los pares (document_type,from,to) que produce, catalogados en document_status_transitions.',
      array_length(v_new_callers, 1), v_new_callers;
  END IF;

  RAISE NOTICE 'PASS (5b): el conjunto de % funciones que invocan record_status_transition sigue siendo EXACTAMENTE el de los 12 llamadores conocidos -- sin altas ni bajas sin revisar.', array_length(v_expected_callers, 1);
END $$;
