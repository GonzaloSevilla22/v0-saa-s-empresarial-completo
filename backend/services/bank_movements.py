"""
Service layer para el historial de movimientos bancarios
(banco-caja-historial-ajustes, D3 — ledger-movement-history).

Lectura — sin require_role, mismo criterio que el resto de los listados de
este módulo (list_active de bank_accounts, list_sessions de cash): cualquier
miembro autenticado de la cuenta puede leer, RLS ya aísla por tenant.
"""
from __future__ import annotations

from datetime import date

from backend.repositories.bank_account_repository import BankAccountRepository


async def list_movements(
    repo: BankAccountRepository,
    bank_account_id: str,
    *,
    page: int,
    size: int,
    types: list[str] | None,
    status: str | None,
    q: str | None,
    date_from: date | None,
    date_to: date | None,
) -> dict:
    return await repo.list_movements_page(
        bank_account_id,
        page=page,
        size=size,
        types=types,
        status=status,
        q=q,
        date_from=date_from,
        date_to=date_to,
    )
