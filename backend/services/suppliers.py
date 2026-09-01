from __future__ import annotations

from fastapi import HTTPException

from backend.core.errors import ProblemHTTPException
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
    """review B (BE-1/SPEC-03): contrato tri-estado real, mismo criterio que
    payment_method_id/branch_id/supplier_id en la edición de operaciones
    (D7). `payload.model_fields_set` -- NUNCA `is None` -- distingue
    "campo ausente" (preservar) de "campo presente con null" (desimputar).
    `model_dump(exclude_none=True)` descartaba el segundo caso en silencio:
    ese era el bug (BE-1)."""
    require_role(auth, ["user", "admin"])
    patch = {field: getattr(payload, field) for field in payload.model_fields_set}
    record = await repo.update(supplier_id, account_id, patch)
    if record is None:
        raise HTTPException(status_code=404, detail="Proveedor no encontrado")
    return dict(record)


def _format_ars(amount) -> str:
    """Formato AR: miles con punto, decimales con coma (mismo criterio que el
    frontend). Solo para el detail humano del 409 — el dato duro es el code."""
    entero, _, dec = f"{amount:,.2f}".partition(".")
    return entero.replace(",", ".") + "," + dec


async def delete_supplier(repo: SupplierRepository, auth: dict, account_id: str, supplier_id: str) -> None:
    """v3-soft-delete-policy: borrado soft (RN-B1/RN-B2) — la fila persiste
    con deleted_at + deleted_by y sale de todas las lecturas por defecto.
    Mismo patrón que delete_client.

    qa-integral-modulos (G9/D7, OQ-1 recomendada): con saldo abierto en la
    cuenta corriente el borrado se BLOQUEA con 409 (`P0409`, ya mapeado — sin
    ERRCODE nuevo): el soft delete sacaría al proveedor de todas las listas y
    su cuenta corriente (solo alcanzable desde la fila del proveedor) quedaría
    inalcanzable — deuda invisible (los $116.550 del QA). Saldo 0 o sin cuenta
    siguen borrando; el flujo de pago/ajuste existente permite saldar primero."""
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(supplier_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Proveedor no encontrado")
    balance = await repo.get_account_balance(supplier_id, account_id)
    if balance is not None and balance != 0:
        raise ProblemHTTPException(
            status_code=409,
            detail=(
                "El proveedor tiene saldo abierto en su cuenta corriente "
                f"($ {_format_ars(balance)}). Registrá el pago o ajustá la "
                "cuenta antes de borrarlo."
            ),
            code="P0409",
        )
    await repo.soft_delete("suppliers", supplier_id, account_id, auth["user_id"])
