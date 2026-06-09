from __future__ import annotations

import datetime
import json
from decimal import Decimal

import asyncpg

from backend.repositories.base import BaseRepository


class SalesRepository(BaseRepository):
    async def list_by_org(self, user_id: str) -> list[asyncpg.Record]:
        return await self.fetch(
            "SELECT * FROM sales WHERE user_id = $1 ORDER BY date DESC",
            user_id,
        )

    async def get_operation(self, operation_id: str, user_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM sales WHERE operation_id = $1 AND user_id = $2 LIMIT 1",
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
        client_id: str | None = None,
        currency: str = "ARS",
    ) -> dict | None:
        existing = await self.get_idempotency(user_id, idempotency_key)
        if existing is not None:
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        row = await self._conn.fetchrow(
            """
            SELECT
                (rpc_create_sale_operation($1, $2::text::uuid, $3, $4, $5::jsonb)->>'operation_id')::uuid
                    AS operation_id,
                'sale'::text AS operation_kind
            """,
            idempotency_key,
            client_id,
            date or datetime.date.today(),
            currency,
            json.dumps(items, default=_default),
        )
        return dict(row) if row else None
