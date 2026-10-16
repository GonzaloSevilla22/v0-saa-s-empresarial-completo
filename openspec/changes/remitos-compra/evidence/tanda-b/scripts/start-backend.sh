#!/usr/bin/env bash
# Backend FastAPI local para la verificación de la tanda B (stack LOCAL, HS256 sólo para dev).
source "C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b/scripts/env.sh" >/dev/null 2>&1
cd C:/Users/Usuario/Desktop/EIE/wt-remitos-compra-b
export BACKEND_ALLOWED_ORIGIN=http://localhost:3000 REDIS_URL= WSFE_ADAPTER_MODE=stub AUTH_ALLOW_HS256_FALLBACK=true PYTHONPATH=C:/Users/Usuario/Desktop/EIE/wt-remitos-compra-b PYTHONIOENCODING=utf-8
exec C:/Users/Usuario/Desktop/EIE/v0-saa-s-empresarial-completo/backend/.venv/Scripts/python.exe -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
