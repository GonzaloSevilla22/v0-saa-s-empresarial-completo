"""
branch-min-stock-realign — Group 2 TDD tests for ProductRepository.

Tests verify:
  2.2/2.3 update() propagates min_stock to branch_stock via
          rpc_set_product_min_stock, in the same asyncpg transaction, only
          when min_stock is part of the changed payload.
  2.4/2.5 create() propagates min_stock to branch_stock AFTER the initial
          stock delta (so the branch_stock row already exists).
  2.6     Triangulation: min_stock=0 does not break; product with no stock
          delta (create) still propagates; update without min_stock in the
          payload does NOT call the RPC.
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "11111111-1111-1111-1111-111111111111"

VIEW_ROW = {
    "id": PRODUCT_ID,
    "account_id": ACCOUNT_ID,
    "user_id": USER_ID,
    "name": "Reel Fly Limay",
    "category": "Pesca",
    "price": "15000.0000",
    "cost": "8000.0000",
    "stock": "15.0000",
    "min_stock": 5,
    "barcode": None,
    "sku": "RFL-001",
    "parent_id": None,
    "is_variant": False,
    "stock_control_type": "tracked",
    "created_at": "2024-01-01T08:00:00",
    "deleted_at": None,
}


def _make_transaction_cm():
    """A context manager mock compatible with `async with self._conn.transaction():`."""
    cm = MagicMock()
    cm.__aenter__ = AsyncMock(return_value=None)
    cm.__aexit__ = AsyncMock(return_value=False)
    return cm


@pytest.fixture
def product_repo():
    from backend.repositories.product_repository import ProductRepository

    conn = AsyncMock()
    conn.transaction = MagicMock(return_value=_make_transaction_cm())
    return ProductRepository(conn), conn


class TestUpdatePropagatesMinStock:
    """2.2/2.3: update() calls rpc_set_product_min_stock when min_stock changes."""

    @pytest.mark.asyncio
    async def test_update_with_min_stock_calls_propagation_rpc(self, product_repo):
        """RED→GREEN: update() with min_stock in payload invokes rpc_set_product_min_stock."""
        repo, conn = product_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"min_stock": 5})

        rpc_calls = [
            call for call in conn.fetchrow.call_args_list
            if "rpc_set_product_min_stock" in call.args[0]
        ]
        assert len(rpc_calls) == 1, (
            f"Expected exactly 1 call to rpc_set_product_min_stock, got {len(rpc_calls)}: "
            f"{[c.args[0] for c in conn.fetchrow.call_args_list]}"
        )
        assert rpc_calls[0].args[1] == PRODUCT_ID
        assert rpc_calls[0].args[2] == 5

    @pytest.mark.asyncio
    async def test_update_without_min_stock_does_not_call_propagation_rpc(self, product_repo):
        """2.6 triangulation: update() without min_stock in payload skips the RPC entirely."""
        repo, conn = product_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"name": "Nuevo nombre"})

        rpc_calls = [
            call for call in conn.fetchrow.call_args_list
            if "rpc_set_product_min_stock" in call.args[0]
        ]
        assert len(rpc_calls) == 0, "update() must not call the propagation RPC when min_stock is absent"

    @pytest.mark.asyncio
    async def test_update_with_min_stock_zero_calls_propagation_rpc(self, product_repo):
        """2.6 triangulation: min_stock=0 is a valid propagation value (does not break)."""
        repo, conn = product_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"min_stock": 0})

        rpc_calls = [
            call for call in conn.fetchrow.call_args_list
            if "rpc_set_product_min_stock" in call.args[0]
        ]
        assert len(rpc_calls) == 1, "update() must propagate min_stock=0 (falsy but explicit)"
        assert rpc_calls[0].args[2] == 0


class TestCreatePropagatesMinStock:
    """2.4/2.5: create() calls rpc_set_product_min_stock AFTER the initial stock delta."""

    @pytest.mark.asyncio
    async def test_create_with_min_stock_and_initial_stock_propagates_after_delta(self, product_repo):
        """RED→GREEN: create() propagates min_stock after _APPLY_STOCK_DELTA_SQL,
        so the just-created branch_stock row is seeded with min_stock."""
        repo, conn = product_repo
        call_order: list[str] = []

        async def fake_fetchrow(query: str, *args):
            if "INSERT INTO products" in query:
                call_order.append("insert_product")
                return {"id": PRODUCT_ID}
            if "rpc_apply_product_stock_delta" in query:
                call_order.append("stock_delta")
                return {"result": "ok"}
            if "rpc_set_product_min_stock" in query:
                call_order.append("min_stock_propagation")
                return {"result": "ok"}
            if "v_products_with_stock" in query:
                call_order.append("get_by_id")
                return VIEW_ROW
            raise AssertionError(f"Unexpected query: {query}")

        conn.fetchrow = AsyncMock(side_effect=fake_fetchrow)

        await repo.create(
            USER_ID, ACCOUNT_ID,
            {"name": "Producto nuevo", "min_stock": 3, "stock": Decimal("10")},
        )

        assert "min_stock_propagation" in call_order, (
            f"Expected rpc_set_product_min_stock to be called during create(), got order: {call_order}"
        )
        stock_delta_idx = call_order.index("stock_delta")
        propagation_idx = call_order.index("min_stock_propagation")
        assert propagation_idx > stock_delta_idx, (
            "Propagation must run AFTER the initial stock delta so the branch_stock row already exists"
        )

    @pytest.mark.asyncio
    async def test_create_without_initial_stock_still_propagates_min_stock(self, product_repo):
        """2.6 triangulation: a product created with stock=0 (no delta call) still
        gets min_stock propagated — the RPC handles the case of an existing/absent row."""
        repo, conn = product_repo
        call_order: list[str] = []

        async def fake_fetchrow(query: str, *args):
            if "INSERT INTO products" in query:
                call_order.append("insert_product")
                return {"id": PRODUCT_ID}
            if "rpc_apply_product_stock_delta" in query:
                call_order.append("stock_delta")
                return {"result": "ok"}
            if "rpc_set_product_min_stock" in query:
                call_order.append("min_stock_propagation")
                return {"result": "ok"}
            if "v_products_with_stock" in query:
                call_order.append("get_by_id")
                return VIEW_ROW
            raise AssertionError(f"Unexpected query: {query}")

        conn.fetchrow = AsyncMock(side_effect=fake_fetchrow)

        await repo.create(
            USER_ID, ACCOUNT_ID,
            {"name": "Producto sin stock inicial", "min_stock": 4, "stock": Decimal("0")},
        )

        assert "stock_delta" not in call_order, "stock=0 must not trigger the delta RPC"
        assert "min_stock_propagation" in call_order, (
            "create() must propagate min_stock even without an initial stock delta"
        )
