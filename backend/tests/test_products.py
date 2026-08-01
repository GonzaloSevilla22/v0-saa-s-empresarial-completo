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


def _plan_limits_row(max_products: int = 100, max_clients: int = 50, max_suppliers: int = 20) -> dict:
    return {"max_products": max_products, "max_clients": max_clients, "max_suppliers": max_suppliers}


async def test_create_product_plan_gratis_over_limit(async_client, mock_pool):
    """Plan gratis is limited to 100 products (plan_limits); 101st should get 403."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "gratis"}})

    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row(max_products=100)
        if "COUNT" in query:
            return {"total": 100}
        return PRODUCT_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
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
        if "plan_limits" in query:
            return _plan_limits_row()
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


# ── billing-pro-trial (D5, task 6.1): límites leídos de plan_limits, no de una
# constante hardcodeada — RED: hoy PLAN_PRODUCT_LIMITS['avanzado']=2000 en
# código difería de plan_limits.max_products=1500 en la DB. ───────────────────


async def test_create_product_plan_avanzado_uses_plan_limits_not_hardcoded(async_client, mock_pool):
    """El límite aplicado para 'avanzado' es el de plan_limits (2000 tras la
    migración de este change), no un valor embebido en el backend."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "avanzado"}})

    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            assert args == ("avanzado",)
            return _plan_limits_row(max_products=2000)
        if "COUNT" in query:
            return {"total": 1999}
        return PRODUCT_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products",
            json={"name": "Producto 2000"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201


async def test_create_product_plan_avanzado_blocked_at_plan_limits_value(async_client, mock_pool):
    """Con 2000 productos y el límite de plan_limits en 2000, el 2001º se
    rechaza — prueba que el límite NO es 999999 (fail-open del dict viejo)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "avanzado"}})

    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row(max_products=2000)
        if "COUNT" in query:
            return {"total": 2000}
        return PRODUCT_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products",
            json={"name": "Producto 2001"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 403


# ── v3-soft-delete-policy (5.2): borrado soft + guard RN-B4 + lecturas ───────


async def test_delete_product_is_soft_delete(async_client, mock_pool):
    """DELETE /products/{id} responde 204 y emite UPDATE ... deleted_at (soft),
    nunca un DELETE físico. deleted_by = usuario autenticado (5.6)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)  # get_by_id del service
    conn.execute = AsyncMock(return_value="UPDATE 1")

    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/products/{PRODUCT_ROW['id']}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )

    assert resp.status_code == 204
    sql = conn.execute.call_args.args[0]
    assert "UPDATE products" in sql
    assert "deleted_at = now()" in sql
    assert "DELETE FROM" not in sql
    assert "11111111-1111-1111-1111-111111111111" in conn.execute.call_args.args


async def test_delete_product_with_stock_returns_409(async_client, mock_pool):
    """El guard RN-B4 (ERRCODE P0B04) se traduce a HTTP 409 con mensaje en
    español (D3) — el borrado con stock/draft es rechazado."""
    import asyncpg as _asyncpg

    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
    err = _asyncpg.exceptions.RaiseError(
        'RN-B4: el producto "Empanada" tiene stock (10) — ajustá el stock a 0 antes de borrarlo'
    )
    err.sqlstate = "P0B04"

    async def execute_side_effect(query, *args):
        # Solo el UPDATE del soft delete dispara el guard — el resto de los
        # execute (inyeccion de claims JWT de get_db_conn) pasa normal.
        if "UPDATE products" in query:
            raise err
        return "SET"

    conn.execute = AsyncMock(side_effect=execute_side_effect)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/products/{PRODUCT_ROW['id']}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )

    assert resp.status_code == 409
    assert "stock" in resp.json()["detail"]


async def test_delete_product_other_pg_errors_not_swallowed(async_client, mock_pool):
    """TRIANGULATE: un PostgresError ajeno al guard NO se mapea a 409."""
    import asyncpg as _asyncpg

    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
    err = _asyncpg.exceptions.RaiseError("otro error")
    err.sqlstate = "P0001"

    async def execute_side_effect(query, *args):
        if "UPDATE products" in query:
            raise err
        return "SET"

    conn.execute = AsyncMock(side_effect=execute_side_effect)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/products/{PRODUCT_ROW['id']}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )

    assert resp.status_code == 500


async def test_list_products_excludes_soft_deleted(async_client, valid_token, mock_pool):
    """El listado (vía v_products_with_stock) filtra deleted_at IS NULL (RN-B1)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[PRODUCT_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/products", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert "deleted_at IS NULL" in conn.fetch.call_args.args[0]


async def test_product_count_for_plan_limit_excludes_soft_deleted(async_client, mock_pool):
    """El contador del límite de plan no cuenta productos borrados — borrar
    libera cupo del plan."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    count_sql = {}

    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row()
        if "COUNT" in query:
            count_sql["sql"] = query
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
    assert "deleted_at IS NULL" in count_sql["sql"]


# ── v31-authz-token-hook (task 7.4-7.6, D6/D3) ───────────────────────────────
# 7.4 ("un JWT con plan='gratis' sobre una cuenta que ya alcanzó el límite del
# plan gratis recibe 403 al crear un producto") ya está cubierta por
# test_create_product_plan_gratis_over_limit (arriba, billing-pro-trial D5):
# el enforcement con el claim `plan` PRESENTE ya lee plan_limits en runtime,
# no un default de 999.999 — no hay una regresión nueva que reproducir acá.
# El residuo real de D6/7.6 es el COMPLEMENTO: los productos EXISTENTES por
# encima del límite (creados antes de que el enforcement empezara a morder,
# o durante la ventana de trial) siguen siendo legibles y editables — solo
# se impide CREAR. GET/PUT no consultan plan_limits en absoluto.


async def test_get_product_ok_even_when_account_over_plan_limit(async_client, valid_token, mock_pool):
    """TRIANGULATE (7.5): leer un producto existente funciona igual sin
    importar si la cuenta está por encima del límite de su plan — GET no
    consulta plan_limits (solo CREATE la enforcea)."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/products/{PRODUCT_ROW['id']}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )

    assert resp.status_code == 200
    sql = conn.fetchrow.call_args.args[0]
    assert "plan_limits" not in sql


async def test_update_product_ok_even_when_account_over_plan_limit(async_client, mock_pool):
    """TRIANGULATE (7.5): editar un producto existente funciona igual sin
    importar el límite del plan — PUT no consulta plan_limits, solo CREATE."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "name": "Empanada Grande"})

    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/products/{PRODUCT_ROW['id']}",
            json={"name": "Empanada Grande"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )

    assert resp.status_code == 200
    assert resp.json()["name"] == "Empanada Grande"
    sql = conn.fetchrow.call_args.args[0]
    assert "plan_limits" not in sql
