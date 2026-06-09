from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.sales_repository import SalesRepository
from backend.schemas.sales import SaleOperationIn, SaleOperationOut, SalesPageOut
from backend.services import sales as sales_service

router = APIRouter(prefix="/sales", tags=["sales"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> SalesRepository:
    return SalesRepository(conn)


@router.get("", response_model=SalesPageOut)
async def list_sales(
    page: int = Query(0, ge=0),
    page_size: int = Query(25, ge=1, le=100),
    date_from: str | None = Query(None),
    date_to: str | None = Query(None),
    auth: dict = Depends(get_current_user),
    repo: SalesRepository = Depends(get_repo),
):
    return await sales_service.list_sales_paginated(
        repo, auth, page, page_size, date_from, date_to,
    )


@router.post("", response_model=SaleOperationOut, status_code=201)
async def create_sale(
    payload: SaleOperationIn,
    auth: dict = Depends(get_current_user),
    repo: SalesRepository = Depends(get_repo),
):
    return await sales_service.create_sale_operation(repo, auth, payload)
