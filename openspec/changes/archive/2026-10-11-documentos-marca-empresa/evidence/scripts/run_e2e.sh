#!/usr/bin/env bash
# Corre el e2e de documentos-marca-empresa contra el stack LOCAL, en las 4 combinaciones, dejando
# capturas y descargas en evidence/screenshots. Playwright levanta su propio Next dev (el puerto 3000 debe estar libre)
# y espera el backend ya levantado (start-backend.sh). Uso: run_e2e.sh [filtro -g]
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null 2>&1
export DOCS_VISUAL_DIR="$EVIDENCE_DIR/screenshots"
cd "$WT_ROOT/frontend" || exit 1
node e2e/fixtures/seed-users.mjs
exec pnpm exec playwright test e2e/documentos-marca.spec.ts --project=chromium "$@"
