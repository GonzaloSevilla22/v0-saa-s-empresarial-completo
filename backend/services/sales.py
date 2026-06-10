from __future__ import annotations

import datetime

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.sales_repository import SalesRepository
from backend.schemas.sales import SaleOperationIn


async def list_sales_paginated(
    repo: SalesRepository,
    account_id: str,
    page: int,
    page_size: int,
    date_from: str | None,
    date_to: str | None,
) -> dict:
    df = datetime.date.fromisoformat(date_from) if date_from else None
    dt = datetime.date.fromisoformat(date_to) if date_to else None
    rows, total = await repo.list_paginated_by_operation(
        account_id, page, page_size, df, dt,
    )
    return {"items": [dict(r) for r in rows], "total_operations": total}


async def create_sale_operation(
    repo: SalesRepository, auth: dict, account_id: str, payload: SaleOperationIn
) -> dict:
    require_role(auth, ["user", "admin"])
    items = [item.model_dump() for item in payload.items]
    record = await repo.create_operation(
        auth["user_id"],
        account_id,
        items,
        payload.idempotency_key,
        date=payload.date,
        client_id=payload.client_id,
        currency=payload.currency,
        canal=payload.canal,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la operación de venta")
    return dict(record)
