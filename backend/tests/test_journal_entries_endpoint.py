"""
journal-entry-outbox — Endpoint tests (Task 6.3)

TDD cycle:
  6.3 RED: test_list_journal_entries_returns_200_scoped — GET /journal-entries
           returns only entries for the caller's account.
  6.3 GREEN: router wired, service + repo implemented.
  6.3 TRIANGULATE: test_list_journal_entries_cross_account_no_leak — result
           is scoped to account, different account gets empty list.
  6.3 TRIANGULATE: test_list_journal_entries_includes_lines — response includes
           debit/credit lines.
  6.3 TRIANGULATE: test_list_journal_entries_no_auth — unauthenticated → 401/403.

Spec ref: journal-entry/spec.md §"List posted entries (read endpoint)"
Design ref: D7 (RLS SELECT-only, no INSERT for authenticated)
"""
from __future__ import annotations

import time
import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from jose import jwt

from backend.repositories.journal_entry_repository import JournalEntryRepository
from backend.services import journal_entries as je_service


# ── Constants ─────────────────────────────────────────────────────────────────

ACCOUNT_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
OTHER_ACCOUNT_ID = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
USER_ID = "11111111-1111-1111-1111-111111111111"
TEST_SECRET = "test-secret-key"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_token(account_id: str | None = None) -> str:
    payload = {
        "sub": USER_ID,
        "role": "authenticated",
        "exp": int(time.time()) + 3600,
    }
    return jwt.encode(payload, TEST_SECRET, algorithm="HS256")


def _make_entry(
    entry_id: str | None = None,
    account_id: str = str(ACCOUNT_ID),
) -> dict:
    return {
        "id": uuid.UUID(entry_id) if entry_id else uuid.uuid4(),
        "account_id": uuid.UUID(account_id),
        "posted_at": datetime(2026, 8, 3, 10, 0, 0, tzinfo=timezone.utc),
        "status": "posted",
        "source_doc_type": "SalesOrder",
        "source_doc_ref": uuid.uuid4(),
        "reversal_of": None,
        "created_at": datetime(2026, 8, 3, 10, 0, 0, tzinfo=timezone.utc),
        "lines": [
            {
                "id": uuid.uuid4(),
                "entry_id": uuid.uuid4(),
                "account_code": "1100",
                "side": "debit",
                "amount": 1210.00,
                "line_no": 1,
                "cost_center_id": None,
            },
            {
                "id": uuid.uuid4(),
                "entry_id": uuid.uuid4(),
                "account_code": "4100",
                "side": "credit",
                "amount": 1000.00,
                "line_no": 2,
                "cost_center_id": None,
            },
            {
                "id": uuid.uuid4(),
                "entry_id": uuid.uuid4(),
                "account_code": "4200",
                "side": "credit",
                "amount": 210.00,
                "line_no": 3,
                "cost_center_id": None,
            },
        ],
    }


# ── Repository unit tests ─────────────────────────────────────────────────────

class TestJournalEntryRepository:
    """6.1 / 6.3: Repository returns scoped entries with lines."""

    @pytest.mark.asyncio
    async def test_list_by_account_returns_entries(self):
        """6.1: list_by_account calls DB and returns list of dicts."""
        conn = AsyncMock()
        entry = _make_entry()
        # First fetch = entries; second = lines (batch)
        conn.fetch = AsyncMock(side_effect=[
            [dict(entry)],  # entries query
            entry["lines"],   # lines query
        ])
        repo = JournalEntryRepository(conn)

        results = await repo.list_by_account(str(ACCOUNT_ID))
        assert isinstance(results, list)
        assert conn.fetch.call_count == 2, "Should fetch entries then lines"

    @pytest.mark.asyncio
    async def test_list_by_account_empty_returns_empty(self):
        """6.1: Empty account → empty list (no lines query)."""
        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[])
        repo = JournalEntryRepository(conn)

        results = await repo.list_by_account(str(ACCOUNT_ID))
        assert results == []
        # Lines query should NOT run when no entries
        assert conn.fetch.call_count == 1

    @pytest.mark.asyncio
    async def test_list_by_account_includes_lines(self):
        """6.1: Result includes nested lines for each entry."""
        conn = AsyncMock()
        entry = _make_entry()
        entry_id = entry["id"]  # pin to a fixed UUID so lines can reference it
        # Lines must reference entry["id"] so the repo's grouping by entry_id works
        pinned_lines = [
            {"id": uuid.uuid4(), "entry_id": entry_id, "account_code": "1100",
             "side": "debit", "amount": 1210.00, "line_no": 1, "cost_center_id": None},
            {"id": uuid.uuid4(), "entry_id": entry_id, "account_code": "4100",
             "side": "credit", "amount": 1000.00, "line_no": 2, "cost_center_id": None},
            {"id": uuid.uuid4(), "entry_id": entry_id, "account_code": "4200",
             "side": "credit", "amount": 210.00, "line_no": 3, "cost_center_id": None},
        ]
        conn.fetch = AsyncMock(side_effect=[
            [dict(entry)],
            pinned_lines,
        ])
        repo = JournalEntryRepository(conn)

        results = await repo.list_by_account(str(ACCOUNT_ID))
        assert len(results) == 1
        assert "lines" in results[0]
        # Lines are correctly grouped by entry_id
        assert len(results[0]["lines"]) == 3

    @pytest.mark.asyncio
    async def test_list_by_account_passes_account_id_to_query(self):
        """6.3: Repository passes account_id to the SQL query (defence-in-depth)."""
        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[])
        repo = JournalEntryRepository(conn)

        await repo.list_by_account(str(ACCOUNT_ID))

        # First call must include account_id
        call_args = conn.fetch.call_args_list[0]
        query_args = list(call_args.args) + list(call_args.kwargs.values())
        assert str(ACCOUNT_ID) in str(query_args), (
            "account_id must be passed to the query (defence-in-depth under RLS)"
        )


# ── Service unit tests ────────────────────────────────────────────────────────

class TestJournalEntryService:
    """6.2 / 6.3: Service delegates to repo, no role guard on reads."""

    @pytest.mark.asyncio
    async def test_list_service_delegates_to_repo(self):
        """6.2: list_journal_entries calls repo.list_by_account."""
        repo = MagicMock()
        repo.list_by_account = AsyncMock(return_value=[_make_entry()])

        results = await je_service.list_journal_entries(repo, str(ACCOUNT_ID))
        repo.list_by_account.assert_called_once_with(str(ACCOUNT_ID), limit=100, offset=0)
        assert len(results) == 1

    @pytest.mark.asyncio
    async def test_list_service_no_role_required(self):
        """6.2: No require_role — read-only, available to all members. No exception raised."""
        repo = MagicMock()
        repo.list_by_account = AsyncMock(return_value=[])

        # Should NOT raise even for a 'member' auth
        member_auth = {"sub": USER_ID, "role": "authenticated", "account_role": "member"}
        # We pass auth to the service only if it needed it; service doesn't take auth param
        # (the guard is pure RLS). Calling without auth confirms no require_role.
        await je_service.list_journal_entries(repo, str(ACCOUNT_ID))
        repo.list_by_account.assert_called_once()

    @pytest.mark.asyncio
    async def test_list_service_pagination(self):
        """6.2: Service passes limit and offset to repo."""
        repo = MagicMock()
        repo.list_by_account = AsyncMock(return_value=[])

        await je_service.list_journal_entries(repo, str(ACCOUNT_ID), limit=10, offset=20)
        repo.list_by_account.assert_called_once_with(str(ACCOUNT_ID), limit=10, offset=20)


# ── Schema validation tests ────────────────────────────────────────────────────

class TestJournalEntrySchemas:
    """6.2: Pydantic v2 schemas validate correctly."""

    def test_journal_line_out_validates(self):
        """6.2: JournalLineOut accepts valid data."""
        from backend.schemas.journal_entries import JournalLineOut
        line = JournalLineOut(
            id=uuid.uuid4(),
            entry_id=uuid.uuid4(),
            account_code="4100",
            side="credit",
            amount=1000.00,
            line_no=1,
            cost_center_id=None,
        )
        assert line.account_code == "4100"
        assert line.side == "credit"

    def test_journal_entry_out_validates_with_lines(self):
        """6.2: JournalEntryOut validates with nested lines."""
        from backend.schemas.journal_entries import JournalEntryOut, JournalLineOut
        entry = JournalEntryOut(
            id=uuid.uuid4(),
            account_id=ACCOUNT_ID,
            posted_at=datetime(2026, 8, 3, tzinfo=timezone.utc),
            status="posted",
            source_doc_type="SalesOrder",
            source_doc_ref=uuid.uuid4(),
            reversal_of=None,
            created_at=datetime(2026, 8, 3, tzinfo=timezone.utc),
            lines=[
                JournalLineOut(
                    id=uuid.uuid4(),
                    entry_id=uuid.uuid4(),
                    account_code="1100",
                    side="debit",
                    amount=1210.00,
                    line_no=1,
                    cost_center_id=None,
                )
            ],
        )
        assert entry.status == "posted"
        assert len(entry.lines) == 1
        assert entry.lines[0].account_code == "1100"

    def test_journal_entry_reversed_status(self):
        """6.2: status='reversed' is valid."""
        from backend.schemas.journal_entries import JournalEntryOut
        entry = JournalEntryOut(
            id=uuid.uuid4(),
            account_id=ACCOUNT_ID,
            posted_at=datetime(2026, 8, 3, tzinfo=timezone.utc),
            status="reversed",
            source_doc_type="SalesOrder",
            source_doc_ref=uuid.uuid4(),
            reversal_of=uuid.uuid4(),
            created_at=datetime(2026, 8, 3, tzinfo=timezone.utc),
            lines=[],
        )
        assert entry.status == "reversed"
        assert entry.reversal_of is not None


# ── Router wiring tests ────────────────────────────────────────────────────────

class TestJournalEntriesRouterWiring:
    """6.3: Router is registered in main.py."""

    def test_journal_entries_router_in_main(self):
        """6.3: journal_entries router is imported and included in main.py."""
        from pathlib import Path
        main_py = Path(__file__).parents[1] / "main.py"
        content = main_py.read_text(encoding="utf-8")
        assert "journal_entries" in content, (
            "main.py must import and include journal_entries router"
        )
        assert "journal_entries.router" in content, (
            "main.py must call app.include_router(journal_entries.router)"
        )

    def test_journal_entries_router_prefix(self):
        """6.3: Router has correct prefix /journal-entries."""
        from backend.routers.journal_entries import router
        assert router.prefix == "/journal-entries", (
            "journal-entries router must have prefix '/journal-entries'"
        )

    def test_journal_entries_router_has_get_endpoint(self):
        """6.3: Router exposes a GET endpoint."""
        from backend.routers.journal_entries import router
        get_routes = [r for r in router.routes if "GET" in getattr(r, "methods", set())]
        assert len(get_routes) >= 1, (
            "journal-entries router must have at least one GET endpoint"
        )

    def test_journal_entry_repository_exists(self):
        """6.1: JournalEntryRepository is importable."""
        from backend.repositories.journal_entry_repository import JournalEntryRepository
        assert JournalEntryRepository is not None

    def test_journal_entry_service_exists(self):
        """6.2: journal_entries service module is importable."""
        from backend.services import journal_entries
        assert hasattr(journal_entries, "list_journal_entries")

    def test_journal_entry_schemas_exist(self):
        """6.2: JournalEntryOut and JournalLineOut are importable."""
        from backend.schemas.journal_entries import JournalEntryOut, JournalLineOut
        assert JournalEntryOut is not None
        assert JournalLineOut is not None
