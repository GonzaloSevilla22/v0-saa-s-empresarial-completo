"""
Service layer para el historial de movimientos bancarios
(banco-caja-historial-ajustes, D3 — ledger-movement-history).

Lectura — sin require_role, mismo criterio que el resto de los listados de
este módulo (list_active de bank_accounts, list_sessions de cash): cualquier
miembro autenticado de la cuenta puede leer.

fix/tenancy-bank-accounts-leak (2026-08-22): NO es cierto que "RLS ya aísla
por tenant" — el pool corre la sesión como owner de las tablas mientras
TENANCY_TX_SCOPE_ENABLED sigue apagada, así que list_movements_page llevaba
un IDOR (bank_account_id de otro tenant devolvía sus movimientos). Este
service ahora verifica pertenencia PRIMERO (404 explícito si el
bank_account_id no es de la cuenta del caller) antes de listar.
"""
from __future__ import annotations

from datetime import date

from fastapi import HTTPException

from backend.repositories.bank_account_repository import BankAccountRepository


async def list_movements(
    repo: BankAccountRepository,
    bank_account_id: str,
    *,
    account_id: str,
    page: int,
    size: int,
    types: list[str] | None,
    status: str | None,
    q: str | None,
    date_from: date | None,
    date_to: date | None,
) -> dict:
    owned = await repo.get_by_id_for_account(bank_account_id, account_id)
    if owned is None:
        raise HTTPException(status_code=404, detail="Cuenta bancaria no encontrada")
    return await repo.list_movements_page(
        bank_account_id,
        account_id=account_id,
        page=page,
        size=size,
        types=types,
        status=status,
        q=q,
        date_from=date_from,
        date_to=date_to,
    )
