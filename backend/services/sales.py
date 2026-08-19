from __future__ import annotations

import datetime

import asyncpg
from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.sales_repository import SalesRepository
from backend.schemas.sales import SaleOperationIn, SaleOperationUpdateIn


async def list_sales_paginated(
    repo: SalesRepository,
    account_id: str,
    page: int,
    page_size: int,
    date_from: str | None,
    date_to: str | None,
    payment_method_id: str | None = None,
) -> dict:
    df = datetime.date.fromisoformat(date_from) if date_from else None
    dt = datetime.date.fromisoformat(date_to) if date_to else None
    rows, total = await repo.list_paginated_by_operation(
        account_id, page, page_size, df, dt, payment_method_id,
    )
    # v3-api-standards §2: envelope estándar {items,total,page,pages}
    pages = -(-total // page_size) if total > 0 else 0
    return {"items": [dict(r) for r in rows], "total": total, "page": page, "pages": pages}


async def delete_sale(
    repo: SalesRepository, auth: dict, account_id: str, sale_id: str
) -> None:
    require_role(auth, ["user", "admin"])
    found = await repo.delete_by_id(sale_id, account_id)
    if not found:
        raise HTTPException(status_code=404, detail="Venta no encontrada")


async def delete_sale_operation(
    repo: SalesRepository, auth: dict, account_id: str, operation_id: str
) -> None:
    require_role(auth, ["user", "admin"])
    found = await repo.delete_by_operation(operation_id, account_id)
    if not found:
        raise HTTPException(status_code=404, detail="Operación no encontrada")


async def update_sale_operation(
    repo: SalesRepository,
    auth: dict,
    payload: SaleOperationUpdateIn,
    payment_method_provided: bool = False,
) -> None:
    require_role(auth, ["user", "admin"])
    items = [item.model_dump() for item in payload.items]
    payment_method_id = (
        str(payload.payment_method_id) if payload.payment_method_id is not None else None
    )
    await repo.update_operation(
        payload.sale_ids,
        payload.client_id,
        payload.date,
        payload.currency,
        items,
        payment_method_id=payment_method_id,
        payment_method_provided=payment_method_provided,
    )


async def promote_to_order(
    repo: SalesRepository,
    auth: dict,
    operation_id: str,
) -> dict:
    """
    facturar-venta-manual (D6):
    Promueve una venta legacy a SalesOrder confirmada para habilitar emit-invoice.

    Guard: escritor (user/admin).
    Mapeo Postgres→HTTP (espejo de sales_orders._map_postgres_error):
      P0401 → 403, P0400 → 400, P0404 → 404, P0409/P0422 → 409.
    """
    require_role(auth, ["user", "admin"])

    try:
        result = await repo.promote_to_order(operation_id)
    except asyncpg.PostgresError as exc:
        _map_postgres_error(exc)

    return result


def _map_postgres_error(exc: asyncpg.PostgresError) -> None:
    """Mapea errores PostgreSQL → HTTPException (misma convención que sales_orders service)."""
    sqlstate = getattr(exc, "sqlstate", None)
    message  = str(exc)

    if sqlstate == "P0401":
        raise HTTPException(status_code=403, detail=f"Sin permiso: {message}")
    if sqlstate == "P0400":
        raise HTTPException(status_code=400, detail=f"Payload inválido: {message}")
    if sqlstate == "P0404":
        raise HTTPException(status_code=404, detail=f"No encontrado: {message}")
    if sqlstate in ("P0409", "P0422"):
        raise HTTPException(status_code=409, detail=f"Conflicto: {message}")

    raise HTTPException(status_code=500, detail=f"Error de base de datos: {message}")


async def create_sale_operation(
    repo: SalesRepository, auth: dict, account_id: str, payload: SaleOperationIn
) -> dict:
    require_role(auth, ["user", "admin"])
    items = [item.model_dump() for item in payload.items]
    payment_method_id = (
        str(payload.payment_method_id) if payload.payment_method_id is not None else None
    )
    record = await repo.create_operation(
        auth["user_id"],
        account_id,
        items,
        payload.idempotency_key,
        date=payload.date,
        client_id=payload.client_id,
        currency=payload.currency,
        canal=payload.canal,
        payment_method_id=payment_method_id,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la operación de venta")
    return dict(record)
