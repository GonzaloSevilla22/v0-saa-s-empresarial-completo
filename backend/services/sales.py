from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.sales_repository import SalesRepository
from backend.schemas.sales import SaleOperationIn


async def list_sales(repo: SalesRepository, auth: dict) -> list:
    return await repo.list_by_org(auth["user_id"])


async def create_sale_operation(
    repo: SalesRepository, auth: dict, payload: SaleOperationIn
) -> dict:
    require_role(auth, ["user", "admin"])
    items = [item.model_dump() for item in payload.items]
    record = await repo.create_operation(
        auth["user_id"],
        payload.org_id,
        items,
        payload.idempotency_key,
        date=payload.date,
        client_id=payload.client_id,
        currency=payload.currency,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la operación de venta")
    return dict(record)
