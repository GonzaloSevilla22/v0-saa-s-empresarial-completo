"""
C-21 v20-inventory-unification — Group 4 TDD tests for StockRepository.

Tests verify:
  4.1 get_stock_by_product queries SUM(branch_stock) not products.stock
  4.2 Tenancy filter uses account_id (not user_id)
  4.3 Multi-branch scenario returns correct aggregate sum
  4.4 Product not found (no branch_stock rows) returns {"product_id": ..., "stock": 0} or 404

Safety net: run existing test_stock.py tests before touching implementation.
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

PRODUCT_ID   = "22222222-2222-2222-2222-222222222222"
ACCOUNT_ID   = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"


# ─── Repository unit tests (no HTTP layer) ────────────────────────────────────

class TestStockRepositoryGetStock:
    """4.1 / 4.2 / 4.3: StockRepository queries branch_stock, filters by account_id."""

    @pytest.fixture
    def repo(self):
        from backend.repositories.stock_repository import StockRepository
        conn = AsyncMock()
        return StockRepository(conn), conn

    @pytest.mark.asyncio
    async def test_get_stock_queries_branch_stock_sum(self, repo):
        """4.1 RED→GREEN: result comes from SUM(branch_stock), not products.stock."""
        repository, conn = repo
        conn.fetchrow = AsyncMock(return_value={"stock": Decimal("42.0000")})

        result = await repository.get_stock_by_product(PRODUCT_ID, ACCOUNT_ID)

        assert result is not None
        assert result["stock"] == Decimal("42.0000")
        # Verify the query sent to the connection uses branch_stock, not products.stock column
        call_args = conn.fetchrow.call_args
        query_str = call_args[0][0].lower()
        assert "branch_stock" in query_str, (
            f"Expected query to reference branch_stock, got: {call_args[0][0]}"
        )
        # Query may JOIN products to verify existence, but must NOT SELECT products.stock column
        assert "p.stock" not in query_str and "products.stock" not in query_str, (
            f"Query must NOT select products.stock column, got: {call_args[0][0]}"
        )

    @pytest.mark.asyncio
    async def test_get_stock_filters_by_account_id(self, repo):
        """4.2 RED→GREEN: tenancy filter uses account_id (not user_id)."""
        repository, conn = repo
        conn.fetchrow = AsyncMock(return_value={"stock": Decimal("10.0000")})

        await repository.get_stock_by_product(PRODUCT_ID, ACCOUNT_ID)

        call_args = conn.fetchrow.call_args
        query_str = call_args[0][0].lower()
        # Must use account_id as parameter
        assert "account_id" in query_str, (
            f"Expected 'account_id' in query, got: {call_args[0][0]}"
        )
        # Must NOT use user_id
        assert "user_id" not in query_str, (
            f"Expected NO 'user_id' in query (C-19 tenancy fix), got: {call_args[0][0]}"
        )
        # Both params passed to fetchrow
        params = list(call_args[0][1:])
        assert PRODUCT_ID in params, "product_id must be passed as parameter"
        assert ACCOUNT_ID in params, "account_id must be passed as parameter"

    @pytest.mark.asyncio
    async def test_get_stock_multi_branch_returns_sum(self, repo):
        """4.3 RED→GREEN: multi-branch account — result is the SUM across all branches."""
        repository, conn = repo
        # SUM of 7 + 3 = 10 from two hypothetical branches
        conn.fetchrow = AsyncMock(return_value={"stock": Decimal("10.0000")})

        result = await repository.get_stock_by_product(PRODUCT_ID, ACCOUNT_ID)

        assert result["stock"] == Decimal("10.0000")
        call_args = conn.fetchrow.call_args
        query_str = call_args[0][0].lower()
        # Aggregation must appear in the query
        assert "sum" in query_str or "coalesce" in query_str, (
            "Query must aggregate branch_stock.quantity with SUM/COALESCE"
        )

    @pytest.mark.asyncio
    async def test_get_stock_no_branch_stock_returns_zero(self, repo):
        """4.1 edge case: product with no branch_stock rows → returns {"stock": 0}."""
        repository, conn = repo
        # COALESCE(SUM(null), 0) = 0 — fetchrow returns a row with stock=0
        conn.fetchrow = AsyncMock(return_value={"stock": Decimal("0")})

        result = await repository.get_stock_by_product(PRODUCT_ID, ACCOUNT_ID)

        assert result["stock"] == Decimal("0")


# ─── Integration tests via HTTP endpoint ─────────────────────────────────────

@pytest.mark.asyncio
async def test_get_stock_endpoint_uses_branch_stock(async_client, valid_token, mock_pool):
    """4.1 + 4.4: The /stock/product/<id> endpoint returns stock from branch_stock sum."""
    pool, conn = mock_pool
    # Simulate SUM(branch_stock) = 33
    conn.fetchrow = AsyncMock(return_value={"stock": Decimal("33.0000")})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/stock/product/{PRODUCT_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert "stock" in body
    assert body["stock"] is not None
    # product_id preserved in response
    assert "product_id" in body


@pytest.mark.asyncio
async def test_get_stock_endpoint_returns_404_when_no_record(async_client, valid_token, mock_pool):
    """4.4: If product not found (fetchrow returns None), 404 is returned."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/stock/product/{PRODUCT_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 404
