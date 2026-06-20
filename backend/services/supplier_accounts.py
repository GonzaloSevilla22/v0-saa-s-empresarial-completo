"""
Service layer para C-30 — SupplierAccount / PaymentMade / SupplierCharge.

Regla dura: guards de rol SOLO en el service.
"""
from __future__ import annotations

import asyncpg
from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.supplier_account_repository import SupplierAccountRepository
from backend.schemas.supplier_accounts import (
    PaymentMadeIn,
    SupplierChargeIn,
)

_ERRCODE_STATUS = {
    "P0400": 400,
    "P0401": 403,
    "P0403": 403,
    "P0404": 404,
    "P0409": 409,
    "P0422": 422,
}


def _pg_to_http(exc: asyncpg.PostgresError) -> HTTPException:
    code = exc.sqlstate if hasattr(exc, "sqlstate") else None
    status = _ERRCODE_STATUS.get(code, 500)
    try:
        detail = str(exc)
    except (IndexError, Exception):
        detail = f"Error de base de datos (ERRCODE: {code})"
    return HTTPException(status_code=status, detail=detail)


async def create_account(
    repo: SupplierAccountRepository,
    auth: dict,
    supplier_id: str,
) -> dict:
    """Crea/retorna la SupplierAccount de un proveedor."""
    require_role(auth, ["user", "admin"])
    try:
        return await repo.create_account(supplier_id)
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc


async def get_account(
    repo: SupplierAccountRepository,
    account_id: str,
    supplier_id: str,
) -> dict:
    """Devuelve saldo + historial de la cuenta corriente del proveedor."""
    row = await repo.get_account(account_id, supplier_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Cuenta corriente no encontrada para este proveedor")
    account = dict(row)
    movements = await repo.list_movements(str(account["id"]))
    account["movements"] = movements
    return account


async def register_payment_made(
    repo: SupplierAccountRepository,
    auth: dict,
    payload: PaymentMadeIn,
) -> dict:
    """Registra un pago al proveedor. Guard is_account_writer. Idempotente."""
    require_role(auth, ["user", "admin"])
    try:
        return await repo.register_payment_made(
            idempotency_key=payload.idempotency_key,
            supplier_id=str(payload.supplier_id),
            amount=float(payload.amount),
            reference_purchase_id=str(payload.reference_purchase_id) if payload.reference_purchase_id else None,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc


async def register_supplier_charge(
    repo: SupplierAccountRepository,
    auth: dict,
    payload: SupplierChargeIn,
) -> dict:
    """Registra un cargo manual en la cta cte del proveedor. Guard is_account_writer."""
    require_role(auth, ["user", "admin"])
    try:
        return await repo.register_supplier_charge(
            idempotency_key=payload.idempotency_key,
            supplier_id=str(payload.supplier_id),
            amount=float(payload.amount),
            reference_id=str(payload.reference_id) if payload.reference_id else None,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc
