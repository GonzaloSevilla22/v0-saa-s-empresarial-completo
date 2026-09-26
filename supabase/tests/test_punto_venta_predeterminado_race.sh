#!/usr/bin/env bash
# =============================================================================
# GATE: test_punto_venta_predeterminado_race.sh
# CHANGE: punto-venta-seleccion (20261063000001) — governance MEDIA, dominio
# fiscal. Hallazgo de red-team: TOCTOU en las tres ramas de resolución de PV
# de rpc_emit_pending_cae — sin lock, una desactivación/cambio de
# predeterminado concurrente podía dejar un comprobante pending_cae en un PV
# que termina inactivo. El fix: los tres SELECT toman FOR SHARE, que
# conflictúa con el FOR NO KEY UPDATE implícito de la desactivación.
#
# No se puede probar en un solo archivo .sql (una sesión nunca bloquea contra
# su propio lock) — dos conexiones psql reales, mismo patrón que
# test_facturar_venta_manual_race.sh.
#
# Caso único (ITER veces): la cuenta tiene UN solo PV activo (v_pv). c2 abre
# una transacción como el OWNER real (SET LOCAL ROLE authenticated + claims,
# igual que el endpoint de desactivación) y desactiva v_pv sin comitear
# todavía. Mientras c2 está frenada ahí, c1 llama
# rpc_emit_pending_cae('factura_c', 100) SIN point_of_sale_id (rama "un solo
# activo"). c1 tiene que ESPERAR a que c2 termine (verificado con
# pg_blocking_pids) — nunca devolver un pending_cae con point_of_sale_id =
# v_pv una vez que v_pv terminó inactivo. Cuando c2 commitea, c1 se
# desbloquea y falla con P0404 no_active_point_of_sale (0 activos tras el
# commit) — ver el resto de las ramas en el gate de comportamiento estático
# (test_punto_venta_predeterminado.sql), que no puede ejercitar la ventana de
# carrera con una sola conexión.
#
# Uso:
#   ITER=10 DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     bash supabase/tests/test_punto_venta_predeterminado_race.sh
# =============================================================================
set -uo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ITER="${ITER:-10}"
TMP=$(mktemp -d)

USER_ID=""; ACCOUNT_ID=""; PV_ID=""; FP_ID=""

cleanup() {
  psql "$DB_URL" -X -q -t -A -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name LIKE 'pvsr\_%' AND pid <> pg_backend_pid();" >/dev/null 2>&1
  if [ -n "$ACCOUNT_ID" ]; then
    psql "$DB_URL" -X -q -t -A >/dev/null 2>&1 <<SQL
DO \$\$
DECLARE v_account uuid := '$ACCOUNT_ID'; v_user uuid := '$USER_ID';
BEGIN
  DELETE FROM public.document_status_history WHERE account_id = v_account;
  DELETE FROM public.fiscal_documents        WHERE account_id = v_account;
  DELETE FROM public.document_sequences      WHERE point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = v_account);
  DELETE FROM public.points_of_sale          WHERE account_id = v_account;
  DELETE FROM public.fiscal_profiles         WHERE account_id = v_account;
  SET LOCAL session_replication_role = replica;
  DELETE FROM public.account_members         WHERE account_id = v_account OR user_id = v_user;
  DELETE FROM public.accounts                WHERE id = v_account;
  SET LOCAL session_replication_role = DEFAULT;
  DELETE FROM public.profiles                WHERE id = v_user;
  DELETE FROM public.billing_events          WHERE user_id = v_user;
  DELETE FROM public.email_logs              WHERE user_id = v_user;
  DELETE FROM auth.users                     WHERE id = v_user;
END \$\$;
SQL
  fi
  rm -rf "$TMP"
}

fail() { echo "GATE PUNTO-VENTA-PREDETERMINADO-RACE FAILED: $*" >&2; cleanup; exit 1; }

# ── Fixture (una sola vez) ───────────────────────────────────────────────────
FIXTURE=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A <<'SQL'
DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_account uuid; v_fp uuid; v_pv uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'pvs-race@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PVS Race', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó la cuenta del anchor';
  END IF;
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account, '20990630060', 'monotributista', 'homologacion', true) RETURNING id INTO v_fp;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, v_account, 3, true) RETURNING id INTO v_pv;

  CREATE TEMP TABLE IF NOT EXISTS _pvsr_out (k text, v text);
  DELETE FROM _pvsr_out;
  INSERT INTO _pvsr_out VALUES ('user', v_user::text), ('account', v_account::text), ('pv', v_pv::text);
END $$;
SELECT string_agg(k || '=' || v, ';' ORDER BY k) FROM _pvsr_out;
SQL
) || fail "no se pudo armar el fixture"

eval "$(echo "$FIXTURE" | tr ';' '\n' | grep -E '^[a-z]+=' | sed 's/^/F_/')"
USER_ID="${F_user:-}"; ACCOUNT_ID="${F_account:-}"; PV_ID="${F_pv:-}"
[ -n "$ACCOUNT_ID" ] && [ -n "$PV_ID" ] || fail "no se pudo parsear el fixture: $FIXTURE"

CLAIMS=$(printf '{"sub": "%s", "role": "authenticated"}' "$USER_ID")

run_iteration() {
  local i="$1"
  # Reactivar el PV para esta iteración.
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -t -A -c \
    "UPDATE public.points_of_sale SET is_active = true WHERE id = '$PV_ID';" >/dev/null

  # c2: desactiva el PV como owner real, sin comitear todavía.
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -A <<SQL > "$TMP/c2_$i.out" 2>&1 &
SET application_name = 'pvsr_c2';
SELECT set_config('request.jwt.claims', '$CLAIMS', false);
BEGIN;
SET LOCAL ROLE authenticated;
UPDATE public.points_of_sale SET is_active = false, is_default = false WHERE id = '$PV_ID';
SELECT pg_sleep(4);
COMMIT;
SQL
  local c2_pid=$!

  # Esperar a que c2 tenga la fila tomada (búsqueda del backend por application_name).
  local waited=0
  local c2_backend=""
  while [ "$waited" -lt 50 ]; do
    c2_backend=$(psql "$DB_URL" -X -q -t -A -c \
      "SELECT pid FROM pg_stat_activity WHERE application_name = 'pvsr_c2' AND state <> 'idle' LIMIT 1;")
    [ -n "$c2_backend" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -n "$c2_backend" ] || { kill "$c2_pid" 2>/dev/null; fail "(iter $i) c2 no llegó a abrir su transacción"; }

  # c1: llama a la RPC sin PV explícito (rama "un solo activo") mientras c2 sostiene el lock.
  psql "$DB_URL" -v ON_ERROR_STOP=1 -X -q -A <<SQL > "$TMP/c1_$i.out" 2>&1 &
SET application_name = 'pvsr_c1';
SELECT set_config('request.jwt.claims', '$CLAIMS', false);
SET ROLE authenticated;
SELECT public.rpc_emit_pending_cae('factura_c', 100);
SQL
  local c1_pid=$!

  # Verificar que c1 queda REALMENTE esperando (pg_blocking_pids), no que
  # simplemente tardó: si no se la ve esperando, FAIL (no INCONCLUSO=PASS).
  local saw_waiting="false"
  local w=0
  while [ "$w" -lt 60 ]; do
    local hit
    hit=$(psql "$DB_URL" -X -q -t -A -c \
      "SELECT 1 FROM pg_stat_activity a
       WHERE a.application_name = 'pvsr_c1' AND a.wait_event_type = 'Lock'
         AND $c2_backend = ANY(pg_blocking_pids(a.pid));")
    if [ "$hit" = "1" ]; then
      saw_waiting="true"
      break
    fi
    sleep 0.1
    w=$((w + 1))
  done

  wait "$c2_pid"
  wait "$c1_pid"
  # Dejar que los backends de esta iteración se cierren del todo antes de la
  # próxima — evita falsos INCONCLUSO por detectar el pid de la iteración
  # anterior todavía en pg_stat_activity.
  sleep 0.3

  [ "$saw_waiting" = "true" ] || fail "(iter $i) nunca se vio a c1 esperando sobre c2 (pg_blocking_pids) — INCONCLUSO"

  if grep -qE 'ERROR:|rpc_emit_pending_cae' "$TMP/c2_$i.out" && grep -q 'ERROR' "$TMP/c2_$i.out"; then
    fail "(iter $i) c2 (desactivación) falló: $(cat "$TMP/c2_$i.out")"
  fi

  # Invariante: c1 NUNCA devuelve pending_cae por el PV que quedó inactivo.
  if grep -q "\"point_of_sale_id\": \"$PV_ID\"" "$TMP/c1_$i.out"; then
    fail "(iter $i) c1 emitió un comprobante en el PV $PV_ID DESPUÉS de que quedó inactivo (TOCTOU no cerrado)"
  fi
  if ! grep -qE 'P0404|no_active_point_of_sale' "$TMP/c1_$i.out"; then
    fail "(iter $i) c1 debía fallar con P0404 no_active_point_of_sale tras esperar la desactivación; salida: $(cat "$TMP/c1_$i.out")"
  fi

  # Invariante global: cero fiscal_documents nuevos con este PV.
  local docs
  docs=$(psql "$DB_URL" -X -q -t -A -c \
    "SELECT count(*) FROM public.fiscal_documents WHERE point_of_sale_id = '$PV_ID';")
  [ "$docs" = "0" ] || fail "(iter $i) quedó un fiscal_documents en el PV inactivo: $docs fila(s)"

  echo "  iter $i: PASS (c1 esperó a c2, P0404 tras el commit, 0 comprobantes en el PV inactivo)"
}

for i in $(seq 1 "$ITER"); do
  run_iteration "$i"
done

echo "PASS: test_punto_venta_predeterminado_race.sh — $ITER iteración(es), TOCTOU cerrado (FOR SHARE espera y re-evalúa; nunca un pending_cae en un PV que quedó inactivo)."
cleanup
