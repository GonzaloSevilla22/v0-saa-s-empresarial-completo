from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.stock_repository import StockRepository
from backend.schemas.stock import StockOut, StockTransferRequest
from backend.services import stock as stock_service

router = APIRouter(prefix="/stock", tags=["stock"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> StockRepository:
    return StockRepository(conn)


@router.get("/product/{product_id}", response_model=StockOut)
async def get_stock(
    product_id: str,
    auth: dict = Depends(get_current_user),
    repo: StockRepository = Depends(get_repo),
):
    return await stock_service.get_stock(repo, auth, product_id)


@router.get("/movements/{product_id}")
async def list_movements(
    product_id: str,
    auth: dict = Depends(get_current_user),
    repo: StockRepository = Depends(get_repo),
):
    return await stock_service.list_movements(repo, auth, product_id)


@router.post("/transfer", status_code=200)
async def transfer_stock(
    payload: StockTransferRequest,
    auth: dict = Depends(get_current_user),
    repo: StockRepository = Depends(get_repo),
):
    return await stock_service.transfer_stock(repo, auth, payload)
