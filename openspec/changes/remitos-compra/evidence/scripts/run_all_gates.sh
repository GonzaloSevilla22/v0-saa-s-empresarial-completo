#!/usr/bin/env bash
export PATH=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/bin:$PATH
export PYTHONIOENCODING=utf-8
S=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/steps
R=/c/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/results
mkdir -p $R
cd /c/Users/Usuario/Desktop/EIE/wt-remitos-compra
echo "reset start $(date +%T)" > $R/summary.txt
docker exec supabase_db_v0-saa-s-empresarial-completo rm -rf /work 2>/dev/null
[ -n "$SKIP_RESET" ] || { npx supabase db reset > $R/reset.log 2>&1 || echo "RESET FAILED" >> $R/summary.txt; }
echo "reset end $(date +%T)" >> $R/summary.txt
while IFS=$'\t' read -r idx name; do
  [ -n "$SKIP_RESET" ] && [ "$idx" = "004" ] && continue
  bash $S/$idx.sh > $R/$idx.log 2>&1 < /dev/null
  rc=$?
  if [ $rc -eq 0 ]; then st=PASS; else st="FAIL($rc)"; fi
  echo "$st	$idx	$name" >> $R/summary.txt
done < $S/index.txt
echo "done $(date +%T)" >> $R/summary.txt
