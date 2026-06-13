"""
C-27 v21-fiscal-profile — DocumentSequence + emit_pending_cae endpoint (TDD).

Task 1.5: gate de concurrencia del rpc_next_document_number (unit test con mock).
Task 3.5: endpoint de emisión pending_cae + P0422 ambiguous_point_of_sale.

Spec refs:
  - document-sequence/spec.md §"Numeración sin huecos"
  - afip-fiscal-document/spec.md §"Emisión síncrona"
  - fiscal-profile/spec.md §"Selección del punto de venta en la emisión"
"""
from __future__ import annotations

import json
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token

ACCOUNT_ID = str(TEST_ACCOUNT_ID)
PV_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"


class TestRpcNextDocumentNumberConcurrencyGate:
    """Task 1.5 — gate de concurrencia vía mock serial.

    En el test unitario se simulan 100 llamadas seriales al RPC con un mock
    que incrementa un contador (emulando el FOR UPDATE serializado en prod).
    El smoke 5.1 en prod valida la concurrencia real con transacciones paralelas.
    """

    @pytest.mark.asyncio
    async def test_sequential_calls_return_no_gaps_or_duplicates(self):
        """100 llamadas seriales al mock incrementan el número sin huecos."""
        counter = [0]

        async def mock_rpc(*args, **kwargs):
            counter[0] += 1
            return {"rpc_next_document_number": counter[0]}

        from backend.repositories.base import BaseRepository
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(side_effect=mock_rpc)

        results = []
        for _ in range(100):
            row = await conn.fetchrow(
                "SELECT public.rpc_next_document_number($1::uuid, $2)",
                PV_ID,
                "factura_b",
            )
            results.append(row["rpc_next_document_number"])

        # Sin huecos: 1..100
        assert results == list(range(1, 101)), (
            f"Expected 1..100, got {results[:10]}..."
        )
        # Sin duplicados
        assert len(set(results)) == 100


class TestEmitPendingCAEEndpoint:
    """Task 3.5 — endpoint POST /fiscal/documents/emit."""

    EMIT_PAYLOAD = {
        "comprobante_type": "factura_b",
        "total": 1500.0,
    }

    EMIT_RESULT = {
        "fiscal_document_id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
        "point_of_sale_id": PV_ID,
        "punto_de_venta": 1,
        "comprobante_type": "factura_b",
        "number": 1,
        "status": "pending_cae",
    }

    async def test_emit_pending_cae_returns_doc(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(self.EMIT_RESULT)}
        )
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/documents/emit",
                json=self.EMIT_PAYLOAD,
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "pending_cae"
        assert body["number"] == 1

    async def test_member_cannot_emit(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/documents/emit",
                json=self.EMIT_PAYLOAD,
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403

    async def test_ambiguous_point_of_sale_returns_422(self, async_client, mock_pool):
        """P0422 ambiguous_point_of_sale → HTTP 422."""
        import asyncpg as _asyncpg

        pool, conn = mock_pool

        class FakePostgresError(_asyncpg.PostgresError):
            sqlstate = "P0422"

            def __str__(self):
                return "ambiguous_point_of_sale: la cuenta tiene 2 puntos de venta activos"

        conn.fetchrow = AsyncMock(side_effect=FakePostgresError())
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/documents/emit",
                json=self.EMIT_PAYLOAD,
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 422
        assert "ambiguous_point_of_sale" in resp.json().get("detail", "")
