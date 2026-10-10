# source este archivo; no imprime nada. Stack LOCAL únicamente (jamás prod).
# Molde: openspec/changes/remitos-compra/evidence/scripts/env.sh, con las rutas relativas a este worktree.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WT_ROOT="$(cd "$_here/../../../../../../.." && pwd)"
cd "$WT_ROOT" || return 1
eval "$(npx -y supabase@2.120.0 status -o env 2>/dev/null)"
export NEXT_PUBLIC_SUPABASE_URL_LOCAL="$API_URL"
export NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL="$ANON_KEY"
export SUPABASE_URL="$API_URL"
export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export DATABASE_URL="$DB_URL"
export SUPABASE_JWT_SECRET="$JWT_SECRET"
# Fixtures de CI (E2E_Tests.yml) y usuarios de rol sólo del stack local de esta verificación.
export QA_TEST_USER_EMAIL=qa.e2e@local.test QA_TEST_USER_PASSWORD=qa-e2e-ci-password-1
export QA_ROLE_PW="qa-roles-local-stock-ledger-1"
export NEXT_PUBLIC_BACKEND_URL_LOCAL=http://localhost:8000 PLAYWRIGHT_BASE_URL=http://localhost:3000
# Salidas de la verificación: capturas dentro de la evidencia, estado de sesión/ids en el scratchpad.
export EVIDENCE_DIR="$WT_ROOT/openspec/changes/archive/2026-10-09-stock-ledger-solo-rpc/evidence/humo-local"
export SCRATCH_DIR="${SCRATCH_DIR:-/c/Users/Usuario/AppData/Local/Temp/claude/C--Users-Usuario-Desktop-EIE-v0-saa-s-empresarial-completo--claude-worktrees-sad-shamir-6c7415/1f0f2598-5e7f-46de-ab66-dcb7b17b1d6b/scratchpad}"
mkdir -p "$SCRATCH_DIR" "$EVIDENCE_DIR/screenshots"
