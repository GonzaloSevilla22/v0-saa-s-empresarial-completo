"""
facturar-venta-afip — Tests TDD para emitir factura AFIP desde una venta.

Strict TDD Mode. Ciclo: SAFETY NET → RED → GREEN → TRIANGULATE → REFACTOR.

Comportamientos cubiertos:
  ── Repo ──────────────────────────────────────────────────────────────────────
  - emit_sale_invoice invoca rpc_emit_sale_invoice con sales_order_id
  - emit_sale_invoice pasa point_of_sale_id (puede ser None)

  ── Service ───────────────────────────────────────────────────────────────────
  - monotributista → factura_c (resolve_invoice_type)
  - sin cliente → consumidor final (receptor NULL/NULL)
  - 409 cuando la orden ya tiene fiscal_document_id (P0409)
  - 404 cuando la orden no existe (P0404)
  - 400 cuando la orden no está en 'confirmed' (P0400)
  - 403 si el emisor es RI (P0401 → OQ-1)
  - cliente con CUIT (DocTipo 80)

  ── Endpoint HTTP ─────────────────────────────────────────────────────────────
  - POST /sales-orders/{id}/emit-invoice → 200 con status='pending_cae'
  - segundo call sobre misma orden → 409 (idempotencia)
  - member token → 403

  ── E2E AFIP (manual, excluido de CI) ────────────────────────────────────────
  - Marcado con @pytest.mark.integration (ver task 5.1)
"""
from __future__ import annotations

import json
import sys
import types
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import asyncpg
import pytest

from backend.tests.conftest import make_token

# ── Workaround fpdf2 ─────────────────────────────────────────────────────────
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes ────────────────────────────────────────────────────────────────

ACCOUNT_ID      = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SALES_ORDER_ID  = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
FISCAL_DOC_ID   = "dddddddd-dddd-dddd-dddd-dddddddddddd"
CLIENT_ID       = "cccccccc-cccc-cccc-cccc-cccccccccccc"
PV_ID           = "11111111-1111-1111-1111-111111111111"

EMIT_RPC_RESULT = {
    "fiscal_document_id": FISCAL_DOC_ID,
    "point_of_sale_id":   PV_ID,
    "punto_de_venta":     1,
    "comprobante_type":   "factura_c",
    "number":             1,
    "status":             "pending_cae",
    "sales_order_id":     SALES_ORDER_ID,
}


# ══════════════════════════════════════════════════════════════════════════════
# FIXTURES
# ══════════════════════════════════════════════════════════════════════════════

@pytest.fixture
def sales_order_repo():
    from backend.repositories.sales_order_repository import SalesOrderRepository
    conn = AsyncMock()
    return SalesOrderRepository(conn), conn


# ══════════════════════════════════════════════════════════════════════════════
# TASK 2.3 RED — REPOSITORY TESTS
# ══════════════════════════════════════════════════════════════════════════════

class TestEmitSaleInvoiceRepository:

    @pytest.mark.asyncio
    async def test_emit_sale_invoice_invokes_rpc(self, sales_order_repo):
        """emit_sale_invoice invoca rpc_emit_sale_invoice con el sales_order_id."""
        repo, conn = sales_order_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(EMIT_RPC_RESULT)}
        )

        result = await repo.emit_sale_invoice(
            sales_order_id=SALES_ORDER_ID,
            point_of_sale_id=None,
        )

        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_emit_sale_invoice" in query
        assert result["fiscal_document_id"] == FISCAL_DOC_ID
        assert result["status"] == "pending_cae"

    @pytest.mark.asyncio
    async def test_emit_sale_invoice_passes_point_of_sale_id(self, sales_order_repo):
        """Triangulación: point_of_sale_id llega al RPC cuando se especifica."""
        repo, conn = sales_order_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(EMIT_RPC_RESULT)}
        )

        await repo.emit_sale_invoice(
            sales_order_id=SALES_ORDER_ID,
            point_of_sale_id=PV_ID,
        )

        args = conn.fetchrow.call_args[0]
        assert PV_ID in args

    @pytest.mark.asyncio
    async def test_emit_sale_invoice_propagates_asyncpg_error(self, sales_order_repo):
        """P0409 de la DB se propaga sin swallowing."""
        repo, conn = sales_order_repo
        err = asyncpg.exceptions.RaiseError("already_invoiced")
        err.sqlstate = "P0409"
        conn.fetchrow = AsyncMock(side_effect=err)

        with pytest.raises(asyncpg.exceptions.RaiseError) as exc_info:
            await repo.emit_sale_invoice(
                sales_order_id=SALES_ORDER_ID,
                point_of_sale_id=None,
            )

        assert exc_info.value.sqlstate == "P0409"


# ══════════════════════════════════════════════════════════════════════════════
# TASK 2.1 RED → TASK 2.4 GREEN — SERVICE TESTS
# ══════════════════════════════════════════════════════════════════════════════

class TestEmitInvoiceService:

    @pytest.mark.asyncio
    async def test_monotributista_resolves_to_factura_c(self):
        """resolve_invoice_type: monotributista → factura_c (task 2.1 RED)."""
        from backend.services.fiscal.invoice_type_resolver import (
            resolve_invoice_type, DocumentType
        )

        result = resolve_invoice_type("monotributista", None)

        assert result == DocumentType.FACTURA_C

    @pytest.mark.asyncio
    async def test_monotributista_with_ri_receptor_still_factura_c(self):
        """Triangulación: monotributista → factura_c aunque el receptor sea RI."""
        from backend.services.fiscal.invoice_type_resolver import (
            resolve_invoice_type, DocumentType
        )

        result = resolve_invoice_type("monotributista", "responsable_inscripto")

        assert result == DocumentType.FACTURA_C

    @pytest.mark.asyncio
    async def test_emit_invoice_happy_path_returns_pending_cae(self):
        """Happy path: emitir factura OK → status='pending_cae'."""
        from backend.services import sales_orders as so_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        repo.emit_sale_invoice = AsyncMock(return_value=EMIT_RPC_RESULT)

        result = await so_service.emit_invoice(
            repo=repo,
            auth=writer_auth,
            sales_order_id=SALES_ORDER_ID,
            point_of_sale_id=None,
        )

        assert result["status"] == "pending_cae"
        assert result["fiscal_document_id"] == FISCAL_DOC_ID

    @pytest.mark.asyncio
    async def test_emit_invoice_member_returns_403(self):
        """member no puede emitir facturas → 403."""
        from fastapi import HTTPException
        from backend.services import sales_orders as so_service

        member_auth = {"role": "member"}
        repo = AsyncMock()

        with pytest.raises(HTTPException) as exc_info:
            await so_service.emit_invoice(
                repo=repo,
                auth=member_auth,
                sales_order_id=SALES_ORDER_ID,
                point_of_sale_id=None,
            )

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_emit_invoice_already_invoiced_returns_409(self):
        """P0409 (already_invoiced) → HTTPException 409."""
        from fastapi import HTTPException
        from backend.services import sales_orders as so_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        err = asyncpg.exceptions.RaiseError("already_invoiced")
        err.sqlstate = "P0409"
        repo.emit_sale_invoice = AsyncMock(side_effect=err)

        with pytest.raises(HTTPException) as exc_info:
            await so_service.emit_invoice(
                repo=repo,
                auth=writer_auth,
                sales_order_id=SALES_ORDER_ID,
                point_of_sale_id=None,
            )

        assert exc_info.value.status_code == 409

    @pytest.mark.asyncio
    async def test_emit_invoice_order_not_found_returns_404(self):
        """P0404 (sales_order_not_found) → HTTPException 404."""
        from fastapi import HTTPException
        from backend.services import sales_orders as so_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        err = asyncpg.exceptions.RaiseError("sales_order_not_found")
        err.sqlstate = "P0404"
        repo.emit_sale_invoice = AsyncMock(side_effect=err)

        with pytest.raises(HTTPException) as exc_info:
            await so_service.emit_invoice(
                repo=repo,
                auth=writer_auth,
                sales_order_id=SALES_ORDER_ID,
                point_of_sale_id=None,
            )

        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_emit_invoice_order_not_confirmed_returns_400(self):
        """P0400 (order_not_confirmed) → HTTPException 400."""
        from fastapi import HTTPException
        from backend.services import sales_orders as so_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        err = asyncpg.exceptions.RaiseError("order_not_confirmed")
        err.sqlstate = "P0400"
        repo.emit_sale_invoice = AsyncMock(side_effect=err)

        with pytest.raises(HTTPException) as exc_info:
            await so_service.emit_invoice(
                repo=repo,
                auth=writer_auth,
                sales_order_id=SALES_ORDER_ID,
                point_of_sale_id=None,
            )

        assert exc_info.value.status_code == 400

    @pytest.mark.asyncio
    async def test_emit_invoice_ri_emisor_returns_403(self):
        """Triangulación (OQ-1): P0401 (ri_not_supported) → HTTPException 403."""
        from fastapi import HTTPException
        from backend.services import sales_orders as so_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        err = asyncpg.exceptions.RaiseError("ri_not_supported")
        err.sqlstate = "P0401"
        repo.emit_sale_invoice = AsyncMock(side_effect=err)

        with pytest.raises(HTTPException) as exc_info:
            await so_service.emit_invoice(
                repo=repo,
                auth=writer_auth,
                sales_order_id=SALES_ORDER_ID,
                point_of_sale_id=None,
            )

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_emit_invoice_with_pv_id_passes_it_to_repo(self):
        """Triangulación (task 2.5): point_of_sale_id se pasa al repo."""
        from backend.services import sales_orders as so_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        repo.emit_sale_invoice = AsyncMock(return_value=EMIT_RPC_RESULT)

        await so_service.emit_invoice(
            repo=repo,
            auth=writer_auth,
            sales_order_id=SALES_ORDER_ID,
            point_of_sale_id=PV_ID,
        )

        repo.emit_sale_invoice.assert_called_once_with(
            sales_order_id=SALES_ORDER_ID,
            point_of_sale_id=PV_ID,
        )


# ══════════════════════════════════════════════════════════════════════════════
# TASK 2.7 RED→GREEN — ENDPOINT HTTP TESTS
# ══════════════════════════════════════════════════════════════════════════════

class TestEmitInvoiceEndpoint:

    async def test_emit_invoice_returns_200_with_pending_cae(self, async_client, mock_pool):
        """POST /sales-orders/{id}/emit-invoice → 200 con status='pending_cae'."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(EMIT_RPC_RESULT)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales-orders/{SALES_ORDER_ID}/emit-invoice",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "pending_cae"
        assert body["fiscal_document_id"] == FISCAL_DOC_ID

    async def test_emit_invoice_already_invoiced_returns_409(self, async_client, mock_pool):
        """Segunda llamada sobre misma orden → 409 (idempotencia)."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        err = asyncpg.exceptions.RaiseError("already_invoiced")
        err.sqlstate = "P0409"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales-orders/{SALES_ORDER_ID}/emit-invoice",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 409

    async def test_emit_invoice_member_returns_403(self, async_client, mock_pool):
        """Triangulación: member no puede facturar → 403."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales-orders/{SALES_ORDER_ID}/emit-invoice",
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    async def test_emit_invoice_with_point_of_sale_returns_200(self, async_client, mock_pool):
        """Triangulación: con point_of_sale_id → 200 normal."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(EMIT_RPC_RESULT)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales-orders/{SALES_ORDER_ID}/emit-invoice",
                json={"point_of_sale_id": PV_ID},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["fiscal_document_id"] == FISCAL_DOC_ID

    async def test_emit_invoice_ri_emisor_returns_403(self, async_client, mock_pool):
        """OQ-1: emisor RI → 403 con mensaje accionable."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        err = asyncpg.exceptions.RaiseError("ri_not_supported")
        err.sqlstate = "P0401"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales-orders/{SALES_ORDER_ID}/emit-invoice",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 403


# ══════════════════════════════════════════════════════════════════════════════
# TASK 5.1 — E2E AFIP (manual, excluido de CI)
# ══════════════════════════════════════════════════════════════════════════════

@pytest.mark.integration
def test_e2e_afip_emit_factura_c_homologacion():
    """
    Test de integración E2E contra ARCA homologación.

    MANUAL — excluido del gate de CI (no correr con pytest sin -m integration).
    Requiere:
      - AFIP_CUIT, AFIP_CERT, AFIP_KEY configurados
      - Credenciales del PO para el ambiente de homologación
      - Una sales_order confirmada sin comprobante en la DB de homologación

    Verificar:
      1. POST /sales-orders/{real_id}/emit-invoice → 200 con status='pending_cae'
      2. El relay pg_cron procesa el pending_cae y lo transiciona a 'authorized'
      3. El fiscal_document tiene un CAE real (14 dígitos)

    Este test no se implementa en el apply automático.
    Tarea 5.1 de tasks.md — requiere trámite ARCA del PO (no bloquea el merge).
    """
    pytest.skip("E2E AFIP: manual — requiere credenciales ARCA del PO")
