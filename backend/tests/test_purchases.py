from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

PURCHASE_ID = "22222222-2222-2222-2222-222222222222"

UPDATE_PAYLOAD = {
    "purchase_ids": [PURCHASE_ID],
    "date": "2024-01-15",
    "description": "Reposición",
    "items": [{"product_id": "prod-uuid-1", "quantity": "3.0", "amount": "80.00"}],
}


async def test_update_purchase_operation_ok(async_client, mock_pool):
    """PUT /purchases/operation invoca rpc_atomic_update_purchase_operation → 200."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["query"] = query
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert "rpc_atomic_update_purchase_operation" in captured["query"]


async def test_update_purchase_operation_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403
