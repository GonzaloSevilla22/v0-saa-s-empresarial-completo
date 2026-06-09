from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

PRODUCT_ROW = {
    "id": "22222222-2222-2222-2222-222222222222",
    "user_id": "11111111-1111-1111-1111-111111111111",
    "name": "Empanada",
    "category": "food",
    "price": "150.0000",
    "cost": "80.0000",
    "stock": "25.5000",
    "min_stock": 5,
    "barcode": None,
    "sku": "EMP-001",
    "parent_id": None,
    "is_variant": False,
    "base_unit_id": None,
    "stock_control_type": "unit",
    "created_at": "2024-01-01T08:00:00",
}


async def test_list_products_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[PRODUCT_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/products", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data[0]["name"] == "Empanada"


async def test_stock_fractional_serialized(async_client, valid_token, mock_pool):
    """Stock with 4 decimal places (NUMERIC 15,4) serializes correctly."""
    pool, conn = mock_pool
    fractional_row = {**PRODUCT_ROW, "stock": "12.7500"}
    conn.fetch = AsyncMock(return_value=[fractional_row])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/products", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    stock_value = resp.json()[0]["stock"]
    assert Decimal(str(stock_value)) == Decimal("12.75")


async def test_create_product_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products",
            json={"name": "Test"},
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_create_product_plan_gratis_over_limit(async_client, mock_pool):
    """Plan gratis is limited to 100 products; 101st should get 403."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "gratis"}})
    count_row = {"total": 100}
    conn.fetchrow = AsyncMock(return_value=count_row)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products",
            json={"name": "New Product"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 403
    assert "plan" in resp.json()["detail"].lower() or "límite" in resp.json()["detail"].lower()


async def test_create_product_ok_under_limit(async_client, mock_pool):
    """Creating a product when under the plan limit succeeds."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    async def fetchrow_side_effect(query, *args):
        if "COUNT" in query:
            return {"total": 5}
        return PRODUCT_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products",
            json={"name": "Empanada"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
