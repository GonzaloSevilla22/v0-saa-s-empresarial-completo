"""qa-integral-modulos (G8, task 8.1) — contrato de GET /sales-orders.

El QA del 2026-08-30 encontró `/ventas/ordenes` devolviendo 500 con CUALQUIER
pedido cargado: `limpiezas-pagos-admin` (G1b, task 5.5) retiró la columna
`sales_orders.payment_method` (TEXT legacy) — la forma de pago vive solo en
`payment_method_id` — pero `SalesOrderOut.payment_method` siguió declarado
REQUERIDO y el `SELECT *` del repositorio ya no trae esa clave: toda fila real
rompe la validación de respuesta (ResponseValidationError → 500).

El mock histórico (`SALES_ORDER_ROW` en test_c29_quote_salesorder.py) tapaba el
bug porque conservaba la clave `payment_method` que la tabla ya no tiene —
exactamente la lección "los mocks replican el transporte real". Estos tests
usan el transporte REAL: la fila tal como la devuelve hoy la tabla (verificado
contra el DDL vivo: sin `payment_method`, con `payment_method_id uuid NULL).

Fix (D6): el repositorio DERIVA `payment_method` = `payment_methods.kind` vía
LEFT JOIN (mismo dominio de 7 valores que el enum), y el schema lo vuelve
Optional (una orden sin imputación es legal → None).
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token
from backend.tests.test_c29_quote_salesorder import (
    ACCOUNT_ID,
    BRANCH_ID,
    CLIENT_ID,
    OPERATION_ID,
    QUOTE_ID,
    SALES_ORDER_ID,
)

# Transporte REAL post-fix: el SELECT del repo proyecta so.* (SIN columna
# payment_method en la tabla) + pm.kind AS payment_method (derivada, puede ser
# NULL). PRE-fix el SELECT * no traía la clave en absoluto — ambos escenarios
# se cubren abajo.
REAL_ROW_NO_PAYMENT_METHOD = {
    "id":                 SALES_ORDER_ID,
    "account_id":         ACCOUNT_ID,
    "branch_id":          BRANCH_ID,
    "client_id":          CLIENT_ID,
    "source_quote_id":    QUOTE_ID,
    "status":             "confirmed",
    "total":              "1500.00",
    "sale_operation_id":  OPERATION_ID,
    "fiscal_document_id": None,
    "created_by":         "11111111-1111-1111-1111-111111111111",
    "created_at":         "2026-06-17T10:05:00",
    "payment_method_id":  None,
}

REAL_ROW_WITH_KIND = {
    **REAL_ROW_NO_PAYMENT_METHOD,
    "payment_method_id": "44444444-4444-4444-4444-444444444444",
    "payment_method":    "transfer",  # pm.kind derivado por el LEFT JOIN
}


class TestListOrdersRealTransport:
    """RED 8.1: la fila real (sin payment_method) debe listar 200, no 500."""

    async def test_list_orders_row_without_payment_method_returns_200(
        self, async_client, mock_pool
    ):
        """RED: fila con la forma REAL de la tabla (sin la columna retirada)
        — hoy 500 por ResponseValidationError; el contrato exige 200."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetch = AsyncMock(return_value=[REAL_ROW_NO_PAYMENT_METHOD])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/sales-orders",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert len(body) == 1
        # Orden sin imputación: la forma de pago derivada es null, no un 500.
        assert body[0]["payment_method"] is None

    async def test_list_orders_row_with_derived_kind_serializes_it(
        self, async_client, mock_pool
    ):
        """TRIANGULATE: orden imputada — el kind derivado viaja en el campo."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetch = AsyncMock(return_value=[REAL_ROW_WITH_KIND])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/sales-orders",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()[0]["payment_method"] == "transfer"

    async def test_list_orders_projects_derived_payment_method(self, mock_pool):
        """El SELECT del repo deriva payment_method desde payment_methods.kind
        (LEFT JOIN) — la tabla ya no tiene la columna (retirada por
        limpiezas-pagos-admin G1b)."""
        from backend.repositories.sales_order_repository import SalesOrderRepository

        _pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        repo = SalesOrderRepository(conn)

        await repo.list_orders(ACCOUNT_ID)

        query = conn.fetch.call_args[0][0].lower()
        assert "payment_methods" in query, (
            "list_orders debe derivar payment_method con LEFT JOIN a "
            "payment_methods — la columna propia fue retirada"
        )
        assert "as payment_method" in query
        assert "account_id" in query

    async def test_get_order_detail_row_without_payment_method_returns_200(
        self, async_client, mock_pool
    ):
        """TRIANGULATE: el detalle usa el mismo contrato SalesOrderOut."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=REAL_ROW_NO_PAYMENT_METHOD)
        conn.fetch = AsyncMock(return_value=[])  # items

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/sales-orders/{SALES_ORDER_ID}",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["payment_method"] is None
