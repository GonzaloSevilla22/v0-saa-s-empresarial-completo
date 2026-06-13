from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository

# Recibos = pagos aprobados (billing_events.event_type='plan_upgraded').
# Se accede con una conexión service (BYPASSRLS) porque el admin lee pagos de
# TODAS las cuentas; el gating de admin lo hace `require_admin` en el router.
_RECEIPT_SELECT = """
    SELECT be.id,
           be.receipt_number,
           be.mercadopago_payment_id AS payment_id,
           be.to_plan                AS plan,
           be.amount,
           be.created_at,
           u.email                   AS customer_email,
           p.name                    AS customer_name
    FROM billing_events be
    JOIN auth.users u ON u.id = be.user_id
    LEFT JOIN profiles p ON p.id = be.user_id
    WHERE be.event_type = 'plan_upgraded'
"""


class BillingRepository(BaseRepository):
    async def list_receipts(
        self, limit: int, offset: int
    ) -> tuple[list[asyncpg.Record], int]:
        total: int = await self._conn.fetchval(
            "SELECT count(*) FROM billing_events WHERE event_type = 'plan_upgraded'"
        ) or 0
        rows: list[asyncpg.Record] = await self._conn.fetch(
            _RECEIPT_SELECT + " ORDER BY be.created_at DESC LIMIT $1 OFFSET $2",
            limit,
            offset,
        )
        return rows, total

    async def get_receipt(self, billing_event_id: str) -> asyncpg.Record | None:
        return await self._conn.fetchrow(
            _RECEIPT_SELECT + " AND be.id = $1::uuid",
            billing_event_id,
        )
