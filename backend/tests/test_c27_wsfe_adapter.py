"""
C-27 v21-fiscal-profile — WSFEAdapter real (tests con SOAP mockeado, sin red).

Task 2.5: tests del adaptador real con el cliente SOAP mockeado.
El test de integración real contra homologación va marcado con
@pytest.mark.integration y excluido del gate de CI.

Spec ref: afip-fiscal-document/spec.md §"Adaptador WSFE detrás de un ACL"
Design ref: D4, D7
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse
from backend.services.fiscal.wsfe_adapter import WSFEAdapter


@pytest.fixture
def cae_request():
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="dddddddd-dddd-dddd-dddd-dddddddddddd",
        comprobante_type="factura_b",
        punto_de_venta=1,
        number=42,
        total=1500.0,
        cuit_emisor="20123456789",
        ambiente="homologacion",
    )


class TestWSFEAdapterMocked:
    """Tests del adaptador real con cliente SOAP mockeado (sin red)."""

    def _make_adapter_with_mocked_client(self):
        """Crear adapter con service_client mockeado para lectura de cert."""
        mock_supa = MagicMock()
        mock_supa.storage.from_.return_value.download.return_value = b"fake-cert-content"
        return WSFEAdapter(supabase_service_client=mock_supa)

    @pytest.mark.asyncio
    async def test_adapter_implements_port(self):
        """WSFEAdapter implementa FiscalDocumentPort."""
        from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort
        adapter = self._make_adapter_with_mocked_client()
        assert isinstance(adapter, FiscalDocumentPort)

    @pytest.mark.asyncio
    async def test_adapter_returns_approved_when_soap_returns_approved(self, cae_request):
        """Cuando SOAP retorna Resultado=A, el adapter retorna CAEResponse is_approved=True."""
        adapter = self._make_adapter_with_mocked_client()

        # Mock del token WSAA y la llamada WSFE
        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa, \
             patch.object(adapter, "_call_wsfe", new_callable=AsyncMock) as mock_wsfe:

            mock_wsaa.return_value = ("token-fake", "sign-fake")
            mock_wsfe.return_value = CAEResponse(
                cae="12345678901234",
                cae_due_date=datetime.date(2026, 7, 15),
                is_approved=True,
            )

            resp = await adapter.request_cae(cae_request)

        assert resp.is_approved is True
        assert resp.cae == "12345678901234"
        mock_wsaa.assert_called_once_with(cae_request)
        mock_wsfe.assert_called_once_with(cae_request, "token-fake", "sign-fake")

    @pytest.mark.asyncio
    async def test_adapter_returns_rejected_when_soap_rejects(self, cae_request):
        """Cuando SOAP retorna rechazo, el adapter retorna CAEResponse is_approved=False."""
        adapter = self._make_adapter_with_mocked_client()

        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa, \
             patch.object(adapter, "_call_wsfe", new_callable=AsyncMock) as mock_wsfe:

            mock_wsaa.return_value = ("tok", "sig")
            mock_wsfe.return_value = CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code="10016",
                error_detail="CUIT no autorizado",
            )

            resp = await adapter.request_cae(cae_request)

        assert resp.is_approved is False
        assert resp.error_code == "10016"

    @pytest.mark.asyncio
    async def test_adapter_returns_rejected_on_exception(self, cae_request):
        """Cuando WSAA/WSFE lanza excepción, el adapter retorna CAEResponse is_approved=False."""
        adapter = self._make_adapter_with_mocked_client()

        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa:
            mock_wsaa.side_effect = ConnectionError("AFIP no responde")
            resp = await adapter.request_cae(cae_request)

        assert resp.is_approved is False
        assert "AFIP no responde" in resp.error_detail

    @pytest.mark.asyncio
    async def test_adapter_resolves_ambiente_from_profile(self, cae_request):
        """El adapter usa el ambiente del perfil de la cuenta (D2), no una env var."""
        adapter = self._make_adapter_with_mocked_client()

        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa, \
             patch.object(adapter, "_call_wsfe", new_callable=AsyncMock) as mock_wsfe:

            mock_wsaa.return_value = ("tok", "sig")
            mock_wsfe.return_value = CAEResponse(cae="00000000000001", cae_due_date=datetime.date.today(), is_approved=True)

            # Perfil en homologacion
            cae_request.ambiente = "homologacion"
            await adapter.request_cae(cae_request)

            # El token se pidió con el request que tiene ambiente="homologacion"
            call_arg = mock_wsaa.call_args[0][0]
            assert call_arg.ambiente == "homologacion"


@pytest.mark.integration
class TestWSFEAdapterRealHomologacion:
    """Tests de integración real contra homologación de ARCA.

    Marcados con @pytest.mark.integration y EXCLUIDOS del gate de CI
    (homologación intermitente — PA-22).

    Para correr manualmente:
        pytest -m integration tests/test_c27_wsfe_adapter.py -v

    Requiere:
    - SUPABASE_SERVICE_ROLE_KEY en el entorno
    - Certificado real en bucket afip-certs/<account_id>/afip.crt y afip.key
    - Cuenta de homologación activa en ARCA
    """

    @pytest.mark.asyncio
    async def test_real_cae_homologacion(self):
        """Solicita un CAE real en homologación de ARCA."""
        pytest.skip("Test de integración real — requiere cert homologación ARCA (PA-22)")
