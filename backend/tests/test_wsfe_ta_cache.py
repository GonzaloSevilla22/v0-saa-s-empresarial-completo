"""
C-31+ v21-wsfe-production-hardening — Ticket de Acceso (TA) cache (Hueco 4).

TDD RED->GREEN->TRIANGULATE: verifica que _get_wsaa_token reusa el TA vigente
(NO llama a loginCms de nuevo), y que el cache persiste entre instancias del adapter.

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/v21-wsfe-production-hardening/specs/afip-fiscal-document/spec.md
  Scenario: Reuso del TA vigente evita un nuevo loginCms
  Scenario: TA expirado fuerza re-autenticacion WSAA
  Scenario: La cache persiste entre invocaciones del relay
Design ref: D5 (Postgres store, TicketCache port)
"""
from __future__ import annotations

import datetime
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest

from backend.services.fiscal.fiscal_document_port import CAERequest


# ============================================================
# Helpers
# ============================================================

def _make_request() -> CAERequest:
    return CAERequest(
        account_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        fiscal_document_id="dddddddd-dddd-dddd-dddd-dddddddddddd",
        comprobante_type="factura_b",
        punto_de_venta=1,
        number=42,
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


def _make_mock_platform_provider(representante_cuit: str = "20422662457") -> MagicMock:
    """Crea un PlatformCredentialProvider mock para inyectar en WSFEAdapter (v22)."""
    provider = MagicMock()
    provider.is_configured.return_value = True
    provider.get_cert.return_value = b"-----BEGIN CERTIFICATE-----\nfakecert\n-----END CERTIFICATE-----\n"
    provider.get_key.return_value  = b"-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----\n"
    provider.get_cuit.return_value = representante_cuit
    return provider


def _future_expiry(minutes: int = 60) -> datetime.datetime:
    """Return a datetime in the future (within TA validity window)."""
    return datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=minutes)


def _past_expiry(minutes: int = 60) -> datetime.datetime:
    """Return a datetime in the past (expired TA)."""
    return datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes)


class FakeTicketCache:
    """In-memory TicketCache for testing (mirrors the TicketCache port interface)."""

    def __init__(self):
        self._store: dict = {}

    def get(self, key: str):
        """Return (token, sign, expires_at) if cached and not expired, else None."""
        entry = self._store.get(key)
        if entry is None:
            return None
        token, sign, expires_at = entry
        now = datetime.datetime.now(datetime.timezone.utc)
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=datetime.timezone.utc)
        if expires_at <= now:
            return None
        return token, sign, expires_at

    def set(self, key: str, token: str, sign: str, expires_at: datetime.datetime) -> None:
        self._store[key] = (token, sign, expires_at)


class TestTAcacheReuse:
    """5.1 RED -> 5.2 GREEN: reuso del TA vigente sin llamar a loginCms.

    v22: la cache key usa el CUIT del representante (platform_provider.get_cuit()),
    no el CUIT del emisor. Una entrada de cache por (representante + ambiente).
    """

    @pytest.mark.asyncio
    async def test_valid_cached_ta_reuses_without_login_cms(self):
        """5.1 RED: TA vigente en cache -> _get_wsaa_token NO llama loginCms.

        v22: el adapter requiere un PlatformCredentialProvider; la cache key
        usa el CUIT del representante (20422662457), no el del emisor.
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        cache = FakeTicketCache()
        invoice = _make_request()
        provider = _make_mock_platform_provider(representante_cuit="20422662457")

        # v22: Pre-populate cache con key del REPRESENTANTE (no del emisor)
        cache_key = f"20422662457:wsfe:{invoice.ambiente}"
        cache.set(
            cache_key,
            token="cached-token-xyz",
            sign="cached-sign-xyz",
            expires_at=_future_expiry(60),
        )

        adapter = WSFEAdapter(
            platform_provider=provider,
            ticket_cache=cache,
        )

        with patch.object(adapter, "_call_wsaa", new_callable=AsyncMock) as mock_call_wsaa, \
             patch.object(adapter, "_sign_tra") as mock_sign_tra:

            token, sign = await adapter._get_wsaa_token(invoice)

        # Must NOT call loginCms (TA del representante vigente en cache)
        mock_call_wsaa.assert_not_called()
        mock_sign_tra.assert_not_called()

        # Must return the cached values
        assert token == "cached-token-xyz"
        assert sign  == "cached-sign-xyz"

    @pytest.mark.asyncio
    async def test_no_cache_calls_login_cms(self):
        """5.2 GREEN: sin TA en cache -> llama _call_wsaa (loginCms).

        v22: el adapter usa el cert del platform_provider (no _read_cert_from_storage).
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        cache = FakeTicketCache()  # empty
        invoice = _make_request()
        provider = _make_mock_platform_provider()

        adapter = WSFEAdapter(
            platform_provider=provider,
            ticket_cache=cache,
        )

        fresh_expiry = _future_expiry(600)  # 10h TA validity

        with patch.object(adapter, "_call_wsaa", new_callable=AsyncMock) as mock_call_wsaa, \
             patch.object(adapter, "_sign_tra", return_value="cms-base64") as mock_sign:

            mock_call_wsaa.return_value = ("fresh-token", "fresh-sign", fresh_expiry)

            token, sign = await adapter._get_wsaa_token(invoice)

        mock_call_wsaa.assert_called_once()
        # v22: el cert viene del platform_provider, no de _read_cert_from_storage
        provider.get_cert.assert_called_once()
        provider.get_key.assert_called_once()
        assert token == "fresh-token"
        assert sign  == "fresh-sign"


class TestTAcacheExpiry:
    """5.3 TRIANGULATE: TA expirado fuerza re-autenticacion; cache persiste entre instancias.

    v22: la cache key es '{representante_cuit}:wsfe:{ambiente}' (plataforma, no emisor).
    """

    @pytest.mark.asyncio
    async def test_expired_ta_forces_login_cms(self):
        """5.3 TRIANGULATE: TA expirado -> fuerza nuevo loginCms y actualiza cache.

        v22: usa platform_provider; la cache key es del representante.
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        cache = FakeTicketCache()
        invoice = _make_request()
        provider = _make_mock_platform_provider(representante_cuit="20422662457")

        # v22: Pre-populate con EXPIRED TA keyado por el representante
        cache_key = "20422662457:wsfe:homologacion"
        cache.set(
            cache_key,
            token="old-token",
            sign="old-sign",
            expires_at=_past_expiry(60),   # already expired
        )

        adapter = WSFEAdapter(
            platform_provider=provider,
            ticket_cache=cache,
        )

        fresh_expiry = _future_expiry(600)

        with patch.object(adapter, "_call_wsaa", new_callable=AsyncMock) as mock_call_wsaa, \
             patch.object(adapter, "_sign_tra", return_value="cms-base64"):

            mock_call_wsaa.return_value = ("new-token", "new-sign", fresh_expiry)

            token, sign = await adapter._get_wsaa_token(invoice)

        mock_call_wsaa.assert_called_once()
        assert token == "new-token"
        assert sign  == "new-sign"

        # Cache must be updated with fresh TA (usando la key del representante)
        cached = cache.get(cache_key)
        assert cached is not None, "Cache debe actualizarse con el TA fresco"
        assert cached[0] == "new-token"
        assert cached[1] == "new-sign"

    @pytest.mark.asyncio
    async def test_cache_persists_across_adapter_instances(self):
        """5.3 TRIANGULATE: la cache no es in-process — un segundo adapter con el mismo
        store comparte el TA (simula relay cron + background compartiendo cache Postgres).

        v22: dos adapters con el mismo platform_provider y shared_cache comparten el TA.
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        shared_cache = FakeTicketCache()
        invoice = _make_request()
        # v22: cache key del representante (compartida entre emisores y adapters)
        cache_key = "20422662457:wsfe:homologacion"
        fresh_expiry = _future_expiry(600)

        # First adapter — does loginCms and populates cache
        provider = _make_mock_platform_provider()
        adapter_1 = WSFEAdapter(
            platform_provider=provider,
            ticket_cache=shared_cache,
        )

        with patch.object(adapter_1, "_call_wsaa", new_callable=AsyncMock) as mock_wsaa_1, \
             patch.object(adapter_1, "_sign_tra", return_value="cms"):

            mock_wsaa_1.return_value = ("shared-token", "shared-sign", fresh_expiry)

            token_1, sign_1 = await adapter_1._get_wsaa_token(invoice)

        assert token_1 == "shared-token"
        mock_wsaa_1.assert_called_once()

        # Second adapter with SAME shared_cache — should reuse without calling loginCms
        adapter_2 = WSFEAdapter(
            platform_provider=_make_mock_platform_provider(),
            ticket_cache=shared_cache,
        )

        with patch.object(adapter_2, "_call_wsaa", new_callable=AsyncMock) as mock_wsaa_2, \
             patch.object(adapter_2, "_sign_tra", return_value="cms"):

            token_2, sign_2 = await adapter_2._get_wsaa_token(invoice)

        mock_wsaa_2.assert_not_called()
        assert token_2 == "shared-token"
        assert sign_2  == "shared-sign"
