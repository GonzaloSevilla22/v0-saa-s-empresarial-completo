from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.purchase_repository import PurchaseRepository
from backend.schemas.purchases import (
    PurchaseOperationIn,
    PurchaseOperationOut,
    PurchaseOperationUpdateIn,
    PurchasesPageOut,
)
from backend.services import purchases as purchases_service

router = APIRouter(prefix="/purchases", tags=["purchases"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PurchaseRepository:
    return PurchaseRepository(conn)


@router.get("", response_model=PurchasesPageOut)
async def list_purchases(
    page: int = Query(0, ge=0),
    page_size: int = Query(25, ge=1, le=100),
    date_from: str | None = Query(None),
    date_to: str | None = Query(None),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    return await purchases_service.list_purchases_paginated(
        repo, str(account_id), page, page_size, date_from, date_to,
    )


@router.delete("", status_code=204)
async def delete_purchases_by_operation(
    operation_id: str = Query(...),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    await purchases_service.delete_purchase_operation(repo, auth, str(account_id), operation_id)


@router.delete("/{purchase_id}", status_code=204)
async def delete_purchase(
    purchase_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    await purchases_service.delete_purchase(repo, auth, str(account_id), purchase_id)


@router.post("", response_model=PurchaseOperationOut, status_code=201)
async def create_purchase(
    payload: PurchaseOperationIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    return await purchases_service.create_purchase_operation(repo, auth, str(account_id), payload)


@router.put("/operation")
async def update_purchase_operation(
    payload: PurchaseOperationUpdateIn,
    auth: dict = Depends(get_current_user),
    repo: PurchaseRepository = Depends(get_repo),
):
    """Edita una operación de compra: reemplaza sus ítems vía
    rpc_atomic_update_purchase_operation (REVERSE + APPLY de stock, atómico)."""
    await purchases_service.update_purchase_operation(repo, auth, payload)
    return {"ok": True}
