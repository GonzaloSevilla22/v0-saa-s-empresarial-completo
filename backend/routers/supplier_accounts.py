"""
Router para C-30 — SupplierAccount / PaymentMade / SupplierCharge.

Routes:
  POST /supplier-accounts                 → create (or get existing) SupplierAccount
  GET  /proveedores/{supplier_id}/cuenta  → saldo + historial
  POST /supplier-accounts/payments        → registrar pago (PaymentMade)
  POST /supplier-accounts/charges         → registrar cargo manual

Arquitectura dura: routers = validación + DI únicamente.
Toda lógica y guards de rol viven en services/supplier_accounts.py.
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.supplier_account_repository import SupplierAccountRepository
from backend.schemas.supplier_accounts import (
    CreateSupplierAccountOut,
    PaymentMadeIn,
    PaymentMadeOut,
    SupplierAccountOut,
    SupplierChargeIn,
    SupplierChargeOut,
    SupplierMovementOut,
)
from backend.services import supplier_accounts as supplier_account_service

router = APIRouter(tags=["supplier-accounts"])


def get_supplier_account_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> SupplierAccountRepository:
    return SupplierAccountRepository(conn)


@router.post("/supplier-accounts", response_model=CreateSupplierAccountOut, status_code=201)
async def create_supplier_account(
    supplier_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """Crea o retorna la cuenta corriente de un proveedor (idempotente)."""
    return await supplier_account_service.create_account(repo, auth, str(supplier_id))


@router.get("/proveedores/{supplier_id}/cuenta")
async def get_supplier_account(
    supplier_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Devuelve el saldo actual + historial de la cuenta corriente del proveedor."""
    account_id = auth.get("account_id") or auth.get("sub", "")
    repo = SupplierAccountRepository(conn)
    return await supplier_account_service.get_account(repo, account_id, str(supplier_id))


@router.get("/supplier-accounts/{supplier_account_id}/movements", response_model=list[SupplierMovementOut])
async def list_supplier_movements(
    supplier_account_id: uuid.UUID,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """Lista paginada de movimientos de la cuenta corriente del proveedor."""
    return await supplier_account_service.get_account(
        repo, str(supplier_account_id), str(supplier_account_id)
    )


@router.post("/supplier-accounts/payments", response_model=PaymentMadeOut)
async def register_payment_made(
    payload: PaymentMadeIn,
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """Registra un pago al proveedor. Idempotente."""
    return await supplier_account_service.register_payment_made(repo, auth, payload)


@router.post("/supplier-accounts/charges", response_model=SupplierChargeOut)
async def register_supplier_charge(
    payload: SupplierChargeIn,
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """Registra un cargo manual en la cuenta corriente del proveedor. Idempotente."""
    return await supplier_account_service.register_supplier_charge(repo, auth, payload)
