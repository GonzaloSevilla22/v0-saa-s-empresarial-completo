-- =============================================================================
-- GATE: test_document_status_transition_role_matrix.sql
-- CHANGE: v3-rbac-multirole Parte B, grupo 11 (D13, D14, D15) — matriz rol ×
-- transición sobre document_status_transitions/record_status_transition.
--
--   (1) allowed_role es text[] (D13) y el reparto es EXACTAMENTE 14
--       pobladas / 6 NULL sobre las 20 filas — las 6 son las 4 de
--       fiscal_document y las 2 quote→expired (11.1).
--       venta-editable-sin-cae (20261060000001) sumó la 4a de
--       fiscal_document (pending_cae→voided, allowed_role NULL por D7):
--       19/5 pasó a 20/6. Este bloque es de conteo EXACTO, así que una fila
--       nueva sin actualizarlo acá rompe el pipeline — a propósito.
--       presupuestos-modulo (20261067000001) sumó las 2 filas de reapertura
--       quote: expired->draft y rejected->draft, con allowed_role
--       {seller,admin,owner} (D4): 20/14 pasó a 22/16. El conjunto de las 6
--       filas NULL no cambia (las dos nuevas no son de sistema).
--       remitos-venta tanda A (20261069000001) sumó delivery_note_sale:
--       NULL->issued {seller,stock,admin,owner} e issued->canceled
--       {admin,owner} (D3): 22/16 pasó a 24/18. Las 6 NULL no cambian (la
--       vuelta converted->issued sin rol es de la tanda B).
--       remitos-venta tanda B (20261070000001) sumó delivery_note_sale:
--       issued->converted {seller,cashier,admin,owner} y converted->issued
--       con allowed_role NULL (sistema: la dispara sólo el borrado de la
--       venta, que ya exige admin/owner por sales_order confirmed->canceled,
--       D3): 24/18 pasó a 26/19 y las filas NULL pasan de 6 a 7.
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
--       _quote_accept_core (quote draft/sent→accepted; era rpc_accept_quote
--       hasta presupuestos-modulo tanda B) y las 2 de
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
--       record_status_transition sigue siendo EXACTAMENTE el de los 13
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

  IF v_total <> 26 OR v_populated <> 19 THEN
    RAISE EXCEPTION 'GATE FAILED (1): se esperaban 26 filas / 19 pobladas, hay % / %', v_total, v_populated;
  END IF;

  SELECT array_agg(document_type || ':' || COALESCE(from_status, 'NULL') || '->' || to_status ORDER BY document_type, from_status NULLS FIRST, to_status)
  INTO v_null_set
  FROM public.document_status_transitions WHERE allowed_role IS NULL;

  IF v_null_set <> ARRAY[
    -- remitos-venta tanda B (D3): la vuelta del remito a pendiente al borrar
    -- la venta. Sin rol propio (tercera exención de record_status_transition):
    -- el borrado ya registró sales_order confirmed->canceled ({admin,owner}).
    'delivery_note_sale:converted->issued',
    'fiscal_document:NULL->pending_cae',
    'fiscal_document:pending_cae->authorized',
    'fiscal_document:pending_cae->rejected',
    -- venta-editable-sin-cae: la anulación del comprobante pendiente NO
    -- enviado. allowed_role NULL (D7) como las otras 3 de fiscal_document —
    -- quien puede editar la venta ya pasó require_role en el service.
    'fiscal_document:pending_cae->voided',
    'quote:draft->expired',
    'quote:sent->expired'
  ] THEN
    RAISE EXCEPTION 'GATE FAILED (1): el conjunto EXACTO de las 7 filas NULL no coincide: %', v_null_set;
  END IF;

  RAISE NOTICE 'PASS (1): allowed_role es text[], 19/26 pobladas, las 7 NULL son exactamente delivery_note_sale:converted->issued + fiscal_document(x4) + quote->expired(x2).';
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
    'sales_order:NULL->draft',           -- _quote_accept_core, rpc_quick_sale
    'sales_order:draft->confirmed',      -- _c29_confirm_order_core
    'sales_order:confirmed->canceled',   -- rpc_delete_sale_operation
    'quote:NULL->draft',                 -- trg_quote_record_creation
    'quote:draft->accepted',             -- _quote_accept_core (v_quote.status='draft')
    'quote:sent->accepted',              -- _quote_accept_core (v_quote.status='sent')
    'cash_session:NULL->open',           -- rpc_open_cash_session
    'cash_session:open->closed',         -- rpc_close_cash_session
    'reconciliation_session:NULL->open', -- rpc_open_reconciliation_session
    'reconciliation_session:open->closed', -- rpc_close_reconciliation_session
    'fiscal_document:NULL->pending_cae', -- rpc_emit_pending_cae
    'fiscal_document:pending_cae->authorized', -- rpc_record_fiscal_transition
    'fiscal_document:pending_cae->rejected',   -- rpc_record_fiscal_transition
    -- venta-editable-sin-cae (20261060000001): 4o estado terminal del
    -- comprobante. Lo produce _fiscal_void_pending_for_sale_edit, el 13o
    -- llamador (ver v_expected_callers del bloque 5b), cuando se edita o se
    -- borra una venta cuyo comprobante pendiente TODAVÍA NO salió hacia ARCA.
    -- Es la única fila de fiscal_document con requires_reason=true: el motivo
    -- ("anulado por edición de la venta X") queda en document_status_history.
    'fiscal_document:pending_cae->voided',     -- _fiscal_void_pending_for_sale_edit
    'stock_transfer:NULL->completed',    -- rpc_transfer_stock
    -- presupuestos-modulo (20261067000001): los 3 llamadores nuevos (5b).
    'quote:draft->sent',                 -- rpc_transition_quote('sent')
    'quote:draft->rejected',             -- rpc_transition_quote('rejected')
    'quote:sent->rejected',              -- rpc_transition_quote('rejected')
    'quote:draft->expired',              -- _expire_overdue_quotes (actor uuid cero)
    'quote:sent->expired',               -- _expire_overdue_quotes (actor uuid cero)
    'quote:expired->draft',              -- rpc_update_quote (reapertura al editar, D5)
    'quote:rejected->draft',             -- rpc_update_quote (reapertura al editar, D5)
    -- remitos-venta tanda A (20261069000001): los 2 llamadores nuevos (5b).
    'delivery_note_sale:NULL->issued',   -- trg_delivery_note_record_creation('delivery_note_sale')
    'delivery_note_sale:issued->canceled', -- rpc_cancel_delivery_note
    -- remitos-venta tanda B (20261070000001): el 19o llamador
    -- (rpc_convert_delivery_note_to_sale) produce sales_order:NULL->draft (ya
    -- listado arriba); delivery_note_sale:issued->converted lo produce el núcleo;
    -- rpc_delete_sale_operation (ya llamador) suma converted->issued.
    'delivery_note_sale:issued->converted', -- _c29_confirm_order_core (orden con origen de remito)
    'delivery_note_sale:converted->issued'  -- rpc_delete_sale_operation (venta nacida de remito)
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
    RAISE EXCEPTION 'GATE FAILED (5): % de los pares (document_type,from,to) que producen los 19 llamadores vivos de record_status_transition NO están catalogados en document_status_transitions: % -- una creación no catalogada hoy pasa SIN chequeo de rol (D17/11.7, exención conservadora), así que un caller nuevo/modificado que produzca uno de estos pares debe agregarlo a la matriz.',
      array_length(v_missing, 1), v_missing;
  END IF;

  RAISE NOTICE 'PASS (5): las % triples (document_type,from,to) que producen los 19 llamadores vivos de record_status_transition están TODAS catalogadas en document_status_transitions.', array_length(v_expected_triples, 1);
END $$;


-- ── (5b) Ronda 2 adversarial (minor): el conjunto de FUNCIONES que ────────
-- invocan record_status_transition sigue siendo EXACTAMENTE el de los 13
-- llamadores conocidos. El bloque (5) de arriba sólo mira hacia ATRÁS (que
-- los 15 pares catalogados existan en document_status_transitions); éste
-- mira hacia ADELANTE -- si aparece un caller NUEVO (o desaparece uno
-- viejo), este bloque falla y obliga a revisar v_expected_triples de (5).
-- Sin este bloque, un caller nuevo que empiece a producir una transición
-- SIN catalogar es invisible: record_status_transition exime la
-- verificación de rol cuando no hay fila (D17/11.7), y (5) sólo audita los
-- 15 pares que YA conoce -- nunca detecta un llamador que ni siquiera
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
    -- venta-editable-sin-cae (20261060000001): 13er llamador. Anula (voided) el
    -- comprobante pendiente de una sales_order cuando el pedido NO salió hacia
    -- ARCA, dentro de la transacción de la edición/borrado de la venta. Produce
    -- exactamente un par: fiscal_document:pending_cae->voided (bloque 5).
    '_fiscal_void_pending_for_sale_edit',
    '_c29_confirm_order_core',
    -- presupuestos-modulo tanda B (20261068000001, D6): el cuerpo de
    -- rpc_accept_quote se movió al núcleo _quote_accept_core, que comparten la
    -- aceptación y la conversión a venta. rpc_accept_quote (wrapper) y
    -- rpc_convert_quote_to_sale delegan en él y NO llaman al helper directo:
    -- el conteo sigue en 16 y los pares quote:draft|sent->accepted y
    -- sales_order:NULL->draft siguen siendo los mismos.
    '_quote_accept_core',
    'rpc_close_cash_session',
    'rpc_close_reconciliation_session',
    'rpc_delete_sale_operation',
    'rpc_emit_pending_cae',
    'rpc_open_cash_session',
    'rpc_open_reconciliation_session',
    'rpc_quick_sale',
    'rpc_record_fiscal_transition',
    'rpc_transfer_stock',
    'trg_quote_record_creation',
    -- presupuestos-modulo (20261067000001): 14o-16o llamadores. Producen los
    -- pares quote:draft->sent, draft|sent->rejected (rpc_transition_quote),
    -- draft|sent->expired (_expire_overdue_quotes) y expired|rejected->draft
    -- (rpc_update_quote) — bloque (5).
    'rpc_update_quote',
    'rpc_transition_quote',
    '_expire_overdue_quotes',
    -- remitos-venta tanda A (20261069000001): 17o-18o llamadores. Producen
    -- delivery_note_sale:NULL->issued (disparador de creación, tipo por
    -- TG_ARGV) e issued->canceled (anulación con motivo) — bloque (5).
    'trg_delivery_note_record_creation',
    'rpc_cancel_delivery_note',
    -- remitos-venta tanda B (20261070000001): 19o llamador. Produce
    -- sales_order:NULL->draft; el par delivery_note_sale:issued->converted lo
    -- produce _c29_confirm_order_core (revisión 8.5, RB-02), ya llamador.
    'rpc_convert_delivery_note_to_sale'
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

  RAISE NOTICE 'PASS (5b): el conjunto de % funciones que invocan record_status_transition sigue siendo EXACTAMENTE el de los 19 llamadores conocidos -- sin altas ni bajas sin revisar.', array_length(v_expected_callers, 1);
END $$;
