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


async def test_delete_sale_calls_stock_reversal_rpc(async_client, mock_pool):
    """v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): el borrado
    de una venta ya NO hace su propio lookup de stock_movements + rpc_apply_
    product_stock_delta + DELETE — delega TODO eso, de una, a
    rpc_reverse_stock_movement (inserta un contramovimiento en vez de borrar
    del ledger append-only — cubre por igual la ruta C-29/POS sin sale_items
    y la ruta v2, porque ya no hay ninguna rama por sale_items en el
    repository). La aritmética de stock/branch_stock se prueba contra
    Postgres real en el gate SQL (stock-a/b/c de
    20260828000001_v31_rls_collision_rpcs.sql) — acá se prueba el CONTRATO:
    delete_by_id llama la RPC exactamente una vez, con (sale_id, reason)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []

    async def fetchrow_side_effect(query, *args):
        if "FROM sales WHERE id" in query:
            return {"id": SALE_ID, "operation_id": None}
        return None

    async def fetch_side_effect(query, *args):
        if "rpc_reverse_stock_movement" in query:
            reversal_calls.append(args)
            return []
        return []

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    conn.fetch = AsyncMock(side_effect=fetch_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 1, "rpc_reverse_stock_movement no se llamó"
    sale_id, reason = reversal_calls[0]
    assert sale_id == SALE_ID
    assert reason == "Venta eliminada"


async def test_delete_sales_by_operation_calls_stock_reversal_rpc_per_sale(async_client, mock_pool):
    """delete_by_operation llama rpc_reverse_stock_movement una vez POR
    venta del lote (TRIANGULATE: 2 ventas distintas del mismo operation_id)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []
    sale_a = "11111111-1111-1111-1111-1111111111aa"
    sale_b = "11111111-1111-1111-1111-1111111111bb"

    async def fetch_side_effect(query, *args):
        if "SELECT id FROM sales WHERE operation_id" in query:
            return [{"id": sale_a}, {"id": sale_b}]
        if "rpc_reverse_stock_movement" in query:
            reversal_calls.append(args)
            return []
        return []

    conn.fetch = AsyncMock(side_effect=fetch_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales?operation_id={OPERATION_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 2
    assert reversal_calls[0] == (sale_a, "Venta eliminada (operación)")
    assert reversal_calls[1] == (sale_b, "Venta eliminada (operación)")


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
    # v3-api-standards §2: envelope estándar {items, total, page, pages}
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


async def test_list_sales_envelope_has_page_and_pages(async_client, valid_token, mock_pool):
    """TRIANGULATE: con resultados, pages = ceil(total/size) y page eco del pedido."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=30)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales?page=0&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 30
    assert body["page"] == 0
    assert body["pages"] == 2


async def test_list_sales_page_out_of_range_returns_empty_items(async_client, valid_token, mock_pool):
    """2.10: página fuera de rango -> 200 con items vacío, no error."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=5)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales?page=99&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 5
    assert body["page"] == 99


async def test_list_sales_page_size_over_max_returns_422(async_client, valid_token, mock_pool):
    """2.10: page_size sobre la cota máxima (100) -> 422 problem+json."""
    pool, conn = mock_pool
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales?page_size=99999",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()
