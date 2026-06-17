"""
Router para C-29 v21-quote-salesorder — SalesOrder endpoints.

Routes:
  GET  /sales-orders              → listar órdenes de venta de la cuenta
  GET  /sales-orders/{id}         → obtener orden por id
  POST /sales-orders/{id}/confirm → confirmar orden existente (hot path)
  POST /sales-orders/quick-sale   → crear + confirmar en un paso (POS)

IMPORTANTE: /quick-sale debe ir ANTES de /{id} para que FastAPI
no trate "quick-sale" como un UUID.

Regla dura: routers hacen validación + DI únicamente.
Toda la lógica de negocio y guards en services/sales_orders.py.
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.sales_order_repository import SalesOrderRepository
from backend.schemas.sales_orders import (
    ConfirmIn,
    ConfirmOut,
    QuickSaleIn,
    SalesOrderOut,
)
from backend.services import sales_orders as so_service

router = APIRouter(tags=["sales-orders"])


# ── Dependency ────────────────────────────────────────────────────────────────

def get_so_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> SalesOrderRepository:
    return SalesOrderRepository(conn)


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/sales-orders", response_model=list[SalesOrderOut])
async def list_orders(
    auth: dict = Depends(get_current_user),
    repo: SalesOrderRepository = Depends(get_so_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await so_service.list_orders(repo, str(account_id))


# IMPORTANTE: quick-sale antes de /{id} para evitar que "quick-sale" sea interpretado como UUID
@router.post("/sales-orders/quick-sale", response_model=ConfirmOut)
async def quick_sale(
    payload: QuickSaleIn,
    auth: dict = Depends(get_current_user),
    repo: SalesOrderRepository = Depends(get_so_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await so_service.quick_sale(
        repo=repo,
        auth=auth,
        payload=payload,
        account_id=str(account_id),
    )


@router.get("/sales-orders/{sales_order_id}", response_model=SalesOrderOut)
async def get_order(
    sales_order_id: str,
    auth: dict = Depends(get_current_user),
    repo: SalesOrderRepository = Depends(get_so_repo),
):
    return await so_service.get_order(repo, sales_order_id)


@router.post("/sales-orders/{sales_order_id}/confirm", response_model=ConfirmOut)
async def confirm_order(
    sales_order_id: str,
    payload: ConfirmIn,
    auth: dict = Depends(get_current_user),
    repo: SalesOrderRepository = Depends(get_so_repo),
):
    return await so_service.confirm(
        repo=repo,
        auth=auth,
        sales_order_id=sales_order_id,
        payload=payload,
    )
