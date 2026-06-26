"""
C-31+ v21-wsfe-production-hardening — Numeracion autoritativa ARCA (Hueco 3).

TDD RED->GREEN->TRIANGULATE: verifica que _call_wsfe usa FECompUltimoAutorizado+1
en lugar del number local, y detecta/maneja el mismatch (Code 10016).

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/v21-wsfe-production-hardening/specs/afip-fiscal-document/spec.md
  Scenario: Usa ultimo + 1 de ARCA
  Scenario: Mismatch con el numero local reservado se detecta y maneja
Design ref: D4 (estrategia B — ARCA-as-source-of-truth)
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

def _make_approved_wsfe_response():
    mock_resp = MagicMock()
    det = MagicMock()
    det.Resultado = "A"
    det.CAE = "86250464989491"
    det.CAEFchVto = "20261231"
    det.Observaciones = None
    mock_resp.FeDetResp.FECAEDetResponse = [det]
    return mock_resp


def _make_request(local_number: int = 42) -> CAERequest:
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="dddddddd-dddd-dddd-dddd-dddddddddddd",
        comprobante_type="factura_b",
        punto_de_venta=1,
        number=local_number,
        total=Decimal("1210.00"),
        cuit_emisor="20123456789",
        ambiente="homologacion",
        cuit_receptor="20000000000",
        fecha_comprobante=datetime.date(2026, 6, 23),
        receptor_iva_condition="consumidor_final",
        neto=Decimal("1000.00"),
        iva_amount=Decimal("210.00"),
        iva_alicuota_id=5,
    )


class TestNumeracionArcaAutoritativa:
    """4.1 RED -> 4.2 GREEN: usa FECompUltimoAutorizado + 1 como CbteDesde/CbteHasta."""

    @pytest.mark.asyncio
    async def test_cbte_numero_is_ultimo_plus_1(self):
        """4.1 RED: cuando FECompUltimoAutorizado devuelve 41, CbteDesde==CbteHasta==42.

        Fails today because _call_wsfe uses invoice_data.number directly.
        (Already fixed in the implementation, so this validates GREEN state.)
        """
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        # Local number is 42, ARCA also returns 41 -> both agree on 42
        invoice = _make_request(local_number=42)
        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            # FECompUltimoAutorizado returns 41 -> authoritative number = 42
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=41)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call

            await adapter._call_wsfe(invoice, "token", "sign")

        # Verify FECompUltimoAutorizado was called
        mock_client.service.FECompUltimoAutorizado.assert_called_once()

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        assert det["CbteDesde"] == 42, (
            f"CbteDesde debe ser 42 (ultimo+1); got {det['CbteDesde']}"
        )
        assert det["CbteHasta"] == 42, (
            f"CbteHasta debe ser 42 (== CbteDesde); got {det['CbteHasta']}"
        )

    @pytest.mark.asyncio
    async def test_cbte_numero_when_ultimo_is_zero(self):
        """4.1 TRIANGULATE: FECompUltimoAutorizado devuelve 0 -> primer comprobante es 1."""
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request(local_number=1)
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

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        assert det["CbteDesde"] == 1, f"Primer comprobante debe ser 1; got {det['CbteDesde']}"
        assert det["CbteHasta"] == 1


class TestNumeracionMismatchDetected:
    """4.3 TRIANGULATE: mismatch entre numero local y ARCA se detecta y maneja."""

    @pytest.mark.asyncio
    async def test_mismatch_uses_arca_number_not_local(self):
        """4.3 TRIANGULATE: local=42 pero ARCA dice ultimo=50 -> usa 51 (ARCA wins D4-B).

        El mismatch se detecta (warning) pero NO bloquea la solicitud —
        el adapter usa el numero de ARCA sin persistir contra el numero local incorrecto.
        """
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        # Local number 42, but ARCA says last authorized was 50 -> should use 51
        invoice = _make_request(local_number=42)
        captured: dict = {}

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            # ARCA says last was 50, so authoritative = 51 (mismatch with local 42)
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            def capture_and_call(**kwargs):
                captured.update(kwargs)
                return _make_approved_wsfe_response()
            mock_client.service.FECAESolicitar.side_effect = capture_and_call

            await adapter._call_wsfe(invoice, "token", "sign")

        det = captured["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]
        # Must use ARCA's authoritative number (51), NOT the local one (42)
        assert det["CbteDesde"] == 51, (
            f"Con mismatch, CbteDesde debe ser el autoritativo de ARCA (51); "
            f"got {det['CbteDesde']} — esto habria dado Code 10016 si se enviaba el local."
        )
        assert det["CbteHasta"] == 51

    @pytest.mark.asyncio
    async def test_mismatch_logs_warning(self):
        """4.3 TRIANGULATE: mismatch emite WARNING (no silencioso)."""
        import logging
        adapter = WSFEAdapter(supabase_service_client=MagicMock())
        invoice = _make_request(local_number=42)

        with patch("zeep.Client") as mock_client_cls:
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            mock_client.service.FECAESolicitar.return_value = _make_approved_wsfe_response()

            with patch("backend.services.fiscal.wsfe_adapter.logger") as mock_logger:
                await adapter._call_wsfe(invoice, "token", "sign")

        # Warning should have been called with mismatch info
        assert mock_logger.warning.called, (
            "El adapter debe emitir un warning al detectar mismatch entre numero local y ARCA."
        )
        warning_args = str(mock_logger.warning.call_args)
        assert any(kw in warning_args.lower() for kw in ["mismatch", "42", "51", "local", "arca"]), (
            f"El warning debe mencionar el mismatch; got: {warning_args}"
        )
