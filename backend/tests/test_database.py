import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

TEST_USER = {
    "user_id": "test-user-id",
    "role": "user",
    "account_role": None,
    "plan": "pro",
}


def _expected_request_claims(user: dict) -> str:
    return json.dumps({"sub": user["user_id"], "role": "authenticated"})


# ── v31-tenancy-pool-rls Paso 1 — grupo 2 ───────────────────────────────
#
# `get_db_conn` queda detrás de la palanca `settings.tenancy_tx_scope_enabled`
# (D8, apagada por defecto). Este archivo reemplaza el test que afirmaba
# literalmente el comportamiento defectuoso (`query.count(", false)") == 2`
# y la presencia de `app.jwt_claims`, GUC que design.md D2 confirma que NO
# lee nadie en todo el repositorio (migraciones, backend, frontend, edge
# functions — barrido de tasks.md 1.4). El test viejo protegía el bug en
# vez de detectarlo: se reemplaza en vez de borrarse en silencio (tasks.md
# 2.1).


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_uses_transactional_scope(mock_pool):
    """RED→GREEN (2.1/2.2): con la palanca encendida, get_db_conn SHALL abrir
    una transacción explícita y setear `request.jwt.claims` con alcance
    TRANSACCIONAL (`set_config(..., true)`, D1) — NUNCA `app.jwt_claims`
    (D2: cero lectores)."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            conn = await gen.__anext__()

            # La transacción se abrió (D1) antes de yieldar la conexión.
            conn_mock.transaction.assert_called_once()
            transaction_ctx = conn_mock.transaction.return_value
            transaction_ctx.__aenter__.assert_awaited_once()

            conn_mock.execute.assert_awaited_once()
            query, request_claims, idle_timeout = conn_mock.execute.call_args[0]

            assert "app.jwt_claims" not in query, (
                "app.jwt_claims no debe inyectarse con la palanca encendida "
                "(design.md D2: cero lectores en todo el repositorio)"
            )
            assert "set_config('request.jwt.claims'" in query
            assert "idle_in_transaction_session_timeout" in query
            # Alcance TRANSACCIONAL: is_local=true (equivalente a SET LOCAL),
            # no alcance de sesión (false) — D1.
            assert query.count(", true)") == 2
            assert query.count(", false)") == 0
            assert request_claims == _expected_request_claims(TEST_USER)
            assert idle_timeout == "30s"
            assert conn is conn_mock

            # Cerrar el generador limpiamente (commit simulado, sin excepción).
            with pytest.raises(StopAsyncIteration):
                await gen.__anext__()
            transaction_ctx.__aexit__.assert_awaited_once()
            # __aexit__ recibido sin excepción == commit.
            assert transaction_ctx.__aexit__.await_args.args == (None, None, None)
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_off_matches_legacy_behavior_byte_for_byte(mock_pool):
    """GREEN (tasks.md 4.1): con la palanca apagada (default), el
    comportamiento es idéntico byte a byte al de antes de este change —
    incluido el GUC `app.jwt_claims` que nadie lee. Es el camino de
    rollback inmediato (D8): se retira recién en el change de limpieza
    posterior (tasks.md 9.7), NO acá."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = False

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            conn = await gen.__anext__()

            # Camino legacy: SIN transacción explícita de request.
            conn_mock.transaction.assert_not_called()

            conn_mock.execute.assert_awaited_once()
            query, app_claims, request_claims = conn_mock.execute.call_args[0]
            assert "set_config('app.jwt_claims'" in query
            assert "set_config('request.jwt.claims'" in query
            # Alcance de SESIÓN (is_local=false) — comportamiento previo,
            # defectuoso, conservado sólo como palanca de apagado.
            assert query.count(", false)") == 2
            assert app_claims == json.dumps(TEST_USER)
            assert request_claims == _expected_request_claims(TEST_USER)
            assert conn is conn_mock
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_rollback_on_exception_no_writes_leak(mock_pool):
    """TRIANGULATE 2.3(a): un request que lanza una excepción produce
    ROLLBACK (la transacción externa recibe la excepción en __aexit__, no
    un commit limpio) y la excepción se re-propaga — FastAPI usa
    exactamente este mecanismo (AsyncExitStack.athrow) para limpiar
    dependencias `yield` cuando el handler falla."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()

            transaction_ctx = conn_mock.transaction.return_value

            class _BoomError(Exception):
                pass

            with pytest.raises(_BoomError):
                await gen.athrow(_BoomError("downstream failure"))

            transaction_ctx.__aexit__.assert_awaited_once()
            exc_type, exc, _tb = transaction_ctx.__aexit__.await_args.args
            assert exc_type is _BoomError, (
                "la transacción externa SHALL recibir la excepción (rollback), "
                "no un cierre limpio (commit) — design.md D1/D3"
            )
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_two_requests_do_not_share_claims(mock_pool):
    """TRIANGULATE 2.3(b): dos requests consecutivos que reutilizan la misma
    conexión mockeada (simulando reciclado de conexión física del pool) NO
    comparten claims — cada invocación de get_db_conn pasa los suyos
    propios como parámetro de la query, nunca un residuo del anterior."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"

            from backend.core.database import get_db_conn

            user_a = {"user_id": "user-aaaa", "role": "user", "account_role": None, "plan": "pro"}
            user_b = {"user_id": "user-bbbb", "role": "user", "account_role": None, "plan": "pro"}

            gen_a = get_db_conn(user_a)
            await gen_a.__anext__()
            with pytest.raises(StopAsyncIteration):
                await gen_a.__anext__()

            gen_b = get_db_conn(user_b)
            await gen_b.__anext__()
            with pytest.raises(StopAsyncIteration):
                await gen_b.__anext__()

            assert conn_mock.execute.await_count == 2
            first_call_claims = conn_mock.execute.await_args_list[0].args[1]
            second_call_claims = conn_mock.execute.await_args_list[1].args[1]

            assert first_call_claims == _expected_request_claims(user_a)
            assert second_call_claims == _expected_request_claims(user_b)
            assert first_call_claims != second_call_claims
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_set_config_between_transaction_open_and_yield(mock_pool):
    """TRIANGULATE 2.3(c): el orden es normativo, no incidental — la
    transacción se abre PRIMERO, `set_config` corre DESPUÉS (todavía dentro
    de la transacción) y ANTES de yieldar la conexión al caller."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    call_order: list[str] = []
    transaction_ctx = conn_mock.transaction.return_value

    async def _record_enter(*_args, **_kwargs):
        call_order.append("transaction_enter")
        return None

    async def _record_execute(*_args, **_kwargs):
        call_order.append("execute")
        return "SET"

    transaction_ctx.__aenter__ = AsyncMock(side_effect=_record_enter)
    conn_mock.execute = AsyncMock(side_effect=_record_execute)

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()
            call_order.append("yielded")

            assert call_order == ["transaction_enter", "execute", "yielded"], (
                "orden esperado: abrir transacción -> set_config -> yield "
                f"(orden real: {call_order!r})"
            )
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_service_conn_has_no_request_transaction_or_claims(mock_pool):
    """RED/GREEN 2.4 (D5): `get_service_conn` es un camino de servicio
    explícitamente separado del de request — nunca abre la transacción del
    Paso 1 ni inyecta claims, sin importar la palanca. Lo usan el webhook de
    pagos y el relay CAE del cron; ambos son cross-account por diseño."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"

            from backend.core.database import get_service_conn

            gen = get_service_conn()
            conn = await gen.__anext__()

            conn_mock.transaction.assert_not_called()
            conn_mock.execute.assert_not_called()
            assert conn is conn_mock
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_raises_when_pool_not_initialized():
    import backend.core.database as db_module

    db_module.pool = None

    from fastapi import HTTPException

    from backend.core.database import get_db_conn

    with pytest.raises(HTTPException) as exc_info:
        async for _ in get_db_conn(TEST_USER):
            pass

    assert exc_info.value.status_code == 503


@pytest.mark.asyncio
async def test_init_pool_raises_when_database_url_empty():
    with patch("backend.core.database.settings") as mock_settings:
        mock_settings.database_url = ""

        from backend.core.database import init_pool

        with pytest.raises(ValueError, match="DATABASE_URL"):
            await init_pool()


@pytest.mark.asyncio
async def test_init_pool_creates_pool_with_correct_params():
    with (
        patch("backend.core.database.settings") as mock_settings,
        patch("backend.core.database.asyncpg") as mock_asyncpg,
    ):
        mock_settings.database_url = "postgresql://user:pass@host/db"
        mock_asyncpg.create_pool = AsyncMock(return_value=MagicMock())

        import backend.core.database as db_module

        db_module.pool = None

        from backend.core.database import init_pool

        await init_pool()

        mock_asyncpg.create_pool.assert_called_once_with(
            "postgresql://user:pass@host/db",
            min_size=2,
            max_size=10,
            statement_cache_size=0,
        )

        db_module.pool = None
