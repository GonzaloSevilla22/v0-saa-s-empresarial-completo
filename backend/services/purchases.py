from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.purchase_repository import PurchaseRepository
from backend.schemas.purchases import PurchaseOperationIn


async def list_purchases(repo: PurchaseRepository, auth: dict) -> list:
    return await repo.list_by_org(auth["user_id"])


async def create_purchase_operation(
    repo: PurchaseRepository, auth: dict, payload: PurchaseOperationIn
) -> dict:
    require_role(auth, ["owner", "admin"])
    items = [item.model_dump() for item in payload.items]
    record = await repo.create_operation(
        auth["user_id"],
        payload.org_id,
        items,
        payload.idempotency_key,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la operación de compra")
    return dict(record)
