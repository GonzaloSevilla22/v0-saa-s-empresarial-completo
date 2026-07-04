"""
Service para bank-account-crud — alta de cuentas bancarias.

Guard: require_role(["user","admin"]) como el hot path (bank_reconciliation,
sales/purchases) — el guard autoritativo por rol de cuenta es is_account_writer
dentro de la RPC rpc_create_bank_account (P0401). Defence-in-depth, no
duplicación de lógica de dominio: la RPC SECURITY DEFINER hace las validaciones
finales (name requerido → P0400, CBU inválido → P0411, sin cuenta activa → P0403).

Mapeo de ERRCODEs local (D3, mismo patrón que customer_accounts._pg_to_http):
P0400 se mapea a 422 acá (validación de payload) en vez del 400 genérico del
handler global de errors.py, que otras RPCs usan para "bad request" no-validación.
"""
from __future__ import annotations

import asyncpg
from fastapi import HTTPException

from backend.core.errors import BANK_ACCOUNT_CREATE_ERRCODE_STATUS
from backend.core.guards import require_role
from backend.repositories.bank_account_repository import BankAccountRepository
from backend.schemas.bank_accounts import BankAccountCreate


def _pg_to_http(exc: asyncpg.PostgresError) -> HTTPException:
    code = exc.sqlstate if hasattr(exc, "sqlstate") else None
    status = BANK_ACCOUNT_CREATE_ERRCODE_STATUS.get(code, 500)
    try:
        detail = str(exc)
    except Exception:
        detail = f"Error de base de datos (ERRCODE: {code})"
    return HTTPException(status_code=status, detail=detail)


async def create_bank_account(
    repo: BankAccountRepository,
    auth: dict,
    payload: BankAccountCreate,
) -> dict:
    """Create a bank account. Requires role user or admin."""
    require_role(auth, ["user", "admin"])
    try:
        return await repo.create(
            name=payload.name,
            bank_name=payload.bank_name,
            cbu=payload.cbu,
            alias=payload.alias,
            currency=payload.currency,
            opening_balance=payload.opening_balance,
            opening_date=payload.opening_date,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc
