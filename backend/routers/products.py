from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.product_repository import ProductRepository
from backend.schemas.products import ProductCreate, ProductOut, ProductUpdate
from backend.services import products as product_service

router = APIRouter(prefix="/products", tags=["products"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ProductRepository:
    return ProductRepository(conn)


@router.get("", response_model=list[ProductOut])
async def list_products(
    auth: dict = Depends(get_current_user),
    repo: ProductRepository = Depends(get_repo),
):
    return await product_service.list_products(repo, auth)


@router.get("/{product_id}", response_model=ProductOut)
async def get_product(
    product_id: str,
    auth: dict = Depends(get_current_user),
    repo: ProductRepository = Depends(get_repo),
):
    return await product_service.get_product(repo, auth, product_id)


@router.post("", response_model=ProductOut, status_code=201)
async def create_product(
    payload: ProductCreate,
    auth: dict = Depends(get_current_user),
    repo: ProductRepository = Depends(get_repo),
):
    return await product_service.create_product(repo, auth, payload)


@router.put("/{product_id}", response_model=ProductOut)
async def update_product(
    product_id: str,
    payload: ProductUpdate,
    auth: dict = Depends(get_current_user),
    repo: ProductRepository = Depends(get_repo),
):
    return await product_service.update_product(repo, auth, product_id, payload)


@router.delete("/{product_id}", status_code=204)
async def delete_product(
    product_id: str,
    auth: dict = Depends(get_current_user),
    repo: ProductRepository = Depends(get_repo),
):
    await product_service.delete_product(repo, auth, product_id)
