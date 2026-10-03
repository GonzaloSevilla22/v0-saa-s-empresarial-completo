#!/usr/bin/env bash
# =============================================================================
# GATE: test_remitos_venta_race.sh
# CHANGE: remitos-venta, TANDA A (20261069000001), tasks.md 1.1 / 6.9 (las
#         carreras que no dependen de la conversión se adelantan a esta tanda).
#
# Carreras con DOS conexiones reales y bloqueo VERIFICADO en pg_stat_activity
# antes de soltar a la primera (sin sleeps a ciegas; molde de
# test_presupuesto_a_venta_race.sh). A ejecuta su operación y queda con la
# transacción abierta esperando un advisory; B arranca y tiene que quedar
# bloqueada en un lock de fila/transacción detrás de A; recién entonces se
# suelta a A.
#
#   (1)  dos emisiones por la ÚLTIMA unidad (claves distintas) -> la segunda
#        espera el lock del producto y recibe P0409 stock_insuficiente; un solo
#        remito, stock en 0;
#   (2)  dos emisiones con la MISMA clave de idempotencia (doble clic) -> la
#        segunda espera en el ON CONFLICT y devuelve el MISMO remito con
#        replayed = true (nunca un 500 por 23505); un solo descuento;
#   (3a) edición abierta vs anulación -> la anulación espera el FOR UPDATE del
#        remito y recibe delivery_note_changed;
#   (3b) anulación abierta vs edición -> la edición recibe
#        delivery_note_invalid_state; en los dos casos Σ quantity_delta del
#        remito = Δ branch_stock;
#   (4a) baja del producto abierta vs emisión -> la emisión espera el lock del
#        producto y, al validar sobre la fila ya bloqueada, recibe P0404
#        product_not_found sin efectos;
#   (4b) emisión abierta vs baja del producto -> la baja espera y el remito
#        queda emitido con el producto vivo al momento del lock.
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_remitos_venta_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961069001
TMP_DIR="$(mktemp -d)"
RUN="rvrace$$"

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
  echo "GATE REMITOS-VENTA-RACE FAILED: $*" >&2
  for f in "$TMP_DIR"/*; do
    [ -f "$f" ] && { echo "--- $(basename "$f") ---" >&2; grep -v 'send_email_log_webhook' "$f" | head -20 >&2; }
  done
  cleanup
  exit 1
}

# ── Fixture: cuenta real vía handle_new_user (owner), cliente, productos ──────
EMAIL="remitos-venta-race-$RUN@test.local"
psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A >/dev/null <<SQL || fail "no se pudo armar el fixture"
DO \$\$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
  v_p       uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', '$EMAIL', now(), now(),
          jsonb_build_object('name', 'Gate RV Race', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta'; END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_account, 'Cliente RV Race');
  -- LAST: una sola unidad (1). IDEM: 10 (2). EDIT: 100 (3a/3b). DEL1: 0 (4a). DEL2: 1 (4b).
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'RV Race Última', 'RV-RACE-LAST', 10, 100) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_p, v_branch, 1);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'RV Race Idem', 'RV-RACE-IDEM', 10, 100) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_p, v_branch, 10);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'RV Race Edit', 'RV-RACE-EDIT', 10, 100) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_p, v_branch, 100);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'RV Race Baja 1', 'RV-RACE-DEL1', 10, 100);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'RV Race Baja 2', 'RV-RACE-DEL2', 10, 100) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_p, v_branch, 1);
END \$\$;
SQL
USER_ID=$(q "SELECT id FROM auth.users WHERE email = '$EMAIL';")
[ -n "$USER_ID" ] || fail "el fixture no creó el usuario"
ACCOUNT_ID=$(q "SELECT account_id FROM public.account_members WHERE user_id = '$USER_ID' ORDER BY created_at LIMIT 1;")
CLIENT_ID=$(q "SELECT id FROM public.clients WHERE account_id = '$ACCOUNT_ID' LIMIT 1;")
BRANCH_ID=$(q "SELECT id FROM public.branches WHERE account_id = '$ACCOUNT_ID' ORDER BY created_at LIMIT 1;")
P_LAST=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RV-RACE-LAST';")
P_IDEM=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RV-RACE-IDEM';")
P_EDIT=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RV-RACE-EDIT';")
P_DEL1=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RV-RACE-DEL1';")
P_DEL2=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RV-RACE-DEL2';")
[ -n "$ACCOUNT_ID" ] && [ -n "$CLIENT_ID" ] && [ -n "$BRANCH_ID" ] && [ -n "$P_LAST" ] && [ -n "$P_IDEM" ] \
  && [ -n "$P_EDIT" ] && [ -n "$P_DEL1" ] && [ -n "$P_DEL2" ] || fail "el fixture no devolvió cuenta/cliente/sucursal/productos"

CLAIMS="SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);"

stock() { q "SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = '$1' AND branch_id = '$BRANCH_ID'), 0);"; }

issue_sql() {  # $1 = clave, $2 = producto, $3 = cantidad
  echo "SELECT 'RES=' || public.rpc_create_sale_delivery_note('$1', '$CLIENT_ID'::uuid, '$BRANCH_ID'::uuid, NULL, NULL,
          jsonb_build_array(jsonb_build_object('product_id', '$2'::uuid, 'unit_id', NULL,
            'quantity', $3, 'price', 100, 'subtotal', $3 * 100)))::text;"
}
update_sql() { # $1 = remito, $2 = versión, $3 = producto, $4 = cantidad
  echo "SELECT 'RES=' || public.rpc_update_delivery_note('$1'::uuid, $2, '$CLIENT_ID'::uuid, '$BRANCH_ID'::uuid, NULL, NULL,
          jsonb_build_array(jsonb_build_object('product_id', '$3'::uuid, 'unit_id', NULL,
            'quantity', $4, 'price', 100, 'subtotal', $4 * 100)))::text;"
}
cancel_sql() { # $1 = remito, $2 = versión
  echo "SELECT 'RES=' || public.rpc_cancel_delivery_note('$1'::uuid, $2, 'carrera')::text;"
}
delete_product_sql() { # $1 = producto
  echo "UPDATE public.products SET deleted_at = now() WHERE id = '$1'; SELECT 'RES=product_deleted';"
}

# Alta fuera de carrera. Devuelve el id del remito.
new_note() {  # $1 = clave, $2 = producto, $3 = cantidad
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<SQL | grep -o '"id": "[0-9a-f-]*"' | head -1 | grep -o '[0-9a-f-]\{36\}'
BEGIN;
$CLAIMS
$(issue_sql "$1" "$2" "$3")
COMMIT;
SQL
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
  echo "[$name] A: $(grep -v send_email_log_webhook "$TMP_DIR/$name.a" | tr '\n' ' ' | cut -c1-160)"
  echo "[$name] B: $(grep -v send_email_log_webhook "$TMP_DIR/$name.b" | tr '\n' ' ' | cut -c1-160)"
}

sum_delta() { q "SELECT COALESCE(sum(quantity_delta), 0) FROM public.stock_movements WHERE reference_id = '$1';"; }
notes_of() { q "SELECT count(*) FROM public.delivery_note_items WHERE product_id = '$1';"; }

# ── (1) dos emisiones por la última unidad ───────────────────────────────────
race "1" "$(issue_sql "${RUN}-1-A" "$P_LAST" 1)" "$(issue_sql "${RUN}-1-B" "$P_LAST" 1)"
grep -q '"replayed": false' "$TMP_DIR/1.a" || fail "(1) A no emitió"
grep -q 'stock_insuficiente' "$TMP_DIR/1.b" || fail "(1) B debía recibir P0409 stock_insuficiente"
[ "$(notes_of "$P_LAST")" = "1" ] || fail "(1) se esperaba exactamente un remito con la última unidad"
[ "$(stock "$P_LAST")" = "0.0000" ] || [ "$(stock "$P_LAST")" = "0" ] || fail "(1) el stock debía quedar en 0, quedó $(stock "$P_LAST")"
echo "PASS (1): dos emisiones por la última unidad -> un remito; la otra esperó el lock del producto y recibió stock_insuficiente."

# ── (2) misma clave (doble clic) ─────────────────────────────────────────────
race "2" "$(issue_sql "${RUN}-2" "$P_IDEM" 2)" "$(issue_sql "${RUN}-2" "$P_IDEM" 2)"
A_ID=$(grep -o '"id": "[0-9a-f-]*"' "$TMP_DIR/2.a" | head -1)
B_ID=$(grep -o '"id": "[0-9a-f-]*"' "$TMP_DIR/2.b" | head -1)
grep -q '"replayed": false' "$TMP_DIR/2.a" || fail "(2) A no emitió"
grep -q '"replayed": true' "$TMP_DIR/2.b" || fail "(2) B debía recibir el replay (nunca un 23505)"
[ -n "$A_ID" ] && [ "$A_ID" = "$B_ID" ] || fail "(2) el replay devolvió otro remito ($A_ID vs $B_ID)"
[ "$(notes_of "$P_IDEM")" = "1" ] || fail "(2) se esperaba exactamente un remito"
S=$(stock "$P_IDEM"); [ "${S%%.*}" = "8" ] || fail "(2) el stock debía bajar una sola vez (10 -> 8), quedó $S"
echo "PASS (2): doble clic con la misma clave -> B esperó en el ON CONFLICT y devolvió el mismo remito con replayed = true; un solo descuento."

# ── (3a) edición abierta vs anulación ────────────────────────────────────────
R3A=$(new_note "${RUN}-3a" "$P_EDIT" 3)
[ -n "$R3A" ] || fail "no se emitió el remito de (3a)"
S0=$(stock "$P_EDIT")
race "3a" "$(update_sql "$R3A" 1 "$P_EDIT" 5)" "$(cancel_sql "$R3A" 1)"
grep -q '"revision": 2' "$TMP_DIR/3a.a" || fail "(3a) A no editó"
grep -q 'delivery_note_changed' "$TMP_DIR/3a.b" || fail "(3a) la anulación debía recibir delivery_note_changed"
[ "$(q "SELECT status FROM public.delivery_notes WHERE id = '$R3A';")" = "issued" ] || fail "(3a) el remito no debía quedar anulado"
S1=$(stock "$P_EDIT")
[ "$(q "SELECT ($S1 - $S0) = -2 AND $(sum_delta "$R3A") = -5;")" = "t" ] || fail "(3a) Δ stock $S0 -> $S1 / Σ delta $(sum_delta "$R3A") no cuadran con la edición 3 -> 5"
echo "PASS (3a): edición abierta vs anulación -> la anulación esperó el FOR UPDATE y recibió delivery_note_changed; Σ delta = -retenido."

# ── (3b) anulación abierta vs edición ────────────────────────────────────────
R3B=$(new_note "${RUN}-3b" "$P_EDIT" 4)
[ -n "$R3B" ] || fail "no se emitió el remito de (3b)"
S0=$(stock "$P_EDIT")
race "3b" "$(cancel_sql "$R3B" 1)" "$(update_sql "$R3B" 1 "$P_EDIT" 1)"
grep -q '"status": "canceled"' "$TMP_DIR/3b.a" || fail "(3b) A no anuló"
grep -q 'delivery_note_invalid_state' "$TMP_DIR/3b.b" || fail "(3b) la edición debía recibir delivery_note_invalid_state"
S1=$(stock "$P_EDIT")
[ "$(q "SELECT ($S1 - $S0) = 4 AND $(sum_delta "$R3B") = 0;")" = "t" ] || fail "(3b) la anulación debía reponer exactamente 4 una vez y cerrar el ledger en 0 ($S0 -> $S1, Σ $(sum_delta "$R3B"))"
echo "PASS (3b): anulación abierta vs edición -> la edición recibió delivery_note_invalid_state; stock repuesto una sola vez, ledger en 0."

# ── (4a) baja del producto abierta vs emisión ────────────────────────────────
race "4a" "$(delete_product_sql "$P_DEL1")" "$(issue_sql "${RUN}-4a" "$P_DEL1" 1)"
grep -q 'RES=product_deleted' "$TMP_DIR/4a.a" || fail "(4a) A no dio de baja el producto"
grep -q 'product_not_found' "$TMP_DIR/4a.b" || fail "(4a) la emisión debía recibir P0404 product_not_found"
[ "$(notes_of "$P_DEL1")" = "0" ] || fail "(4a) quedó un remito con un producto dado de baja"
echo "PASS (4a): baja del producto abierta vs emisión -> la emisión esperó el lock y, validando sobre la fila bloqueada, recibió product_not_found sin efectos."

# ── (4b) emisión abierta vs baja del producto ────────────────────────────────
race "4b" "$(issue_sql "${RUN}-4b" "$P_DEL2" 1)" "$(delete_product_sql "$P_DEL2")"
grep -q '"replayed": false' "$TMP_DIR/4b.a" || fail "(4b) A no emitió"
grep -q 'RES=product_deleted' "$TMP_DIR/4b.b" || fail "(4b) la baja debía proceder después de la emisión (stock en 0)"
[ "$(notes_of "$P_DEL2")" = "1" ] || fail "(4b) el remito debía quedar emitido"
echo "PASS (4b): emisión abierta vs baja -> la baja esperó al remito, que quedó emitido con el producto vivo al momento del lock."

# Ningún remito sin número, todos correlativos.
[ "$(q "SELECT count(*) = max(number) AND count(*) = count(DISTINCT number) FROM public.delivery_notes WHERE account_id = '$ACCOUNT_ID';")" = "t" ] \
  || fail "la numeración de los remitos de la carrera tiene huecos o repetidos"

cleanup
LEFT=$(q "SELECT count(*) FROM auth.users WHERE id = '$USER_ID';")
[ "$LEFT" = "0" ] || { echo "GATE REMITOS-VENTA-RACE FAILED: quedó el usuario del fixture" >&2; exit 1; }
echo "GATE REMITOS-VENTA-RACE PASSED: 6 carreras con bloqueo real verificado (residuo cero)."
