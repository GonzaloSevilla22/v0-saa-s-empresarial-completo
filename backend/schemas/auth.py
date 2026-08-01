from __future__ import annotations

from pydantic import BaseModel, Field


class ClaimsStatusOut(BaseModel):
    """Response schema for GET /auth/claims-status (v31-authz-token-hook D8).

    Diagnóstico de presencia de claims — SOLO booleanos de presencia y
    valores efectivos del propio llamante. NUNCA el token, NUNCA el payload
    crudo, NUNCA el identificador de otro usuario.
    """

    role_claim_present: bool = Field(
        ..., description="True si app_metadata.role viajó en el JWT (hook activo para este usuario)."
    )
    account_role_claim_present: bool = Field(
        ..., description="True si app_metadata.account_role viajó en el JWT."
    )
    plan_claim_present: bool = Field(
        ..., description="True si app_metadata.plan viajó en el JWT."
    )
    effective_role: str = Field(..., description="Rol de plataforma efectivo (claim o fallback).")
    effective_account_role: str | None = Field(
        None, description="Rol de tenant efectivo (claim; sin fallback en el JWT — None si ausente)."
    )
    effective_plan: str = Field(..., description="Plan efectivo (claim o fallback de transición 'pro').")
    source: str = Field(
        ...,
        description="'token' si los tres claims vinieron del JWT; 'fallback' si al menos uno se resolvió por default.",
    )
