"""
productos-categorias-sku — Router TDD tests (tasks 8.5 GREEN, 8.6 TRIANGULATE).

Espejo de test_payment_method_router.py: endpoints /product-categories vía
async_client con el pool asyncpg mockeado.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import account_roles_fetchval, make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CAT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

CAT_ROW = {
    "id": CAT_ID,
    "account_id": ACCOUNT_ID,
    "name": "Ropa",
    "is_active": True,
    "sort_order": 2,
    "created_at": "2026-09-03T10:00:00+00:00",
}
CAT_ROW_INACTIVE = {**CAT_ROW, "is_active": False}


def _account_role_token(account_role: str) -> str:
    return make_token({"app_metadata": {"account_role": account_role}})


class TestProductCategoryListEndpoint:
    @pytest.mark.asyncio
    async def test_get_list_ok_for_member(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["member"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetch = AsyncMock(return_value=[CAT_ROW])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/product-categories", headers={"Authorization": f"Bearer {_account_role_token('member')}"}
            )

        assert resp.status_code == 200
        data = resp.json()
        assert data[0]["name"] == "Ropa"
        assert data[0]["sort_order"] == 2
        assert "kind" not in data[0]

    @pytest.mark.asyncio
    async def test_get_list_include_inactive(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetch = AsyncMock(return_value=[CAT_ROW, CAT_ROW_INACTIVE])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/product-categories?include_inactive=true",
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 200
        assert len(resp.json()) == 2
        assert "is_active = TRUE" not in conn.fetch.call_args[0][0]

    @pytest.mark.asyncio
    async def test_get_list_unauthenticated_returns_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/product-categories")
        assert resp.status_code == 401


class TestProductCategoryCreateEndpoint:
    @pytest.mark.asyncio
    async def test_create_owner_returns_201(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetchrow = AsyncMock(return_value=CAT_ROW)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/product-categories", json={"name": "Ropa"},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 201
        assert resp.json()["name"] == "Ropa"
        assert resp.json()["is_active"] is True

    @pytest.mark.asyncio
    async def test_create_member_returns_403_rfc7807(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["member"])  # D12: la base reporta el mismo rol que declara el token
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/product-categories", json={"name": "Ferretería"},
                headers={"Authorization": f"Bearer {_account_role_token('member')}"},
            )

        assert resp.status_code == 403
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["status"] == 403
        conn.fetchrow.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_create_missing_name_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/product-categories", json={"sort_order": 3},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_create_duplicate_returns_409(self, async_client, mock_pool):
        import asyncpg as _asyncpg

        pool, conn = mock_pool

        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetchrow = AsyncMock(side_effect=_asyncpg.UniqueViolationError("dup"))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/product-categories", json={"name": "ropa"},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 409
        assert "ropa" in resp.json()["detail"].lower()


class TestProductCategoryUpdateEndpoint:
    @pytest.mark.asyncio
    async def test_patch_rename_owner_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetchrow = AsyncMock(return_value={**CAT_ROW, "name": "Indumentaria"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/product-categories/{CAT_ID}", json={"name": "Indumentaria"},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 200
        assert resp.json()["name"] == "Indumentaria"

    @pytest.mark.asyncio
    async def test_patch_reorder_only(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["admin"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetchrow = AsyncMock(return_value={**CAT_ROW, "sort_order": 9})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/product-categories/{CAT_ID}", json={"sort_order": 9},
                headers={"Authorization": f"Bearer {_account_role_token('admin')}"},
            )

        assert resp.status_code == 200
        assert resp.json()["sort_order"] == 9

    @pytest.mark.asyncio
    async def test_patch_member_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["member"])  # D12: la base reporta el mismo rol que declara el token
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/product-categories/{CAT_ID}", json={"name": "X"},
                headers={"Authorization": f"Bearer {_account_role_token('member')}"},
            )
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_patch_other_account_returns_404(self, async_client, mock_pool):
        """TRIANGULATE 8.6: categoría de otra cuenta → 404 sin revelar existencia."""
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetchrow = AsyncMock(return_value=None)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/product-categories/{CAT_ID}", json={"name": "X"},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 404
        assert resp.json()["title"] == "No encontrado"


class TestProductCategoryDeactivateDeleteEndpoints:
    @pytest.mark.asyncio
    async def test_deactivate_owner_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.fetchrow = AsyncMock(return_value=CAT_ROW_INACTIVE)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/product-categories/{CAT_ID}/deactivate",
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 200
        assert resp.json()["is_active"] is False

    @pytest.mark.asyncio
    async def test_deactivate_member_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["member"])  # D12: la base reporta el mismo rol que declara el token
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/product-categories/{CAT_ID}/deactivate",
                headers={"Authorization": f"Bearer {_account_role_token('member')}"},
            )
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_delete_owner_soft_deletes_204(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.execute = AsyncMock(return_value="UPDATE 1")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/product-categories/{CAT_ID}",
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 204
        sql = conn.execute.call_args.args[0]
        assert "UPDATE product_categories" in sql
        assert "deleted_at = now()" in sql
        assert "DELETE FROM" not in sql

    @pytest.mark.asyncio
    async def test_delete_not_found_returns_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])  # D12: la base reporta el mismo rol que declara el token
        conn.execute = AsyncMock(return_value="UPDATE 0")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/product-categories/{CAT_ID}",
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 404


class TestProductCategoryDefaultEndpoints:
    @pytest.mark.asyncio
    async def test_get_default_ok_for_member(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=CAT_ID)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/product-categories/default",
                headers={"Authorization": f"Bearer {_account_role_token('member')}"},
            )

        assert resp.status_code == 200
        assert resp.json()["default_category_id"] == CAT_ID

    @pytest.mark.asyncio
    async def test_get_default_null_when_unconfigured(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=None)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/product-categories/default",
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 200
        assert resp.json()["default_category_id"] is None

    @pytest.mark.asyncio
    async def test_patch_default_owner_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        # F5 (revisor adversarial): el service escribe (rpc_set_default_product_category,
        # resultado descartado) y RELEE (get_default_category_id) — la RELECTURA es la
        # que decide la respuesta del PATCH.
        # D12: el guard suma una consulta propia (`rpc_my_active_account_roles`) ANTES
        # de las dos del service, así que el doble despacha por consulta en vez de por
        # posición — atar el test al orden lo volvía frágil sin ganar nada.
        conn.fetchval = account_roles_fetchval(["owner"], otherwise=[None, CAT_ID])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/product-categories/default",
                json={"default_category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 200
        assert resp.json()["default_category_id"] == CAT_ID
        service_sql = [
            call.args[0].lower()
            for call in conn.fetchval.call_args_list
            if "rpc_my_active_account_roles" not in call.args[0]
        ]
        assert len(service_sql) == 2, "el service escribe y relee"
        assert "rpc_set_default_product_category" in service_sql[0]

    @pytest.mark.asyncio
    async def test_patch_default_null_clears(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["admin"], otherwise=None)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/product-categories/default",
                json={"default_category_id": None},
                headers={"Authorization": f"Bearer {_account_role_token('admin')}"},
            )

        assert resp.status_code == 200
        assert resp.json()["default_category_id"] is None

    @pytest.mark.asyncio
    async def test_patch_default_member_returns_403_rfc7807(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["member"], otherwise=None)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/product-categories/default",
                json={"default_category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_account_role_token('member')}"},
            )

        assert resp.status_code == 403
        assert resp.headers["content-type"].startswith("application/problem+json")
        # D12: el guard SÍ consulta la base ahora (es el punto del change), así
        # que "no tocó la conexión" dejó de ser la forma de decir "el service
        # nunca corrió". Se assertea lo que de verdad importa: la única
        # consulta emitida fue la del guard, ninguna escritura llegó a la base.
        emitted = [call.args[0] for call in conn.fetchval.call_args_list]
        assert len(emitted) == 1
        assert "rpc_my_active_account_roles" in emitted[0]

    @pytest.mark.asyncio
    async def test_patch_default_p0404_maps_to_404(self, async_client, mock_pool):
        import asyncpg as _asyncpg

        pool, conn = mock_pool
        err = _asyncpg.exceptions.RaiseError("product_category_not_found")
        err.sqlstate = "P0404"
        conn.fetchval = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/product-categories/default",
                json={"default_category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 404

    @pytest.mark.asyncio
    async def test_patch_default_p0401_maps_to_403(self, async_client, mock_pool):
        import asyncpg as _asyncpg

        pool, conn = mock_pool
        err = _asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetchval = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/product-categories/default",
                json={"default_category_id": CAT_ID},
                headers={"Authorization": f"Bearer {_account_role_token('owner')}"},
            )

        assert resp.status_code == 403
