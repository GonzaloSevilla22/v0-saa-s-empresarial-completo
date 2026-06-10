from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class BranchRepository(BaseRepository):
    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM branches WHERE account_id = $1 ORDER BY name ASC",
            account_id,
        )

    async def get_by_id(self, branch_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM branches WHERE id = $1 AND account_id = $2",
            branch_id,
            account_id,
        )

    async def create(self, account_id: str, data: dict) -> asyncpg.Record | None:
        return await self.fetchrow(
            "INSERT INTO branches (account_id, name) VALUES ($1, $2) RETURNING *",
            account_id,
            data["name"],
        )

    async def update(self, branch_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(branch_id, account_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE branches SET {set_clauses} WHERE id = $1 AND account_id = $2 RETURNING *",
            branch_id,
            account_id,
            *values,
        )
