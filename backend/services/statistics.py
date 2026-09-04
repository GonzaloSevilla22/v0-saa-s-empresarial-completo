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
# E2: las cinco dimensiones de rpc_sales_breakdown.
_BREAKDOWN_DIMENSION: dict[str, str] = {
    "canal":    "canal",
    "branch":   "branch",
    "weekday":  "weekday",
    "hour":     "hour",
    "category": "category",
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


# ── E2 — desgloses por dimensión y top clientes ──────────────────────────────

def _breakdown_row(row: dict) -> dict:
    # El tramo "Sin …" viene con bucket_key NULL y su rótulo ya resuelto por el
    # read-model: acá no se filtra ni se renombra (spec: nunca omitido).
    return {
        "key":        row["bucket_key"],
        "label":      row["bucket_label"],
        "sort_order": row["sort_order"],
        "revenue":    row["revenue"],
        "units":      row["units"],
        "operations": row["operations"],
    }


async def get_sales_breakdown(
    repo: StatisticsRepository,
    account_id: str,
    *,
    start: datetime.date,
    end: datetime.date,
    dimension: str,
    branch_id: str | None,
    canal: str | None,
) -> dict:
    """Desglose del período por una dimensión (canal / branch / weekday /
    hour / category). Ningún tramo se re-agrega acá; la ventana aplicada
    viaja desde la primera fila (None si la dimensión no devolvió filas)."""
    _validate_range(start, end)
    rpc_dimension = _BREAKDOWN_DIMENSION.get(dimension)
    if rpc_dimension is None:
        raise HTTPException(status_code=422, detail=f"Dimensión no admitida: {dimension}")

    try:
        rows = await repo.fetch_sales_breakdown(
            account_id, start=start, end=end, dimension=rpc_dimension,
            branch_id=branch_id, canal=canal,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc

    return {
        "dimension": dimension,
        "window":    window_from_row(rows[0]) if rows else None,
        "rows":      [_breakdown_row(r) for r in rows],
    }


_CLIENT_METRIC_KEYS = ("revenue", "units", "operations", "last_sale_date")


async def get_top_clients(
    repo: StatisticsRepository,
    account_id: str,
    *,
    start: datetime.date,
    end: datetime.date,
    branch_id: str | None,
    limit: int,
) -> dict:
    """Top clientes del período. Las filas row_kind='client' son los items;
    la fila row_kind='unassigned' (siempre presente, OQ-2) es el importe de
    las ventas sin cliente, declarado aparte — jamás un item del ranking."""
    _validate_range(start, end)

    try:
        rows = await repo.fetch_top_clients(
            account_id, start=start, end=end, branch_id=branch_id, limit=limit,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc

    unassigned = next((r for r in rows if r["row_kind"] == "unassigned"), None)
    if unassigned is None:
        raise HTTPException(
            status_code=500,
            detail="El read-model de top clientes no devolvió la fila de ventas sin cliente",
        )

    return {
        "window": window_from_row(unassigned),
        "items": [
            {
                "rank":        r["rank"],
                "client_id":   r["client_id"],
                "client_name": r["client_name"],
                **{k: r[k] for k in _CLIENT_METRIC_KEYS},
            }
            for r in rows if r["row_kind"] == "client"
        ],
        "unassigned":    {k: unassigned[k] for k in _CLIENT_METRIC_KEYS},
        "total_clients": int(unassigned["total_clients"]),
    }


# ── E3 — detalle por producto ────────────────────────────────────────────────

_PRODUCT_METRIC_KEYS = (
    "units", "revenue", "operations", "total_cost", "gross_margin",
    "gross_margin_pct", "cost_coverage_pct", "last_sale_date",
)


def _product_metrics(row: dict) -> dict:
    # Un margen / costo / cobertura NULL se preserva como None — nunca 0 (D11).
    return {k: row[k] for k in _PRODUCT_METRIC_KEYS}


async def get_product_sales_evolution(
    repo: StatisticsRepository,
    account_id: str,
    *,
    product_id: str,
    start: datetime.date,
    end: datetime.date,
    bucket: str,
    branch_id: str | None,
    canal: str | None,
) -> dict:
    """Detalle de un producto y su grupo de variantes: cabecera + totales
    (fila row_kind='total'), puntos por intervalo (row_kind='bucket', en cero
    los vacíos) y miembros del grupo con ventas (row_kind='member'). Nada se
    re-agrega acá; la tenencia la resuelve la RPC (P0404 → 404)."""
    _validate_range(start, end)
    rpc_bucket = _EVOLUTION_BUCKET.get(bucket)
    if rpc_bucket is None:
        raise HTTPException(status_code=422, detail=f"Granularidad no admitida: {bucket}")

    try:
        rows = await repo.fetch_product_sales_evolution(
            account_id, product_id, start=start, end=end, bucket=rpc_bucket,
            branch_id=branch_id, canal=canal,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc

    total = next((r for r in rows if r["row_kind"] == "total"), None)
    if total is None:
        raise HTTPException(
            status_code=500,
            detail="El read-model de detalle por producto no devolvió la fila de totales",
        )

    return {
        "product": {
            "product_id":    total["product_id"],
            "product_name":  total["product_name"],
            "sku":           total["product_sku"],
            "category":      total["product_category"],
            "parent_id":     total["parent_id"],
            "parent_name":   total["parent_name"],
            "is_group":      bool(total["is_group"]),
            "variant_count": int(total["variant_count"]),
        },
        "bucket": bucket,
        "window": window_from_row(total),
        "totals": _product_metrics(total),
        "points": [
            {"bucket_start": r["bucket_start"], "bucket_end": r["bucket_end"], **_product_metrics(r)}
            for r in rows if r["row_kind"] == "bucket"
        ],
        "members": [
            {
                "rank":         r["rank"],
                "product_id":   r["variant_id"],
                "product_name": r["variant_name"],
                "sku":          r["variant_sku"],
                **_product_metrics(r),
            }
            for r in rows if r["row_kind"] == "member"
        ],
    }
