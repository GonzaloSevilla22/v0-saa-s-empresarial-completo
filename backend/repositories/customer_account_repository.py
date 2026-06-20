"""
Repository para C-30 — CustomerAccount / PaymentReceived.

JWT-passthrough via base.py (conexión ya configurada con claims del usuario).
Mutaciones via SELECT rpc_...(args) → SECURITY DEFINER RPCs.
Lecturas de saldo/historial via SELECT directo (RLS SELECT aplica).
"""
from __future__ import annotations

import json

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class CustomerAccountRepository(BaseRepository):
    """Repository para cuentas corrientes de clientes — JWT-passthrough via base.py."""

    async def create_account(self, client_id: str) -> dict:
        """Invoca rpc_create_customer_account(p_client_id) → crea/retorna la cuenta."""
        row = await self.fetchrow(
            "SELECT public.rpc_create_customer_account($1::uuid) AS result",
            client_id,
        )
        return _jsonb(row["result"])

    async def get_account(self, account_id: str, client_id: str) -> asyncpg.Record | None:
        """Lee la fila de customer_accounts para (account_id, client_id)."""
        return await self.fetchrow(
            """
            SELECT *
            FROM public.customer_accounts
            WHERE account_id = $1::uuid
              AND client_id  = $2::uuid
            """,
            account_id,
            client_id,
        )

    async def list_movements(
        self,
        customer_account_id: str,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict]:
        """Lista customer_account_movements paginados por (customer_account_id, created_at)."""
        return await self.fetch(
            """
            SELECT *
            FROM public.customer_account_movements
            WHERE customer_account_id = $1::uuid
            ORDER BY created_at DESC
            LIMIT $2
            OFFSET $3
            """,
            customer_account_id,
            limit,
            offset,
        )

    async def register_payment_received(
        self,
        idempotency_key: str,
        client_id: str,
        amount: float,
        reference_sale_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_payment_received → registra cobro en la cuenta del cliente."""
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_payment_received(
              $1::text, $2::uuid, $3::numeric, $4::uuid
            ) AS result
            """,
            idempotency_key,
            client_id,
            amount,
            reference_sale_id,
        )
        return _jsonb(row["result"])
