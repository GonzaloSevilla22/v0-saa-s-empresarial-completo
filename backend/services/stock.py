from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.stock_repository import StockRepository
from backend.schemas.stock import StockTransferRequest


async def get_stock(repo: StockRepository, auth: dict, product_id: str) -> dict:
    record = await repo.get_stock_by_product(product_id, auth["user_id"])
    if record is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return {"product_id": product_id, "stock": record["stock"]}


async def list_movements(repo: StockRepository, auth: dict, product_id: str) -> list:
    return await repo.list_movements(product_id, auth["user_id"])


async def transfer_stock(
    repo: StockRepository, auth: dict, payload: StockTransferRequest
) -> dict:
    require_role(auth, ["owner", "admin"])
    result = await repo.transfer(
        str(payload.from_branch_id),
        str(payload.to_branch_id),
        str(payload.product_id),
        float(payload.quantity),
    )
    if result is None:
        raise HTTPException(status_code=422, detail="Transferencia fallida: stock insuficiente o parámetros inválidos")
    return dict(result)
