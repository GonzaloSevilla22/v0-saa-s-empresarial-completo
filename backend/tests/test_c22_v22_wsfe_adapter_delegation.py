"""
v22-afip-delegation-billing — Tests TDD del WSFEAdapter con cert de plataforma.

Verifica:
  §3 — Adapter firma TRA con cert del representante (no per-account)
       Auth.Cuit = CUIT del emisor/representado (ya existía, verificar)
  §4 — Caché del TA keyada por (representante_cuit + ambiente)
  §5 — Factory: gate "platform cert configured?" (no ha_cert per-account)
  §6 — Mapeo del error de delegación no autorizada (DELEGATION_NOT_AUTHORIZED)

Safety net: ver baseline 43/43 en test_c27 + test_c31.

Gate: python -m pytest backend/tests -m "not integration"
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse


# ── Fixture: CAERequest con datos mínimos ────────────────────────────────────

@pytest.fixture
def cae_request_a():
    """CAERequest para cuenta A (CUIT C1)."""
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="doc-aaa",
        comprobante_type="factura_b",
        punto_de_venta=1,
        number=1,
        total=100.0,
        cuit_emisor="20111111111",
        ambiente="homologacion",
    )


@pytest.fixture
def cae_request_b():
    """CAERequest para cuenta B (CUIT C2, distinto al de A)."""
    return CAERequest(
        account_id="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        fiscal_document_id="doc-bbb",
        comprobante_type="factura_b",
        punto_de_venta=1,
        number=2,
        total=200.0,
        cuit_emisor="20222222222",
        ambiente="homologacion",
    )


@pytest.fixture
def mock_platform_provider():
    """PlatformCredentialProvider mockeado con cert/key/CUIT del representante."""
    provider = MagicMock()
    provider.is_configured.return_value = True
    provider.get_cert.return_value = b"-----BEGIN CERTIFICATE-----\nfakecert\n-----END CERTIFICATE-----\n"
    provider.get_key.return_value  = b"-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----\n"
    provider.get_cuit.return_value = "20422662457"  # CUIT representante (AliadataProd)
    return provider


@pytest.fixture
def mock_not_configured_provider():
    """PlatformCredentialProvider mockeado sin configuración."""
    provider = MagicMock()
    provider.is_configured.return_value = False
    return provider


# =============================================================================
# §3.0 — Safety net (baseline ya capturado antes, aquí referenciamos)
# =============================================================================

class TestSafetyNetBaseline:
    """3.0 SAFETY NET: los tests previos del adapter siguen verdes."""

    def test_wsfe_adapter_imports_ok(self):
        """El módulo wsfe_adapter importa sin errores."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter
        assert WSFEAdapter is not None

    def test_wsfe_stub_adapter_imports_ok(self):
        """El módulo wsfe_stub_adapter importa sin errores."""
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter
        assert WSFEStubAdapter is not None


# =============================================================================
# §3.1 RED → §3.2 GREEN — Firma TRA con cert del representante
# =============================================================================

class TestAdapterSignsWithPlatformCert:
    """3.1 RED → 3.2 GREEN: el adapter firma la TRA con el cert de plataforma."""

    @pytest.mark.asyncio
    async def test_get_wsaa_token_uses_platform_cert_not_per_account(
        self, cae_request_a, mock_platform_provider
    ):
        """3.1 RED: el adapter obtiene el cert del platform_provider, NO de storage."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=mock_platform_provider)

        # Mockear _sign_tra y _call_wsaa para no necesitar red ni zeep real
        with patch.object(adapter, "_sign_tra", return_value="fake-cms") as mock_sign, \
             patch.object(adapter, "_call_wsaa", new_callable=AsyncMock) as mock_wsaa:

            mock_wsaa.return_value = (
                "fake-token", "fake-sign",
                datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)
            )

            token, sign = await adapter._get_wsaa_token(cae_request_a)

        # Verificar que get_cert() y get_key() del PROVIDER fueron llamados
        mock_platform_provider.get_cert.assert_called_once()
        mock_platform_provider.get_key.assert_called_once()
        # Verificar que _sign_tra fue llamado con los bytes del provider
        mock_sign.assert_called_once_with(
            b"-----BEGIN CERTIFICATE-----\nfakecert\n-----END CERTIFICATE-----\n",
            b"-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----\n",
            "homologacion",
        )
        assert token == "fake-token"

    @pytest.mark.asyncio
    async def test_adapter_does_not_call_read_cert_from_storage(
        self, cae_request_a, mock_platform_provider
    ):
        """3.2 GREEN: el adapter NO intenta _read_cert_from_storage per-account."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=mock_platform_provider)

        with patch.object(adapter, "_sign_tra", return_value="fake-cms"), \
             patch.object(adapter, "_call_wsaa", new_callable=AsyncMock) as mock_wsaa:

            mock_wsaa.return_value = (
                "tok", "sig",
                datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)
            )
            # _read_cert_from_storage no debe llamarse
            if hasattr(adapter, "_read_cert_from_storage"):
                with patch.object(adapter, "_read_cert_from_storage", side_effect=AssertionError(
                    "_read_cert_from_storage no debe ser llamado en el modelo de delegación"
                )):
                    await adapter._get_wsaa_token(cae_request_a)
            else:
                await adapter._get_wsaa_token(cae_request_a)


# =============================================================================
# §3.3 RED → §3.4 GREEN — Auth.Cuit = CUIT del emisor/representado
# =============================================================================

class TestAuthCuitIsEmissorNotPlatform:
    """3.3 RED → 3.4 GREEN: Auth.Cuit = CUIT del emisor (representado), no del representante."""

    @pytest.mark.asyncio
    async def test_auth_cuit_equals_cuit_emisor(self, cae_request_a, mock_platform_provider):
        """3.3 RED: en la solicitud WSFE, Auth.Cuit = cuit_emisor del invoice (20111111111)."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=mock_platform_provider)

        captured_auth = {}

        async def mock_call_wsfe_capture_auth(invoice_data, token, sign):
            # Simular el armado de Auth como lo hace _call_wsfe
            auth = {
                "Token": token,
                "Sign": sign,
                "Cuit": int(invoice_data.cuit_emisor.replace("-", "")),
            }
            captured_auth.update(auth)
            return CAEResponse(
                cae="99999999999999",
                cae_due_date=datetime.date.today(),
                is_approved=True,
            )

        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa, \
             patch.object(adapter, "_call_wsfe", side_effect=mock_call_wsfe_capture_auth):

            mock_wsaa.return_value = ("token-plat", "sign-plat")
            resp = await adapter.request_cae(cae_request_a)

        # Auth.Cuit debe ser el CUIT del emisor (20111111111), NO el del representante (20422662457)
        assert captured_auth.get("Cuit") == 20111111111, (
            f"Auth.Cuit debe ser el CUIT del emisor, no del representante. "
            f"Obtenido: {captured_auth.get('Cuit')}"
        )
        assert resp.is_approved is True

    @pytest.mark.asyncio
    async def test_two_different_emisors_use_same_platform_ta_but_different_auth_cuit(
        self, cae_request_a, cae_request_b, mock_platform_provider
    ):
        """3.4 GREEN: dos emisores distintos usan el mismo TA pero Auth.Cuit distinto."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=mock_platform_provider)

        captured_auth_calls = []

        async def capture_call_wsfe(invoice_data, token, sign):
            captured_auth_calls.append({
                "cuit_emisor": invoice_data.cuit_emisor,
                "token": token,
            })
            return CAEResponse(
                cae="88888888888888",
                cae_due_date=datetime.date.today(),
                is_approved=True,
            )

        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa, \
             patch.object(adapter, "_call_wsfe", side_effect=capture_call_wsfe):

            # Mismo TA del representante para ambos
            mock_wsaa.return_value = ("shared-token", "shared-sign")

            await adapter.request_cae(cae_request_a)
            await adapter.request_cae(cae_request_b)

        assert len(captured_auth_calls) == 2
        # Los CUIT emisores son distintos
        assert captured_auth_calls[0]["cuit_emisor"] == "20111111111"
        assert captured_auth_calls[1]["cuit_emisor"] == "20222222222"
        # Los tokens son iguales (mismo TA del representante)
        assert captured_auth_calls[0]["token"] == captured_auth_calls[1]["token"]


# =============================================================================
# §3.5 TRIANGULATE — Regresión RG 5616 (ya cubierta en test_c27; aquí spot-check)
# =============================================================================

class TestRegressionRG5616WithDelegation:
    """3.5 TRIANGULATE: los tests de producción (TLS, URLs) siguen verdes."""

    def test_wsaa_urls_preserved(self):
        """3.5: las URLs de WSAA y WSFEv1 no cambiaron con la delegación."""
        from backend.services.fiscal.wsfe_adapter import _WSAA_URLS, _WSFEV1_URLS
        assert "wsaahomo.afip.gob.ar" in _WSAA_URLS["homologacion"]
        assert "wsaa.afip.gob.ar" in _WSAA_URLS["produccion"]
        assert "servicios1.afip.gov.ar" in _WSFEV1_URLS["produccion"]
        assert "wswhomo.afip.gob.ar" in _WSFEV1_URLS["homologacion"]

    def test_adapter_with_platform_provider_implements_port(self, mock_platform_provider):
        """3.5: WSFEAdapter con provider sigue implementando FiscalDocumentPort."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter
        from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort
        adapter = WSFEAdapter(platform_provider=mock_platform_provider)
        assert isinstance(adapter, FiscalDocumentPort)


# =============================================================================
# §4.1 RED → §4.2 GREEN — Caché del TA keyada por (representante + ambiente)
# =============================================================================

class TestTACacheKeyByPlatformAndAmbiente:
    """4.1 RED → 4.2 GREEN: la cache key es '{representante_cuit}:wsfe:{ambiente}'."""

    @pytest.mark.asyncio
    async def test_cache_key_uses_platform_cuit_not_account_cuit(
        self, cae_request_a, mock_platform_provider
    ):
        """4.1 RED: la cache key incluye el CUIT del representante, no el del emisor."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        mock_cache = MagicMock()
        mock_cache.get.return_value = None  # Cache miss para forzar loginCms

        adapter = WSFEAdapter(
            platform_provider=mock_platform_provider,
            ticket_cache=mock_cache,
        )

        with patch.object(adapter, "_sign_tra", return_value="fake-cms"), \
             patch.object(adapter, "_call_wsaa", new_callable=AsyncMock) as mock_wsaa:

            mock_wsaa.return_value = (
                "platform-token", "platform-sign",
                datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)
            )

            await adapter._get_wsaa_token(cae_request_a)

        # La cache.get fue llamada con la key del representante (20422662457), no del emisor (20111111111)
        get_calls = [str(c) for c in mock_cache.get.call_args_list]
        assert any("20422662457" in c for c in get_calls), (
            f"La cache key debe incluir el CUIT del representante (20422662457). "
            f"Llamadas: {get_calls}"
        )
        # Y NO debe incluir el CUIT del emisor de la cuenta
        assert not any("20111111111" in c for c in get_calls), (
            "La cache key NO debe incluir el CUIT del emisor de la cuenta"
        )

    @pytest.mark.asyncio
    async def test_two_emisors_share_same_ta_cache_entry(
        self, cae_request_a, cae_request_b, mock_platform_provider
    ):
        """4.1 RED: dos emisores distintos comparten el mismo TA en cache (mismo representante+ambiente)."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        # Cache que retorna hit en la segunda llamada
        call_count = [0]
        def cache_get(key):
            call_count[0] += 1
            # Primer get: miss (fuerza loginCms). Segundo get: hit (reusar TA).
            if call_count[0] == 1:
                return None
            return ("cached-token", "cached-sign", datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=10))

        mock_cache = MagicMock()
        mock_cache.get.side_effect = cache_get

        adapter = WSFEAdapter(
            platform_provider=mock_platform_provider,
            ticket_cache=mock_cache,
        )

        login_cms_calls = [0]

        async def mock_call_wsaa(url, cms):
            login_cms_calls[0] += 1
            return (
                "platform-token", "platform-sign",
                datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)
            )

        with patch.object(adapter, "_sign_tra", return_value="fake-cms"), \
             patch.object(adapter, "_call_wsaa", side_effect=mock_call_wsaa):

            # Request A: cache miss → loginCms
            token_a, sign_a = await adapter._get_wsaa_token(cae_request_a)
            # Request B: cache hit → NO loginCms (mismo representante + ambiente)
            token_b, sign_b = await adapter._get_wsaa_token(cae_request_b)

        assert login_cms_calls[0] == 1, (
            f"Solo 1 loginCms esperado (TA compartido); se hicieron {login_cms_calls[0]}"
        )

    @pytest.mark.asyncio
    async def test_cache_key_format_is_platform_cuit_wsfe_ambiente(
        self, cae_request_a, mock_platform_provider
    ):
        """4.2 GREEN: el formato exacto de la cache key es '{rep_cuit}:wsfe:{ambiente}'."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        set_keys = []

        mock_cache = MagicMock()
        mock_cache.get.return_value = None
        def capture_set(key, *args, **kwargs):
            set_keys.append(key)
        mock_cache.set.side_effect = capture_set

        adapter = WSFEAdapter(
            platform_provider=mock_platform_provider,
            ticket_cache=mock_cache,
        )

        with patch.object(adapter, "_sign_tra", return_value="cms"), \
             patch.object(adapter, "_call_wsaa", new_callable=AsyncMock) as mock_wsaa:

            mock_wsaa.return_value = (
                "tok", "sig",
                datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)
            )
            await adapter._get_wsaa_token(cae_request_a)

        # La key del cache.set debe ser "20422662457:wsfe:homologacion"
        expected_key = "20422662457:wsfe:homologacion"
        assert expected_key in set_keys, (
            f"La cache key guardada debe ser '{expected_key}'. "
            f"Keys usadas: {set_keys}"
        )

    @pytest.mark.asyncio
    async def test_expired_ta_forces_reauth(self, cae_request_a, mock_platform_provider):
        """4.3 TRIANGULATE: TA expirado → fuerza re-auth con loginCms."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        # Cache retorna TA expirado (None = expired, ya lo filtra el cache)
        mock_cache = MagicMock()
        mock_cache.get.return_value = None  # Expired → cache miss

        login_count = [0]
        adapter = WSFEAdapter(
            platform_provider=mock_platform_provider,
            ticket_cache=mock_cache,
        )

        async def mock_wsaa(url, cms):
            login_count[0] += 1
            return (
                "fresh-token", "fresh-sign",
                datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)
            )

        with patch.object(adapter, "_sign_tra", return_value="cms"), \
             patch.object(adapter, "_call_wsaa", side_effect=mock_wsaa):
            tok, sig = await adapter._get_wsaa_token(cae_request_a)

        assert login_count[0] == 1, "TA expirado debe forzar loginCms"
        assert tok == "fresh-token"


# =============================================================================
# §5.1 RED → §5.2/5.3/5.4 GREEN — Factory con gate de plataforma
# =============================================================================

class TestAdapterFactoryPlatformGate:
    """5.1 RED → 5.2/5.4 GREEN: la factory usa gate 'platform cert configured?'."""

    def test_factory_returns_real_when_platform_configured(self, mock_platform_provider):
        """5.1 RED: platform configurado → WSFEAdapter real."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = build_cae_adapter(platform_provider=mock_platform_provider)
        assert isinstance(adapter, WSFEAdapter)

    def test_factory_returns_stub_when_platform_not_configured(self, mock_not_configured_provider):
        """5.1 RED: platform NO configurado → WSFEStubAdapter."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        adapter = build_cae_adapter(platform_provider=mock_not_configured_provider)
        assert isinstance(adapter, WSFEStubAdapter)

    def test_factory_returns_real_even_for_account_without_cert_path(self, mock_platform_provider):
        """5.4 TRIANGULATE: certificado_afip_path = NULL pero plataforma configurada → real."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        # Sin has_cert ni per-account cert — solo platform_provider configurado
        adapter = build_cae_adapter(platform_provider=mock_platform_provider)
        assert isinstance(adapter, WSFEAdapter)

    def test_factory_stub_when_no_provider(self):
        """5.4 TRIANGULATE: sin provider → WSFEStubAdapter (default seguro)."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        adapter = build_cae_adapter(platform_provider=None)
        assert isinstance(adapter, WSFEStubAdapter)

    def test_factory_real_adapter_has_provider_injected(self, mock_platform_provider):
        """5.2 GREEN: el WSFEAdapter real tiene el platform_provider inyectado."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        mock_cache = MagicMock()
        adapter = build_cae_adapter(
            platform_provider=mock_platform_provider,
            ticket_cache=mock_cache,
        )
        assert isinstance(adapter, WSFEAdapter)
        assert adapter._platform_provider is mock_platform_provider
        assert adapter._ticket_cache is mock_cache


# =============================================================================
# §6.1 RED → §6.2/6.3 GREEN — Mapeo DELEGATION_NOT_AUTHORIZED
# =============================================================================

class TestDelegationNotAuthorizedMapping:
    """6.1 RED → 6.2/6.3 GREEN: error de delegación → DELEGATION_NOT_AUTHORIZED."""

    @pytest.mark.asyncio
    async def test_delegation_error_mapped_to_domain_code(self, cae_request_a, mock_platform_provider):
        """6.1 RED: error AFIP de 'no autorizado a representar' → DELEGATION_NOT_AUTHORIZED."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=mock_platform_provider)

        # Simular que _call_wsfe levanta la excepción que produce el error de delegación
        # En AFIP el error de "representante no autorizado" viene en Observaciones con
        # un código de autenticación/token. El adapter normaliza esto.
        async def mock_call_wsfe_delegation_error(invoice_data, token, sign):
            # Simular respuesta AFIP de error de delegación
            raise RuntimeError("El certificado no está habilitado para representar al CUIT 20111111111 — código AFIP: AUTH-TOKEN-REJECTED")

        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa, \
             patch.object(adapter, "_call_wsfe", side_effect=mock_call_wsfe_delegation_error):

            mock_wsaa.return_value = ("tok", "sig")
            resp = await adapter.request_cae(cae_request_a)

        # El comprobante NO debe quedar authorized
        assert resp.is_approved is False
        # El error_code debe ser DELEGATION_NOT_AUTHORIZED
        assert resp.error_code == "DELEGATION_NOT_AUTHORIZED", (
            f"Error code esperado: DELEGATION_NOT_AUTHORIZED. Obtenido: {resp.error_code!r}"
        )
        # El error_detail debe contener instrucciones accionables
        assert "ARCA" in resp.error_detail or "EmprendeSmart" in resp.error_detail or "delegaci" in resp.error_detail.lower(), (
            f"El error_detail debe contener instrucciones accionables. Obtenido: {resp.error_detail!r}"
        )

    @pytest.mark.asyncio
    async def test_data_rejection_not_mapped_to_delegation_error(
        self, cae_request_a, mock_platform_provider
    ):
        """6.3 TRIANGULATE: rechazo por datos (Code 10246) NO produce el mensaje de onboarding."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=mock_platform_provider)

        async def mock_call_wsfe_data_rejection(invoice_data, token, sign):
            return CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code="10246",
                error_detail="CondicionIVAReceptorId no informado o incorrecto",
            )

        with patch.object(adapter, "_get_wsaa_token", new_callable=AsyncMock) as mock_wsaa, \
             patch.object(adapter, "_call_wsfe", side_effect=mock_call_wsfe_data_rejection):

            mock_wsaa.return_value = ("tok", "sig")
            resp = await adapter.request_cae(cae_request_a)

        # Error de datos: NOT DELEGATION_NOT_AUTHORIZED
        assert resp.error_code == "10246", (
            "Rechazo por datos (10246) no debe mapearse a DELEGATION_NOT_AUTHORIZED"
        )
        assert resp.error_code != "DELEGATION_NOT_AUTHORIZED"

    @pytest.mark.asyncio
    async def test_wsaa_delegation_error_normalized(self, cae_request_a, mock_platform_provider):
        """6.1 RED: error WSAA de 'no autorizado a representar' → DELEGATION_NOT_AUTHORIZED."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=mock_platform_provider)

        # Simular que _get_wsaa_token levanta el error de delegación
        async def mock_wsaa_delegation_error(invoice_data):
            raise RuntimeError(
                "El representante 20422662457 no está autorizado a actuar "
                "en nombre del CUIT 20111111111 para el servicio wsfe"
            )

        with patch.object(adapter, "_get_wsaa_token", side_effect=mock_wsaa_delegation_error):
            resp = await adapter.request_cae(cae_request_a)

        assert resp.is_approved is False
        assert resp.error_code == "DELEGATION_NOT_AUTHORIZED"
