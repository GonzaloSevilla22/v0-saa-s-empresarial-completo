#!/usr/bin/env bash
# Corre un .mjs de este directorio con el entorno local. Uso: run.sh visual-stock.mjs [filtro]
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null 2>&1
cd "$EVIDENCE_DIR/scripts" || exit 1
exec node "$@"
