"""
v22-afip-delegation-billing — Tests TDD para PlatformCredentialProvider.

Verifica que el provider:
  - Resuelve cert + key + CUIT representante desde settings
  - Retorna "no configurado" cuando faltan variables
  - NUNCA loguea ni devuelve la key privada
  - `is_configured()` refleja el estado correcto

Spec ref: specs/afip-platform-credential/spec.md
Design ref: D3 (cert de plataforma server-side), OQ-3 (env vars en Render)

Gate: python -m pytest backend/tests -m "not integration"
"""
from __future__ import annotations

import logging
from unittest.mock import patch

import pytest


# =============================================================================
# §2.1 RED → §2.2 GREEN — PlatformCredentialProvider resolución desde settings
# =============================================================================

class TestPlatformCredentialProviderResolution:
    """2.1 RED → 2.2 GREEN: el provider resuelve cert/key/CUIT desde settings."""

    def test_provider_exists(self):
        """2.1 RED: PlatformCredentialProvider existe."""
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider
        assert PlatformCredentialProvider is not None

    def test_provider_configured_returns_cert_bytes(self):
        """2.2 GREEN: cuando AFIP_PLATFORM_CERT está seteado, get_cert() retorna bytes."""
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider

        fake_cert = b"-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n"
        fake_key  = b"-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----\n"

        with patch.dict("os.environ", {
            "AFIP_PLATFORM_CERT": fake_cert.decode(),
            "AFIP_PLATFORM_KEY":  fake_key.decode(),
            "AFIP_PLATFORM_CUIT": "20422662457",
        }, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            from backend.core.config import settings as _settings
            provider = PlatformCredentialProvider(settings=_settings)
            cert = provider.get_cert()

        assert isinstance(cert, bytes)
        assert b"BEGIN CERTIFICATE" in cert

    def test_provider_configured_returns_cuit(self):
        """2.2 GREEN: cuando configurado, get_cuit() retorna el CUIT del representante."""
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider

        with patch.dict("os.environ", {
            "AFIP_PLATFORM_CERT": "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----",
            "AFIP_PLATFORM_KEY":  "-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----",
            "AFIP_PLATFORM_CUIT": "20422662457",
        }, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            provider = PlatformCredentialProvider(settings=cfg_mod.settings)
            cuit = provider.get_cuit()

        assert cuit == "20422662457"

    def test_provider_is_configured_true_when_all_set(self):
        """2.2 GREEN: is_configured() = True cuando cert+key+CUIT están en settings."""
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider

        with patch.dict("os.environ", {
            "AFIP_PLATFORM_CERT": "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----",
            "AFIP_PLATFORM_KEY":  "-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----",
            "AFIP_PLATFORM_CUIT": "20422662457",
        }, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            provider = PlatformCredentialProvider(settings=cfg_mod.settings)
            assert provider.is_configured() is True


# =============================================================================
# §2.3 TRIANGULATE — casos no configurado / parcial
# =============================================================================

class TestPlatformCredentialProviderNotConfigured:
    """2.3 TRIANGULATE: casos donde el cert no está configurado."""

    def _make_provider_with_env(self, env_overrides: dict):
        """Helper: crea un provider con env vars específicas (limpia las del cert primero)."""
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider

        base_env = {
            "AFIP_PLATFORM_CERT": "",
            "AFIP_PLATFORM_KEY":  "",
            "AFIP_PLATFORM_CUIT": "",
        }
        base_env.update(env_overrides)

        with patch.dict("os.environ", base_env, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            return PlatformCredentialProvider(settings=cfg_mod.settings)

    def test_not_configured_when_cert_missing(self):
        """2.3 TRIANGULATE: sin AFIP_PLATFORM_CERT → is_configured() = False."""
        provider = self._make_provider_with_env({
            "AFIP_PLATFORM_CERT": "",
            "AFIP_PLATFORM_KEY":  "-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----",
            "AFIP_PLATFORM_CUIT": "20422662457",
        })
        assert provider.is_configured() is False

    def test_not_configured_when_key_missing(self):
        """2.3 TRIANGULATE: sin AFIP_PLATFORM_KEY → is_configured() = False."""
        provider = self._make_provider_with_env({
            "AFIP_PLATFORM_CERT": "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----",
            "AFIP_PLATFORM_KEY":  "",
            "AFIP_PLATFORM_CUIT": "20422662457",
        })
        assert provider.is_configured() is False

    def test_not_configured_when_cuit_missing(self):
        """2.3 TRIANGULATE: sin AFIP_PLATFORM_CUIT → is_configured() = False."""
        provider = self._make_provider_with_env({
            "AFIP_PLATFORM_CERT": "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----",
            "AFIP_PLATFORM_KEY":  "-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----",
            "AFIP_PLATFORM_CUIT": "",
        })
        assert provider.is_configured() is False

    def test_get_cert_raises_when_not_configured(self):
        """2.3 TRIANGULATE: get_cert() lanza RuntimeError cuando no configurado."""
        provider = self._make_provider_with_env({})
        with pytest.raises(RuntimeError, match="no configurado"):
            provider.get_cert()

    def test_get_key_raises_when_not_configured(self):
        """2.3 TRIANGULATE: get_key() lanza RuntimeError cuando no configurado."""
        provider = self._make_provider_with_env({})
        with pytest.raises(RuntimeError, match="(?i)no configurad"):
            provider.get_key()


# =============================================================================
# §2.4 — Verificación de no-exposición de la key privada
# =============================================================================

class TestPlatformKeyNeverExposed:
    """2.4: la key privada del representante NO aparece en logs ni en el repr del provider."""

    def test_provider_repr_does_not_contain_key_material(self):
        """2.4: __repr__ y __str__ del provider no filtran el PEM de la key."""
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider

        fake_key = "-----BEGIN RSA PRIVATE KEY-----\nSECRET_KEY_MATERIAL\n-----END RSA PRIVATE KEY-----"

        with patch.dict("os.environ", {
            "AFIP_PLATFORM_CERT": "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----",
            "AFIP_PLATFORM_KEY":  fake_key,
            "AFIP_PLATFORM_CUIT": "20422662457",
        }, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            provider = PlatformCredentialProvider(settings=cfg_mod.settings)

        provider_str = str(provider)
        provider_repr = repr(provider)

        assert "SECRET_KEY_MATERIAL" not in provider_str, (
            "El __str__ del provider no debe contener material de la key privada"
        )
        assert "SECRET_KEY_MATERIAL" not in provider_repr, (
            "El __repr__ del provider no debe contener material de la key privada"
        )

    def test_provider_log_does_not_contain_key_material(self, caplog):
        """2.4: el constructor del provider no loguea la key privada."""
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider

        fake_key = "-----BEGIN RSA PRIVATE KEY-----\nSECRET_KEY_LOGTEST\n-----END RSA PRIVATE KEY-----"

        with caplog.at_level(logging.DEBUG, logger="backend"), \
             patch.dict("os.environ", {
                 "AFIP_PLATFORM_CERT": "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----",
                 "AFIP_PLATFORM_KEY":  fake_key,
                 "AFIP_PLATFORM_CUIT": "20422662457",
             }, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            PlatformCredentialProvider(settings=cfg_mod.settings)

        all_logs = caplog.text
        assert "SECRET_KEY_LOGTEST" not in all_logs, (
            "El provider NO debe loguear el material de la key privada"
        )

    def test_settings_env_vars_exist_in_config(self):
        """2.2 GREEN: los campos afip_platform_cert/key/cuit existen en Settings."""
        from backend.core.config import Settings
        fields = Settings.model_fields
        assert "afip_platform_cert" in fields, "Settings debe tener afip_platform_cert"
        assert "afip_platform_key"  in fields, "Settings debe tener afip_platform_key"
        assert "afip_platform_cuit" in fields, "Settings debe tener afip_platform_cuit"
