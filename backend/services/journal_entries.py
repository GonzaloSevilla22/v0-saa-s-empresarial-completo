"""
journal-entry-outbox — JournalEntries service layer (Task 6.2)
asiento-contable-gastos (D10, 2026-09-10) — filtros por período, tipo/
referencia de documento y estado, empujados hasta el repositorio.

Service: list_journal_entries
  - No require_role: all account members can read the journal (read-only).
  - The DB-level SELECT RLS policy (account_id IN current_account_ids()) is the
    primary access control; the service layer is defence-in-depth.
  - JWT-passthrough: no service_role.
"""
from __future__ import annotations

import datetime

from backend.repositories.journal_entry_repository import JournalEntryRepository


async def list_journal_entries(
    repo: JournalEntryRepository,
    account_id: str,
    *,
    limit: int = 100,
    offset: int = 0,
    date_from: datetime.date | None = None,
    date_to: datetime.date | None = None,
    source_doc_type: str | None = None,
    source_doc_ref: str | None = None,
    status: str | None = None,
) -> list[dict]:
    """List journal entries (with lines) for the account.

    Returns entries ordered by posted_at DESC (most recent first).
    No require_role: read-only; RLS is the gate.

    Args:
        repo: JournalEntryRepository (JWT-passthrough connection).
        account_id: Tenant UUID (also enforced by RLS).
        limit: Page size (default 100, max enforced by caller).
        offset: Pagination offset.
        date_from/date_to/source_doc_type/source_doc_ref/status: filtros
            opcionales (D10), sin validación de negocio acá — pura
            delegación al repositorio.
    """
    return await repo.list_by_account(
        account_id,
        limit=limit,
        offset=offset,
        date_from=date_from,
        date_to=date_to,
        source_doc_type=source_doc_type,
        source_doc_ref=source_doc_ref,
        status=status,
    )


async def list_journal_entries_page(
    repo: JournalEntryRepository,
    account_id: str,
    *,
    page: int = 0,
    size: int = 100,
    date_from: datetime.date | None = None,
    date_to: datetime.date | None = None,
    source_doc_type: str | None = None,
    source_doc_ref: str | None = None,
    status: str | None = None,
) -> dict:
    """v3-api-standards §2.9: envelope estándar {items,total,page,pages}
    (reemplaza limit/offset + lista plana). No require_role: read-only.

    asiento-contable-gastos (D10): filtros opcionales pasados tal cual al
    repositorio — el mismo predicado gobierna items y total (8.8)."""
    return await repo.list_by_account_page(
        account_id,
        page=page,
        size=size,
        date_from=date_from,
        date_to=date_to,
        source_doc_type=source_doc_type,
        source_doc_ref=source_doc_ref,
        status=status,
    )
