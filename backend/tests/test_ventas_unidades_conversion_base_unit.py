"""ventas-unidades-conversion (D10) — `base_unit_id` viaja de punta a punta.

Hallazgo del apply: `products.base_unit_id` no se exponía en
v_products_with_stock ni en ProductOut, y ProductCreate/ProductUpdate no la
aceptaban — el formulario la mandaba y el backend la descartaba en silencio.
Sin esto, la "unidad en que se lleva el stock" nunca llega al selector de
unidades ni a la normalización local del frontend.

  GET  /products        → la fila de la vista expone base_unit_id.
  POST /products        → se persiste; una unidad ajena/inexistente da 422.
  PUT  /products/{id}   → tri-estado por ausencia: omitida conserva, uuid
                          asigna, null desasigna (mismo molde que cost/sku).
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token

UNIT_KG = "0a0a0a0a-0a0a-4a0a-8a0a-0a0a0a0a0a0a"

PRODUCT_ROW = {
    "id": "22222222-2222-2222-2222-222222222222",
    "user_id": "11111111-1111-1111-1111-111111111111",
    "name": "Tomate",
    "category": "Verdulería",
    "category_id": None,
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
    "base_unit_id": UNIT_KG,
}


def _plan_limits_row() -> dict:
    return {"max_products": 100, "max_clients": 50, "max_suppliers": 20}


async def test_list_products_exposes_base_unit_id(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[PRODUCT_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/products", headers={"Authorization": f"Bearer {valid_token}"})
    assert resp.status_code == 200
    assert resp.json()[0]["base_unit_id"] == UNIT_KG


async def test_list_products_without_column_still_deserializes(async_client, valid_token, mock_pool):
    """Una fila de una base sin la migración (sin la columna) sigue saliendo: default None."""
    pool, conn = mock_pool
    row = {k: v for k, v in PRODUCT_ROW.items() if k != "base_unit_id"}
    conn.fetch = AsyncMock(return_value=[row])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/products", headers={"Authorization": f"Bearer {valid_token}"})
    assert resp.status_code == 200
    assert resp.json()[0]["base_unit_id"] is None


async def test_create_product_persists_base_unit_id(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    inserts: list[tuple] = []
    unit_checks: list[tuple] = []

    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row()
        if "COUNT" in query:
            return {"total": 5}
        if "FROM units_of_measure" in query:
            unit_checks.append(args)
            return {"?column?": 1}
        if "INSERT INTO products" in query:
            inserts.append(args)
            return {"id": PRODUCT_ROW["id"]}
        return PRODUCT_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products",
            json={"name": "Tomate", "base_unit_id": UNIT_KG},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201, resp.text
    assert len(inserts) == 1
    assert "base_unit_id" in inserts[0] or UNIT_KG in inserts[0]
    assert inserts[0][-1] == UNIT_KG  # último placeholder ($13) del INSERT
    # Auditoría post-apply: el guard de tenencia se consulta UNA vez y scopeado a
    # la cuenta del request (sistema O cuenta) — no basta con que exista.
    assert len(unit_checks) == 1
    assert unit_checks[0][0] == UNIT_KG
    assert str(unit_checks[0][1]) == str(TEST_ACCOUNT_ID)


async def test_create_product_rejects_unit_not_visible_to_account(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row()
        if "COUNT" in query:
            return {"total": 5}
        if "FROM units_of_measure" in query:
            return None  # ni del sistema ni de la cuenta
        return PRODUCT_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products",
            json={"name": "Tomate", "base_unit_id": UNIT_KG},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    assert "base_unit_not_found" in resp.text


async def test_update_product_base_unit_tristate(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    updates: list[tuple[str, tuple]] = []

    async def fetchrow_side_effect(query, *args):
        if "FROM units_of_measure" in query:
            return {"?column?": 1}
        return PRODUCT_ROW

    async def execute_side_effect(query, *args):
        updates.append((query, args))
        return "UPDATE 1"

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    conn.execute = AsyncMock(side_effect=execute_side_effect)
    conn.fetchval = AsyncMock(return_value=None)
    headers = {"Authorization": f"Bearer {owner_token}"}
    pid = PRODUCT_ROW["id"]

    with patch("backend.core.database.pool", pool):
        # (a) omitida → no aparece en el UPDATE
        resp = await async_client.put(f"/products/{pid}", json={"name": "Tomate perita"}, headers=headers)
        assert resp.status_code == 200, resp.text
        assert "base_unit_id" not in updates[-1][0]

        # (b) uuid → se asigna
        resp = await async_client.put(f"/products/{pid}", json={"base_unit_id": UNIT_KG}, headers=headers)
        assert resp.status_code == 200, resp.text
        assert "base_unit_id = $" in updates[-1][0]
        assert UNIT_KG in updates[-1][1]

        # (c) null explícito → se desasigna (viaja como None, no se filtra)
        resp = await async_client.put(f"/products/{pid}", json={"base_unit_id": None}, headers=headers)
        assert resp.status_code == 200, resp.text
        assert "base_unit_id = $" in updates[-1][0]
        assert None in updates[-1][1]
