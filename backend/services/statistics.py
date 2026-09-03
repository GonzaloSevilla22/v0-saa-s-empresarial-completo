"""
estadisticas-ventas E1 — service del read-model de estadísticas de ventas
(task 3.3).

Sin gate de plan y sin require_role: el módulo está disponible en TODOS los
planes (D8 — el historial se recorta dentro de la RPC contra
get_effective_plan, nunca contra auth["plan"], que cae a "pro" sin claim) y
es lectura para todo miembro; la autorización de tenant es el P0401 del
propio RPC.

Responsabilidades: validar el rango (422 sin consulta), resolver el orden y el
bucket por diccionario (nunca interpolando), componer la evolución por
`period` y propagar ERRCODEs → HTTP.
"""
from __future__ import annotations

import datetime

import asyncpg
from fastapi import HTTPException

from backend.repositories.statistics_repository import (
    StatisticsRepository,
    window_from_row,
)

# P0400 (bucket/orden/rango inválidos en la RPC) → 422: es un error de
# validación de entrada, el mismo status que el router da por Literal.
_ERRCODE_STATUS = {
    "P0400": 422,
    "P0401": 403,
    "P0403": 403,
    "P0404": 404,
}

# Diccionarios cerrados API → RPC. El router ya acota por Literal; esto es la
# segunda línea: un valor fuera del dominio jamás llega a la base.
_RANKING_ORDER: dict[str, str] = {
    "units":   "units",
    "revenue": "revenue",
    "margin":  "margin",
}
_EVOLUTION_BUCKET: dict[str, str] = {
    "day":   "day",
    "week":  "week",
    "month": "month",
}

_METRIC_KEYS = (
    "revenue", "credit_notes", "net_revenue", "units", "operations", "service_revenue",
)


def _pg_to_http(exc: asyncpg.PostgresError) -> HTTPException:
    code = exc.sqlstate if hasattr(exc, "sqlstate") else None
    status = _ERRCODE_STATUS.get(code, 500)
    try:
        detail = str(exc)
    except (IndexError, Exception):
        detail = f"Error de base de datos (ERRCODE: {code})"
    return HTTPException(status_code=status, detail=detail)


def _validate_range(start: datetime.date, end: datetime.date) -> None:
    if end < start:
        raise HTTPException(
            status_code=422,
            detail="El fin del rango es anterior al inicio",
        )


def _point(row: dict) -> dict:
    return {
        "bucket_start": row["bucket_start"],
        "bucket_end":   row["bucket_end"],
        **{k: row[k] for k in _METRIC_KEYS},
    }


def _totals(row: dict) -> dict:
    return {
        "start": row["bucket_start"],
        "end":   row["bucket_end"],
        **{k: row[k] for k in _METRIC_KEYS},
    }


async def get_sales_evolution(
    repo: StatisticsRepository,
    account_id: str,
    *,
    start: datetime.date,
    end: datetime.date,
    bucket: str,
    branch_id: str | None,
    canal: str | None,
) -> dict:
    """Evolución por intervalo + totales del período actual y del anterior.

    Las filas 'current' y 'previous' las produce la RPC: acá no se re-agregan
    buckets (invariante de consumo de reporting-invariants)."""
    _validate_range(start, end)
    rpc_bucket = _EVOLUTION_BUCKET.get(bucket)
    if rpc_bucket is None:
        raise HTTPException(status_code=422, detail=f"Granularidad no admitida: {bucket}")

    try:
        rows = await repo.fetch_sales_evolution(
            account_id, start=start, end=end, bucket=rpc_bucket,
            branch_id=branch_id, canal=canal,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc

    current = next((r for r in rows if r["period"] == "current"), None)
    previous = next((r for r in rows if r["period"] == "previous"), None)
    if current is None or previous is None:
        raise HTTPException(
            status_code=500,
            detail="El read-model de evolución no devolvió las filas de totales",
        )

    return {
        "bucket":   bucket,
        "window":   window_from_row(current),
        "points":   [_point(r) for r in rows if r["period"] == "bucket"],
        "current":  _totals(current),
        "previous": _totals(previous),
    }


async def get_product_ranking(
    repo: StatisticsRepository,
    account_id: str,
    *,
    start: datetime.date,
    end: datetime.date,
    order_by: str,
    group_variants: bool,
    page: int,
    size: int,
    branch_id: str | None,
    canal: str | None,
) -> dict:
    """Ranking paginado (envelope estándar + ventana aplicada)."""
    _validate_range(start, end)
    rpc_order = _RANKING_ORDER.get(order_by)
    if rpc_order is None:
        raise HTTPException(status_code=422, detail=f"Orden no admitido: {order_by}")

    try:
        return await repo.fetch_product_ranking_page(
            account_id, start=start, end=end, order_by=rpc_order,
            group_variants=group_variants, page=page, size=size,
            branch_id=branch_id, canal=canal,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc
