"""
Service layer for C-28 v21-cash-session.

Architecture rule (hard): NO business logic in routers.
All guards (role, plan, domain invariants) live here.
Repositories handle data access only.

fix/tenancy-bank-accounts-leak (2026-08-22): TODAS las lecturas de este
service exigen account_id explícito ahora — "RLS ya aísla por cuenta" era
falso mientras la palanca TENANCY_TX_SCOPE_ENABLED del pool sigue apagada
(el pool corre como owner de las tablas, no como `authenticated`).
"""
from __future__ import annotations

from datetime import date

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.cashbox_repository import CashboxRepository
from backend.repositories.cash_session_repository import CashSessionRepository
from backend.schemas.cash import CashboxCreate, OpenSessionIn, CloseSessionIn, RegisterMovementIn


# ── Cashboxes ─────────────────────────────────────────────────────────────────

async def list_cashboxes(
    repo: CashboxRepository,
    branch_id: str,
    account_id: str,
) -> list:
    return await repo.list_cashboxes(branch_id, account_id)


async def create_cashbox(
    repo: CashboxRepository,
    auth: dict,
    payload: CashboxCreate,
) -> dict:
    require_role(auth, ["user", "admin"])
    record = await repo.create_cashbox(
        str(payload.branch_id),
        payload.name,
        payload.currency,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la caja")
    return dict(record)


# ── CashSession ───────────────────────────────────────────────────────────────

async def open_session(
    repo: CashSessionRepository,
    auth: dict,
    cashbox_id: str,
    payload: OpenSessionIn,
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.open_session(cashbox_id, float(payload.opening_balance))


async def close_session(
    repo: CashSessionRepository,
    auth: dict,
    session_id: str,
    payload: CloseSessionIn,
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.close_session(
        session_id, float(payload.counted_balance), idempotency_key=payload.idempotency_key
    )


async def current_session(
    repo: CashSessionRepository,
    cashbox_id: str,
    account_id: str,
) -> dict:
    record = await repo.current_session(cashbox_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="No hay sesión de caja abierta para esta caja")
    return dict(record)


async def list_sessions(
    repo: CashSessionRepository,
    cashbox_id: str,
    account_id: str,
) -> list:
    return await repo.list_sessions(cashbox_id, account_id)


# ── CashMovement ──────────────────────────────────────────────────────────────

async def register_movement(
    repo: CashSessionRepository,
    auth: dict,
    session_id: str,
    payload: RegisterMovementIn,
) -> dict:
    """require_role(["user","admin"]) ya cubre task 6.5 (un usuario de
    sólo lectura no puede ajustar) — mismo guard que gobierna el resto de
    movimientos, sin código nuevo (el ajuste reusa este endpoint, task 6.2)."""
    require_role(auth, ["user", "admin"])
    return await repo.register_movement(
        session_id,
        float(payload.amount),
        payload.movement_type.value,
        str(payload.reference_id) if payload.reference_id else None,
        payload.description,
    )


async def list_movements(
    repo: CashSessionRepository,
    session_id: str,
    account_id: str,
) -> list:
    return await repo.list_movements(session_id, account_id)


async def list_movements_by_cashbox(
    repo: CashSessionRepository,
    cashbox_id: str,
    account_id: str,
    *,
    page: int,
    size: int,
    types: list[str] | None,
    q: str | None,
    date_from: date | None,
    date_to: date | None,
) -> dict:
    """D2 del design: historial de TODAS las sesiones de la caja (no solo
    la abierta). Lectura — sin require_role, mismo criterio que list_movements
    y list_sessions (cualquier miembro autenticado de la cuenta puede leer)."""
    return await repo.list_movements_by_cashbox_page(
        cashbox_id, account_id=account_id, page=page, size=size,
        types=types, q=q, date_from=date_from, date_to=date_to,
    )
