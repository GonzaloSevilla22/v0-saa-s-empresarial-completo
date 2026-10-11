# source este archivo; no imprime nada. Stack LOCAL únicamente (jamás prod).
# Molde: openspec/changes/archive/2026-10-09-stock-ledger-solo-rpc/evidence/humo-local/scripts/env.sh
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WT_ROOT="$(cd "$_here/../../../../.." && pwd)"
cd "$WT_ROOT" || return 1
eval "$(npx -y supabase@2.120.0 status -o env 2>/dev/null)"
export NEXT_PUBLIC_SUPABASE_URL_LOCAL="$API_URL"
export NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL="$ANON_KEY"
export SUPABASE_URL="$API_URL"
export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export DATABASE_URL="$DB_URL"
export SUPABASE_JWT_SECRET="$JWT_SECRET"
# Fixtures de CI (E2E_Tests.yml): usuarios QA del stack local.
export QA_TEST_USER_EMAIL=qa.e2e@local.test QA_TEST_USER_PASSWORD=qa-e2e-ci-password-1
export QA_LOGOUT_USER_EMAIL=qa.logout@local.test QA_LOGOUT_USER_PASSWORD=qa-logout-ci-password-1
export RELAY_SECRET=e2e-relay-local-only
export NEXT_PUBLIC_BACKEND_URL_LOCAL=http://localhost:8000 PLAYWRIGHT_BASE_URL=http://localhost:3000
export EVIDENCE_DIR="$WT_ROOT/openspec/changes/documentos-marca-empresa/evidence"
mkdir -p "$EVIDENCE_DIR/screenshots" "$EVIDENCE_DIR/logs"
