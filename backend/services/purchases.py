from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.purchase_repository import PurchaseRepository
from backend.schemas.purchases import PurchaseOperationIn


async def list_purchases(repo: PurchaseRepository, auth: dict) -> list:
    return await repo.list_by_org(auth["user_id"])


async def delete_purchase(
    repo: PurchaseRepository, auth: dict, purchase_id: str
) -> None:
    require_role(auth, ["user", "admin"])
    found = await repo.delete_by_id(purchase_id, auth["user_id"])
    if not found:
        raise HTTPException(status_code=404, detail="Compra no encontrada")


async def delete_purchase_operation(
    repo: PurchaseRepository, auth: dict, operation_id: str
) -> None:
    require_role(auth, ["user", "admin"])
    found = await repo.delete_by_operation(operation_id, auth["user_id"])
    if not found:
        raise HTTPException(status_code=404, detail="Operación no encontrada")


async def create_purchase_operation(
    repo: PurchaseRepository, auth: dict, payload: PurchaseOperationIn
) -> dict:
    require_role(auth, ["user", "admin"])
    # Extract operation-level description from first item (frontend sends it per-item)
    description = payload.items[0].description if payload.items else None
    items = [item.model_dump() for item in payload.items]
    record = await repo.create_operation(
        auth["user_id"],
        payload.org_id,
        items,
        payload.idempotency_key,
        date=payload.date,
        description=description,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la operación de compra")
    return dict(record)
