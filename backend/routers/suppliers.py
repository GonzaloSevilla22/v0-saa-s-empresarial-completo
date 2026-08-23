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
    supplier_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    return await supplier_service.get_supplier(repo, str(account_id), supplier_id)


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
    supplier_id: str,
    payload: SupplierUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    return await supplier_service.update_supplier(repo, auth, str(account_id), supplier_id, payload)


@router.delete("/{supplier_id}", status_code=204)
async def delete_supplier(
    supplier_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SupplierRepository = Depends(get_repo),
):
    await supplier_service.delete_supplier(repo, auth, str(account_id), supplier_id)
