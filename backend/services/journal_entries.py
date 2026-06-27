"""
journal-entry-outbox — JournalEntries service layer (Task 6.2)

Service: list_journal_entries
  - No require_role: all account members can read the journal (read-only).
  - The DB-level SELECT RLS policy (account_id IN current_account_ids()) is the
    primary access control; the service layer is defence-in-depth.
  - JWT-passthrough: no service_role.
"""
from __future__ import annotations

from backend.repositories.journal_entry_repository import JournalEntryRepository


async def list_journal_entries(
    repo: JournalEntryRepository,
    account_id: str,
    *,
    limit: int = 100,
    offset: int = 0,
) -> list[dict]:
    """List journal entries (with lines) for the account.

    Returns entries ordered by posted_at DESC (most recent first).
    No require_role: read-only; RLS is the gate.

    Args:
        repo: JournalEntryRepository (JWT-passthrough connection).
        account_id: Tenant UUID (also enforced by RLS).
        limit: Page size (default 100, max enforced by caller).
        offset: Pagination offset.
    """
    return await repo.list_by_account(account_id, limit=limit, offset=offset)
