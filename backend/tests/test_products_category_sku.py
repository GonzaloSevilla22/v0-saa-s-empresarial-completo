"""
productos-categorias-sku — producto: category_id, SKU, tri-estado y lote
(tasks 9.2 RED, 9.8 TRIANGULATE, 9.10/9.11 RED, 9.14 TRIANGULATE).

Contrato D12 (tri-estado por AUSENCIA, nunca por `is None`) para `sku` y
`category_id`; SKU normalizado (trim, vacío → NULL); conflicto de SKU → 409
que nombra el SKU; variante hereda la categoría del padre resuelta en el
servidor; recategorización en lote (D14) como UN solo UPDATE filtrado por
account_id, con 404 para la categoría destino ajena/inactiva y tope 500.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CAT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
CAT_OTHER = "dddddddd-dddd-dddd-dddd-dddddddddddd"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
PARENT_ID = "33333333-3333-3333-3333-333333333333"

PRODUCT_ROW = {
    "id": PRODUCT_ID,
    "user_id": "11111111-1111-1111-1111-111111111111",
    "name": "Empanada",
    "category": "Alimentos",
    "category_id": CAT_ID,
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
CAT_ROW = {"id": CAT_ID, "account_id": ACCOUNT_ID, "name": "Alimentos", "is_active": True, "sort_order": 3, "created_at": "2026-09-03T00:00:00"}
PARENT_ROW = {**PRODUCT_ROW, "id": PARENT_ID, "name": "Zapatillas", "category": "Ropa", "category_id": CAT_OTHER, "sku": None}


def _owner() -> str:
    return make_token({"role": "user", "app_metadata": {"account_role": "owner"}})


def _plan_limits_row() -> dict:
    return {"max_products": 100, "max_clients": 50, "max_suppliers": 20}


def _update_sql(conn) -> str | None:
    for call in conn.execute.call_args_list:
        if "UPDATE products" in call.args[0]:
            return call.args[0]
    return None


def _update_args(conn) -> tuple:
    for call in conn.execute.call_args_list:
        if "UPDATE products" in call.args[0]:
            return call.args[1:]
    return ()


# ── 9.2 RED: tri-estado del SKU en PUT ────────────────────────────────────────

class TestUpdateSkuTriState:
    @pytest.mark.asyncio
    async def test_sku_absent_preserves(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"price": 200},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        sql = _update_sql(conn)
        assert sql is not None and "sku" not in sql
        assert "category_id" not in sql

    @pytest.mark.asyncio
    async def test_sku_null_clears(self, async_client, mock_pool):
        """Hoy imposible: model_dump(exclude_none) + filtro `is not None` en el
        repo (doble filtro, hallazgo del propose) tragaban el null."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "sku": None})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"sku": None},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        sql = _update_sql(conn)
        assert sql is not None and "sku = $" in sql
        assert None in _update_args(conn)

    @pytest.mark.asyncio
    async def test_sku_value_trimmed(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "sku": "rem-002"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"sku": "  rem-002  "},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        assert "rem-002" in _update_args(conn)
        assert "  rem-002  " not in _update_args(conn)

    @pytest.mark.asyncio
    async def test_sku_only_spaces_becomes_null(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "sku": None})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"sku": "   "},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        sql = _update_sql(conn)
        assert sql is not None and "sku = $" in sql
        assert None in _update_args(conn)

    @pytest.mark.asyncio
    async def test_other_fields_keep_exclude_none_behaviour(self, async_client, mock_pool):
        """No ampliar el alcance (9.4): `barcode: null` sigue sin tocar la columna."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"barcode": None, "price": 10},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        sql = _update_sql(conn)
        assert sql is not None and "barcode" not in sql


# ── 9.2 RED: tri-estado de category_id en PUT ────────────────────────────────

class TestUpdateCategoryTriState:
    @pytest.mark.asyncio
    async def test_category_null_unassigns_without_lookup(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "category_id": None})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"category_id": None},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        sql = _update_sql(conn)
        assert sql is not None and "category_id = $" in sql
        assert None in _update_args(conn)
        assert not any("product_categories" in c.args[0] for c in conn.fetchrow.call_args_list)

    @pytest.mark.asyncio
    async def test_category_valid_assigns(self, async_client, mock_pool):
        pool, conn = mock_pool

        async def fetchrow_side_effect(query, *args):
            if "product_categories" in query:
                return CAT_ROW
            return PRODUCT_ROW

        conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        assert resp.json()["category_id"] == CAT_ID
        assert CAT_ID in _update_args(conn)

    @pytest.mark.asyncio
    async def test_category_of_other_account_rejected_404_without_write(self, async_client, mock_pool):
        pool, conn = mock_pool

        async def fetchrow_side_effect(query, *args):
            if "product_categories" in query:
                return None
            return PRODUCT_ROW

        conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"category_id": CAT_OTHER},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 404
        assert _update_sql(conn) is None

    @pytest.mark.asyncio
    async def test_variant_edit_ignores_client_category(self, async_client, mock_pool):
        """9.7: la variante hereda del padre — un category_id del cliente sobre
        una variante se ignora (no se escribe, no se valida)."""
        pool, conn = mock_pool
        variant_row = {**PRODUCT_ROW, "parent_id": PARENT_ID, "is_variant": True}

        async def fetchrow_side_effect(query, *args):
            if "product_categories" in query:
                raise AssertionError("no debe validar categoría para una variante")
            return variant_row

        conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}", json={"category_id": CAT_OTHER, "price": 99},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        sql = _update_sql(conn)
        assert sql is not None and "category_id" not in sql


# ── 9.5/9.6/9.7 RED: alta — SKU normalizado, 409, herencia del padre ─────────

class TestCreateProductSkuAndCategory:
    def _side_effect(self, *, category=CAT_ROW, parent=PARENT_ROW, insert_raises=None):
        async def fetchrow_side_effect(query, *args):
            if "plan_limits" in query:
                return _plan_limits_row()
            if "COUNT" in query:
                return {"total": 5}
            if "product_categories" in query:
                return category
            if "INSERT INTO products" in query:
                if insert_raises is not None:
                    raise insert_raises
                return {"id": PRODUCT_ID}
            if f"WHERE id = $1" in query and args and args[0] == PARENT_ID:
                return parent
            return PRODUCT_ROW
        return fetchrow_side_effect

    def _insert_args(self, conn) -> tuple:
        for call in conn.fetchrow.call_args_list:
            if "INSERT INTO products" in call.args[0]:
                return call.args[1:]
        return ()

    @pytest.mark.asyncio
    async def test_create_sku_trimmed(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=self._side_effect())
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Empanada", "sku": "  EMP-001 ", "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 201
        args = self._insert_args(conn)
        assert "EMP-001" in args and "  EMP-001 " not in args
        assert CAT_ID in args

    @pytest.mark.asyncio
    async def test_create_without_sku_persists_null(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=self._side_effect())
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Empanada", "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 201
        args = self._insert_args(conn)
        # posición 9 = sku en el INSERT (user, account, name, category, category_id? → ver repo)
        assert None in args

    @pytest.mark.asyncio
    async def test_create_sku_only_spaces_is_null(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=self._side_effect())
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Empanada", "sku": "   "},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 201
        assert "   " not in self._insert_args(conn)

    @pytest.mark.asyncio
    async def test_create_duplicate_sku_returns_409_naming_sku(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=self._side_effect(insert_raises=_unique("idx_products_sku_account_lower")))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Empanada", "sku": "EMP-001"},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 409
        assert "EMP-001" in resp.json()["detail"]

    @pytest.mark.asyncio
    async def test_create_category_of_other_account_rejected(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=self._side_effect(category=None))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Empanada", "category_id": CAT_OTHER},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 404
        assert self._insert_args(conn) == ()

    @pytest.mark.asyncio
    async def test_variant_inherits_parent_category_ignoring_client(self, async_client, mock_pool):
        """9.7: el servidor resuelve la categoría desde el padre; lo que mande
        el cliente para una variante se ignora."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=self._side_effect())
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Zapatillas 41", "parent_id": PARENT_ID, "is_variant": True, "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 201
        args = self._insert_args(conn)
        assert CAT_OTHER in args   # la del padre
        assert CAT_ID not in args  # la del cliente, ignorada

    @pytest.mark.asyncio
    async def test_variant_with_unknown_parent_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=self._side_effect(parent=None))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Huérfana", "parent_id": PARENT_ID, "is_variant": True},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 404


def _unique(constraint: str) -> asyncpg.UniqueViolationError:
    err = asyncpg.UniqueViolationError("duplicate key value violates unique constraint")
    err.constraint_name = constraint  # asyncpg lo expone como atributo plano (PostgresMessage.new)
    return err


# ── 9.10 RED: repository de lote ──────────────────────────────────────────────

class TestBulkSetCategoryRepository:
    @pytest.fixture
    def repo(self):
        from backend.repositories.product_repository import ProductRepository

        conn = AsyncMock()
        return ProductRepository(conn), conn

    @pytest.mark.asyncio
    async def test_single_update_scoped_by_account_and_idempotent(self, repo):
        r, conn = repo
        conn.execute = AsyncMock(return_value="UPDATE 3")

        updated = await r.bulk_set_category([PRODUCT_ID, PARENT_ID], ACCOUNT_ID, CAT_ID)

        assert updated == 3
        assert conn.execute.await_count == 1
        sql = conn.execute.call_args.args[0]
        assert "UPDATE products" in sql
        assert "ANY($1" in sql
        assert "account_id = $2" in sql
        assert "IS DISTINCT FROM $3" in sql
        # D14: padre → variantes y variante suelta → su padre, en la MISMA sentencia
        assert "parent_id" in sql
        assert ACCOUNT_ID in conn.execute.call_args.args
        assert CAT_ID in conn.execute.call_args.args

    @pytest.mark.asyncio
    async def test_foreign_ids_produce_no_error(self, repo):
        r, conn = repo
        conn.execute = AsyncMock(return_value="UPDATE 0")

        assert await r.bulk_set_category([CAT_OTHER], ACCOUNT_ID, CAT_ID) == 0

    @pytest.mark.asyncio
    async def test_excludes_soft_deleted_products(self, repo):
        r, conn = repo
        conn.execute = AsyncMock(return_value="UPDATE 1")

        await r.bulk_set_category([PRODUCT_ID], ACCOUNT_ID, CAT_ID)

        assert "deleted_at IS NULL" in conn.execute.call_args.args[0]


# ── 9.11/9.13 RED: endpoint de lote ──────────────────────────────────────────

class TestBulkCategoryEndpoint:
    @pytest.mark.asyncio
    async def test_happy_path_returns_requested_and_updated(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CAT_ROW)
        conn.execute = AsyncMock(return_value="UPDATE 4")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/products/bulk-category",
                json={"product_ids": [PRODUCT_ID, PARENT_ID, PRODUCT_ID], "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        assert resp.json() == {"requested": 2, "updated": 4}
        assert "is_active = TRUE" in conn.fetchrow.call_args.args[0]

    @pytest.mark.asyncio
    async def test_target_inactive_or_foreign_returns_404_without_write(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=None)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/products/bulk-category",
                json={"product_ids": [PRODUCT_ID], "category_id": CAT_OTHER},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 404
        assert "otra cuenta" not in resp.json()["detail"].lower()
        assert not any("UPDATE products" in c.args[0] for c in conn.execute.call_args_list)

    @pytest.mark.asyncio
    async def test_idempotent_zero_updated_is_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CAT_ROW)
        conn.execute = AsyncMock(return_value="UPDATE 0")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/products/bulk-category",
                json={"product_ids": [PRODUCT_ID], "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        assert resp.json() == {"requested": 1, "updated": 0}

    @pytest.mark.asyncio
    async def test_over_cap_rejected_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        ids = [f"{i:08x}-0000-0000-0000-000000000000" for i in range(501)]
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/products/bulk-category",
                json={"product_ids": ids, "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_empty_list_rejected_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/products/bulk-category",
                json={"product_ids": [], "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_member_forbidden(self, async_client, mock_pool):
        pool, conn = mock_pool
        member = make_token({"role": "member"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/products/bulk-category",
                json={"product_ids": [PRODUCT_ID], "category_id": CAT_ID},
                headers={"Authorization": f"Bearer {member}"},
            )
        assert resp.status_code == 403


# ── ProductOut expone category_id (response_model filtra la salida) ──────────

class TestProductOutCarriesCategoryId:
    @pytest.mark.asyncio
    async def test_list_exposes_category_id(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[PRODUCT_ROW])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/products", headers={"Authorization": f"Bearer {valid_token}"})
        assert resp.status_code == 200
        assert resp.json()[0]["category_id"] == CAT_ID
