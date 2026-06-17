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

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.cashbox_repository import CashboxRepository
from backend.repositories.cash_session_repository import CashSessionRepository
from backend.schemas.cash import (
    CashboxCreate,
    CashboxOut,
    CashMovementOut,
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
):
    return await cash_service.list_cashboxes(repo, branch_id)


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
):
    return await cash_service.current_session(repo, cashbox_id)


@router.get("/cashboxes/{cashbox_id}/sessions", response_model=list[CashSessionOut])
async def list_sessions(
    cashbox_id: str,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
):
    return await cash_service.list_sessions(repo, cashbox_id)


@router.post("/sessions/{session_id}/close", response_model=CloseSessionOut)
async def close_session(
    session_id: str,
    payload: CloseSessionIn,
    auth: dict = Depends(get_current_user),
    repo: CashSessionRepository = Depends(get_session_repo),
):
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
):
    return await cash_service.list_movements(repo, session_id)
