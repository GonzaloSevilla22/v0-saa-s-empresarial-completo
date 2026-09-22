#!/usr/bin/env bash
# =============================================================================
# GATE: test_venta_editable_sin_cae_race.sh
# CHANGE: venta-editable-sin-cae (20261060000001) — governance CRÍTICO
#
# Prueba de exclusión de la edición/borrado de una venta contra los DOS otros
# escritores del comprobante: el RELAY (que lo manda a ARCA) y la EMISIÓN (que
# lo crea). Tres casos, los tres con DOS conexiones reales:
#
#   (e) EMISIÓN ABIERTA vs edición — red team 2026-09-22, M1. La emisión toma
#       `sales_orders FOR UPDATE` y RECIÉN DESPUÉS crea el comprobante y lo
#       vincula. Si la edición resuelve "¿hay comprobante?" SIN tomar ese mismo
#       lock, no ve el comprobante que la emisión está por commitear, decide
#       "no hay nada que anular", y deja una venta editada con un comprobante
#       pendiente VIVO por el importe VIEJO: el relay le pide CAE a ARCA por
#       $1000 contra una venta de $111. Es exactamente el daño que este change
#       existe para impedir. El helper tiene que tomar la ORDEN primero y leer
#       `fiscal_document_id` de la fila BLOQUEADA (READ COMMITTED re-evalúa
#       contra la versión más reciente al otorgar el lock).
#
#   (f) ORDEN DE LOCKS — red team 2026-09-22, M2. La emisión bloquea so → fd.
#       Si la edición lo hace al revés (fd → so) las dos se matan con un
#       deadlock 40P01 crudo, que el usuario ve en el camino de dinero en vez
#       de un P0423 traducido (y el NOWAIT no ayuda: quien espera es la
#       emisión). Con el orden unificado so → fd no hay ciclo posible.
#
#   (c) RELAY con la fila TOMADA: el helper pide el lock del comprobante con
#       FOR UPDATE **NOWAIT**, así que NO se cuelga esperando (con un FOR
#       UPDATE a secas el request del usuario quedaría bloqueado detrás de un
#       round-trip SOAP a ARCA) y NO anula nada: traduce 55P03
#       (lock_not_available) a P0423 con el token TRANSITORIO
#       `fiscal_document_claim_in_flight`. Después, liberado el lock, el MISMO
#       pedido funciona — sin eso, el gate no distinguiría "NOWAIT rechaza" de
#       "la edición está rota".
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
# En (e) y (f) la sesión A además espera a VER a la edición bloqueada
# (`pg_stat_activity.wait_event_type = 'Lock'`) antes de avanzar: así el
# interleave es el que se quiere probar y no el que salga.
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
# Anchor sintético + venta + orden CONFIRMADA todavía SIN comprobante: el caso
# (e) necesita que la emisión ocurra DENTRO de su transacción abierta. Los
# casos (f) y (c) emiten después, con `emit_now`.
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

  CREATE TEMP TABLE IF NOT EXISTS _race_out (k text, v text);
  DELETE FROM _race_out;
  INSERT INTO _race_out VALUES
    ('user', v_user::text), ('account', v_account::text), ('client', v_client::text),
    ('product', v_product::text), ('sale', v_sale::text), ('so', v_so::text),
    ('pv', v_pv::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _race_out;
SQL
) || fail "no se pudo sembrar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z]+=' | sed 's/^/RACE_/')"
USER_ID="$RACE_user"; ACCOUNT_ID="$RACE_account"
[ -n "${RACE_so:-}" ] || fail "el fixture no devolvió el sales_order_id"
[ -n "${RACE_pv:-}" ] || fail "el fixture no devolvió el punto de venta"
echo "fixture: so=$RACE_so sale=$RACE_sale account=$ACCOUNT_ID"

# ── Helpers ──────────────────────────────────────────────────────────────────

# La edición BORRA las filas de `sales` y crea otras nuevas, así que el id de la
# venta cambia después de cada caso: hay que volver a resolverlo.
resolve_sale() {
  RACE_sale=$(q "SELECT id FROM public.sales WHERE account_id = '$ACCOUNT_ID' ORDER BY created_at DESC LIMIT 1;")
  [ -n "$RACE_sale" ] || fail "no quedó ninguna fila de sales en la cuenta del anchor"
}

# Emite un comprobante nuevo (transacción propia, commiteada). Vale después de
# una anulación: la allow-list de re-emisión habilita 'voided'.
emit_now() {
  local out
  out=$(psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
SELECT 'DOC=' || (public.rpc_emit_sale_invoice('$RACE_so'::uuid, '$RACE_pv'::uuid)->>'fiscal_document_id');
COMMIT;
SQL
)
  RACE_doc=$(echo "$out" | grep -o 'DOC=[0-9a-f-]*' | head -1 | cut -d= -f2)
  [ -n "${RACE_doc:-}" ] || fail "no se pudo emitir el comprobante del fixture. Salida: $out"
  local st
  st=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$RACE_doc';")
  [ "$st" = "pending_cae" ] || fail "el comprobante emitido debía nacer pending_cae, nació '$st'"
}

# Espera (máx. ~20 s) a que la sesión A tenga el advisory lock tomado: cuando
# aparece, el lock de fila que A tomó ANTES ya está garantizado.
wait_for_a() {
  local held
  for _ in $(seq 1 200); do
    held=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
    [ "${held:-0}" -ge 1 ] && return 0
    q "SELECT pg_sleep(0.1);" >/dev/null
  done
  fail "la sesión A nunca tomó el lock (advisory $ADVISORY_KEY ausente de pg_locks)"
}

wait_for_a_gone() {
  local held
  for _ in $(seq 1 200); do
    held=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
    [ "${held:-1}" -eq 0 ] && return 0
    q "SELECT pg_sleep(0.1);" >/dev/null
  done
  fail "la sesión A no soltó el advisory $ADVISORY_KEY"
}

# La edición de la venta, tal como la llama el backend. Imprime el resultado.
edit_sale() {  # $1 = quantity nueva
  psql "$DB_URL" -X -q -t -A 2>&1 <<SQL
-- Red de seguridad: si algún día se pierde el NOWAIT del comprobante, el
-- timeout lo delata en vez de dejar el gate colgado hasta que CI lo mate.
-- Session-level (no SET LOCAL: fuera de un bloque de transacción SET LOCAL
-- sólo emite un WARNING y no hace nada).
SET statement_timeout = '25s';
-- Un solo bloque de transacción: set_config(..., is_local => true) muere al
-- final de SU transacción, y en autocommit cada statement es una transacción
-- propia — sin el BEGIN, auth.uid() ya no ve los claims en el DO de abajo y la
-- RPC contesta 42501 "Not authenticated" en vez de ejercitar la carrera.
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
DO \$\$
DECLARE v_sqlstate text; v_msg text; v_res jsonb;
BEGIN
  BEGIN
    v_res := public.rpc_atomic_update_sale_operation(
      ARRAY['$RACE_sale'::uuid], '$RACE_client'::uuid, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', '$RACE_product'::uuid, 'amount', 500.00, 'quantity', $1))
    );
    RAISE NOTICE 'EDIT_OK anulo=% label=%',
      (v_res->'voided_fiscal_document') IS NOT NULL AND (v_res->'voided_fiscal_document') <> 'null'::jsonb,
      COALESCE(v_res->'voided_fiscal_document'->>'label', '-');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
    RAISE NOTICE 'EDIT_ERR sqlstate=% msg=%', v_sqlstate, v_msg;
  END;
END \$\$;
COMMIT;
SQL
}

assert_no_deadlock() {  # $1 = etiqueta, $2 = salida
  echo "$2" | grep -qiE 'deadlock|40P01' \
    && fail "$1: apareció un DEADLOCK — el orden de locks de la edición no coincide con el de la emisión (so → fd). Salida: $2"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# (e) La EMISIÓN abierta y la edición entrando en el medio (red team M1)
# ═════════════════════════════════════════════════════════════════════════════
A_OUT_E=$(mktemp)
psql "$DB_URL" -X -q -t -A > "$A_OUT_E" 2>&1 <<SQL &
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
-- La emisión real: toma sales_orders FOR UPDATE, crea el comprobante y lo
-- vincula. TODO sin commitear todavía.
SELECT 'A_DOC=' || (public.rpc_emit_sale_invoice('$RACE_so'::uuid, '$RACE_pv'::uuid)->>'fiscal_document_id');
SELECT pg_advisory_xact_lock($ADVISORY_KEY);
-- Espera a VER a la edición bloqueada antes de commitear. Si la edición NO
-- pide el lock de la orden (el bug), nadie se bloquea, este loop se agota a
-- los ~30 s y el gate concluye igual por el ESTADO FINAL del comprobante.
DO \$\$
DECLARE v_i int;
BEGIN
  FOR v_i IN 1..300 LOOP
    -- pg_locks y NO pg_stat_activity: las vistas pg_stat_* se CONGELAN por
    -- transacción (pgstat_read_current_status cachea el snapshot), así que
    -- desde una transacción abierta jamás se vería aparecer al que se bloquea
    -- después. pg_locks lee el lock manager en vivo.
    IF EXISTS (SELECT 1 FROM pg_locks
               WHERE NOT granted AND pid <> pg_backend_pid()
                 AND locktype IN ('transactionid', 'tuple')) THEN
      RETURN;
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE NOTICE 'A_SIN_ESPERA: nadie se bloqueó detrás de la orden';
END \$\$;
COMMIT;
SQL
A_PID=$!
wait_for_a
echo "sesion A: emisión ABIERTA (sales_orders tomada, comprobante creado, sin commitear)"

B_OUT=$(edit_sale 7)
wait "$A_PID" 2>/dev/null
A_PID=""

assert_no_deadlock "(e)" "$B_OUT"
echo "$B_OUT" | grep -q 'EDIT_OK' \
  || fail "(e): la edición debía terminar OK (el comprobante todavía no salió hacia ARCA). Salida: $B_OUT"
echo "$B_OUT" | grep -q 'EDIT_OK anulo=t' \
  || fail "(e): la edición tenía que ANULAR el comprobante que la emisión acababa de crear. Salida: $B_OUT"

E_DOC=$(q "SELECT fiscal_document_id FROM public.sales_orders WHERE id = '$RACE_so';")
[ -n "$E_DOC" ] || fail "(e): la orden quedó sin comprobante vinculado — la emisión de la sesión A no commiteó"
E_STATUS=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$E_DOC';")
[ "$E_STATUS" = "voided" ] \
  || fail "(e): el comprobante creado por la emisión quedó en '$E_STATUS'. Un pending_cae VIVO sobre una venta ya editada es el daño que este change existe para impedir: el relay le pediría CAE a ARCA por el importe VIEJO."
E_PENDING=$(q "SELECT count(*) FROM public.fiscal_documents WHERE account_id = '$ACCOUNT_ID' AND status = 'pending_cae';")
[ "$E_PENDING" = "0" ] || fail "(e): quedaron $E_PENDING comprobantes pending_cae vivos sobre una venta editada"
E_HIST=$(q "SELECT count(*) FROM public.document_status_history WHERE document_id = '$E_DOC' AND to_status = 'voided';")
[ "$E_HIST" = "1" ] || fail "(e): la anulación debía dejar UNA transición a voided en el historial (hay $E_HIST)"
echo "PASS (e): con la emisión abierta, la edición espera la orden, VE el comprobante recién creado y lo anula — no queda ningún pendiente vivo con importes viejos."

# ═════════════════════════════════════════════════════════════════════════════
# (f) Orden de locks: so → fd en las dos direcciones, sin deadlock (red team M2)
# ═════════════════════════════════════════════════════════════════════════════
resolve_sale
emit_now
echo "fixture (f): doc=$RACE_doc sale=$RACE_sale"

A_OUT_F=$(mktemp)
psql "$DB_URL" -X -q -t -A > "$A_OUT_F" 2>&1 <<SQL &
BEGIN;
-- Replica la SECUENCIA de locks de rpc_emit_sale_invoice: primero la orden…
SELECT id FROM public.sales_orders WHERE id = '$RACE_so' FOR UPDATE;
SELECT pg_advisory_xact_lock($ADVISORY_KEY);
DO \$\$
DECLARE v_i int;
BEGIN
  FOR v_i IN 1..300 LOOP
    -- pg_locks y NO pg_stat_activity: las vistas pg_stat_* se CONGELAN por
    -- transacción (pgstat_read_current_status cachea el snapshot), así que
    -- desde una transacción abierta jamás se vería aparecer al que se bloquea
    -- después. pg_locks lee el lock manager en vivo.
    IF EXISTS (SELECT 1 FROM pg_locks
               WHERE NOT granted AND pid <> pg_backend_pid()
                 AND locktype IN ('transactionid', 'tuple')) THEN
      RETURN;
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE NOTICE 'A_SIN_ESPERA: nadie se bloqueó detrás de la orden';
END \$\$;
-- …y DESPUÉS el comprobante. Con la edición tomando los locks al revés
-- (fd → so), acá se cerraba el ciclo y Postgres mataba a una de las dos.
SELECT id FROM public.fiscal_documents WHERE id = '$RACE_doc' FOR UPDATE;
ROLLBACK;
SQL
A_PID=$!
wait_for_a
echo "sesion A: orden tomada, esperando para pedir el comprobante (secuencia de la emisión)"

B_OUT=$(edit_sale 5)
wait "$A_PID" 2>/dev/null
A_PID=""
A_OUT_F_TXT=$(cat "$A_OUT_F"); rm -f "$A_OUT_F"

assert_no_deadlock "(f) sesión B" "$B_OUT"
assert_no_deadlock "(f) sesión A" "$A_OUT_F_TXT"
echo "$B_OUT" | grep -q 'EDIT_OK anulo=t' \
  || fail "(f): la edición debía esperar la orden y anular el comprobante, sin deadlock. Salida B: $B_OUT | Salida A: $A_OUT_F_TXT"
F_STATUS=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$RACE_doc';")
[ "$F_STATUS" = "voided" ] || fail "(f): el comprobante debía quedar voided, quedó '$F_STATUS'"
echo "PASS (f): con la orden tomada por la emisión, la edición espera detrás (so → fd) — ni deadlock ni 40P01 en ninguna de las dos sesiones."

# ═════════════════════════════════════════════════════════════════════════════
# (c) El RELAY con la fila del comprobante TOMADA
# ═════════════════════════════════════════════════════════════════════════════
resolve_sale
emit_now
echo "fixture (c): doc=$RACE_doc sale=$RACE_sale"

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
wait_for_a
echo "sesion A: fila de fiscal_documents TOMADA (lock de fila + advisory visibles)"

B_OUT=$(edit_sale 7)
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
wait_for_a_gone

B_OUT=$(edit_sale 7)
assert_no_deadlock "(c-reintento)" "$B_OUT"
echo "$B_OUT" | grep -q 'EDIT_OK anulo=t' \
  || fail "liberado el lock, el MISMO pedido de edición debía funcionar y anular el comprobante. Salida: $B_OUT"

STATUS=$(q "SELECT status FROM public.fiscal_documents WHERE id = '$RACE_doc';")
[ "$STATUS" = "voided" ] || fail "tras el reintento el comprobante debía quedar voided, quedó '$STATUS'"
echo "PASS (c-reintento): liberado el lock, el mismo pedido edita y anula — el rechazo era TRANSITORIO, no un bloqueo permanente."

cleanup
LEFT=$(q "SELECT count(*) FROM auth.users WHERE email = 'venta-editable-race@test.local';")
[ "$LEFT" = "0" ] || { echo "GATE VENTA-EDITABLE-SIN-CAE-RACE FAILED: la limpieza dejó el anchor sintético" >&2; exit 1; }

echo "GATE VENTA-EDITABLE-SIN-CAE-RACE PASSED: exclusión contra la EMISIÓN (e), orden de locks sin deadlock (f) y NOWAIT contra el RELAY (c) — el rechazo es transitorio y el reintento funciona. Fixtures limpios."
