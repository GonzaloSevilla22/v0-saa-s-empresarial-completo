#!/usr/bin/env bash
# Bateria completa: el orden de KPI_Validation.yml (psql -f supabase/tests/*.sql) + los gates extra.
# Los gates que usan \i supabase/migrations/... (no funcionan por stdin) se corren con -f desde /tmp/wt del contenedor.
# Formato de salida: exit|gate|duracion|primera linea de ERROR
# Uso: run_battery.sh > salida.txt
set -u
cd "$(dirname "$0")/../../../../.."
CID=supabase_db_v0-saa-s-empresarial-completo
MSYS_NO_PATHCONV=1 docker exec "$CID" sh -c 'rm -rf /tmp/wt && mkdir -p /tmp/wt/supabase' >/dev/null
MSYS_NO_PATHCONV=1 docker cp supabase/migrations "$CID":/tmp/wt/supabase/migrations >/dev/null
MSYS_NO_PATHCONV=1 docker cp supabase/tests "$CID":/tmp/wt/supabase/tests >/dev/null
{
  grep -oE 'supabase/tests/test_[a-z0-9_]+\.sql' .github/workflows/KPI_Validation.yml | sed -E 's#supabase/tests/##; s#\.sql##'
  echo test_branch_stock
  echo test_sales_order_payment_method_drop
} | awk '!seen[$0]++' | while read -r g; do
  [ -f "supabase/tests/$g.sql" ] || { echo "-|$g|0s|ARCHIVO NO EXISTE"; continue; }
  s=$(date +%s)
  if grep -qE '^\ir? ' "supabase/tests/$g.sql"; then
    out=$(MSYS_NO_PATHCONV=1 docker exec -w /tmp/wt "$CID" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f "supabase/tests/$g.sql" 2>&1); mode="-f"
  else
    out=$(MSYS_NO_PATHCONV=1 docker exec -i "$CID" psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "supabase/tests/$g.sql" 2>&1); mode="stdin"
  fi
  rc=$?
  e=$(date +%s)
  err=$(printf '%s\n' "$out" | grep -m1 -E '(^|: )ERROR:' | tr -d '\r' | cut -c1-200)
  echo "$rc|$g|$((e-s))s|$mode $err"
done
