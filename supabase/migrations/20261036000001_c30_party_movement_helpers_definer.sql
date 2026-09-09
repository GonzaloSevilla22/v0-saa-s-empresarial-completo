-- =============================================================================
-- c30-party-movement-helpers-definer — candidato S2 (h3 de
-- cuenta-corriente-party-guard, ver openspec/changes/archive/2026-08-23-
-- cuenta-corriente-party-guard/design.md §"Hallazgos laterales de la
-- revisión de seguridad" y CLAUDE.md §"Candidatos" — aprobado por el PO,
-- governance CRÍTICO/tenencia). Tanda candidatos-db-backend, 2026-09-09.
-- =============================================================================
--
-- HALLAZGO: `c30_register_customer_account_movement` y
-- `c30_register_supplier_account_movement` son SECURITY INVOKER, reciben la
-- cuenta corriente (`p_account_id`, el id de `customer_accounts`/
-- `supplier_accounts` — NO el tenant) COMO PARÁMETRO, y NO validan tenencia:
-- resuelven la cabecera con `SELECT ... FOR UPDATE` y postean el movimiento
-- sin comparar `v_acc.account_id` contra la sesión. Hoy la única barrera
-- contra una llamada directa es que ninguna policy de escritura existe sobre
-- `customer_account_movements`/`supplier_account_movements` (RLS enabled,
-- solo policy de SELECT) — una defensa de segundo orden, no un guard.
--
-- Verificado VIVO en prod (gxdhpxvdjjkmxhdkkwyb) el 2026-09-09, vía
-- mcp__supabase__execute_sql (antes de esta migración):
--   c30_register_customer_account_movement(uuid,numeric,text,uuid,date)
--     prosecdef=false, owner=postgres, search_path=public
--     length(pg_get_functiondef)=1668  md5=357047b84cde0c119f26b4fb9f05d1b1
--     proacl: EXECUTE para postgres, anon, authenticated, service_role
--   c30_register_supplier_account_movement(uuid,numeric,text,uuid,date)
--     prosecdef=false, owner=postgres, search_path=public
--     length(pg_get_functiondef)=1474  md5=c20cf97288fd2e42fe4277d99455d20c
--   pg_policies: customer_account_movements_select / supplier_account_
--     movements_select — SOLO SELECT, sin policy de INSERT/UPDATE.
-- (La base local recién reseteada reproduce el MISMO cuerpo — el md5 con
-- CRLF del checkout Windows difería en bytes, no en contenido; confirmado
-- diff línea a línea con \r quitados: cero diferencias reales. Gotcha ya
-- documentado, ver memoria `project_pg_functiondef_crlf_deno_gotchas`.)
--
-- CORRECCIÓN post-revisión adversarial (F3, misma tanda, MAJOR): la primera
-- versión de esta migración afirmaba que "todos los callers ya resolvieron y
-- validaron is_account_writer(v_account_id) sobre la sesión antes de
-- llamar", y usaba is_account_writer como guard interno de este mismo
-- helper. Es falso: medido en la base, 3 de 8 callers de nivel 1
-- (_pay_register_party_charge, _pay_reverse_party_charge,
-- rpc_issue_credit_note) NO llaman is_account_writer, y los callers de
-- nivel 2 que los alcanzan (rpc_create_sale_operation(_v2),
-- rpc_create_purchase_operation, rpc_delete_sale_operation,
-- rpc_delete_purchase_operation, rpc_atomic_update_sale_operation) autorizan
-- con `current_account_ids()` (mera MEMBRESÍA) + propiedad del producto, no
-- con rol. is_account_writer exige role IN ('owner','admin'); el CHECK de
-- account_members admite además 'member'. Con is_account_writer como guard
-- interno, un usuario 'member' (hoy 0 en prod, pero es exactamente el caso
-- de uso de v3-rbac-multirole) que hoy puede emitir una venta a crédito
-- recibiría P0401 y la venta entera fallaría — probado antes/después en
-- transacción con ROLLBACK: con is_account_writer, «venta a CRÉDITO por
-- member: FALLA sqlstate=P0401»; con el guard de membresía de abajo, la
-- misma venta funciona igual que antes de esta migración.
--
-- DECISIÓN DEL ORQUESTADOR (opción A del fix F3): el candidato h3 es un
-- guard de TENENCIA (que la cuenta corriente pertenezca al tenant de la
-- sesión), no de autorización por rol — la autorización de cada camino de
-- entrada (owner/admin donde corresponda) la deciden las RPCs de nivel 1/2,
-- no este helper intra-transacción de nivel más bajo. El guard interno se
-- implementa con `current_account_ids()` (membresía), la forma canónica del
-- proyecto para backstops de tenencia (mismo patrón que
-- 20261013000001_tenancy_guard_caja_sesion.sql §"MEMBRESÍA, NO
-- is_account_writer"): cierra el cross-tenant sin estrechar la matriz de
-- roles. Endurecer a owner/admin queda anotado como precondición de
-- `v3-rbac-multirole` en CHANGES.md, no resuelto acá.
--
-- Callers vivos (grep 2026-09-09, todos SECURITY DEFINER; ninguno pasa un
-- account_id ajeno — la propiedad de la cuenta corriente ya la resuelve el
-- choke point c30_get_or_create_customer_account/c30_get_or_create_supplier_
-- account de cuenta-corriente-party-guard antes de que exista la fila):
--   customer: _pay_register_party_charge, _pay_reverse_party_charge,
--             rpc_issue_credit_note, rpc_register_payment_received,
--             rpc_reverse_payment_received
--   supplier: rpc_register_supplier_charge, rpc_register_payment_made,
--             rpc_reverse_payment_made
-- Ningún caller directo vía PostgREST (frontend/backend): grep de
-- `.rpc('c30_register_` en frontend/ solo encuentra el tipo generado en
-- database.types.ts (sin uso real); grep de `get_service_conn` en backend/
-- ubica los routers fiscal.py/outbox.py/payments.py y services/
-- subscriptions.py, y NINGUNO de ellos llama a `rpc_register_payment_
-- received`, `rpc_register_payment_made`, `rpc_register_supplier_charge`,
-- `rpc_issue_credit_note`, `rpc_reverse_payment_*`, `_pay_register_party_
-- charge`, `_pay_reverse_party_charge` ni a los dos helpers de este archivo
-- (son webhook de suscripciones/CAE/outbox — dominio distinto de la cuenta
-- corriente de cliente/proveedor). Tampoco hay `cron.schedule` que invoque
-- esta cadena: el único cron de cobranzas-vencimientos
-- (`cobranzas-overdue-digest-sweep`) solo LEE aging y escribe
-- `email_logs`/`events`, nunca postea un movimiento. Conclusión: NINGÚN
-- camino real corre sin `auth.uid()` resuelto — se agrega el guard sin
-- reportar deviation.
--
-- DISEÑO (aprobado, revisado por F3): CREATE OR REPLACE con la MISMA firma
-- (nunca se cambia: no hace falta DROP+CREATE) agregando SECURITY DEFINER +
-- el guard de MEMBRESÍA justo después de confirmar FOUND en el SELECT ...
-- FOR UPDATE ya existente — se reutiliza `v_acc.account_id` (la columna de
-- tenant real en ambas tablas, confirmado con information_schema) en lugar
-- de una segunda SELECT redundante. El resto del cuerpo queda IDÉNTICO byte
-- a byte (P0404/P0409/INSERT/UPDATE sin tocar). Guard:
-- `IF v_acc.account_id NOT IN (SELECT public.current_account_ids()) THEN
-- RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401'` — el `IN (SELECT
-- ...)` es la forma canónica del proyecto porque current_account_ids()
-- devuelve SETOF uuid, no un array (`= ANY(...)` falla con "op ANY/ALL
-- (array) requires array on right side").
-- Tras el CREATE OR REPLACE (que CONSERVA el ACL previo — a diferencia de
-- DROP+CREATE, que lo resetea a los default privileges): REVOKE ALL ...
-- FROM PUBLIC, anon, authenticated (gotcha #432: nombrar los tres roles,
-- nunca solo PUBLIC) — `postgres` y `service_role` conservan EXECUTE, mismo
-- patrón que 20261010000001_revoke_internal_money_helpers.sql. Sin GRANT: no
-- hay caller directo real que lo necesite.
--
-- Defensa en profundidad deliberada: el guard interno + el REVOKE son
-- independientes. Si un REVOKE futuro se pierde en un CREATE OR REPLACE que
-- no reafirme permisos (el mismo mecanismo que produjo el hotfix #454), el
-- guard de tenencia sigue rechazando una cuenta ajena — igual que el
-- chequeo (3)+(4) redundante del gate de ACLs para _pay_register_party_
-- charge/_journal_post_from_event.
--
-- Gate permanente: supabase/tests/test_c30_party_movement_helpers_acl.sql
-- (introspección + negativo 42501 + positivo de no-regresión + guard
-- interno P0401). test_function_acl_gate.sql check (4) (barrido por
-- convención de nombre `c30_`) también cubre estas dos funciones ahora que
-- son SECURITY DEFINER: con el REVOKE de authenticated ninguna aparece como
-- offender — NO se agregan a `v_internal_allowlist` (no hace falta, y el
-- comentario de esa lista pide justificar cada entrada nueva).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.c30_register_customer_account_movement(
  p_account_id   uuid,
  p_amount       numeric,
  p_type         text,
  p_reference_id uuid DEFAULT NULL,
  p_due_date     date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_acc           public.customer_accounts%ROWTYPE;
  v_balance_after numeric(15,2);
  v_movement_id   uuid;
BEGIN
  -- D1: lock de fila de cabecera para serializar (FOR UPDATE)
  SELECT * INTO v_acc
  FROM public.customer_accounts
  WHERE id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'customer_account_not_found: %', p_account_id
      USING ERRCODE = 'P0404';
  END IF;

  -- S2 (h3 de cuenta-corriente-party-guard): ahora que el helper es
  -- SECURITY DEFINER, el guard de tenencia deja de depender de la ausencia
  -- de policies de escritura sobre customer_account_movements — se valida
  -- explícitamente contra el tenant REAL de la fila (v_acc.account_id),
  -- nunca contra el account_id recibido por parámetro. Guard de MEMBRESÍA
  -- (F3, corrección post-revisión), no de rol: la autorización por rol de
  -- cada camino de entrada la deciden las RPCs de nivel 1/2, no este helper
  -- de bajo nivel — ver cabecera "DECISIÓN DEL ORQUESTADOR".
  IF v_acc.account_id NOT IN (SELECT public.current_account_ids()) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  v_balance_after := v_acc.balance + p_amount;

  -- OQ-1 (RESUELTO): invariante balance >= 0 — guard explícito antes del INSERT
  IF v_balance_after < 0 THEN
    RAISE EXCEPTION 'overpayment: el pago (%) excede el saldo deudor (%)',
      ABS(p_amount), v_acc.balance
      USING ERRCODE = 'P0409';
  END IF;

  -- INSERT append-only en el ledger. cobranzas-vencimientos (D1): due_date
  -- viaja en el MISMO INSERT — snapshot, nunca un UPDATE posterior.
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, reference_id, due_date, created_by)
  VALUES
    (p_account_id, v_acc.account_id, p_amount, v_balance_after, p_type, p_reference_id, p_due_date, auth.uid())
  RETURNING id INTO v_movement_id;

  -- UPDATE de la cabecera (UPDATE-then-INSERT bajo FOR UPDATE, D1/gotcha #2)
  UPDATE public.customer_accounts
  SET balance = v_balance_after
  WHERE id = p_account_id;

  RETURN v_movement_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date) IS
  'C-30 + cobranzas-vencimientos + c30-party-movement-helpers-definer (S2, '
  '2026-09-09): helper intra-transacción del ledger de cliente. SECURITY '
  'DEFINER con guard de TENENCIA por membresía (current_account_ids() sobre '
  'el tenant REAL de la fila, v_acc.account_id) — cierra h3 de '
  'cuenta-corriente-party-guard. No usa is_account_writer a propósito (F3): '
  'la autorización por rol de cada camino de entrada la deciden las RPCs de '
  'nivel 1/2. FOR UPDATE en cabecera, balance_after materializado, INSERT '
  'append-only con due_date (5º arg, trailing, NULL = sin vencimiento). No '
  'ejecutable por anon ni authenticated (REVOKE explícito de los tres '
  'roles).';


CREATE OR REPLACE FUNCTION public.c30_register_supplier_account_movement(
  p_account_id   uuid,
  p_amount       numeric,
  p_type         text,
  p_reference_id uuid DEFAULT NULL,
  p_due_date     date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_acc           public.supplier_accounts%ROWTYPE;
  v_balance_after numeric(15,2);
  v_movement_id   uuid;
BEGIN
  -- D1: lock de fila de cabecera
  SELECT * INTO v_acc
  FROM public.supplier_accounts
  WHERE id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_account_not_found: %', p_account_id
      USING ERRCODE = 'P0404';
  END IF;

  -- S2 (h3 de cuenta-corriente-party-guard): espejo exacto del guard del
  -- helper de cliente. Guard de MEMBRESÍA, no de rol (F3).
  IF v_acc.account_id NOT IN (SELECT public.current_account_ids()) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  v_balance_after := v_acc.balance + p_amount;

  -- OQ-1: invariante balance >= 0
  IF v_balance_after < 0 THEN
    RAISE EXCEPTION 'overpayment: el pago (%) excede el saldo deudor (%)',
      ABS(p_amount), v_acc.balance
      USING ERRCODE = 'P0409';
  END IF;

  -- INSERT append-only. cobranzas-vencimientos (D1): due_date en el mismo INSERT.
  INSERT INTO public.supplier_account_movements
    (supplier_account_id, account_id, amount, balance_after, movement_type, reference_id, due_date, created_by)
  VALUES
    (p_account_id, v_acc.account_id, p_amount, v_balance_after, p_type, p_reference_id, p_due_date, auth.uid())
  RETURNING id INTO v_movement_id;

  -- UPDATE cabecera
  UPDATE public.supplier_accounts
  SET balance = v_balance_after
  WHERE id = p_account_id;

  RETURN v_movement_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date) IS
  'C-30 + cobranzas-vencimientos + c30-party-movement-helpers-definer (S2, '
  '2026-09-09): espejo exacto del helper de cliente para el ledger de '
  'proveedor, con guard de TENENCIA por membresía (current_account_ids(), '
  'NO is_account_writer — F3) y due_date como 5º arg trailing. No '
  'ejecutable por anon ni authenticated.';


-- =============================================================================
-- GATE DE INTROSPECCIÓN (corre SIEMPRE, también en prod).
-- =============================================================================
DO $$
DECLARE
  v_fn        text;
  v_oid       regprocedure;
  v_prosecdef bool;
  v_proconfig text[];
  v_prosrc    text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date)',
    'public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date)'
  ]
  LOOP
    v_oid := v_fn::regprocedure;

    SELECT p.prosecdef, p.proconfig, p.prosrc
    INTO v_prosecdef, v_proconfig, v_prosrc
    FROM pg_proc p
    WHERE p.oid = v_oid;

    IF NOT v_prosecdef THEN
      RAISE EXCEPTION 'GATE FAILED: % no quedó SECURITY DEFINER.', v_fn;
    END IF;

    IF v_proconfig IS NULL OR NOT ('search_path=public' = ANY (v_proconfig)) THEN
      RAISE EXCEPTION 'GATE FAILED: % no tiene SET search_path = public.', v_fn;
    END IF;

    IF position('current_account_ids' IN v_prosrc) = 0 THEN
      RAISE EXCEPTION 'GATE FAILED: % no contiene el guard de membresía current_account_ids().', v_fn;
    END IF;

    -- F3: el guard debe ser de MEMBRESÍA, no de rol — si algún CREATE OR
    -- REPLACE futuro reintroduce is_account_writer acá, rompería la venta a
    -- crédito de un 'member' (ver cabecera "DECISIÓN DEL ORQUESTADOR").
    IF position('is_account_writer' IN v_prosrc) > 0 THEN
      RAISE EXCEPTION 'GATE FAILED: % volvió a usar is_account_writer como guard interno — eso estrecha la autorización a owner/admin y rompe la venta a crédito de un member (F3).', v_fn;
    END IF;

    IF has_function_privilege('anon', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE FAILED: % sigue expuesta a anon/authenticated tras el REVOKE.', v_fn;
    END IF;

    IF NOT has_function_privilege('postgres', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE FAILED: postgres quedó sin EXECUTE en %.', v_fn;
    END IF;
  END LOOP;

  RAISE NOTICE 'GATE OK: c30_register_customer_account_movement y c30_register_supplier_account_movement son SECURITY DEFINER con guard de membresía current_account_ids(), search_path fijo, y sin EXECUTE para anon/authenticated (postgres conserva EXECUTE).';
END $$;
