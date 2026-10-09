#!/usr/bin/env bash
# FastAPI contra la base LOCAL (mismo arranque que E2E_Tests.yml). Usa el venv del proyecto.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null 2>&1
export BACKEND_ALLOWED_ORIGIN=http://localhost:3000 REDIS_URL='' WSFE_ADAPTER_MODE=stub AUTH_ALLOW_HS256_FALLBACK=true
cd "$WT_ROOT" || exit 1
exec backend/.venv/Scripts/python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
