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

import pytest

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


# ── presupuestos-modulo (tanda B, 6.6) — presupuesto de origen y líneas de servicio ─

QUOTE_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"


async def test_sales_expone_el_presupuesto_de_origen(async_client, valid_token, mock_pool):
    """`/sales` trae `source_quote_id` y su número, derivados de
    `sales_orders.source_quote_id → quotes` (sin columnas denormalizadas)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row(source_quote_id=QUOTE_ID, source_quote_number=12)])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    assert resp.status_code == 200
    item = resp.json()["items"][0]
    assert item["source_quote_id"] == QUOTE_ID
    assert item["source_quote_number"] == 12

    sql = _normalized(conn.fetch.await_args_list[-1].args[0])
    assert re.search(r"so\.source_quote_id\s+AS source_quote_id\b", sql)
    assert re.search(r"sq\.number\s+AS source_quote_number\b", sql)
    # el JOIN al presupuesto exige la misma cuenta (nunca un número ajeno)
    assert re.search(r"LEFT JOIN (public\.)?quotes sq ON sq\.id = so\.source_quote_id AND sq\.account_id = so\.account_id", sql)


async def test_sales_sin_presupuesto_no_inventa_origen(async_client, valid_token, mock_pool):
    """Una venta del POS o del formulario no nació de un presupuesto: sin
    indicador."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row()])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    item = resp.json()["items"][0]
    assert item["source_quote_id"] is None
    assert item["source_quote_number"] is None


@pytest.mark.parametrize("flag", [True, False])
async def test_sales_expone_has_service_lines(async_client, valid_token, mock_pool, flag):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row(has_service_lines=flag)])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    assert resp.json()["items"][0]["has_service_lines"] is flag


async def test_sales_fila_sin_derivado_es_sin_lineas_de_servicio(async_client, valid_token, mock_pool):
    """Default conservador: una fila sin el derivado = sin líneas de servicio
    (la autoridad al editar sigue siendo el servidor)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row()])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    assert resp.json()["items"][0]["has_service_lines"] is False


async def test_sales_la_linea_de_servicio_muestra_su_descripcion(async_client, valid_token, mock_pool):
    """La fila legacy de una línea de servicio no tiene producto ni descripción:
    el read model la resuelve desde `sales_order_items.name_snapshot` de la
    MISMA orden y la entrega como `product_name`."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row(product_name="Instalación", has_service_lines=True)])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    item = resp.json()["items"][0]
    assert item["product_id"] is None
    assert item["product_name"] == "Instalación"

    sql = _normalized(conn.fetch.await_args_list[-1].args[0])
    # la descripción sólo se busca para una fila SIN producto y SIN línea de venta
    assert "COALESCE(pr.name, svc.name_snapshot) AS product_name" in sql
    lateral = sql[sql.index("LEFT JOIN LATERAL"):sql.index(") svc ON TRUE")]
    assert "FROM sales_order_items soi" in lateral or "FROM public.sales_order_items soi" in lateral
    assert "soi.sales_order_id = so.id" in lateral
    assert "soi.account_id = s.account_id" in lateral          # tenencia explícita
    assert "soi.product_id IS NULL" in lateral and "s.product_id IS NULL" in lateral
    # emparejado por precio, cantidad, subtotal y unidad (D6, OQ-P15). La unidad
    # se compara con la forma explícita (igual, o ambas nulas) y NO con
    # `IS NOT DISTINCT FROM`: el gate de referencias a tablas toma la palabra
    # que sigue a FROM como nombre de tabla y lo marcaría como falso positivo.
    for pair in ("soi.price = s.amount", "soi.quantity = s.quantity", "soi.subtotal = s.total",
                 "(soi.unit_id = s.unit_id OR (soi.unit_id IS NULL AND s.unit_id IS NULL))"):
        assert pair in lateral, pair
    assert "DISTINCT FROM" not in lateral
    # sin fan-out: dos líneas iguales no duplican la fila de la venta
    assert "LIMIT 1" in lateral


async def test_sales_has_service_lines_se_calcula_por_operacion(async_client, valid_token, mock_pool):
    """Una operación con alguna fila sin producto marca TODAS sus filas (el
    lápiz de "Editar" es de la operación, no de la fila)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row()])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    sql = _normalized(conn.fetch.await_args_list[-1].args[0])
    assert re.search(
        r"BOOL_OR\(s\.product_id IS NULL AND si\.id IS NULL AND so\.source_quote_id IS NOT NULL\) "
        r"OVER \(PARTITION BY COALESCE\(s\.operation_id::text, s\.id::text\)\) AS has_service_lines", sql)


async def test_sales_has_service_lines_exige_el_origen_presupuesto(async_client, valid_token, mock_pool):
    """Revisión 6.11 (B-01): una fila sin producto NO alcanza para ser una línea
    de servicio. En prod hay operaciones históricas con `product_id` NULL porque
    el producto se borró (FK ON DELETE SET NULL): sin el origen en un
    presupuesto, el lápiz de editar tendría un motivo falso."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_sale_row()])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

    sql = _normalized(conn.fetch.await_args_list[-1].args[0])
    flag = re.search(r"BOOL_OR\((.+?)\) OVER \(PARTITION BY .+? AS has_service_lines", sql)
    assert flag is not None
    assert "so.source_quote_id IS NOT NULL" in flag.group(1)
    assert "COALESCE(si.product_id, s.product_id) IS NULL" not in flag.group(1)


async def test_list_orders_trae_el_numero_del_presupuesto_de_origen():
    from backend.repositories.sales_order_repository import SalesOrderRepository

    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    await SalesOrderRepository(conn).list_orders(str(TEST_ACCOUNT_ID))

    sql = _normalized(conn.fetch.await_args.args[0])
    assert re.search(r"sq\.number\s+AS source_quote_number\b", sql)
    assert re.search(r"LEFT JOIN public\.quotes sq ON sq\.id = so\.source_quote_id AND sq\.account_id = so\.account_id", sql)


async def test_get_order_trae_el_numero_del_presupuesto_de_origen():
    from backend.repositories.sales_order_repository import SalesOrderRepository

    conn = AsyncMock()
    conn.fetchrow = AsyncMock(return_value=None)
    await SalesOrderRepository(conn).get_order("44444444-4444-4444-4444-444444444444", str(TEST_ACCOUNT_ID))

    sql = _normalized(conn.fetchrow.await_args.args[0])
    assert re.search(r"sq\.number\s+AS source_quote_number\b", sql)
    assert "WHERE so.id = $1::uuid AND so.account_id = $2::uuid" in sql


async def test_sales_orders_expone_el_presupuesto_de_origen(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_order_row(source_quote_id=QUOTE_ID, source_quote_number=12)])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales-orders", headers={"Authorization": f"Bearer {valid_token}"})

    assert resp.status_code == 200
    order = resp.json()[0]
    assert order["source_quote_id"] == QUOTE_ID
    assert order["source_quote_number"] == 12


async def test_sales_orders_sin_presupuesto_de_origen(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[_order_row()])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get("/sales-orders", headers={"Authorization": f"Bearer {valid_token}"})

    order = resp.json()[0]
    assert order["source_quote_id"] is None
    assert order["source_quote_number"] is None
