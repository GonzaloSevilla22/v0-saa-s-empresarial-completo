from __future__ import annotations

import re

import asyncpg
from fastapi import HTTPException

from backend.core.guards import require_account_role
from backend.repositories.product_category_repository import ProductCategoryRepository

_WS = re.compile(r"\s+")


def normalize_category_name(name: str | None) -> str | None:
    """productos-categorias-sku (D6, task 5.8): ÚNICO helper de normalización
    del nombre de categoría del lado Python — espejo exacto de
    `public.product_category_normalize_name(text)` (trim + colapso de espacios
    internos; vacío → None). Lo usan el service del catálogo y el validador
    del importador comparte el criterio."""
    if name is None:
        return None
    collapsed = _WS.sub(" ", name.strip())
    return collapsed or None


def _duplicate_409(name: str) -> HTTPException:
    return HTTPException(
        status_code=409,
        detail=f'Ya existe una categoría llamada "{name}" en tu cuenta (la comparación no distingue mayúsculas).',
    )


async def list_product_categories(
    repo: ProductCategoryRepository,
    auth: dict,
    account_id: str,
    *,
    active_only: bool = True,
) -> list:
    """Lectura abierta a cualquier miembro de la cuenta (spec product-category,
    'Member puede leer pero no escribir'). La RLS member_select acota al scope."""
    return await repo.list_by_account(account_id, active_only=active_only)


async def create_product_category(
    repo: ProductCategoryRepository,
    auth: dict,
    account_id: str,
    *,
    name: str,
    sort_order: int | None,
    conn,
) -> dict:
    """Crear una categoría. Requiere rol de TENANT owner/admin (espejo de
    create_payment_method), con defensa en profundidad vía RLS writer_insert.
    El unique de la DB es la fuente de verdad del duplicado; acá sólo se
    traduce el 23505 a un 409 legible que nombra la categoría."""
    await require_account_role(conn, auth, ["owner", "admin"])
    normalised = normalize_category_name(name)
    if normalised is None:
        raise HTTPException(status_code=422, detail="El nombre de la categoría no puede estar vacío")
    try:
        record = await repo.create(account_id, name=normalised, sort_order=sort_order)
    except asyncpg.UniqueViolationError as exc:
        raise _duplicate_409(normalised) from exc
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la categoría")
    return dict(record)


async def update_product_category(
    repo: ProductCategoryRepository,
    auth: dict,
    account_id: str,
    category_id: str,
    *,
    name: str | None,
    sort_order: int | None,
    is_active: bool | None,
    conn,
) -> dict:
    """Renombrar / reordenar / reactivar. Requiere owner/admin. Una categoría
    inexistente, borrada o de OTRA cuenta devuelve el mismo 404 (el repo
    scopea por account_id) sin revelar en cuál de los tres casos cayó."""
    await require_account_role(conn, auth, ["owner", "admin"])
    normalised = name
    if name is not None:
        normalised = normalize_category_name(name)
        if normalised is None:
            raise HTTPException(status_code=422, detail="El nombre de la categoría no puede estar vacío")
    try:
        record = await repo.update(
            category_id, account_id, name=normalised, sort_order=sort_order, is_active=is_active
        )
    except asyncpg.UniqueViolationError as exc:
        raise _duplicate_409(normalised or "") from exc
    if record is None:
        raise HTTPException(status_code=404, detail="Categoría no encontrada")
    return dict(record)


async def deactivate_product_category(
    repo: ProductCategoryRepository,
    auth: dict,
    account_id: str,
    category_id: str,
    *,
    conn,
) -> dict:
    """Baja lógica reversible (D3): deja de ofrecerse en los selectores de
    altas nuevas; los productos ya imputados conservan su category_id y su
    nombre sigue siendo legible. Requiere owner/admin."""
    await require_account_role(conn, auth, ["owner", "admin"])
    record = await repo.deactivate(category_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Categoría no encontrada")
    return dict(record)


async def delete_product_category(
    repo: ProductCategoryRepository,
    auth: dict,
    account_id: str,
    category_id: str,
    *,
    conn,
) -> None:
    """Soft delete como maestro (soft-delete-policy RN-B1/RN-B2): deleted_at +
    deleted_by vía el helper centralizado. Nunca DELETE físico — la FK
    ON DELETE RESTRICT de products.category_id lo impediría igual."""
    await require_account_role(conn, auth, ["owner", "admin"])
    deleted = await repo.soft_delete("product_categories", category_id, account_id, auth["user_id"])
    if not deleted:
        raise HTTPException(status_code=404, detail="Categoría no encontrada")
