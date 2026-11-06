#!/usr/bin/env bash
# =============================================================================
# GATE: test_productos_padre_variantes_race.sh
# CHANGE: productos-padre-variantes (20261093000001) — tanda A, tarea 4.3/4.4
#
# Carrera entre la CORRECCIÓN DE LA UNIDAD DE UNA FAMILIA (rpc_relabel_product_unit,
# que cambia la unidad con stock/historia y por eso sale del guard con el GUC
# products.unit_relabel_root) y una COMPRA de una variante de esa familia.
#
# La garantía que se verifica (spec units-of-measure, "Corrección concurrente con
# una compra"): la que llega SEGUNDA espera la fila del producto y decide sobre lo
# commiteado; NUNCA queda stock grabado en una unidad distinta de la base efectiva.
#
#   (a) relabel ABIERTO vs compra de la variante en gramos -> la compra espera las
#       variantes que la RPC tomó FOR UPDATE, lee la unidad NUEVA ('u') y termina en
#       P0400 unit_type_mismatch; sin stock, sin movimiento y sin fila de compra.
#   (b) compra de la variante ABIERTA vs relabel -> el relabel espera la fila de la
#       variante; al seguir ve la línea grabada en gramos y termina en P0409
#       unit_relabel_conflict; la unidad de la familia no cambió y el stock sigue en kg.
#
# Esto NO se puede probar en un solo .sql: una sesión nunca bloquea contra su propio
# lock (mismo patrón que test_ventas_unidades_conversion_race.sh: advisory lock
# visible en pg_locks + espera a VER a la otra sesión bloqueada, sin sleeps).
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_productos_padre_variantes_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961093001

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

fail() { echo "GATE PRODUCTOS-PADRE-VARIANTES-RACE FAILED: $*" >&2; cleanup; exit 1; }

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
  DELETE FROM public.events                WHERE account_id = v_account;
  DELETE FROM public.email_logs            WHERE user_id = v_user;
  DELETE FROM public.operation_idempotency WHERE user_id = v_user;
  SET session_replication_role = replica;
  DELETE FROM public.purchase_items        WHERE account_id = v_account;
  DELETE FROM public.purchases             WHERE account_id = v_account OR user_id = v_user;
  DELETE FROM public.stock_movements       WHERE account_id = v_account OR user_id = v_user;
  DELETE FROM public.branch_stock          WHERE account_id = v_account;
  DELETE FROM public.products              WHERE account_id = v_account OR user_id = v_user;
  DELETE FROM public.units_of_measure      WHERE account_id = v_account;
  DELETE FROM public.payment_methods       WHERE account_id = v_account;
  DELETE FROM public.product_categories    WHERE account_id = v_account;
  DELETE FROM public.cashboxes             WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account);
  DELETE FROM public.branches              WHERE account_id = v_account;
  DELETE FROM public.audit_logs            WHERE account_id = v_account;
  DELETE FROM public.accounts              WHERE id = v_account;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id = v_account;
  DELETE FROM public.account_members       WHERE user_id = v_user;
  DELETE FROM public.profiles              WHERE id = v_user;
  DELETE FROM auth.users                   WHERE id = v_user;
  DELETE FROM public.audit_logs            WHERE account_id = v_account;
END \$\$;
SQL
  fi
}

# ── Fixture ──────────────────────────────────────────────────────────────────
# Cuenta real vía handle_new_user (el usuario es el DUEÑO: puede corregir la unidad);
# unidades kg / g / u de la cuenta; dos familias (padre variant_only en kg + variante
# que hereda) SIN stock ni movimientos.
FIXTURE=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<'SQL'
DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
  v_kg      uuid;
  v_g       uuid;
  v_u       uuid;
  v_pa      uuid;   -- (a) padre en kg
  v_va      uuid;   -- (a) variante que hereda kg
  v_pb      uuid;   -- (b) padre en kg
  v_vb      uuid;   -- (b) variante que hereda kg
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'productos-padre-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Productos Padre Race', 'phone', '', 'locality', '', 'province', ''));

  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta del anchor';
  END IF;
  v_branch := public.c26_default_branch(v_account);

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account, 'Kilogramo PPVR', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account, 'Gramo PPVR', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account, 'Unidad PPVR', 'u', 'unit', 1, false) RETURNING id INTO v_u;

  INSERT INTO public.products (user_id, account_id, name, sku, base_unit_id, stock_control_type)
  VALUES (v_user, v_account, 'Queso PPVR A (padre kg)', 'PPVR-PA', v_kg, 'variant_only') RETURNING id INTO v_pa;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user, v_account, 'Queso PPVR A horma', 'PPVR-VA', 900, 1800, v_pa, true) RETURNING id INTO v_va;
  INSERT INTO public.products (user_id, account_id, name, sku, base_unit_id, stock_control_type)
  VALUES (v_user, v_account, 'Queso PPVR B (padre kg)', 'PPVR-PB', v_kg, 'variant_only') RETURNING id INTO v_pb;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user, v_account, 'Queso PPVR B horma', 'PPVR-VB', 900, 1800, v_pb, true) RETURNING id INTO v_vb;

  CREATE TEMP TABLE IF NOT EXISTS _race_out (k text, v text);
  DELETE FROM _race_out;
  INSERT INTO _race_out VALUES
    ('user', v_user::text), ('account', v_account::text), ('branch', v_branch::text),
    ('kg', v_kg::text), ('g', v_g::text), ('u', v_u::text),
    ('pa', v_pa::text), ('va', v_va::text), ('pb', v_pb::text), ('vb', v_vb::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _race_out;
SQL
) || fail "no se pudo sembrar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z]+=' | sed 's/^/R_/')"
USER_ID="$R_user"; ACCOUNT_ID="$R_account"
[ -n "${R_va:-}" ] && [ -n "${R_vb:-}" ] || fail "el fixture no devolvió los productos"
echo "fixture: account=$ACCOUNT_ID branch=$R_branch"

# ── Helpers ──────────────────────────────────────────────────────────────────

wait_for_a() {
  local held
  for _ in $(seq 1 200); do
    held=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
    [ "${held:-0}" -ge 1 ] && return 0
    q "SELECT pg_sleep(0.1);" >/dev/null
  done
  fail "la sesión A nunca tomó el lock (advisory $ADVISORY_KEY ausente de pg_locks)"
}

# Bloque de la sesión A: toma el advisory DESPUÉS de sus locks de fila y espera a VER
# a la otra sesión bloqueada (pg_locks, no pg_stat_activity: las vistas pg_stat_* se
# congelan por transacción) antes de commitear.
A_WAIT_BLOCK="
SELECT pg_advisory_xact_lock($ADVISORY_KEY);
DO \$\$
DECLARE v_i int;
BEGIN
  FOR v_i IN 1..300 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks
               WHERE NOT granted AND pid <> pg_backend_pid()
                 AND locktype IN ('transactionid', 'tuple')) THEN
      RETURN;
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE NOTICE 'A_SIN_ESPERA: nadie se bloqueó detrás de la fila';
END \$\$;"

CLAIMS="
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);"

# La compra, tal como la llama el backend. Imprime PURCHASE_OK o PURCHASE_ERR.
purchase() {  # $1 = product_id, $2 = quantity, $3 = unit_id
  psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
BEGIN;
$CLAIMS
DO \$\$
DECLARE v_sqlstate text; v_msg text;
BEGIN
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      'ppvr-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate PPVR',
      jsonb_build_array(jsonb_build_object('product_id', '$1'::uuid, 'amount', 0.90, 'quantity', $2, 'unit_id', '$3'::uuid)),
      '$R_branch'::uuid);
    RAISE NOTICE 'PURCHASE_OK';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
    RAISE NOTICE 'PURCHASE_ERR sqlstate=% msg=%', v_sqlstate, v_msg;
  END;
END \$\$;
COMMIT;
SQL
}

stock_of()     { q "SELECT COALESCE(SUM(quantity), 0)::numeric(15,4) FROM public.branch_stock WHERE product_id = '$1';"; }
movements_of() { q "SELECT count(*) FROM public.stock_movements WHERE product_id = '$1';"; }
purchases_of() { q "SELECT count(*) FROM public.purchases WHERE product_id = '$1';"; }
base_of()      { q "SELECT COALESCE(base_unit_id::text, 'NULL') FROM public.products WHERE id = '$1';"; }

# ═════════════════════════════════════════════════════════════════════════════
# (a) Relabel ABIERTO vs compra de la variante en gramos
# ═════════════════════════════════════════════════════════════════════════════
psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
BEGIN;
$CLAIMS
SELECT public.rpc_relabel_product_unit('$R_pa'::uuid, '$R_u'::uuid, false);
$A_WAIT_BLOCK
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesión A: corrección de la unidad de la familia kg → u ABIERTA (la RPC tomó la raíz y la variante FOR UPDATE)"
B_OUT=$(purchase "$R_va" 2000 "$R_g")
wait "$A_PID" 2>/dev/null
A_PID=""

[ "$(base_of "$R_pa")" = "$R_u" ] || fail "(a): la corrección de la sesión A no commiteó (base $(base_of "$R_pa"))"
[ "$(base_of "$R_va")" = "NULL" ] || fail "(a): la variante debía quedar heredando (base propia NULL), tiene $(base_of "$R_va")"
echo "$B_OUT" | grep -q 'PURCHASE_ERR sqlstate=P0400' \
  || fail "(a): la compra de 2000 g tenía que terminar en P0400 (la familia ya es 'u'). Salida: $B_OUT | stock=$(stock_of "$R_va") movimientos=$(movements_of "$R_va")"
echo "$B_OUT" | grep -q 'unit_type_mismatch' || fail "(a): el rechazo tenía que ser unit_type_mismatch. Salida: $B_OUT"
[ "$(stock_of "$R_va")" = "0.0000" ] || fail "(a): quedó stock $(stock_of "$R_va") en una familia que ya es 'u'"
[ "$(movements_of "$R_va")" = "0" ] || fail "(a): quedaron $(movements_of "$R_va") movimientos de stock"
[ "$(purchases_of "$R_va")" = "0" ] || fail "(a): quedó una fila de compra"
echo "PASS (a): con el relabel abierto, la compra espera la fila, lee la unidad NUEVA y rechaza la línea en g (P0400) — nada quedó escrito en la unidad vieja."

# ═════════════════════════════════════════════════════════════════════════════
# (b) Compra de la variante ABIERTA vs relabel
# ═════════════════════════════════════════════════════════════════════════════
psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
BEGIN;
$CLAIMS
SELECT public.rpc_create_purchase_operation(
  'ppvr-b-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate PPVR (b)',
  jsonb_build_array(jsonb_build_object('product_id', '$R_vb'::uuid, 'amount', 0.90, 'quantity', 2000, 'unit_id', '$R_g'::uuid)),
  '$R_branch'::uuid);
$A_WAIT_BLOCK
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesión A: compra de 2000 g de la variante ABIERTA (fila de la variante tomada FOR UPDATE)"
B_OUT=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
BEGIN;
$CLAIMS
DO \$\$
DECLARE v_sqlstate text; v_msg text;
BEGIN
  PERFORM public.rpc_relabel_product_unit('$R_pb'::uuid, '$R_u'::uuid, false);
  RAISE NOTICE 'RELABEL_OK';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
  v_msg := SQLERRM;
  RAISE NOTICE 'RELABEL_ERR sqlstate=% msg=%', v_sqlstate, v_msg;
END \$\$;
COMMIT;
SQL
)
wait "$A_PID" 2>/dev/null
A_PID=""

echo "$B_OUT" | grep -q 'RELABEL_ERR sqlstate=P0409' \
  || fail "(b): el relabel tenía que esperar la compra y terminar en P0409 unit_relabel_conflict. Salida: $B_OUT | base de la familia=$(base_of "$R_pb")"
echo "$B_OUT" | grep -q 'unit_relabel_conflict' || fail "(b): el rechazo tenía que ser unit_relabel_conflict. Salida: $B_OUT"
[ "$(base_of "$R_pb")" = "$R_kg" ] || fail "(b): la unidad de la familia cambió debajo del stock ($(base_of "$R_pb"))"
[ "$(stock_of "$R_vb")" = "2.0000" ] || fail "(b): el stock quedó en $(stock_of "$R_vb"), esperaba 2 (kg)"
echo "PASS (b): con la compra abierta, el relabel espera la fila, ve la línea en g commiteada y rechaza con P0409 unit_relabel_conflict."

cleanup
LEFT=$(q "SELECT count(*) FROM public.products WHERE account_id = '$ACCOUNT_ID' OR user_id = '$USER_ID';")
[ "$LEFT" = "0" ] || { echo "GATE PRODUCTOS-PADRE-VARIANTES-RACE FAILED: el cleanup dejó $LEFT productos" >&2; exit 1; }
echo "GATE PRODUCTOS-PADRE-VARIANTES-RACE PASSED: corrección de unidad de una familia vs compra de una variante en los dos órdenes — nunca queda stock en una unidad distinta de la base efectiva. Fixtures limpios."
