from __future__ import annotations

import asyncpg
from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.plan_limits_repository import PlanLimitsRepository
from backend.repositories.product_category_repository import ProductCategoryRepository
from backend.repositories.product_repository import ProductRepository
from backend.schemas.products import ProductCreate, ProductUpdate

# v3-soft-delete-policy (D3): ERRCODE del guard RN-B4
# (fn_guard_product_soft_delete, migración 20260811000001).
_RN_B4_SQLSTATE = "P0B04"

# billing-pro-trial (D5): PLAN_PRODUCT_LIMITS retirado — el diccionario decía
# avanzado=2000 mientras plan_limits en la DB decía 1500 (divergencia real,
# invisible mientras el gating fue fail-open). El límite se lee ahora de
# plan_limits en runtime (spec plan-gating), alineado a 2000 en la misma
# migración que este change trae (20260817000001).

# productos-categorias-sku (D4/D5): nombres de los índices únicos vivos de
# products cuyo 23505 merece un mensaje legible. La restricción de la base es
# la fuente de verdad; acá sólo se traduce.
_SKU_UNIQUE_INDEX = "idx_products_sku_account_lower"
_BARCODE_UNIQUE_INDEX = "idx_products_barcode_unique"


def normalize_sku(sku: str | None) -> str | None:
    """productos-categorias-sku (spec product-sku): trim; vacío → None. Un SKU
    en blanco jamás se persiste como cadena vacía."""
    if sku is None:
        return None
    trimmed = sku.strip()
    return trimmed or None


def _translate_unique_violation(exc: asyncpg.UniqueViolationError, sku: str | None) -> HTTPException | None:
    constraint = getattr(exc, "constraint_name", None)
    if constraint == _SKU_UNIQUE_INDEX:
        return HTTPException(
            status_code=409,
            detail=f'El SKU "{sku}" ya pertenece a otro producto de tu cuenta (la comparación no distingue mayúsculas). Cambialo o dejalo vacío.',
        )
    if constraint == _BARCODE_UNIQUE_INDEX:
        return HTTPException(status_code=409, detail="Ya existe un producto con ese código de barras.")
    return None


async def _resolve_category_for_account(
    category_repo: ProductCategoryRepository, category_id: str, account_id: str
) -> asyncpg.Record:
    """Spec product-category: una categoría de OTRA cuenta (o borrada) se
    rechaza sin revelar si existe en otro lado — mismo 404 en los tres casos.
    Se acepta una desactivada: un producto puede seguir imputado a ella
    (edición que no cambia la categoría); la UI sólo ofrece activas."""
    category = await category_repo.get_by_id(category_id, account_id)
    if category is None:
        raise HTTPException(status_code=404, detail="Categoría no encontrada")
    return category


async def list_products(repo: ProductRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_product(repo: ProductRepository, account_id: str, product_id: str) -> dict:
    record = await repo.get_by_id(product_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return dict(record)


async def create_product(
    repo: ProductRepository,
    auth: dict,
    account_id: str,
    payload: ProductCreate,
    plan_limits_repo: PlanLimitsRepository,
    category_repo: ProductCategoryRepository | None = None,
) -> dict:
    require_role(auth, ["user", "admin"])
    plan = auth.get("plan", "pro")
    limits = await plan_limits_repo.get_limits(plan)
    limit = limits["max_products"]
    current_count = await repo.count_by_org(account_id)
    if current_count >= limit:
        raise HTTPException(
            status_code=403,
            detail=f"Límite de productos alcanzado para el plan {plan} ({limit} máx.). Borrá productos existentes o subí de plan.",
        )

    data = payload.model_dump()
    data["sku"] = normalize_sku(payload.sku)

    parent_id = data.get("parent_id")
    if parent_id:
        # D11/9.7: la variante hereda la categoría del PADRE resuelta en el
        # servidor — lo que mande el cliente se ignora.
        parent = await repo.get_by_id(parent_id, account_id)
        if parent is None:
            raise HTTPException(status_code=404, detail="Producto padre no encontrado")
        parent_category_id = parent["category_id"] if "category_id" in parent.keys() else None
        data["category_id"] = str(parent_category_id) if parent_category_id else None
        data["category"] = parent["category"]
    elif payload.category_id is not None:
        if category_repo is None:
            raise HTTPException(status_code=500, detail="Catálogo de categorías no disponible")
        category = await _resolve_category_for_account(category_repo, str(payload.category_id), account_id)
        data["category_id"] = str(payload.category_id)
        data["category"] = category["name"]
    else:
        data["category_id"] = None

    try:
        record = await repo.create(auth["user_id"], account_id, data)
    except asyncpg.UniqueViolationError as exc:
        translated = _translate_unique_violation(exc, data["sku"])
        if translated is not None:
            raise translated from exc
        raise
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el producto")
    return dict(record)


async def update_product(
    repo: ProductRepository,
    auth: dict,
    account_id: str,
    product_id: str,
    payload: ProductUpdate,
    *,
    sku_provided: bool = False,
    category_provided: bool = False,
    category_repo: ProductCategoryRepository | None = None,
) -> dict:
    """productos-categorias-sku (D12): tri-estado por AUSENCIA para `sku` y
    `category_id` (`*_provided` derivado de `model_fields_set` en el router).
    El resto de los campos conserva `exclude_none` (task 9.4)."""
    require_role(auth, ["user", "admin"])
    data = payload.model_dump(exclude_none=True, exclude={"sku", "category_id"})

    if sku_provided:
        data["sku"] = normalize_sku(payload.sku)

    if category_provided:
        existing = await repo.get_by_id(product_id, account_id)
        if existing is None:
            raise HTTPException(status_code=404, detail="Producto no encontrado")
        # D11/9.7: una variante hereda del padre — el cliente no puede
        # contradecirlo; se ignora sin validar ni escribir.
        if existing["parent_id"] is None:
            if payload.category_id is None:
                data["category_id"] = None
            else:
                if category_repo is None:
                    raise HTTPException(status_code=500, detail="Catálogo de categorías no disponible")
                await _resolve_category_for_account(category_repo, str(payload.category_id), account_id)
                data["category_id"] = str(payload.category_id)

    try:
        record = await repo.update(product_id, account_id, data)
    except asyncpg.UniqueViolationError as exc:
        translated = _translate_unique_violation(exc, data.get("sku"))
        if translated is not None:
            raise translated from exc
        raise
    if record is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return dict(record)


async def bulk_set_category(
    repo: ProductRepository,
    auth: dict,
    account_id: str,
    product_ids: list[str],
    category_id: str,
    category_repo: ProductCategoryRepository,
) -> dict:
    """productos-categorias-sku (D14): recategorización en lote.

    La categoría destino se valida contra la cuenta y contra su estado vivo Y
    activo ANTES del UPDATE — inexistente, ajena, borrada o inactiva → 404 con
    un mensaje que no revela si existe en otra cuenta (criterio P0404 de
    cuenta-corriente-party-guard). Los ids de producto ajenos no producen
    error: quedan fuera del WHERE del repositorio.
    """
    require_role(auth, ["user", "admin"])
    unique_ids = list(dict.fromkeys(product_ids))
    target = await category_repo.get_active_by_id(category_id, account_id)
    if target is None:
        raise HTTPException(status_code=404, detail="Categoría no encontrada o inactiva")
    updated = await repo.bulk_set_category(unique_ids, account_id, category_id)
    return {"requested": len(unique_ids), "updated": updated}


async def delete_product(repo: ProductRepository, auth: dict, account_id: str, product_id: str) -> None:
    """v3-soft-delete-policy: borrado soft (RN-B1/RN-B2). El guard RN-B4 de la
    DB (stock <> 0 o referenciado en documentos draft) se traduce a 409 con
    mensaje de UX en español (D3)."""
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(product_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    try:
        await repo.soft_delete("products", product_id, account_id, auth["user_id"])
    except asyncpg.PostgresError as exc:
        if getattr(exc, "sqlstate", None) == _RN_B4_SQLSTATE:
            detail = getattr(exc, "message", None) or str(exc) or (
                "El producto tiene stock o está incluido en documentos en "
                "borrador; no puede borrarse"
            )
            raise HTTPException(status_code=409, detail=detail) from exc
        raise
