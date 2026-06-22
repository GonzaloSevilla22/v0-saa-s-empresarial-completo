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


async def test_delete_purchase_restores_stock_without_purchase_items(async_client, mock_pool):
    """Compra con stock_movements pero SIN purchase_items (ruta legacy / espejo C-29):
    el borrado DEBE revertir la entrada de stock (decrementa branch_stock)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []

    async def fetchrow_side_effect(query, *args):
        if "rpc_apply_product_stock_delta" in query:
            reversal_calls.append(args)
            return {"rpc_apply_product_stock_delta": None}
        if "FROM purchases WHERE id" in query:
            return {"id": PURCHASE_ID, "operation_id": None}
        if "FROM stock_movements" in query:
            return {
                "product_id": "prod-uuid-1",
                "quantity_delta": 5,  # compra = entrada de stock
                "branch_id": "branch-uuid-1",
            }
        if "FROM purchase_items" in query:
            return None  # ruta que no escribe purchase_items
        return None

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/purchases/{PURCHASE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 1, "la reversa de stock no se ejecutó"
    product_id, delta, branch_id = reversal_calls[0]
    assert product_id == "prod-uuid-1"
    assert delta == -5  # revierte la entrada: signo opuesto a quantity_delta = 5
    assert branch_id == "branch-uuid-1"
