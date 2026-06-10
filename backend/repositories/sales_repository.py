from __future__ import annotations

import datetime
import json
from decimal import Decimal

import asyncpg

from backend.repositories.base import BaseRepository


class SalesRepository(BaseRepository):
    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM sales WHERE account_id = $1 ORDER BY date DESC",
            account_id,
        )

    async def list_paginated_by_operation(
        self,
        account_id: str,
        page: int,
        page_size: int,
        date_from: datetime.date | None = None,
        date_to: datetime.date | None = None,
    ) -> tuple[list[asyncpg.Record], int]:
        total: int = await self._conn.fetchval(
            """
            SELECT COUNT(DISTINCT COALESCE(operation_id::text, id::text))
            FROM sales
            WHERE account_id = $1::uuid
              AND ($2::date IS NULL OR date >= $2::date)
              AND ($3::date IS NULL OR date <= $3::date)
            """,
            account_id, date_from, date_to,
        ) or 0

        rows: list[asyncpg.Record] = await self._conn.fetch(
            """
            WITH op_page AS (
              SELECT COALESCE(operation_id::text, id::text) AS op_key
              FROM sales
              WHERE account_id = $1::uuid
                AND ($2::date IS NULL OR date >= $2::date)
                AND ($3::date IS NULL OR date <= $3::date)
              GROUP BY COALESCE(operation_id::text, id::text)
              ORDER BY MAX(date) DESC
              LIMIT $4 OFFSET $5
            )
            SELECT s.id, s.date, s.product_id, s.client_id, s.operation_id,
                   s.quantity, s.amount, s.total, s.currency,
                   pr.name AS product_name,
                   cl.name AS client_name
            FROM sales s
            JOIN op_page ON COALESCE(s.operation_id::text, s.id::text) = op_page.op_key
            LEFT JOIN products pr ON s.product_id = pr.id
            LEFT JOIN clients cl ON s.client_id = cl.id
            WHERE s.account_id = $1::uuid
            ORDER BY s.date DESC, s.id
            """,
            account_id, date_from, date_to, page_size, page * page_size,
        )
        return rows, total

    async def get_operation(self, operation_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM sales WHERE operation_id = $1 AND account_id = $2 LIMIT 1",
            operation_id,
            account_id,
        )

    async def get_idempotency(self, account_id: str, idempotency_key: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            SELECT operation_id, operation_kind FROM operation_idempotency
            WHERE account_id = $1 AND idempotency_key = $2
            """,
            account_id,
            idempotency_key,
        )

    async def create_operation(
        self,
        user_id: str,
        account_id: str,
        items: list[dict],
        idempotency_key: str,
        date: datetime.date | None = None,
        client_id: str | None = None,
        currency: str = "ARS",
        canal: str | None = None,
    ) -> dict | None:
        existing = await self.get_idempotency(account_id, idempotency_key)
        if existing is not None:
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        row = await self._conn.fetchrow(
            """
            SELECT
                (rpc_create_sale_operation($1, $2::text::uuid, $3, $4, $5::jsonb, p_canal => $6)->>'operation_id')::uuid
                    AS operation_id,
                'sale'::text AS operation_kind
            """,
            idempotency_key,
            client_id,
            date or datetime.date.today(),
            currency,
            json.dumps(items, default=_default),
            canal,
        )
        return dict(row) if row else None
