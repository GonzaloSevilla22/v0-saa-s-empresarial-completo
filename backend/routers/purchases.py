from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.purchase_repository import PurchaseRepository
from backend.schemas.purchases import PurchaseOperationIn, PurchaseOperationOut
from backend.services import purchases as purchases_service

router = APIRouter(prefix="/purchases", tags=["purchases"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PurchaseRepository:
    return PurchaseRepository(conn)


@router.get("")
async def list_purchases(
    auth: dict = Depends(get_current_user),
    repo: PurchaseRepository = Depends(get_repo),
):
    return await purchases_service.list_purchases(repo, auth)


@router.delete("", status_code=204)
async def delete_purchases_by_operation(
    operation_id: str = Query(...),
    auth: dict = Depends(get_current_user),
    repo: PurchaseRepository = Depends(get_repo),
):
    await purchases_service.delete_purchase_operation(repo, auth, operation_id)


@router.delete("/{purchase_id}", status_code=204)
async def delete_purchase(
    purchase_id: str,
    auth: dict = Depends(get_current_user),
    repo: PurchaseRepository = Depends(get_repo),
):
    await purchases_service.delete_purchase(repo, auth, purchase_id)


@router.post("", response_model=PurchaseOperationOut, status_code=201)
async def create_purchase(
    payload: PurchaseOperationIn,
    auth: dict = Depends(get_current_user),
    repo: PurchaseRepository = Depends(get_repo),
):
    return await purchases_service.create_purchase_operation(repo, auth, payload)
