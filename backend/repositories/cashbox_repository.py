from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class CashboxRepository(BaseRepository):
    """Repository for cashboxes — read/write via RLS-guarded queries and RPCs."""

    async def list_cashboxes(self, branch_id: str) -> list[dict]:
        # v3-soft-delete-policy (RN-B1): excluye cashboxes borradas.
        return await self.fetch(
            "SELECT * FROM public.cashboxes WHERE branch_id = $1"
            + self.not_deleted_clause()
            + " ORDER BY created_at ASC",
            branch_id,
        )

    async def soft_delete_cashbox(
        self, cashbox_id: str, account_id: str, deleted_by: str
    ) -> bool:
        """Soft delete de una cashbox (RN-B2) — variante OQ2 del design.

        `cashboxes` no tiene account_id directo: el scope de cuenta se
        resuelve vía branch_id → branches.account_id, por eso NO usa el
        soft_delete genérico del BaseRepository (cuya allowlist la excluye
        a propósito).

        v31-tenancy-pool-rls (colisión #2, sign-off PO 2026-08-01): cashboxes
        no tiene policy de UPDATE — encaminado por rpc_soft_delete_cashbox
        (SECURITY DEFINER), que replica el mismo JOIN y agrega el check
        is_account_writer(account_id) que ya usa cashboxes_insert.
        """
        return await self._conn.fetchval(
            "SELECT public.rpc_soft_delete_cashbox($1::uuid, $2::uuid, $3::uuid)",
            cashbox_id,
            account_id,
            deleted_by,
        )

    async def create_cashbox(
        self,
        branch_id: str,
        name: str,
        currency: str = "ARS",
    ) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            INSERT INTO public.cashboxes (branch_id, name, currency)
            VALUES ($1, $2, $3)
            RETURNING *
            """,
            branch_id,
            name,
            currency,
        )
