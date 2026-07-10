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
        resuelve vía branch_id → branches.account_id en el propio UPDATE,
        por eso NO usa el soft_delete genérico del BaseRepository (cuya
        allowlist la excluye a propósito).
        """
        status = await self.execute(
            """
            UPDATE public.cashboxes cb
            SET    deleted_at = now(), deleted_by = $3
            FROM   public.branches b
            WHERE  cb.id = $1
              AND  b.id = cb.branch_id
              AND  b.account_id = $2
              AND  cb.deleted_at IS NULL
            """,
            cashbox_id,
            account_id,
            deleted_by,
        )
        return int(status.rsplit(" ", 1)[-1]) > 0

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
