"""
C-21 checkpoint #2 — single-write branch_stock (TDD).

products.stock no existe más: el stock vive SOLO en branch_stock.
  - ProductRepository.create: INSERT sin stock; stock inicial via
    rpc_apply_product_stock_delta; retorna fila de v_products_with_stock.
  - ProductRepository.update: 'stock' se redirige al RPC como delta
    (target − Σ actual); nunca entra al UPDATE de products.
  - ProductRepository.search_by_sku/barcode: leen de v_products_with_stock.
  - PurchaseRepository.delete_*: la reversa de stock va al RPC (delta negativo,
    allow_negative, sin movement) en vez de UPDATE products.
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "11111111-1111-1111-1111-111111111111"
PURCHASE_ID = "33333333-3333-3333-3333-333333333333"

VIEW_ROW = {
    "id": PRODUCT_ID,
    "account_id": ACCOUNT_ID,
    "user_id": USER_ID,
    "name": "Reel Fly Limay",
    "category": "Pesca",
    "price": "15000.0000",
    "cost": "8000.0000",
    "stock": "15.0000",
    "min_stock": 2,
    "barcode": None,
    "sku": "RFL-001",
    "parent_id": None,
    "is_variant": False,
    "stock_control_type": "tracked",
    "created_at": "2024-01-01T08:00:00",
    "deleted_at": None,
}

RPC_NAME = "rpc_apply_product_stock_delta"


def _strip_stock_lookalikes(query: str) -> str:
    """Remove identifiers that contain 'stock' but are not the dropped column."""
    return (
        query.lower()
        .replace("v_products_with_stock", "VIEW")
        .replace("min_stock", "MS")
        .replace("stock_control_type", "SCT")
        .replace("branch_stock", "BS")
        .replace("stock_movements", "SM")
        .replace(RPC_NAME, "RPC")
    )


def _mock_tx(conn) -> None:
    ctx = AsyncMock()
    ctx.__aenter__ = AsyncMock(return_value=None)
    ctx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=ctx)


def _rpc_calls(conn_method) -> list:
    return [c for c in conn_method.call_args_list if RPC_NAME in c[0][0]]


@pytest.fixture
def product_repo():
    from backend.repositories.product_repository import ProductRepository

    conn = AsyncMock()
    _mock_tx(conn)
    return ProductRepository(conn), conn


@pytest.fixture
def purchase_repo():
    from backend.repositories.purchase_repository import PurchaseRepository

    conn = AsyncMock()
    _mock_tx(conn)
    return PurchaseRepository(conn), conn


class TestProductCreateSingleWrite:
    @pytest.mark.asyncio
    async def test_create_insert_does_not_write_stock_column(self, product_repo):
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(side_effect=[{"id": PRODUCT_ID}, VIEW_ROW])

        await repo.create(USER_ID, ACCOUNT_ID, {"name": "X", "stock": Decimal("0")})

        insert_query = conn.fetchrow.call_args_list[0][0][0]
        assert "insert into products" in insert_query.lower()
        assert "stock" not in _strip_stock_lookalikes(insert_query), (
            f"INSERT must not reference the dropped products.stock column: {insert_query}"
        )

    @pytest.mark.asyncio
    async def test_create_with_initial_stock_calls_rpc(self, product_repo):
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(
            side_effect=[{"id": PRODUCT_ID}, {"quantity_after": "25"}, VIEW_ROW]
        )

        await repo.create(USER_ID, ACCOUNT_ID, {"name": "X", "stock": Decimal("25")})

        rpc_calls = _rpc_calls(conn.fetchrow)
        assert len(rpc_calls) == 1, "Initial stock > 0 must call rpc_apply_product_stock_delta"
        assert Decimal("25") in rpc_calls[0][0], "RPC must receive the initial stock as delta"

    @pytest.mark.asyncio
    async def test_create_zero_stock_skips_rpc(self, product_repo):
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(side_effect=[{"id": PRODUCT_ID}, VIEW_ROW])

        await repo.create(USER_ID, ACCOUNT_ID, {"name": "X", "stock": Decimal("0")})

        assert _rpc_calls(conn.fetchrow) == [], "stock=0 must not call the RPC"

    @pytest.mark.asyncio
    async def test_create_returns_view_row(self, product_repo):
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(side_effect=[{"id": PRODUCT_ID}, VIEW_ROW])

        result = await repo.create(USER_ID, ACCOUNT_ID, {"name": "X"})

        assert result == VIEW_ROW
        final_query = conn.fetchrow.call_args_list[-1][0][0].lower()
        assert "v_products_with_stock" in final_query, (
            "create must return the row from the view (ProductOut requires stock)"
        )


class TestProductUpdateStockRedirect:
    @pytest.mark.asyncio
    async def test_update_excludes_stock_from_products_update(self, product_repo):
        repo, conn = product_repo
        conn.fetchval = AsyncMock(return_value=Decimal("12"))
        conn.fetchrow = AsyncMock(side_effect=[{"quantity_after": "30"}, VIEW_ROW])

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"name": "N", "stock": Decimal("30")})

        update_calls = [
            c for c in conn.execute.call_args_list if "update products" in c[0][0].lower()
        ]
        assert len(update_calls) == 1
        assert "stock" not in _strip_stock_lookalikes(update_calls[0][0][0]), (
            "UPDATE products must not reference the dropped stock column"
        )

    @pytest.mark.asyncio
    async def test_update_stock_calls_rpc_with_delta(self, product_repo):
        repo, conn = product_repo
        conn.fetchval = AsyncMock(return_value=Decimal("12"))
        conn.fetchrow = AsyncMock(side_effect=[{"quantity_after": "30"}, VIEW_ROW])

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"stock": Decimal("30")})

        rpc_calls = _rpc_calls(conn.fetchrow)
        assert len(rpc_calls) == 1
        assert Decimal("18") in rpc_calls[0][0], (
            "delta must be target − Σ actual (30 − 12 = 18)"
        )

    @pytest.mark.asyncio
    async def test_update_stock_equal_to_sum_skips_rpc(self, product_repo):
        repo, conn = product_repo
        conn.fetchval = AsyncMock(return_value=Decimal("30"))
        conn.fetchrow = AsyncMock(side_effect=[VIEW_ROW])

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"stock": Decimal("30")})

        assert _rpc_calls(conn.fetchrow) == [], "delta 0 must not call the RPC"

    @pytest.mark.asyncio
    async def test_update_without_stock_unchanged_behavior(self, product_repo):
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(side_effect=[VIEW_ROW])

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"name": "Nuevo"})

        update_calls = [
            c for c in conn.execute.call_args_list if "update products" in c[0][0].lower()
        ]
        assert len(update_calls) == 1
        assert _rpc_calls(conn.fetchrow) == []


class TestProductSearchUsesView:
    @pytest.mark.asyncio
    async def test_search_by_sku_queries_view(self, product_repo):
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.search_by_sku("RFL-001", ACCOUNT_ID)

        assert "v_products_with_stock" in conn.fetchrow.call_args[0][0].lower(), (
            "search_by_sku must read from the view (ProductOut requires stock)"
        )

    @pytest.mark.asyncio
    async def test_search_by_barcode_queries_view(self, product_repo):
        repo, conn = product_repo
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.search_by_barcode("779123", ACCOUNT_ID)

        assert "v_products_with_stock" in conn.fetchrow.call_args[0][0].lower()


class TestPurchaseDeleteRevertsBranchStock:
    @pytest.mark.asyncio
    async def test_delete_by_id_reverts_via_rpc(self, purchase_repo):
        repo, conn = purchase_repo
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"id": PURCHASE_ID, "operation_id": None},          # header
                {"product_id": PRODUCT_ID, "quantity_delta": Decimal("5"), "branch_id": None},  # stock_movement
                {"quantity_after": "0"},                             # RPC result
            ]
        )

        ok = await repo.delete_by_id(PURCHASE_ID, ACCOUNT_ID)

        assert ok is True
        bad = [c for c in conn.execute.call_args_list if "update products" in c[0][0].lower()]
        assert bad == [], "delete must not UPDATE products (stock column dropped)"
        rpc_calls = _rpc_calls(conn.fetchrow)
        assert len(rpc_calls) == 1
        assert Decimal("-5") in rpc_calls[0][0], "revert delta must be −quantity_delta"

    @pytest.mark.asyncio
    async def test_delete_by_id_without_movement_skips_rpc(self, purchase_repo):
        repo, conn = purchase_repo
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"id": PURCHASE_ID, "operation_id": None},
                None,  # no stock_movement registered → sin reversa
            ]
        )

        ok = await repo.delete_by_id(PURCHASE_ID, ACCOUNT_ID)

        assert ok is True
        assert _rpc_calls(conn.fetchrow) == []

    @pytest.mark.asyncio
    async def test_delete_by_operation_reverts_via_rpc(self, purchase_repo):
        repo, conn = purchase_repo
        conn.fetch = AsyncMock(return_value=[{"id": PURCHASE_ID}])
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"product_id": PRODUCT_ID, "quantity_delta": Decimal("3"), "branch_id": None},  # stock_movement
                {"quantity_after": "0"},                             # RPC result
            ]
        )

        ok = await repo.delete_by_operation("44444444-4444-4444-4444-444444444444", ACCOUNT_ID)

        assert ok is True
        bad = [c for c in conn.execute.call_args_list if "update products" in c[0][0].lower()]
        assert bad == [], "delete must not UPDATE products (stock column dropped)"
        rpc_calls = _rpc_calls(conn.fetchrow)
        assert len(rpc_calls) == 1
        assert Decimal("-3") in rpc_calls[0][0]
