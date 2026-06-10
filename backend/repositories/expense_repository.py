from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class ExpenseRepository(BaseRepository):
    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM expenses WHERE account_id = $1 ORDER BY date DESC",
            account_id,
        )

    async def get_by_id(self, expense_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM expenses WHERE id = $1 AND account_id = $2",
            expense_id,
            account_id,
        )

    async def create(self, user_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            INSERT INTO expenses (user_id, account_id, category, amount, description, date)
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING *
            """,
            user_id,
            account_id,
            data["category"],
            data["amount"],
            data.get("description"),
            data["date"],
        )

    async def update(self, expense_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(expense_id, account_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE expenses SET {set_clauses} WHERE id = $1 AND account_id = $2 RETURNING *",
            expense_id,
            account_id,
            *values,
        )

    async def delete(self, expense_id: str, account_id: str) -> str:
        return await self.execute(
            "DELETE FROM expenses WHERE id = $1 AND account_id = $2",
            expense_id,
            account_id,
        )
