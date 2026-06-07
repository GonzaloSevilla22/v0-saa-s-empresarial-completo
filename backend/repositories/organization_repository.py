from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class OrganizationRepository(BaseRepository):
    async def get_by_id(self, org_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM organizations WHERE id = $1",
            org_id,
        )

    async def update_settings(self, org_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(org_id)
        set_clauses = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE organizations SET {set_clauses} WHERE id = $1 RETURNING *",
            org_id,
            *values,
        )
