"""
Repository para C-30 — SupplierAccount / PaymentMade / SupplierCharge.

Espejo exacto de CustomerAccountRepository para el dominio de proveedores.
JWT-passthrough via base.py.
"""
from __future__ import annotations

import json

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class SupplierAccountRepository(BaseRepository):
    """Repository para cuentas corrientes de proveedores — JWT-passthrough via base.py."""

    async def create_account(self, supplier_id: str) -> dict:
        """Invoca rpc_create_supplier_account(p_supplier_id) → crea/retorna la cuenta."""
        row = await self.fetchrow(
            "SELECT public.rpc_create_supplier_account($1::uuid) AS result",
            supplier_id,
        )
        return _jsonb(row["result"])

    async def get_account(self, account_id: str, supplier_id: str) -> asyncpg.Record | None:
        """Lee la fila de supplier_accounts para (account_id, supplier_id)."""
        return await self.fetchrow(
            """
            SELECT *
            FROM public.supplier_accounts
            WHERE account_id  = $1::uuid
              AND supplier_id = $2::uuid
            """,
            account_id,
            supplier_id,
        )

    async def list_movements(
        self,
        supplier_account_id: str,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict]:
        """Lista supplier_account_movements paginados por (supplier_account_id, created_at)."""
        return await self.fetch(
            """
            SELECT *
            FROM public.supplier_account_movements
            WHERE supplier_account_id = $1::uuid
            ORDER BY created_at DESC
            LIMIT $2
            OFFSET $3
            """,
            supplier_account_id,
            limit,
            offset,
        )

    async def register_payment_made(
        self,
        idempotency_key: str,
        supplier_id: str,
        amount: float,
        reference_purchase_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_payment_made → registra pago a la cuenta del proveedor."""
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_payment_made(
              $1::text, $2::uuid, $3::numeric, $4::uuid
            ) AS result
            """,
            idempotency_key,
            supplier_id,
            amount,
            reference_purchase_id,
        )
        return _jsonb(row["result"])

    async def register_supplier_charge(
        self,
        idempotency_key: str,
        supplier_id: str,
        amount: float,
        reference_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_supplier_charge → cargo manual en la cuenta del proveedor."""
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_supplier_charge(
              $1::text, $2::uuid, $3::numeric, $4::uuid
            ) AS result
            """,
            idempotency_key,
            supplier_id,
            amount,
            reference_id,
        )
        return _jsonb(row["result"])
