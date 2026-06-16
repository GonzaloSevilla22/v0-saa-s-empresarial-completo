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
            SELECT s.id, s.date, s.client_id, s.operation_id, s.currency,
                   COALESCE(si.product_id, s.product_id) AS product_id,
                   COALESCE(si.quantity,   s.quantity)   AS quantity,
                   COALESCE(si.price,      s.amount)     AS amount,
                   COALESCE(si.subtotal,   s.total)      AS total,
                   pr.name AS product_name,
                   cl.name AS client_name
            FROM sales s
            JOIN op_page ON COALESCE(s.operation_id::text, s.id::text) = op_page.op_key
            LEFT JOIN sale_items si ON si.sale_id = s.id AND si.product_id IS NOT NULL
            LEFT JOIN products pr ON COALESCE(si.product_id, s.product_id) = pr.id
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

    async def delete_by_id(self, sale_id: str, account_id: str) -> bool:
        async with self._conn.transaction():
            # Espejo de PurchaseRepository.delete_by_id. product_id se lee de
            # sale_items (fuente de verdad post-C-20); la reversa de stock va a
            # branch_stock (C-21) con el signo opuesto al movimiento original.
            row = await self._conn.fetchrow(
                "SELECT id, operation_id FROM sales WHERE id = $1::uuid AND account_id = $2::uuid",
                sale_id,
                account_id,
            )
            if row is None:
                return False
            item_row = await self._conn.fetchrow(
                "SELECT product_id FROM sale_items WHERE sale_id = $1::uuid AND product_id IS NOT NULL LIMIT 1",
                sale_id,
            )
            product_id = item_row["product_id"] if item_row else None
            if product_id is not None:
                movement = await self._conn.fetchrow(
                    "SELECT quantity_delta, branch_id FROM stock_movements WHERE reference_id = $1::uuid AND reference_type = 'sale' LIMIT 1",
                    sale_id,
                )
                if movement is not None and movement["quantity_delta"] is not None:
                    # La venta descontó stock (quantity_delta < 0); la reversa
                    # devuelve a la branch original. allow_negative + sin movement
                    # nuevo = paridad con el comportamiento previo.
                    await self._conn.fetchrow(
                        "SELECT public.rpc_apply_product_stock_delta($1::uuid, $2::numeric, $3::uuid, NULL, FALSE, TRUE)",
                        product_id,
                        -movement["quantity_delta"],
                        movement["branch_id"],
                    )
                await self._conn.execute(
                    "DELETE FROM stock_movements WHERE reference_id = $1::uuid AND reference_type = 'sale'",
                    sale_id,
                )
            await self._conn.execute("DELETE FROM sales WHERE id = $1::uuid", sale_id)
            if row["operation_id"] is not None:
                count = await self._conn.fetchval(
                    "SELECT COUNT(*) FROM sales WHERE operation_id = $1",
                    row["operation_id"],
                )
                if count == 0:
                    await self._conn.execute(
                        "DELETE FROM operation_idempotency WHERE operation_id = $1",
                        row["operation_id"],
                    )
            return True

    async def delete_by_operation(self, operation_id: str, account_id: str) -> bool:
        async with self._conn.transaction():
            # Espejo de PurchaseRepository.delete_by_operation.
            rows = await self._conn.fetch(
                "SELECT id FROM sales WHERE operation_id = $1::uuid AND account_id = $2::uuid",
                operation_id,
                account_id,
            )
            if not rows:
                return False
            for row in rows:
                sale_id = row["id"]
                item_row = await self._conn.fetchrow(
                    "SELECT product_id FROM sale_items WHERE sale_id = $1 AND product_id IS NOT NULL LIMIT 1",
                    sale_id,
                )
                product_id = item_row["product_id"] if item_row else None
                if product_id is not None:
                    movement = await self._conn.fetchrow(
                        "SELECT quantity_delta, branch_id FROM stock_movements WHERE reference_id = $1 AND reference_type = 'sale' LIMIT 1",
                        sale_id,
                    )
                    if movement is not None and movement["quantity_delta"] is not None:
                        await self._conn.fetchrow(
                            "SELECT public.rpc_apply_product_stock_delta($1::uuid, $2::numeric, $3::uuid, NULL, FALSE, TRUE)",
                            product_id,
                            -movement["quantity_delta"],
                            movement["branch_id"],
                        )
                    await self._conn.execute(
                        "DELETE FROM stock_movements WHERE reference_id = $1 AND reference_type = 'sale'",
                        sale_id,
                    )
            await self._conn.execute(
                "DELETE FROM sales WHERE operation_id = $1::uuid AND account_id = $2::uuid",
                operation_id,
                account_id,
            )
            await self._conn.execute(
                "DELETE FROM operation_idempotency WHERE operation_id = $1::uuid",
                operation_id,
            )
            return True

    async def update_operation(
        self,
        sale_ids: list[str],
        client_id: str | None,
        date: datetime.date,
        currency: str,
        items: list[dict],
    ) -> None:
        # rpc_atomic_update_sale_operation hace REVERSE de los ítems viejos +
        # APPLY de los nuevos en una sola transacción (stock sobre branch_stock,
        # C-21 hotfix). RLS/auth.uid() scope vía JWT-passthrough de la conexión.
        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        await self._conn.execute(
            "SELECT rpc_atomic_update_sale_operation($1::text[]::uuid[], $2::text::uuid, $3::date, $4::text, $5::jsonb)",
            sale_ids,
            client_id,
            date,
            currency,
            json.dumps(items, default=_default),
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
