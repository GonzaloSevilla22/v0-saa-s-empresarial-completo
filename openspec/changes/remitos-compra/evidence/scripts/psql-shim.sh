#!/usr/bin/env bash
# wrapper local: psql dentro del contenedor de Supabase (no hay psql en el host)
export MSYS_NO_PATHCONV=1
C=supabase_db_v0-saa-s-empresarial-completo
if ! docker exec $C test -d /work/supabase/migrations 2>/dev/null; then
  docker exec $C mkdir -p /work
  (cd /c/Users/Usuario/Desktop/EIE/wt-remitos-compra && tar cf - supabase/migrations supabase/tests) | docker exec -i $C tar xf - -C /work
fi
args=(); file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) file="$2"; shift 2;;
    -f*) file="${1#-f}"; shift;;
    *) a="${1//127.0.0.1:54322/127.0.0.1:5432}"; a="${a//localhost:54322/127.0.0.1:5432}"; args+=("$a"); shift;;
  esac
done
envs=()
[ -n "${PGAPPNAME:-}" ] && envs+=(-e "PGAPPNAME=$PGAPPNAME")
if [ -n "$file" ]; then
  docker exec -i -w /work "${envs[@]}" supabase_db_v0-saa-s-empresarial-completo psql "${args[@]}" < "$file"
else
  if [ -t 0 ]; then docker exec -w /work "${envs[@]}" supabase_db_v0-saa-s-empresarial-completo psql "${args[@]}"
  else docker exec -i -w /work "${envs[@]}" supabase_db_v0-saa-s-empresarial-completo psql "${args[@]}"; fi
fi
