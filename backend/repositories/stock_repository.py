from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class StockRepository(BaseRepository):
    async def get_stock_by_product(self, product_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT stock FROM products WHERE id = $1 AND account_id = $2",
            product_id,
            account_id,
        )

    async def list_movements(self, product_id: str, account_id: str) -> list[dict]:
        return await self.fetch(
            """
            SELECT sm.* FROM stock_movements sm
            JOIN products p ON p.id = sm.product_id
            WHERE sm.product_id = $1 AND p.account_id = $2
            ORDER BY sm.created_at DESC
            """,
            product_id,
            account_id,
        )

    async def transfer(
        self, from_branch_id: str, to_branch_id: str, product_id: str, quantity: float
    ) -> asyncpg.Record | None:
        return await self.call_rpc(
            "rpc_transfer_stock",
            p_from_branch_id=from_branch_id,
            p_to_branch_id=to_branch_id,
            p_product_id=product_id,
            p_quantity=quantity,
        )
