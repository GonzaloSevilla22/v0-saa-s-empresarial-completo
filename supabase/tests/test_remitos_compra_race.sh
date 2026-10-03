#!/usr/bin/env bash
# =============================================================================
# GATE: test_remitos_compra_race.sh
# CHANGE: remitos-compra, TANDA A (20261071000001), tasks.md 1.1 / 6.10 — las
#         carreras de design.md §D16 que no dependen de la conversión.
#
# Carreras con DOS conexiones reales y bloqueo VERIFICADO en pg_stat_activity
# antes de soltar a la primera (sin sleeps a ciegas; molde de
# test_remitos_venta_race.sh). A ejecuta su operación y queda con la
# transacción abierta esperando un advisory; B arranca y tiene que quedar
# bloqueada en un lock de fila/transacción detrás de A; recién entonces se
# suelta a A.
#
#   (1)  dos recepciones del mismo producto (claves distintas) -> la segunda
#        espera el lock del producto y las dos suman: stock +a+b, dos remitos
#        con números RC distintos;
#   (2)  dos recepciones con la MISMA clave (doble clic) -> la segunda espera en
#        el ON CONFLICT y devuelve el MISMO remito con replayed = true (nunca un
#        500 por 23505); una sola suma;
#   (3a) anulación abierta vs venta del POS que consume la última unidad
#        recibida -> la venta espera y rechaza por stock (la anulación ya la
#        restó); stock 0;
#   (3b) venta del POS abierta vs anulación -> la anulación espera y rechaza con
#        P0409 delivery_note_stock_consumed; stock 0. En los dos órdenes, nunca
#        stock negativo ni 23514;
#   (4a) edición abierta vs anulación -> la anulación espera el FOR UPDATE del
#        remito y recibe delivery_note_changed;
#   (4b) anulación abierta vs edición -> la edición recibe
#        delivery_note_invalid_state; en los dos casos Σ quantity_delta del
#        remito = Δ branch_stock;
#   (5a) recepción abierta vs baja de una sucursal VACÍA -> la baja espera el
#        FOR SHARE de la sucursal y rechaza con P0428 (branch_has_stock: la
#        recepción ya sumó; el remito pendiente también la bloquearía);
#   (5b) baja abierta vs recepción a esa sucursal -> la recepción espera y
#        rechaza con P0422 (sucursal desactivada); nunca stock ni un remito
#        pendiente en una sucursal desactivada;
#   (5c) baja abierta vs edición que mueve un remito a esa sucursal -> la
#        edición espera el FOR SHARE de la sucursal nueva y rechaza con P0422;
#        el remito sigue en su sucursal;
#   (6a) recepción abierta vs borrado del proveedor (delete_supplier toma el
#        proveedor FOR UPDATE, cuenta los remitos pendientes y recién entonces
#        lo da de baja) -> el borrado espera, cuenta el remito y NO borra
#        (revisión adversarial RC-A-04);
#   (6b) borrado abierto vs recepción -> la recepción espera el FOR SHARE del
#        proveedor, lo relee borrado y rechaza con supplier_not_found; ningún
#        remito pendiente queda en un proveedor dado de baja;
#   (6c) edición abierta vs borrado -> el borrado espera y no borra.
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_remitos_compra_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961071001
TMP_DIR="$(mktemp -d)"
RUN="rcrace$$"

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
  echo "GATE REMITOS-COMPRA-RACE FAILED: $*" >&2
  for f in "$TMP_DIR"/*; do
    [ -f "$f" ] && { echo "--- $(basename "$f") ---" >&2; grep -v 'send_email_log_webhook' "$f" | head -20 >&2; }
  done
  cleanup
  exit 1
}

# ── Fixture: cuenta real vía handle_new_user (owner), proveedor, productos ───
EMAIL="remitos-compra-race-$RUN@test.local"
psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A >/dev/null <<SQL || fail "no se pudo armar el fixture"
DO \$\$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', '$EMAIL', now(), now(),
          jsonb_build_object('name', 'Gate RC Race', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta'; END IF;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account, 'Proveedor RC Race');
  -- Un proveedor por carrera de borrado (6a/6b/6c): el soft delete lo consume.
  INSERT INTO public.suppliers (account_id, name) VALUES
    (v_account, 'Proveedor RC Race Borrado A'),
    (v_account, 'Proveedor RC Race Borrado B'),
    (v_account, 'Proveedor RC Race Borrado C');
  -- Dos sucursales VACÍAS extra para la baja (5a/5b/5c) y una de origen (5c).
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account, 'RC Race Vacía 1', TRUE, 'active', now(), now() + interval '1 minute'),
         (v_account, 'RC Race Vacía 2', TRUE, 'active', now(), now() + interval '2 minutes'),
         (v_account, 'RC Race Vacía 3', TRUE, 'active', now(), now() + interval '3 minutes'),
         (v_account, 'RC Race Origen',  TRUE, 'active', now(), now() + interval '4 minutes');
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES
    (v_user, v_account, 'RC Race Doble',  'RC-RACE-TWO',  10, 100),
    (v_user, v_account, 'RC Race Idem',   'RC-RACE-IDEM', 10, 100),
    (v_user, v_account, 'RC Race Última 1', 'RC-RACE-LAST1', 10, 100),
    (v_user, v_account, 'RC Race Última 2', 'RC-RACE-LAST2', 10, 100),
    (v_user, v_account, 'RC Race Edit',   'RC-RACE-EDIT', 10, 100),
    (v_user, v_account, 'RC Race Baja',   'RC-RACE-BAJA', 10, 100),
    (v_user, v_account, 'RC Race Borrado', 'RC-RACE-BORRADO', 10, 100);
END \$\$;
SQL
USER_ID=$(q "SELECT id FROM auth.users WHERE email = '$EMAIL';")
[ -n "$USER_ID" ] || fail "el fixture no creó el usuario"
ACCOUNT_ID=$(q "SELECT account_id FROM public.account_members WHERE user_id = '$USER_ID' ORDER BY created_at LIMIT 1;")
SUPPLIER_ID=$(q "SELECT id FROM public.suppliers WHERE account_id = '$ACCOUNT_ID' AND name = 'Proveedor RC Race';")
SUP_A=$(q "SELECT id FROM public.suppliers WHERE account_id = '$ACCOUNT_ID' AND name = 'Proveedor RC Race Borrado A';")
SUP_B=$(q "SELECT id FROM public.suppliers WHERE account_id = '$ACCOUNT_ID' AND name = 'Proveedor RC Race Borrado B';")
SUP_C=$(q "SELECT id FROM public.suppliers WHERE account_id = '$ACCOUNT_ID' AND name = 'Proveedor RC Race Borrado C';")
BRANCH_ID=$(q "SELECT id FROM public.branches WHERE account_id = '$ACCOUNT_ID' ORDER BY created_at LIMIT 1;")
EMPTY1=$(q "SELECT id FROM public.branches WHERE account_id = '$ACCOUNT_ID' AND name = 'RC Race Vacía 1';")
EMPTY2=$(q "SELECT id FROM public.branches WHERE account_id = '$ACCOUNT_ID' AND name = 'RC Race Vacía 2';")
EMPTY3=$(q "SELECT id FROM public.branches WHERE account_id = '$ACCOUNT_ID' AND name = 'RC Race Vacía 3';")
ORIGIN=$(q "SELECT id FROM public.branches WHERE account_id = '$ACCOUNT_ID' AND name = 'RC Race Origen';")
P_TWO=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RC-RACE-TWO';")
P_IDEM=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RC-RACE-IDEM';")
P_LAST1=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RC-RACE-LAST1';")
P_LAST2=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RC-RACE-LAST2';")
P_EDIT=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RC-RACE-EDIT';")
P_BAJA=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RC-RACE-BAJA';")
P_BORRADO=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' AND sku = 'RC-RACE-BORRADO';")
PM_OTHER=$(q "SELECT id FROM public.payment_methods WHERE account_id = '$ACCOUNT_ID' AND kind = 'other' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;")
[ -n "$ACCOUNT_ID" ] && [ -n "$SUPPLIER_ID" ] && [ -n "$BRANCH_ID" ] && [ -n "$EMPTY1" ] && [ -n "$EMPTY2" ] \
  && [ -n "$EMPTY3" ] && [ -n "$ORIGIN" ] && [ -n "$P_TWO" ] && [ -n "$P_IDEM" ] && [ -n "$P_LAST1" ] \
  && [ -n "$P_LAST2" ] && [ -n "$P_EDIT" ] && [ -n "$P_BAJA" ] && [ -n "$PM_OTHER" ] \
  && [ -n "$SUP_A" ] && [ -n "$SUP_B" ] && [ -n "$SUP_C" ] && [ -n "$P_BORRADO" ] \
  || fail "el fixture no devolvió cuenta/proveedor/sucursales/productos/forma de pago"

CLAIMS="SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);"

stock() { q "SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = '$1' AND branch_id = '${2:-$BRANCH_ID}'), 0);"; }

issue_sql() {  # $1 = clave, $2 = producto, $3 = cantidad, $4 = sucursal (opcional), $5 = proveedor (opcional)
  echo "SELECT 'RES=' || public.rpc_create_purchase_delivery_note('$1', '${5:-$SUPPLIER_ID}'::uuid, '${4:-$BRANCH_ID}'::uuid, NULL, NULL,
          jsonb_build_array(jsonb_build_object('product_id', '$2'::uuid, 'unit_id', NULL,
            'quantity', $3, 'price', 100, 'subtotal', $3 * 100)))::text;"
}
update_sql() { # $1 = remito, $2 = versión, $3 = producto, $4 = cantidad, $5 = sucursal (opcional), $6 = proveedor (opcional)
  echo "SELECT 'RES=' || public.rpc_update_purchase_delivery_note('$1'::uuid, $2, '${6:-$SUPPLIER_ID}'::uuid, '${5:-$BRANCH_ID}'::uuid, NULL, NULL,
          jsonb_build_array(jsonb_build_object('product_id', '$3'::uuid, 'unit_id', NULL,
            'quantity', $4, 'price', 100, 'subtotal', $4 * 100)))::text;"
}
cancel_sql() { # $1 = remito, $2 = versión
  echo "SELECT 'RES=' || public.rpc_cancel_delivery_note('$1'::uuid, $2, 'carrera')::text;"
}
sell_sql() {   # $1 = clave, $2 = producto, $3 = cantidad (venta del POS)
  echo "SELECT 'RES=' || public.rpc_quick_sale('$1', NULL, jsonb_build_array(jsonb_build_object(
            'product_id', '$2'::uuid, 'unit_id', NULL, 'quantity', $3, 'price', 1, 'subtotal', $3)),
          'other', NULL, NULL, NULL, '$BRANCH_ID'::uuid, NULL, '$PM_OTHER'::uuid, NULL)::text;"
}
deactivate_sql() { # $1 = sucursal
  echo "SELECT 'RES=deactivated:' || public.rpc_deactivate_branch('$1'::uuid)::text;"
}
# Réplica en SQL de delete_supplier (backend/services/suppliers.py): el proveedor
# se toma FOR UPDATE ANTES de contar, y el conteo y el soft delete son sentencias
# aparte (en READ COMMITTED cada una relee). $1 = proveedor.
delete_supplier_sql() {
  echo "SELECT 'LOCKED=' || count(*) FROM (SELECT id FROM public.suppliers
          WHERE id = '$1'::uuid AND account_id = '$ACCOUNT_ID'::uuid AND deleted_at IS NULL FOR UPDATE) s;
        SELECT 'PENDING=' || count(*) FROM public.delivery_notes
          WHERE supplier_id = '$1'::uuid AND account_id = '$ACCOUNT_ID'::uuid AND direction = 'purchase' AND status = 'issued';
        UPDATE public.suppliers SET deleted_at = now(), deleted_by = '$USER_ID'::uuid
          WHERE id = '$1'::uuid AND account_id = '$ACCOUNT_ID'::uuid
            AND NOT EXISTS (SELECT 1 FROM public.delivery_notes
                            WHERE supplier_id = '$1'::uuid AND account_id = '$ACCOUNT_ID'::uuid
                              AND direction = 'purchase' AND status = 'issued')
          RETURNING 'DELETED=' || id;"
}

# Alta fuera de carrera. Devuelve el id del remito.
new_note() {  # $1 = clave, $2 = producto, $3 = cantidad, $4 = sucursal (opcional), $5 = proveedor (opcional)
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<SQL | grep -o '"id": "[0-9a-f-]*"' | head -1 | grep -o '[0-9a-f-]\{36\}'
BEGIN;
$CLAIMS
$(issue_sql "$1" "$2" "$3" "${4:-}" "${5:-}")
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

no_check_violation() {  # $1 = nombre de la carrera
  if grep -qiE '23514|violates check constraint' "$TMP_DIR/$1.a" "$TMP_DIR/$1.b"; then
    fail "($1) la base abortó con la restricción de stock no negativo (23514) en vez del error de negocio"
  fi
}

sum_delta() { q "SELECT COALESCE(sum(quantity_delta), 0) FROM public.stock_movements WHERE reference_id = '$1';"; }
dn_status() { q "SELECT status FROM public.delivery_notes WHERE id = '$1';"; }
notes_of()  { q "SELECT count(DISTINCT delivery_note_id) FROM public.delivery_note_items WHERE product_id = '$1';"; }
is_zero()   { [ "$(q "SELECT ($1)::numeric = 0;")" = "t" ]; }

# ── (1) dos recepciones del mismo producto ───────────────────────────────────
race "1" "$(issue_sql "${RUN}-1-A" "$P_TWO" 3)" "$(issue_sql "${RUN}-1-B" "$P_TWO" 4)"
grep -q '"replayed": false' "$TMP_DIR/1.a" || fail "(1) A no recibió"
grep -q '"replayed": false' "$TMP_DIR/1.b" || fail "(1) B debía recibir también (después de esperar el lock del producto)"
[ "$(notes_of "$P_TWO")" = "2" ] || fail "(1) se esperaban dos remitos de compra"
S=$(stock "$P_TWO"); [ "$(q "SELECT $S = 7;")" = "t" ] || fail "(1) el stock debía sumar 3 + 4 = 7, quedó $S"
[ "$(q "SELECT count(DISTINCT dn.number) FROM public.delivery_notes dn JOIN public.delivery_note_items i ON i.delivery_note_id = dn.id WHERE i.product_id = '$P_TWO';")" = "2" ] \
  || fail "(1) los dos remitos debían tener números RC distintos"
echo "PASS (1): dos recepciones concurrentes del mismo producto -> la segunda esperó el lock del producto; las dos sumaron (7) con números RC distintos."

# ── (2) misma clave (doble clic) ─────────────────────────────────────────────
race "2" "$(issue_sql "${RUN}-2" "$P_IDEM" 2)" "$(issue_sql "${RUN}-2" "$P_IDEM" 2)"
A_ID=$(grep -o '"id": "[0-9a-f-]*"' "$TMP_DIR/2.a" | head -1)
B_ID=$(grep -o '"id": "[0-9a-f-]*"' "$TMP_DIR/2.b" | head -1)
grep -q '"replayed": false' "$TMP_DIR/2.a" || fail "(2) A no recibió"
grep -q '"replayed": true' "$TMP_DIR/2.b" || fail "(2) B debía recibir el replay (nunca un 23505)"
[ -n "$A_ID" ] && [ "$A_ID" = "$B_ID" ] || fail "(2) el replay devolvió otro remito ($A_ID vs $B_ID)"
[ "$(notes_of "$P_IDEM")" = "1" ] || fail "(2) se esperaba exactamente un remito"
S=$(stock "$P_IDEM"); [ "$(q "SELECT $S = 2;")" = "t" ] || fail "(2) el stock debía subir una sola vez (0 -> 2), quedó $S"
echo "PASS (2): doble clic con la misma clave -> B esperó en el ON CONFLICT y devolvió el mismo remito con replayed = true; una sola suma."

# ── (3a) anulación abierta vs venta del POS de la última unidad ──────────────
R3A=$(new_note "${RUN}-3a" "$P_LAST1" 1); [ -n "$R3A" ] || fail "no se recibió el remito de (3a)"
race "3a" "$(cancel_sql "$R3A" 1)" "$(sell_sql "${RUN}-3a-pos" "$P_LAST1" 1)"
no_check_violation "3a"
grep -q '"status": "canceled"' "$TMP_DIR/3a.a" || fail "(3a) A no anuló"
grep -qi 'insuficiente' "$TMP_DIR/3a.b" || fail "(3a) la venta debía rechazar por stock insuficiente (la anulación ya restó la unidad)"
is_zero "$(stock "$P_LAST1")" || fail "(3a) el stock debía quedar en 0, quedó $(stock "$P_LAST1")"
is_zero "$(sum_delta "$R3A")" || fail "(3a) el ledger del remito anulado debía cerrar en 0"
echo "PASS (3a): anulación abierta vs venta del POS -> la venta esperó el lock y rechazó por stock; stock 0, ledger del remito en 0."

# ── (3b) venta del POS abierta vs anulación ──────────────────────────────────
R3B=$(new_note "${RUN}-3b" "$P_LAST2" 1); [ -n "$R3B" ] || fail "no se recibió el remito de (3b)"
race "3b" "$(sell_sql "${RUN}-3b-pos" "$P_LAST2" 1)" "$(cancel_sql "$R3B" 1)"
no_check_violation "3b"
grep -q 'RES=' "$TMP_DIR/3b.a" || fail "(3b) la venta del POS no se completó"
grep -q 'delivery_note_stock_consumed' "$TMP_DIR/3b.b" || fail "(3b) la anulación debía rechazar con P0409 delivery_note_stock_consumed"
[ "$(dn_status "$R3B")" = "issued" ] || fail "(3b) el remito debía seguir issued"
is_zero "$(stock "$P_LAST2")" || fail "(3b) el stock debía quedar en 0, quedó $(stock "$P_LAST2")"
echo "PASS (3b): venta del POS abierta vs anulación -> la anulación esperó y rechazó con delivery_note_stock_consumed; nunca stock negativo ni 23514."

# ── (4a) edición abierta vs anulación ────────────────────────────────────────
R4A=$(new_note "${RUN}-4a" "$P_EDIT" 3); [ -n "$R4A" ] || fail "no se recibió el remito de (4a)"
S0=$(stock "$P_EDIT")
race "4a" "$(update_sql "$R4A" 1 "$P_EDIT" 5)" "$(cancel_sql "$R4A" 1)"
grep -q '"revision": 2' "$TMP_DIR/4a.a" || fail "(4a) A no editó"
grep -q 'delivery_note_changed' "$TMP_DIR/4a.b" || fail "(4a) la anulación debía recibir delivery_note_changed"
[ "$(dn_status "$R4A")" = "issued" ] || fail "(4a) el remito no debía quedar anulado"
S1=$(stock "$P_EDIT")
[ "$(q "SELECT ($S1 - $S0) = 2 AND $(sum_delta "$R4A") = 5;")" = "t" ] || fail "(4a) Δ stock $S0 -> $S1 / Σ delta $(sum_delta "$R4A") no cuadran con la edición 3 -> 5"
echo "PASS (4a): edición abierta vs anulación -> la anulación esperó el FOR UPDATE y recibió delivery_note_changed; Σ delta = +aportado."

# ── (4b) anulación abierta vs edición ────────────────────────────────────────
R4B=$(new_note "${RUN}-4b" "$P_EDIT" 2); [ -n "$R4B" ] || fail "no se recibió el remito de (4b)"
S0=$(stock "$P_EDIT")
race "4b" "$(cancel_sql "$R4B" 1)" "$(update_sql "$R4B" 1 "$P_EDIT" 4)"
grep -q '"status": "canceled"' "$TMP_DIR/4b.a" || fail "(4b) A no anuló"
grep -q 'delivery_note_invalid_state' "$TMP_DIR/4b.b" || fail "(4b) la edición debía recibir delivery_note_invalid_state"
S1=$(stock "$P_EDIT")
[ "$(q "SELECT ($S1 - $S0) = -2;")" = "t" ] && is_zero "$(sum_delta "$R4B")" || fail "(4b) Δ stock $S0 -> $S1 / Σ delta $(sum_delta "$R4B") no cuadran con la anulación"
echo "PASS (4b): anulación abierta vs edición -> la edición recibió delivery_note_invalid_state; ledger del remito en 0."

# ── (5a) recepción abierta vs baja de una sucursal vacía ─────────────────────
race "5a" "$(issue_sql "${RUN}-5a" "$P_BAJA" 1 "$EMPTY1")" "$(deactivate_sql "$EMPTY1")"
grep -q '"replayed": false' "$TMP_DIR/5a.a" || fail "(5a) la recepción debía completarse"
# La recepción ya sumó stock, así que el primer token de P0428 que salta es
# branch_has_stock (antes que branch_has_pending_delivery_notes, que el remito
# pendiente también dispararía): la spec declara ESE token y el gate lo exige.
grep -q 'branch_has_stock' "$TMP_DIR/5a.b" || fail "(5a) la baja debía rechazar con P0428 branch_has_stock (el token exacto que declara la spec)"
[ "$(q "SELECT is_active FROM public.branches WHERE id = '$EMPTY1';")" = "t" ] || fail "(5a) la sucursal debía seguir activa"
echo "PASS (5a): recepción abierta vs baja de una sucursal vacía -> la baja esperó el FOR SHARE y rechazó con P0428 (la sucursal ya tiene lo recibido)."

# ── (5b) baja abierta vs recepción a esa sucursal ────────────────────────────
race "5b" "$(deactivate_sql "$EMPTY2")" "$(issue_sql "${RUN}-5b" "$P_BAJA" 1 "$EMPTY2")"
grep -q 'RES=deactivated' "$TMP_DIR/5b.a" || fail "(5b) la baja debía completarse"
grep -q 'P0422\|delivery_note_branch_inactive' "$TMP_DIR/5b.b" || fail "(5b) la recepción debía rechazar con P0422 (sucursal desactivada)"
is_zero "$(stock "$P_BAJA" "$EMPTY2")" || fail "(5b) no debía quedar stock en la sucursal desactivada"
[ "$(q "SELECT count(*) FROM public.delivery_notes WHERE branch_id = '$EMPTY2';")" = "0" ] || fail "(5b) no debía quedar un remito en la sucursal desactivada"
echo "PASS (5b): baja abierta vs recepción -> la recepción esperó, releyó la sucursal desactivada y rechazó con P0422; sin stock ni remito ahí."

# ── (5c) baja abierta vs edición que mueve un remito a esa sucursal ──────────
R5C=$(new_note "${RUN}-5c" "$P_BAJA" 1 "$ORIGIN"); [ -n "$R5C" ] || fail "no se recibió el remito de (5c)"
race "5c" "$(deactivate_sql "$EMPTY3")" "$(update_sql "$R5C" 1 "$P_BAJA" 1 "$EMPTY3")"
grep -q 'RES=deactivated' "$TMP_DIR/5c.a" || fail "(5c) la baja debía completarse"
grep -q 'P0422\|delivery_note_branch_inactive' "$TMP_DIR/5c.b" || fail "(5c) la edición debía rechazar con P0422"
[ "$(q "SELECT branch_id FROM public.delivery_notes WHERE id = '$R5C';")" = "$ORIGIN" ] || fail "(5c) el remito debía seguir en su sucursal"
is_zero "$(stock "$P_BAJA" "$EMPTY3")" || fail "(5c) no debía quedar stock en la sucursal desactivada"
echo "PASS (5c): baja abierta vs edición hacia esa sucursal -> la edición esperó el FOR SHARE de la sucursal nueva y rechazó con P0422."

# ── (6a) recepción abierta vs borrado del proveedor ──────────────────────────
race "6a" "$(issue_sql "${RUN}-6a" "$P_BORRADO" 1 "" "$SUP_A")" "$(delete_supplier_sql "$SUP_A")"
grep -q '"replayed": false' "$TMP_DIR/6a.a" || fail "(6a) la recepción debía completarse"
grep -q 'PENDING=1' "$TMP_DIR/6a.b" || fail "(6a) el borrado debía esperar y contar el remito de la recepción (PENDING=1)"
grep -q 'DELETED=' "$TMP_DIR/6a.b" && fail "(6a) el borrado no debía dar de baja a un proveedor con un remito pendiente"
[ "$(q "SELECT deleted_at IS NULL FROM public.suppliers WHERE id = '$SUP_A';")" = "t" ] || fail "(6a) el proveedor debía seguir vivo"
[ "$(q "SELECT count(*) FROM public.delivery_notes WHERE supplier_id = '$SUP_A' AND status = 'issued';")" = "1" ] || fail "(6a) debía quedar un remito pendiente"
echo "PASS (6a): recepción abierta vs borrado del proveedor -> el borrado esperó el FOR SHARE, contó el remito y no borró."

# ── (6b) borrado abierto vs recepción ────────────────────────────────────────
race "6b" "$(delete_supplier_sql "$SUP_B")" "$(issue_sql "${RUN}-6b" "$P_BORRADO" 1 "" "$SUP_B")"
grep -q 'PENDING=0' "$TMP_DIR/6b.a" && grep -q 'DELETED=' "$TMP_DIR/6b.a" || fail "(6b) el borrado debía completarse sobre un proveedor sin remitos"
grep -q 'supplier_not_found' "$TMP_DIR/6b.b" || fail "(6b) la recepción debía rechazar con supplier_not_found (el proveedor ya está dado de baja)"
[ "$(q "SELECT deleted_at IS NOT NULL FROM public.suppliers WHERE id = '$SUP_B';")" = "t" ] || fail "(6b) el proveedor debía quedar dado de baja"
[ "$(q "SELECT count(*) FROM public.delivery_notes WHERE supplier_id = '$SUP_B';")" = "0" ] || fail "(6b) no debía quedar un remito en un proveedor dado de baja"
echo "PASS (6b): borrado abierto vs recepción -> la recepción esperó, releyó el proveedor borrado y rechazó con supplier_not_found; ningún remito en un proveedor dado de baja."

# ── (6c) edición abierta vs borrado ──────────────────────────────────────────
R6C=$(new_note "${RUN}-6c" "$P_BORRADO" 1 "" "$SUP_C"); [ -n "$R6C" ] || fail "no se recibió el remito de (6c)"
race "6c" "$(update_sql "$R6C" 1 "$P_BORRADO" 2 "" "$SUP_C")" "$(delete_supplier_sql "$SUP_C")"
grep -q '"revision": 2' "$TMP_DIR/6c.a" || fail "(6c) la edición debía completarse"
grep -q 'PENDING=1' "$TMP_DIR/6c.b" || fail "(6c) el borrado debía esperar y contar el remito (PENDING=1)"
grep -q 'DELETED=' "$TMP_DIR/6c.b" && fail "(6c) el borrado no debía dar de baja al proveedor"
[ "$(q "SELECT deleted_at IS NULL FROM public.suppliers WHERE id = '$SUP_C';")" = "t" ] || fail "(6c) el proveedor debía seguir vivo"
echo "PASS (6c): edición abierta vs borrado del proveedor -> el borrado esperó el FOR SHARE y no borró."

# Numeración RC sin huecos ni repetidos.
[ "$(q "SELECT count(*) = max(number) AND count(*) = count(DISTINCT number) FROM public.delivery_notes WHERE account_id = '$ACCOUNT_ID' AND direction = 'purchase';")" = "t" ] \
  || fail "la numeración RC de las carreras tiene huecos o repetidos"

cleanup
LEFT=$(q "SELECT count(*) FROM auth.users WHERE id = '$USER_ID';")
[ "$LEFT" = "0" ] || { echo "GATE REMITOS-COMPRA-RACE FAILED: quedó el usuario del fixture" >&2; exit 1; }
echo "GATE REMITOS-COMPRA-RACE PASSED: 12 carreras con bloqueo real verificado (recepciones concurrentes, doble clic, anulación contra venta del POS en los dos órdenes, edición contra anulación en los dos órdenes, recepción y edición contra la baja de una sucursal vacía, recepción y edición contra el borrado del proveedor), residuo cero."
