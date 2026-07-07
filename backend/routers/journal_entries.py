"""
journal-entry-outbox — FastAPI router for journal entries (Task 6.2)

Minimal read-only endpoint: GET /journal-entries
  - 3-layer architecture: router (parse + DI) → service (guards) → repo (data)
  - JWT-passthrough: no service_role
  - Pydantic v2 response schema

No write endpoints: the posting relay is the only writer (SECURITY DEFINER).
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.journal_entry_repository import JournalEntryRepository
from backend.schemas.journal_entries import JournalEntryPageOut
from backend.services import journal_entries as je_service

router = APIRouter(prefix="/journal-entries", tags=["journal-entries"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> JournalEntryRepository:
    return JournalEntryRepository(conn)


@router.get("", response_model=JournalEntryPageOut)
async def list_journal_entries(
    page: int = Query(0, ge=0, description="Página, 0-based"),
    size: int = Query(100, ge=1, le=500, description="Tamaño de página (máx 500)"),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: JournalEntryRepository = Depends(get_repo),
):
    """List journal entries (with debit/credit lines) for the current account.

    v3-api-standards §2.9: envelope estándar {items,total,page,pages}.
    Returns entries ordered by posted_at DESC (most recent first).
    Available to all authenticated members of the account (read-only).
    RLS enforces account scope — no cross-account leak.
    """
    return await je_service.list_journal_entries_page(
        repo,
        str(account_id),
        page=page,
        size=size,
    )
