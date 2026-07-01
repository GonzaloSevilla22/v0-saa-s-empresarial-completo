"""
Router para bank-payment-routing C2 — lectura de bank_accounts.

Routes:
  GET /bank-accounts → lista de cuentas bancarias activas de la organización
                        (picker de cuenta bancaria en el formulario de cobro/pago).

Arquitectura dura: routers = validación + DI únicamente. Solo lectura — sin
mutaciones (la creación/edición de cuentas bancarias vive en bank-account-ledger
C1, sin wiring de backend aún).
"""
from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.bank_account_repository import BankAccountRepository
from backend.schemas.bank_accounts import BankAccountOut

router = APIRouter(tags=["bank-accounts"])


def get_bank_account_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> BankAccountRepository:
    return BankAccountRepository(conn)


@router.get("/bank-accounts", response_model=list[BankAccountOut])
async def list_bank_accounts(
    auth: dict = Depends(get_current_user),
    repo: BankAccountRepository = Depends(get_bank_account_repo),
):
    """Lista las cuentas bancarias activas de la organización (para el picker de cobro/pago)."""
    return await repo.list_active()
