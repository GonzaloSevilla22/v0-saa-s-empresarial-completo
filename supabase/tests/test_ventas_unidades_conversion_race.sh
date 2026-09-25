#!/usr/bin/env bash
# =============================================================================
# GATE: test_ventas_unidades_conversion_race.sh
# CHANGE: ventas-unidades-conversion (20261062000001) — tercera revisión del
#         PR #584 (fix-round 2, 2026-09-25)
#
# Carrera entre un CAMBIO DE UNIDAD BASE y una COMPRA del mismo producto. El
# guard de la unidad base (trg_product_base_unit_guard, P0409
# base_unit_locked) se evalúa en el momento del UPDATE, antes del commit: con
# 0 stock y 0 movimientos deja cambiar kg → u. Si en ese instante una compra
# NORMALIZA la cantidad con la unidad base COMMITEADA (kg) y recién después
# toma la fila del producto FOR UPDATE, espera al UPDATE, y al seguir escribe
# 2 (kg) sobre un producto cuya unidad ya es 'u': 2 kg pasan a leerse 2 u, y
# la línea queda en g sobre una base 'u' (una edición posterior da P0400).
# Reproducido por la revisión con dos conexiones (redteam-2/toctou):
#   FINAL base=u stock=2.0000 movimientos=1 delta=2.0000 linea_unit=g
#
# La corrección: en los seis caminos que escriben stock la cantidad se
# normaliza DESPUÉS del SELECT … FROM products … FOR UPDATE. Cuando la
# compra obtiene el lock, READ COMMITTED le da una foto nueva: el helper lee
# la unidad base nueva y rechaza la línea en g con P0400 unit_type_mismatch.
#
# Tres casos, los tres con DOS conexiones reales:
#   (a) cambio de unidad base ABIERTO vs compra → la compra termina en P0400,
#       sin stock, sin movimiento y sin fila de compra.
#   (b) compra ABIERTA vs cambio de unidad base → el cambio espera la fila,
#       ve el stock y el movimiento commiteados y termina en P0409.
#   (c) una VARIANTE que hereda la unidad del padre: cambio de la unidad del
#       PADRE abierto (el trigger toma la variante FOR UPDATE) vs compra de la
#       variante → P0400; la variante no queda con stock en la unidad vieja.
#
# Sólo la COMPRA es alcanzable: una venta necesita stock > 0 en la sucursal,
# y con stock distinto de 0 el trigger ya rechaza el cambio de unidad base —
# en una venta la carrera no puede escribir nada. Los tres caminos de venta
# se reordenaron igual (el gate .sql lo verifica por introspección).
#
# ESTO NO SE PUEDE PROBAR EN UN SOLO .sql: una sesión nunca bloquea contra su
# propio lock (ver test_venta_editable_sin_cae_race.sh — mismo patrón:
# advisory lock visible en pg_locks + espera a VER a la otra sesión bloqueada,
# sin sleeps).
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_ventas_unidades_conversion_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961062001

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

fail() { echo "GATE VENTAS-UNIDADES-CONVERSION-RACE FAILED: $*" >&2; cleanup; exit 1; }

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
# Cuenta real vía handle_new_user; unidades kg / g / u de la cuenta; productos
# SIN stock ni movimientos (condición para que el trigger deje cambiar la base).
FIXTURE=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<'SQL'
DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
  v_kg      uuid;
  v_g       uuid;
  v_u       uuid;
  v_pa      uuid;
  v_pb      uuid;
  v_parent  uuid;
  v_var     uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'ventas-unidades-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Ventas Unidades Race', 'phone', '', 'locality', '', 'province', ''));

  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta del anchor';
  END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account, 'Kilogramo VUCR', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account, 'Gramo VUCR', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account, 'Unidad VUCR', 'u', 'unit', 1, false) RETURNING id INTO v_u;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user, v_account, 'Harina VUCR (a)', 'VUCR-A', 900, 1800, v_kg) RETURNING id INTO v_pa;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user, v_account, 'Harina VUCR (b)', 'VUCR-B', 900, 1800, v_kg) RETURNING id INTO v_pb;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, stock_control_type)
  VALUES (v_user, v_account, 'Queso VUCR (padre kg)', 'VUCR-P', 900, 1800, v_kg, 'variant_only') RETURNING id INTO v_parent;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user, v_account, 'Queso VUCR — horma', 'VUCR-V', 900, 1800, v_parent, true) RETURNING id INTO v_var;

  CREATE TEMP TABLE IF NOT EXISTS _race_out (k text, v text);
  DELETE FROM _race_out;
  INSERT INTO _race_out VALUES
    ('user', v_user::text), ('account', v_account::text), ('branch', v_branch::text),
    ('kg', v_kg::text), ('g', v_g::text), ('u', v_u::text),
    ('pa', v_pa::text), ('pb', v_pb::text), ('parent', v_parent::text), ('var', v_var::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _race_out;
SQL
) || fail "no se pudo sembrar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z]+=' | sed 's/^/R_/')"
USER_ID="$R_user"; ACCOUNT_ID="$R_account"
[ -n "${R_var:-}" ] || fail "el fixture no devolvió los productos"
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

# Bloque de la sesión A: toma el advisory DESPUÉS de su lock de fila y espera
# a VER a la otra sesión bloqueada (pg_locks, no pg_stat_activity: las vistas
# pg_stat_* se congelan por transacción) antes de commitear.
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

# La compra, tal como la llama el backend. Imprime PURCHASE_OK o PURCHASE_ERR.
purchase() {  # $1 = product_id, $2 = quantity, $3 = unit_id
  psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
DO \$\$
DECLARE v_sqlstate text; v_msg text;
BEGIN
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      'vucr-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUCR',
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
# (a) Cambio de unidad base ABIERTO vs compra
# ═════════════════════════════════════════════════════════════════════════════
psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
BEGIN;
UPDATE public.products SET base_unit_id = '$R_u' WHERE id = '$R_pa';
$A_WAIT_BLOCK
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesión A: cambio de unidad base kg → u ABIERTO (el trigger ya lo dejó pasar: 0 stock, 0 movimientos)"
B_OUT=$(purchase "$R_pa" 2000 "$R_g")
wait "$A_PID" 2>/dev/null
A_PID=""

[ "$(base_of "$R_pa")" = "$R_u" ] || fail "(a): el cambio de unidad base de la sesión A no commiteó (base $(base_of "$R_pa"))"
echo "$B_OUT" | grep -q 'PURCHASE_ERR sqlstate=P0400' \
  || fail "(a): la compra de 2000 g tenía que terminar en P0400 (la unidad base ya es 'u'). Salida: $B_OUT | stock=$(stock_of "$R_pa") movimientos=$(movements_of "$R_pa") — si la compra normaliza ANTES del FOR UPDATE escribe 2 kg que se leen 2 u."
echo "$B_OUT" | grep -q 'unit_type_mismatch' || fail "(a): el rechazo tenía que ser unit_type_mismatch. Salida: $B_OUT"
[ "$(stock_of "$R_pa")" = "0.0000" ] || fail "(a): quedó stock $(stock_of "$R_pa") sobre un producto en 'u' por una compra en g"
[ "$(movements_of "$R_pa")" = "0" ] || fail "(a): quedaron $(movements_of "$R_pa") movimientos de stock"
[ "$(purchases_of "$R_pa")" = "0" ] || fail "(a): quedó una fila de compra"
echo "PASS (a): con el cambio de unidad base abierto, la compra espera la fila, lee la unidad NUEVA y rechaza la línea en g (P0400) — nada quedó escrito en la unidad vieja."

# ═════════════════════════════════════════════════════════════════════════════
# (b) Compra ABIERTA vs cambio de unidad base
# ═════════════════════════════════════════════════════════════════════════════
psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
SELECT public.rpc_create_purchase_operation(
  'vucr-b-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUCR (b)',
  jsonb_build_array(jsonb_build_object('product_id', '$R_pb'::uuid, 'amount', 0.90, 'quantity', 2000, 'unit_id', '$R_g'::uuid)),
  '$R_branch'::uuid);
$A_WAIT_BLOCK
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesión A: compra de 2000 g ABIERTA (fila del producto tomada FOR UPDATE)"
B_OUT=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
SET statement_timeout = '25s';
DO \$\$
DECLARE v_sqlstate text; v_msg text;
BEGIN
  UPDATE public.products SET base_unit_id = '$R_u' WHERE id = '$R_pb';
  RAISE NOTICE 'BASE_CHANGE_OK';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
  v_msg := SQLERRM;
  RAISE NOTICE 'BASE_CHANGE_ERR sqlstate=% msg=%', v_sqlstate, v_msg;
END \$\$;
SQL
)
wait "$A_PID" 2>/dev/null
A_PID=""

echo "$B_OUT" | grep -q 'BASE_CHANGE_ERR sqlstate=P0409' \
  || fail "(b): el cambio de unidad base tenía que esperar la compra y terminar en P0409 base_unit_locked. Salida: $B_OUT"
[ "$(base_of "$R_pb")" = "$R_kg" ] || fail "(b): la unidad base cambió debajo del stock ($(base_of "$R_pb"))"
[ "$(stock_of "$R_pb")" = "2.0000" ] || fail "(b): el stock quedó en $(stock_of "$R_pb"), esperaba 2 (kg)"
echo "PASS (b): con la compra abierta, el cambio de unidad base espera la fila, ve el stock commiteado y rechaza con P0409."

# ═════════════════════════════════════════════════════════════════════════════
# (c) Variante que hereda: cambio de la unidad del PADRE abierto vs compra de la variante
# ═════════════════════════════════════════════════════════════════════════════
psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
BEGIN;
UPDATE public.products SET base_unit_id = '$R_u' WHERE id = '$R_parent';
$A_WAIT_BLOCK
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesión A: cambio de unidad base del PADRE kg → u ABIERTO (la variante que hereda quedó tomada FOR UPDATE por el trigger)"
B_OUT=$(purchase "$R_var" 2000 "$R_g")
wait "$A_PID" 2>/dev/null
A_PID=""

[ "$(base_of "$R_parent")" = "$R_u" ] || fail "(c): el cambio de unidad del padre no commiteó"
echo "$B_OUT" | grep -q 'PURCHASE_ERR sqlstate=P0400' \
  || fail "(c): la compra de la variante tenía que terminar en P0400 (hereda 'u'). Salida: $B_OUT | stock=$(stock_of "$R_var")"
[ "$(stock_of "$R_var")" = "0.0000" ] || fail "(c): la variante quedó con stock $(stock_of "$R_var") en la unidad vieja"
[ "$(movements_of "$R_var")" = "0" ] || fail "(c): quedaron movimientos de la variante"
echo "PASS (c): con el cambio de unidad del padre abierto, la compra de la variante espera, lee la unidad heredada NUEVA y rechaza (P0400)."

cleanup
LEFT=$(q "SELECT count(*) FROM public.products WHERE account_id = '$ACCOUNT_ID' OR user_id = '$USER_ID';")
[ "$LEFT" = "0" ] || { echo "GATE VENTAS-UNIDADES-CONVERSION-RACE FAILED: el cleanup dejó $LEFT productos" >&2; exit 1; }
echo "GATE VENTAS-UNIDADES-CONVERSION-RACE PASSED: cambio de unidad base vs compra en las dos direcciones y con herencia de variante — la cantidad se normaliza con la fila tomada. Fixtures limpios."
