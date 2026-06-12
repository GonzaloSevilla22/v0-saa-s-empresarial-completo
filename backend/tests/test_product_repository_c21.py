"""
C-21 v20-inventory-unification — Group 5 TDD tests for ProductRepository.

Tests verify:
  5.1 list_by_org queries v_products_with_stock (not FROM products)
  5.2 get_by_id queries v_products_with_stock (not FROM products)
  5.3 stock field from list_by_org comes from view (branch_stock sum), not products.stock
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"

VIEW_ROW = {
    "id": PRODUCT_ID,
    "account_id": ACCOUNT_ID,
    "user_id": "11111111-1111-1111-1111-111111111111",
    "name": "Reel Fly Limay",
    "category": "Pesca",
    "price": "15000.0000",
    "cost": "8000.0000",
    "stock": "15.0000",   # stock from view = Σ branch_stock (not products.stock)
    "min_stock": 2,
    "barcode": None,
    "sku": "RFL-001",
    "parent_id": None,
    "is_variant": False,
    "stock_control_type": "tracked",
    "created_at": "2024-01-01T08:00:00",
    "deleted_at": None,
}


@pytest.fixture
def product_repo():
    from backend.repositories.product_repository import ProductRepository
    conn = AsyncMock()
    return ProductRepository(conn), conn


class TestProductRepositoryListByOrg:
    """5.1: list_by_org queries v_products_with_stock instead of products."""

    @pytest.mark.asyncio
    async def test_list_by_org_queries_view(self, product_repo):
        """RED→GREEN: list_by_org SELECT FROM v_products_with_stock."""
        repo, conn = product_repo
        conn.fetch = AsyncMock(return_value=[VIEW_ROW])

        await repo.list_by_org(ACCOUNT_ID)

        query_str = conn.fetch.call_args[0][0].lower()
        assert "v_products_with_stock" in query_str, (
            f"Expected list_by_org to query v_products_with_stock, got: {conn.fetch.call_args[0][0]}"
        )

    @pytest.mark.asyncio
    async def test_list_by_org_does_not_query_bare_products_table(self, product_repo):
        """5.1: list_by_org must NOT query products directly (reads stock from view)."""
        repo, conn = product_repo
        conn.fetch = AsyncMock(return_value=[VIEW_ROW])

        await repo.list_by_org(ACCOUNT_ID)

        query_str = conn.fetch.call_args[0][0].lower()
        # The query must use the view, not the bare products table
        # (It's OK to reference 'products' as part of 'v_products_with_stock' but
        #  the FROM clause must be the view)
        assert "from products" not in query_str.replace("v_products_with_stock", "REPLACED"), (
            "list_by_org must SELECT FROM v_products_with_stock, not bare products table"
        )

    @pytest.mark.asyncio
    async def test_list_by_org_returns_stock_field(self, product_repo):
        """5.3: The returned rows include a 'stock' field (from view)."""
        repo, conn = product_repo
        conn.fetch = AsyncMock(return_value=[VIEW_ROW])

        rows = await repo.list_by_org(ACCOUNT_ID)

        assert len(rows) == 1
        assert "stock" in rows[0]
        assert rows[0]["stock"] == "15.0000"


class TestProductRepositoryGetById:
    """5.2: get_by_id queries v_products_with_stock."""

    @pytest.mark.asyncio
    async def test_get_by_id_queries_view(self, product_repo):
        """RED→GREEN: get_by_id SELECT FROM v_products_with_stock."""
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.get_by_id(PRODUCT_ID, ACCOUNT_ID)

        query_str = conn.fetchrow.call_args[0][0].lower()
        assert "v_products_with_stock" in query_str, (
            f"Expected get_by_id to query v_products_with_stock, got: {conn.fetchrow.call_args[0][0]}"
        )

    @pytest.mark.asyncio
    async def test_get_by_id_not_found_returns_none(self, product_repo):
        """get_by_id returns None when no row exists."""
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.get_by_id(PRODUCT_ID, ACCOUNT_ID)

        assert result is None
