"""
Repository para bank-payment-routing C2 — lectura de bank_accounts.

Solo lectura: SELECT directo (RLS SELECT de bank-account-ledger C1 aplica vía
JWT-passthrough). Sin mutaciones — la creación/edición de cuentas vive en C1
(rpc_create_bank_account/rpc_update_bank_account, sin wiring de backend aún).
"""
from __future__ import annotations

from backend.repositories.base import BaseRepository


class BankAccountRepository(BaseRepository):
    """Repository de solo lectura para el picker de cuenta bancaria — JWT-passthrough via base.py."""

    async def list_active(self) -> list[dict]:
        """Lista las bank_accounts activas visibles por RLS (cuenta del usuario)."""
        return await self.fetch(
            """
            SELECT id, account_id, name, bank_name, cbu, alias, currency, is_active
            FROM public.bank_accounts
            WHERE is_active = true
            ORDER BY name
            """
        )
