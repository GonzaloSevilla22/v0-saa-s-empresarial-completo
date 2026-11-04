"""
multiusuario-operativo TANDA C (grupo 15) — InvitationRepository.

JWT-passthrough vía base.py (la conexión ya trae los claims del usuario, incluida la cuenta
activa). Todo el dominio vive en RPCs SECURITY DEFINER (tanda C): el repositorio sólo las
invoca, en la MISMA conexión —es decir, en la misma transacción— del request, de modo que crear
una invitación y encolar su email son atómicos (un tope P0439 en el envío revierte la creación).

Ninguna función recibe un destinatario ni un token para ENVIAR: el email se arma en la base
desde la fila de la invitación.
"""
from __future__ import annotations

import json

from backend.repositories.base import BaseRepository
from backend.repositories.commercial_document_support import CommercialIssuerMixin


def _jsonb(value):
    """asyncpg devuelve json/jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class InvitationRepository(CommercialIssuerMixin, BaseRepository):
    """Repository de la invitación de miembros a una cuenta."""

    async def invite(self, email: str, account_id: str, roles: list[str]) -> dict:
        """`rpc_invite_member(email, cuenta, roles)`: crea la invitación (cupo, autoridad, duplicada)."""
        row = await self.fetchrow(
            "SELECT public.rpc_invite_member($1, $2::uuid, $3::text[]) AS result",
            email,
            account_id,
            roles,
        )
        return _jsonb(row["result"])

    async def send_email(self, invitation_id: str, account_display_name: str | None, renew: bool) -> dict:
        """`rpc_send_invitation_email(id, nombre, renovar)`: encola el email `org_invite` desde la fila
        y, con `renew`, rota el token. Topes y autoridad los decide la base (P0403 / P0404 / P0409 / P0439)."""
        row = await self.fetchrow(
            "SELECT public.rpc_send_invitation_email($1::uuid, $2, $3::boolean) AS result",
            invitation_id,
            account_display_name,
            renew,
        )
        return _jsonb(row["result"])

    async def list_invitations(self, account_id: str) -> list[dict]:
        """`rpc_list_account_invitations(cuenta)`: pendientes y vencidas/revocadas recientes, sin token."""
        return await self.fetch("SELECT * FROM public.rpc_list_account_invitations($1::uuid)", account_id)

    async def revoke(self, invitation_id: str) -> dict:
        """`rpc_revoke_invitation(id)`: pasa la invitación a `revoked` (idempotente)."""
        row = await self.fetchrow("SELECT public.rpc_revoke_invitation($1::uuid) AS result", invitation_id)
        return _jsonb(row["result"])

    async def preview(self, token: str) -> dict:
        """`rpc_invitation_preview(token)`: la vista previa, ligada a la identidad autenticada."""
        row = await self.fetchrow("SELECT public.rpc_invitation_preview($1) AS result", token)
        return _jsonb(row["result"])

    async def accept(self, token: str) -> dict:
        """`rpc_accept_invitation(token)`: crea la membresía y deja el negocio como cuenta activa."""
        row = await self.fetchrow("SELECT public.rpc_accept_invitation($1) AS result", token)
        return _jsonb(row["result"])
