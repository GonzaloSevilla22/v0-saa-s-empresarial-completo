"""v31-tenancy-pool-rls Paso 2 — grupo 7.5: las cuatro combinaciones de las
dos palancas (`tenancy_tx_scope_enabled`, `tenancy_rls_role_enabled`).

Tres son válidas (Settings se construye sin error). La cuarta —Paso 2
encendido sin Paso 1— es inválida por diseño (D6: `SET LOCAL ROLE` sin la
transacción explícita del Paso 1 no tiene alcance transaccional que lo
sostenga hasta la query de negocio) y SHALL fallar explícito al construir
`Settings()`, es decir al arrancar el proceso — no degradar en silencio.
"""
from __future__ import annotations

import pytest
from pydantic import ValidationError

from backend.core.config import Settings


@pytest.mark.parametrize(
    ("tx_scope", "rls_role"),
    [
        (False, False),  # off/off — estado actual de prod hoy
        (True, False),  # on/off — Paso 1 solo (estado que el PO firmó para la ventana de observación)
        (True, True),  # on/on — Paso 1 + Paso 2
    ],
)
def test_valid_flag_combinations_construct_without_error(tx_scope: bool, rls_role: bool) -> None:
    s = Settings(tenancy_tx_scope_enabled=tx_scope, tenancy_rls_role_enabled=rls_role)
    assert s.tenancy_tx_scope_enabled is tx_scope
    assert s.tenancy_rls_role_enabled is rls_role


def test_invalid_combination_step2_on_step1_off_fails_explicitly_at_startup() -> None:
    """La única combinación inválida de las cuatro (tasks.md 7.5): Paso 2
    encendido con Paso 1 apagado. Falla en la construcción de `Settings()`
    —que corre al importar `backend.core.config` (arranque del proceso)—
    con un mensaje que explica el POR QUÉ (D6), no un error críptico."""
    with pytest.raises(ValidationError) as exc_info:
        Settings(tenancy_tx_scope_enabled=False, tenancy_rls_role_enabled=True)

    message = str(exc_info.value)
    assert "tenancy_rls_role_enabled" in message
    assert "tenancy_tx_scope_enabled" in message


def test_default_settings_have_both_flags_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """D8: mergear deja el código inerte — ambas palancas apagadas por
    defecto cuando no hay variables de entorno que las enciendan. Se
    despejan explícitamente las dos env vars (y no sólo `_env_file=None`,
    que sólo desactiva el archivo `.env` — pydantic-settings sigue leyendo
    el entorno real del proceso) para que este test sea determinístico sin
    importar qué haya seteado el shell que lo ejecuta (p.ej. al verificar
    a mano las 4 combinaciones de tasks.md 7.5)."""
    monkeypatch.delenv("TENANCY_TX_SCOPE_ENABLED", raising=False)
    monkeypatch.delenv("TENANCY_RLS_ROLE_ENABLED", raising=False)
    s = Settings(_env_file=None)  # type: ignore[call-arg]
    assert s.tenancy_tx_scope_enabled is False
    assert s.tenancy_rls_role_enabled is False
