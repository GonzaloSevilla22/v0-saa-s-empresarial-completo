from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.member_repository import MemberRepository
from backend.schemas.members import AssignRoleRequest, MemberOut, RoleAssignmentOut
from backend.services import members as members_service

router = APIRouter(prefix="/members", tags=["members"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> MemberRepository:
    return MemberRepository(conn)


@router.get("", response_model=list[MemberOut])
async def list_members(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: MemberRepository = Depends(get_repo),
):
    """Lista los miembros de la cuenta con su conjunto completo de roles
    (vigentes y vencidos). Disponible a cualquier miembro de la cuenta."""
    return await members_service.list_members(repo, auth, str(account_id))


@router.post("/{user_id}/roles", response_model=RoleAssignmentOut, status_code=201)
async def assign_role(
    user_id: uuid.UUID,
    payload: AssignRoleRequest,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: MemberRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Asigna un rol del catálogo a un miembro, con vencimiento opcional.
    Requiere owner/admin (v3-rbac-multirole Parte C, grupo 14)."""
    return await members_service.assign_role(
        repo, auth, str(account_id), str(user_id),
        payload.role, payload.expires_at,
        conn=conn,
    )


@router.delete("/{user_id}/roles/{role}", response_model=RoleAssignmentOut)
async def revoke_role(
    user_id: uuid.UUID,
    role: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: MemberRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Revoca un rol de un miembro. Requiere owner/admin."""
    return await members_service.revoke_role(
        repo, auth, str(account_id), str(user_id), role,
        conn=conn,
    )


@router.delete("/{user_id}")
async def remove_member(
    user_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: MemberRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Quita a un miembro por completo de la cuenta (rpc_remove_member,
    Parte A). Requiere owner/admin; el guard fino (no expulsar al owner, un
    admin no expulsa a otro admin/owner) lo hace la RPC misma."""
    return await members_service.remove_member(
        repo, auth, str(account_id), str(user_id),
        conn=conn,
    )
