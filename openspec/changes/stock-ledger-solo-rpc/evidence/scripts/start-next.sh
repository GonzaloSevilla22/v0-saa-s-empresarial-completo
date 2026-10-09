#!/usr/bin/env bash
# Next dev contra el Supabase LOCAL (las NEXT_PUBLIC_* del entorno ganan sobre frontend/.env.local, que no se lee ni se imprime).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null 2>&1
export NEXT_PUBLIC_SUPABASE_URL="$NEXT_PUBLIC_SUPABASE_URL_LOCAL" NEXT_PUBLIC_SUPABASE_ANON_KEY="$NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL" NEXT_PUBLIC_BACKEND_URL="$NEXT_PUBLIC_BACKEND_URL_LOCAL" NEXT_PUBLIC_PLAYWRIGHT_LOCAL=true NODE_ENV=development
cd "$WT_ROOT/frontend" || exit 1
exec pnpm dev
