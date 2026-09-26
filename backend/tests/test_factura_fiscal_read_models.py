"""
factura-fiscal-imprimible — grupo 6: los read models traen el CAE.

  * `/sales` (6.1): el SELECT existente suma `fd.cae`, `fd.cae_due_date` y
    `fd.comprobante_type` (derivados de `fiscal_documents`, sin columnas
    denormalizadas) y `SaleOut` los expone.
  * `/sales-orders` (6.3): hasta hoy la lista no traía NADA del comprobante y
    la página pasaba `initialStatus="pending_cae"` fijo al badge, así que una
    orden autorizada se veía "En trámite" para siempre (Realtime sólo avisa
    cambios, no el estado inicial). La lista suma el estado REAL con el mismo
    nombre de campos que `/sales` y `fiscal_frozen` con la misma condición que
    `routers/fiscal.py` (`is_frozen`: marca Y `pending_cae`).
"""
from __future__ import annotations

import re
from unittest.mock import AsyncMock, patch

from backend.tests.conftest import TEST_ACCOUNT_ID


def _normalized(sql: str) -> str:
    return " ".join(sql.split())


def _sale_row(**extra) -> dict:
    row = {
        "id": "11111111-1111-1111-1111-111111111111", "date": "2026-09-25T00:00:00+00:00",
        "client_id": None, "operation_id": "33333333-3333-3333-3333-333333333333",
        "currency": "ARS", "product_id": None, "quantity": "1", "amount": "32500.00",
        "total": "32500.00", "product_name": None, "client_name": None,
        "branch_id": None, "canal": None, "unit_id": None,
        "payment_method_id": None, "payment_method_name": None, "payment_method_kind": None,
    }
    row.update(extra)
    return row


# ── 6.1 — /sales ─────────────────────────────────────────────────────────────

async def test_sales_expone_cae_vencimiento_y_tipo(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row(
        fiscal_document_id="22222222-2222-2222-2222-222222222222",
        fiscal_document_status="authorized",
        fiscal_punto_de_venta=3,
        fiscal_number=501,
        fiscal_cae="71234567890123",
        fiscal_cae_due_date="2026-10-05",
        fiscal_comprobante_type="factura_c",
    )])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    assert resp.status_code == 200
    item = resp.json()["items"][0]
    assert item["fiscal_cae"] == "71234567890123"
    assert item["fiscal_cae_due_date"] == "2026-10-05"
    assert item["fiscal_comprobante_type"] == "factura_c"

    sql = _normalized(conn.fetch.await_args_list[-1].args[0])
    assert re.search(r"fd\.cae\s+AS fiscal_cae\b", sql)
    assert re.search(r"fd\.cae_due_date\s+AS fiscal_cae_due_date\b", sql)
    assert re.search(r"fd\.comprobante_type\s+AS fiscal_comprobante_type\b", sql)


async def test_sales_sin_comprobante_no_inventa_cae(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row()])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    item = resp.json()["items"][0]
    assert item["fiscal_cae"] is None
    assert item["fiscal_cae_due_date"] is None
    assert item["fiscal_comprobante_type"] is None


# ── 6.3 — /sales-orders ──────────────────────────────────────────────────────

async def test_list_orders_trae_el_estado_real_del_comprobante():
    from backend.repositories.sales_order_repository import SalesOrderRepository

    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    await SalesOrderRepository(conn).list_orders(str(TEST_ACCOUNT_ID))

    sql = _normalized(conn.fetch.await_args.args[0])
    assert conn.fetch.await_args.args[1:] == (str(TEST_ACCOUNT_ID),)
    assert "WHERE so.account_id = $1::uuid" in sql
    assert ("LEFT JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id "
            "AND fd.account_id = so.account_id") in sql
    for expr, alias in (
        ("fd.status", "fiscal_document_status"),
        ("fd.punto_de_venta", "fiscal_punto_de_venta"),
        ("fd.number", "fiscal_number"),
        ("fd.cae", "fiscal_cae"),
        ("fd.cae_due_date", "fiscal_cae_due_date"),
        ("fd.comprobante_type", "fiscal_comprobante_type"),
    ):
        assert f"{expr} AS {alias}" in sql, alias
    # misma condición que routers/fiscal.py (is_frozen)
    assert ("(fd.cae_submit_unconfirmed_at IS NOT NULL AND fd.status = 'pending_cae') "
            "AS fiscal_frozen") in sql


def _order_row(**extra) -> dict:
    row = {
        "id": "44444444-4444-4444-4444-444444444444",
        "account_id": str(TEST_ACCOUNT_ID),
        "branch_id": "55555555-5555-5555-5555-555555555555",
        "client_id": None, "source_quote_id": None, "status": "confirmed",
        "payment_method": None, "payment_method_id": None, "total": "32500.00",
        "sale_operation_id": None, "fiscal_document_id": "22222222-2222-2222-2222-222222222222",
        "created_by": "66666666-6666-6666-6666-666666666666",
        "created_at": "2026-09-25T15:34:00+00:00",
    }
    row.update(extra)
    return row


async def test_sales_orders_expone_el_comprobante(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_order_row(
        fiscal_document_status="authorized",
        fiscal_punto_de_venta=3,
        fiscal_number=501,
        fiscal_cae="71234567890123",
        fiscal_cae_due_date="2026-10-05",
        fiscal_comprobante_type="factura_c",
        fiscal_frozen=False,
    )])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales-orders", headers={"Authorization": f"Bearer {valid_token}"})

    assert resp.status_code == 200
    order = resp.json()[0]
    assert order["fiscal_document_status"] == "authorized"
    assert order["fiscal_punto_de_venta"] == 3
    assert order["fiscal_number"] == 501
    assert order["fiscal_cae"] == "71234567890123"
    assert order["fiscal_cae_due_date"] == "2026-10-05"
    assert order["fiscal_comprobante_type"] == "factura_c"
    assert order["fiscal_frozen"] is False


async def test_sales_orders_sin_comprobante(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_order_row(fiscal_document_id=None)])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales-orders", headers={"Authorization": f"Bearer {valid_token}"})

    order = resp.json()[0]
    assert order["fiscal_document_status"] is None
    assert order["fiscal_cae"] is None
    assert order["fiscal_frozen"] is False
