"""
journal-entry-outbox — JournalEntryRepository (Task 6.1)

Read-only repository for journal_entries + journal_lines.
JWT-passthrough: RLS SELECT policy on both tables enforces account scope.
No service_role. Writes are not exposed here (relay-only via SECURITY DEFINER).
"""
from __future__ import annotations

import uuid

from backend.repositories.base import BaseRepository


class JournalEntryRepository(BaseRepository):
    """Read-only access to the double-entry accounting tables.

    Connection is JWT-passthrough (no service_role). The SELECT RLS policy on
    journal_entries and journal_lines (account_id IN current_account_ids()) is
    the DB-level access gate.

    Task 6.1: list_by_account returns entries with their lines, most-recent-first.
    """

    async def list_by_account(
        self,
        account_id: str,
        *,
        limit: int = 100,
        offset: int = 0,
    ) -> list[dict]:
        """List journal entries with their lines for the account (most recent first).

        Returns entries with nested lines. RLS enforces account scope so the
        WHERE clause on account_id is defence-in-depth (not the only guard).

        Args:
            account_id: Tenant UUID (also enforced by RLS).
            limit: Page size (default 100).
            offset: Page offset for pagination.
        """
        entries = await self._fetch_entries(account_id, limit=limit, offset=offset)
        return await self._attach_lines(entries)

    async def list_by_account_page(
        self,
        account_id: str,
        *,
        page: int,
        size: int,
    ) -> dict:
        """v3-api-standards §2.9: envelope estándar {items,total,page,pages}
        (reemplaza limit/offset + lista plana)."""
        total: int = await self._conn.fetchval(
            "SELECT COUNT(*) FROM public.journal_entries WHERE account_id = $1::uuid",
            account_id,
        ) or 0

        offset = page * size
        entries = await self._fetch_entries(account_id, limit=size, offset=offset)
        items = await self._attach_lines(entries)
        pages = -(-total // size) if total > 0 else 0

        return {"items": items, "total": total, "page": page, "pages": pages}

    async def _fetch_entries(
        self, account_id: str, *, limit: int, offset: int
    ) -> list[dict]:
        """Fetch entry headers (sin líneas)."""
        return await self.fetch(
            """
            SELECT
                id,
                account_id,
                posted_at,
                status,
                source_doc_type,
                source_doc_ref,
                reversal_of,
                created_at
            FROM public.journal_entries
            WHERE account_id = $1::uuid
            ORDER BY posted_at DESC, created_at DESC
            LIMIT $2 OFFSET $3
            """,
            account_id,
            limit,
            offset,
        )

    async def _attach_lines(self, entries: list[dict]) -> list[dict]:
        """Batch-fetch journal_lines para las entries dadas y las agrupa por entry_id."""
        if not entries:
            return []

        entry_ids = [e["id"] for e in entries]
        lines = await self.fetch(
            """
            SELECT
                id,
                entry_id,
                account_code,
                side,
                amount,
                line_no,
                cost_center_id
            FROM public.journal_lines
            WHERE entry_id = ANY($1::uuid[])
            ORDER BY entry_id, line_no
            """,
            entry_ids,
        )

        lines_by_entry: dict[uuid.UUID, list[dict]] = {}
        for line in lines:
            eid = line["entry_id"]
            lines_by_entry.setdefault(eid, []).append(dict(line))

        result = []
        for entry in entries:
            entry_dict = dict(entry)
            entry_dict["lines"] = lines_by_entry.get(entry["id"], [])
            result.append(entry_dict)

        return result
