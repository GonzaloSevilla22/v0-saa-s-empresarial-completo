"""
Router de estadisticas-ventas E1 — read-models del módulo de estadísticas.

Routes:
  GET /reports/statistics/evolution → evolución por día/semana/mes + comparación
  GET /reports/statistics/products  → ranking de productos, paginado
  GET /reports/statistics/breakdown → desglose por canal / sucursal / día de la
                                      semana / hora de carga / categoría (E2)
  GET /reports/statistics/clients   → top clientes del período (E2, OQ-2)
  GET /reports/statistics/products/{product_id}
                                    → detalle de un producto y su grupo de
                                      variantes por intervalo (E3, D12)

Arquitectura dura: routers = validación + DI únicamente. La lógica vive en
services/statistics.py; el acceso a datos en repositories/statistics_repository.py.

`bucket` y `order_by` son Literal: un valor fuera del dominio devuelve 422 sin
ejecutar ninguna consulta (D9, mismo patrón que GET /reports/receivables).
Sin gate de plan: el historial se recorta en la RPC (D8).
"""
from __future__ import annotations

import datetime
import uuid
from typing import Literal

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.statistics_repository import StatisticsRepository
from backend.schemas.statistics import (
    ProductRankingPageOut,
    ProductSalesDetailOut,
    SalesBreakdownOut,
    SalesEvolutionOut,
    TopClientsOut,
)
from backend.services import statistics as statistics_service

# Espejo estructural del report_router de customer_accounts (/reports/*).
report_router = APIRouter(prefix="/reports/statistics", tags=["statistics"])


def get_statistics_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> StatisticsRepository:
    return StatisticsRepository(conn)


@report_router.get("/evolution", response_model=SalesEvolutionOut)
async def sales_evolution(
    start: datetime.date = Query(..., description="Inicio del rango (fecha de negocio)"),
    end: datetime.date = Query(..., description="Fin del rango, incluido completo"),
    bucket: Literal["day", "week", "month"] = Query("day"),
    branch_id: uuid.UUID | None = Query(None),
    canal: str | None = Query(None, max_length=80),
    auth: dict = Depends(get_current_user),
    repo: StatisticsRepository = Depends(get_statistics_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Evolución de ventas con comparación contra el período anterior.

    La ventana aplicada (clamp de historial por plan) viaja en `window`; los
    intervalos sin ventas viajan en cero. Las NC del período se restan por
    el mismo helper que el Tablero (D7)."""
    return await statistics_service.get_sales_evolution(
        repo, str(account_id),
        start=start, end=end, bucket=bucket,
        branch_id=str(branch_id) if branch_id else None,
        canal=canal,
    )


@report_router.get("/products", response_model=ProductRankingPageOut)
async def product_ranking(
    start: datetime.date = Query(...),
    end: datetime.date = Query(...),
    order_by: Literal["units", "revenue", "margin"] = Query("units"),
    group_variants: bool = Query(True),
    page: int = Query(0, ge=0),
    size: int = Query(25, ge=1, le=200),
    branch_id: uuid.UUID | None = Query(None),
    canal: str | None = Query(None, max_length=80),
    auth: dict = Depends(get_current_user),
    repo: StatisticsRepository = Depends(get_statistics_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Ranking de productos del período (envelope estándar).

    El orden se resuelve en el servidor sobre el conjunto completo, nunca
    sobre la página visible. Las líneas de servicio no rankean (D6); su
    importe lo declara la evolución (`service_revenue`)."""
    return await statistics_service.get_product_ranking(
        repo, str(account_id),
        start=start, end=end, order_by=order_by, group_variants=group_variants,
        page=page, size=size,
        branch_id=str(branch_id) if branch_id else None,
        canal=canal,
    )


@report_router.get("/breakdown", response_model=SalesBreakdownOut)
async def sales_breakdown(
    start: datetime.date = Query(...),
    end: datetime.date = Query(...),
    dimension: Literal["canal", "branch", "weekday", "hour", "category"] = Query(
        ..., description="Dimensión del desglose"
    ),
    branch_id: uuid.UUID | None = Query(None),
    canal: str | None = Query(None, max_length=80),
    auth: dict = Depends(get_current_user),
    repo: StatisticsRepository = Depends(get_statistics_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Desglose del período por una dimensión (E2).

    El tramo "Sin canal" / "Sin sucursal" / "Sin categoría" viaja con `key`
    null y nunca se omite; día de la semana y hora vienen completos (7 / 24
    filas). La hora es de CARGA de la operación (`created_at`), no de venta
    (OQ-1). Ningún desglose resta notas de crédito (D7)."""
    return await statistics_service.get_sales_breakdown(
        repo, str(account_id),
        start=start, end=end, dimension=dimension,
        branch_id=str(branch_id) if branch_id else None,
        canal=canal,
    )


@report_router.get("/clients", response_model=TopClientsOut)
async def top_clients(
    start: datetime.date = Query(...),
    end: datetime.date = Query(...),
    branch_id: uuid.UUID | None = Query(None),
    limit: int = Query(10, ge=1, le=200),
    auth: dict = Depends(get_current_user),
    repo: StatisticsRepository = Depends(get_statistics_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Top clientes del período por importe (E2, OQ-2).

    Las ventas sin cliente no compiten: su importe viaja en `unassigned`
    para que la superficie lo declare. El orden se resuelve en el servidor
    sobre el conjunto completo; `limit` acota sólo las filas de cliente."""
    return await statistics_service.get_top_clients(
        repo, str(account_id),
        start=start, end=end,
        branch_id=str(branch_id) if branch_id else None,
        limit=limit,
    )


@report_router.get("/products/{product_id}", response_model=ProductSalesDetailOut)
async def product_sales_detail(
    product_id: uuid.UUID,
    start: datetime.date = Query(...),
    end: datetime.date = Query(...),
    bucket: Literal["day", "week", "month"] = Query("day"),
    branch_id: uuid.UUID | None = Query(None),
    canal: str | None = Query(None, max_length=80),
    auth: dict = Depends(get_current_user),
    repo: StatisticsRepository = Depends(get_statistics_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Detalle de un producto (E3, D12): evolución por intervalo del producto
    y su grupo de variantes, totales del período y desglose por miembro.

    La tenencia la resuelve el read-model: un producto de otra cuenta o
    inexistente responde 404 (RFC 7807), nunca un detalle vacío. Un producto
    sin ventas en el período responde 200 con totales en cero y margen
    null. No resta notas de crédito (una NC no tiene producto atribuible)."""
    return await statistics_service.get_product_sales_evolution(
        repo, str(account_id),
        product_id=str(product_id),
        start=start, end=end, bucket=bucket,
        branch_id=str(branch_id) if branch_id else None,
        canal=canal,
    )
