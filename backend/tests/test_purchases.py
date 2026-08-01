from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

PURCHASE_ID = "22222222-2222-2222-2222-222222222222"

UPDATE_PAYLOAD = {
    "purchase_ids": [PURCHASE_ID],
    "date": "2024-01-15",
    "description": "Reposición",
    "items": [{"product_id": "prod-uuid-1", "quantity": "3.0", "amount": "80.00"}],
}


async def test_update_purchase_operation_ok(async_client, mock_pool):
    """PUT /purchases/operation invoca rpc_atomic_update_purchase_operation → 200."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["query"] = query
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert "rpc_atomic_update_purchase_operation" in captured["query"]


async def test_update_purchase_operation_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_delete_purchase_calls_stock_reversal_rpc(async_client, mock_pool):
    """v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): el borrado
    de una compra ya NO hace su propio lookup de stock_movements + rpc_apply_
    product_stock_delta + DELETE — delega TODO eso, de una, a
    rpc_reverse_stock_movement (que inserta un contramovimiento en vez de
    borrar del ledger append-only). La aritmética de stock/branch_stock se
    prueba contra Postgres real en el gate SQL (stock-a/b/c de
    20260828000001_v31_rls_collision_rpcs.sql) — acá se prueba el CONTRATO:
    delete_by_id llama la RPC exactamente una vez, con (purchase_id, reason)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []

    async def fetchrow_side_effect(query, *args):
        if "FROM purchases WHERE id" in query:
            return {"id": PURCHASE_ID, "operation_id": None}
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
            f"/purchases/{PURCHASE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 1, "rpc_reverse_stock_movement no se llamó"
    purchase_id, reason = reversal_calls[0]
    assert purchase_id == PURCHASE_ID
    assert reason == "Compra eliminada"


# ── v3-api-standards §2.5: envelope estándar {items,total,page,pages} ───────


async def test_list_purchases_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


async def test_list_purchases_envelope_has_page_and_pages(async_client, valid_token, mock_pool):
    """TRIANGULATE: con resultados, pages = ceil(total/size)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=30)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases?page=0&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 30
    assert body["page"] == 0
    assert body["pages"] == 2


async def test_list_purchases_page_out_of_range_returns_empty_items(async_client, valid_token, mock_pool):
    """2.10: página fuera de rango -> 200 con items vacío, no error."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=5)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases?page=99&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 5
    assert body["page"] == 99


async def test_list_purchases_page_size_over_max_returns_422(async_client, valid_token, mock_pool):
    """2.10: page_size sobre la cota máxima (100) -> 422 problem+json."""
    pool, conn = mock_pool
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases?page_size=99999",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()
