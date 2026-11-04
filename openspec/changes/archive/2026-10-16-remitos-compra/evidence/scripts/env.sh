# source this; no imprime nada
cd "C:/Users/Usuario/Desktop/EIE/wt-remitos-compra"
eval "$(npx supabase status -o env 2>/dev/null)"
export NEXT_PUBLIC_SUPABASE_URL_LOCAL="$API_URL"
export NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL="$ANON_KEY"
export SUPABASE_URL="$API_URL"
export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export DATABASE_URL="$DB_URL"
export SUPABASE_JWT_SECRET="$JWT_SECRET"
export QA_TEST_USER_EMAIL=qa.e2e@local.test QA_TEST_USER_PASSWORD=<fixture-ci>
export QA_LOGOUT_USER_EMAIL=qa.logout@local.test QA_LOGOUT_USER_PASSWORD=<fixture-ci>
export QA_ROLE_PW="Qa-$(cat /c/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/.rolepw 2>/dev/null)"
export NEXT_PUBLIC_BACKEND_URL_LOCAL=http://localhost:8000 PLAYWRIGHT_BASE_URL=http://localhost:3000
