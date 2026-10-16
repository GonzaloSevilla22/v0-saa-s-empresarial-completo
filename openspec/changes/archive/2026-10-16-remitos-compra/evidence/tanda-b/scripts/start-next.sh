#!/usr/bin/env bash
source "C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b/scripts/env.sh" >/dev/null 2>&1
export NEXT_PUBLIC_SUPABASE_URL="$NEXT_PUBLIC_SUPABASE_URL_LOCAL" NEXT_PUBLIC_SUPABASE_ANON_KEY="$NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL" NEXT_PUBLIC_BACKEND_URL="$NEXT_PUBLIC_BACKEND_URL_LOCAL" NEXT_PUBLIC_PLAYWRIGHT_LOCAL=true NODE_ENV=development
cd "C:/Users/Usuario/Desktop/EIE/wt-remitos-compra-b/frontend"
exec pnpm dev
