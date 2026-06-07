from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

EXPENSE_ROW = {
    "id": "exp-uuid-1",
    "user_id": "test-user-id",
    "category": "supplies",
    "amount": "150.00",
    "description": "Paper",
    "date": "2024-01-15",
    "created_at": "2024-01-15T10:00:00",
}


async def test_get_expenses_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[EXPENSE_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/expenses", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert data[0]["category"] == "supplies"


async def test_get_expenses_empty(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/expenses", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json() == []


async def test_create_expense_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "owner"})
    conn.fetchrow = AsyncMock(return_value=EXPENSE_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/expenses",
            json={"category": "supplies", "amount": "150.00", "date": "2024-01-15"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["category"] == "supplies"


async def test_create_expense_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    conn.fetchrow = AsyncMock(return_value=EXPENSE_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/expenses",
            json={"category": "supplies", "amount": "50.00", "date": "2024-01-15"},
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_delete_expense_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    conn.fetchrow = AsyncMock(return_value=EXPENSE_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            "/expenses/exp-uuid-1",
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_get_expense_cross_org_empty(async_client, mock_pool):
    """RLS via JWT-passthrough returns no row for a different org's expense."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    other_token = make_token({"sub": "other-user-id"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/expenses/exp-uuid-1",
            headers={"Authorization": f"Bearer {other_token}"},
        )
    assert resp.status_code == 404
