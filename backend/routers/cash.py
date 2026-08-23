"""
Router for C-28 v21-cash-session — CashSession / CashMovement endpoints.

Routes:
  GET  /branches/{branch_id}/cashboxes            → list cashboxes for a branch
  POST /cashboxes                                  → create a cashbox
  POST /cashboxes/{cashbox_id}/sessions/open       → open a cash session
  GET  /cashboxes/{cashbox_id}/current-session     → get the open session (404 if none)
  GET  /cashboxes/{cashbox_id}/sessions            → list all sessions for a cashbox
  POST /sessions/{session_id}/close                → close a session with arqueo
  POST /sessions/{session_id}/movements            → register a cash movement
  GET  /sessions/{session_id}/movements            → list movements for a session

Architecture rule (hard): Routers do validation + DI only.
All business logic and role guards live in services/cash.py.
"""
from __future__ import annotations

import uuid
from datetime import date

import asyncpg
from fastapi import APIRouter, Depends, Query, Request

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.core.idempotency import require_idempotency_key
from backend.repositories.cashbox_repository import CashboxRepository
from backend.repositories.cash_session_repository import CashSessionRepository
from backend.schemas.cash import (
    CashboxCreate,
    CashboxOut,
    CashMovementOut,
    CashMovementPageOut,
    CashSessionOut,
    CloseSessionIn,
    CloseSessionOut,
    OpenSessionIn,
    OpenSessionOut,
    RegisterMovementIn,
    RegisterMovementOut,
)
from backend.services import cash as cash_service

router = APIRouter(tags=["cash"])


# ── Dependencies ──────────────────────────────────────────────────────────────

def get_cashbox_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> CashboxRepository:
    return CashboxRepository(conn)


def get_session_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> CashSessionRepository:
    return CashSessionRepository(conn)


# ── Cashbox routes ────────────────────────────────────────────────────────────

@router.get("/branches/{branch_id}/cashboxes", response_model=list[CashboxOut])
async def list_cashboxes(
    branch_id: str,
    auth: dict = Depends(get_current_user),
    repo: CashboxRepository = Depends(get_cashbox_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await cash_service.list_cashboxes(repo, branch_id, str(account_id))


@router.post("/cashboxes", response_model=CashboxOut, status_code=201)
async def create_cashbox(
    payload: CashboxCreate,
    auth: dict = Depends(get_current_user),
    repo: CashboxRepository = Depends(get_cashbox_repo),
):
    return await cash_service.create_cashbox(repo, auth, payload)


# ── CashSession routes ────────────────────────────────────────────────────────

@router.post("/cashboxes/{cashbox_id}/sessions/open", response_model=OpenSessionOut)
async def open_session(
    cashbox_id: str,
    payload: OpenSessionIn,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
):
    return await cash_service.open_session(repo, auth, cashbox_id, payload)


@router.get("/cashboxes/{cashbox_id}/current-session", response_model=CashSessionOut)
async def current_session(
    cashbox_id: str,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await cash_service.current_session(repo, cashbox_id, str(account_id))


@router.get("/cashboxes/{cashbox_id}/sessions", response_model=list[CashSessionOut])
async def list_sessions(
    cashbox_id: str,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await cash_service.list_sessions(repo, cashbox_id, str(account_id))


@router.post("/sessions/{session_id}/close", response_model=CloseSessionOut)
async def close_session(
    session_id: str,
    request: Request,
    payload: CloseSessionIn,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
):
    """v3-api-standards §4: Idempotency-Key por header, con fallback al body
    (D5 — la única mutación no-idempotente que no tenía idempotencia real)."""
    payload.idempotency_key = await require_idempotency_key(request, payload.idempotency_key)
    return await cash_service.close_session(repo, auth, session_id, payload)


# ── CashMovement routes ───────────────────────────────────────────────────────

@router.post("/sessions/{session_id}/movements", response_model=RegisterMovementOut)
async def register_movement(
    session_id: str,
    payload: RegisterMovementIn,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
):
    return await cash_service.register_movement(repo, auth, session_id, payload)


@router.get("/sessions/{session_id}/movements", response_model=list[CashMovementOut])
async def list_movements(
    session_id: str,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await cash_service.list_movements(repo, session_id, str(account_id))


@router.get("/cashboxes/{cashbox_id}/movements", response_model=CashMovementPageOut)
async def list_cashbox_movements(
    cashbox_id: str,
    page: int = Query(0, ge=0, description="Página, 0-based"),
    size: int = Query(30, ge=1, le=500, description="Tamaño de página (máx 500)"),
    types: list[str] | None = Query(None, description="Filtro por movement_type (repetible)"),
    q: str | None = Query(None, description="Búsqueda de texto sobre el motivo (server-side)"),
    date_from: date | None = Query(None, alias="from"),
    date_to: date | None = Query(None, alias="to"),
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """ledger-movement-history (D2): historial de TODAS las sesiones de la
    caja — a diferencia de GET /sessions/{id}/movements (que sigue existiendo
    sin cambios, task 5.8), esta ruta no corta en la sesión abierta."""
    return await cash_service.list_movements_by_cashbox(
        repo, cashbox_id, str(account_id), page=page, size=size,
        types=types, q=q, date_from=date_from, date_to=date_to,
    )
