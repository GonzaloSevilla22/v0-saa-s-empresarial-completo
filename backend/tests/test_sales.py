from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

OPERATION_ROW = {
    "operation_id": "66666666-6666-6666-6666-666666666666",
    "operation_kind": "sale",
}

SALE_PAYLOAD = {
    "idempotency_key": "key-abc-123",
    "org_id": "org-uuid-1",
    "items": [
        {"product_id": "prod-uuid-1", "quantity": "2.0000", "amount": "300.00"}
    ],
}


async def test_create_sale_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["operation_id"] == "66666666-6666-6666-6666-666666666666"


async def test_create_sale_idempotent(async_client, mock_pool):
    """Duplicate idempotency_key returns existing operation (HTTP 201 with same data)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=OPERATION_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["operation_id"] == "66666666-6666-6666-6666-666666666666"


async def test_create_sale_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_list_sales_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert isinstance(resp.json(), list)
