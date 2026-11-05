"""
mp-cuota-acreditacion-resiliente 3.5 (D5, OQ-2 (a)) — `require_relay_secret`:
la verificación del secreto compartido de los endpoints de máquina que
dispara `pg_cron`, extraída del inline de
`backend/routers/fiscal.py::process_pending_cae_cron` a una dependencia
única que también usa el barrido de suscripciones
(`POST /payments/subscriptions/reconcile-cron`). Fail-closed: sin secreto
configurado, sin cabecera o con el secreto equivocado → 401.

El contrato HTTP del endpoint fiscal lo sigue fijando
`test_c27_cae_relay_trigger.py` (la red de seguridad de esta extracción).
"""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import patch

import pytest
from fastapi import HTTPException

from backend.core.guards import require_relay_secret

SECRET = "relay-secret-de-prueba"


def _request(authorization: str | None) -> SimpleNamespace:
    headers = {} if authorization is None else {"Authorization": authorization}
    return SimpleNamespace(headers=headers)


def _call(configured: str | None, authorization: str | None) -> None:
    with patch("backend.core.config.settings.relay_secret", configured):
        require_relay_secret(_request(authorization))


class TestRequireRelaySecret:
    def test_correct_secret_passes(self):
        _call(SECRET, f"Bearer {SECRET}")

    @pytest.mark.parametrize("configured", [None, ""])
    def test_unconfigured_secret_rejects_everything(self, configured):
        """Fail-closed: sin `RELAY_SECRET` ninguna llamada pasa — ni siquiera
        una que mande `Bearer ` vacío (que igualaría al secreto vacío)."""
        with pytest.raises(HTTPException) as exc:
            _call(configured, "Bearer ")
        assert exc.value.status_code == 401

    @pytest.mark.parametrize("authorization", [None, "", SECRET, f"Basic {SECRET}", "Bearer otro-secreto"])
    def test_missing_malformed_or_wrong_header_is_401(self, authorization):
        with pytest.raises(HTTPException) as exc:
            _call(SECRET, authorization)
        assert exc.value.status_code == 401

    def test_comparison_is_constant_time(self):
        """La comparación pasa por `hmac.compare_digest` (nunca `==`)."""
        with patch("backend.core.guards.hmac.compare_digest", return_value=False) as cmp:
            with pytest.raises(HTTPException):
                _call(SECRET, f"Bearer {SECRET}")
        cmp.assert_called_once_with(SECRET.encode(), SECRET.encode())

    def test_non_ascii_header_is_401_not_500(self):
        """TRIANGULATE: una cabecera con caracteres no-ASCII se rechaza con
        401 — con `compare_digest` sobre str lanzaría TypeError (500)."""
        with pytest.raises(HTTPException) as exc:
            _call(SECRET, "Bearer contraseña-ñ")
        assert exc.value.status_code == 401
