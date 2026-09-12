"""
v3-rbac-multirole Parte C (grupo 14) — MemberRepository.

JWT-passthrough via base.py (conexión ya configurada con claims del
usuario). Lecturas via rpc_list_account_members (SECURITY DEFINER, guard de
tenencia inline — Parte A/C mantienen account_member_roles cerrada por
completo a authenticated, así que ninguna lectura directa de tabla es
posible acá). Mutaciones via las RPCs SECURITY DEFINER de asignación/
revocación (Parte C) y via rpc_remove_member (reutilizado de la Parte A,
contrato legacy {ok}|{error} — no lanza excepciones).
"""
from __future__ import annotations

import json

from backend.repositories.base import BaseRepository


def _jsonb(value):
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class MemberRepository(BaseRepository):
    """Repository para la administración de miembros y sus roles."""

    async def list_members(self, account_id: str) -> list[dict]:
        """Lista los miembros de la cuenta con su conjunto completo de roles
        (vigentes y vencidos) via rpc_list_account_members."""
        rows = await self.fetch(
            "SELECT * FROM public.rpc_list_account_members($1::uuid)",
            account_id,
        )
        for row in rows:
            row["roles"] = _jsonb(row["roles"])
        return rows

    async def assign_role(
        self,
        account_id: str,
        target_user_id: str,
        role: str,
        expires_at,
    ) -> dict:
        """Invoca rpc_assign_member_role — RAISE EXCEPTION con P04xx en
        cualquier rechazo (autoridad/tenencia/catálogo/owner+vencimiento),
        propagado por asyncpg_error_handler. Nunca un contrato {error}."""
        row = await self.fetchrow(
            "SELECT public.rpc_assign_member_role($1::uuid, $2::uuid, $3::text, $4::timestamptz) AS result",
            account_id,
            target_user_id,
            role,
            expires_at,
        )
        return _jsonb(row["result"])

    async def revoke_role(self, account_id: str, target_user_id: str, role: str) -> dict:
        """Invoca rpc_revoke_member_role — mismo criterio de excepciones que assign_role."""
        row = await self.fetchrow(
            "SELECT public.rpc_revoke_member_role($1::uuid, $2::uuid, $3::text) AS result",
            account_id,
            target_user_id,
            role,
        )
        return _jsonb(row["result"])

    async def remove_member(self, account_id: str, target_user_id: str) -> dict:
        """Invoca rpc_remove_member (Parte A, SIN cambios de esta parte) —
        contrato LEGACY {ok:true}|{error:"..."}, nunca lanza excepción. El
        service traduce {error} a un HTTPException."""
        row = await self.fetchrow(
            "SELECT public.rpc_remove_member($1::uuid, $2::uuid) AS result",
            account_id,
            target_user_id,
        )
        return _jsonb(row["result"])

    async def member_exists(self, account_id: str, target_user_id: str) -> bool:
        """Ronda 1 adversarial (finding MINOR): ¿el target ES miembro de esta
        cuenta? `rpc_remove_member` (Parte A, contrato legacy) hace un
        DELETE sin verificar tenencia y devuelve `{ok:true}` aunque afecte 0
        filas -- un `DELETE /members/{uuid-ajeno}` respondía 200 sin haber
        quitado a nadie, inconsistente con `assign_role`/`revoke_role` (mismo
        router), que para el MISMO uuid devuelven 404/P0404. Este chequeo
        corre ANTES de invocar la RPC para que el service pueda traducirlo a
        un 404 real. `account_members` tiene RLS de lectura para "mismo
        miembro de la cuenta" (mismo criterio que `client_belongs_to_account`
        de `QuoteRepository`), así que un SELECT directo alcanza sin RPC
        propia."""
        row = await self.fetchrow(
            "SELECT 1 FROM public.account_members WHERE account_id = $1::uuid AND user_id = $2::uuid",
            account_id,
            target_user_id,
        )
        return row is not None
