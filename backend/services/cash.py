"""
Service layer for C-28 v21-cash-session.

Architecture rule (hard): NO business logic in routers.
All guards (role, plan, domain invariants) live here.
Repositories handle data access only.
"""
from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.cashbox_repository import CashboxRepository
from backend.repositories.cash_session_repository import CashSessionRepository
from backend.schemas.cash import CashboxCreate, OpenSessionIn, CloseSessionIn, RegisterMovementIn


# ── Cashboxes ─────────────────────────────────────────────────────────────────

async def list_cashboxes(
    repo: CashboxRepository,
    branch_id: str,
) -> list:
    return await repo.list_cashboxes(branch_id)


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
    return await repo.close_session(session_id, float(payload.counted_balance))


async def current_session(
    repo: CashSessionRepository,
    cashbox_id: str,
) -> dict:
    record = await repo.current_session(cashbox_id)
    if record is None:
        raise HTTPException(status_code=404, detail="No hay sesión de caja abierta para esta caja")
    return dict(record)


async def list_sessions(
    repo: CashSessionRepository,
    cashbox_id: str,
) -> list:
    return await repo.list_sessions(cashbox_id)


# ── CashMovement ──────────────────────────────────────────────────────────────

async def register_movement(
    repo: CashSessionRepository,
    auth: dict,
    session_id: str,
    payload: RegisterMovementIn,
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.register_movement(
        session_id,
        float(payload.amount),
        payload.movement_type.value,
        str(payload.reference_id) if payload.reference_id else None,
    )


async def list_movements(
    repo: CashSessionRepository,
    session_id: str,
) -> list:
    return await repo.list_movements(session_id)
