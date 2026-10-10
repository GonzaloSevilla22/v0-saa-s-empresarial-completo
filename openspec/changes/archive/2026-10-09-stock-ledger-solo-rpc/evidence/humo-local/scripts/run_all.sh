#!/usr/bin/env bash
# Corrida limpia del humo: db reset -> backend nuevo -> siembra -> login -> pasos 1..9 -> estado final.
# Uso: bash run_all.sh   (con Next dev ya levantado por start-next.sh; el backend lo reinicia este script)
H="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$H/scripts/env.sh" >/dev/null 2>&1
L="$H/logs"
echo "== db reset" ; npx -y supabase@2.120.0 db reset > "$L/00_db_reset.log" 2>&1; echo "RESET_EXIT=$?" >> "$L/00_db_reset.log"; tail -3 "$L/00_db_reset.log"
cd "$WT_ROOT"
echo "== backend" ; (nohup bash "$H/scripts/start-backend.sh" > "$L/01_backend_uvicorn.log" 2>&1 &) ; sleep 12; curl -s -m 5 http://127.0.0.1:8000/health; echo
cd "$H/scripts"
echo "== seed" ; node seed.mjs 2>&1 | tee "$L/03_seed.log"
echo "== login" ; node 10_login.mjs 2>&1 | tee "$L/04_login.log"
for s in 21_paso1 22_paso2 23_paso3_4 24_paso5 25_paso6 26_paso7_8 27_movil 28_recaptura_edicion 29_importador_parcial; do
  echo "== $s" ; node $s.mjs > "$L/05_$s.log" 2>&1 ; echo "exit=$?"
done
echo "== estado final" ; MSYS_NO_PATHCONV=1 docker exec -i supabase_db_v0-saa-s-empresarial-completo psql -X -U postgres -d postgres < "$H/scripts/estado_final.sql" > "$L/40_estado_final_bd.log" 2>&1; echo "exit=$?"
