from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.product_repository import ProductRepository
from backend.schemas.products import ProductCreate, ProductUpdate

PLAN_PRODUCT_LIMITS = {
    "gratis": 100,
    "inicial": 500,
    "avanzado": 2000,
    "pro": 999999,
}


async def list_products(repo: ProductRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_product(repo: ProductRepository, account_id: str, product_id: str) -> dict:
    record = await repo.get_by_id(product_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return dict(record)


async def create_product(repo: ProductRepository, auth: dict, account_id: str, payload: ProductCreate) -> dict:
    require_role(auth, ["user", "admin"])
    plan = auth.get("plan", "pro")
    limit = PLAN_PRODUCT_LIMITS.get(plan, 100)
    current_count = await repo.count_by_org(account_id)
    if current_count >= limit:
        raise HTTPException(
            status_code=403,
            detail=f"Límite de productos alcanzado para el plan {plan} ({limit} máx.)",
        )
    record = await repo.create(auth["user_id"], account_id, payload.model_dump())
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el producto")
    return dict(record)


async def update_product(
    repo: ProductRepository, auth: dict, account_id: str, product_id: str, payload: ProductUpdate
) -> dict:
    require_role(auth, ["user", "admin"])
    record = await repo.update(product_id, account_id, payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return dict(record)


async def delete_product(repo: ProductRepository, auth: dict, account_id: str, product_id: str) -> None:
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(product_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    await repo.delete(product_id, account_id)
