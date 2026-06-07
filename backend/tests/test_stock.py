from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest


async def test_get_stock_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value={"stock": "25.5000"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/stock/product/prod-uuid-1",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    assert resp.json()["stock"] is not None


async def test_transfer_stock_rpc_returns_none_gives_422(async_client, mock_pool):
    """If rpc_transfer_stock returns None (stock insuficiente), service raises 422."""
    from backend.tests.conftest import make_token
    pool, conn = mock_pool
    owner_token = make_token({"role": "owner"})
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/stock/transfer",
            json={
                "from_branch_id": "branch-a",
                "to_branch_id": "branch-b",
                "product_id": "prod-uuid-1",
                "quantity": "999.0000",
            },
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
