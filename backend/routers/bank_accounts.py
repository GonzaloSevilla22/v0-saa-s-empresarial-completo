"""
Router para bank_accounts — lectura (C2) y alta (bank-account-crud).

Routes:
  GET  /bank-accounts → lista de cuentas bancarias activas de la organización
                         (picker de cuenta bancaria en el formulario de cobro/pago).
  POST /bank-accounts → alta de una cuenta bancaria (invoca rpc_create_bank_account).

Arquitectura dura: routers = validación + DI únicamente; la lógica y los guards
viven en el service (backend/services/bank_accounts.py).
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.bank_account_repository import BankAccountRepository
from backend.schemas.bank_accounts import BankAccountCreate, BankAccountOut
from backend.services import bank_accounts as bank_account_service

router = APIRouter(tags=["bank-accounts"])


def get_bank_account_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> BankAccountRepository:
    return BankAccountRepository(conn)


@router.get("/bank-accounts", response_model=list[BankAccountOut])
async def list_bank_accounts(
    auth: dict = Depends(get_current_user),
    repo: BankAccountRepository = Depends(get_bank_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Lista las cuentas bancarias activas de la organización (para el picker de cobro/pago).

    fix/tenancy-bank-accounts-leak: account_id SIEMPRE explícito — nunca
    confiar solo en RLS (ver nota en BankAccountRepository.list_active)."""
    return await repo.list_active(str(account_id))


@router.post("/bank-accounts", response_model=BankAccountOut, status_code=201)
async def create_bank_account(
    payload: BankAccountCreate,
    auth: dict = Depends(get_current_user),
    repo: BankAccountRepository = Depends(get_bank_account_repo),
):
    """Crea una cuenta bancaria (rpc_create_bank_account). Requiere rol user/admin."""
    return await bank_account_service.create_bank_account(repo, auth, payload)
