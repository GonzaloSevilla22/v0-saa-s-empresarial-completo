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
    PaymentReversalIn,
)

# Mapa de ERRCODEs propios de C-30 → HTTP status
# bank-payment-routing C2: P0412 (bank_account no encontrada/inactiva) → 400
# (mismo tratamiento que P0400: error de payload/referencia inválida del cliente).
# cobranzas-reverso: P0426 (sin sesión de caja abierta para compensar) y
# P0451 (asiento original no encontrado todavía — retry async) — mismo 409
# que el resto de los conflictos de estado (P0409/P0423/P0425).
_ERRCODE_STATUS = {
    "P0400": 400,
    "P0401": 403,
    "P0403": 403,
    "P0404": 404,
    "P0409": 409,
    "P0412": 400,
    "P0422": 422,
    "P0426": 409,
    "P0451": 409,
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
    movements = await repo.list_movements(str(account["id"]), account_id)
    account["movements"] = movements
    return account


async def list_movements(
    repo: CustomerAccountRepository,
    customer_account_id: str,
    account_id: str,
    page: int = 0,
    size: int = 50,
) -> dict:
    """v3-api-standards §2.7: envelope estándar {items,total,page,pages}.

    fix/tenancy-bank-accounts-leak (2026-08-22): `account_id` obligatorio —
    antes GET /customer-accounts/{id}/movements era un IDOR (cualquier
    usuario autenticado podía leer los movimientos de la cuenta corriente de
    OTRO tenant con solo conocer/adivinar el customer_account_id)."""
    return await repo.list_movements_page(
        customer_account_id, account_id=account_id, page=page, size=size
    )


async def register_payment_received(
    repo: CustomerAccountRepository,
    auth: dict,
    payload: PaymentReceivedIn,
) -> dict:
    """Registra un cobro. Guard is_account_writer. Idempotente.

    cobranzas-catalogo-pagos (D1): propaga payment_method_id (uuid) al repo —
    el kind se deriva en el servidor, nunca acá.
    """
    require_role(auth, ["user", "admin"])
    try:
        return await repo.register_payment_received(
            idempotency_key=payload.idempotency_key,
            client_id=str(payload.client_id),
            amount=float(payload.amount),
            reference_sale_id=str(payload.reference_sale_id) if payload.reference_sale_id else None,
            payment_method_id=str(payload.payment_method_id) if payload.payment_method_id else None,
            bank_account_id=str(payload.bank_account_id) if payload.bank_account_id else None,
            # caja-compras-cobranzas (D2): passthrough del opt-in de caja —
            # la RPC resuelve y valida las dos condiciones (P0422).
            cash_session_id=str(payload.cash_session_id) if payload.cash_session_id else None,
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc


async def reverse_payment_received(
    repo: CustomerAccountRepository,
    auth: dict,
    payment_id: str,
    payload: PaymentReversalIn,
) -> dict:
    """cobranzas-reverso (task 10.1): anula un cobro. Guard is_account_writer
    evaluado ANTES de llamar al repo (D8 se re-verifica además en la RPC,
    pero el guard de rol del service es la primera capa — mismo criterio que
    register_payment_received). Cero lógica de negocio acá: sólo el guard y
    la propagación de errores."""
    require_role(auth, ["user", "admin"])
    try:
        return await repo.reverse_payment_received(payment_id, payload.reason)
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc


async def list_receivables(
    repo: CustomerAccountRepository,
    auth: dict,
    account_id: str,
    *,
    page: int = 0,
    size: int = 25,
    sort: str = "balance",
    sort_dir: str = "desc",
) -> dict:
    """cobranzas-panel (task 3.5): listado paginado de deudores.

    Sin gate de plan (D10): la cuenta corriente está disponible en todos los
    planes, gatear su único lector agregado dejaría al free registrando deuda
    que no puede leer. Sin require_role: es lectura para todo miembro; la
    autorización de tenant es el P0401 del propio RPC (D1)."""
    try:
        return await repo.list_receivables_page(
            account_id, page=page, size=size, sort=sort, sort_dir=sort_dir
        )
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc


async def get_receivables_summary(
    repo: CustomerAccountRepository,
    auth: dict,
    account_id: str,
) -> dict:
    """cobranzas-panel (task 3.5, D2): total por cobrar + cantidad de
    deudores, agregado sobre el MISMO RPC del listado. Sin gate de plan
    (D10) y sin require_role — mismos criterios que list_receivables."""
    try:
        return await repo.get_receivables_summary(account_id)
    except asyncpg.PostgresError as exc:
        raise _pg_to_http(exc) from exc
