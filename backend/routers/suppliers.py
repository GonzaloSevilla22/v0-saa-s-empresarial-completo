from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.supplier_repository import SupplierRepository
from backend.schemas.suppliers import SupplierCreate, SupplierOut, SupplierUpdate
from backend.services import suppliers as supplier_service

# review B (SEC-3): los 3 path params supplier_id son uuid.UUID, no str. La
# mayoría de los routers del repo tipan sus path params como `str` -- pero
# `supplier_accounts.py` (la superficie hermana de ESTA MISMA entidad, C-30)
# ya usa uuid.UUID, y es el contrato más seguro: FastAPI rechaza un id
# malformado con 422 RFC 7807 (field=supplier_id) en el borde, ANTES de que
# llegue como parámetro $1::uuid a asyncpg -- un "abc" viejo producía un
# DataError sin sqlstate mapeado en _BUSINESS_ERRCODE_STATUS y caía al
# catch-all de 500 (SEC-3, hallazgo del review).
router = APIRouter(prefix="/suppliers", tags=["suppliers"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> SupplierRepository:
    return SupplierRepository(conn)


@router.get("", response_model=list[SupplierOut])
async def list_suppliers(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    """supplier-directory: lista plana sin envelope, molde de GET /clients —
    consumida como selector por el form de compra (D10)."""
    return await supplier_service.list_suppliers(repo, str(account_id))


@router.get("/{supplier_id}", response_model=SupplierOut)
async def get_supplier(
    supplier_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    return await supplier_service.get_supplier(repo, str(account_id), str(supplier_id))


@router.post("", response_model=SupplierOut, status_code=201)
async def create_supplier(
    payload: SupplierCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    return await supplier_service.create_supplier(repo, auth, str(account_id), payload)


@router.put("/{supplier_id}", response_model=SupplierOut)
async def update_supplier(
    supplier_id: uuid.UUID,
    payload: SupplierUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    return await supplier_service.update_supplier(
        repo, auth, str(account_id), str(supplier_id), payload
    )


@router.delete("/{supplier_id}", status_code=204)
async def delete_supplier(
    supplier_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    await supplier_service.delete_supplier(repo, auth, str(account_id), str(supplier_id))
