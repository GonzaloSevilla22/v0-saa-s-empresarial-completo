"""
C-31+ v21-wsfe-production-hardening — Array Iva / AlicIva (Hueco 2).

TDD RED->GREEN->TRIANGULATE: verifica que _call_wsfe:
  - tipo A/B: incluye Iva array con AlicIva {Id, BaseImp, Importe} y totales consistentes
  - tipo C: SIN array Iva, ImpIVA=0, ImpNeto=ImpTotal

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/v21-wsfe-production-hardening/specs/afip-fiscal-document/spec.md
  Scenario: Array Iva para comprobante A/B con IVA 21%
  Scenario: Comprobante tipo C sin array Iva
Design ref: D3
"""
from __future__ import annotations

import datetime
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse
from backend.services.fiscal.wsfe_adapter import WSFEAdapter


# ============================================================
# Helpers
# ============================================================

def _make_approved_wsfe_response():
    """Minimal mock WSFE response for an approved CAE."""
    mock_resp = MagicMock()
    det = MagicMock()
    det.Resultado = "A"
    det.CAE = "86250464989491"
    det.CAEFchVto = "20261231"
    det.Observaciones = None
    mock_resp.FeDetResp.FECAEDetResponse = [det]
    return mock_resp


def _make_request_factura_b(neto: Decimal, iva_amount: Decimal) -> CAERequest:
    """Factura B (tipo A/B) with explicit IVA breakdown."""
    total = neto + iva_amount
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="dddddddd-dddd-dddd-dddd-dddddddddddd",
        comprobante_type="factura_b",
        punto_de_venta=1,
        number=42,
        total=total,
        cuit_emisor="20123456789",
        ambiente="homologacion",
        cuit_receptor="20000000000",
        fecha_comprobante=datetime.date(2026, 6, 23),
        receptor_iva_condition="consumidor_final",
        neto=neto,
        iva_amount=iva_amount,
        iva_alicuota_id=5,
    )


def _make_request_factura_c(total: Decimal) -> CAERequest:
    """Factura C (tipo C = monotributista emisor) — no IVA."""
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
        comprobante_type="factura_c",
        punto_de_venta=1,
        number=10,
        total=total,
        cuit_emisor="27000000000",
        ambiente="homologacion",
        cuit_receptor=None,
        fecha_comprobante=datetime.date(2026, 6, 23),
        receptor_iva_condition="consumidor_final",
        neto=None,
        iva_amount=None,
        iva_alicuota_id=None,
    )


class TestIvaArrayTipoB:
    """3.1 RED -> 3.2 GREEN: Iva array presente para factura_b con IVA 21%."""

    @pytest.mark.asyncio
    async def test_factura_b_has_iva_array(self):
        """3.1 RED: FECAEDetRequest de factura_b tiene array Iva con AlicIva Id=5.

        Fails today because _call_wsfe sets ImpIVA=0 and sends no Iva array.
        """
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request_factura_b(neto=Decimal("1000.00"), iva_amount=Decimal("210.00"))
        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=41)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call
            await adapter._call_wsfe(invoice, "token", "sign")

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]

        # Array Iva debe existir
        assert "Iva" in det, "FECAEDetRequest tipo B debe incluir el campo 'Iva'"
        iva_field = det["Iva"]
        assert "AlicIva" in iva_field, "Iva debe tener la clave 'AlicIva'"
        alicuotas = iva_field["AlicIva"]
        assert len(alicuotas) >= 1, "Debe haber al menos una alicuota en AlicIva"

        alicuota = alicuotas[0]
        assert alicuota["Id"] == 5, f"Alicuota 21% debe tener Id=5; got {alicuota['Id']}"
        assert alicuota["BaseImp"] == 1000.0, f"BaseImp debe ser 1000.0; got {alicuota['BaseImp']}"
        assert alicuota["Importe"] == 210.0, f"Importe debe ser 210.0; got {alicuota['Importe']}"

    @pytest.mark.asyncio
    async def test_factura_b_imp_neto_imp_iva_consistent_with_total(self):
        """3.2 GREEN: ImpNeto + ImpIVA == ImpTotal para factura_b (sin otros tributos)."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request_factura_b(neto=Decimal("1000.00"), iva_amount=Decimal("210.00"))
        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=41)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call
            await adapter._call_wsfe(invoice, "token", "sign")

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]

        imp_neto  = det["ImpNeto"]
        imp_iva   = det["ImpIVA"]
        imp_total = det["ImpTotal"]

        assert imp_neto == 1000.0,  f"ImpNeto debe ser 1000.0; got {imp_neto}"
        assert imp_iva  == 210.0,   f"ImpIVA debe ser 210.0; got {imp_iva}"
        assert abs(imp_neto + imp_iva - imp_total) < 0.01, (
            f"ImpNeto({imp_neto}) + ImpIVA({imp_iva}) debe == ImpTotal({imp_total})"
        )

    @pytest.mark.asyncio
    async def test_factura_b_second_amount_also_consistent(self):
        """3.2 GREEN TRIANGULATE: segundo monto diferente — consistencia de totales."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request_factura_b(neto=Decimal("500.00"), iva_amount=Decimal("105.00"))
        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=0)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call
            await adapter._call_wsfe(invoice, "token", "sign")

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        imp_neto  = det["ImpNeto"]
        imp_iva   = det["ImpIVA"]
        imp_total = det["ImpTotal"]
        assert abs(imp_neto + imp_iva - imp_total) < 0.01, (
            f"ImpNeto({imp_neto}) + ImpIVA({imp_iva}) debe == ImpTotal({imp_total})"
        )


class TestIvaArrayTipoC:
    """3.3 TRIANGULATE: tipo C — SIN array Iva, ImpIVA=0, ImpNeto=ImpTotal."""

    @pytest.mark.asyncio
    async def test_factura_c_has_no_iva_array(self):
        """3.3 TRIANGULATE: factura_c NO incluye campo 'Iva' en FECAEDetRequest."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request_factura_c(total=Decimal("1000.00"))
        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=9)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call
            await adapter._call_wsfe(invoice, "token", "sign")

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]

        # Tipo C: NO debe incluir array Iva
        assert "Iva" not in det, (
            f"FECAEDetRequest tipo C NO debe incluir 'Iva'; got keys: {list(det.keys())}"
        )
        assert det["ImpIVA"] == 0, f"Tipo C: ImpIVA debe ser 0; got {det['ImpIVA']}"

    @pytest.mark.asyncio
    async def test_factura_c_imp_neto_equals_imp_total(self):
        """3.3 TRIANGULATE: tipo C — ImpNeto == ImpTotal (sin IVA discriminado)."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request_factura_c(total=Decimal("750.00"))
        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=0)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call
            await adapter._call_wsfe(invoice, "token", "sign")

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        assert abs(det["ImpNeto"] - det["ImpTotal"]) < 0.01, (
            f"Tipo C: ImpNeto({det['ImpNeto']}) debe == ImpTotal({det['ImpTotal']})"
        )
