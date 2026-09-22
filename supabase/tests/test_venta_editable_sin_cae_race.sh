#!/usr/bin/env bash
# =============================================================================
# GATE: test_venta_editable_sin_cae_race.sh
# CHANGE: venta-editable-sin-cae (20261060000001) — governance CRÍTICO
#
# Caso (c) de la prueba de exclusión edición-vs-relay: el relay tiene la fila de
# fiscal_documents TOMADA (SELECT ... FOR UPDATE, todavía sin commitear) y la
# edición de la venta entra en el medio. El helper _fiscal_void_pending_for_sale_edit
# pide el lock con FOR UPDATE **NOWAIT**, así que:
#
#   · NO se cuelga esperando (con un FOR UPDATE a secas el request del usuario
#     quedaría bloqueado detrás de un round-trip SOAP a ARCA), y
#   · NO anula nada: traduce 55P03 (lock_not_available) a P0423 con el token
#     TRANSITORIO `fiscal_document_claim_in_flight`, que el frontend muestra
#     como "probá de nuevo en unos minutos".
#
# Después, liberado el lock, el MISMO pedido de edición funciona — sin eso, el
# gate no distinguiría "NOWAIT rechaza" de "la edición está rota".
#
# ESTO NO SE PUEDE PROBAR EN UN SOLO ARCHIVO .sql: una sesión nunca bloquea
# contra su propio lock. Hacen falta DOS backends reales. dblink no sirve en
# este entorno (el rol `postgres` de Supabase NO es superusuario, así que
# dblink_connect rechaza la conexión local por trust y dblink_connect_u no se
# puede otorgar) — de ahí los dos `psql`.
#
# La sincronización es DETERMINÍSTICA, no por sleep: la sesión A toma primero
# el lock de fila y RECIÉN DESPUÉS un advisory lock, que sí es observable en
# pg_locks. Cuando este script ve el advisory, el lock de fila ya está tomado.
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_venta_editable_sin_cae_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961060001

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

fail() { echo "GATE VENTA-EDITABLE-SIN-CAE-RACE FAILED: $*" >&2; cleanup; exit 1; }

USER_ID=""
ACCOUNT_ID=""

cleanup() {
  [ -n "${A_PID:-}" ] && kill "$A_PID" 2>/dev/null
  # Liberar el backend de la sesión A si quedó vivo con el lock tomado.
  psql "$DB_URL" -X -q -t -A -c "
    SELECT pg_terminate_backend(l.pid)
    FROM pg_locks l
    WHERE l.locktype = 'advisory' AND l.objid = $ADVISORY_KEY AND l.pid <> pg_backend_pid();" >/dev/null 2>&1
  if [ -n "$ACCOUNT_ID" ]; then
    psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL
DO \$\$
DECLARE v_account uuid := '$ACCOUNT_ID'; v_user uuid := '$USER_ID';
BEGIN
  DELETE FROM public.sales_orders            WHERE account_id = v_account;
  DELETE FROM public.document_status_history WHERE account_id = v_account;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account;
  DELETE FROM public.points_of_sale          WHERE account_id = v_account;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account;
  DELETE FROM public.sale_items              WHERE account_id = v_account;
  DELETE FROM public.stock_movements         WHERE account_id = v_account;
  DELETE FROM public.sales                   WHERE account_id = v_account;
  DELETE FROM public.events                  WHERE account_id = v_account;
  DELETE FROM public.branch_stock            WHERE account_id = v_account;
  DELETE FROM public.products                WHERE account_id = v_account;
  DELETE FROM public.clients                 WHERE account_id = v_account;
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
# Anchor sintético + venta + orden + comprobante pending_cae SIN marca.
FIXTURE=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<'SQL'
DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
  v_client  uuid;
  v_product uuid;
  v_fp      uuid;
  v_pv      uuid;
  v_result  jsonb;
  v_op      uuid;
  v_sale    uuid;
  v_so      uuid;
  v_doc     uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'venta-editable-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Venta Editable Race', 'phone', '', 'locality', '', 'province', ''));

  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta del anchor';
  END IF;

  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user, v_account, '__gate_vesc_race_client__') RETURNING id INTO v_client;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_vesc_race_product__', 'VESC-RACE-1', 300, 500)
  RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 200);

  -- CUIT y punto de venta propios (fn_guard_pos_cuit_cross_account, P0435).
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account, '20999999996', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fp;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, v_account, 9701, true) RETURNING id INTO v_pv;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);

  v_result := public.rpc_create_sale_operation(
    'vesc-race-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op AND product_id = v_product;

  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_account, v_branch, v_client, 'confirmed', 1000, v_user, v_op)
  RETURNING id INTO v_so;

  v_doc := (public.rpc_emit_sale_invoice(v_so, v_pv)->>'fiscal_document_id')::uuid;

  CREATE TEMP TABLE IF NOT EXISTS _race_out (k text, v text);
  DELETE FROM _race_out;
  INSERT INTO _race_out VALUES
    ('user', v_user::text), ('account', v_account::text), ('client', v_client::text),
    ('product', v_product::text), ('sale', v_sale::text), ('doc', v_doc::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _race_out;
SQL
) || fail "no se pudo sembrar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z]+=' | sed 's/^/RACE_/')"
USER_ID="$RACE_user"; ACCOUNT_ID="$RACE_account"
[ -n "${RACE_doc:-}" ] || fail "el fixture no devolvió el fiscal_document_id"
echo "fixture: doc=$RACE_doc sale=$RACE_sale account=$ACCOUNT_ID"

STATUS=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$RACE_doc';")
[ "$STATUS" = "pending_cae" ] || fail "el comprobante del fixture debía nacer pending_cae, nació '$STATUS'"

# ── Sesión A: simula el relay con la fila TOMADA y sin commitear ─────────────
# Orden deliberado: PRIMERO el lock de fila, DESPUÉS el advisory. Así, cuando
# el advisory aparece en pg_locks, el lock de fila ya está garantizado.
psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
BEGIN;
SELECT id FROM public.fiscal_documents WHERE id = '$RACE_doc' FOR UPDATE;
SELECT pg_advisory_xact_lock($ADVISORY_KEY);
SELECT pg_sleep(60);
ROLLBACK;
SQL
A_PID=$!

# Espera DETERMINÍSTICA de que A tenga los dos locks (máx. ~20 s).
for _ in $(seq 1 200); do
  HELD=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
  [ "${HELD:-0}" -ge 1 ] && break
  q "SELECT pg_sleep(0.1);" >/dev/null
done
[ "${HELD:-0}" -ge 1 ] || fail "la sesión A nunca tomó el lock (advisory $ADVISORY_KEY ausente de pg_locks)"
echo "sesion A: fila de fiscal_documents TOMADA (lock de fila + advisory visibles)"

# ── Sesión B: la edición. Debe rechazar con P0423 y NO colgarse ──────────────
B_OUT=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
-- Red de seguridad: con el NOWAIT no debería esperar NADA. Si algún día se
-- cambia por un FOR UPDATE a secas, el timeout lo delata en vez de dejar el
-- gate colgado hasta que CI lo mate. Session-level (no SET LOCAL: fuera de un
-- bloque de transacción SET LOCAL sólo emite un WARNING y no hace nada).
SET statement_timeout = '15s';
-- Un solo bloque de transacción: set_config(..., is_local => true) muere al
-- final de SU transacción, y en autocommit cada statement es una transacción
-- propia — sin el BEGIN, auth.uid() ya no ve los claims en el DO de abajo y la
-- RPC contesta 42501 "Not authenticated" en vez de ejercitar la carrera.
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
DO \$\$
DECLARE v_sqlstate text; v_msg text;
BEGIN
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY['$RACE_sale'::uuid], '$RACE_client'::uuid, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', '$RACE_product'::uuid, 'amount', 500.00, 'quantity', 7))
    );
    RAISE EXCEPTION 'RACE_FAIL: la edición NO debía poder anular con la fila tomada por el relay';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
  END;
  RAISE NOTICE 'RACE_B sqlstate=% msg=%', v_sqlstate, v_msg;
END \$\$;
ROLLBACK;
SQL
)
echo "$B_OUT" | grep -q 'sqlstate=P0423' \
  || fail "la edición debía rechazar con P0423 mientras el relay tiene la fila tomada. Salida: $B_OUT"
echo "$B_OUT" | grep -q 'fiscal_document_claim_in_flight' \
  || fail "esperaba el token TRANSITORIO fiscal_document_claim_in_flight (no uno terminal). Salida: $B_OUT"
echo "$B_OUT" | grep -qi 'statement timeout\|canceling statement' \
  && fail "la edición se COLGÓ esperando el lock: falta el NOWAIT. Salida: $B_OUT"
echo "PASS (c): con la fila tomada por el relay, la edición rechaza con P0423/fiscal_document_claim_in_flight sin colgarse (NOWAIT)."

STATUS=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$RACE_doc';")
[ "$STATUS" = "pending_cae" ] || fail "el comprobante NO debía anularse durante la carrera, quedó '$STATUS'"
HIST=$(q "SELECT count(*) FROM public.document_status_history WHERE document_id = '$RACE_doc' AND to_status = 'voided';")
[ "$HIST" = "0" ] || fail "no debía escribirse ninguna transición a voided durante la carrera (hay $HIST)"
echo "PASS (c-intacto): el comprobante sigue pending_cae y no hay transición a voided."

# ── Liberar la sesión A y reintentar: el MISMO pedido debe funcionar ─────────
q "SELECT pg_terminate_backend(l.pid) FROM pg_locks l
   WHERE l.locktype = 'advisory' AND l.objid = $ADVISORY_KEY AND l.pid <> pg_backend_pid();" >/dev/null
wait "$A_PID" 2>/dev/null
A_PID=""

for _ in $(seq 1 100); do
  HELD=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
  [ "${HELD:-1}" -eq 0 ] && break
  q "SELECT pg_sleep(0.1);" >/dev/null
done

RETRY_OUT=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
SELECT public.rpc_atomic_update_sale_operation(
  ARRAY['$RACE_sale'::uuid], '$RACE_client'::uuid, CURRENT_DATE, 'ARS',
  jsonb_build_array(jsonb_build_object('product_id', '$RACE_product'::uuid, 'amount', 500.00, 'quantity', 7))
)->>'voided_fiscal_document' IS NOT NULL AS anulo;
COMMIT;
SQL
)
echo "$RETRY_OUT" | tail -1 | grep -q '^t$' \
  || fail "liberado el lock, el MISMO pedido de edición debía funcionar y anular el comprobante. Salida: $RETRY_OUT"

STATUS=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$RACE_doc';")
[ "$STATUS" = "voided" ] || fail "tras el reintento el comprobante debía quedar voided, quedó '$STATUS'"
echo "PASS (c-reintento): liberado el lock, el mismo pedido edita y anula — el rechazo era TRANSITORIO, no un bloqueo permanente."

cleanup
LEFT=$(q "SELECT count(*) FROM auth.users WHERE email = 'venta-editable-race@test.local';")
[ "$LEFT" = "0" ] || { echo "GATE VENTA-EDITABLE-SIN-CAE-RACE FAILED: la limpieza dejó el anchor sintético" >&2; exit 1; }

echo "GATE VENTA-EDITABLE-SIN-CAE-RACE PASSED: caso (c) de la prueba de exclusión — NOWAIT rechaza sin colgar, no anula nada, y el reintento funciona. Fixtures limpios."
