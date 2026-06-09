from __future__ import annotations

import datetime
import json
from decimal import Decimal

import asyncpg

from backend.repositories.base import BaseRepository


class PurchaseRepository(BaseRepository):
    async def list_by_org(self, user_id: str) -> list[asyncpg.Record]:
        return await self.fetch(
            "SELECT * FROM purchases WHERE user_id = $1 ORDER BY date DESC",
            user_id,
        )

    async def get_operation(self, operation_id: str, user_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM purchases WHERE operation_id = $1 AND user_id = $2 LIMIT 1",
            operation_id,
            user_id,
        )

    async def get_idempotency(self, user_id: str, idempotency_key: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            SELECT operation_id, operation_kind FROM operation_idempotency
            WHERE user_id = $1 AND idempotency_key = $2
            """,
            user_id,
            idempotency_key,
        )

    async def delete_by_id(self, purchase_id: str, user_id: str) -> bool:
        async with self._conn.transaction():
            row = await self._conn.fetchrow(
                "SELECT id, product_id, operation_id FROM purchases WHERE id = $1::uuid AND user_id = $2::uuid",
                purchase_id,
                user_id,
            )
            if row is None:
                return False
            if row["product_id"] is not None:
                delta = await self._conn.fetchval(
                    "SELECT quantity_delta FROM stock_movements WHERE reference_id = $1::uuid AND reference_type = 'purchase' LIMIT 1",
                    purchase_id,
                )
                if delta is not None:
                    await self._conn.execute(
                        "UPDATE products SET stock = stock - $1 WHERE id = $2::uuid",
                        delta,
                        row["product_id"],
                    )
                await self._conn.execute(
                    "DELETE FROM stock_movements WHERE reference_id = $1::uuid AND reference_type = 'purchase'",
                    purchase_id,
                )
            await self._conn.execute("DELETE FROM purchases WHERE id = $1::uuid", purchase_id)
            if row["operation_id"] is not None:
                count = await self._conn.fetchval(
                    "SELECT COUNT(*) FROM purchases WHERE operation_id = $1",
                    row["operation_id"],
                )
                if count == 0:
                    await self._conn.execute(
                        "DELETE FROM operation_idempotency WHERE operation_id = $1",
                        row["operation_id"],
                    )
            return True

    async def delete_by_operation(self, operation_id: str, user_id: str) -> bool:
        async with self._conn.transaction():
            rows = await self._conn.fetch(
                "SELECT id, product_id FROM purchases WHERE operation_id = $1::uuid AND user_id = $2::uuid",
                operation_id,
                user_id,
            )
            if not rows:
                return False
            for row in rows:
                if row["product_id"] is not None:
                    delta = await self._conn.fetchval(
                        "SELECT quantity_delta FROM stock_movements WHERE reference_id = $1 AND reference_type = 'purchase' LIMIT 1",
                        row["id"],
                    )
                    if delta is not None:
                        await self._conn.execute(
                            "UPDATE products SET stock = stock - $1 WHERE id = $2",
                            delta,
                            row["product_id"],
                        )
                    await self._conn.execute(
                        "DELETE FROM stock_movements WHERE reference_id = $1 AND reference_type = 'purchase'",
                        row["id"],
                    )
            await self._conn.execute(
                "DELETE FROM purchases WHERE operation_id = $1::uuid AND user_id = $2::uuid",
                operation_id,
                user_id,
            )
            await self._conn.execute(
                "DELETE FROM operation_idempotency WHERE operation_id = $1::uuid",
                operation_id,
            )
            return True

    async def create_operation(
        self,
        user_id: str,
        org_id: str,
        items: list[dict],
        idempotency_key: str,
        date: datetime.date | None = None,
        description: str | None = None,
    ) -> dict | None:
        existing = await self.get_idempotency(user_id, idempotency_key)
        if existing is not None:
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        # The RPC takes description at operation level — strip it from items
        clean_items = [
            {k: v for k, v in item.items() if k != "description"}
            for item in items
        ]

        row = await self._conn.fetchrow(
            """
            SELECT
                (rpc_create_purchase_operation($1, $2, $3, $4::jsonb)->>'operation_id')::uuid
                    AS operation_id,
                'purchase'::text AS operation_kind
            """,
            idempotency_key,
            date or datetime.date.today(),
            description,
            json.dumps(clean_items, default=_default),
        )
        return dict(row) if row else None
