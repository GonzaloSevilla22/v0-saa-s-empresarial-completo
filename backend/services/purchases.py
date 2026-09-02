from __future__ import annotations

import datetime

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.purchase_repository import PurchaseRepository
from backend.schemas.purchases import PurchaseOperationIn, PurchaseOperationUpdateIn


async def list_purchases_paginated(
    repo: PurchaseRepository,
    account_id: str,
    page: int,
    page_size: int,
    date_from: str | None,
    date_to: str | None,
    cost_center_id: str | None = None,
    payment_method_id: str | None = None,
) -> dict:
    df = datetime.date.fromisoformat(date_from) if date_from else None
    dt = datetime.date.fromisoformat(date_to) if date_to else None
    rows, total = await repo.list_paginated_by_operation(
        account_id, page, page_size, df, dt, cost_center_id, payment_method_id,
    )
    # v3-api-standards §2: envelope estándar {items,total,page,pages}
    pages = -(-total // page_size) if total > 0 else 0
    return {"items": [dict(r) for r in rows], "total": total, "page": page, "pages": pages}


async def delete_purchase(
    repo: PurchaseRepository, auth: dict, account_id: str, purchase_id: str
) -> None:
    require_role(auth, ["user", "admin"])
    found = await repo.delete_by_id(purchase_id, account_id)
    if not found:
        raise HTTPException(status_code=404, detail="Compra no encontrada")


async def delete_purchase_operation(
    repo: PurchaseRepository, auth: dict, account_id: str, operation_id: str
) -> None:
    require_role(auth, ["user", "admin"])
    found = await repo.delete_by_operation(operation_id, account_id)
    if not found:
        raise HTTPException(status_code=404, detail="Operación no encontrada")


async def update_purchase_operation(
    repo: PurchaseRepository,
    auth: dict,
    payload: PurchaseOperationUpdateIn,
    payment_method_provided: bool = False,
    branch_provided: bool = False,
    supplier_provided: bool = False,
    cost_center_provided: bool = False,
) -> None:
    require_role(auth, ["user", "admin"])
    items = [item.model_dump() for item in payload.items]
    payment_method_id = (
        str(payload.payment_method_id) if payload.payment_method_id is not None else None
    )
    branch_id = str(payload.branch_id) if payload.branch_id is not None else None
    # compras-proveedor-cuenta-corriente (D7, task 9.4, OQ-5 opción A):
    # passthrough tri-estado, mismo patrón que payment_method_id/branch_id.
    supplier_id = str(payload.supplier_id) if payload.supplier_id is not None else None
    cost_center_id = (
        str(payload.cost_center_id) if payload.cost_center_id is not None else None
    )
    await repo.update_operation(
        payload.purchase_ids,
        payload.date,
        payload.description,
        items,
        payment_method_id=payment_method_id,
        payment_method_provided=payment_method_provided,
        branch_id=branch_id,
        branch_provided=branch_provided,
        supplier_id=supplier_id,
        supplier_provided=supplier_provided,
        cost_center_id=cost_center_id,
        cost_center_provided=cost_center_provided,
    )


async def create_purchase_operation(
    repo: PurchaseRepository, auth: dict, account_id: str, payload: PurchaseOperationIn
) -> dict:
    require_role(auth, ["user", "admin"])
    # Extract operation-level description from first item (frontend sends it per-item)
    description = payload.items[0].description if payload.items else None
    items = [item.model_dump() for item in payload.items]
    # cost-center-dimension: pass optional cost_center_id to RPC (propagated to all rows)
    cost_center_id = str(payload.cost_center_id) if payload.cost_center_id is not None else None
    # metodos-pago-operaciones: pass optional payment_method_id to RPC (propagated to all rows)
    payment_method_id = (
        str(payload.payment_method_id) if payload.payment_method_id is not None else None
    )
    # pos-banco-movimientos (D2): passthrough del override — la RPC resuelve
    # y valida (P0412/P0400/P0424).
    bank_account_id = (
        str(payload.bank_account_id) if payload.bank_account_id is not None else None
    )
    # compras-proveedor-cuenta-corriente (D4): passthrough del proveedor —
    # la RPC resuelve pertenencia (P0404) y exige proveedor si kind='credit'
    # (P0400 credit_requires_supplier).
    supplier_id = str(payload.supplier_id) if payload.supplier_id is not None else None
    # caja-compras-cobranzas (D3): passthrough de branch_id — antes se
    # descartaba acá (el 5.º argumento de la RPC llegaba NULL literal).
    branch_id = str(payload.branch_id) if payload.branch_id is not None else None
    # caja-compras-cobranzas (D2): passthrough del opt-in de caja — la RPC
    # resuelve y valida las tres condiciones (P0422).
    cash_session_id = (
        str(payload.cash_session_id) if payload.cash_session_id is not None else None
    )
    record = await repo.create_operation(
        auth["user_id"],
        account_id,
        items,
        payload.idempotency_key,
        date=payload.date,
        description=description,
        branch_id=branch_id,
        cost_center_id=cost_center_id,
        payment_method_id=payment_method_id,
        bank_account_id=bank_account_id,
        supplier_id=supplier_id,
        cash_session_id=cash_session_id,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la operación de compra")
    return dict(record)
