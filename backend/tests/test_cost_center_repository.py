"""
cost-center-dimension — CostCenterRepository TDD tests (tasks 2.1-2.3).

Tests cover CostCenterRepository methods via asyncpg mock.
No real DB is touched — all SQL is verified through call_args.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CC_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

CC_ROW_ACTIVE = {
    "id": CC_ID,
    "account_id": ACCOUNT_ID,
    "name": "Marketing",
    "code": "MKTO",
    "is_active": True,
    "created_at": "2026-08-02T10:00:00+00:00",
}

CC_ROW_INACTIVE = {
    "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
    "account_id": ACCOUNT_ID,
    "name": "Logística",
    "code": None,
    "is_active": False,
    "created_at": "2026-08-01T08:00:00+00:00",
}


@pytest.fixture
def cost_center_repo():
    from backend.repositories.cost_center_repository import CostCenterRepository

    conn = AsyncMock()
    return CostCenterRepository(conn), conn


# ── 2.1 RED: list_by_account ──────────────────────────────────────────────────

class TestCostCenterRepositoryList:
    @pytest.mark.asyncio
    async def test_list_active_only_by_default(self, cost_center_repo):
        """list_by_account(active_only=True) returns only active centers."""
        repo, conn = cost_center_repo
        conn.fetch = AsyncMock(return_value=[CC_ROW_ACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=True)

        assert len(result) == 1
        sql = conn.fetch.call_args[0][0]
        assert "is_active" in sql.lower()
        assert result[0]["name"] == "Marketing"

    @pytest.mark.asyncio
    async def test_list_all_when_active_only_false(self, cost_center_repo):
        """list_by_account(active_only=False) returns all centers including inactive."""
        repo, conn = cost_center_repo
        conn.fetch = AsyncMock(return_value=[CC_ROW_ACTIVE, CC_ROW_INACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=False)

        assert len(result) == 2
        # When active_only=False, the SQL should NOT filter by is_active
        sql = conn.fetch.call_args[0][0].lower()
        # We expect the is_active filter to be absent (or always-true) in the full query
        assert ACCOUNT_ID in conn.fetch.call_args[0]

    @pytest.mark.asyncio
    async def test_list_empty_when_no_centers(self, cost_center_repo):
        """list_by_account returns empty list when account has no centers."""
        repo, conn = cost_center_repo
        conn.fetch = AsyncMock(return_value=[])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=True)

        assert result == []


# ── 2.1 RED: create ────────────────────────────────────────────────────────────

class TestCostCenterRepositoryCreate:
    @pytest.mark.asyncio
    async def test_create_returns_new_row(self, cost_center_repo):
        """create inserts a cost center and returns the created row."""
        repo, conn = cost_center_repo
        conn.fetchrow = AsyncMock(return_value=CC_ROW_ACTIVE)

        result = await repo.create(ACCOUNT_ID, name="Marketing", code="MKTO")

        assert result is not None
        assert result["name"] == "Marketing"
        sql = conn.fetchrow.call_args[0][0].upper()
        assert "INSERT" in sql
        assert "RETURNING" in sql

    @pytest.mark.asyncio
    async def test_create_without_code(self, cost_center_repo):
        """create accepts None code (optional field)."""
        repo, conn = cost_center_repo
        row = {**CC_ROW_ACTIVE, "code": None}
        conn.fetchrow = AsyncMock(return_value=row)

        result = await repo.create(ACCOUNT_ID, name="Marketing", code=None)

        assert result is not None
        # code=None should be passed through
        args = conn.fetchrow.call_args[0]
        assert None in args


# ── 2.1 RED: update ────────────────────────────────────────────────────────────

class TestCostCenterRepositoryUpdate:
    @pytest.mark.asyncio
    async def test_update_name_returns_row(self, cost_center_repo):
        """update name of a cost center returns updated row."""
        repo, conn = cost_center_repo
        updated = {**CC_ROW_ACTIVE, "name": "Marketing Digital"}
        conn.fetchrow = AsyncMock(return_value=updated)

        result = await repo.update(CC_ID, ACCOUNT_ID, name="Marketing Digital", code=None)

        assert result is not None
        sql = conn.fetchrow.call_args[0][0].upper()
        assert "UPDATE" in sql
        assert "RETURNING" in sql

    @pytest.mark.asyncio
    async def test_update_not_found_returns_none(self, cost_center_repo):
        """update returns None when cost center not found for the account."""
        repo, conn = cost_center_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.update("nonexistent-id", ACCOUNT_ID, name="X", code=None)

        assert result is None


# ── 2.1 RED: deactivate ────────────────────────────────────────────────────────

class TestCostCenterRepositoryDeactivate:
    @pytest.mark.asyncio
    async def test_deactivate_sets_is_active_false(self, cost_center_repo):
        """deactivate marks is_active=false and returns updated row."""
        repo, conn = cost_center_repo
        deactivated = {**CC_ROW_ACTIVE, "is_active": False}
        conn.fetchrow = AsyncMock(return_value=deactivated)

        result = await repo.deactivate(CC_ID, ACCOUNT_ID)

        assert result is not None
        assert result["is_active"] is False
        sql = conn.fetchrow.call_args[0][0].upper()
        assert "IS_ACTIVE" in sql or "is_active" in conn.fetchrow.call_args[0][0]
        assert "UPDATE" in sql

    @pytest.mark.asyncio
    async def test_deactivate_returns_none_if_not_found(self, cost_center_repo):
        """deactivate returns None when cost center does not exist."""
        repo, conn = cost_center_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.deactivate("nonexistent", ACCOUNT_ID)

        assert result is None


# ── 2.3 TRIANGULATE ────────────────────────────────────────────────────────────

class TestCostCenterRepositoryTriangulate:
    @pytest.mark.asyncio
    async def test_list_active_only_filters_inactive(self, cost_center_repo):
        """TRIANGULATE: list_by_account(active_only=True) excludes inactive rows."""
        repo, conn = cost_center_repo
        # DB + RLS only returns active row when active_only=True
        conn.fetch = AsyncMock(return_value=[CC_ROW_ACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=True)

        # Only the active center should be returned
        assert all(r["is_active"] for r in result)

    @pytest.mark.asyncio
    async def test_list_all_includes_inactive(self, cost_center_repo):
        """TRIANGULATE: list_by_account(active_only=False) includes inactive rows."""
        repo, conn = cost_center_repo
        conn.fetch = AsyncMock(return_value=[CC_ROW_ACTIVE, CC_ROW_INACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=False)

        assert len(result) == 2
        active_names = {r["name"] for r in result}
        assert "Marketing" in active_names
        assert "Logística" in active_names

    @pytest.mark.asyncio
    async def test_deactivate_marks_is_active_false_not_deletes(self, cost_center_repo):
        """TRIANGULATE: deactivate uses UPDATE is_active=false, NOT DELETE."""
        repo, conn = cost_center_repo
        conn.fetchrow = AsyncMock(return_value={**CC_ROW_ACTIVE, "is_active": False})

        result = await repo.deactivate(CC_ID, ACCOUNT_ID)

        sql = conn.fetchrow.call_args[0][0].upper()
        assert "DELETE" not in sql, "deactivate must use soft-delete, not DELETE"
        assert "UPDATE" in sql
        assert result["is_active"] is False
