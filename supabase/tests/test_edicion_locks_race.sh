#!/usr/bin/env bash
# =============================================================================
# GATE: test_edicion_locks_race.sh
# CHANGE: edicion-operaciones-con-dinero, tanda A, grupo 4 (tasks 4.1 y 4.3) — governance ALTA
#
# Dos ediciones CONCURRENTES de la misma operacion, con DOS conexiones reales (una sesion nunca bloquea contra su
# propio lock; dblink no sirve en este entorno: el rol `postgres` de Supabase no es superusuario). Dos casos:
#
#   (c) COMPRA. `rpc_atomic_update_purchase_operation` hoy NO toma ningun lock de filas (la venta si: orden ascendente
#       + recuento, P0404). Con dos "Guardar" a la vez las dos aplican: las dos revierten el stock, la segunda borra
#       filas que ya no existen y vuelve a insertar -> la operacion queda DUPLICADA y el stock descuadrado. Con el
#       lock (FOR UPDATE ascendente + recuento) la segunda espera, vuelve a contar, no encuentra las filas y levanta
#       P0404; el estado final es el de UNA sola edicion.
#
#   (e) GASTO. `rpc_update_expense` lee la fila SIN bloquearla y la usa como "valor vigente" de todo campo que el
#       llamador no informa (`COALESCE(p_x, v_old.x)`). Dos ediciones a la vez pierden una de las dos (lost update):
#       A cambia la descripcion y B cambia el importe; B pisa la descripcion de A con la que leyo antes. Con
#       `FOR UPDATE` en la lectura B espera a A y lee su resultado: quedan las dos modificaciones.
#
# La sincronizacion es DETERMINISTICA, no por sleep: la sesion A hace su edicion y recien despues toma un advisory lock
# observable en pg_locks (el lock de fila ya esta tomado); espera a VER a la otra bloqueada (o un tope de ~6 s si
# la otra NO se bloquea, que es justamente el bug) y recien ahi hace COMMIT.
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres bash supabase/tests/test_edicion_locks_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961088001

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

fail() { echo "GATE EDICION-LOCKS-RACE FAILED: $*" >&2; cleanup; exit 1; }

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
  DELETE FROM public.purchase_items          WHERE account_id = v_account;
  DELETE FROM public.purchases               WHERE account_id = v_account;
  DELETE FROM public.expenses                WHERE account_id = v_account;
  DELETE FROM public.stock_movements         WHERE account_id = v_account;
  DELETE FROM public.events                  WHERE account_id = v_account;
  DELETE FROM public.audit_logs              WHERE account_id = v_account;
  DELETE FROM public.branch_stock            WHERE account_id = v_account;
  DELETE FROM public.products                WHERE account_id = v_account;
  DELETE FROM public.suppliers               WHERE account_id = v_account;
  DELETE FROM public.analytics_events        WHERE user_id = v_user;
  DELETE FROM public.cashboxes               WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account);
  SET session_replication_role = replica;
  DELETE FROM public.branches                WHERE account_id = v_account;
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
  v_result  jsonb;
  v_op      uuid;
  v_purchase uuid;
  v_expense uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'edicion-locks-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Edicion Locks Race', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creo la cuenta'; END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_elr_product__', 'ELR-1', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 200);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);

  v_result := public.rpc_create_purchase_operation(
    'elr-' || gen_random_uuid()::text, CURRENT_DATE, 'compra del gate',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 100.00, 'quantity', 5, 'unit_id', NULL)),
    v_branch);
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase FROM public.purchases WHERE operation_id = v_op;

  INSERT INTO public.expenses (user_id, account_id, category, amount, date, description, branch_id)
  VALUES (v_user, v_account, 'otros', 100, now(), 'desc original', v_branch) RETURNING id INTO v_expense;

  CREATE TEMP TABLE IF NOT EXISTS _race_out (k text, v text);
  DELETE FROM _race_out;
  INSERT INTO _race_out VALUES ('user', v_user::text), ('account', v_account::text), ('product', v_product::text),
    ('purchase', v_purchase::text), ('expense', v_expense::text), ('branch', v_branch::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _race_out;
SQL
) || fail "no se pudo sembrar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z]+=' | sed 's/^/RACE_/')"
USER_ID="$RACE_user"; ACCOUNT_ID="$RACE_account"
[ -n "${RACE_purchase:-}" ] || fail "el fixture no devolvio la compra"
echo "fixture: purchase=$RACE_purchase expense=$RACE_expense account=$ACCOUNT_ID"

wait_for_a() {
  local held
  for _ in $(seq 1 200); do
    held=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
    [ "${held:-0}" -ge 1 ] && return 0
    q "SELECT pg_sleep(0.1);" >/dev/null
  done
  fail "la sesion A nunca tomo el advisory $ADVISORY_KEY"
}

# Espera (max ~6 s) a ver a OTRO backend bloqueado esperando un lock de fila/transaccion. Si nadie se bloquea
# (el bug) vuelve igual: el gate concluye por el ESTADO FINAL.
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

# ═════════════════════════════════════════════════════════════════════════════
# (c) COMPRA — dos ediciones a la vez
# ═════════════════════════════════════════════════════════════════════════════
STOCK_BEFORE=$(q "SELECT quantity FROM public.branch_stock WHERE account_id = '$ACCOUNT_ID' AND product_id = '$RACE_product';")
[ "$STOCK_BEFORE" = "205.0000" ] || [ "$STOCK_BEFORE" = "205" ] || fail "stock inicial esperado 205, es '$STOCK_BEFORE'"

edit_purchase() {  # $1 = cantidad nueva
  psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
DO \$\$
DECLARE v_sqlstate text; v_msg text; v_res jsonb;
BEGIN
  BEGIN
    v_res := public.rpc_atomic_update_purchase_operation(
      ARRAY['$RACE_purchase'::uuid], CURRENT_DATE, 'edit concurrente',
      jsonb_build_array(jsonb_build_object('product_id', '$RACE_product'::uuid, 'amount', 100.00, 'quantity', $1)));
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

A_OUT=$(mktemp)
psql "$DB_URL" -X -q -t -A > "$A_OUT" 2>&1 <<SQL &
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
SELECT 'A_OK=' || (public.rpc_atomic_update_purchase_operation(
  ARRAY['$RACE_purchase'::uuid], CURRENT_DATE, 'edit A',
  jsonb_build_array(jsonb_build_object('product_id', '$RACE_product'::uuid, 'amount', 100.00, 'quantity', 3)))->>'operation_id');
SELECT pg_advisory_xact_lock($ADVISORY_KEY);
$A_WAIT
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesion A: edicion de la compra ABIERTA (cantidad 5 -> 3, sin commitear)"
B_OUT=$(edit_purchase 4)
wait "$A_PID" 2>/dev/null; A_PID=""
grep -q 'A_OK=' "$A_OUT" || fail "(c): la edicion de la sesion A no termino bien. Salida: $(cat "$A_OUT")"

echo "$B_OUT" | grep -qiE 'deadlock|40P01' && fail "(c): apareció un deadlock. Salida: $B_OUT"

echo "$B_OUT" | grep -q 'EDIT_ERR sqlstate=P0404' \
  || fail "(c): la segunda edicion de la MISMA compra debia esperar a la primera, recontar las filas y levantar P0404 (ya no existen). Salida de B: $B_OUT"

LINES=$(q "SELECT count(*) FROM public.purchases WHERE account_id = '$ACCOUNT_ID' AND description LIKE 'edit%';")
[ "$LINES" = "1" ] || fail "(c): la operacion debia quedar con UNA linea (la edicion de A), tiene $LINES: las dos ediciones aplicaron"
STOCK_AFTER=$(q "SELECT quantity::int FROM public.branch_stock WHERE account_id = '$ACCOUNT_ID' AND product_id = '$RACE_product';")
[ "$STOCK_AFTER" = "203" ] || fail "(c): el stock debia quedar en 203 (205 - 5 + 3, UNA edicion) y quedo en $STOCK_AFTER"
echo "PASS (c): dos ediciones concurrentes de la misma compra: la segunda espera, recuenta y levanta P0404; estado final de UNA sola edicion (1 linea, stock 203)."

# ═════════════════════════════════════════════════════════════════════════════
# (e) GASTO — lost update
# ═════════════════════════════════════════════════════════════════════════════
edit_expense_amount() {
  psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
DO \$\$
DECLARE v_sqlstate text; v_msg text;
BEGIN
  BEGIN
    PERFORM public.rpc_update_expense('$RACE_expense'::uuid, p_amount => 999);
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

A_OUT=$(mktemp)
psql "$DB_URL" -X -q -t -A > "$A_OUT" 2>&1 <<SQL &
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
SELECT 'A_OK=' || (public.rpc_update_expense('$RACE_expense'::uuid, p_description => 'desc de A')->>'expense_id');
SELECT pg_advisory_xact_lock($ADVISORY_KEY);
$A_WAIT
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesion A: edicion del gasto ABIERTA (descripcion, sin commitear)"
B_OUT=$(edit_expense_amount)
wait "$A_PID" 2>/dev/null; A_PID=""
grep -q 'A_OK=' "$A_OUT" || fail "(e): la edicion de la sesion A no termino bien. Salida: $(cat "$A_OUT")"
echo "$B_OUT" | grep -q 'EDIT_OK' || fail "(e): la edicion de B (solo el importe) debia terminar OK. Salida: $B_OUT"

ROW=$(q "SELECT description || '|' || amount::int FROM public.expenses WHERE id = '$RACE_expense';")
[ "$ROW" = "desc de A|999" ] \
  || fail "(e): lost update: se esperaba 'desc de A|999' (las DOS ediciones) y quedo '$ROW' — B pisó la descripcion de A con el valor viejo que leyó sin bloquear la fila"
echo "PASS (e): dos ediciones concurrentes del mismo gasto: la segunda lee el resultado de la primera (descripcion de A + importe de B)."

cleanup
[ "$(q "SELECT count(*) FROM auth.users WHERE email = 'edicion-locks-race@test.local';")" = "0" ] || fail "cleanup: quedo el anchor"
echo "PASS: gate edicion-locks-race completo y sin residuo."
