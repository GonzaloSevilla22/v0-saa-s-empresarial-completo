"""
Service layer para C-30 — CustomerAccount / PaymentReceived.

Regla dura: guards de rol SOLO en el service, NUNCA en routers ni repositories.
Patrón: require_role(auth, ["user", "admin"]) antes de cualquier mutación.
Propagación de ERRCODEs → HTTPException vía backend/core/errors.py.
"""
from __future__ import annotations

import asyncpg
from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.customer_account_repository import CustomerAccountRepository
from backend.schemas.customer_accounts import (
    PaymentReceivedIn,
)

# Mapa de ERRCODEs propios de C-30 → HTTP status
# bank-payment-routing C2: P0412 (bank_account no encontrada/inactiva) → 400
# (mismo tratamiento que P0400: error de payload/referencia inválida del cliente).
_ERRCODE_STATUS = {
    "P0400": 400,
    "P0401": 403,
    "P0403": 403,
    "P0404": 404,
    "P0409": 409,
    "P0412": 400,
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
    repo: CustomerAccountRepository,
    auth: dict,
    client_id: str,
) -> dict:
    """Crea/retorna la CustomerAccount de un cliente. Guard is_account_writer."""
    require_role(auth, ["user", "admin"])
    try:
        return await repo.create_account(client_id)
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc


async def get_account(
    repo: CustomerAccountRepository,
    account_id: str,
    client_id: str,
) -> dict:
    """Devuelve saldo + historial de la cuenta corriente del cliente."""
    row = await repo.get_account(account_id, client_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Cuenta corriente no encontrada para este cliente")
    account = dict(row)
    movements = await repo.list_movements(str(account["id"]))
    account["movements"] = movements
    return account


async def list_movements(
    repo: CustomerAccountRepository,
    customer_account_id: str,
    limit: int = 50,
    offset: int = 0,
) -> list[dict]:
    """Historial paginado de movimientos de la cuenta corriente."""
    return await repo.list_movements(customer_account_id, limit=limit, offset=offset)


async def register_payment_received(
    repo: CustomerAccountRepository,
    auth: dict,
    payload: PaymentReceivedIn,
) -> dict:
    """Registra un cobro. Guard is_account_writer. Idempotente.

    bank-payment-routing C2: propaga payment_method/bank_account_id al repo.
    """
    require_role(auth, ["user", "admin"])
    try:
        return await repo.register_payment_received(
            idempotency_key=payload.idempotency_key,
            client_id=str(payload.client_id),
            amount=float(payload.amount),
            reference_sale_id=str(payload.reference_sale_id) if payload.reference_sale_id else None,
            payment_method=payload.payment_method,
            bank_account_id=str(payload.bank_account_id) if payload.bank_account_id else None,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc
