#!/usr/bin/env bash
# =============================================================================
# GATE: test_presupuesto_a_venta_race.sh
# CHANGE: presupuestos-modulo, TANDA B (20261068000001), tasks.md 6.2 —
#         rpc_convert_quote_to_sale con DOS conexiones reales.
#
# ESTO NO SE PUEDE PROBAR EN UN SOLO .sql: una sesión nunca bloquea contra su
# propio lock. Cada caso sigue el mismo guion determinista (sin sleeps a
# ciegas):
#   1. un "portero" toma un advisory lock EXCLUSIVO;
#   2. la sesión A ejecuta su operación y, con la transacción ABIERTA, pide el
#      advisory en modo compartido: queda esperando con sus locks tomados;
#   3. la sesión B lanza su operación y el script espera a verla BLOQUEADA en
#      un lock de fila/transacción (pg_stat_activity.wait_event_type = 'Lock',
#      distinto de 'advisory'). Si B nunca se bloquea, no hubo carrera y el
#      gate FALLA;
#   4. se termina al portero: A commitea y B sigue.
#
# Casos (design.md D6 / D2):
#   (1a) mismo presupuesto, claves distintas -> A vende, B recibe
#        quote_invalid_state (esperó el FOR UPDATE del presupuesto);
#   (1b) mismo presupuesto, MISMA clave (doble clic) -> B hace replay
#        (replayed = true, misma venta): la idempotencia se lee después del lock;
#   (2)  la MISMA clave sobre DOS presupuestos distintos -> A vende; B espera en
#        el ON CONFLICT de operation_idempotency del núcleo de venta, recibe el
#        replay ajeno y lo convierte en P0409 idempotency_key_conflict: su
#        presupuesto sigue en sent y no queda ninguna orden draft;
#   (3a) conversión abierta vs borrado del mismo draft nunca enviado -> la venta
#        queda con su presupuesto accepted y enlazado; el borrado recibe
#        quote_not_deletable;
#   (3b) borrado abierto vs conversión -> el presupuesto se borra y la
#        conversión recibe quote_not_found;
#   (4)  DOS conversiones simultáneas de presupuestos DISTINTOS que comparten
#        dos productos (claves distintas, ROUNDS rondas con barrera): ninguna
#        puede terminar en deadlock (40P01). El núcleo de venta bloquea los
#        productos en el orden de sales_order_items.id (un uuid aleatorio por
#        orden), así que dos órdenes con los mismos dos productos los toman en
#        orden inverso; la conversión toma ella los productos por id ascendente
#        ANTES de entrar al núcleo para que ese orden sea el mismo en todas;
#   y en ningún caso existe una orden con source_quote_id NULL.
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_presupuesto_a_venta_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961068001
TMP_DIR="$(mktemp -d)"
RUN="pvrace$$"

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

USER_ID=""
ACCOUNT_ID=""
GATE_PID=""

cleanup() {
  [ -n "${GATE_PID:-}" ] && kill "$GATE_PID" 2>/dev/null
  psql "$DB_URL" -X -q -t -A -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name LIKE '${RUN}%' AND pid <> pg_backend_pid();" >/dev/null 2>&1
  if [ -n "$ACCOUNT_ID" ]; then
    psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL
DO \$\$
DECLARE v_account uuid := '$ACCOUNT_ID'; v_user uuid := '$USER_ID'; v_table text;
BEGIN
  SET session_replication_role = replica;
  DELETE FROM public.cash_movements WHERE session_id IN (
    SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account);
  DELETE FROM public.cash_sessions WHERE cashbox_id IN (
    SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account);
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account);
  FOR v_table IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = \$1', v_table) USING v_account;
  END LOOP;
  DELETE FROM public.accounts              WHERE id = v_account;
  DELETE FROM public.account_members       WHERE user_id = v_user;
  DELETE FROM public.profiles              WHERE id = v_user;
  DELETE FROM public.email_logs            WHERE user_id = v_user;
  DELETE FROM public.analytics_events      WHERE user_id = v_user;
  DELETE FROM public.operation_idempotency WHERE user_id = v_user;
  DELETE FROM auth.users                   WHERE id = v_user;
  SET session_replication_role = DEFAULT;
END \$\$;
SQL
  fi
  rm -rf "$TMP_DIR"
}

fail() {
  echo "GATE PRESUPUESTO-A-VENTA-RACE FAILED: $*" >&2
  for f in "$TMP_DIR"/*; do
    [ -f "$f" ] && { echo "--- $(basename "$f") ---" >&2; grep -v 'send_email_log_webhook' "$f" | head -20 >&2; }
  done
  cleanup
  exit 1
}

# ── Fixture: cuenta real vía handle_new_user, cliente, producto con stock ─────
EMAIL="presupuesto-a-venta-race-$RUN@test.local"
psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A >/dev/null <<SQL || fail "no se pudo armar el fixture"
DO \$\$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
  v_product uuid;
  v_product2 uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', '$EMAIL', now(), now(),
          jsonb_build_object('name', 'Gate PV Race', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta'; END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_account, 'Cliente PV Race');
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'Producto PV Race', 'PV-RACE-1', 10, 100) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 1000);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'Producto PV Race 2', 'PV-RACE-2', 10, 100) RETURNING id INTO v_product2;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product2, v_branch, 1000);
END \$\$;
SQL
USER_ID=$(q "SELECT id FROM auth.users WHERE email = '$EMAIL';")
[ -n "$USER_ID" ] || fail "el fixture no creó el usuario"
ACCOUNT_ID=$(q "SELECT account_id FROM public.account_members WHERE user_id = '$USER_ID' ORDER BY created_at LIMIT 1;")
CLIENT_ID=$(q "SELECT id FROM public.clients WHERE account_id = '$ACCOUNT_ID' LIMIT 1;")
PRODUCT_ID=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'PV-RACE-1';")
PRODUCT2_ID=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'PV-RACE-2';")
PM_CREDIT=$(q "SELECT id FROM public.payment_methods WHERE account_id = '$ACCOUNT_ID' AND kind = 'credit' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;")
[ -n "$ACCOUNT_ID" ] && [ -n "$CLIENT_ID" ] && [ -n "$PRODUCT_ID" ] && [ -n "$PRODUCT2_ID" ] && [ -n "$PM_CREDIT" ] || fail "el fixture no devolvió cuenta/cliente/producto/forma de pago"

CLAIMS="SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);"

# Alta de un presupuesto por la RPC (enviado o no). Devuelve el id.
new_quote() {
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<SQL | grep -o 'QID=[0-9a-f-]*' | sed 's/QID=//'
BEGIN;
$CLAIMS
WITH q AS (
  SELECT (public.rpc_create_quote('$CLIENT_ID'::uuid, NULL, NULL, NULL,
           jsonb_build_array(jsonb_build_object('product_id', '$PRODUCT_ID'::uuid, 'unit_id', NULL,
             'quantity', 1, 'price', 100, 'subtotal', 100, 'description', NULL)))->>'id')::uuid AS id)
SELECT 'QID=' || id FROM q;
COMMIT;
SQL
}
send_quote() {
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A >/dev/null <<SQL
BEGIN;
$CLAIMS
SELECT public.rpc_transition_quote('$1'::uuid, 'sent', NULL);
COMMIT;
SQL
}

convert_sql() {  # $1 = clave, $2 = presupuesto
  echo "SELECT 'RES=' || public.rpc_convert_quote_to_sale('$1', '$2'::uuid, 1, '$PM_CREDIT'::uuid, NULL, NULL, NULL, NULL)::text;"
}
delete_sql() {   # $1 = presupuesto
  echo "SELECT 'RES=deleted' FROM (SELECT public.rpc_delete_quote('$1'::uuid)) d;"
}

wait_for() {  # $1 = condición SQL (boolean), $2 = descripción
  local ok=""
  for _ in $(seq 1 400); do
    ok=$(q "SELECT ($1)::text;")
    [ "$ok" = "true" ] && return 0
    q "SELECT pg_sleep(0.05);" >/dev/null
  done
  fail "timeout esperando: $2"
}

# Corre un caso: A ejecuta $2 y queda con la transacción abierta; B ejecuta $3
# y debe bloquearse en un lock de fila/transacción antes de soltar a A.
race() {
  local name="$1" sql_a="$2" sql_b="$3"
  PGAPPNAME="${RUN}-gate" psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
SELECT pg_advisory_lock($ADVISORY_KEY);
SELECT pg_sleep(120);
SQL
  GATE_PID=$!
  wait_for "EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted)" "el portero de $name"

  PGAPPNAME="${RUN}-a" psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A > "$TMP_DIR/$name.a" 2>&1 <<SQL &
SET statement_timeout = '60s';
BEGIN;
$CLAIMS
$sql_a
SELECT pg_advisory_xact_lock_shared($ADVISORY_KEY);
COMMIT;
SQL
  local pid_a=$!
  wait_for "EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '${RUN}-a' AND wait_event = 'advisory')" "que A termine su operación y retenga sus locks ($name)"

  PGAPPNAME="${RUN}-b" psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A > "$TMP_DIR/$name.b" 2>&1 <<SQL &
SET statement_timeout = '60s';
BEGIN;
$CLAIMS
$sql_b
COMMIT;
SQL
  local pid_b=$!
  wait_for "EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '${RUN}-b' AND wait_event_type = 'Lock' AND wait_event <> 'advisory')" "que B quede bloqueada detrás de A ($name): sin bloqueo no hay carrera"

  q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '${RUN}-gate';" >/dev/null
  wait "$GATE_PID" 2>/dev/null
  GATE_PID=""
  wait "$pid_a" 2>/dev/null
  wait "$pid_b" 2>/dev/null
  echo "[$name] A: $(tr '\n' ' ' < "$TMP_DIR/$name.a" | cut -c1-200)"
  echo "[$name] B: $(tr '\n' ' ' < "$TMP_DIR/$name.b" | cut -c1-200)"
}

res_json() { grep -o 'RES=.*' "$1" | head -1 | sed 's/^RES=//'; }

# ── (1a) mismo presupuesto, claves distintas ─────────────────────────────────
Q1=$(new_quote); send_quote "$Q1"
[ -n "$Q1" ] || fail "no se creó el presupuesto de (1a)"
race "1a" "$(convert_sql "${RUN}-1a-A" "$Q1")" "$(convert_sql "${RUN}-1a-B" "$Q1")"
grep -q '"replayed": false' "$TMP_DIR/1a.a" || fail "(1a) A no vendió"
grep -q 'quote_invalid_state' "$TMP_DIR/1a.b" || fail "(1a) B debía recibir quote_invalid_state"
[ "$(q "SELECT count(*) FROM public.sales_orders WHERE source_quote_id = '$Q1';")" = "1" ] || fail "(1a) se esperaba exactamente una orden del presupuesto"
[ "$(q "SELECT count(*) FROM public.events WHERE event_type = 'QuoteAccepted' AND aggregate_id = '$Q1';")" = "1" ] || fail "(1a) se esperaba un solo QuoteAccepted"
[ "$(q "SELECT status FROM public.quotes WHERE id = '$Q1';")" = "accepted" ] || fail "(1a) el presupuesto no quedó accepted"
echo "PASS (1a): dos conversiones del mismo presupuesto con claves distintas -> una venta, un accepted, un QuoteAccepted; la otra esperó el lock y recibió quote_invalid_state."

# ── (1b) mismo presupuesto, misma clave (doble clic) ─────────────────────────
Q2=$(new_quote); send_quote "$Q2"
race "1b" "$(convert_sql "${RUN}-1b" "$Q2")" "$(convert_sql "${RUN}-1b" "$Q2")"
A_ORDER=$(res_json "$TMP_DIR/1b.a" | grep -o '"sales_order_id": "[0-9a-f-]*"')
B_ORDER=$(res_json "$TMP_DIR/1b.b" | grep -o '"sales_order_id": "[0-9a-f-]*"')
grep -q '"replayed": false' "$TMP_DIR/1b.a" || fail "(1b) A no vendió"
grep -q '"replayed": true' "$TMP_DIR/1b.b" || fail "(1b) B debía recibir el replay"
[ -n "$A_ORDER" ] && [ "$A_ORDER" = "$B_ORDER" ] || fail "(1b) el replay devolvió otra orden ($A_ORDER vs $B_ORDER)"
[ "$(q "SELECT count(*) FROM public.sales_orders WHERE source_quote_id = '$Q2';")" = "1" ] || fail "(1b) se esperaba exactamente una orden"
echo "PASS (1b): doble clic con la misma clave -> B esperó el lock, leyó la clave después y devolvió la misma venta con replayed = true."

# ── (2) misma clave sobre dos presupuestos distintos ─────────────────────────
Q3=$(new_quote); send_quote "$Q3"
Q4=$(new_quote); send_quote "$Q4"
race "2" "$(convert_sql "${RUN}-2" "$Q3")" "$(convert_sql "${RUN}-2" "$Q4")"
grep -q '"replayed": false' "$TMP_DIR/2.a" || fail "(2) A no vendió"
grep -q 'idempotency_key_conflict' "$TMP_DIR/2.b" || fail "(2) B debía recibir idempotency_key_conflict"
[ "$(q "SELECT status FROM public.quotes WHERE id = '$Q4';")" = "sent" ] || fail "(2) el presupuesto de B cambió de estado"
[ "$(q "SELECT count(*) FROM public.sales_orders WHERE source_quote_id = '$Q4';")" = "0" ] || fail "(2) quedó una orden del presupuesto de B"
[ "$(q "SELECT count(*) FROM public.sales_orders WHERE account_id = '$ACCOUNT_ID' AND status = 'draft';")" = "0" ] || fail "(2) quedó una orden draft"
[ "$(q "SELECT count(*) FROM public.events WHERE event_type = 'QuoteAccepted' AND aggregate_id = '$Q4';")" = "0" ] || fail "(2) quedó un QuoteAccepted del presupuesto de B"
echo "PASS (2): la misma clave en paralelo sobre dos presupuestos -> una venta; la otra recibió idempotency_key_conflict, su presupuesto sigue en sent y no quedó ninguna orden draft."

# ── (3a) conversión abierta vs borrado ───────────────────────────────────────
Q5=$(new_quote)
race "3a" "$(convert_sql "${RUN}-3a" "$Q5")" "$(delete_sql "$Q5")"
grep -q '"replayed": false' "$TMP_DIR/3a.a" || fail "(3a) A no vendió"
grep -q 'quote_not_deletable' "$TMP_DIR/3a.b" || fail "(3a) el borrado debía recibir quote_not_deletable"
[ "$(q "SELECT status FROM public.quotes WHERE id = '$Q5';")" = "accepted" ] || fail "(3a) el presupuesto no quedó accepted"
[ "$(q "SELECT count(*) FROM public.sales_orders WHERE source_quote_id = '$Q5' AND status = 'confirmed';")" = "1" ] || fail "(3a) la venta perdió su presupuesto de origen"
echo "PASS (3a): conversión abierta vs borrado del mismo draft -> la venta queda con su presupuesto accepted y enlazado; el borrado recibió quote_not_deletable."

# ── (3b) borrado abierto vs conversión ───────────────────────────────────────
Q6=$(new_quote)
race "3b" "$(delete_sql "$Q6")" "$(convert_sql "${RUN}-3b" "$Q6")"
grep -q 'RES=deleted' "$TMP_DIR/3b.a" || fail "(3b) A no borró"
grep -q 'quote_not_found' "$TMP_DIR/3b.b" || fail "(3b) la conversión debía recibir quote_not_found"
[ "$(q "SELECT count(*) FROM public.quotes WHERE id = '$Q6';")" = "0" ] || fail "(3b) el presupuesto no se borró"
echo "PASS (3b): borrado abierto vs conversión -> el presupuesto se borra y la conversión recibe quote_not_found."

# ── (4) dos presupuestos distintos con los mismos dos productos, a la vez ────
# Barrera: las dos sesiones esperan un advisory compartido que el portero
# retiene en exclusivo; al soltarlo arrancan juntas. Cada ronda usa dos
# presupuestos nuevos y dos claves distintas. Nadie se bloquea "a propósito":
# lo que se mide es que el orden de los locks de producto no deje un deadlock.
ROUNDS="${ROUNDS:-12}"
new_quote2() {
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<SQL | grep -o 'QID=[0-9a-f-]*' | sed 's/QID=//'
BEGIN;
$CLAIMS
WITH q AS (
  SELECT (public.rpc_create_quote('$CLIENT_ID'::uuid, NULL, NULL, NULL,
           jsonb_build_array(
             jsonb_build_object('product_id', '$PRODUCT_ID'::uuid, 'unit_id', NULL,
               'quantity', 1, 'price', 100, 'subtotal', 100, 'description', NULL),
             jsonb_build_object('product_id', '$PRODUCT2_ID'::uuid, 'unit_id', NULL,
               'quantity', 1, 'price', 100, 'subtotal', 100, 'description', NULL)))->>'id')::uuid AS id)
SELECT 'QID=' || id FROM q;
COMMIT;
SQL
}
DEADLOCKS=0
SOLD=0
for r in $(seq 1 "$ROUNDS"); do
  QA=$(new_quote2); send_quote "$QA"
  QB=$(new_quote2); send_quote "$QB"
  [ -n "$QA" ] && [ -n "$QB" ] || fail "(4) no se crearon los presupuestos de la ronda $r"
  PGAPPNAME="${RUN}-gate" psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
SELECT pg_advisory_lock($ADVISORY_KEY);
SELECT pg_sleep(120);
SQL
  GATE_PID=$!
  wait_for "EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted)" "el portero de (4) ronda $r"
  for side in a b; do
    if [ "$side" = "a" ]; then QX="$QA"; else QX="$QB"; fi
    PGAPPNAME="${RUN}-4$side" psql "$DB_URL" -X -q -t -A > "$TMP_DIR/4.$r.$side" 2>&1 <<SQL &
SET statement_timeout = '60s';
BEGIN;
$CLAIMS
SELECT pg_advisory_xact_lock_shared($ADVISORY_KEY);
$(convert_sql "${RUN}-4-$r-$side" "$QX")
COMMIT;
SQL
    eval "PID_$side=$!"
  done
  wait_for "(SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('${RUN}-4a', '${RUN}-4b') AND wait_event = 'advisory') = 2" "que las dos sesiones de (4) esperen la barrera (ronda $r)"
  q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '${RUN}-gate';" >/dev/null
  wait "$GATE_PID" 2>/dev/null
  GATE_PID=""
  wait "$PID_a" 2>/dev/null
  wait "$PID_b" 2>/dev/null
  for side in a b; do
    if grep -q '40P01\|deadlock detected' "$TMP_DIR/4.$r.$side"; then
      DEADLOCKS=$((DEADLOCKS + 1))
      echo "[4] ronda $r lado $side: $(tr '\n' ' ' < "$TMP_DIR/4.$r.$side" | cut -c1-160)"
    elif grep -q '"replayed": false' "$TMP_DIR/4.$r.$side"; then
      SOLD=$((SOLD + 1))
    else
      fail "(4) ronda $r lado $side: resultado inesperado: $(tr '\n' ' ' < "$TMP_DIR/4.$r.$side" | cut -c1-200)"
    fi
  done
done
[ "$DEADLOCKS" = "0" ] || fail "(4) $DEADLOCKS conversiones terminaron en deadlock (40P01) sobre $ROUNDS rondas"
[ "$SOLD" = "$((ROUNDS * 2))" ] || fail "(4) se esperaban $((ROUNDS * 2)) ventas y hubo $SOLD"
echo "PASS (4): $ROUNDS rondas de dos conversiones simultáneas de presupuestos distintos con los mismos dos productos -> $SOLD ventas, ningún deadlock."

[ "$(q "SELECT count(*) FROM public.sales_orders WHERE account_id = '$ACCOUNT_ID' AND source_quote_id IS NULL;")" = "0" ] || fail "quedó una orden con source_quote_id NULL"
[ "$(q "SELECT count(*) FROM public.sales_orders WHERE account_id = '$ACCOUNT_ID';")" = "$((4 + ROUNDS * 2))" ] || fail "se esperaban exactamente $((4 + ROUNDS * 2)) órdenes (1a, 1b, 2, 3a y las de (4))"

cleanup
LEFT=$(q "SELECT count(*) FROM auth.users WHERE id = '$USER_ID';")
[ "$LEFT" = "0" ] || { echo "GATE PRESUPUESTO-A-VENTA-RACE FAILED: quedó el usuario del fixture" >&2; exit 1; }
echo "GATE PRESUPUESTO-A-VENTA-RACE PASSED: 5 carreras con bloqueo real verificado + el caso de deadlock (4), ninguna orden sin presupuesto de origen (residuo cero)."
