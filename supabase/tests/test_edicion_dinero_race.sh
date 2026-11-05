#!/usr/bin/env bash
# =============================================================================
# GATE: test_edicion_dinero_race.sh
# CHANGE: edicion-operaciones-con-dinero, tanda B, grupo 7 (task 7.5) — governance ALTA
#
# Dos ediciones CONCURRENTES de ventas con dinero, con DOS conexiones reales (una sesion nunca bloquea contra su propio
# lock; dblink no sirve: el rol `postgres` de Supabase no es superusuario). Dos casos:
#
#   (a) DOBLE "GUARDAR" de la MISMA venta a credito (1000 -> 1200 contra 1000 -> 1300). La segunda edicion espera a la
#       primera en el lock de filas de `sales`, recuenta bajo el lock (las filas ya no existen: la primera las reemplazo) y
#       levanta P0404 SIN escribir dinero. Sin eso las dos compensarian el cargo viejo: la cuenta corriente quedaria
#       con el cargo duplicado. Estado final: UNA sola edicion (cargo neto 1200, una fila de auditoria).
#
#   (b) DOS EDICIONES QUE CRUZAN CLIENTES: A mueve la venta S1 del cliente 1 al 2 y B mueve la venta S2 del cliente 2 al 1.
#       Cada una toma sus filas de `sales` (distintas) y despues las DOS cuentas corrientes. Con un orden de bloqueo fijo
#       (ids ascendentes, `_op_edit_lock`) la segunda espera a la primera: SIN `40P01` (deadlock) y sin P0425 espurio.
#       Estado final: cada cargo en la cuenta del cliente nuevo.
#
# La sincronizacion es DETERMINISTICA, no por sleep: la sesion A hace su edicion y recien despues toma un advisory lock
# observable en pg_locks (los locks de fila ya estan tomados); espera a VER a la otra bloqueada (o un tope de ~6 s si
# la otra NO se bloquea, que es justamente el bug) y recien ahi hace COMMIT.
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres bash supabase/tests/test_edicion_dinero_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961089001

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

fail() { echo "GATE EDICION-DINERO-RACE FAILED: $*" >&2; cleanup; exit 1; }

USER_ID=""
ACCOUNT_ID=""

cleanup() {
  [ -n "${A_PID:-}" ] && kill "$A_PID" 2>/dev/null
  psql "$DB_URL" -X -q -t -A -c "
    SELECT pg_terminate_backend(l.pid)
    FROM pg_locks l
    WHERE l.locktype = 'advisory' AND l.objid = $ADVISORY_KEY AND l.pid <> pg_backend_pid();" >/dev/null 2>&1
  if [ -n "$ACCOUNT_ID" ]; then
    psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL
DO \$\$
DECLARE v_account uuid := '$ACCOUNT_ID'; v_user uuid := '$USER_ID';
BEGIN
  DELETE FROM public.customer_account_movements WHERE account_id = v_account;
  DELETE FROM public.customer_accounts       WHERE account_id = v_account;
  DELETE FROM public.sale_items              WHERE account_id = v_account;
  DELETE FROM public.sales                   WHERE account_id = v_account;
  DELETE FROM public.stock_movements         WHERE account_id = v_account;
  DELETE FROM public.events                  WHERE account_id = v_account;
  DELETE FROM public.audit_logs              WHERE account_id = v_account;
  DELETE FROM public.branch_stock            WHERE account_id = v_account;
  DELETE FROM public.products                WHERE account_id = v_account;
  DELETE FROM public.clients                 WHERE account_id = v_account;
  DELETE FROM public.analytics_events        WHERE user_id = v_user;
  DELETE FROM public.cashboxes               WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account);
  SET session_replication_role = replica;
  DELETE FROM public.branches                WHERE account_id = v_account;
  DELETE FROM public.payment_methods         WHERE account_id = v_account;
  DELETE FROM public.accounts                WHERE id = v_account;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members         WHERE user_id = v_user;
  DELETE FROM public.profiles                WHERE id = v_user;
  DELETE FROM public.email_logs              WHERE user_id = v_user;
  DELETE FROM public.operation_idempotency   WHERE user_id = v_user;
  DELETE FROM auth.users                     WHERE id = v_user;
END \$\$;
SQL
  fi
}

# ── Fixture ──────────────────────────────────────────────────────────────────
FIXTURE=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<'SQL'
DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
  v_product uuid;
  v_pm      uuid;
  v_c1      uuid;
  v_c2      uuid;
  v_s1      uuid;
  v_s2      uuid;
  v_s3      uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'edicion-dinero-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Edicion Dinero Race', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creo la cuenta'; END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm FROM public.payment_methods WHERE account_id = v_account AND kind = 'credit' AND is_active AND deleted_at IS NULL LIMIT 1;
  IF v_pm IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: sin forma de pago a credito sembrada'; END IF;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_edr_product__', 'EDR-1', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 500);
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_user, v_account, '__edr_c1__', 'active') RETURNING id INTO v_c1;
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_user, v_account, '__edr_c2__', 'active') RETURNING id INTO v_c2;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);

  -- S1: cliente 1 (para el doble guardado y para cruzar) · S2: cliente 2 (para cruzar) · S3: cliente 1 (otra venta)
  v_s1 := ((public.rpc_create_sale_operation_v2('edr-1-' || gen_random_uuid()::text, v_c1, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 1000, 'quantity', 1)), v_branch, NULL, v_pm))->>'operation_id')::uuid;
  v_s2 := ((public.rpc_create_sale_operation_v2('edr-2-' || gen_random_uuid()::text, v_c2, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 1000, 'quantity', 1)), v_branch, NULL, v_pm))->>'operation_id')::uuid;
  v_s3 := ((public.rpc_create_sale_operation_v2('edr-3-' || gen_random_uuid()::text, v_c1, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 1000, 'quantity', 1)), v_branch, NULL, v_pm))->>'operation_id')::uuid;

  CREATE TEMP TABLE IF NOT EXISTS _race_out (k text, v text);
  DELETE FROM _race_out;
  INSERT INTO _race_out VALUES ('user', v_user::text), ('account', v_account::text), ('product', v_product::text),
    ('pm', v_pm::text), ('c1', v_c1::text), ('c2', v_c2::text), ('s1', v_s1::text), ('s2', v_s2::text), ('s3', v_s3::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _race_out;
SQL
) || fail "no se pudo sembrar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z0-9]+=' | sed 's/^/RACE_/')"
USER_ID="$RACE_user"; ACCOUNT_ID="$RACE_account"
[ -n "${RACE_s1:-}" ] || fail "el fixture no devolvio la venta"
echo "fixture: s1=$RACE_s1 s2=$RACE_s2 s3=$RACE_s3 account=$ACCOUNT_ID"

wait_for_a() {
  local held
  for _ in $(seq 1 200); do
    held=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
    [ "${held:-0}" -ge 1 ] && return 0
    q "SELECT pg_sleep(0.1);" >/dev/null
  done
  fail "la sesion A nunca tomo el advisory $ADVISORY_KEY"
}

# Espera (max ~6 s) a ver a OTRO backend bloqueado esperando un lock de fila/transaccion.
A_WAIT='
DO $$
DECLARE v_i int;
BEGIN
  FOR v_i IN 1..60 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks WHERE NOT granted AND pid <> pg_backend_pid() AND locktype IN ('"'"'transactionid'"'"', '"'"'tuple'"'"')) THEN
      RETURN;
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $$;'

sale_ids() { q "SELECT array_to_string(array_agg(id ORDER BY id), ',') FROM public.sales WHERE operation_id = '$1';"; }
net() { q "SELECT COALESCE(sum(m.amount), 0) FROM public.customer_account_movements m JOIN public.customer_accounts ca ON ca.id = m.customer_account_id WHERE ca.account_id = '$ACCOUNT_ID' AND ca.client_id = '$1' AND m.reference_id = '$2' AND m.movement_type IN ('sale', 'credit_note');"; }

edit_sale() {  # $1 operation  $2 cliente  $3 importe
  local ids; ids=$(sale_ids "$1")
  psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
DO \$\$
DECLARE v_sqlstate text; v_msg text;
BEGIN
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      string_to_array('$ids', ',')::uuid[], '$2'::uuid, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', '$RACE_product'::uuid, 'amount', $3, 'quantity', 1)));
    RAISE NOTICE 'EDIT_OK';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
    RAISE NOTICE 'EDIT_ERR sqlstate=% msg=%', v_sqlstate, v_msg;
  END;
END \$\$;
COMMIT;
SQL
}

# Sesion A: edita y se queda con el lock hasta ver a B bloqueada.
hold_edit_sale() {  # $1 operation  $2 cliente  $3 importe  $4 archivo de salida
  local ids; ids=$(sale_ids "$1")
  psql "$DB_URL" -X -q -t -A > "$4" 2>&1 <<SQL &
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
SELECT 'A_OK=' || (public.rpc_atomic_update_sale_operation(
  string_to_array('$ids', ',')::uuid[], '$2'::uuid, CURRENT_DATE, 'ARS',
  jsonb_build_array(jsonb_build_object('product_id', '$RACE_product'::uuid, 'amount', $3, 'quantity', 1)))->>'operation_id');
SELECT pg_advisory_xact_lock($ADVISORY_KEY);
$A_WAIT
COMMIT;
SQL
  A_PID=$!
}

# ═════════════════════════════════════════════════════════════════════════════
# (a) DOBLE GUARDAR de la misma venta a credito
# ═════════════════════════════════════════════════════════════════════════════
A_OUT=$(mktemp)
hold_edit_sale "$RACE_s1" "$RACE_c1" 1200 "$A_OUT"
wait_for_a
echo "sesion A: edicion de la venta S1 ABIERTA (1000 -> 1200, sin commitear)"
B_OUT=$(edit_sale "$RACE_s1" "$RACE_c1" 1300)
wait "$A_PID" 2>/dev/null; A_PID=""
grep -q 'A_OK=' "$A_OUT" || fail "(a): la edicion de la sesion A no termino bien. Salida: $(cat "$A_OUT")"
echo "$B_OUT" | grep -qiE 'deadlock|40P01' && fail "(a): aparecio un deadlock. Salida: $B_OUT"
echo "$B_OUT" | grep -q 'EDIT_ERR sqlstate=P0404' \
  || fail "(a): la segunda edicion de la MISMA venta debia esperar a la primera, recontar las filas y levantar P0404. Salida de B: $B_OUT"

NET=$(net "$RACE_c1" "$RACE_s1")
[ "$NET" = "1200.00" ] || fail "(a): el cargo neto de S1 debia quedar en 1200.00 (UNA sola edicion) y quedo en '$NET'"
TOTAL=$(q "SELECT sum(total)::int FROM public.sales WHERE operation_id = '$RACE_s1';")
[ "$TOTAL" = "1200" ] || fail "(a): la venta debia quedar en 1200 (la edicion de A), quedo en $TOTAL"
EDITS=$(q "SELECT count(*) FROM public.audit_logs WHERE account_id = '$ACCOUNT_ID' AND entity_id = '$RACE_s1' AND action = 'sale_operation.edited';")
[ "$EDITS" = "1" ] || fail "(a): debia quedar UNA fila de auditoria (la edicion rechazada no deja rastro), hay $EDITS"
echo "PASS (a): doble guardado de la misma venta: la segunda espera, recuenta y levanta P0404; cargo neto 1200, una sola edicion auditada."

# ═════════════════════════════════════════════════════════════════════════════
# (b) DOS ediciones que CRUZAN clientes
# ═════════════════════════════════════════════════════════════════════════════
A_OUT=$(mktemp)
hold_edit_sale "$RACE_s3" "$RACE_c2" 1000 "$A_OUT"
wait_for_a
echo "sesion A: S3 pasa del cliente 1 al cliente 2 (ABIERTA, sin commitear)"
B_OUT=$(edit_sale "$RACE_s2" "$RACE_c1" 1000)
wait "$A_PID" 2>/dev/null; A_PID=""
grep -q 'A_OK=' "$A_OUT" || fail "(b): la edicion de la sesion A no termino bien. Salida: $(cat "$A_OUT")"
echo "$B_OUT" | grep -qiE 'deadlock|40P01' && fail "(b): aparecio un deadlock entre las dos ediciones que cruzan clientes. Salida: $B_OUT"
echo "$B_OUT" | grep -q 'EDIT_OK' || fail "(b): la edicion de B debia terminar OK (espera a A, sin deadlock ni P0425 espurio). Salida: $B_OUT"

[ "$(net "$RACE_c2" "$RACE_s3")" = "1000.00" ] || fail "(b): el cargo de S3 debia quedar en la cuenta del cliente 2"
[ "$(net "$RACE_c1" "$RACE_s3")" = "0.00" ] || [ "$(net "$RACE_c1" "$RACE_s3")" = "0" ] || fail "(b): el cargo de S3 debia salir de la cuenta del cliente 1"
[ "$(net "$RACE_c1" "$RACE_s2")" = "1000.00" ] || fail "(b): el cargo de S2 debia quedar en la cuenta del cliente 1"
echo "PASS (b): dos ediciones que cruzan clientes: la segunda espera a la primera con orden de bloqueo fijo; sin 40P01 y cada cargo en la cuenta del cliente nuevo."

cleanup
[ "$(q "SELECT count(*) FROM auth.users WHERE email = 'edicion-dinero-race@test.local';")" = "0" ] || fail "cleanup: quedo el anchor"
echo "PASS: gate edicion-dinero-race completo y sin residuo."
