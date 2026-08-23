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
        account_id: str,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict]:
        """Lista customer_account_movements paginados por (customer_account_id, created_at).

        Usado por `get_account` (vista combinada saldo+historial) — mantiene
        su firma limit/offset. Para el endpoint dedicado de listado usar
        `list_movements_page` (v3-api-standards §2.7).

        fix/tenancy-bank-accounts-leak (2026-08-22): `account_id` obligatorio
        — antes solo filtraba por customer_account_id (IDOR: un id de OTRO
        tenant devolvía sus movimientos). account_id está desnormalizado en
        la tabla (RLS), así que el filtro es directo, sin JOIN.
        """
        return await self.fetch(
            """
            SELECT *
            FROM public.customer_account_movements
            WHERE customer_account_id = $1::uuid AND account_id = $2::uuid
            ORDER BY created_at DESC
            LIMIT $3
            OFFSET $4
            """,
            customer_account_id,
            account_id,
            limit,
            offset,
        )

    async def list_movements_page(
        self,
        customer_account_id: str,
        *,
        account_id: str,
        page: int,
        size: int,
    ) -> dict:
        """v3-api-standards §2.7: envelope estándar {items,total,page,pages}
        para GET /customer-accounts/{id}/movements (reemplaza limit/offset +
        lista plana).

        fix/tenancy-bank-accounts-leak: `account_id` obligatorio — mismo IDOR
        que list_movements (ver nota ahí)."""
        return await self.paginate(
            """
            SELECT *
            FROM public.customer_account_movements
            WHERE customer_account_id = $1::uuid AND account_id = $2::uuid
            ORDER BY created_at DESC
            """,
            """
            SELECT COUNT(*)
            FROM public.customer_account_movements
            WHERE customer_account_id = $1::uuid AND account_id = $2::uuid
            """,
            customer_account_id,
            account_id,
            page=page,
            size=size,
        )

    async def register_payment_received(
        self,
        idempotency_key: str,
        client_id: str,
        amount: float,
        reference_sale_id: str | None = None,
        payment_method: str = "cash",
        bank_account_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_payment_received → registra cobro en la cuenta del cliente.

        bank-payment-routing C2: payment_method/bank_account_id son params aditivos
        trailing (default cash/None) — retrocompatibles con la firma de C-30.
        """
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_payment_received(
              $1::text, $2::uuid, $3::numeric, $4::uuid, $5::text, $6::uuid
            ) AS result
            """,
            idempotency_key,
            client_id,
            amount,
            reference_sale_id,
            payment_method,
            bank_account_id,
        )
        return _jsonb(row["result"])
