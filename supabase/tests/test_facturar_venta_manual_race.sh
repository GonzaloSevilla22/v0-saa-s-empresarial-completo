#!/usr/bin/env bash
# =============================================================================
# GATE: test_facturar_venta_manual_race.sh
# CHANGE: venta-editable-vs-promocion-legacy (20261061000001) — governance CRÍTICO
#
# Exclusión de la PROMOCIÓN de una venta cargada a mano (rpc_promote_legacy_
# sale_to_order, que crea la sales_order en SU transacción) contra la EDICIÓN
# y el BORRADO de esa venta (que resuelven "¿hay orden que anular?"), con DOS
# o más conexiones reales. Sin exclusión, una edición/borrado que corre
# mientras la promoción crea la orden no la ve, concluye "no hay nada que
# anular", y queda un comprobante pending_cae VIVO por los importes VIEJOS
# (red team de #582, N1: 4/4 interleavings).
#
# El ancla es lo único que existe ANTES de la orden: las filas de `sales` de
# la operación, tomadas FOR UPDATE en orden de id por promoción, edición y
# borrado. Orden global de locks: sales → sales_orders → fiscal_documents.
#
# Casos (cada uno ITER veces, con una venta nueva de $1000 = 500 × 2):
#   R1  promoción frenada con la orden creada (sin commit) → edición a $111:
#       la edición ESPERA a la promoción, ve la orden, la re-apunta y la
#       recalcula; la emisión posterior sale por $111.
#   R1b promoción commiteada, EMISIÓN abierta → edición: espera la orden,
#       anula el comprobante recién creado y recalcula (0 pendientes vivos).
#   R2  promoción frenada → borrado: el borrado ESPERA, ve la orden y la
#       cancela; la emisión posterior da P0400 order_not_confirmed.
#   R3  edición frenada con las filas tomadas → promoción: la promoción
#       ESPERA y, cuando la edición commitea, no encuentra filas → P0404.
#   R4  borrado frenado → promoción: ESPERA y → P0404.
#   R5  dos promociones de la misma operación: la segunda ESPERA y devuelve
#       la MISMA orden (replayed=true).
#   R6  doble "Guardar": dos ediciones de la misma operación. La segunda
#       ESPERA a la primera sobre las filas de sales y, cuando la primera
#       commitea, falla con P0404 ANTES de revertir stock: una sola operación
#       nueva y el stock movido una sola vez (sin el lock temprano, la
#       segunda revertía stock sobre filas ya borradas e insertaba una
#       operación duplicada).
# Además, una vez: R0 una promoción de OTRA cuenta sobre la operación no
# bloquea ninguna fila ajena (el JOIN de tenencia filtra antes del FOR UPDATE).
#
# Reglas ("el camino se ejecutó" — lección #577/#580/#582): en cada iteración
# se VE a la sesión víctima esperando (pg_locks NOT granted) y bloqueada por
# la sesión que corresponde (pg_blocking_pids), el freno está tomado (advisory
# visible) y cada salida trae su marcador. Sin espera observada o sin marcador
# = INCONCLUSO = FAIL. Cualquier 40P01/deadlock o statement timeout = FAIL.
# Invariante global al final de CADA iteración: ningún pending_cae cuyo total
# difiera de Σ sales.total de la operación de su orden, o cuya orden apunte a
# una operación sin filas.
#
# Frenos determinísticos (se liberan con pg_terminate_backend):
#   K_items: LOCK TABLE sales_order_items IN EXCLUSIVE MODE → la promoción
#            queda frenada DESPUÉS de insertar la orden (sin commit) y con las
#            filas de sales tomadas: exactamente la ventana de N1.
#   K_stock: la fila de branch_stock del producto FOR UPDATE → la edición y el
#            borrado quedan frenados con las filas de sales tomadas y ANTES de
#            escribir sales (revierten stock primero).
#
# ESTO NO SE PUEDE PROBAR EN UN SOLO ARCHIVO .sql (una sesión nunca bloquea
# contra su propio lock; dblink no sirve: `postgres` no es superusuario en
# Supabase). De ahí los `psql` en paralelo.
#
# Uso:
#   ITER=20 DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_facturar_venta_manual_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ITER="${ITER:-20}"
KEY=961061001            # advisory del freno K
KEY_E=961061002          # advisory de la emisión abierta (R1b)
WAIT_TICKS="${WAIT_TICKS:-100}"   # × 0.1 s para ver a la víctima esperando
TMP=$(mktemp -d)

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

USER_ID=""; ACCOUNT_ID=""; USER_B=""; ACCOUNT_B=""
BG_PIDS=()

cleanup() {
  for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  psql "$DB_URL" -X -q -t -A -c "
    SELECT pg_terminate_backend(l.pid) FROM pg_locks l
    WHERE l.locktype = 'advisory' AND l.objid IN ($KEY, $KEY_E) AND l.pid <> pg_backend_pid();" >/dev/null 2>&1
  psql "$DB_URL" -X -q -t -A -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name LIKE 'fvm\_%' AND pid <> pg_backend_pid();" >/dev/null 2>&1
  for acc_user in "$ACCOUNT_ID:$USER_ID" "$ACCOUNT_B:$USER_B"; do
    local acc="${acc_user%%:*}" usr="${acc_user##*:}"
    [ -n "$acc" ] || continue
    psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL
DO \$\$
DECLARE v_account uuid := '$acc'; v_user uuid := '$usr';
BEGIN
  DELETE FROM public.sales_orders            WHERE account_id = v_account;
  DELETE FROM public.document_status_history WHERE account_id = v_account;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account;
  DELETE FROM public.document_sequences      WHERE point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account);
  DELETE FROM public.points_of_sale          WHERE account_id = v_account;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account;
  DELETE FROM public.sale_items              WHERE account_id = v_account;
  DELETE FROM public.stock_movements         WHERE account_id = v_account;
  DELETE FROM public.sales                   WHERE account_id = v_account;
  DELETE FROM public.events                  WHERE account_id = v_account;
  DELETE FROM public.notifications           WHERE account_id = v_account;
  DELETE FROM public.branch_stock            WHERE account_id = v_account;
  DELETE FROM public.products                WHERE account_id = v_account;
  DELETE FROM public.clients                 WHERE account_id = v_account;
  DELETE FROM public.analytics_events        WHERE user_id = v_user;
  DELETE FROM public.payment_methods         WHERE account_id = v_account;
  DELETE FROM public.product_categories      WHERE account_id = v_account;
  DELETE FROM public.account_member_roles    WHERE account_id = v_account;
  DELETE FROM public.cashboxes               WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account);
  SET LOCAL session_replication_role = replica;
  DELETE FROM public.audit_logs              WHERE account_id = v_account;
  DELETE FROM public.branches                WHERE account_id = v_account;
  DELETE FROM public.account_members         WHERE account_id = v_account OR user_id = v_user;
  DELETE FROM public.accounts                WHERE id = v_account;
  SET LOCAL session_replication_role = DEFAULT;
  DELETE FROM public.profiles                WHERE id = v_user;
  DELETE FROM public.email_logs              WHERE user_id = v_user;
  DELETE FROM public.operation_idempotency   WHERE user_id = v_user;
  DELETE FROM auth.users                     WHERE id = v_user;
END \$\$;
SQL
  done
  rm -rf "$TMP"
}

fail() { echo "GATE FACTURAR-VENTA-MANUAL-RACE FAILED: $*" >&2; cleanup; exit 1; }

# ── Fixture ──────────────────────────────────────────────────────────────────
FIXTURE=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<'SQL'
DO $$
DECLARE
  v_user uuid := gen_random_uuid(); v_user_b uuid := gen_random_uuid();
  v_account uuid; v_account_b uuid; v_branch uuid; v_client uuid; v_product uuid;
  v_fp uuid; v_pv uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'facturar-venta-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Facturar Venta Race', 'phone', '', 'locality', '', 'province', '')),
         (v_user_b, 'authenticated', 'authenticated', 'facturar-venta-race-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Facturar Venta Race B', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account   FROM public.account_members WHERE user_id = v_user   ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  IF v_account IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los anchors';
  END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user, v_account, '__gate_fvm_race_client__') RETURNING id INTO v_client;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_fvm_race_product__', 'FVM-RACE-1', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 100000);

  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account, '20999999998', 'monotributista', 'homologacion', true) RETURNING id INTO v_fp;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, v_account, 9901, true) RETURNING id INTO v_pv;

  CREATE TEMP TABLE IF NOT EXISTS _race_out (k text, v text);
  DELETE FROM _race_out;
  INSERT INTO _race_out VALUES
    ('user', v_user::text), ('account', v_account::text), ('branch', v_branch::text),
    ('client', v_client::text), ('product', v_product::text), ('pv', v_pv::text),
    ('userb', v_user_b::text), ('accountb', v_account_b::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _race_out;
SQL
) || fail "no se pudo sembrar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z]+=' | sed 's/^/F_/')"
USER_ID="${F_user:-}"; ACCOUNT_ID="${F_account:-}"; USER_B="${F_userb:-}"; ACCOUNT_B="${F_accountb:-}"
[ -n "$USER_ID" ] && [ -n "${F_pv:-}" ] && [ -n "${F_product:-}" ] || fail "el fixture no devolvió los ids (salida: $FIXTURE)"
echo "fixture: account=$ACCOUNT_ID pv=$F_pv product=$F_product ITER=$ITER"

CLAIMS_A="SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true); SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Venta nueva cargada a mano: 500 × 2 = $1000. Deja OP y SALE.
new_sale() {
  local out
  out=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A 2>&1 <<SQL
BEGIN;
$CLAIMS_A
SELECT 'OP=' || (public.rpc_create_sale_operation(
  'fvm-race-' || gen_random_uuid()::text, '$F_client'::uuid, CURRENT_DATE, 'ARS',
  jsonb_build_array(jsonb_build_object('product_id', '$F_product'::uuid, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL)),
  '$F_branch'::uuid, NULL, NULL)->>'operation_id');
COMMIT;
SQL
)
  OP=$(echo "$out" | grep -o 'OP=[0-9a-f-]*' | head -1 | cut -d= -f2)
  [ -n "$OP" ] || fail "no se pudo crear la venta de la iteración: $out"
  SALE=$(q "SELECT id FROM public.sales WHERE operation_id = '$OP';")
  [ -n "$SALE" ] || fail "la venta $OP no tiene filas"
}

# Sesiones (en background, salida a archivo). Cada una se identifica por
# application_name para poder verla desde una conexión NUEVA (las vistas
# pg_stat_* se congelan dentro de una transacción; desde una conexión nueva no).
promote_bg() {  # $1 app, $2 op, $3 out, [$4 user]
  local usr="${4:-$USER_ID}"
  psql "$DB_URL" -X -q -t -A > "$3" 2>&1 <<SQL &
SET application_name = '$1';
SET statement_timeout = '25s';
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$usr', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$usr', true);
DO \$\$
DECLARE v_res jsonb; v_state text; v_msg text;
BEGIN
  BEGIN
    v_res := public.rpc_promote_legacy_sale_to_order('$2'::uuid);
    RAISE NOTICE 'PROMOTE_OK so=% replayed=%', v_res->>'sales_order_id', v_res->>'replayed';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE NOTICE 'PROMOTE_ERR sqlstate=% msg=%', v_state, v_msg;
  END;
END \$\$;
COMMIT;
SQL
  BG_PIDS+=($!)
  LAST_BG=$!
}

edit_bg() {  # $1 app, $2 sale, $3 out  (edita a 111 × 1 = $111)
  psql "$DB_URL" -X -q -t -A > "$3" 2>&1 <<SQL &
SET application_name = '$1';
SET statement_timeout = '25s';
BEGIN;
$CLAIMS_A
DO \$\$
DECLARE v_res jsonb; v_state text; v_msg text;
BEGIN
  BEGIN
    v_res := public.rpc_atomic_update_sale_operation(
      ARRAY['$2'::uuid], '$F_client'::uuid, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', '$F_product'::uuid, 'amount', 111.00, 'quantity', 1)));
    RAISE NOTICE 'EDIT_OK op=% anulo=%', v_res->>'operation_id',
      (v_res->'voided_fiscal_document') IS NOT NULL AND (v_res->'voided_fiscal_document') <> 'null'::jsonb;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE NOTICE 'EDIT_ERR sqlstate=% msg=%', v_state, v_msg;
  END;
END \$\$;
COMMIT;
SQL
  BG_PIDS+=($!)
  LAST_BG=$!
}

delete_bg() {  # $1 app, $2 op, $3 out
  psql "$DB_URL" -X -q -t -A > "$3" 2>&1 <<SQL &
SET application_name = '$1';
SET statement_timeout = '25s';
BEGIN;
$CLAIMS_A
DO \$\$
DECLARE v_ok boolean; v_state text; v_msg text;
BEGIN
  BEGIN
    v_ok := public.rpc_delete_sale_operation(NULL, '$2'::uuid, 'gate race');
    RAISE NOTICE 'DELETE_OK found=%', v_ok;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE NOTICE 'DELETE_ERR sqlstate=% msg=%', v_state, v_msg;
  END;
END \$\$;
COMMIT;
SQL
  BG_PIDS+=($!)
  LAST_BG=$!
}

# Emisión sincrónica (transacción propia). Deja EMIT_LINE.
emit_now() {  # $1 so
  EMIT_LINE=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
BEGIN;
$CLAIMS_A
DO \$\$
DECLARE v_res jsonb; v_state text; v_msg text;
BEGIN
  BEGIN
    v_res := public.rpc_emit_sale_invoice('$1'::uuid, '$F_pv'::uuid);
    RAISE NOTICE 'EMIT_OK doc=%', v_res->>'fiscal_document_id';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE NOTICE 'EMIT_ERR sqlstate=% msg=%', v_state, v_msg;
  END;
END \$\$;
COMMIT;
SQL
)
}

# Freno K en background: toma su lock y DESPUÉS el advisory (visible en
# pg_locks → cuando aparece, el lock ya está tomado).
brake_bg() {  # $1 = items | stock
  local take
  if [ "$1" = "items" ]; then
    take="LOCK TABLE public.sales_order_items IN EXCLUSIVE MODE;"
  else
    take="SELECT 1 FROM public.branch_stock WHERE product_id = '$F_product' AND branch_id = '$F_branch' FOR UPDATE;"
  fi
  psql "$DB_URL" -X -q -t -A > /dev/null 2>&1 <<SQL &
SET application_name = 'fvm_brake';
BEGIN;
$take
SELECT pg_advisory_xact_lock($KEY);
SELECT pg_sleep(60);
ROLLBACK;
SQL
  BG_PIDS+=($!)
  BRAKE_BG=$!
  wait_advisory "$KEY" || fail "el freno $1 nunca tomó su lock (advisory $KEY ausente de pg_locks)"
}

# Espera (en UNA conexión, máx. ~20 s) a que el advisory $1 esté tomado.
wait_advisory() {
  local out
  out=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
DO \$\$
BEGIN
  FOR i IN 1..400 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = $1 AND granted) THEN
      RAISE NOTICE 'ADV_SEEN'; RETURN;
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END \$\$;
SQL
)
  [[ "$out" == *ADV_SEEN* ]]
}

release_brake() {
  q "SELECT pg_terminate_backend(l.pid) FROM pg_locks l
     WHERE l.locktype = 'advisory' AND l.objid = $KEY AND l.pid <> pg_backend_pid();" >/dev/null
  wait "$BRAKE_BG" 2>/dev/null
  local out
  out=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
DO \$\$
BEGIN
  FOR i IN 1..400 LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = $KEY) THEN
      RAISE NOTICE 'ADV_GONE'; RETURN;
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END \$\$;
SQL
)
  [[ "$out" == *ADV_GONE* ]] || fail "el freno no soltó el advisory $KEY"
}

# Espera a VER a la sesión $1 bloqueada POR la sesión $2 (pg_blocking_pids)
# y esperando sobre la tabla $3 (lock de fila `tuple` o de tabla sobre ESA
# relación), en UNA conexión. $2 = 'brake' para el freno K. La tabla importa:
# sin ella, una espera INCIDENTAL cuenta como exclusión (medido en RED: la
# promoción esperaba al borrado por la fila de `products` que
# rpc_reverse_stock_movement toma FOR UPDATE, no por las filas de la venta).
# pg_stat_activity se congela dentro de una transacción:
# pg_stat_clear_snapshot() en cada vuelta. Devuelve 0 si la vio esperando;
# 1 si terminó sin esperar o se agotó WAIT_TICKS.
seen_blocked_by() {
  local victim="$1" blocker="$2" rel="$3" bexpr
  if [ "$blocker" = "brake" ]; then
    bexpr="(SELECT pid FROM pg_locks WHERE locktype = 'advisory' AND objid = $KEY AND granted LIMIT 1)"
  else
    bexpr="(SELECT pid FROM pg_stat_activity WHERE application_name = '$blocker' ORDER BY backend_start DESC LIMIT 1)"
  fi
  local out
  out=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
DO \$\$
DECLARE v_pid int; v_b int; v_seen boolean := false;
BEGIN
  FOR i IN 1..$WAIT_TICKS LOOP
    PERFORM pg_stat_clear_snapshot();
    SELECT pid INTO v_pid FROM pg_stat_activity
    WHERE application_name = '$victim' ORDER BY backend_start DESC LIMIT 1;
    v_b := $bexpr;
    IF v_pid IS NOT NULL THEN
      v_seen := true;
      IF v_b IS NOT NULL
         AND EXISTS (SELECT 1 FROM pg_locks WHERE pid = v_pid AND NOT granted)
         AND v_b = ANY (pg_blocking_pids(v_pid))
         AND EXISTS (SELECT 1 FROM pg_locks
                     WHERE pid = v_pid AND relation = '$rel'::regclass
                       AND (locktype = 'tuple' OR (locktype = 'relation' AND NOT granted))) THEN
        RAISE NOTICE 'WAIT_SEEN'; RETURN;
      END IF;
    ELSIF v_seen THEN
      RAISE NOTICE 'WAIT_GONE'; RETURN;
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE NOTICE 'WAIT_TIMEOUT';
END \$\$;
SQL
)
  [[ "$out" == *WAIT_SEEN* ]]
}

# ¿El proceso en background $1 terminó dentro de $2 × 0.1 s?
bg_done_within() {
  for _ in $(seq 1 "$2"); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

no_deadlock() {  # $1 etiqueta, $2 archivo
  grep -qiE 'deadlock|40P01' "$2" && { echo "  $1: DEADLOCK — $(tr '\n' ' ' < "$2")"; return 1; }
  grep -qiE 'statement timeout|canceling statement' "$2" && { echo "  $1: COLGADO (statement_timeout) — $(tr '\n' ' ' < "$2")"; return 1; }
  return 0
}

# Invariante global: ningún pending_cae vivo con importe o venta que no son los
# de su orden. Devuelve la cantidad de filas que lo violan (en toda la cuenta);
# cada caso compara contra la foto tomada al empezar (D0) → daño NUEVO.
damage_count() {
  q "SELECT count(*) FROM public.fiscal_documents fd
     JOIN public.sales_orders so ON so.fiscal_document_id = fd.id
     WHERE fd.account_id = '$ACCOUNT_ID' AND fd.status = 'pending_cae'
       AND ( NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.operation_id = so.sale_operation_id)
             OR round(fd.total, 2) <> (SELECT round(sum(s.total), 2) FROM public.sales s WHERE s.operation_id = so.sale_operation_id) );"
}

declare -A PASS
for c in R1 R1b R2 R3 R4 R5 R6; do PASS[$c]=0; done
DAMAGE_TOTAL=0

# ═════════════════════════════════════════════════════════════════════════════
# R0 (una vez) — tenencia: la promoción de OTRA cuenta no bloquea filas ajenas.
# ═════════════════════════════════════════════════════════════════════════════
new_sale
psql "$DB_URL" -X -q -t -A > "$TMP/r0.txt" 2>&1 <<SQL &
SET application_name = 'fvm_r0_foreign';
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_B', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_B', true);
DO \$\$
DECLARE v_state text; v_msg text;
BEGIN
  PERFORM public.rpc_promote_legacy_sale_to_order('$OP'::uuid);
  RAISE NOTICE 'R0_PROMOTE_OK (no debía)';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RAISE NOTICE 'R0_PROMOTE_ERR sqlstate=%', v_state;
END \$\$;
-- La transacción QUEDA ABIERTA: si la promoción hubiera tomado filas ajenas,
-- seguirían tomadas acá.
SELECT pg_advisory_xact_lock($KEY_E);
SELECT pg_sleep(30);
ROLLBACK;
SQL
R0_BG=$!; BG_PIDS+=($R0_BG)
wait_advisory "$KEY_E" || fail "R0: la sesión de la otra cuenta nunca llegó a su advisory. Salida: $(cat "$TMP/r0.txt")"
R0_NOWAIT=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
BEGIN;
SELECT 'LOCKED=' || count(*) FROM (SELECT id FROM public.sales WHERE operation_id = '$OP' FOR UPDATE NOWAIT) x;
ROLLBACK;
SQL
)
q "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND objid = $KEY_E AND pid <> pg_backend_pid();" >/dev/null
wait "$R0_BG" 2>/dev/null
grep -q 'R0_PROMOTE_ERR sqlstate=P0404' "$TMP/r0.txt" || fail "R0: la promoción desde otra cuenta debía dar P0404. Salida: $(cat "$TMP/r0.txt")"
echo "$R0_NOWAIT" | grep -q 'LOCKED=1' || fail "R0: con la promoción ajena rechazada y su transacción abierta, las filas de la venta tenían que estar LIBRES (FOR UPDATE NOWAIT). Salida: $R0_NOWAIT"
echo "PASS R0: la promoción desde otra cuenta da P0404 y no deja bloqueada ninguna fila ajena."

# ═════════════════════════════════════════════════════════════════════════════
for i in $(seq 1 "$ITER"); do
  # ── R1: promoción frenada (orden creada, sin commit) → edición ────────────
  ok=1
  new_sale
  D0=$(damage_count)
  brake_bg items
  promote_bg "fvm_r1_promote_$i" "$OP" "$TMP/a.txt"; A_BG=$LAST_BG
  seen_blocked_by "fvm_r1_promote_$i" brake public.sales_order_items || { echo "  R1#$i INCONCLUSO: la promoción no quedó frenada en sales_order_items"; ok=0; }
  edit_bg "fvm_r1_edit_$i" "$SALE" "$TMP/b.txt"; B_BG=$LAST_BG
  if ! seen_blocked_by "fvm_r1_edit_$i" "fvm_r1_promote_$i" public.sales; then
    echo "  R1#$i INCONCLUSO/FAIL: la edición NO esperó a la promoción sobre las filas de sales (sin exclusión: no ve la orden que se está creando)"; ok=0
  fi
  release_brake
  wait "$A_BG" 2>/dev/null; wait "$B_BG" 2>/dev/null
  no_deadlock "R1#$i A" "$TMP/a.txt" || ok=0; no_deadlock "R1#$i B" "$TMP/b.txt" || ok=0
  SO=$(grep -o 'PROMOTE_OK so=[0-9a-f-]*' "$TMP/a.txt" | cut -d= -f2)
  [ -n "$SO" ] || { echo "  R1#$i: sin PROMOTE_OK — $(tr '\n' ' ' < "$TMP/a.txt")"; ok=0; }
  grep -q 'EDIT_OK' "$TMP/b.txt" || { echo "  R1#$i: sin EDIT_OK — $(tr '\n' ' ' < "$TMP/b.txt")"; ok=0; }
  NEWOP=$(grep -o 'EDIT_OK op=[0-9a-f-]*' "$TMP/b.txt" | cut -d= -f2)
  if [ -n "$SO" ]; then
    ROW=$(q "SELECT sale_operation_id || '|' || total FROM public.sales_orders WHERE id = '$SO';")
    [ "$ROW" = "$NEWOP|111.00" ] || { echo "  R1#$i: la orden quedó '$ROW', esperaba '$NEWOP|111.00' (re-apuntada y recalculada)"; ok=0; }
    emit_now "$SO"
    DOC=$(echo "$EMIT_LINE" | grep -o 'EMIT_OK doc=[0-9a-f-]*' | cut -d= -f2)
    if [ -z "$DOC" ]; then echo "  R1#$i: la emisión posterior falló — $(echo "$EMIT_LINE" | tr '\n' ' ')"; ok=0
    else
      T=$(q "SELECT total FROM public.fiscal_documents WHERE id = '$DOC';")
      [ "$T" = "111.00" ] || { echo "  R1#$i: el comprobante salió por $T, esperaba 111.00"; ok=0; }
    fi
  fi
  D=$(( $(damage_count) - D0 )); [ "$D" = "0" ] || { echo "  R1#$i: DAÑO — $D comprobante(s) pending_cae con importes viejos o sin venta"; ok=0; DAMAGE_TOTAL=$((DAMAGE_TOTAL + D)); }
  [ $ok -eq 1 ] && PASS[R1]=$((PASS[R1] + 1))

  # ── R1b: promoción commiteada, EMISIÓN abierta → edición ─────────────────
  ok=1
  new_sale
  D0=$(damage_count)
  promote_bg "fvm_r1b_promote_$i" "$OP" "$TMP/a.txt"; wait "$LAST_BG" 2>/dev/null
  SO=$(grep -o 'PROMOTE_OK so=[0-9a-f-]*' "$TMP/a.txt" | cut -d= -f2)
  [ -n "$SO" ] || { echo "  R1b#$i: sin PROMOTE_OK — $(tr '\n' ' ' < "$TMP/a.txt")"; ok=0; }
  psql "$DB_URL" -X -q -t -A > "$TMP/e.txt" 2>&1 <<SQL &
SET application_name = 'fvm_r1b_emit_$i';
SET statement_timeout = '25s';
BEGIN;
$CLAIMS_A
SELECT 'A_DOC=' || (public.rpc_emit_sale_invoice('$SO'::uuid, '$F_pv'::uuid)->>'fiscal_document_id');
SELECT pg_advisory_xact_lock($KEY_E);
DO \$\$
BEGIN
  FOR v_i IN 1..150 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks WHERE NOT granted AND pid <> pg_backend_pid()
                 AND locktype IN ('transactionid', 'tuple')) THEN
      -- Sostener la orden un rato más: el orquestador tiene que VER a la
      -- edición esperando (desde otra conexión) antes de que esto commitee.
      PERFORM pg_sleep(2);
      RETURN;
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE NOTICE 'A_SIN_ESPERA';
END \$\$;
COMMIT;
SQL
  E_BG=$!; BG_PIDS+=($E_BG)
  wait_advisory "$KEY_E" || { echo "  R1b#$i INCONCLUSO: la emisión abierta nunca llegó a su advisory — $(tr '\n' ' ' < "$TMP/e.txt")"; ok=0; }
  edit_bg "fvm_r1b_edit_$i" "$SALE" "$TMP/b.txt"; B_BG=$LAST_BG
  seen_blocked_by "fvm_r1b_edit_$i" "fvm_r1b_emit_$i" public.sales_orders || { echo "  R1b#$i INCONCLUSO: la edición no esperó a la emisión abierta"; ok=0; }
  wait "$E_BG" 2>/dev/null; wait "$B_BG" 2>/dev/null
  no_deadlock "R1b#$i E" "$TMP/e.txt" || ok=0; no_deadlock "R1b#$i B" "$TMP/b.txt" || ok=0
  ADOC=$(grep -o 'A_DOC=[0-9a-f-]*' "$TMP/e.txt" | cut -d= -f2)
  grep -q 'EDIT_OK .*anulo=t' "$TMP/b.txt" || { echo "  R1b#$i: la edición debía ANULAR el comprobante recién emitido — $(tr '\n' ' ' < "$TMP/b.txt")"; ok=0; }
  if [ -n "$ADOC" ]; then
    ST=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$ADOC';")
    [ "$ST" = "voided" ] || { echo "  R1b#$i: el comprobante de la emisión abierta quedó '$ST'"; ok=0; }
  else echo "  R1b#$i: la emisión abierta no creó comprobante — $(tr '\n' ' ' < "$TMP/e.txt")"; ok=0; fi
  if [ -n "$SO" ]; then
    T=$(q "SELECT total FROM public.sales_orders WHERE id = '$SO';")
    [ "$T" = "111.00" ] || { echo "  R1b#$i: la orden quedó en $T, esperaba 111.00"; ok=0; }
  fi
  D=$(( $(damage_count) - D0 )); [ "$D" = "0" ] || { echo "  R1b#$i: DAÑO — $D"; ok=0; DAMAGE_TOTAL=$((DAMAGE_TOTAL + D)); }
  [ $ok -eq 1 ] && PASS[R1b]=$((PASS[R1b] + 1))

  # ── R2: promoción frenada → borrado ─────────────────────────────────────
  ok=1
  new_sale
  D0=$(damage_count)
  brake_bg items
  promote_bg "fvm_r2_promote_$i" "$OP" "$TMP/a.txt"; A_BG=$LAST_BG
  seen_blocked_by "fvm_r2_promote_$i" brake public.sales_order_items || { echo "  R2#$i INCONCLUSO: la promoción no quedó frenada"; ok=0; }
  delete_bg "fvm_r2_delete_$i" "$OP" "$TMP/b.txt"; B_BG=$LAST_BG
  if ! seen_blocked_by "fvm_r2_delete_$i" "fvm_r2_promote_$i" public.sales; then
    echo "  R2#$i INCONCLUSO/FAIL: el borrado NO esperó a la promoción sobre las filas de sales"; ok=0
  fi
  release_brake
  wait "$A_BG" 2>/dev/null; wait "$B_BG" 2>/dev/null
  no_deadlock "R2#$i A" "$TMP/a.txt" || ok=0; no_deadlock "R2#$i B" "$TMP/b.txt" || ok=0
  SO=$(grep -o 'PROMOTE_OK so=[0-9a-f-]*' "$TMP/a.txt" | cut -d= -f2)
  grep -q 'DELETE_OK found=t' "$TMP/b.txt" || { echo "  R2#$i: sin DELETE_OK — $(tr '\n' ' ' < "$TMP/b.txt")"; ok=0; }
  if [ -n "$SO" ]; then
    ROW=$(q "SELECT status || '|' || COALESCE(sale_operation_id::text, 'null') FROM public.sales_orders WHERE id = '$SO';")
    [ "$ROW" = "canceled|null" ] || { echo "  R2#$i: la orden quedó '$ROW', esperaba canceled|null"; ok=0; }
    emit_now "$SO"
    echo "$EMIT_LINE" | grep -q 'EMIT_ERR sqlstate=P0400' || { echo "  R2#$i: emitir sobre la orden de una venta borrada debía dar P0400 — $(echo "$EMIT_LINE" | tr '\n' ' ')"; ok=0; }
  else echo "  R2#$i: sin PROMOTE_OK — $(tr '\n' ' ' < "$TMP/a.txt")"; ok=0; fi
  D=$(( $(damage_count) - D0 )); [ "$D" = "0" ] || { echo "  R2#$i: DAÑO — $D"; ok=0; DAMAGE_TOTAL=$((DAMAGE_TOTAL + D)); }
  [ $ok -eq 1 ] && PASS[R2]=$((PASS[R2] + 1))

  # ── R3: edición frenada (filas tomadas) → promoción ─────────────────────
  ok=1
  new_sale
  D0=$(damage_count)
  OLDOP=$OP
  brake_bg stock
  edit_bg "fvm_r3_edit_$i" "$SALE" "$TMP/b.txt"; B_BG=$LAST_BG
  seen_blocked_by "fvm_r3_edit_$i" brake public.branch_stock || { echo "  R3#$i INCONCLUSO: la edición no quedó frenada en branch_stock"; ok=0; }
  promote_bg "fvm_r3_promote_$i" "$OP" "$TMP/a.txt"; A_BG=$LAST_BG
  if ! seen_blocked_by "fvm_r3_promote_$i" "fvm_r3_edit_$i" public.sales; then
    echo "  R3#$i FAIL: la promoción NO esperó a la edición sobre las filas de sales"; ok=0
    # Sin exclusión la promoción ya terminó: la emisión de la pantalla llega
    # ANTES de que la edición se lleve las filas — el estado final lo muestra.
    # Si la promoción terminó sola (no hubo exclusión), la emisión de la
    # pantalla llega ANTES de que la edición se lleve las filas.
    if bg_done_within "$A_BG" 50; then
      SO=$(grep -o 'PROMOTE_OK so=[0-9a-f-]*' "$TMP/a.txt" | cut -d= -f2)
      [ -n "$SO" ] && emit_now "$SO"
    fi
  fi
  release_brake
  wait "$A_BG" 2>/dev/null; wait "$B_BG" 2>/dev/null
  no_deadlock "R3#$i A" "$TMP/a.txt" || ok=0; no_deadlock "R3#$i B" "$TMP/b.txt" || ok=0
  grep -q 'EDIT_OK' "$TMP/b.txt" || { echo "  R3#$i: sin EDIT_OK — $(tr '\n' ' ' < "$TMP/b.txt")"; ok=0; }
  grep -q 'PROMOTE_ERR sqlstate=P0404' "$TMP/a.txt" || { echo "  R3#$i: la promoción debía dar P0404 (la venta ya no existe) — $(tr '\n' ' ' < "$TMP/a.txt")"; ok=0; }
  N=$(q "SELECT count(*) FROM public.sales_orders WHERE sale_operation_id = '$OLDOP';")
  [ "$N" = "0" ] || { echo "  R3#$i: quedaron $N órdenes sobre la operación vieja"; ok=0; }
  D=$(( $(damage_count) - D0 )); [ "$D" = "0" ] || { echo "  R3#$i: DAÑO — $D comprobante(s) pending_cae sobre una venta editada"; ok=0; DAMAGE_TOTAL=$((DAMAGE_TOTAL + D)); }
  [ $ok -eq 1 ] && PASS[R3]=$((PASS[R3] + 1))

  # ── R4: borrado frenado → promoción ─────────────────────────────────────
  ok=1
  new_sale
  D0=$(damage_count)
  OLDOP=$OP
  brake_bg stock
  delete_bg "fvm_r4_delete_$i" "$OP" "$TMP/b.txt"; B_BG=$LAST_BG
  seen_blocked_by "fvm_r4_delete_$i" brake public.branch_stock || { echo "  R4#$i INCONCLUSO: el borrado no quedó frenado en branch_stock"; ok=0; }
  promote_bg "fvm_r4_promote_$i" "$OP" "$TMP/a.txt"; A_BG=$LAST_BG
  if ! seen_blocked_by "fvm_r4_promote_$i" "fvm_r4_delete_$i" public.sales; then
    echo "  R4#$i FAIL: la promoción NO esperó al borrado sobre las filas de sales"; ok=0
    # Si la promoción terminó sola (no hubo exclusión), la emisión de la
    # pantalla llega ANTES de que la borrado se lleve las filas.
    if bg_done_within "$A_BG" 50; then
      SO=$(grep -o 'PROMOTE_OK so=[0-9a-f-]*' "$TMP/a.txt" | cut -d= -f2)
      [ -n "$SO" ] && emit_now "$SO"
    fi
  fi
  release_brake
  wait "$A_BG" 2>/dev/null; wait "$B_BG" 2>/dev/null
  no_deadlock "R4#$i A" "$TMP/a.txt" || ok=0; no_deadlock "R4#$i B" "$TMP/b.txt" || ok=0
  grep -q 'DELETE_OK found=t' "$TMP/b.txt" || { echo "  R4#$i: sin DELETE_OK — $(tr '\n' ' ' < "$TMP/b.txt")"; ok=0; }
  grep -q 'PROMOTE_ERR sqlstate=P0404' "$TMP/a.txt" || { echo "  R4#$i: la promoción debía dar P0404 — $(tr '\n' ' ' < "$TMP/a.txt")"; ok=0; }
  N=$(q "SELECT count(*) FROM public.sales_orders WHERE sale_operation_id = '$OLDOP';")
  [ "$N" = "0" ] || { echo "  R4#$i: quedaron $N órdenes sobre la venta borrada"; ok=0; }
  D=$(( $(damage_count) - D0 )); [ "$D" = "0" ] || { echo "  R4#$i: DAÑO — $D comprobante(s) pending_cae sobre una venta borrada"; ok=0; DAMAGE_TOTAL=$((DAMAGE_TOTAL + D)); }
  [ $ok -eq 1 ] && PASS[R4]=$((PASS[R4] + 1))

  # ── R5: dos promociones de la misma operación ───────────────────────────
  ok=1
  new_sale
  D0=$(damage_count)
  brake_bg items
  promote_bg "fvm_r5_promote1_$i" "$OP" "$TMP/a.txt"; A_BG=$LAST_BG
  seen_blocked_by "fvm_r5_promote1_$i" brake public.sales_order_items || { echo "  R5#$i INCONCLUSO: la primera promoción no quedó frenada"; ok=0; }
  promote_bg "fvm_r5_promote2_$i" "$OP" "$TMP/b.txt"; B_BG=$LAST_BG
  seen_blocked_by "fvm_r5_promote2_$i" "fvm_r5_promote1_$i" public.sales || { echo "  R5#$i INCONCLUSO: la segunda promoción no esperó a la primera sobre las filas de sales"; ok=0; }
  release_brake
  wait "$A_BG" 2>/dev/null; wait "$B_BG" 2>/dev/null
  no_deadlock "R5#$i A1" "$TMP/a.txt" || ok=0; no_deadlock "R5#$i A2" "$TMP/b.txt" || ok=0
  SO1=$(grep -o 'PROMOTE_OK so=[0-9a-f-]*' "$TMP/a.txt" | cut -d= -f2)
  SO2=$(grep -o 'PROMOTE_OK so=[0-9a-f-]*' "$TMP/b.txt" | cut -d= -f2)
  { [ -n "$SO1" ] && [ "$SO1" = "$SO2" ]; } || { echo "  R5#$i: las dos promociones debían devolver la MISMA orden ($SO1 / $SO2)"; ok=0; }
  grep -q 'replayed=true' "$TMP/b.txt" || { echo "  R5#$i: la segunda promoción debía ser replay — $(tr '\n' ' ' < "$TMP/b.txt")"; ok=0; }
  N=$(q "SELECT count(*) FROM public.sales_orders WHERE sale_operation_id = '$OP';")
  [ "$N" = "1" ] || { echo "  R5#$i: $N órdenes para la operación, esperaba 1"; ok=0; }
  D=$(( $(damage_count) - D0 )); [ "$D" = "0" ] || { echo "  R5#$i: DAÑO — $D"; ok=0; DAMAGE_TOTAL=$((DAMAGE_TOTAL + D)); }
  [ $ok -eq 1 ] && PASS[R5]=$((PASS[R5] + 1))

  # ── R6: doble "Guardar" — dos ediciones de la misma operación ───────────
  ok=1
  new_sale
  D0=$(damage_count)
  STK0=$(q "SELECT quantity FROM public.branch_stock WHERE product_id = '$F_product' AND branch_id = '$F_branch';")
  T0=$(q "SELECT clock_timestamp();")
  brake_bg stock
  edit_bg "fvm_r6_edit1_$i" "$SALE" "$TMP/a.txt"; A_BG=$LAST_BG
  seen_blocked_by "fvm_r6_edit1_$i" brake public.branch_stock || { echo "  R6#$i INCONCLUSO: la primera edición no quedó frenada en branch_stock"; ok=0; }
  edit_bg "fvm_r6_edit2_$i" "$SALE" "$TMP/b.txt"; B_BG=$LAST_BG
  if ! seen_blocked_by "fvm_r6_edit2_$i" "fvm_r6_edit1_$i" public.sales; then
    echo "  R6#$i FAIL: la segunda edición NO esperó a la primera sobre las filas de sales"; ok=0
  fi
  release_brake
  wait "$A_BG" 2>/dev/null; wait "$B_BG" 2>/dev/null
  no_deadlock "R6#$i E1" "$TMP/a.txt" || ok=0; no_deadlock "R6#$i E2" "$TMP/b.txt" || ok=0
  grep -q 'EDIT_OK' "$TMP/a.txt" || { echo "  R6#$i: la primera edición debía terminar bien — $(tr '\n' ' ' < "$TMP/a.txt")"; ok=0; }
  grep -q 'EDIT_ERR sqlstate=P0404' "$TMP/b.txt" || { echo "  R6#$i: la segunda edición debía dar P0404 (las filas ya no existen) — $(tr '\n' ' ' < "$TMP/b.txt")"; ok=0; }
  N=$(q "SELECT count(*) FROM public.sales WHERE account_id = '$ACCOUNT_ID' AND created_at >= '$T0'::timestamptz;")
  [ "$N" = "1" ] || { echo "  R6#$i: DUPLICADO — $N filas de venta nuevas después de dos ediciones de la misma operación, esperaba 1"; ok=0; }
  N=$(q "SELECT count(*) FROM public.sales WHERE operation_id = '$OP';")
  [ "$N" = "0" ] || { echo "  R6#$i: la operación vieja conserva $N filas"; ok=0; }
  STK=$(q "SELECT (quantity = $STK0 + 1)::text || '|' || quantity FROM public.branch_stock WHERE product_id = '$F_product' AND branch_id = '$F_branch';")
  [ "${STK%%|*}" = "true" ] || { echo "  R6#$i: el stock quedó en ${STK##*|}, esperaba $STK0 + 1 (500 × 2 → 111 × 1, movido UNA vez)"; ok=0; }
  D=$(( $(damage_count) - D0 )); [ "$D" = "0" ] || { echo "  R6#$i: DAÑO — $D"; ok=0; DAMAGE_TOTAL=$((DAMAGE_TOTAL + D)); }
  [ $ok -eq 1 ] && PASS[R6]=$((PASS[R6] + 1))

  echo "iter $i: R1=${PASS[R1]} R1b=${PASS[R1b]} R2=${PASS[R2]} R3=${PASS[R3]} R4=${PASS[R4]} R5=${PASS[R5]} R6=${PASS[R6]}"
done

SUMMARY="R1 PASS=${PASS[R1]}/$ITER  R1b PASS=${PASS[R1b]}/$ITER  R2 PASS=${PASS[R2]}/$ITER  R3 PASS=${PASS[R3]}/$ITER  R4 PASS=${PASS[R4]}/$ITER  R5 PASS=${PASS[R5]}/$ITER  R6 PASS=${PASS[R6]}/$ITER  (comprobantes dañados observados: $DAMAGE_TOTAL)"
echo "$SUMMARY"
for c in R1 R1b R2 R3 R4 R5 R6; do
  [ "${PASS[$c]}" -eq "$ITER" ] || fail "$SUMMARY"
done

cleanup
LEFT=$(q "SELECT count(*) FROM auth.users WHERE email IN ('facturar-venta-race@test.local', 'facturar-venta-race-b@test.local');")
[ "$LEFT" = "0" ] || { echo "GATE FACTURAR-VENTA-MANUAL-RACE FAILED: la limpieza dejó los anchors sintéticos" >&2; exit 1; }
LEFTA=$(q "SELECT count(*) FROM public.accounts WHERE id IN ('$ACCOUNT_ID', '$ACCOUNT_B');")
[ "$LEFTA" = "0" ] || { echo "GATE FACTURAR-VENTA-MANUAL-RACE FAILED: la limpieza dejó las cuentas del fixture" >&2; exit 1; }

echo "GATE FACTURAR-VENTA-MANUAL-RACE PASSED: $SUMMARY — la promoción, la edición y el borrado se excluyen por las filas de la venta (sales → sales_orders → fiscal_documents), sin deadlocks, sin comprobantes vivos con importes viejos, un doble «Guardar» no duplica la operación, y la promoción ajena no bloquea filas. Fixtures limpios."
