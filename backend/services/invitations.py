"""
multiusuario-operativo TANDA C (grupo 15) — servicio de invitaciones a una cuenta.

Capas: router (validación + DI) -> este service (capacidad, nombre del negocio) -> repository (RPCs).

  - Crear, reenviar, revocar y listar exigen `CAN_CONFIGURE` (dueño o administrador de la
    cuenta activa). Es una capacidad SENSIBLE (`backend/core/rbac.py`): se decide contra la base
    aunque el token traiga el claim. Es un primer filtro barato; la autoridad real la repite
    cada RPC con el helper canónico `_account_assert_capability` ANTES de escribir.
  - Crear llama a `rpc_invite_member` y a `rpc_send_invitation_email` sobre la MISMA conexión
    (la transacción del request): un tope de envío (P0439) revierte la creación.
  - El nombre del negocio del email sale de la cascada canónica del emisor
    (`resolve_commercial_issuer`, la misma de los PDF): una sola definición del "nombre visible".
  - Vista previa y aceptación NO exigen rol de la cuenta —el invitado todavía no es miembro— ni la
    cuenta activa: la identidad la liga la base contra el email de la invitación.
"""
from __future__ import annotations

from backend.core.errors import ProblemHTTPException
from backend.core.guards import require_account_role
from backend.core.rbac import CAN_CONFIGURE
from backend.repositories.invitation_repository import InvitationRepository
from backend.schemas.invitations import TOKEN_PATTERN
from backend.services.commercial_documents.issuer import resolve_commercial_issuer

# El MISMO texto y código que devuelve la base ante un token inexistente, vencido, revocado, rotado
# o de otra identidad: un token que ni tiene forma de token no se distingue de ninguno de esos.
INVALID_TOKEN_DETAIL = "P404: invalid or expired invitation token"


def _reject_malformed_token(token: str) -> None:
    if not TOKEN_PATTERN.match(token):
        raise ProblemHTTPException(status_code=404, detail=INVALID_TOKEN_DETAIL, code="P0404")


async def _issuer_name(repo: InvitationRepository, account_id: str) -> str:
    """Nombre visible del negocio por la cascada canónica del emisor."""
    return (await resolve_commercial_issuer(repo, account_id)).name


async def create_invitation(
    repo: InvitationRepository,
    auth: dict,
    account_id: str,
    email: str,
    roles: list[str],
    *,
    conn,
) -> dict:
    """Crea la invitación y encola el email en la misma transacción."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    name = await _issuer_name(repo, account_id)
    created = await repo.invite(email, account_id, roles)
    sent = await repo.send_email(str(created["id"]), name, False)
    return {**sent, "email_queued": bool(sent.get("queued", True))}


async def list_invitations(repo: InvitationRepository, auth: dict, account_id: str, *, conn) -> list[dict]:
    await require_account_role(conn, auth, CAN_CONFIGURE)
    return await repo.list_invitations(account_id)


async def resend_invitation(
    repo: InvitationRepository, auth: dict, account_id: str, invitation_id: str, *, conn
) -> dict:
    """Reenvía: la base rota el token, renueva el vencimiento y encola el email nuevo."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    name = await _issuer_name(repo, account_id)
    sent = await repo.send_email(invitation_id, name, True)
    return {**sent, "email_queued": bool(sent.get("queued", True))}


async def revoke_invitation(
    repo: InvitationRepository, auth: dict, account_id: str, invitation_id: str, *, conn
) -> dict:
    await require_account_role(conn, auth, CAN_CONFIGURE)
    return await repo.revoke(invitation_id)


async def preview_invitation(repo: InvitationRepository, token: str) -> dict:
    _reject_malformed_token(token)
    return await repo.preview(token)


async def accept_invitation(repo: InvitationRepository, token: str) -> dict:
    _reject_malformed_token(token)
    return await repo.accept(token)
