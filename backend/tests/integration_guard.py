"""Fail-closed del tier de integración (v31-money-integration-tests, D2).

Con `CI_REQUIRE_INTEGRATION=1` el tier de CI no puede terminar en verde sin haber ejercitado la base:

1. `pytest_sessionstart` — preflight: valida el host del DSN y abre/cierra una conexión. Si falla,
   la sesión aborta con código 1 y un mensaje con el DSN SIN credenciales y la causa, en vez de
   recolectar ~130 skips para descubrir que no hay base.
2. `pytest_collection_finish` — si la selección no contiene ningún test `integration` (una
   expresión `-m` mal escrita), aborta con 1 en lugar de informar «0 tests» en verde.
3. `pytest_runtest_makereport` — un test `integration` y NO `arca` cuyo reporte, en cualquier fase,
   sale `skipped` se reescribe a `failed` con el motivo original. Cubre los `pytest.skip` de
   `integration_db.connect()`, los de fixtures y cualquier skip futuro, sin tocar cada test.

Sin la variable no hace nada: en local los tests se siguen salteando cuando no hay Postgres, y el job
hermético (`-m "not integration"`) no cambia. Los `arca` (servicio real de ARCA, nunca en CI) están
exentos. Un `xfail` no cuenta como skip y no se reescribe; la regla es que ningún test del tier lo lleva.

`backend/tests/conftest.py` re-exporta los hooks con un import explícito (no `pytest_plugins`: en un
conftest que no es el de la raíz ya no está soportado). `pytester` los carga aislados con
`-p backend.tests.integration_guard`.
"""
from __future__ import annotations

import asyncio
import os

import asyncpg
import pytest

from backend.tests import integration_db

ENV_VAR = "CI_REQUIRE_INTEGRATION"


def integration_required() -> bool:
    return os.environ.get(ENV_VAR) == "1"


async def _ping(dsn: str) -> None:
    conn = await asyncpg.connect(dsn, timeout=15)
    await conn.close()


def preflight() -> None:
    """Valida el host del DSN y comprueba que la base responde; lanza si no."""
    dsn = integration_db.assert_local_dsn()
    asyncio.run(_ping(dsn))


def pytest_sessionstart(session: pytest.Session) -> None:
    if not integration_required():
        return
    try:
        preflight()
    except Exception as exc:  # noqa: BLE001 - cualquier causa aborta la sesión con un mensaje legible
        shown = integration_db._redacted(integration_db.DSN)
        pytest.exit(
            f"{ENV_VAR}=1: preflight del tier de integración falló contra {shown}: "
            f"{type(exc).__name__}: {exc}",
            returncode=1,
        )


def pytest_collection_finish(session: pytest.Session) -> None:
    if not integration_required():
        return
    if not any(item.get_closest_marker("integration") for item in session.items):
        pytest.exit(
            f"{ENV_VAR}=1: la selección no contiene ningún test marcado `integration` "
            "(¿expresión -m mal escrita?); no se informa «0 tests» en verde.",
            returncode=1,
        )


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item: pytest.Item, call: pytest.CallInfo):
    outcome = yield
    if not integration_required():
        return
    if item.get_closest_marker("integration") is None or item.get_closest_marker("arca") is not None:
        return
    report = outcome.get_result()
    if report.skipped and not hasattr(report, "wasxfail"):
        longrepr = report.longrepr
        reason = longrepr[2] if isinstance(longrepr, tuple) and len(longrepr) == 3 else str(longrepr)
        reason = reason.removeprefix("Skipped: ")
        report.outcome = "failed"
        report.longrepr = (
            f"{ENV_VAR}=1: un test de integración no puede saltearse en CI (fase {report.when}). "
            f"Motivo original: {reason}"
        )
