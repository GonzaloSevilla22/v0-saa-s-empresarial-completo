from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.sales_repository import SalesRepository
from backend.schemas.sales import SaleOperationIn, SaleOperationOut
from backend.services import sales as sales_service

router = APIRouter(prefix="/sales", tags=["sales"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> SalesRepository:
    return SalesRepository(conn)


@router.get("")
async def list_sales(
    auth: dict = Depends(get_current_user),
    repo: SalesRepository = Depends(get_repo),
):
    return await sales_service.list_sales(repo, auth)


@router.post("", response_model=SaleOperationOut, status_code=201)
async def create_sale(
    payload: SaleOperationIn,
    auth: dict = Depends(get_current_user),
    repo: SalesRepository = Depends(get_repo),
):
    return await sales_service.create_sale_operation(repo, auth, payload)
