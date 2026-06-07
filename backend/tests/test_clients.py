from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

CLIENT_ROW = {
    "id": "cli-uuid-1",
    "user_id": "test-user-id",
    "name": "Acme Corp",
    "email": "acme@example.com",
    "phone": "+54 261 555-1234",
    "created_at": "2024-01-10T09:00:00",
}


async def test_get_clients_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[CLIENT_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data[0]["name"] == "Acme Corp"


async def test_get_clients_empty(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json() == []


async def test_create_client_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "owner"})
    conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Acme Corp", "email": "acme@example.com"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["name"] == "Acme Corp"


async def test_create_client_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Test"},
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_get_client_cross_org_returns_404(async_client, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    other_token = make_token({"sub": "other-user-id"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/cli-uuid-1",
            headers={"Authorization": f"Bearer {other_token}"},
        )
    assert resp.status_code == 404
