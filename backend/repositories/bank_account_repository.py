"""
Repository para bank_accounts — lectura (C2) y alta (bank-account-crud).

JWT-passthrough (invariant de BaseRepository) mantiene la RLS activa. La
creación invoca la RPC SECURITY DEFINER ya existente `rpc_create_bank_account`
(bank-account-ledger C1, migración 20260804000002) — sin INSERT directo, sin
service_role. Tras la RPC se hace un re-SELECT por id para devolver el shape
completo de BankAccountOut (D2 del design: consistencia con lo persistido).
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal

from backend.repositories.base import BaseRepository


class BankAccountRepository(BaseRepository):
    """Repository de bank_accounts — JWT-passthrough via base.py."""

    async def list_active(self) -> list[dict]:
        """Lista las bank_accounts activas visibles por RLS (cuenta del usuario).

        v3-soft-delete-policy (D1): is_active = baja lógica reversible;
        deleted_at IS NULL excluye además las borradas (RN-B1). El borrado
        real es soft_delete("bank_accounts", ...) del BaseRepository.
        """
        return await self.fetch(
            """
            SELECT id, account_id, name, bank_name, cbu, alias, currency, is_active
            FROM public.bank_accounts
            WHERE is_active = true
              AND deleted_at IS NULL
            ORDER BY name
            """
        )

    async def create(
        self,
        *,
        name: str,
        bank_name: str | None,
        cbu: str | None,
        alias: str | None,
        currency: str,
        opening_balance: Decimal,
        opening_date: date | None,
    ) -> dict | None:
        """Invoca rpc_create_bank_account (SECURITY DEFINER) y re-SELECT-a la fila creada.

        La RPC devuelve un jsonb con bank_account_id/account_id/name/currency/
        opening_balance/is_active (no incluye bank_name/cbu/alias). Se re-SELECT-a
        por id para armar el shape completo de BankAccountOut, consistente con lo
        que quedó persistido.
        """
        rpc_row = await self.fetchrow(
            "SELECT rpc_create_bank_account($1, $2, $3, $4, $5, $6, $7) AS result",
            name,
            bank_name,
            cbu,
            alias,
            currency,
            opening_balance,
            opening_date,
        )
        if rpc_row is None:
            return None
        result = rpc_row["result"]
        bank_account_id = result["bank_account_id"] if isinstance(result, dict) else result
        return await self._get_by_id(bank_account_id)

    async def _get_by_id(self, bank_account_id) -> dict | None:
        record = await self.fetchrow(
            """
            SELECT id, account_id, name, bank_name, cbu, alias, currency, is_active
            FROM public.bank_accounts
            WHERE id = $1
            """,
            bank_account_id,
        )
        return dict(record) if record is not None else None
