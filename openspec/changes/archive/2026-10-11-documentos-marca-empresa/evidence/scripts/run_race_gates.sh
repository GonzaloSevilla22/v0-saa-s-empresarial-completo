#!/usr/bin/env bash
# Corre los gates de carrera (.sh) DENTRO del contenedor de la base (tiene psql), con DB_URL local y CR eliminados.
set -u
cd "$(dirname "$0")/../../../../.."
CID=supabase_db_v0-saa-s-empresarial-completo
URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres"
run() { # nombre, env..., script
  local name="$1"; shift; local script="$1"; shift
  local out; out=$(tr -d '\r' < "supabase/tests/$script" | MSYS_NO_PATHCONV=1 docker exec -i -e DB_URL="$URL" "$@" "$CID" bash 2>&1); local rc=$?
  echo "$name exit=$rc"; printf '%s\n' "$out" | tail -2 | sed 's/^/    /'
}
run test_ventas_unidades_conversion_race test_ventas_unidades_conversion_race.sh
run test_facturar_venta_manual_race test_facturar_venta_manual_race.sh -e ITER=20
run test_remitos_venta_race test_remitos_venta_race.sh
run test_remitos_compra_race test_remitos_compra_race.sh
run test_venta_editable_sin_cae_race test_venta_editable_sin_cae_race.sh
run test_presupuesto_a_venta_race test_presupuesto_a_venta_race.sh
run test_internal_document_numbering_race:remito_venta test_internal_document_numbering_race.sh -e DOC_TYPE=delivery_note_sale -e N=20
run test_internal_document_numbering_race:remito_compra test_internal_document_numbering_race.sh -e DOC_TYPE=delivery_note_purchase -e N=20
run test_punto_venta_predeterminado_race test_punto_venta_predeterminado_race.sh -e ITER=10
