from __future__ import annotations

from fastapi import APIRouter, Depends

from backend.core.auth import get_claims_status
from backend.schemas.auth import ClaimsStatusOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.get("/claims-status", response_model=ClaimsStatusOut)
async def claims_status(diagnostics: dict = Depends(get_claims_status)):
    """Diagnóstico PERMANENTE de presencia de claims (v31-authz-token-hook D8).

    Es el único camino de verificación válido de que el custom access token
    hook está activo para la sesión del llamante: NO se basa en
    `auth.users.raw_app_metadata` (el hook nunca escribe esa columna — esa
    query daría `false` con el hook perfectamente activo). Describe
    únicamente al usuario autenticado que la invoca.
    """
    return diagnostics
