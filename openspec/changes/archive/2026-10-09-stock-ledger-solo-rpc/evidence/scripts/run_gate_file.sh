#!/usr/bin/env bash
# Corre un gate que usa \i supabase/migrations/... (no funciona por stdin): copia migrations y tests al
# contenedor (/tmp/wt) y lo ejecuta con -f desde ese cwd. Uso: run_gate_file.sh test_xxx
set -u
cd "$(dirname "$0")/../../../../.."
CID=supabase_db_v0-saa-s-empresarial-completo
MSYS_NO_PATHCONV=1 docker exec "$CID" sh -c 'rm -rf /tmp/wt && mkdir -p /tmp/wt/supabase' >/dev/null
MSYS_NO_PATHCONV=1 docker cp supabase/migrations "$CID":/tmp/wt/supabase/migrations >/dev/null
MSYS_NO_PATHCONV=1 docker cp supabase/tests "$CID":/tmp/wt/supabase/tests >/dev/null
MSYS_NO_PATHCONV=1 docker exec -w /tmp/wt "$CID" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f "supabase/tests/$1.sql" 2>&1
echo "GATE_EXIT=$?"
