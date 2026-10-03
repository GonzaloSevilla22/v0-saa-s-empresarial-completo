#!/usr/bin/env bash
# db reset limpio desde el worktree + todos los pasos run: de KPI_Validation.yml en orden.
export PATH=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos/bin:$PATH
export PYTHONIOENCODING=utf-8
export MSYS_NO_PATHCONV=1
S=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos/b/steps
R=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos/b/results
rm -rf $R; mkdir -p $R
cd /c/Users/Usuario/Desktop/EIE/wt-remitos
docker exec supabase_db_v0-saa-s-empresarial-completo rm -rf /work >/dev/null 2>&1
echo "reset start $(date +%T)" > $R/summary.txt
npx supabase db reset > $R/reset.log 2>&1 || echo "RESET FAILED" >> $R/summary.txt
echo "reset end $(date +%T)" >> $R/summary.txt
while IFS=$'\t' read -r idx name; do
  docker exec supabase_db_v0-saa-s-empresarial-completo rm -rf /work >/dev/null 2>&1
  start=$(date +%s)
  bash $S/$idx.sh > $R/$idx.log 2>&1 < /dev/null
  rc=$?
  if [ $rc -eq 0 ]; then st=PASS; else st="FAIL($rc)"; fi
  echo "$st	$idx	$name	$(( $(date +%s) - start ))s" >> $R/summary.txt
done < $S/index.txt
echo "done $(date +%T)" >> $R/summary.txt
