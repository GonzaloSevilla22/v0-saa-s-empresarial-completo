from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class CashboxRepository(BaseRepository):
    """Repository for cashboxes — read/write via RLS-guarded queries and RPCs."""

    async def list_cashboxes(self, branch_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM public.cashboxes WHERE branch_id = $1 ORDER BY created_at ASC",
            branch_id,
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
