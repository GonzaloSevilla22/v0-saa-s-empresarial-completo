"""v31-tenancy-pool-rls Paso 1 — grupo 3 (D3): atomicidad por request.

Con la palanca `tenancy_tx_scope_enabled` encendida, `get_db_conn` abre una
transacción explícita ANTES de yieldar la conexión (grupo 2). Consecuencia
directa (D3, no una decisión aparte): los 9 `async with self._conn.transaction()`
de los repositories (`backend/repositories/*.py`) dejan de ser transacciones
de nivel superior y pasan a ser SAVEPOINTs anidados bajo la transacción del
request — así es como asyncpg (y Postgres) tratan una transacción abierta
dentro de otra ya abierta, sin que el código de los repositories necesite
cambiar una sola línea.

No hay Postgres real en la suite (todo mockeado, ver conftest.py). Un mock
de `unittest.mock` no puede reproducir la semántica de anidamiento
BEGIN/SAVEPOINT/RELEASE/ROLLBACK TO — así que este archivo define un doble
mínimo (`FakeTxConnection`) que SÍ la modela: un buffer de "escrituras" por
nivel de anidamiento, donde un nivel interno que sale sin excepción se
funde en el buffer del nivel padre (RELEASE SAVEPOINT), y sólo el nivel más
externo, al salir sin excepción, persiste a `committed` (COMMIT real). Esto
no reemplaza una prueba de integración contra Postgres real (fuera del
alcance del Paso 1, ver design.md "Probado bajo carga"); prueba el
MECANISMO — que es exactamente lo que D3 afirma que cambia.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest


class _FakeTxCtx:
    def __init__(self, conn: "FakeTxConnection"):
        self._conn = conn

    async def __aenter__(self):
        self._conn._stack.append([])
        return self

    async def __aexit__(self, exc_type, exc, tb):
        buf = self._conn._stack.pop()
        if exc_type is None:
            if self._conn._stack:
                # Nivel interno (SAVEPOINT) que sale limpio: RELEASE — se
                # funde en el buffer del nivel padre, todavía sin persistir.
                self._conn._stack[-1].extend(buf)
            else:
                # Nivel más externo (transacción del request): COMMIT real.
                self._conn.committed.extend(buf)
        # Con excepción: ROLLBACK (o ROLLBACK TO SAVEPOINT) — el buffer del
        # nivel que sale se descarta, sin tocar committed ni el padre.
        return False


class FakeTxConnection:
    """Doble mínimo de asyncpg.Connection que modela anidamiento de
    transacciones (BEGIN + SAVEPOINT) para probar D3 sin una DB real."""

    def __init__(self):
        self.committed: list[str] = []
        self._stack: list[list[str]] = []

    def transaction(self):
        return _FakeTxCtx(self)

    async def execute(self, *_args, **_kwargs):
        # set_config de get_db_conn — no escribe datos de negocio.
        return "SET"

    async def write(self, label: str) -> None:
        """Emula un INSERT/UPDATE de un repository: va al buffer del nivel
        de anidamiento más interno actualmente abierto."""
        assert self._stack, "write() fuera de cualquier conn.transaction()"
        self._stack[-1].append(label)


TEST_USER = {"user_id": "user-atomicity", "role": "user", "account_role": None, "plan": "pro"}


async def _open_get_db_conn(fake_conn: FakeTxConnection, *, enabled: bool):
    """Adquiere `conn` a través del get_db_conn REAL (no un simulacro
    aparte) para que este test ejercite el código de producción, con
    `fake_conn` en lugar de la conexión asyncpg real."""
    import backend.core.database as db_module

    class _FakePool:
        def acquire(self):
            return _FakeAcquireCtx(fake_conn)

    class _FakeAcquireCtx:
        def __init__(self, conn):
            self._conn = conn

        async def __aenter__(self):
            return self._conn

        async def __aexit__(self, *_exc):
            return False

    db_module.pool = _FakePool()
    settings_patch = patch("backend.core.database.settings")
    mock_settings = settings_patch.start()
    mock_settings.tenancy_tx_scope_enabled = enabled
    mock_settings.tenancy_tx_idle_timeout = "30s"

    gen = db_module.get_db_conn(TEST_USER)
    conn = await gen.__anext__()
    return gen, conn, settings_patch


class _DownstreamFailure(Exception):
    pass


# ── 3.1 RED / 3.2 GREEN ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_step1_off_write_inside_repo_transaction_survives_later_failure():
    """RED (3.1) contra el comportamiento ACTUAL (palanca apagada): hoy el
    `conn.transaction()` de un repository ES la transacción de nivel
    superior (no hay una externa que lo envuelva) — así que si comitea y
    ALGO MÁS FALLA DESPUÉS en el mismo request, lo escrito ya quedó
    persistido. Es el comportamiento que D3 señala como el que cambia."""
    fake_conn = FakeTxConnection()
    gen, conn, settings_patch = await _open_get_db_conn(fake_conn, enabled=False)
    try:
        # Repository: abre su propia transacción de nivel superior y escribe.
        async with conn.transaction():
            await conn.write("insert_sale")

        # Algo más falla DESPUÉS, en el mismo request (p.ej. un paso
        # posterior del handler). Con la palanca apagada no hay transacción
        # externa que lo capture: el generador simplemente termina normal
        # (get_db_conn no envuelve nada), la falla downstream es asunto del
        # caller, no de get_db_conn.
        with pytest.raises(StopAsyncIteration):
            await gen.__anext__()

        assert "insert_sale" in fake_conn.committed, (
            "comportamiento actual (palanca apagada): la escritura del "
            "repository ya está comiteada, con o sin fallas posteriores"
        )
    finally:
        settings_patch.stop()


@pytest.mark.asyncio
async def test_step1_on_write_inside_repo_transaction_rolls_back_with_request_failure():
    """GREEN (3.2): con la palanca encendida, el `conn.transaction()` del
    repository queda anidado (SAVEPOINT) bajo la transacción externa que
    abre get_db_conn. Si el request falla DESPUÉS de esa escritura, la
    transacción externa hace ROLLBACK y la escritura NUNCA llega a
    `committed` — D3, el cambio de comportamiento deliberado."""
    fake_conn = FakeTxConnection()
    gen, conn, settings_patch = await _open_get_db_conn(fake_conn, enabled=True)
    try:
        async with conn.transaction():  # repository: ahora es un SAVEPOINT
            await conn.write("insert_sale")

        # El request falla después de la escritura — FastAPI hace exactamente
        # esto (AsyncExitStack.athrow) cuando el handler lanza una excepción.
        with pytest.raises(_DownstreamFailure):
            await gen.athrow(_DownstreamFailure("falla posterior a la escritura"))

        assert "insert_sale" not in fake_conn.committed, (
            "con la transacción externa activa, una falla posterior a la "
            "escritura interna NO debe dejar trabajo persistido (D3)"
        )
    finally:
        settings_patch.stop()


# ── 3.3 TRIANGULATE ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_step1_on_handled_savepoint_rollback_does_not_abort_whole_request():
    """TRIANGULATE 3.3(a): un rollback INTERNO de savepoint (el repository
    atrapa su propia excepción y no la re-propaga) no aborta el request
    completo — una escritura posterior, fuera del savepoint fallido, sí
    persiste cuando el request termina bien."""
    fake_conn = FakeTxConnection()
    gen, conn, settings_patch = await _open_get_db_conn(fake_conn, enabled=True)
    try:
        # Repository: intenta escribir algo inválido, su propio código
        # atrapa el error de validación de negocio y NO lo re-propaga —
        # patrón real de los 9 call sites (ver tasks.md 3.4 / design D3).
        try:
            async with conn.transaction():
                await conn.write("insert_bad")
                raise ValueError("violación de invariante de negocio")
        except ValueError:
            pass  # manejado dentro del repository, el request continúa

        # El resto del request escribe algo válido, fuera del savepoint fallido.
        await conn.write("insert_good")

        # Request exitoso: get_db_conn cierra limpio (commit).
        with pytest.raises(StopAsyncIteration):
            await gen.__anext__()

        assert "insert_good" in fake_conn.committed
        assert "insert_bad" not in fake_conn.committed
    finally:
        settings_patch.stop()


@pytest.mark.asyncio
async def test_step1_on_successful_request_with_internal_write_persists():
    """TRIANGULATE 3.3(b): un request exitoso con escritura interna (vía el
    `conn.transaction()` — SAVEPOINT — de un repository) sí persiste
    cuando el request completo termina sin excepción."""
    fake_conn = FakeTxConnection()
    gen, conn, settings_patch = await _open_get_db_conn(fake_conn, enabled=True)
    try:
        async with conn.transaction():
            await conn.write("insert_ok")

        with pytest.raises(StopAsyncIteration):
            await gen.__anext__()

        assert "insert_ok" in fake_conn.committed
    finally:
        settings_patch.stop()
