"""
C-31+ v21-wsfe-production-hardening — CondicionIVAReceptorId (Hueco 1, RG 5616).

TDD RED->GREEN->TRIANGULATE: verifica que _call_wsfe incluye CondicionIVAReceptorId
en el FECAEDetRequest, mapeado desde CAERequest.receptor_iva_condition.

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/v21-wsfe-production-hardening/specs/afip-fiscal-document/spec.md
  Scenario: CondicionIVAReceptorId presente para consumidor final
Design ref: D2
"""
from __future__ import annotations

import datetime
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest

from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse
from backend.services.fiscal.wsfe_adapter import WSFEAdapter

# ============================================================
# Helpers
# ============================================================

def _make_request(
    comprobante_type: str = "factura_b",
    receptor_iva_condition: str = "consumidor_final",
    cuit_receptor: str | None = "20000000000",
) -> CAERequest:
    """Build a minimal CAERequest with the new receptor_iva_condition field."""
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="dddddddd-dddd-dddd-dddd-dddddddddddd",
        comprobante_type=comprobante_type,
        punto_de_venta=1,
        number=42,
        total=Decimal("1210.00"),
        cuit_emisor="20123456789",
        ambiente="homologacion",
        cuit_receptor=cuit_receptor,
        fecha_comprobante=datetime.date(2026, 6, 23),
        receptor_iva_condition=receptor_iva_condition,
        neto=Decimal("1000.00"),
        iva_amount=Decimal("210.00"),
        iva_alicuota_id=5,
    )


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


class TestCondicionIVAReceptorId:
    """2.1 RED -> 2.2 GREEN -> 2.3 TRIANGULATE: CondicionIVAReceptorId."""

    @pytest.mark.asyncio
    async def test_consumidor_final_gets_condicion_id_5(self):
        """2.1 RED: FECAEDetRequest tiene CondicionIVAReceptorId=5 para consumidor_final.

        Fails today because _call_wsfe does NOT include CondicionIVAReceptorId.
        """
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request(receptor_iva_condition="consumidor_final")

        captured: dict = {}

        import zeep as _zeep_real  # noqa: F401 — available in test env

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECAESolicitar.return_value = _make_approved_wsfe_response()
            # Intercept the call to capture the request body
            original_call = mock_client.service.FECAESolicitar.side_effect
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=41)

            await adapter._call_wsfe(invoice, "token", "sign")

        det_request = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        assert "CondicionIVAReceptorId" in det_request, (
            "CondicionIVAReceptorId NO esta en FECAEDetRequest — Code 10246 en produccion."
        )
        assert det_request["CondicionIVAReceptorId"] == 5, (
            f"consumidor_final debe mapear a id 5 (RG 5616); "
            f"got {det_request['CondicionIVAReceptorId']}"
        )

    @pytest.mark.asyncio
    async def test_responsable_inscripto_gets_condicion_id_1(self):
        """2.3 TRIANGULATE: responsable_inscripto -> id 1 (RG 5616 tabla D2)."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request(receptor_iva_condition="responsable_inscripto")

        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=10)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call

            await adapter._call_wsfe(invoice, "token", "sign")

        det_request = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        assert det_request.get("CondicionIVAReceptorId") == 1, (
            f"responsable_inscripto debe mapear a id 1; got {det_request.get('CondicionIVAReceptorId')}"
        )

    @pytest.mark.asyncio
    async def test_monotributista_gets_condicion_id_6(self):
        """2.3 TRIANGULATE: monotributista -> id 6."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request(receptor_iva_condition="monotributista")

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

        det_request = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        assert det_request.get("CondicionIVAReceptorId") == 6

    @pytest.mark.asyncio
    async def test_exento_gets_condicion_id_4(self):
        """2.3 TRIANGULATE: exento -> id 4."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request(receptor_iva_condition="exento")

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

        det_request = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        assert det_request.get("CondicionIVAReceptorId") == 4

    @pytest.mark.asyncio
    async def test_unknown_condition_raises_normalized_error(self):
        """2.3 TRIANGULATE borde: condicion sin mapeo levanta error normalizado (NO omite el campo).

        Omitir CondicionIVAReceptorId -> Code 10246 en produccion.
        El adapter DEBE fallar explicitamente antes de llegar a ARCA.
        """
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request(receptor_iva_condition="condicion_desconocida_xyz")

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(Nro=0)

            with pytest.raises((ValueError, KeyError, RuntimeError)) as exc_info:
                await adapter._call_wsfe(invoice, "token", "sign")

        # El error debe mencionar la condicion o el campo
        error_str = str(exc_info.value).lower()
        assert any(kw in error_str for kw in ["condicion", "iva", "receptor", "unknown", "10246", "condicion_desconocida"]), (
            f"El error debe mencionar la condicion IVA desconocida; got: {exc_info.value}"
        )
