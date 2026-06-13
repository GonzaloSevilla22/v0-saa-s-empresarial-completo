from __future__ import annotations

import json

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value):
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


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

    # ── C-26: lifecycle operacional ─────────────────────────────────────────
    async def open_branch(self, branch_id: str) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_open_branch($1::uuid) AS result",
            branch_id,
        )
        return _jsonb(row["result"])

    async def close_branch(self, branch_id: str) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_close_branch($1::uuid) AS result",
            branch_id,
        )
        return _jsonb(row["result"])

    async def list_transfers(self, branch_id: str, account_id: str) -> list[dict]:
        # Transferencias donde la sucursal es origen O destino, aisladas por cuenta.
        return await self.fetch(
            """
            SELECT st.id, st.account_id, st.product_id, p.name AS product_name,
                   st.from_branch_id, fb.name AS from_branch_name,
                   st.to_branch_id,   tb.name AS to_branch_name,
                   st.quantity, st.status, st.created_at
            FROM stock_transfers st
            JOIN branches fb ON fb.id = st.from_branch_id
            JOIN branches tb ON tb.id = st.to_branch_id
            JOIN products p  ON p.id  = st.product_id
            WHERE st.account_id = $2
              AND (st.from_branch_id = $1 OR st.to_branch_id = $1)
            ORDER BY st.created_at DESC
            LIMIT 100
            """,
            branch_id,
            account_id,
        )
