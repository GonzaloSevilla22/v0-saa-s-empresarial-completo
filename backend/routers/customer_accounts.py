"""
Router para C-30 — CustomerAccount / PaymentReceived.

Routes:
  POST /customer-accounts                → create (or get existing) CustomerAccount
  GET  /clientes/{client_id}/cuenta      → saldo + historial
  GET  /customer-accounts/{id}/movements → lista de movimientos paginados
  POST /customer-accounts/payments       → registrar cobro (PaymentReceived)

Arquitectura dura: routers = validación + DI únicamente.
Toda lógica y guards de rol viven en services/customer_accounts.py.
"""
from __future__ import annotations

import uuid
from typing import Optional

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.customer_account_repository import CustomerAccountRepository
from backend.schemas.customer_accounts import (
    AccountMovementOut,
    CreateCustomerAccountOut,
    CustomerAccountOut,
    PaymentReceivedIn,
    PaymentReceivedOut,
)
from backend.services import customer_accounts as customer_account_service

router = APIRouter(tags=["customer-accounts"])


def get_customer_account_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> CustomerAccountRepository:
    return CustomerAccountRepository(conn)


@router.post("/customer-accounts", response_model=CreateCustomerAccountOut, status_code=201)
async def create_customer_account(
    client_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
):
    """Crea o retorna la cuenta corriente de un cliente (idempotente)."""
    return await customer_account_service.create_account(repo, auth, str(client_id))


@router.get("/clientes/{client_id}/cuenta")
async def get_customer_account(
    client_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Devuelve el saldo actual + historial de la cuenta corriente del cliente."""
    # Derivar account_id del JWT claims (el repo usa la conexión con JWT-passthrough)
    account_id = auth.get("account_id") or auth.get("sub", "")
    repo = CustomerAccountRepository(conn)
    return await customer_account_service.get_account(repo, account_id, str(client_id))


@router.get("/customer-accounts/{customer_account_id}/movements", response_model=list[AccountMovementOut])
async def list_customer_movements(
    customer_account_id: uuid.UUID,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
):
    """Lista paginada de movimientos de la cuenta corriente."""
    return await customer_account_service.list_movements(
        repo, str(customer_account_id), limit=limit, offset=offset
    )


@router.post("/customer-accounts/payments", response_model=PaymentReceivedOut)
async def register_payment_received(
    payload: PaymentReceivedIn,
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
):
    """Registra un cobro en la cuenta corriente del cliente. Idempotente."""
    return await customer_account_service.register_payment_received(repo, auth, payload)
