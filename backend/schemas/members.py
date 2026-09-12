from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict, Field


class MemberRoleOut(BaseModel):
    """Una asignación de rol dentro del conjunto de un miembro.

    v3-rbac-multirole Parte C (grupo 14): `is_active` es un derivado del
    servidor (expires_at NULL o futuro) — la pantalla distingue una
    asignación vencida de una vigente sin tener que comparar fechas del lado
    del cliente.
    """

    model_config = ConfigDict(from_attributes=True)

    role: str
    expires_at: datetime.datetime | None
    is_active: bool


class MemberOut(BaseModel):
    """Un miembro de la cuenta con su conjunto COMPLETO de roles (vigentes y
    vencidos) — response de GET /members."""

    model_config = ConfigDict(from_attributes=True)

    member_id: uuid.UUID
    user_id: uuid.UUID
    legacy_role: str
    created_at: datetime.datetime
    name: str | None
    email: str | None
    roles: list[MemberRoleOut]


class AssignRoleRequest(BaseModel):
    """Payload for POST /members/{user_id}/roles."""

    role: str = Field(..., min_length=1, description="Código del catálogo (account_role_catalog)")
    expires_at: datetime.datetime | None = Field(
        None, description="Vencimiento opcional; NULL = permanente. El rol owner NUNCA admite vencimiento (P0406)."
    )


class RoleAssignmentOut(BaseModel):
    """Response de asignar/revocar un rol — refleja el jsonb que devuelven
    rpc_assign_member_role / rpc_revoke_member_role."""

    account_id: uuid.UUID
    user_id: uuid.UUID
    role: str
    expires_at: datetime.datetime | None = None
