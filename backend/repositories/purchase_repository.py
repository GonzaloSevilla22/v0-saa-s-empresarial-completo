from __future__ import annotations

import datetime
import json
from decimal import Decimal
from typing import TYPE_CHECKING

import asyncpg

from backend.repositories.base import BaseRepository

if TYPE_CHECKING:
    from backend.repositories.outbox_repository import OutboxRepository


class PurchaseRepository(BaseRepository):
    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM purchases WHERE account_id = $1 ORDER BY date DESC",
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
            FROM purchases
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
              FROM purchases
              WHERE account_id = $1::uuid
                AND ($2::date IS NULL OR date >= $2::date)
                AND ($3::date IS NULL OR date <= $3::date)
              GROUP BY COALESCE(operation_id::text, id::text)
              ORDER BY MAX(date) DESC
              LIMIT $4 OFFSET $5
            )
            SELECT p.id, p.date, p.operation_id, p.description,
                   COALESCE(pi2.product_id, p.product_id) AS product_id,
                   COALESCE(pi2.quantity,   p.quantity)   AS quantity,
                   COALESCE(pi2.price,      p.amount)     AS amount,
                   COALESCE(pi2.subtotal,   p.total)      AS total,
                   pr.name AS product_name
            FROM purchases p
            JOIN op_page ON COALESCE(p.operation_id::text, p.id::text) = op_page.op_key
            LEFT JOIN purchase_items pi2 ON pi2.purchase_id = p.id AND pi2.product_id IS NOT NULL
            LEFT JOIN products pr ON COALESCE(pi2.product_id, p.product_id) = pr.id
            WHERE p.account_id = $1::uuid
            ORDER BY p.date DESC, p.id
            """,
            account_id, date_from, date_to, page_size, page * page_size,
        )
        return rows, total

    async def get_operation(self, operation_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM purchases WHERE operation_id = $1 AND account_id = $2 LIMIT 1",
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

    async def delete_by_id(self, purchase_id: str, account_id: str) -> bool:
        async with self._conn.transaction():
            # C-20 Group 6.3: fetch purchase_id and operation_id from header,
            # product_id from purchase_items (preparing for DROP of flat columns).
            row = await self._conn.fetchrow(
                "SELECT id, operation_id FROM purchases WHERE id = $1::uuid AND account_id = $2::uuid",
                purchase_id,
                account_id,
            )
            if row is None:
                return False
            # Read product_id from purchase_items (C-20: source of truth post-migration)
            item_row = await self._conn.fetchrow(
                "SELECT product_id FROM purchase_items WHERE purchase_id = $1::uuid AND product_id IS NOT NULL LIMIT 1",
                purchase_id,
            )
            product_id = item_row["product_id"] if item_row else None
            if product_id is not None:
                movement = await self._conn.fetchrow(
                    "SELECT quantity_delta, branch_id FROM stock_movements WHERE reference_id = $1::uuid AND reference_type = 'purchase' LIMIT 1",
                    purchase_id,
                )
                if movement is not None and movement["quantity_delta"] is not None:
                    # C-21 checkpoint #2: la reversa va a branch_stock (branch del
                    # movimiento o default). allow_negative + sin movement nuevo =
                    # paridad con el comportamiento previo sobre products.stock.
                    await self._conn.fetchrow(
                        "SELECT public.rpc_apply_product_stock_delta($1::uuid, $2::numeric, $3::uuid, NULL, FALSE, TRUE)",
                        product_id,
                        -movement["quantity_delta"],
                        movement["branch_id"],
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

    async def delete_by_operation(self, operation_id: str, account_id: str) -> bool:
        async with self._conn.transaction():
            # C-20 Group 6.3: fetch purchase ids first; get product_id per id from
            # purchase_items (not from purchases flat column — prepares for DROP).
            rows = await self._conn.fetch(
                "SELECT id FROM purchases WHERE operation_id = $1::uuid AND account_id = $2::uuid",
                operation_id,
                account_id,
            )
            if not rows:
                return False
            for row in rows:
                purchase_id = row["id"]
                item_row = await self._conn.fetchrow(
                    "SELECT product_id FROM purchase_items WHERE purchase_id = $1 AND product_id IS NOT NULL LIMIT 1",
                    purchase_id,
                )
                product_id = item_row["product_id"] if item_row else None
                if product_id is not None:
                    movement = await self._conn.fetchrow(
                        "SELECT quantity_delta, branch_id FROM stock_movements WHERE reference_id = $1 AND reference_type = 'purchase' LIMIT 1",
                        purchase_id,
                    )
                    if movement is not None and movement["quantity_delta"] is not None:
                        # C-21 checkpoint #2: reversa sobre branch_stock (ver delete_by_id)
                        await self._conn.fetchrow(
                            "SELECT public.rpc_apply_product_stock_delta($1::uuid, $2::numeric, $3::uuid, NULL, FALSE, TRUE)",
                            product_id,
                            -movement["quantity_delta"],
                            movement["branch_id"],
                        )
                    await self._conn.execute(
                        "DELETE FROM stock_movements WHERE reference_id = $1 AND reference_type = 'purchase'",
                        purchase_id,
                    )
            await self._conn.execute(
                "DELETE FROM purchases WHERE operation_id = $1::uuid AND account_id = $2::uuid",
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
        purchase_ids: list[str],
        date: datetime.date,
        description: str | None,
        items: list[dict],
    ) -> None:
        # rpc_atomic_update_purchase_operation hace REVERSE de los ítems viejos +
        # APPLY de los nuevos en una sola transacción (stock sobre branch_stock,
        # C-21 hotfix). RLS/auth.uid() scope vía JWT-passthrough de la conexión.
        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        await self._conn.execute(
            "SELECT rpc_atomic_update_purchase_operation($1::text[]::uuid[], $2::date, $3::text, $4::jsonb)",
            purchase_ids,
            date,
            description,
            json.dumps(items, default=_default),
        )

    async def create_operation(
        self,
        user_id: str,
        account_id: str,
        items: list[dict],
        idempotency_key: str,
        date: datetime.date | None = None,
        description: str | None = None,
    ) -> dict | None:
        existing = await self.get_idempotency(account_id, idempotency_key)
        if existing is not None:
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

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

    async def create_operation_with_event(
        self,
        outbox_repo: "OutboxRepository",
        user_id: str,
        account_id: str,
        items: list[dict],
        idempotency_key: str,
        date: datetime.date | None = None,
        description: str | None = None,
    ) -> dict | None:
        """C-25 producer: create purchase + emit PurchaseCreated in the SAME transaction.

        Per DEC-20: the event INSERT is in the same transaction as the mutation.
        If the mutation fails, the event row rolls back with it (no orphaned event).
        On idempotency hit (existing operation), no new event is emitted.
        """
        existing = await self.get_idempotency(account_id, idempotency_key)
        if existing is not None:
            # Idempotency replay — return existing, do NOT emit a duplicate event
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        clean_items = [
            {k: v for k, v in item.items() if k != "description"}
            for item in items
        ]

        # Run mutation + event INSERT in the same transaction (DEC-20)
        async with self._conn.transaction():
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

            if row is None:
                return None

            operation_id = str(row["operation_id"])

            # C-25 DEC-20: emit PurchaseCreated in the same transaction
            await outbox_repo.emit_event(
                account_id=account_id,
                event_type="PurchaseCreated",
                aggregate_type="Purchase",
                aggregate_id=operation_id,
                payload={
                    "account_id": account_id,
                    "operation_id": operation_id,
                    "item_count": len(clean_items),
                },
            )

        return dict(row)
