"""
fiscal-receptor-iva-relay — Identificación del receptor (DocTipo/DocNro) + umbral + guard A/B.

TDD RED->GREEN->TRIANGULATE: verifica que _call_wsfe:
  - deriva DocTipo/DocNro del receptor (80=CUIT, 96=DNI, 99=sin identificar/DocNro=0)
  - exige identificación cuando total >= umbral (RG 5824/2026, $10M)
  - falla explícito para Factura A/B sin desglose de IVA (D5, no IVA=0 silencioso)

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/fiscal-receptor-iva-relay/specs/afip-fiscal-document/spec.md
  Scenario: Receptor con CUIT emite DocTipo 80 / con DNI emite DocTipo 96
  Scenario: Consumidor final sin identificar bajo el umbral
  Scenario: Total sobre el umbral exige identificación
  Scenario: Factura A/B sin desglose no se emite con IVA en cero silenciosamente
Design ref: D2 (DocTipo derivado), D3 (umbral config), D5 (guard A/B)
"""
from __future__ import annotations

import datetime
from decimal import Decimal
from unittest.mock import MagicMock, patch

import pytest

from backend.services.fiscal.fiscal_document_port import CAERequest
from backend.services.fiscal.wsfe_adapter import WSFEAdapter


def _make_approved_wsfe_response():
    mock_resp = MagicMock()
    det = MagicMock()
    det.Resultado = "A"
    det.CAE = "86250464989491"
    det.CAEFchVto = "20261231"
    det.Observaciones = None
    mock_resp.FeDetResp.FECAEDetResponse = [det]
    return mock_resp


def _make_request(
    *,
    comprobante_type: str = "factura_c",
    total: Decimal = Decimal("1000.00"),
    cuit_receptor: str | None = None,
    receptor_doc_tipo: int | None = None,
    receptor_doc_nro: str | None = None,
    neto: Decimal | None = None,
    iva_amount: Decimal | None = None,
    iva_alicuota_id: int | None = None,
) -> CAERequest:
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="dddddddd-dddd-dddd-dddd-dddddddddddd",
        comprobante_type=comprobante_type,
        punto_de_venta=1,
        number=1,
        total=total,
        cuit_emisor="27000000000",
        ambiente="homologacion",
        cuit_receptor=cuit_receptor,
        fecha_comprobante=datetime.date(2026, 6, 26),
        receptor_iva_condition="consumidor_final",
        receptor_doc_tipo=receptor_doc_tipo,
        receptor_doc_nro=receptor_doc_nro,
        neto=neto,
        iva_amount=iva_amount,
        iva_alicuota_id=iva_alicuota_id,
    )


async def _capture_det(adapter: WSFEAdapter, invoice: CAERequest) -> dict:
    captured: dict = {}
    with patch("zeep.Client") as mock_client_cls:
        mock_client = MagicMock()
        mock_client_cls.return_value = mock_client
        mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=0)

        def capture_and_call(**kwargs):
            captured.update(kwargs)
            return _make_approved_wsfe_response()

        mock_client.service.FECAESolicitar.side_effect = capture_and_call
        await adapter._call_wsfe(invoice, "token", "sign")
    return captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]


class TestDocTipoDerivation:
    """6.1/6.2/6.3: DocTipo derivado del receptor."""

    @pytest.mark.asyncio
    async def test_receptor_cuit_emits_doctipo_80(self):
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(receptor_doc_tipo=80, receptor_doc_nro="20-11111111-2")
        det = await _capture_det(adapter, invoice)
        assert det["DocTipo"] == 80
        assert det["DocNro"] == 20111111112

    @pytest.mark.asyncio
    async def test_receptor_dni_emits_doctipo_96(self):
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(receptor_doc_tipo=96, receptor_doc_nro="12345678")
        det = await _capture_det(adapter, invoice)
        assert det["DocTipo"] == 96
        assert det["DocNro"] == 12345678

    @pytest.mark.asyncio
    async def test_no_receptor_defaults_doctipo_99(self):
        """TRIANGULATE: sin receptor y bajo umbral → DocTipo=99, DocNro=0 (comportamiento actual)."""
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(total=Decimal("1000.00"))
        det = await _capture_det(adapter, invoice)
        assert det["DocTipo"] == 99
        assert det["DocNro"] == 0

    @pytest.mark.asyncio
    async def test_legacy_cuit_receptor_derives_doctipo_80(self):
        """TRIANGULATE: cuit_receptor presente sin doc_tipo explícito → CUIT (80)."""
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(cuit_receptor="20999999996")
        det = await _capture_det(adapter, invoice)
        assert det["DocTipo"] == 80
        assert det["DocNro"] == 20999999996


class TestThresholdGuard:
    """6.6/6.7: identificación obligatoria del receptor sobre el umbral."""

    @pytest.mark.asyncio
    async def test_total_over_threshold_without_receptor_raises(self):
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(total=Decimal("10000000.00"))  # == umbral
        with pytest.raises(ValueError) as exc:
            await _capture_det(adapter, invoice)
        msg = str(exc.value).lower()
        assert any(k in msg for k in ["receptor", "identific", "umbral", "10"])

    @pytest.mark.asyncio
    async def test_over_threshold_with_receptor_ok(self):
        """TRIANGULATE: sobre el umbral CON receptor identificado → emite normal."""
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(
            total=Decimal("12000000.00"), receptor_doc_tipo=80, receptor_doc_nro="20999999996"
        )
        det = await _capture_det(adapter, invoice)
        assert det["DocTipo"] == 80

    @pytest.mark.asyncio
    async def test_under_threshold_without_receptor_ok(self):
        """TRIANGULATE: bajo el umbral sin receptor → DocTipo=99 sin fricción."""
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(total=Decimal("9999999.99"))
        det = await _capture_det(adapter, invoice)
        assert det["DocTipo"] == 99


class TestFacturaABBreakdownGuard:
    """6.8/6.9: Factura A/B sin desglose de IVA falla explícito (D5)."""

    @pytest.mark.asyncio
    async def test_factura_b_without_breakdown_raises(self):
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(comprobante_type="factura_b", total=Decimal("1210.00"))
        with pytest.raises(ValueError) as exc:
            await _capture_det(adapter, invoice)
        msg = str(exc.value).lower()
        assert any(k in msg for k in ["iva", "desglose", "neto"])

    @pytest.mark.asyncio
    async def test_factura_b_with_breakdown_ok(self):
        """TRIANGULATE: factura_b CON desglose → emite con array Iva real."""
        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_request(
            comprobante_type="factura_b",
            total=Decimal("1210.00"),
            neto=Decimal("1000.00"),
            iva_amount=Decimal("210.00"),
            iva_alicuota_id=5,
        )
        det = await _capture_det(adapter, invoice)
        assert "Iva" in det
        assert det["Iva"]["AlicIva"][0]["Importe"] == 210.0
