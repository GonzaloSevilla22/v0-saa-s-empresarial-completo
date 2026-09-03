"""
Router de estadisticas-ventas E1 — read-models del módulo de estadísticas.

Routes:
  GET /reports/statistics/evolution → evolución por día/semana/mes + comparación
  GET /reports/statistics/products  → ranking de productos, paginado

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
from backend.schemas.statistics import ProductRankingPageOut, SalesEvolutionOut
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
