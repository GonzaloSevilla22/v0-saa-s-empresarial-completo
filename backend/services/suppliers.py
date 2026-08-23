from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.supplier_repository import SupplierRepository
from backend.schemas.suppliers import SupplierCreate, SupplierUpdate


async def list_suppliers(repo: SupplierRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_supplier(repo: SupplierRepository, account_id: str, supplier_id: str) -> dict:
    record = await repo.get_by_id(supplier_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Proveedor no encontrado")
    return dict(record)


async def create_supplier(
    repo: SupplierRepository, auth: dict, account_id: str, payload: SupplierCreate
) -> dict:
    """D3 (compras-proveedor-cuenta-corriente): a diferencia de create_client,
    el service NO precuenta contra el límite de plan. La única fuente de
    verdad es trg_guard_supplier_plan_limit (ERRCODE P0B10), que ve TODOS los
    inserts de suppliers -- incluidos los que no pasan por este endpoint. El
    mapeo P0B10 -> 403 vive en backend/core/errors.py (task 8.2)."""
    require_role(auth, ["user", "admin"])
    record = await repo.create(account_id, payload.model_dump())
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el proveedor")
    return dict(record)


async def update_supplier(
    repo: SupplierRepository, auth: dict, account_id: str, supplier_id: str, payload: SupplierUpdate
) -> dict:
    require_role(auth, ["user", "admin"])
    record = await repo.update(supplier_id, account_id, payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Proveedor no encontrado")
    return dict(record)


async def delete_supplier(repo: SupplierRepository, auth: dict, account_id: str, supplier_id: str) -> None:
    """v3-soft-delete-policy: borrado soft (RN-B1/RN-B2) — la fila persiste
    con deleted_at + deleted_by y sale de todas las lecturas por defecto.
    Mismo patrón que delete_client."""
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(supplier_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Proveedor no encontrado")
    await repo.soft_delete("suppliers", supplier_id, account_id, auth["user_id"])
