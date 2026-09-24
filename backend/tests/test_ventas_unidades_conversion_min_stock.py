"""ventas-unidades-conversion (D7) — el umbral de stock mínimo es fraccionario.

branch_stock.min_stock pasa a numeric(15,4) (20261061000001) y
rpc_set_product_min_stock a (uuid, numeric). El backend deja de tipar el
umbral como `int`: un "avisar cuando queden 0,5 kg" viajaba como 0 (int(0.5))
o era rechazado con 422 antes de llegar a la RPC.

  3.1  ProductCreate / ProductUpdate aceptan Decimal("0.5"), rechazan negativo.
  3.1  _propagate_min_stock manda Decimal (no int) y el SQL castea a numeric.
  3.1  create() y update() propagan el valor fraccionario SIN truncarlo.
  Triangulación: el entero sigue siendo entero (5 → Decimal("5")).
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest
from pydantic import ValidationError

from backend.repositories import product_repository as pr_module
from backend.schemas.products import ProductCreate, ProductUpdate

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "11111111-1111-1111-1111-111111111111"

VIEW_ROW = {
    "id": PRODUCT_ID,
    "account_id": ACCOUNT_ID,
    "user_id": USER_ID,
    "name": "Tomate",
    "category": "Verdulería",
    "price": "1000.0000",
    "cost": "600.0000",
    "stock": "0.5500",
    "min_stock": "0.5000",
    "barcode": None,
    "sku": "TOM-001",
    "parent_id": None,
    "is_variant": False,
    "stock_control_type": "tracked",
    "created_at": "2024-01-01T08:00:00",
    "deleted_at": None,
}


def _make_transaction_cm():
    cm = MagicMock()
    cm.__aenter__ = AsyncMock(return_value=None)
    cm.__aexit__ = AsyncMock(return_value=False)
    return cm


@pytest.fixture
def product_repo():
    conn = AsyncMock()
    conn.transaction = MagicMock(return_value=_make_transaction_cm())
    return pr_module.ProductRepository(conn), conn


# ── Esquemas ────────────────────────────────────────────────────────────────

class TestSchemasAcceptFractionalMinStock:
    def test_create_accepts_half_kilo(self):
        p = ProductCreate(name="Tomate", min_stock=Decimal("0.5"))
        assert p.min_stock == Decimal("0.5")

    def test_create_accepts_string_half_kilo_from_json(self):
        p = ProductCreate.model_validate({"name": "Tomate", "min_stock": "0.5"})
        assert p.min_stock == Decimal("0.5")

    def test_create_default_is_zero(self):
        assert ProductCreate(name="Tomate").min_stock == Decimal("0")

    def test_create_rejects_negative(self):
        with pytest.raises(ValidationError):
            ProductCreate(name="Tomate", min_stock=Decimal("-1"))

    def test_update_accepts_fractional_and_rejects_negative(self):
        assert ProductUpdate(min_stock=Decimal("0.25")).min_stock == Decimal("0.25")
        assert ProductUpdate().min_stock is None
        with pytest.raises(ValidationError):
            ProductUpdate(min_stock=Decimal("-0.01"))

    def test_integer_stays_integer_valued(self):
        """Triangulación: un producto por unidad no cambia de aspecto."""
        assert ProductCreate(name="Huevo", min_stock=5).min_stock == Decimal("5")


# ── Repository ──────────────────────────────────────────────────────────────

class TestRepositoryPropagatesDecimal:
    def test_propagation_sql_casts_to_numeric_not_int(self):
        assert "::numeric" in pr_module._SET_MIN_STOCK_SQL
        assert "::int" not in pr_module._SET_MIN_STOCK_SQL

    @pytest.mark.asyncio
    async def test_update_propagates_half_kilo_without_truncation(self, product_repo):
        repo, conn = product_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"min_stock": Decimal("0.5")})

        rpc_calls = [c for c in conn.fetchrow.call_args_list if "rpc_set_product_min_stock" in c.args[0]]
        assert len(rpc_calls) == 1
        assert rpc_calls[0].args[1] == PRODUCT_ID
        assert isinstance(rpc_calls[0].args[2], Decimal)
        assert rpc_calls[0].args[2] == Decimal("0.5")

    @pytest.mark.asyncio
    async def test_create_propagates_half_kilo_as_decimal(self, product_repo):
        repo, conn = product_repo
        seen: dict[str, object] = {}

        async def fake_fetchrow(query: str, *args):
            if "INSERT INTO products" in query:
                seen["insert_min_stock"] = args[5]
                return {"id": PRODUCT_ID}
            if "rpc_apply_product_stock_delta" in query:
                return {"result": "ok"}
            if "rpc_set_product_min_stock" in query:
                seen["rpc_min_stock"] = args[1]
                return {"result": "ok"}
            if "v_products_with_stock" in query:
                return VIEW_ROW
            raise AssertionError(f"Unexpected query: {query}")

        conn.fetchrow = AsyncMock(side_effect=fake_fetchrow)

        await repo.create(
            USER_ID, ACCOUNT_ID,
            {"name": "Tomate", "min_stock": Decimal("0.5"), "stock": Decimal("1")},
        )

        assert seen["insert_min_stock"] == Decimal("0.5")
        assert isinstance(seen["rpc_min_stock"], Decimal)
        assert seen["rpc_min_stock"] == Decimal("0.5")

    @pytest.mark.asyncio
    async def test_update_integer_min_stock_still_integer_valued(self, product_repo):
        repo, conn = product_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")
        conn.fetchrow = AsyncMock(return_value=VIEW_ROW)

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"min_stock": 5})

        rpc_calls = [c for c in conn.fetchrow.call_args_list if "rpc_set_product_min_stock" in c.args[0]]
        assert rpc_calls[0].args[2] == Decimal("5")
