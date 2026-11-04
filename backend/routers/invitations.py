"""
multiusuario-operativo TANDA C (grupo 15) — endpoints de la invitación a una cuenta.

  /members/invitations      (dueño o administrador de la cuenta activa)
      POST                  crea la invitación y encola el email (misma transacción)
      GET                   pendientes y vencidas/revocadas recientes (sin token)
      POST /{id}/resend     reenvía: rota el token y renueva el vencimiento
      DELETE /{id}          revoca

  /invitations/{token}      (el invitado, ya autenticado; no exige rol ni cuenta activa)
      GET                   vista previa ligada a su identidad
      POST /accept          acepta y deja el negocio como cuenta activa

Los P04xx de las RPCs los traduce a RFC 7807 el handler global (`asyncpg_error_handler`):
P0404 -> 404, P0409 -> 409, P0401/P0402/P0403 -> 403, P0400 -> 400, P0407 -> 409 y
P0439 (topes de envío) -> 429. La aceptación y la vista previa van por FastAPI (no por
PostgREST) justamente para que el P0404 y el P0409 lleguen como 404 y 409, no como 500.
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.invitation_repository import InvitationRepository
from backend.schemas.invitations import (
    InvitationAccepted,
    InvitationCreateRequest,
    InvitationOut,
    InvitationPreview,
    InvitationRevoked,
    InvitationSent,
)
from backend.services import invitations as invitations_service

# Las rutas literales de /members/invitations se registran ANTES que el router de /members
# (main.py): ningún `/members/{user_id}` puede capturarlas.
router = APIRouter(prefix="/members/invitations", tags=["invitations"])
token_router = APIRouter(prefix="/invitations", tags=["invitations"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> InvitationRepository:
    return InvitationRepository(conn)


@router.post("", response_model=InvitationSent, status_code=201)
async def create_invitation(
    payload: InvitationCreateRequest,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: InvitationRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Invita a una persona por email con un conjunto de roles. Requiere owner/admin."""
    return await invitations_service.create_invitation(
        repo, auth, str(account_id), payload.email, payload.roles, conn=conn,
    )


@router.get("", response_model=list[InvitationOut])
async def list_invitations(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: InvitationRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Invitaciones pendientes y vencidas/revocadas de los últimos 30 días. Nunca el token."""
    return await invitations_service.list_invitations(repo, auth, str(account_id), conn=conn)


@router.post("/{invitation_id}/resend", response_model=InvitationSent)
async def resend_invitation(
    invitation_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: InvitationRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Reenvía la invitación con un link nuevo (el anterior deja de servir). Topes: P0439 -> 429."""
    return await invitations_service.resend_invitation(
        repo, auth, str(account_id), str(invitation_id), conn=conn,
    )


@router.delete("/{invitation_id}", response_model=InvitationRevoked)
async def revoke_invitation(
    invitation_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: InvitationRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Revoca una invitación pendiente: la aceptación pasa a fallar como un token vencido."""
    return await invitations_service.revoke_invitation(
        repo, auth, str(account_id), str(invitation_id), conn=conn,
    )


@token_router.get("/{token}", response_model=InvitationPreview)
async def preview_invitation(
    token: str,
    auth: dict = Depends(get_current_user),
    repo: InvitationRepository = Depends(get_repo),
):
    """Vista previa para quien abrió el link, SOLO si su identidad es la invitada."""
    return await invitations_service.preview_invitation(repo, token)


@token_router.post("/{token}/accept", response_model=InvitationAccepted)
async def accept_invitation(
    token: str,
    auth: dict = Depends(get_current_user),
    repo: InvitationRepository = Depends(get_repo),
):
    """Acepta la invitación: crea la membresía y deja el negocio como cuenta activa."""
    return await invitations_service.accept_invitation(repo, token)
