"""fix/service-role-key-env-alias — bug de producción 2026-09-04.

Síntoma reproducido en prod: el PO tocó "Pasarme a Inicial" en `/planes` y
recibió 502 "No se pudo resolver el email del usuario" (logs de Render:
`[subscriptions] No se pudo resolver el email del usuario <uuid>` × 7, sin
el warning `[payments] Could not fetch user email for ...` que
`_fetch_user_email` emite cuando la llamada HTTP responde != 200 — es decir,
la llamada HTTP nunca se hizo).

Causa raíz: `Settings.service_role_key` (backend/core/config.py) no declaraba
`validation_alias`, así que pydantic-settings lo leía del nombre implícito
`SERVICE_ROLE_KEY` — variable que NO existe en el servicio de Render. La que
sí existe (verificada por nombre, nunca por valor) es
`SUPABASE_SERVICE_ROLE_KEY`, consistente con `SUPABASE_URL`/`SUPABASE_JWT_SECRET`.
`_fetch_user_email` (backend/services/payments.py) hace short-circuit ANTES
de la llamada HTTP cuando `not settings.service_role_key` — de ahí la
ausencia del warning `[payments] Could not fetch user email for ...`: la
función nunca llegó a intentar la request.

Este archivo cubre la capa `Settings` (el fix real). El caso central —
"con la variable de entorno seteada, `_fetch_user_email` llega a hacer la
llamada HTTP"— vive en `test_payments.py::TestFetchUserEmailEnvAlias`.
"""
from __future__ import annotations

import pytest

from backend.core.config import Settings


def test_reads_supabase_service_role_key_env_var(monkeypatch: pytest.MonkeyPatch) -> None:
    """RED (antes del fix): `SUPABASE_SERVICE_ROLE_KEY` es el nombre REAL
    configurado en Render — el campo debe leerlo."""
    monkeypatch.delenv("SERVICE_ROLE_KEY", raising=False)
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "prod-key-abc123")

    s = Settings(_env_file=None)  # type: ignore[call-arg]

    assert s.service_role_key == "prod-key-abc123"


def test_legacy_service_role_key_env_var_still_works(monkeypatch: pytest.MonkeyPatch) -> None:
    """TRIANGULATE: el nombre viejo `SERVICE_ROLE_KEY` (usado hoy por algún
    entorno local/CI) sigue funcionando — el alias es aditivo, no un
    reemplazo que rompa lo que ya andaba."""
    monkeypatch.delenv("SUPABASE_SERVICE_ROLE_KEY", raising=False)
    monkeypatch.setenv("SERVICE_ROLE_KEY", "legacy-key-xyz789")

    s = Settings(_env_file=None)  # type: ignore[call-arg]

    assert s.service_role_key == "legacy-key-xyz789"


def test_supabase_prefixed_name_takes_precedence_when_both_set(monkeypatch: pytest.MonkeyPatch) -> None:
    """TRIANGULATE: si por algún motivo ambas variables conviven, gana el
    nombre real de Render (`SUPABASE_SERVICE_ROLE_KEY`) — es el primero en
    `AliasChoices`, y es el que debe reflejar el valor vivo en prod."""
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "prod-key-real")
    monkeypatch.setenv("SERVICE_ROLE_KEY", "legacy-key-stale")

    s = Settings(_env_file=None)  # type: ignore[call-arg]

    assert s.service_role_key == "prod-key-real"


def test_defaults_to_empty_when_neither_env_var_set(monkeypatch: pytest.MonkeyPatch) -> None:
    """TRIANGULATE: sin ninguna de las dos variables, el campo sigue
    degradando a `""` (comportamiento actual preservado, no un default
    nuevo que enmascare la ausencia real de configuración)."""
    monkeypatch.delenv("SUPABASE_SERVICE_ROLE_KEY", raising=False)
    monkeypatch.delenv("SERVICE_ROLE_KEY", raising=False)

    s = Settings(_env_file=None)  # type: ignore[call-arg]

    assert s.service_role_key == ""
