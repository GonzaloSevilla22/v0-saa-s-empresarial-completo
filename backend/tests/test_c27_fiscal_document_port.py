"""
C-27 v21-fiscal-profile — FiscalDocumentPort + WSFEStubAdapter (TDD).

TDD RED→GREEN:
  2.3 RED: el port define la interfaz; el stub devuelve CAEResponse ficticio
           determinístico; el service solo referencia tipos de dominio (no SOAP).
  2.4 GREEN: port FiscalDocumentPort + WSFEStubAdapter + tipos CAERequest/CAEResponse/DocumentType.

Spec refs: afip-fiscal-document/spec.md §"Adaptador WSFE detrás de un ACL"
"""
from __future__ import annotations

import datetime
import inspect

import pytest

from backend.services.fiscal.fiscal_document_port import (
    CAERequest,
    CAEResponse,
    FiscalDocumentPort,
)
from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter


class TestFiscalDocumentPort:
    """2.3 RED → 2.4 GREEN: port define la interfaz correcta."""

    def test_port_is_abstract_class(self):
        """FiscalDocumentPort es una clase abstracta (no instanciable directamente)."""
        with pytest.raises(TypeError):
            FiscalDocumentPort()

    def test_port_has_request_cae_method(self):
        """FiscalDocumentPort define el método request_cae."""
        assert hasattr(FiscalDocumentPort, "request_cae")
        method = getattr(FiscalDocumentPort, "request_cae")
        sig = inspect.signature(method)
        assert "invoice_data" in sig.parameters

    def test_cae_request_has_required_fields(self):
        """CAERequest contiene los campos mínimos de dominio."""
        req = CAERequest(
            account_id="acc-123",
            fiscal_document_id="doc-456",
            comprobante_type="factura_b",
            punto_de_venta=1,
            number=42,
            total=1500.0,
            cuit_emisor="20123456789",
            ambiente="homologacion",
        )
        assert req.account_id == "acc-123"
        assert req.comprobante_type == "factura_b"
        assert req.ambiente == "homologacion"

    def test_cae_response_has_required_fields(self):
        """CAEResponse contiene cae, cae_due_date y is_approved."""
        resp = CAEResponse(
            cae="12345678901234",
            cae_due_date=datetime.date(2026, 7, 1),
            is_approved=True,
            error_code=None,
            error_detail=None,
        )
        assert resp.is_approved is True
        assert resp.cae == "12345678901234"

    def test_rejected_cae_response(self):
        """CAEResponse puede representar un rechazo."""
        resp = CAEResponse(
            cae=None,
            cae_due_date=None,
            is_approved=False,
            error_code="10016",
            error_detail="CUIT no autorizado",
        )
        assert resp.is_approved is False
        assert resp.error_code == "10016"


class TestWSFEStubAdapter:
    """2.3 RED → 2.4 GREEN: stub devuelve CAEResponse ficticio determinístico."""

    @pytest.fixture
    def stub(self):
        return WSFEStubAdapter()

    @pytest.mark.asyncio
    async def test_stub_implements_port(self, stub):
        """WSFEStubAdapter es una instancia de FiscalDocumentPort."""
        assert isinstance(stub, FiscalDocumentPort)

    @pytest.mark.asyncio
    async def test_stub_returns_approved_cae(self, stub):
        """El stub devuelve is_approved=True con un CAE ficticio determinístico."""
        req = CAERequest(
            account_id="acc-123",
            fiscal_document_id="doc-456",
            comprobante_type="factura_b",
            punto_de_venta=1,
            number=42,
            total=1500.0,
            cuit_emisor="20123456789",
            ambiente="homologacion",
        )
        resp = await stub.request_cae(req)

        assert isinstance(resp, CAEResponse)
        assert resp.is_approved is True
        assert resp.cae is not None
        assert len(resp.cae) > 0
        assert resp.cae_due_date is not None

    @pytest.mark.asyncio
    async def test_stub_cae_is_deterministic_for_same_doc(self, stub):
        """El mismo fiscal_document_id produce el mismo CAE (determinístico)."""
        req = CAERequest(
            account_id="acc-123",
            fiscal_document_id="doc-fixed",
            comprobante_type="factura_a",
            punto_de_venta=2,
            number=100,
            total=99.99,
            cuit_emisor="20987654321",
            ambiente="homologacion",
        )
        resp1 = await stub.request_cae(req)
        resp2 = await stub.request_cae(req)
        assert resp1.cae == resp2.cae

    @pytest.mark.asyncio
    async def test_stub_does_not_touch_network(self, stub, monkeypatch):
        """El stub no hace ninguna llamada HTTP/SOAP (sin side effects de red)."""
        import socket

        calls = []

        def mock_getaddrinfo(*args, **kwargs):
            calls.append(args)
            raise RuntimeError("Network access not allowed in stub")

        monkeypatch.setattr(socket, "getaddrinfo", mock_getaddrinfo)

        req = CAERequest(
            account_id="acc-net",
            fiscal_document_id="doc-net",
            comprobante_type="factura_b",
            punto_de_venta=1,
            number=1,
            total=100.0,
            cuit_emisor="20111222333",
            ambiente="homologacion",
        )
        # No debe lanzar excepción (no toca red)
        resp = await stub.request_cae(req)
        assert resp.is_approved is True
        assert calls == [], "stub should not call network"

    @pytest.mark.asyncio
    async def test_stub_cae_due_date_is_future(self, stub):
        """El CAE ficticio tiene una fecha de vencimiento futura."""
        req = CAERequest(
            account_id="acc-123",
            fiscal_document_id="doc-date",
            comprobante_type="factura_c",
            punto_de_venta=1,
            number=5,
            total=500.0,
            cuit_emisor="20333444555",
            ambiente="homologacion",
        )
        resp = await stub.request_cae(req)
        assert resp.cae_due_date > datetime.date.today()
