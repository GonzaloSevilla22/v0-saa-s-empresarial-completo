#!/usr/bin/env bash
# Reproduce 6.5 (ajuste fantasma) y 6.6 (viewer por PUT /products) contra el comportamiento de HEAD y contra
# el nuevo. Uso: run_repro_6_5_6_6.sh head|new
#   head: dentro de una transaccion que se revierte, reinstala los 5 cuerpos vivos de partida
#         (evidence/live_functiondefs) y elimina el CHECK de motivo => comportamiento de la tanda A.
#   new : el mismo escenario sobre los cuerpos nuevos (estado migrado).
set -u
cd "$(dirname "$0")/../../../../.."
E=openspec/changes/stock-ledger-solo-rpc/evidence
MODE="${1:-head}"
TPL="$E/scripts/repro_6_5_6_6_head_bodies.sql.tpl"
if [ "$MODE" = "head" ]; then
  {
    echo "ALTER TABLE public.stock_movements DROP CONSTRAINT IF EXISTS stock_movements_manual_needs_reason;"
    for f in rpc_apply_product_stock_delta rpc_reverse_stock_movement rpc_adjust_branch_stock rpc_stock_adjustment rpc_transfer_stock; do
      cat "$E/live_functiondefs/$f.sql"; echo ";"
    done
  } > /tmp/reinstate_head.sql
else
  : > /tmp/reinstate_head.sql
fi
python - "$TPL" /tmp/reinstate_head.sql <<'PYEOF' > /tmp/repro_run.sql
import sys
tpl=open(sys.argv[1],encoding='utf-8').read()
body=open(sys.argv[2],encoding='utf-8').read()
sys.stdout.buffer.write(tpl.replace('@@REINSTATE_HEAD@@', body).encode('utf-8'))
PYEOF
MSYS_NO_PATHCONV=1 docker exec -i supabase_db_v0-saa-s-empresarial-completo psql -v ON_ERROR_STOP=1 -U postgres -d postgres < /tmp/repro_run.sql 2>&1 | grep -E "NOTICE:  6\.|ERROR|ROLLBACK" | sed 's/^NOTICE:  //'
