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
