#!/usr/bin/env bash
# =============================================================================
# GATE: test_internal_document_numbering_race.sh
# CHANGE: presupuestos-modulo (20261067000001), tasks.md 1.8 — capability
#         internal-document-numbering.
#
# N sesiones REALES crean a la vez el PRIMER presupuesto de una cuenta que
# todavía no tiene fila en internal_document_sequences. Es el caso que ejercita
# el camino difícil de _next_internal_document_number: todas ven "no hay fila"
# en el UPDATE, todas intentan el INSERT, una gana y las demás chocan con la
# PK (unique_violation) y reintentan el UPDATE, que espera el lock de la fila
# hasta el commit de la anterior. Resultado exigido: los números 1..N, sin
# huecos ni repetidos, la secuencia en N y N presupuestos.
#
# Sincronización sin sleeps a ciegas (mismo criterio que
# test_ventas_unidades_conversion_race.sh): una sesión "portero" toma un
# advisory lock EXCLUSIVO; las N sesiones piden el mismo advisory en modo
# COMPARTIDO y quedan esperando. Cuando pg_locks muestra a las N esperando, se
# termina al portero y las N arrancan juntas contra la RPC rpc_create_quote,
# tal como la llama el backend (claims del owner en la transacción).
#
# ESTO NO SE PUEDE PROBAR EN UN SOLO .sql: una sesión nunca compite contra sí
# misma.
#
# Uso:
#   DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_internal_document_numbering_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ADVISORY_KEY=961067001
N="${N:-20}"
TMP_DIR="$(mktemp -d)"

q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$1"; }

USER_ID=""
ACCOUNT_ID=""
GATE_PID=""

cleanup() {
  [ -n "${GATE_PID:-}" ] && kill "$GATE_PID" 2>/dev/null
  psql "$DB_URL" -X -q -t -A -c "
    SELECT pg_terminate_backend(l.pid)
    FROM pg_locks l
    WHERE l.locktype = 'advisory' AND l.objid = $ADVISORY_KEY AND l.pid <> pg_backend_pid();" >/dev/null 2>&1
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
  DELETE FROM auth.users                   WHERE id = v_user;
  SET session_replication_role = DEFAULT;
END \$\$;
SQL
  fi
  rm -rf "$TMP_DIR"
}

fail() { echo "GATE INTERNAL-DOCUMENT-NUMBERING-RACE FAILED: $*" >&2; cleanup; exit 1; }

# ── Fixture: cuenta real vía handle_new_user, sin fila de secuencia ──────────
psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A >/dev/null <<'SQL' || fail "no se pudo armar el fixture"
DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_client  uuid;
  v_product uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'internal-numbering-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Numeración Race', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta';
  END IF;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_account, 'Cliente Race') RETURNING id INTO v_client;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'Producto Race', 'NUM-RACE-1', 10, 20) RETURNING id INTO v_product;
  IF EXISTS (SELECT 1 FROM public.internal_document_sequences WHERE account_id = v_account) THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta nueva ya tiene fila de secuencia';
  END IF;
END $$;
SQL
USER_ID=$(q "SELECT id FROM auth.users WHERE email = 'internal-numbering-race@test.local' ORDER BY created_at DESC LIMIT 1;")
[ -n "$USER_ID" ] || fail "el fixture no creó el usuario"
ACCOUNT_ID=$(q "SELECT account_id FROM public.account_members WHERE user_id = '$USER_ID' ORDER BY created_at LIMIT 1;")
CLIENT_ID=$(q "SELECT id FROM public.clients WHERE account_id = '$ACCOUNT_ID' LIMIT 1;")
PRODUCT_ID=$(q "SELECT id FROM public.products WHERE account_id = '$ACCOUNT_ID' LIMIT 1;")
[ -n "$ACCOUNT_ID" ] && [ -n "$CLIENT_ID" ] && [ -n "$PRODUCT_ID" ] || fail "el fixture no devolvió cuenta/cliente/producto"
echo "fixture: account=$ACCOUNT_ID, $N sesiones"

# ── Portero: advisory EXCLUSIVO, retenido hasta que lo terminemos ────────────
psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL &
SELECT pg_advisory_lock($ADVISORY_KEY);
SELECT pg_sleep(120);
SQL
GATE_PID=$!

for _ in $(seq 1 200); do
  held=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND granted;")
  [ "${held:-0}" -ge 1 ] && break
  q "SELECT pg_sleep(0.05);" >/dev/null
done
[ "${held:-0}" -ge 1 ] || fail "el portero nunca tomó el advisory lock"

# ── N sesiones: esperan el advisory compartido y crean el presupuesto ────────
WORKER_PIDS=()
for i in $(seq 1 "$N"); do
  psql "$DB_URL" -X -q -t -A > "$TMP_DIR/w$i.out" 2>&1 <<SQL &
SET statement_timeout = '60s';
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '$USER_ID', 'role', 'authenticated')::text, true);
SELECT set_config('request.jwt.claim.sub', '$USER_ID', true);
SELECT pg_advisory_xact_lock_shared($ADVISORY_KEY);
SELECT 'NUM=' || (public.rpc_create_quote(
  '$CLIENT_ID'::uuid, NULL, NULL, NULL,
  jsonb_build_array(jsonb_build_object('product_id', '$PRODUCT_ID'::uuid, 'unit_id', NULL,
                                       'quantity', 1, 'price', 20, 'subtotal', 20, 'description', NULL))
)->>'number');
COMMIT;
SQL
  WORKER_PIDS+=($!)
done

waiting=0
for _ in $(seq 1 400); do
  waiting=$(q "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $ADVISORY_KEY AND NOT granted;")
  [ "${waiting:-0}" -ge "$N" ] && break
  q "SELECT pg_sleep(0.05);" >/dev/null
done
[ "${waiting:-0}" -ge "$N" ] || fail "sólo $waiting de $N sesiones llegaron a esperar el advisory: no hubo carrera"
echo "las $N sesiones esperan juntas — se suelta el portero"

q "SELECT pg_terminate_backend(l.pid) FROM pg_locks l WHERE l.locktype = 'advisory' AND l.objid = $ADVISORY_KEY AND l.granted AND l.mode = 'ExclusiveLock';" >/dev/null
wait "$GATE_PID" 2>/dev/null
GATE_PID=""

for pid in "${WORKER_PIDS[@]}"; do
  wait "$pid" 2>/dev/null
done

NUMS=$(cat "$TMP_DIR"/w*.out | grep -o 'NUM=[0-9]*' | sed 's/NUM=//' | sort -n | tr '\n' ' ' | sed 's/ $//')
EXPECTED=$(seq 1 "$N" | tr '\n' ' ' | sed 's/ $//')
if [ "$NUMS" != "$EXPECTED" ]; then
  echo "--- salidas de las sesiones ---" >&2
  cat "$TMP_DIR"/w*.out >&2
  fail "las sesiones recibieron [$NUMS], se esperaba [$EXPECTED]"
fi

DB_CHECK=$(q "SELECT count(*) || '/' || count(DISTINCT number) || '/' || COALESCE(min(number), 0) || '/' || COALESCE(max(number), 0)
              FROM public.quotes WHERE account_id = '$ACCOUNT_ID';")
[ "$DB_CHECK" = "$N/$N/1/$N" ] || fail "en la base: filas/distintos/min/max = $DB_CHECK, se esperaba $N/$N/1/$N"
SEQ=$(q "SELECT last_number FROM public.internal_document_sequences WHERE account_id = '$ACCOUNT_ID' AND document_type = 'quote';")
[ "$SEQ" = "$N" ] || fail "internal_document_sequences quedó en $SEQ, se esperaba $N"

echo "PASS: $N altas concurrentes del primer presupuesto de una cuenta sin fila de secuencia recibieron 1..$N, sin huecos ni repetidos; la secuencia quedó en $N."

cleanup
LEFT=$(q "SELECT count(*) FROM auth.users WHERE id = '$USER_ID';")
[ "$LEFT" = "0" ] || { echo "GATE INTERNAL-DOCUMENT-NUMBERING-RACE FAILED: quedó el usuario del fixture" >&2; exit 1; }
echo "GATE INTERNAL-DOCUMENT-NUMBERING-RACE PASSED (residuo cero)."
