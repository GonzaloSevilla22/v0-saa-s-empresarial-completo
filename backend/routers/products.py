from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.plan_limits_repository import PlanLimitsRepository
from backend.repositories.product_category_repository import ProductCategoryRepository
from backend.repositories.product_repository import ProductRepository
from backend.schemas.products import (
    ProductBulkCategoryIn,
    ProductBulkCategoryOut,
    ProductCreate,
    ProductOut,
    ProductUpdate,
)
from backend.services import products as product_service

router = APIRouter(prefix="/products", tags=["products"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ProductRepository:
    return ProductRepository(conn)


def get_plan_limits_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PlanLimitsRepository:
    return PlanLimitsRepository(conn)


def get_category_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ProductCategoryRepository:
    return ProductCategoryRepository(conn)


@router.get("", response_model=list[ProductOut])
async def list_products(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductRepository = Depends(get_repo),
):
    return await product_service.list_products(repo, str(account_id))


# productos-categorias-sku (D14): declarado ANTES de las rutas /{product_id}
# para que "bulk-category" nunca se lea como un id.
@router.patch("/bulk-category", response_model=ProductBulkCategoryOut)
async def bulk_set_category(
    payload: ProductBulkCategoryIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductRepository = Depends(get_repo),
    category_repo: ProductCategoryRepository = Depends(get_category_repo),
):
    """Recategorización en lote: UN solo UPDATE filtrado por cuenta; el padre
    propaga a sus variantes; tope de 500 ids por request (el cliente trocea)."""
    return await product_service.bulk_set_category(
        repo, auth, str(account_id),
        [str(pid) for pid in payload.product_ids],
        str(payload.category_id),
        category_repo,
    )


@router.get("/{product_id}", response_model=ProductOut)
async def get_product(
    product_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductRepository = Depends(get_repo),
):
    return await product_service.get_product(repo, str(account_id), product_id)


@router.post("", response_model=ProductOut, status_code=201)
async def create_product(
    payload: ProductCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductRepository = Depends(get_repo),
    plan_limits_repo: PlanLimitsRepository = Depends(get_plan_limits_repo),
    category_repo: ProductCategoryRepository = Depends(get_category_repo),
):
    return await product_service.create_product(
        repo, auth, str(account_id), payload, plan_limits_repo, category_repo
    )


@router.put("/{product_id}", response_model=ProductOut)
async def update_product(
    product_id: str,
    payload: ProductUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductRepository = Depends(get_repo),
    category_repo: ProductCategoryRepository = Depends(get_category_repo),
):
    """productos-categorias-sku (D12): `sku` y `category_id` son tri-estado por
    AUSENCIA de la clave en el JSON — `model_fields_set`, nunca `is None`
    (precedente exacto: `bank_account_id` en PATCH /payment-methods)."""
    return await product_service.update_product(
        repo, auth, str(account_id), product_id, payload,
        sku_provided="sku" in payload.model_fields_set,
        category_provided="category_id" in payload.model_fields_set,
        category_repo=category_repo,
    )


@router.delete("/{product_id}", status_code=204)
async def delete_product(
    product_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductRepository = Depends(get_repo),
):
    await product_service.delete_product(repo, auth, str(account_id), product_id)
