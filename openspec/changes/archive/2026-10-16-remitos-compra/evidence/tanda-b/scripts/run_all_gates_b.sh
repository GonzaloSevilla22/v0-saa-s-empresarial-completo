#!/usr/bin/env bash
# db reset limpio desde el worktree + todos los pasos run: de KPI_Validation.yml en orden
# (remitos-compra tanda B, 8.1b). Las carreras corren dentro del contenedor por el shim de psql.
# SKIP_RESET=1 reutiliza la base tal como está.
export PATH=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b/bin:$PATH
export PYTHONIOENCODING=utf-8
export MSYS_NO_PATHCONV=1
S=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b/steps
R=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b/results
rm -rf $R; mkdir -p $R
cd /c/Users/Usuario/Desktop/EIE/wt-remitos-compra-b
docker exec supabase_db_v0-saa-s-empresarial-completo rm -rf /work-rcb >/dev/null 2>&1
echo "reset start $(date +%T)" > $R/summary.txt
if [ -z "$SKIP_RESET" ]; then
  npx supabase db reset > $R/reset.log 2>&1 || echo "RESET FAILED" >> $R/summary.txt
fi
echo "reset end $(date +%T)" >> $R/summary.txt
while IFS=$'\t' read -r idx name; do
  docker exec supabase_db_v0-saa-s-empresarial-completo rm -rf /work-rcb >/dev/null 2>&1
  start=$(date +%s)
  bash $S/$idx.sh > $R/$idx.log 2>&1 < /dev/null
  rc=$?
  if [ $rc -eq 0 ]; then st=PASS; else st="FAIL($rc)"; fi
  echo "$st	$idx	$name	$(( $(date +%s) - start ))s" >> $R/summary.txt
done < $S/index.txt
echo "done $(date +%T)" >> $R/summary.txt
