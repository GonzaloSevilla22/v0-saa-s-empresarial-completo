from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

OPERATION_ROW = {
    "operation_id": "66666666-6666-6666-6666-666666666666",
    "operation_kind": "sale",
}

SALE_PAYLOAD = {
    "idempotency_key": "key-abc-123",
    "org_id": "org-uuid-1",
    "items": [
        {"product_id": "prod-uuid-1", "quantity": "2.0000", "amount": "300.00"}
    ],
}


async def test_create_sale_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["operation_id"] == "66666666-6666-6666-6666-666666666666"


async def test_create_sale_idempotent(async_client, mock_pool):
    """Duplicate idempotency_key returns existing operation (HTTP 201 with same data)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=OPERATION_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["operation_id"] == "66666666-6666-6666-6666-666666666666"


async def test_create_sale_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_create_sale_passes_canal_to_rpc(async_client, mock_pool):
    """El canal del payload llega como argumento del RPC rpc_create_sale_operation."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json={**SALE_PAYLOAD, "canal": "instagram"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert "rpc_create_sale_operation" in captured["query"]
    assert "instagram" in captured["args"]


async def test_create_sale_without_canal_passes_none(async_client, mock_pool):
    """Sin canal en el payload, el RPC recibe NULL (ventas legacy = 'Sin canal')."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert None in captured["args"][-1:]  # último arg = canal None


SALE_ID = "11111111-1111-1111-1111-111111111111"
OPERATION_ID = "66666666-6666-6666-6666-666666666666"

UPDATE_PAYLOAD = {
    "sale_ids": [SALE_ID],
    "client_id": None,
    "date": "2024-01-15",
    "currency": "ARS",
    "items": [{"product_id": "prod-uuid-1", "quantity": "1.0", "amount": "100.00"}],
}


async def test_delete_sale_ok(async_client, mock_pool):
    """DELETE /sales/{id} elimina una venta simple → 204."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    async def fetchrow_side_effect(query, *args):
        # Header de la venta encontrado; sin product_id en sale_items → sin stock.
        if "FROM sales WHERE id" in query:
            return {"id": SALE_ID, "operation_id": None}
        return None

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204


async def test_delete_sale_not_found(async_client, mock_pool):
    """Venta inexistente (o de otra org, vía RLS) → 404."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 404


async def test_delete_sale_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_delete_sales_by_operation_ok(async_client, mock_pool):
    """DELETE /sales?operation_id= elimina toda la operación agrupada → 204."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetch = AsyncMock(return_value=[{"id": SALE_ID}])
    conn.fetchrow = AsyncMock(return_value=None)  # sin product_id → sin reversa de stock
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales?operation_id={OPERATION_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204


async def test_delete_sales_by_operation_not_found(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales?operation_id={OPERATION_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 404


BRANCH_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"


async def test_delete_sale_c29_path_restores_stock(async_client, mock_pool):
    """Ruta C-29/POS: hay stock_movements pero NO hay sale_items.
    El borrado DEBE reponer stock vía rpc_apply_product_stock_delta."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []

    async def fetchrow_side_effect(query, *args):
        if "rpc_apply_product_stock_delta" in query:
            reversal_calls.append(args)
            return {"rpc_apply_product_stock_delta": None}
        if "FROM sales WHERE id" in query:
            return {"id": SALE_ID, "operation_id": None}
        if "FROM stock_movements" in query:
            return {
                "product_id": "prod-uuid-1",
                "quantity_delta": -2,
                "branch_id": BRANCH_ID,
            }
        if "FROM sale_items" in query:
            return None  # C-29 no escribe sale_items
        return None

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 1, "la reversa de stock no se ejecutó"
    product_id, delta, branch_id = reversal_calls[0]
    assert product_id == "prod-uuid-1"
    assert delta == 2  # signo opuesto a quantity_delta = -2
    assert branch_id == BRANCH_ID


async def test_delete_sale_v2_path_still_restores_stock(async_client, mock_pool):
    """Paridad: venta con stock_movements (ruta v2) sigue reponiendo stock.
    Triangulación con inputs distintos (delta -1, otra branch)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []
    deleted_movements: list = []

    async def fetchrow_side_effect(query, *args):
        if "rpc_apply_product_stock_delta" in query:
            reversal_calls.append(args)
            return {"rpc_apply_product_stock_delta": None}
        if "FROM sales WHERE id" in query:
            return {"id": SALE_ID, "operation_id": None}
        if "FROM stock_movements" in query:
            return {
                "product_id": "prod-uuid-9",
                "quantity_delta": -1,
                "branch_id": None,
            }
        return None

    async def execute_side_effect(query, *args):
        if "DELETE FROM stock_movements" in query:
            deleted_movements.append(args)
        return "DELETE 1"

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 1
    assert reversal_calls[0][0] == "prod-uuid-9"
    assert reversal_calls[0][1] == 1  # -(-1)
    # la fila de stock_movements no debe quedar huérfana
    assert len(deleted_movements) == 1


async def test_delete_sales_by_operation_restores_stock(async_client, mock_pool):
    """delete_by_operation repone el stock de cada línea en su propia branch."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []
    sale_a = "11111111-1111-1111-1111-1111111111aa"
    sale_b = "11111111-1111-1111-1111-1111111111bb"

    conn.fetch = AsyncMock(return_value=[{"id": sale_a}, {"id": sale_b}])

    async def fetchrow_side_effect(query, *args):
        if "rpc_apply_product_stock_delta" in query:
            reversal_calls.append(tuple(args))
            return {"rpc_apply_product_stock_delta": None}
        if "FROM stock_movements" in query:
            if args and args[0] == sale_a:
                return {"product_id": "prod-a", "quantity_delta": -3, "branch_id": "branch-1"}
            return {"product_id": "prod-b", "quantity_delta": -1, "branch_id": "branch-2"}
        return None

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales?operation_id={OPERATION_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 2
    assert ("prod-a", 3, "branch-1") in reversal_calls
    assert ("prod-b", 1, "branch-2") in reversal_calls


async def test_delete_sale_service_line_no_reversal(async_client, mock_pool):
    """Línea de servicio (sin stock_movements) → borra sin reversa ni error."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []

    async def fetchrow_side_effect(query, *args):
        if "rpc_apply_product_stock_delta" in query:
            reversal_calls.append(args)
            return {}
        if "FROM sales WHERE id" in query:
            return {"id": SALE_ID, "operation_id": None}
        if "FROM stock_movements" in query:
            return None  # servicio: sin movimiento
        return None

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert reversal_calls == []


async def test_update_sale_operation_ok(async_client, mock_pool):
    """PUT /sales/operation invoca rpc_atomic_update_sale_operation → 200."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["query"] = query
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert "rpc_atomic_update_sale_operation" in captured["query"]


async def test_update_sale_operation_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_list_sales_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    body = resp.json()
    # Paginado por operaciones: {items, total_operations}
    assert body["items"] == []
    assert body["total_operations"] == 0
