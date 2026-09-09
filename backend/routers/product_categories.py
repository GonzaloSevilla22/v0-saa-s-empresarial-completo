from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.product_category_repository import ProductCategoryRepository
from backend.schemas.product_categories import (
    ProductCategoryCreate,
    ProductCategoryDefaultIn,
    ProductCategoryDefaultOut,
    ProductCategoryOut,
    ProductCategoryUpdate,
)
from backend.services import product_categories as pc_service

router = APIRouter(prefix="/product-categories", tags=["product-categories"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ProductCategoryRepository:
    return ProductCategoryRepository(conn)


@router.get("", response_model=list[ProductCategoryOut])
async def list_product_categories(
    include_inactive: bool = Query(False, description="Incluir categorías desactivadas (pantalla de gestión)"),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductCategoryRepository = Depends(get_repo),
):
    """Catálogo de categorías de producto de la cuenta (cualquier miembro).

    Por defecto sólo las activas, ordenadas por sort_order; con
    include_inactive=true también las desactivadas — nunca las borradas.
    """
    return await pc_service.list_product_categories(
        repo, auth, str(account_id), active_only=not include_inactive
    )


@router.get("/default", response_model=ProductCategoryDefaultOut)
async def get_default_product_category(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductCategoryRepository = Depends(get_repo),
):
    """categoria-default-configurable: default de la cuenta para las filas
    sin categoría de la carga masiva. Lectura para cualquier miembro (RLS
    aplica en la conexión) — espejo de get_collection_settings."""
    return await pc_service.get_default_product_category(repo, str(account_id))


@router.patch("/default", response_model=ProductCategoryDefaultOut)
async def set_default_product_category(
    payload: ProductCategoryDefaultIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductCategoryRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Fija (o limpia, con null) el default vía rpc_set_default_product_category
    — guard is_account_writer (P0401 → 403); categoría inexistente/de otra
    cuenta/inactiva/soft-deleted (P0404 → 404). Requiere owner/admin."""
    return await pc_service.set_default_product_category(
        repo, auth, str(account_id), str(payload.default_category_id) if payload.default_category_id else None, conn=conn
    )


@router.post("", response_model=ProductCategoryOut, status_code=201)
async def create_product_category(
    payload: ProductCategoryCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductCategoryRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Crear una categoría. Requiere rol de TENANT owner o admin."""
    return await pc_service.create_product_category(
        repo, auth, str(account_id), name=payload.name, sort_order=payload.sort_order, conn=conn
    )


@router.patch("/{category_id}", response_model=ProductCategoryOut)
async def update_product_category(
    category_id: str,
    payload: ProductCategoryUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductCategoryRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Renombrar / reordenar / reactivar. Campo ausente conserva. Requiere owner/admin."""
    return await pc_service.update_product_category(
        repo, auth, str(account_id), category_id,
        name=payload.name, sort_order=payload.sort_order, is_active=payload.is_active, conn=conn,
    )


@router.patch("/{category_id}/deactivate", response_model=ProductCategoryOut)
async def deactivate_product_category(
    category_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductCategoryRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Baja lógica reversible (is_active=false). Los productos imputados la conservan."""
    return await pc_service.deactivate_product_category(repo, auth, str(account_id), category_id, conn=conn)


@router.delete("/{category_id}", status_code=204)
async def delete_product_category(
    category_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ProductCategoryRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Soft delete como maestro (deleted_at/deleted_by). Nunca borrado físico."""
    await pc_service.delete_product_category(repo, auth, str(account_id), category_id, conn=conn)
