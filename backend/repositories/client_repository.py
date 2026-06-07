from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class ClientRepository(BaseRepository):
    async def list_by_org(self, user_id: str) -> list[asyncpg.Record]:
        return await self.fetch(
            "SELECT * FROM clients WHERE user_id = $1 ORDER BY name ASC",
            user_id,
        )

    async def get_by_id(self, client_id: str, user_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM clients WHERE id = $1 AND user_id = $2",
            client_id,
            user_id,
        )

    async def create(self, user_id: str, data: dict) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            INSERT INTO clients (user_id, name, email, phone)
            VALUES ($1, $2, $3, $4)
            RETURNING *
            """,
            user_id,
            data["name"],
            data.get("email"),
            data.get("phone"),
        )

    async def update(self, client_id: str, user_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(client_id, user_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE clients SET {set_clauses} WHERE id = $1 AND user_id = $2 RETURNING *",
            client_id,
            user_id,
            *values,
        )

    async def delete(self, client_id: str, user_id: str) -> str:
        return await self.execute(
            "DELETE FROM clients WHERE id = $1 AND user_id = $2",
            client_id,
            user_id,
        )
