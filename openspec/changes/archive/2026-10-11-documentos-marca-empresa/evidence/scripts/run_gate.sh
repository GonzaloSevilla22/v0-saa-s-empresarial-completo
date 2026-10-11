#!/usr/bin/env bash
# Corre UN gate SQL contra el stack local (contenedor supabase_db_v0-saa-s-empresarial-completo) por stdin.
# Uso: run_gate.sh test_xxx   -> imprime la salida y "GATE_EXIT=<n>"
set -u
cd "$(dirname "$0")/../../../../.."   # raiz del worktree
G="$1"
MSYS_NO_PATHCONV=1 docker exec -i supabase_db_v0-saa-s-empresarial-completo psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "supabase/tests/${G}.sql" 2>&1
echo "GATE_EXIT=$?"
