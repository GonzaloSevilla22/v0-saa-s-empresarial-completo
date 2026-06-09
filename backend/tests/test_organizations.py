from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

ORG_ROW = {
    "id": "44444444-4444-4444-4444-444444444444",
    "name": "Mi Empresa",
    "created_at": "2024-01-01T00:00:00",
}


async def test_get_org_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=ORG_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/organizations/org-uuid-1",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Mi Empresa"


async def test_get_org_not_found(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/organizations/nonexistent",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 404


async def test_update_org_settings_owner_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=ORG_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/organizations/org-uuid-1/settings",
            json={"name": "Nueva Empresa"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200


async def test_update_org_settings_admin_forbidden(async_client, mock_pool):
    """Only owner can update org settings."""
    pool, conn = mock_pool
    admin_token = make_token({"role": "admin"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/organizations/org-uuid-1/settings",
            json={"name": "Nueva"},
            headers={"Authorization": f"Bearer {admin_token}"},
        )
    assert resp.status_code == 403
